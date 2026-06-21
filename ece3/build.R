# Build script: Ecology and Evolution corpus for scienceverse/papers
#
# Produces:
#   ece3/sample.csv   the sampled DOIs (100/year target, 2011-2026)
#   ece3/pdf/         PDF files (CC-BY 4.0, fully open access journal)
#   ece3/xml/         GROBID TEI-XML intermediate files
#   ece3/manifest.csv one row per paper with provenance metadata
#   ece3.rds          metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: httr2, metacheck (scienceverse/metacheck)
#   metacheck::email() set to a valid address for Unpaywall API
#   GROBID 0.9 instance (used: https://grobid.work.abed.cloud)
#
# Ecology and Evolution (Wiley, fully OA, ISSN 2045-7758) publishes far
# more articles per year than fit a complete corpus (~15,700 total,
# 2011-2026), so this is a STRATIFIED RANDOM SAMPLE (100/year target).
#
# Wiley's own PDF host (onlinelibrary.wiley.com) is effectively blocked
# by active, adaptive Cloudflare bot protection -- see
# downloading_articles.md's "Publisher access: a spectrum" section.
# Do not attempt direct Wiley downloads. Every sampled DOI tested
# (12/12 across 2012-2023) had a Europe PMC deposit with hasPDF: Y, so
# this corpus is downloaded entirely via Europe PMC instead -- unlike
# most Europe PMC fallback usage elsewhere in this repo (typically
# partial coverage for a hybrid journal), this journal's deposit
# coverage is consistently complete because every EE article is OA and
# Wiley deposits all of them.
#
# This script is self-contained and idempotent: every phase skips work
# already done on disk, so re-running it just continues from where it
# left off.
#
# Phases:
#   Phase 1: download  - sample 100 DOIs/year, verify OA via Unpaywall,
#                         download via Europe PMC
#   Phase 2: replace    - resample same-year replacements for any
#                         download failures or oversized/non-article
#                         exclusions found later
#   Phase 3: convert    - GROBID-convert PDFs, assemble RDS + manifest
#   Phase 4: cleanup     - overwrite GROBID-extracted DOI with the known
#                         CrossRef DOI, backfill missing titles

library(httr2)
suppressMessages(library(metacheck))

ISSN       <- "2045-7758"   # Ecology and Evolution
EMAIL      <- metacheck::email()
YEARS      <- 2011:2026
N_PER_YEAR <- 100
SEED       <- 20260621
PDF_DIR    <- "ece3/pdf"
XML_DIR    <- "ece3/xml"
GROBID_URL <- "https://grobid.work.abed.cloud/api/processFulltextDocument"
RDS_OUT    <- "ece3.rds"
MANIFEST   <- "ece3/manifest.csv"
SAMPLE_CSV <- "ece3/sample.csv"

