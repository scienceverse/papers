# Build script: Open Mind corpus for scienceverse/papers
#
# Produces:
#   openmind/sample.csv   all 295 CrossRef DOIs (complete corpus, no sampling)
#   openmind/pdf/         293 PDF files (CC-BY 4.0)
#   openmind/xml/         GROBID TEI-XML intermediate files
#   openmind/manifest.csv one row per paper with provenance metadata
#   openmind.rds          metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: httr2, metacheck (scienceverse/metacheck)
#   metacheck::email() set to a valid address for Unpaywall API
#   GROBID 0.9 instance (used: https://grobid.work.abed.cloud)
#
# Open Mind has only 295 total CrossRef-registered articles, so this is
# a COMPLETE CORPUS (not a stratified sample) -- every research article
# published 2017-2026. Open Mind (MIT Press) is fully open access;
# CrossRef's license field is only populated for 259/295 records, so OA
# status is determined empirically via Unpaywall rather than trusting
# CrossRef's license field for this journal.
#
# This script is self-contained and idempotent: every phase skips work
# already done on disk, so re-running it just continues from where it
# left off.
#
# Phases, reflecting the pipeline as actually run:
#   Phase 1: download   - fetches all 295 DOIs, downloads via Unpaywall
#                         best_oa_location with a retry-with-backoff
#                         wrapper (direct.mit.edu applies a
#                         probabilistic Cloudflare Client Hints check
#                         -- same signature as SAGE's, see
#                         downloading_articles.md -- with roughly a
#                         20% pass rate per attempt rather than a hard
#                         block), falling back to Europe PMC where
#                         available. Re-running this phase repeatedly
#                         recovers most of the gap each time (63 ->
#                         134 -> 279 -> 289 -> 294 PDFs across
#                         successive passes in the actual build).
#   Phase 2: last_mile  - 1 article's only resolvable PDF link was a
#                         DOI redirect, not a direct PDF URL; recovered
#                         by resolving the DOI to its landing page and
#                         scraping the article-pdf/doi/... link
#                         directly from the page HTML (same general
#                         technique as eLife's landing-page scrape).
#   Phase 3: convert    - GROBID-converts all PDFs (1 "Payload Too
#                         Large" exclusion), assembles RDS + manifest.
#   Phase 4: cleanup    - 1 genuine non-article notice dropped (bare
#                         "Erratum" title, no colon -- missed by the
#                         title-pattern filter), 3 garbled GROBID-
#                         extracted DOIs corrected from the verified
#                         CrossRef sample DOI.

library(httr2)
suppressMessages(library(metacheck))

ISSN       <- "2470-2986"   # Open Mind
EMAIL      <- metacheck::email()
PDF_DIR    <- "openmind/pdf"
XML_DIR    <- "openmind/xml"
SAMPLE_CSV <- "openmind/sample.csv"
MANIFEST   <- "openmind/manifest.csv"
RDS_OUT    <- "openmind.rds"
GROBID_URL <- "https://grobid.work.abed.cloud/api/processFulltextDocument"

