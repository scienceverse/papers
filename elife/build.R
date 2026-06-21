# Build script: eLife corpus for scienceverse/papers
#
# Produces:
#   elife/sample.csv   the sampled DOIs (100/year target, 2017-2026)
#   elife/pdf/         1000 PDF files (CC-BY 4.0)
#   elife/xml/         GROBID TEI-XML intermediate files
#   elife/manifest.csv one row per paper with provenance metadata
#   elife.rds          metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: httr2, metacheck (scienceverse/metacheck)
#   metacheck::email() set to a valid address for Unpaywall API
#   GROBID 0.9 instance (used: https://grobid.work.abed.cloud)
#
# eLife has roughly 22,400 articles in total, far too many for a
# complete corpus, so this is a STRATIFIED RANDOM SAMPLE (100/year
# target, 2017-2026). eLife is a fully open-access publisher (CC-BY
# 4.0 confirmed via CrossRef license sampling).
#
# This script is fully self-contained and idempotent: every phase
# skips work already done on disk, so re-running it after a partial
# failure (or to pick up newly-resampled replacements) just continues
# from where it left off. Run phases in order; each phase function is
# called once at the bottom of the file.
#
# Phases, reflecting the pipeline as actually run:
#   Phase 1: download   - samples 100 DOIs/year, downloads via
#                         Unpaywall -> Europe PMC route.
#   Phase 2: retry      - the Unpaywall/Europe PMC route alone only
#                         reached ~608/1000 on the first pass (the
#                         intermittent API-failure pattern documented
#                         in downloading_articles.md, compounded by
#                         genuinely sparser Europe PMC deposit coverage
#                         for recent years). Adds an elifesciences.org
#                         landing-page scrape fallback (extracts the
#                         signed direct-download PDF link from the
#                         article page's HTML) for DOIs Europe PMC had
#                         no deposit for. The scrape fallback needed
#                         three fixes before it was reliable: (a) strip
#                         a trailing DOI version suffix (eLife's
#                         "Reviewed Preprint" scheme, e.g. ".3") before
#                         constructing the landing-page URL -- left
#                         unstripped, this 404s; (b) anchor the PDF
#                         filename pattern to "elife-<num>-v<n>.pdf"
#                         exactly, since the page also links a combined
#                         figures PDF and per-figure source-data PDFs
#                         that an unanchored pattern could match
#                         instead; (c) pass perl = TRUE to regexpr(),
#                         since R's default regex engine occasionally
#                         mis-located the match start by one byte on
#                         some UTF-8 pages, truncating the URL's
#                         scheme. Re-running this phase repeatedly
#                         closes the gap to 1000/1000 (each pass
#                         recovers a smaller remainder -- this is the
#                         documented intermittent-failure pattern, not
#                         a bug, once the above fixes are in place).
#   Phase 3: convert    - GROBID-converts all PDFs (some "Payload Too
#                         Large" exclusions are expected; resample
#                         phase 1+2 for the same year if so), assembles
#                         RDS + manifest.
#   Phase 4: cleanup    - corrects garbled/missing/version-suffix-only
#                         DOIs from the verified CrossRef sample DOI,
#                         backfills missing titles (eLife's short
#                         "Insight" commentary pieces often have no
#                         GROBID-extracted title). When resampling a
#                         replacement for an excluded slot, deduplicate
#                         by DOI with the version suffix stripped --
#                         eLife registers some "Reviewed Preprint"
#                         revisions under a separate DOI
#                         (10.7554/eLife.92805 vs 10.7554/eLife.92805.3
#                         are the SAME article), and a raw-string DOI
#                         comparison will miss this.

library(httr2)
suppressMessages(library(metacheck))

ISSN       <- "2050-084X"   # eLife
EMAIL      <- metacheck::email()
YEARS      <- 2017:2026
N_PER_YEAR <- 100
SEED       <- 20260620
PDF_DIR    <- "elife/pdf"
XML_DIR    <- "elife/xml"
SAMPLE_CSV <- "elife/sample.csv"
MANIFEST   <- "elife/manifest.csv"
RDS_OUT    <- "elife.rds"
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
  grepl("^Author Correction:|^Publisher Correction:|^Editor's evaluation|^eLife digest", title, ignore.case = TRUE)
}

