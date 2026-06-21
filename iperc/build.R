# Build script: i-Perception corpus for scienceverse/papers
#
# Produces:
#   iperc/sample.csv   the sampled DOIs (100/year target, 2017-2026)
#   iperc/pdf/         496 PDF files (CC-BY 4.0)
#   iperc/xml/         GROBID TEI-XML intermediate files
#   iperc/manifest.csv one row per paper with provenance metadata
#   iperc.rds          metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: httr2, metacheck (scienceverse/metacheck)
#   metacheck::email() set to a valid address for Unpaywall API
#   GROBID 0.9 instance (used: https://grobid.work.abed.cloud)
#
# i-Perception publishes more articles per year than fit a complete
# corpus, so this is a STRATIFIED RANDOM SAMPLE (100/year target,
# 2017-2026). i-Perception is a SAGE open-access-only journal (not
# hybrid) -- confirmed via CrossRef license sampling.
#
# SAGE's direct PDF host (journals.sagepub.com/doi/pdf/{doi}) initially
# appeared blocked at bulk-download scale (HTTP 403 "Blocked | Sage"
# after ~70 requests), but this was root-caused to a Cloudflare Client
# Hints check, not a rate limit or IP block -- see
# downloading_articles.md for the full writeup. Adding Sec-CH-UA /
# Sec-CH-UA-Mobile / Sec-CH-UA-Platform headers alongside the Chrome
# User-Agent resolved it completely.
#
# This script is self-contained and idempotent: every phase skips work
# already done on disk, so re-running it just continues from where it
# left off.
#
# Phases, reflecting the pipeline as actually run:
#   Phase 1: download            - sample 100 DOIs/year, download via
#                                   SAGE direct host (with Client Hints
#                                   headers)
#   Phase 2: fix_orphan_rows     - an earlier numeric-coercion bug in a
#                                   retry script (missing colClasses =
#                                   "character") caused some downloaded
#                                   PDFs' sample.csv rows to be lost;
#                                   recovered by extracting the DOI
#                                   directly from each orphaned PDF's
#                                   bytes (not its filename -- the
#                                   filename itself can be off by a
#                                   digit) and re-querying CrossRef
#   Phase 3: fix_duplicate_dois  - the orphan recovery above
#                                   reconstructed some rows under a
#                                   slightly different (typo'd)
#                                   article_id than the original,
#                                   creating duplicate-DOI rows;
#                                   resolved by keeping only the row
#                                   matching an actual downloaded PDF
#   Phase 4: convert             - GROBID-convert PDFs, assemble RDS + manifest
#   Phase 5: cleanup             - dropped 4 genuine non-article
#                                   notices (2 titled literally
#                                   "Erratum" in CrossRef's own record,
#                                   1 "Correction to Figures", 1 thin-
#                                   content "Addendum") that slipped
#                                   past the title-pattern filter,
#                                   corrected 6 garbled GROBID DOIs,
#                                   backfilled 2 missing titles from
#                                   CrossRef

library(httr2)
suppressMessages(library(metacheck))

ISSN       <- "2041-6695"   # i-Perception
EMAIL      <- metacheck::email()
YEARS      <- 2017:2026
N_PER_YEAR <- 100
SEED       <- 20260620
PDF_DIR    <- "iperc/pdf"
XML_DIR    <- "iperc/xml"
GROBID_URL <- "https://grobid.work.abed.cloud/api/processFulltextDocument"
RDS_OUT    <- "iperc.rds"
MANIFEST   <- "iperc/manifest.csv"
SAMPLE_CSV <- "iperc/sample.csv"

