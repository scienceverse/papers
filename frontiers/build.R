# Build script: Frontiers in Psychology corpus for scienceverse/papers
#
# Produces:
#   frontiers/sample.csv   the sampled DOIs (100/year target, 2017-2026)
#   frontiers/pdf/         1000 PDF files (CC-BY 4.0)
#   frontiers/xml/         GROBID TEI-XML intermediate files
#   frontiers/manifest.csv one row per paper with provenance metadata
#   frontiers.rds          metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: httr2, metacheck (scienceverse/metacheck)
#   metacheck::email() set to a valid address for Unpaywall API
#   GROBID 0.9 instance (used: https://grobid.work.abed.cloud)
#
# Frontiers in Psychology has roughly 51,000 articles in total, far too
# many for a complete corpus, so this is a STRATIFIED RANDOM SAMPLE
# (100/year target, 2017-2026), same approach as natcomm/scan/iperc.
# Frontiers is a fully open-access publisher (CC-BY 4.0 confirmed via
# CrossRef license sampling) with strong Europe PMC deposit coverage,
# so PDFs were sourced via the DOI -> Unpaywall OA check -> Europe PMC
# PMCID lookup -> europepmc.org direct-PDF route.
#
# This script is self-contained and idempotent: every phase skips work
# already done on disk, so re-running it just continues from where it
# left off.
#
# Phases, reflecting the pipeline as actually run:
#   Phase 1: download   - samples 100 DOIs/year, downloads via
#                         Unpaywall -> Europe PMC route.
#   Phase 2: resample   - several years (2018, 2022, 2025 -- and others
#                         affected by the intermittent Unpaywall/Europe
#                         PMC failure rate documented in
#                         downloading_articles.md) initially came up
#                         short of 100/year. Closed by resampling
#                         replacement DOIs from the same year and
#                         re-running the download loop against them,
#                         repeated until every year reached 100/100.
#   Phase 3: convert    - GROBID-converts all PDFs, assembles RDS +
#                         manifest.
#   Phase 4: cleanup    - 60 articles had a garbled or missing
#                         GROBID-extracted DOI (GROBID had pulled a
#                         reference's DOI instead of the article's own,
#                         a known failure mode on some PDF layouts);
#                         corrected from the verified CrossRef sample
#                         DOI. 4 articles had no GROBID-extracted title;
#                         backfilled from the CrossRef sample title.

library(httr2)
suppressMessages(library(metacheck))

ISSN        <- "1664-1078"   # Frontiers in Psychology
EMAIL       <- metacheck::email()
YEARS       <- 2017:2026
N_PER_YEAR  <- 100
SEED        <- 20260620
PDF_DIR     <- "frontiers/pdf"
XML_DIR     <- "frontiers/xml"
SAMPLE_CSV  <- "frontiers/sample.csv"
MANIFEST    <- "frontiers/manifest.csv"
RDS_OUT     <- "frontiers.rds"
GROBID_URL  <- "https://grobid.work.abed.cloud/api/processFulltextDocument"

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