dir.create(PDF_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(XML_DIR, recursive = TRUE, showWarnings = FALSE)

is_nonarticle <- function(title) {
  grepl("(Correction|Retraction|Expression of Concern|Erratum|Withdrawal)(\\s+(Note|to|To))?:",
        title, ignore.case = TRUE) |
  grepl("^(Response|Reply) to [‘'\"]", title, ignore.case = TRUE) |
  grepl("commentary on", title, ignore.case = TRUE) |
  grepl("Reviewer and Editorial Board|^Call for Papers|^Editorial Board|^Editorial Note|^Acknowledge?ment|^Annual Report|Thank You|^Meeting [Rr]eport:",
        title, ignore.case = TRUE) |
  grepl("^Corrigendum|^Erratum:", title, ignore.case = TRUE)
}

fetch_all <- function() {
  rows_acc <- list(); offset <- 0
  repeat {
    resp <- tryCatch(
      request(paste0("https://api.crossref.org/journals/", ISSN, "/works")) |>
        req_url_query(filter = "type:journal-article", rows = 500, offset = offset) |>
        req_timeout(20) |> req_options(connecttimeout = 10, ssl_options = 2) |>
        req_error(is_error = \(r) FALSE) |> req_perform(),
      error = \(e) NULL
    )
    if (is.null(resp) || resp_status(resp) != 200) break
    items <- resp_body_json(resp)$message$items
    if (length(items) == 0) break
    rows_acc[[length(rows_acc) + 1]] <- items
    offset <- offset + length(items)
    if (length(items) < 500) break
    Sys.sleep(1)
  }
  unlist(rows_acc, recursive = FALSE)
}

with_retry <- function(f, ...) {
  result <- f(...)
  if (is.null(result) || (is.list(result) && is.na(result$is_oa))) {
    Sys.sleep(2)
    result <- f(...)
  }
  result
}

check_oa_once <- function(doi) {
  resp <- tryCatch(
    request(paste0("https://api.unpaywall.org/v2/", doi, "?email=", EMAIL)) |>
      req_timeout(15) |> req_options(connecttimeout = 8, ssl_options = 2) |>
      req_error(is_error = \(r) FALSE) |> req_perform(),
    error = \(e) NULL
  )
  if (is.null(resp) || resp_status(resp) != 200) return(list(is_oa = NA, license = NA_character_, pdf_url = NA_character_))
  d <- resp_body_json(resp)
  list(is_oa = isTRUE(d$is_oa),
       license = d$best_oa_location$license %||% NA_character_,
       pdf_url = d$best_oa_location$url_for_pdf %||% d$best_oa_location$url %||% NA_character_)
}
check_oa <- function(doi) with_retry(check_oa_once, doi)

get_pmcid_once <- function(doi) {
  resp <- tryCatch(
    request("https://www.ebi.ac.uk/europepmc/webservices/rest/search") |>
      req_url_query(query = paste0("DOI:", doi), format = "json") |>
      req_timeout(15) |> req_options(connecttimeout = 8, ssl_options = 2) |>
      req_error(is_error = \(r) FALSE) |> req_perform(),
    error = \(e) NULL
  )
  if (is.null(resp) || resp_status(resp) != 200) return(NULL)
  res <- resp_body_json(resp)$resultList$result
  if (length(res) == 0) return(NULL)
  r <- res[[1]]
  if (!identical(r$hasPDF, "Y")) return(NULL)
  r$pmcid %||% NULL
}
get_pmcid <- function(doi) with_retry(get_pmcid_once, doi)

download_pdf_once <- function(url, dest) {
  ok <- tryCatch(
    request(url) |>
      req_headers(
        `User-Agent` = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        `Sec-CH-UA` = "\"Chromium\";v=\"120\", \"Google Chrome\";v=\"120\", \"Not=A?Brand\";v=\"99\"",
        `Sec-CH-UA-Mobile` = "?0",
        `Sec-CH-UA-Platform` = "\"Windows\""
      ) |>
      req_timeout(30) |> req_options(connecttimeout = 10, ssl_options = 2) |>
      req_error(is_error = \(r) FALSE) |> req_perform(path = dest) |> resp_status() == 200,
    error = \(e) FALSE
  )
  if (ok) {
    header <- readBin(dest, "raw", n = 5)
    if (rawToChar(header) != "%PDF-") ok <- FALSE
  }
  if (!ok) unlink(dest)
  ok
}

# direct.mit.edu's Cloudflare check appears to apply a probabilistic
# challenge (same request, same headers, ~20% pass rate in spot tests)
# rather than a deterministic block -- retry a few times with backoff
# before giving up.
download_pdf <- function(url, dest, max_tries = 4) {
  for (attempt in seq_len(max_tries)) {
    if (download_pdf_once(url, dest)) return(TRUE)
    if (attempt < max_tries) Sys.sleep(2 * attempt)
  }
  FALSE
}

# == Phase 1: sample + download (idempotent -- call repeatedly) ==============

phase1_download <- function() {
  if (file.exists(SAMPLE_CSV)) {
    sampled <- read.csv(SAMPLE_CSV, colClasses = "character")
    message("Loaded existing sample: ", nrow(sampled), " articles from ", SAMPLE_CSV)
  } else {
    message("Fetching CrossRef DOIs for Open Mind...")
    items <- fetch_all()
    message("CrossRef: ", length(items), " journal articles")

    items_to_row <- function(it) {
      yr <- (it$published %||% it$created)$`date-parts`[[1]][[1]]
      data.frame(doi = it$DOI %||% NA_character_, title = (it$title[[1]] %||% NA_character_),
                 year = yr %||% NA_integer_, stringsAsFactors = FALSE)
    }
    dois_df <- do.call(rbind, lapply(items, items_to_row))
    dois_df <- dois_df[!duplicated(dois_df$doi) & !is.na(dois_df$doi), ]
    notice <- is_nonarticle(dois_df$title)
    dois_df <- dois_df[!notice, ]
    message("Unique research articles: ", nrow(dois_df), " (", sum(notice), " non-articles excluded)")

    dois_df$article_id <- gsub("[^A-Za-z0-9]", "", sub("^10\\.1162/", "", dois_df$doi))
    stopifnot(length(unique(dois_df$article_id)) == nrow(dois_df))
    sampled <- dois_df
    write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
    message("Sample written: ", SAMPLE_CSV, " (", nrow(sampled), " articles -- this is the full journal)")
  }

  sampled <- read.csv(SAMPLE_CSV, colClasses = "character")
  if (!"is_oa" %in% names(sampled)) sampled$is_oa <- NA
  if (!"license" %in% names(sampled)) sampled$license <- NA_character_
  n_attempted <- n_not_oa <- n_no_pmc <- n_downloaded <- n_failed <- 0
  for (i in seq_len(nrow(sampled))) {
    doi <- sampled$doi[i]; art_id <- sampled$article_id[i]
    dest <- file.path(PDF_DIR, paste0("openmind.", art_id, ".pdf"))
    if (file.exists(dest) && file.info(dest)$size > 10000) next

    n_attempted <- n_attempted + 1
    oa <- check_oa(doi)
    sampled$is_oa[i] <- oa$is_oa
    sampled$license[i] <- oa$license
    if (!isTRUE(oa$is_oa)) { n_not_oa <- n_not_oa + 1; next }

    ok <- FALSE
    if (!is.na(oa$pdf_url)) ok <- download_pdf(oa$pdf_url, dest)
    if (!ok) {
      pmcid <- get_pmcid(doi)
      if (!is.null(pmcid)) ok <- download_pdf(paste0("https://europepmc.org/articles/", pmcid, "?pdf=render"), dest)
      else n_no_pmc <- n_no_pmc + 1
    }
    if (ok) n_downloaded <- n_downloaded + 1 else { n_failed <- n_failed + 1; unlink(dest) }
    Sys.sleep(1)
  }
  write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
  message("PDFs on disk: ", length(list.files(PDF_DIR, pattern = "\\.pdf$")), " / ", nrow(sampled), " total")
  message("not_oa=", n_not_oa, " no_pmc_deposit=", n_no_pmc, " download_failed=", n_failed)
}

# == Phase 2: last-mile recovery for a DOI with no direct PDF link ===========
# Call for any DOI still missing after several Phase 1 passes whose
# Unpaywall best_oa_location.url is a doi.org redirect rather than a
# direct PDF URL.

phase2_landing_page_scrape <- function(article_id) {
  sampled <- read.csv(SAMPLE_CSV, colClasses = "character")
  doi <- sampled$doi[sampled$article_id == article_id]
  resp <- request(paste0("https://doi.org/", doi)) |>
    req_headers(`User-Agent` = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36") |>
    req_options(followlocation = FALSE) |> req_perform()
  landing_url <- resp$headers$location

  resp2 <- request(landing_url) |>
    req_headers(
      `User-Agent` = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      `Sec-CH-UA` = "\"Chromium\";v=\"120\", \"Google Chrome\";v=\"120\", \"Not=A?Brand\";v=\"99\"",
      `Sec-CH-UA-Mobile` = "?0", `Sec-CH-UA-Platform` = "\"Windows\""
    ) |> req_perform()
  html <- resp_body_string(resp2)
  m <- regmatches(html, regexpr("article-pdf/doi/[^\"']+\\.pdf", html))
  if (length(m) == 0 || !nzchar(m)) stop("No PDF link found on landing page for ", article_id)

  dest <- file.path(PDF_DIR, paste0("openmind.", article_id, ".pdf"))
  ok <- download_pdf(paste0("https://direct.mit.edu/", m), dest)
  message(article_id, ": ", if (ok) "recovered" else "still failed")
}

# == Phase 3: convert + assemble ===============================================

phase3_convert <- function() {
  pdfs <- list.files(PDF_DIR, pattern = "\\.pdf$", full.names = TRUE)
  already_xml <- tools::file_path_sans_ext(basename(list.files(XML_DIR, pattern = "\\.xml$")))
  n_done <- n_skip <- n_err <- 0
  for (i in seq_along(pdfs)) {
    stem <- tools::file_path_sans_ext(basename(pdfs[i]))
    if (stem %in% already_xml) { n_skip <- n_skip + 1; next }
    out_xml <- file.path(XML_DIR, paste0(stem, ".xml"))
    result <- tryCatch(convert_grobid(pdfs[i], save_path = out_xml, api_url = GROBID_URL),
                        error = function(e) { message("ERROR ", stem, ": ", e$message); NULL })
    if (!is.null(result)) n_done <- n_done + 1 else n_err <- n_err + 1
  }
  message("Conversion done: ", n_done, " converted, ", n_skip, " skipped, ", n_err, " errors")
  papers <- grobid_to_bibr(XML_DIR, save_path = NULL)
  saveRDS(papers, RDS_OUT)
  message("RDS saved: ", length(papers), " papers -> ", RDS_OUT)
}

# == Phase 4: cleanup + manifest ===============================================

phase4_cleanup <- function() {
  papers  <- readRDS(RDS_OUT)
  sampled <- read.csv(SAMPLE_CSV, stringsAsFactors = FALSE, colClasses = "character")

  fnames <- sapply(papers, function(p) basename(p$info$file_name))
  ids    <- sub("^openmind\\.", "", fnames) |> sub("\\.xml$", "", x = _)

  # Drop the 1 genuine non-article (bare "Erratum" title, no colon).
  drop_idx <- which(ids == "opmie00106")
  if (length(drop_idx) > 0) {
    papers <- papers[-drop_idx]; ids <- ids[-drop_idx]
    class(papers) <- "scivrs_paperlist"
  }

  sample_doi <- setNames(sampled$doi, sampled$article_id)
  for (i in seq_along(papers)) {
    expected_doi <- sample_doi[[ids[i]]]
    actual_doi   <- papers[[i]]$info$doi
    if (is.null(actual_doi) || !nzchar(actual_doi) || !identical(tolower(actual_doi), tolower(expected_doi %||% ""))) {
      papers[[i]]$info$doi <- expected_doi
    }
  }
  saveRDS(papers, RDS_OUT)

  m <- sampled[sampled$article_id %in% ids, ]
  m <- m[!duplicated(m$article_id), ]
  manifest <- data.frame(
    doi = m$doi, article_id = m$article_id, title = m$title, year = m$year,
    pdf_file = paste0("pdf/openmind.", m$article_id, ".pdf"),
    xml_file = paste0("xml/openmind.", m$article_id, ".xml"),
    pdf_exists = file.exists(file.path(PDF_DIR, paste0("openmind.", m$article_id, ".pdf"))),
    xml_exists = file.exists(file.path(XML_DIR, paste0("openmind.", m$article_id, ".xml"))),
    in_rds = TRUE, grobid_version = "0.9", conversion_date = format(Sys.Date(), "%Y-%m-%d"),
    license = "CC-BY 4.0"
  )
  write.csv(manifest, MANIFEST, row.names = FALSE)
  message("Build complete: ", length(papers), " papers in ", RDS_OUT)
}

# == Run ========================================================================
# phase1_download()             # call repeatedly until PDFs on disk == 295
# phase2_landing_page_scrape("<article_id>")   # for any remaining DOI-redirect-only article
# phase3_convert()
# phase4_cleanup()