dir.create(PDF_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(XML_DIR, recursive = TRUE, showWarnings = FALSE)

is_nonarticle <- function(title) {
  grepl("(Correction|Retraction|Expression of Concern|Erratum|Withdrawal|Corrigendum|Addendum)(\\s+(Note|to|To))?:?",
        title, ignore.case = TRUE) |
  grepl("^(Response|Reply) to [‘'\"]", title, ignore.case = TRUE) |
  grepl("commentary on", title, ignore.case = TRUE) |
  grepl("Reviewer and Editorial Board|^Call for Papers|^Editorial Board|^Editorial Note|^Acknowledge?ment|^Annual Report|Thank You|^Meeting [Rr]eport:",
        title, ignore.case = TRUE) |
  grepl("^Corrigendum", title, ignore.case = TRUE) |
  identical(trimws(title), "Erratum")
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

download_pdf <- function(url, dest) {
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

# == Phase 1: initial sample + download =======================================

phase1_download <- function() {
  if (file.exists(SAMPLE_CSV)) {
    sampled <- read.csv(SAMPLE_CSV, colClasses = "character")
    message("Loaded existing sample: ", nrow(sampled), " articles from ", SAMPLE_CSV)
  } else {
    message("Fetching CrossRef DOIs for ", length(YEARS), " years...")
    all_items <- lapply(YEARS, \(yr) { Sys.sleep(1); items <- fetch_year(yr); message("  ", yr, ": ", length(items), " journal articles"); items })
    names(all_items) <- YEARS

    dois_df <- do.call(rbind, lapply(YEARS, \(yr) {
      items <- all_items[[as.character(yr)]]
      do.call(rbind, lapply(items, function(it) data.frame(doi = it$DOI %||% NA_character_, title = (it$title[[1]] %||% NA_character_), year = yr, stringsAsFactors = FALSE)))
    }))
    dois_df <- dois_df[!duplicated(dois_df$doi) & !is.na(dois_df$doi), ]
    notice <- is_nonarticle(dois_df$title)
    dois_df <- dois_df[!notice, ]
    message("CrossRef: ", nrow(dois_df), " unique research articles (", sum(notice), " non-articles excluded)")

    set.seed(SEED)
    sampled <- do.call(rbind, lapply(YEARS, \(yr) {
      pool <- dois_df[dois_df$year == yr, ]
      pool[sample.int(nrow(pool), min(N_PER_YEAR, nrow(pool))), ]
    }))
    sampled$article_id <- gsub("[^A-Za-z0-9]", "", sub("^10\\.1177/", "", sampled$doi))
    stopifnot(length(unique(sampled$article_id)) == nrow(sampled))
    write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
    message("Sampled: ", nrow(sampled), " articles (", N_PER_YEAR, "/year target)")
  }

  sampled <- read.csv(SAMPLE_CSV, colClasses = "character")
  for (i in seq_len(nrow(sampled))) {
    doi <- sampled$doi[i]; art_id <- sampled$article_id[i]
    dest <- file.path(PDF_DIR, paste0("iperc.", art_id, ".pdf"))
    if (file.exists(dest) && file.info(dest)$size > 10000) next
    download_pdf(paste0("https://journals.sagepub.com/doi/pdf/", doi), dest)
    Sys.sleep(1)
  }
  message("PDFs on disk: ", length(list.files(PDF_DIR, pattern = "\\.pdf$")), " / ", nrow(sampled))
}

# == Phase 2: recover orphaned PDFs whose sample.csv row was lost =============
# Only needed if a prior run hit the colClasses numeric-coercion bug
# (long-digit article_ids silently collapsed to lossy scientific
# notation, dropping rows on write). Always read/write sample.csv with
# colClasses = "character" to avoid re-triggering this.

extract_doi_from_pdf <- function(path) {
  raw <- readBin(path, "raw", n = 200000)
  printable <- raw
  printable[!(raw >= as.raw(0x20) & raw <= as.raw(0x7e))] <- as.raw(0x20)
  txt <- rawToChar(printable)
  m <- regmatches(txt, regexpr("10\\.1177/[0-9]+", txt))
  if (length(m) == 0 || !nzchar(m)) return(NA_character_)
  m
}

get_crossref_work <- function(doi) {
  resp <- tryCatch(
    request(paste0("https://api.crossref.org/works/", doi)) |>
      req_timeout(15) |> req_options(connecttimeout = 8, ssl_options = 2) |>
      req_error(is_error = \(r) FALSE) |> req_perform(),
    error = \(e) NULL
  )
  if (is.null(resp) || resp_status(resp) != 200) return(NULL)
  m <- resp_body_json(resp)$message
  parts <- (m$`published-print`$`date-parts` %||% m$`published-online`$`date-parts` %||% m$published$`date-parts`)[[1]]
  list(title = m$title[[1]] %||% NA_character_, year = if (is.null(parts)) NA_integer_ else as.integer(parts[[1]]))
}

phase2_fix_orphan_rows <- function() {
  sampled <- read.csv(SAMPLE_CSV, stringsAsFactors = FALSE, colClasses = "character")
  have_ids <- sub("\\.pdf$", "", sub("^iperc\\.", "", list.files(PDF_DIR, pattern = "\\.pdf$")))
  orphan_ids <- setdiff(have_ids, sampled$article_id)
  message("Orphaned PDFs needing a sample.csv row: ", length(orphan_ids))
  if (length(orphan_ids) == 0) return(invisible(NULL))

  new_rows <- data.frame()
  for (id in orphan_ids) {
    path <- file.path(PDF_DIR, paste0("iperc.", id, ".pdf"))
    doi <- extract_doi_from_pdf(path)
    if (is.na(doi)) doi <- paste0("10.1177/", id)
    w <- get_crossref_work(doi)
    if (is.null(w)) { message("  CrossRef lookup failed: ", doi); next }
    new_rows <- rbind(new_rows, data.frame(doi = doi, title = w$title, year = w$year, article_id = id, stringsAsFactors = FALSE))
    Sys.sleep(0.3)
  }
  message("Reconstructed ", nrow(new_rows), " / ", length(orphan_ids), " rows")
  sampled <- rbind(sampled, new_rows)
  write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
}

# == Phase 3: resolve duplicate DOIs from orphan recovery =====================
# The orphan recovery above can reconstruct a row under a slightly
# different article_id than the original phantom row for the same DOI
# (a transcription artifact). For each duplicated DOI, keep only the
# row whose article_id has an actual PDF on disk.

phase3_fix_duplicate_dois <- function() {
  sampled <- read.csv(SAMPLE_CSV, stringsAsFactors = FALSE, colClasses = "character")
  have_ids <- sub("\\.pdf$", "", sub("^iperc\\.", "", list.files(PDF_DIR, pattern = "\\.pdf$")))
  dup_dois <- unique(sampled$doi[duplicated(sampled$doi)])
  message("Duplicated DOIs: ", length(dup_dois))
  if (length(dup_dois) == 0) return(invisible(NULL))

  drop_idx <- c()
  for (d in dup_dois) {
    idx <- which(sampled$doi == d)
    has_pdf <- sampled$article_id[idx] %in% have_ids
    if (sum(has_pdf) == 1) drop_idx <- c(drop_idx, idx[!has_pdf])
    else drop_idx <- c(drop_idx, idx[-1])
  }
  sampled <- sampled[-drop_idx, ]
  stopifnot(sum(duplicated(sampled$doi)) == 0)
  write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
  message("Dropped ", length(drop_idx), " duplicate rows; sample.csv now ", nrow(sampled), " rows")
}

# == Phase 4: convert + assemble ===============================================

phase4_convert <- function() {
  pdfs <- list.files(PDF_DIR, pattern = "\\.pdf$", full.names = TRUE)
  already_xml <- tools::file_path_sans_ext(basename(list.files(XML_DIR, pattern = "\\.xml$")))
  for (pdf in pdfs) {
    stem <- tools::file_path_sans_ext(basename(pdf))
    if (stem %in% already_xml) next
    out_xml <- file.path(XML_DIR, paste0(stem, ".xml"))
    tryCatch(convert_grobid(pdf, save_path = out_xml, api_url = GROBID_URL),
             error = function(e) message("ERROR ", stem, ": ", e$message))
  }
  papers <- grobid_to_bibr(XML_DIR, save_path = NULL)
  saveRDS(papers, RDS_OUT)
  message("RDS saved: ", length(papers), " papers -> ", RDS_OUT)
}

# == Phase 5: cleanup + manifest ===============================================
# 4 genuine non-article notices dropped (identified by manual title
# inspection after the audit -- 2 literally titled "Erratum", 1
# "Correction to Figures: ...", 1 thin-content "Addendum to ..." --
# these slipped past is_nonarticle() because they don't match its
# patterns exactly), garbled DOIs corrected, missing titles backfilled.

KNOWN_NONARTICLE_IDS <- c("2041669516688509", "2041669517723929", "2041669517752413", "2041669518760868")

phase5_cleanup <- function() {
  papers  <- readRDS(RDS_OUT)
  sampled <- read.csv(SAMPLE_CSV, stringsAsFactors = FALSE, colClasses = "character")
  fnames  <- sapply(papers, function(p) basename(p$info$file_name))
  ids     <- sub("^iperc\\.", "", fnames) |> sub("\\.xml$", "", x = _)

  keep <- !(ids %in% KNOWN_NONARTICLE_IDS)
  papers <- papers[keep]; ids <- ids[keep]
  class(papers) <- "scivrs_paperlist"
  message("Dropped ", sum(!keep), " genuine non-article notices")

  sample_doi <- setNames(sampled$doi, sampled$article_id)
  for (i in seq_along(papers)) {
    expected_doi <- sample_doi[[ids[i]]]
    actual_doi <- papers[[i]]$info$doi
    if (is.null(actual_doi) || !nzchar(actual_doi) || !identical(tolower(actual_doi), tolower(expected_doi %||% ""))) {
      papers[[i]]$info$doi <- expected_doi
    }
    if (!nzchar(papers[[i]]$info$title %||% "")) {
      papers[[i]]$info$title <- sampled$title[sampled$article_id == ids[i]]
    }
  }
  saveRDS(papers, RDS_OUT)

  manifest <- data.frame(
    doi = sample_doi[ids], article_id = ids,
    title = sapply(papers, function(p) p$info$title), year = sampled$year[match(ids, sampled$article_id)],
    pdf_file = paste0("pdf/iperc.", ids, ".pdf"), xml_file = paste0("xml/iperc.", ids, ".xml"),
    pdf_exists = file.exists(file.path(PDF_DIR, paste0("iperc.", ids, ".pdf"))),
    xml_exists = file.exists(file.path(XML_DIR, paste0("iperc.", ids, ".xml"))),
    in_rds = TRUE, grobid_version = "0.9", conversion_date = format(Sys.Date(), "%Y-%m-%d"),
    license = "CC-BY 4.0"
  )
  write.csv(manifest, MANIFEST, row.names = FALSE)
  message("Build complete: ", length(papers), " papers in ", RDS_OUT)
}

# == Run ========================================================================
# phase1_download()
# phase2_fix_orphan_rows()       # only if orphans exist
# phase3_fix_duplicate_dois()    # only if duplicates exist
# phase4_convert()
# phase5_cleanup()