dir.create(PDF_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(XML_DIR, recursive = TRUE, showWarnings = FALSE)

is_nonarticle <- function(title) {
  grepl("(Correction|Retraction|Expression of Concern|Erratum|Withdrawal|Corrigendum|Addendum|Publisher.s Note)(\\s+(Note|to|To))?:?",
        title, ignore.case = TRUE) |
  grepl("^(Response|Reply) to [‘'\"]", title, ignore.case = TRUE) |
  grepl("commentary on", title, ignore.case = TRUE) |
  grepl("Reviewer and Editorial Board|^Call for Papers|^Editorial Board|^Editorial Note|^Acknowledge?ment|^Annual Report|Thank You|^Meeting [Rr]eport:",
        title, ignore.case = TRUE) |
  grepl("^Author Correction:|^Publisher Correction:", title, ignore.case = TRUE) |
  grepl("^In [Mm]emoriam", title, ignore.case = TRUE)
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

check_oa <- function(doi) {
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

get_pmcid <- function(doi) {
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

download_pdf <- function(url, dest, max_size = 18 * 1024 * 1024) {
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
  if (ok && !is.null(max_size) && file.info(dest)$size > max_size) ok <- FALSE
  if (!ok) unlink(dest)
  ok
}

download_one <- function(doi, art_id, max_size = NULL) {
  dest <- file.path(PDF_DIR, paste0("ece3.", art_id, ".pdf"))
  if (file.exists(dest) && file.info(dest)$size > 10000) return(list(ok = TRUE, is_oa = NA, license = NA_character_))
  oa <- check_oa(doi)
  if (!isTRUE(oa$is_oa)) return(list(ok = FALSE, is_oa = oa$is_oa, license = oa$license))
  pmcid <- get_pmcid(doi)
  if (is.null(pmcid)) return(list(ok = FALSE, is_oa = oa$is_oa, license = oa$license))
  ok <- download_pdf(paste0("https://europepmc.org/articles/", pmcid, "?pdf=render"), dest, max_size = max_size)
  list(ok = ok, is_oa = oa$is_oa, license = oa$license)
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
    sampled$article_id <- gsub("[^A-Za-z0-9]", "", sub("^10\\.1002/", "", sampled$doi))
    stopifnot(length(unique(sampled$article_id)) == nrow(sampled))
    sampled$is_oa <- NA
    sampled$license <- NA_character_
    write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
    message("Sampled: ", nrow(sampled), " articles (", N_PER_YEAR, "/year target)")
  }

  sampled <- read.csv(SAMPLE_CSV, colClasses = "character")
  for (i in seq_len(nrow(sampled))) {
    r <- download_one(sampled$doi[i], sampled$article_id[i])
    sampled$is_oa[i] <- r$is_oa
    sampled$license[i] <- r$license
    Sys.sleep(1)
  }
  write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
  message("PDFs on disk: ", length(list.files(PDF_DIR, pattern = "\\.pdf$")), " / ", nrow(sampled))
}

# == Phase 2: replace specific article_ids (download failures, oversized   ===
# == PDFs, or audit-found non-articles) with same-year resamples ===========
# Pass the article_ids to replace and the years they belong to (named
# vector: names = article_id, values = year).

replace_articles <- function(bad_ids_by_year, max_size = 18 * 1024 * 1024) {
  sampled <- read.csv(SAMPLE_CSV, colClasses = "character")
  sampled <- sampled[!(sampled$article_id %in% names(bad_ids_by_year)), ]
  for (id in names(bad_ids_by_year)) unlink(file.path(PDF_DIR, paste0("ece3.", id, ".pdf")))

  n_found <- 0
  for (yr in sort(unique(bad_ids_by_year))) {
    n_needed <- sum(bad_ids_by_year == yr)
    items <- fetch_year(yr)
    pool <- do.call(rbind, lapply(items, function(it) data.frame(doi = it$DOI %||% NA_character_, title = (it$title[[1]] %||% NA_character_), year = yr, stringsAsFactors = FALSE)))
    pool <- pool[!duplicated(pool$doi) & !is.na(pool$doi), ]
    pool <- pool[!is_nonarticle(pool$title), ]
    pool <- pool[!(pool$doi %in% sampled$doi), ]
    pool$article_id <- gsub("[^A-Za-z0-9]", "", sub("^10\\.1002/", "", pool$doi))
    set.seed(SEED + yr)
    pool <- pool[sample.int(nrow(pool)), ]

    found_this_year <- 0
    for (i in seq_len(nrow(pool))) {
      if (found_this_year >= n_needed) break
      r <- download_one(pool$doi[i], pool$article_id[i], max_size = max_size)
      if (r$ok) {
        new_row <- data.frame(doi = pool$doi[i], title = pool$title[i], year = yr, article_id = pool$article_id[i], is_oa = TRUE, license = r$license)
        sampled <- rbind(sampled, new_row[, colnames(sampled)])
        found_this_year <- found_this_year + 1
        n_found <- n_found + 1
      }
      Sys.sleep(1)
    }
    message("Year ", yr, ": found ", found_this_year, "/", n_needed, " replacements")
  }
  write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
  message("Total replacements found: ", n_found, "/", length(bad_ids_by_year))
}

# == Phase 3: convert + assemble ===============================================

phase3_convert <- function() {
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

# == Phase 4: cleanup + manifest ===============================================

phase4_cleanup <- function() {
  papers  <- readRDS(RDS_OUT)
  sampled <- read.csv(SAMPLE_CSV, colClasses = "character")
  fnames  <- sapply(papers, function(p) basename(p$info$file_name))
  ids     <- sub("^ece3\\.", "", fnames) |> sub("\\.xml$", "", x = _)

  sample_doi <- setNames(sampled$doi, sampled$article_id)
  n_doi_fixed <- n_title_fixed <- 0
  for (i in seq_along(papers)) {
    expected_doi <- sample_doi[[ids[i]]]
    actual_doi <- papers[[i]]$info$doi
    if (is.null(actual_doi) || !nzchar(actual_doi) || !identical(tolower(actual_doi), tolower(expected_doi %||% ""))) {
      papers[[i]]$info$doi <- expected_doi
      n_doi_fixed <- n_doi_fixed + 1
    }
    if (!nzchar(papers[[i]]$info$title %||% "")) {
      papers[[i]]$info$title <- sampled$title[sampled$article_id == ids[i]]
      n_title_fixed <- n_title_fixed + 1
    }
  }
  message("Corrected DOI for ", n_doi_fixed, " papers; backfilled title for ", n_title_fixed)
  saveRDS(papers, RDS_OUT)

  m <- sampled[sampled$article_id %in% ids, ]
  m <- m[!duplicated(m$article_id), ]
  manifest <- data.frame(
    doi = m$doi, article_id = m$article_id, title = m$title, year = m$year, license = m$license,
    pdf_file = paste0("pdf/ece3.", m$article_id, ".pdf"), xml_file = paste0("xml/ece3.", m$article_id, ".xml"),
    pdf_exists = file.exists(file.path(PDF_DIR, paste0("ece3.", m$article_id, ".pdf"))),
    xml_exists = file.exists(file.path(XML_DIR, paste0("ece3.", m$article_id, ".xml"))),
    in_rds = TRUE, grobid_version = "0.9", conversion_date = format(Sys.Date(), "%Y-%m-%d")
  )
  write.csv(manifest, MANIFEST, row.names = FALSE)
  message("Build complete: ", length(papers), " papers in ", RDS_OUT)
}

# == Run ========================================================================
# phase1_download()
# replace_articles(c(ece312345 = 2020, ...))   # download failures / oversized PDFs
# phase3_convert()
# replace_articles(c(...))   # non-article notices found by an audit of the assembled RDS
# phase4_cleanup()