fetch_year <- function(yr) {
  rows_acc <- list(); offset <- 0
  repeat {
    resp <- tryCatch(
      request(paste0("https://api.crossref.org/journals/", ISSN, "/works")) |>
        req_url_query(filter = paste0("from-pub-date:", yr, "-01-01,until-pub-date:", yr, "-12-31,type:journal-article"),
                       rows = 500, offset = offset) |>
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
  if (is.null(resp) || resp_status(resp) != 200) return(list(is_oa = NA, license = NA_character_))
  d <- resp_body_json(resp)
  list(is_oa = isTRUE(d$is_oa), license = d$best_oa_location$license %||% NA_character_)
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

download_pdf <- function(url, dest) {
  ok <- tryCatch(
    request(url) |>
      req_headers(`User-Agent` = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36") |>
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

download_one <- function(doi, art_id) {
  dest <- file.path(PDF_DIR, paste0("frontiers.", art_id, ".pdf"))
  if (file.exists(dest) && file.info(dest)$size > 10000) return(TRUE)
  oa <- check_oa(doi)
  if (!isTRUE(oa$is_oa)) return(FALSE)
  pmcid <- get_pmcid(doi)
  if (is.null(pmcid)) return(FALSE)
  download_pdf(paste0("https://europepmc.org/articles/", pmcid, "?pdf=render"), dest)
}

# == Phase 1: initial sample + download =======================================

phase1_download <- function() {
  if (file.exists(SAMPLE_CSV)) {
    sampled <- read.csv(SAMPLE_CSV, colClasses = "character")
    message("Loaded existing sample: ", nrow(sampled), " articles from ", SAMPLE_CSV)
  } else {
    message("Fetching CrossRef DOIs for ", length(YEARS), " years...")
    all_items <- lapply(YEARS, \(yr) { Sys.sleep(1); items <- fetch_year(yr); message("  ", yr, ": ", length(items), " journal articles"); items })
    names(all_items) <- YEARS

    items_to_row <- function(it, yr) data.frame(doi = it$DOI %||% NA_character_, title = (it$title[[1]] %||% NA_character_), year = yr, stringsAsFactors = FALSE)
    dois_df <- do.call(rbind, lapply(YEARS, \(yr) do.call(rbind, lapply(all_items[[as.character(yr)]], items_to_row, yr = yr))))
    dois_df <- dois_df[!duplicated(dois_df$doi) & !is.na(dois_df$doi), ]
    notice <- is_nonarticle(dois_df$title)
    dois_df <- dois_df[!notice, ]
    message("CrossRef: ", nrow(dois_df), " unique research articles (", sum(notice), " non-articles excluded)")

    set.seed(SEED)
    sampled <- do.call(rbind, lapply(YEARS, \(yr) {
      pool <- dois_df[dois_df$year == yr, ]
      pool[sample.int(nrow(pool), min(N_PER_YEAR, nrow(pool))), ]
    }))
    sampled$article_id <- gsub("[^A-Za-z0-9]", "", sub("^10\\.3389/", "", sampled$doi))
    stopifnot(length(unique(sampled$article_id)) == nrow(sampled))
    write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
    message("Sampled: ", nrow(sampled), " articles (", N_PER_YEAR, "/year target)")
  }

  sampled <- read.csv(SAMPLE_CSV, colClasses = "character")
  for (i in seq_len(nrow(sampled))) { download_one(sampled$doi[i], sampled$article_id[i]); Sys.sleep(1) }
  message("PDFs on disk: ", length(list.files(PDF_DIR, pattern = "\\.pdf$")), " / ", nrow(sampled))
}

# == Phase 2: resample short years (idempotent -- call repeatedly per year) ===
# Several years initially came up short of 100/year because of the
# intermittent Unpaywall/Europe PMC failure pattern (documented in
# downloading_articles.md). Call this for any year with fewer than 100
# articles downloaded; it resamples replacement DOIs for that year only.

resample_year <- function(yr) {
  sampled <- read.csv(SAMPLE_CSV, colClasses = "character")
  sampled$year <- as.integer(sampled$year)
  have <- list.files(PDF_DIR, pattern = "\\.pdf$")
  have_ids <- sub("\\.pdf$", "", sub("^frontiers\\.", "", have))
  n_have_this_year <- sum(sampled$year == yr & sampled$article_id %in% have_ids)
  n_needed <- N_PER_YEAR - n_have_this_year
  if (n_needed <= 0) { message("Year ", yr, " already at target"); return(invisible(NULL)) }

  items <- fetch_year(yr)
  items_to_row <- function(it) data.frame(doi = it$DOI %||% NA_character_, title = (it$title[[1]] %||% NA_character_), year = yr, stringsAsFactors = FALSE)
  pool <- do.call(rbind, lapply(items, items_to_row))
  pool <- pool[!is.na(pool$doi) & !(pool$doi %in% sampled$doi), ]
  pool <- pool[!is_nonarticle(pool$title), ]
  pool$article_id <- gsub("[^A-Za-z0-9]", "", sub("^10\\.3389/", "", pool$doi))
  pool <- pool[sample.int(nrow(pool)), ]

  n_found <- 0
  for (i in seq_len(nrow(pool))) {
    if (n_found >= n_needed) break
    if (download_one(pool$doi[i], pool$article_id[i])) {
      new_row <- data.frame(doi = pool$doi[i], title = pool$title[i], year = yr, article_id = pool$article_id[i])
      new_row <- new_row[, colnames(sampled)[colnames(sampled) %in% colnames(new_row)]]
      for (col in setdiff(colnames(sampled), colnames(new_row))) new_row[[col]] <- NA
      sampled <- rbind(sampled, new_row[, colnames(sampled)])
      n_found <- n_found + 1
    }
    Sys.sleep(1)
  }
  write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
  message("Year ", yr, ": found ", n_found, "/", n_needed, " replacements")
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
  sampled <- read.csv(SAMPLE_CSV, colClasses = "character")

  fnames <- sapply(papers, function(p) basename(p$info$file_name))
  ids    <- sub("^frontiers\\.", "", fnames) |> sub("\\.xml$", "", x = _)

  sample_doi   <- setNames(sampled$doi, sampled$article_id)
  sample_title <- setNames(sampled$title, sampled$article_id)

  for (i in seq_along(papers)) {
    expected_doi <- sample_doi[[ids[i]]]
    actual_doi   <- papers[[i]]$info$doi
    if (is.null(actual_doi) || !nzchar(actual_doi) || !identical(tolower(actual_doi), tolower(expected_doi %||% ""))) {
      papers[[i]]$info$doi <- expected_doi
    }
    if (!nzchar(papers[[i]]$info$title %||% "")) {
      papers[[i]]$info$title <- sample_title[[ids[i]]]
    }
  }
  saveRDS(papers, RDS_OUT)

  m <- sampled[sampled$article_id %in% ids, ]
  m <- m[!duplicated(m$article_id), ]
  manifest <- data.frame(
    doi = m$doi, article_id = m$article_id, title = m$title, year = m$year,
    pdf_file = paste0("pdf/frontiers.", m$article_id, ".pdf"),
    xml_file = paste0("xml/frontiers.", m$article_id, ".xml"),
    pdf_exists = file.exists(file.path(PDF_DIR, paste0("frontiers.", m$article_id, ".pdf"))),
    xml_exists = file.exists(file.path(XML_DIR, paste0("frontiers.", m$article_id, ".xml"))),
    in_rds = TRUE, grobid_version = "0.9", conversion_date = format(Sys.Date(), "%Y-%m-%d")
  )
  write.csv(manifest, MANIFEST, row.names = FALSE)
  message("Build complete: ", length(papers), " papers in ", RDS_OUT)
}

# == Run ========================================================================
# phase1_download()
# resample_year(<year>)        # call once per under-quota year, repeat until 100/100
# phase3_convert()
# phase4_cleanup()