# DOI -> bare article number, with any trailing "Reviewed Preprint"
# version suffix stripped (10.7554/eLife.88799.3 -> 88799). Needed both
# for URL construction and for duplicate detection across DOI variants
# of the same article.
normalize_article_num <- function(doi) {
  n <- sub("^10\\.7554/eLife\\.", "", doi, ignore.case = TRUE)
  sub("\\.[0-9]+$", "", n)
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

download_pdf <- function(url, dest, referer = NULL) {
  headers <- c(`User-Agent` = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
  if (!is.null(referer)) headers <- c(headers, Referer = referer)
  ok <- tryCatch(
    request(url) |>
      req_headers(!!!headers) |>
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

# Fallback: elifesciences.org landing page embeds a working direct
# download link as href="https://elifesciences.org/download/<base64
# path>/elife-<id>-v<n>.pdf?_hash=...". Extract it directly from the
# landing page HTML. See Phase 2 notes above for the three fixes baked
# into this function (version-suffix stripping, anchored filename
# pattern, perl = TRUE).
get_elife_direct_pdf_url <- function(doi) {
  article_num <- normalize_article_num(doi)
  landing_url <- paste0("https://elifesciences.org/articles/", article_num)
  resp <- tryCatch(
    request(landing_url) |>
      req_headers(`User-Agent` = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36") |>
      req_timeout(20) |> req_options(connecttimeout = 10, ssl_options = 2) |>
      req_error(is_error = \(r) FALSE) |> req_perform(),
    error = \(e) NULL
  )
  if (is.null(resp) || resp_status(resp) != 200) return(NULL)
  html <- resp_body_string(resp)
  m <- regmatches(html, regexpr('https://elifesciences\\.org/download/[A-Za-z0-9_-]+/elife-[0-9]+-v[0-9]+\\.pdf\\?_hash=([A-Za-z0-9_-]|%[0-9A-Fa-f]{2})+', html, perl = TRUE))
  if (length(m) == 0 || !nzchar(m)) return(NULL)
  list(url = m, referer = landing_url)
}

download_one <- function(doi, art_id) {
  dest <- file.path(PDF_DIR, paste0("elife.", art_id, ".pdf"))
  if (file.exists(dest) && file.info(dest)$size > 10000) return(TRUE)
  ok <- FALSE
  oa <- check_oa(doi)
  if (isTRUE(oa$is_oa)) {
    pmcid <- get_pmcid(doi)
    if (!is.null(pmcid)) ok <- download_pdf(paste0("https://europepmc.org/articles/", pmcid, "?pdf=render"), dest)
  }
  if (!ok) {
    direct <- get_elife_direct_pdf_url(doi)
    if (!is.null(direct)) ok <- download_pdf(direct$url, dest, referer = direct$referer)
  }
  if (!ok) unlink(dest)
  ok
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

    items_to_row <- function(it, yr) {
      data.frame(doi = it$DOI %||% NA_character_, title = (it$title[[1]] %||% NA_character_), year = yr, stringsAsFactors = FALSE)
    }
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
    sampled$article_id <- paste0("elife", gsub("[^0-9]", "", normalize_article_num(sampled$doi)))
    stopifnot(length(unique(sampled$article_id)) == nrow(sampled))
    write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
    message("Sampled: ", nrow(sampled), " articles (", N_PER_YEAR, "/year target)")
  }

  sampled <- read.csv(SAMPLE_CSV, colClasses = "character")
  for (i in seq_len(nrow(sampled))) {
    download_one(sampled$doi[i], sampled$article_id[i])
    Sys.sleep(1)
  }
  message("PDFs on disk: ", length(list.files(PDF_DIR, pattern = "\\.pdf$")), " / ", nrow(sampled))
}

# == Phase 2: retry missing (idempotent -- safe to call repeatedly) ===========

phase2_retry_missing <- function() {
  sampled <- read.csv(SAMPLE_CSV, colClasses = "character")
  pdf_ids <- sub("^elife\\.", "", list.files(PDF_DIR, pattern = "\\.pdf$"))
  pdf_ids <- sub("\\.pdf$", "", pdf_ids)
  missing <- sampled[!(sampled$article_id %in% pdf_ids), ]
  message("Missing PDFs: ", nrow(missing), " / ", nrow(sampled))
  n_ok <- n_fail <- 0
  for (i in seq_len(nrow(missing))) {
    ok <- download_one(missing$doi[i], missing$article_id[i])
    if (ok) n_ok <- n_ok + 1 else n_fail <- n_fail + 1
    Sys.sleep(1)
  }
  message("Retry complete: downloaded=", n_ok, " failed=", n_fail)
}

# == Phase 2b: resample a replacement for an excluded slot ====================
# Call this once per excluded article_id (e.g. after Phase 3 reports a
# "Payload Too Large" GROBID error) to find a same-year replacement.

resample_replacement <- function(excluded_article_id, yr) {
  sampled <- read.csv(SAMPLE_CSV, colClasses = "character")
  sampled <- sampled[sampled$article_id != excluded_article_id, ]
  unlink(file.path(PDF_DIR, paste0("elife.", excluded_article_id, ".pdf")))

  existing_nums <- normalize_article_num(sampled$doi)
  items <- fetch_year(yr)
  items_to_row <- function(it) data.frame(doi = it$DOI %||% NA_character_, title = (it$title[[1]] %||% NA_character_), year = yr, stringsAsFactors = FALSE)
  pool <- do.call(rbind, lapply(items, items_to_row))
  pool <- pool[!is.na(pool$doi), ]
  pool$article_num <- normalize_article_num(pool$doi)
  pool <- pool[!(pool$article_num %in% existing_nums), ]   # DOI-version-normalized dedup
  pool <- pool[!is_nonarticle(pool$title), ]
  pool$article_id <- paste0("elife", gsub("[^0-9]", "", pool$article_num))
  pool <- pool[sample.int(nrow(pool)), ]

  for (i in seq_len(nrow(pool))) {
    if (download_one(pool$doi[i], pool$article_id[i])) {
      dest <- file.path(PDF_DIR, paste0("elife.", pool$article_id[i], ".pdf"))
      if (file.info(dest)$size >= 40000000) { unlink(dest); next }   # avoid resampling into another oversized PDF
      new_row <- data.frame(doi = pool$doi[i], title = pool$title[i], year = yr, article_id = pool$article_id[i],
                             is_oa = TRUE, license = NA_character_)
      new_row <- new_row[, colnames(sampled)]
      sampled <- rbind(sampled, new_row)
      write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
      message("Found replacement for ", excluded_article_id, ": ", pool$doi[i], " -> ", pool$article_id[i])
      return(invisible(TRUE))
    }
    Sys.sleep(1)
  }
  stop("No replacement found for ", excluded_article_id, " (year ", yr, ")")
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
  message("Conversion: ", n_done, " converted, ", n_skip, " skipped, ", n_err, " errors (likely oversized -- use resample_replacement())")

  papers <- grobid_to_bibr(XML_DIR, save_path = NULL)
  saveRDS(papers, RDS_OUT)
  message("RDS saved: ", length(papers), " papers -> ", RDS_OUT)
}

# == Phase 4: cleanup + manifest ===============================================

phase4_cleanup <- function() {
  papers  <- readRDS(RDS_OUT)
  sampled <- read.csv(SAMPLE_CSV, colClasses = "character")

  fnames <- sapply(papers, function(p) basename(p$info$file_name))
  ids    <- sub("^elife\\.", "", fnames) |> sub("\\.xml$", "", x = _)

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
    pdf_file = paste0("pdf/elife.", m$article_id, ".pdf"),
    xml_file = paste0("xml/elife.", m$article_id, ".xml"),
    pdf_exists = file.exists(file.path(PDF_DIR, paste0("elife.", m$article_id, ".pdf"))),
    xml_exists = file.exists(file.path(XML_DIR, paste0("elife.", m$article_id, ".xml"))),
    in_rds = TRUE, grobid_version = "0.9", conversion_date = format(Sys.Date(), "%Y-%m-%d")
  )
  write.csv(manifest, MANIFEST, row.names = FALSE)
  message("Build complete: ", length(papers), " papers in ", RDS_OUT)
}

# == Run ========================================================================
# phase1_download()
# phase2_retry_missing()       # call repeatedly until PDFs on disk == 1000
# resample_replacement("elife<id>", <year>)   # call once per GROBID exclusion
# phase3_convert()
# phase4_cleanup()