# Build script: BMC Oral Health corpus for scienceverse/papers
#
# Produces:
#   bmcoral/sample.csv     the sampled DOIs
#   bmcoral/pdf/           1,000 PDF files (mostly CC-BY 4.0, some CC-BY-NC-ND)
#   bmcoral/manifest.csv   one row per paper with provenance metadata
#   bmcoral.rds             metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: httr2, metacheck (scienceverse/metacheck)
#   metacheck::email() set to a valid address for Unpaywall API
#   GROBID 0.9 instance (used: https://grobid.work.abed.cloud)
#
# Phases, reflecting the pipeline as actually run:
#   Phase 1: download         - sample 1,000 DOIs (100/year, 2016-2025),
#                                download PDFs
#   Phase 2: retry_missing    - recover the ~18 articles with no Unpaywall
#                                PDF url by resolving the doi.org redirect
#   Phase 3: convert          - GROBID-convert PDFs, assemble RDS + manifest
#   Phase 4: replace_empties  - 21 articles excluded (1 oversized PDF, 20
#                                with a GROBID title-extraction gap) and
#                                replaced with fresh draws from the same
#                                per-year pool, preserving stratification
#   Phase 5: doi_correction   - overwrite GROBID's unreliable header DOI
#                                with the verified CrossRef sample DOI

library(httr2)
suppressMessages(library(metacheck))

ISSN       <- "1472-6831"   # BMC Oral Health
EMAIL      <- metacheck::email()
YEARS      <- 2016:2025
N_PER_YEAR <- 100
SEED       <- 20260619
PDF_DIR    <- "bmcoral/pdf"
XML_DIR    <- "bmcoral/xml"
GROBID_URL <- "https://grobid.work.abed.cloud/api/processFulltextDocument"
RDS_OUT    <- "bmcoral.rds"
MANIFEST   <- "bmcoral/manifest.csv"
SAMPLE_CSV <- "bmcoral/sample.csv"

dir.create(PDF_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(XML_DIR, recursive = TRUE, showWarnings = FALSE)

is_nonarticle <- function(title) {
  grepl("(Correction|Retraction|Expression of Concern|Erratum|Withdrawal)(\\s+(Note|to|To))?:",
        title, ignore.case = TRUE) |
  grepl("^(Response|Reply) to [‘'\"]", title, ignore.case = TRUE) |
  grepl("commentary on", title, ignore.case = TRUE) |
  grepl("Reviewer and Editorial Board|^Call for Papers|^Editorial Board|^Acknowledge?ment|^Annual Report|Thank You|^Meeting [Rr]eport:",
        title, ignore.case = TRUE)
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

items_to_row <- function(it, yr) {
  data.frame(doi = it$DOI %||% NA_character_, title = (it$title[[1]] %||% NA_character_),
             year = yr, stringsAsFactors = FALSE)
}

get_pdf_url <- function(doi) {
  resp <- tryCatch(
    request(paste0("https://api.unpaywall.org/v2/", doi, "?email=", EMAIL)) |>
      req_timeout(15) |> req_options(connecttimeout = 8, ssl_options = 2) |>
      req_error(is_error = \(r) FALSE) |> req_perform(),
    error = \(e) NULL
  )
  if (is.null(resp) || resp_status(resp) != 200) return(NULL)
  d <- resp_body_json(resp)
  loc <- d$best_oa_location
  url <- loc$url_for_pdf %||% NA_character_
  if (is.na(url) || !nzchar(url)) {
    urls <- sapply(d$oa_locations %||% list(), function(l) l$url_for_pdf %||% NA_character_)
    urls <- urls[!is.na(urls)]
    if (length(urls) == 0) return(NULL)
    url <- urls[[1]]
  }
  url
}

springer_fallback_url <- function(doi) paste0("https://link.springer.com/content/pdf/", doi, ".pdf")

download_pdf <- function(url, dest) {
  ok <- tryCatch(
    request(url) |>
      req_headers(`User-Agent` = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36") |>
      req_timeout(30) |> req_options(connecttimeout = 10, ssl_options = 2) |>
      req_error(is_error = \(r) FALSE) |>
      req_perform(path = dest) |> resp_status() == 200,
    error = \(e) FALSE
  )
  if (ok) {
    header <- readBin(dest, "raw", n = 5)
    if (rawToChar(header) != "%PDF-") { ok <- FALSE; unlink(dest) }
  }
  ok
}

convert_all <- function() {
  pdfs <- list.files(PDF_DIR, pattern = "\\.pdf$", full.names = TRUE)
  already_xml <- tools::file_path_sans_ext(basename(list.files(XML_DIR, pattern = "\\.xml$")))
  for (pdf in pdfs) {
    stem <- tools::file_path_sans_ext(basename(pdf))
    if (stem %in% already_xml) next
    out_xml <- file.path(XML_DIR, paste0(stem, ".xml"))
    tryCatch(convert_grobid(pdf, save_path = out_xml, api_url = GROBID_URL),
             error = function(e) message("ERROR ", stem, ": ", e$message))
  }
}

write_manifest <- function() {
  sampled <- read.csv(SAMPLE_CSV, stringsAsFactors = FALSE)
  papers  <- readRDS(RDS_OUT)
  paper_ids <- sapply(papers, function(p) basename(p$info$file_name)) |>
    sub("^bmcoral\\.", "", x = _) |> sub("\\.xml$", "", x = _)
  manifest <- data.frame(
    doi             = sampled$doi,
    article_id      = sampled$article_id,
    title           = sampled$title,
    year            = sampled$year,
    pdf_file        = paste0("pdf/bmcoral.", sampled$article_id, ".pdf"),
    xml_file        = paste0("xml/bmcoral.", sampled$article_id, ".xml"),
    pdf_exists      = file.exists(file.path(PDF_DIR, paste0("bmcoral.", sampled$article_id, ".pdf"))),
    xml_exists      = file.exists(file.path(XML_DIR,  paste0("bmcoral.", sampled$article_id, ".xml"))),
    in_rds          = sampled$article_id %in% paper_ids,
    grobid_version  = "0.9",
    conversion_date = format(Sys.Date(), "%Y-%m-%d"),
    license         = "Mostly CC-BY 4.0; some CC-BY-NC-ND -- check individual article"
  )
  write.csv(manifest, MANIFEST, row.names = FALSE)
  message("Coverage: ", sum(manifest$in_rds), "/", nrow(manifest))
}

resample_replace <- function(bad_ids) {
  sampled <- read.csv(SAMPLE_CSV, stringsAsFactors = FALSE)
  bad_rows <- sampled[sampled$article_id %in% bad_ids, ]
  set.seed(SEED)
  replacements <- list()
  for (yr in unique(bad_rows$year)) {
    n_needed <- sum(bad_rows$year == yr)
    pool <- fetch_year(yr)
    pool <- do.call(rbind, lapply(pool, items_to_row, yr = yr))
    pool <- pool[!duplicated(pool$doi) & !is.na(pool$doi), ]
    pool <- pool[!is_nonarticle(pool$title), ]
    pool <- pool[!(pool$doi %in% sampled$doi), ]
    picked <- pool[sample.int(nrow(pool), n_needed), ]
    picked$article_id <- gsub("[^A-Za-z0-9]", "", sub("^10\\.\\d+/", "", picked$doi))
    replacements[[as.character(yr)]] <- picked
  }
  replacements <- do.call(rbind, replacements)
  stopifnot(!any(replacements$article_id %in% sampled$article_id))

  sampled <- sampled[!(sampled$article_id %in% bad_ids), ]
  sampled <- rbind(sampled, replacements)
  write.csv(sampled, SAMPLE_CSV, row.names = FALSE)

  for (id in bad_ids) {
    unlink(file.path(PDF_DIR, paste0("bmcoral.", id, ".pdf")))
    unlink(file.path(XML_DIR, paste0("bmcoral.", id, ".xml")))
  }
  for (i in seq_len(nrow(replacements))) {
    pdf_url <- get_pdf_url(replacements$doi[i])
    if (is.null(pdf_url)) pdf_url <- springer_fallback_url(replacements$doi[i])
    dest <- file.path(PDF_DIR, paste0("bmcoral.", replacements$article_id[i], ".pdf"))
    download_pdf(pdf_url, dest)
    Sys.sleep(1)
  }
}

# == Phase 1: download ===========================================================

message("Fetching CrossRef DOIs for ", length(YEARS), " years...")
dois_df <- do.call(rbind, lapply(YEARS, \(yr) {
  Sys.sleep(1)
  items <- fetch_year(yr)
  message("  ", yr, ": ", length(items), " journal articles")
  do.call(rbind, lapply(items, items_to_row, yr = yr))
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
sampled$article_id <- gsub("[^A-Za-z0-9]", "", sub("^10\\.\\d+/", "", sampled$doi))
stopifnot(length(unique(sampled$article_id)) == nrow(sampled))
write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
message("Sampled: ", nrow(sampled), " articles (", N_PER_YEAR, "/year target)")

for (i in seq_len(nrow(sampled))) {
  dest <- file.path(PDF_DIR, paste0("bmcoral.", sampled$article_id[i], ".pdf"))
  if (file.exists(dest) && file.info(dest)$size > 10000) next
  pdf_url <- get_pdf_url(sampled$doi[i])
  if (is.null(pdf_url)) pdf_url <- springer_fallback_url(sampled$doi[i])
  download_pdf(pdf_url, dest)
  Sys.sleep(1)
}
message("PDFs on disk: ", length(list.files(PDF_DIR, pattern = "\\.pdf$")), " / ", nrow(sampled))

# == Phase 2: retry missing (no Unpaywall url, or download failed) ==============

have <- list.files(PDF_DIR, pattern = "\\.pdf$")
have_ids <- sub("^bmcoral\\.", "", have) |> sub("\\.pdf$", "", x = _)
missing <- sampled[!(sampled$article_id %in% have_ids), ]
for (i in seq_len(nrow(missing))) {
  dest <- file.path(PDF_DIR, paste0("bmcoral.", missing$article_id[i], ".pdf"))
  download_pdf(springer_fallback_url(missing$doi[i]), dest)
  Sys.sleep(1)
}
message("PDFs on disk after retry: ", length(list.files(PDF_DIR, pattern = "\\.pdf$")), " / ", nrow(sampled))

# == Phase 3: convert =============================================================

convert_all()
papers <- grobid_to_bibr(XML_DIR, save_path = NULL)
saveRDS(papers, RDS_OUT)
message("RDS saved: ", length(papers), " papers -> ", RDS_OUT)
write_manifest()

# == Phase 4: replace empty-title / oversized papers =============================
# 1 PDF exceeded GROBID's upload size limit; 20 had a GROBID parsing gap
# (empty titleStmt/title despite substantial extracted body text).

m <- read.csv(MANIFEST, stringsAsFactors = FALSE)
papers <- readRDS(RDS_OUT)
fnames <- sapply(papers, function(p) basename(p$info$file_name))
ids <- sub("^bmcoral\\.", "", fnames) |> sub("\\.xml$", "", x = _)
title_len <- sapply(papers, function(p) nchar(p$info$title %||% ""))
empty_title_ids <- ids[title_len == 0]
oversized_ids <- m$article_id[!m$xml_exists]   # PDF present, conversion failed
bad_ids <- union(empty_title_ids, oversized_ids)

if (length(bad_ids) > 0) {
  resample_replace(bad_ids)
  convert_all()
  papers <- readRDS(RDS_OUT)
  fnames <- sapply(papers, function(p) basename(p$info$file_name))
  existing_ids <- sub("^bmcoral\\.", "", fnames) |> sub("\\.xml$", "", x = _)
  papers <- papers[!(existing_ids %in% bad_ids)]

  new_xml <- file.path(XML_DIR, paste0("bmcoral.",
    setdiff(read.csv(SAMPLE_CSV, stringsAsFactors = FALSE)$article_id, existing_ids), ".xml"))
  new_xml <- new_xml[file.exists(new_xml)]
  new_papers <- grobid_to_bibr(new_xml, save_path = NULL)
  if (length(new_xml) == 1) new_papers <- list(new_papers)  # see note below

  orig_class <- class(papers)
  combined <- c(papers, new_papers)
  class(combined) <- orig_class
  saveRDS(combined, RDS_OUT)
  write_manifest()
}
# Note: grobid_to_bibr() on a single file path returns one unwrapped
# scivrs_paper object, not a length-1 paperlist -- wrap it before
# concatenating, or its internal fields get spliced in as separate papers.

# == Phase 5: DOI correction ======================================================

papers <- readRDS(RDS_OUT)
sampled <- read.csv(SAMPLE_CSV, stringsAsFactors = FALSE)
fnames <- sapply(papers, function(p) basename(p$info$file_name))
ids <- sub("^bmcoral\\.", "", fnames) |> sub("\\.xml$", "", x = _)
doi_lookup <- setNames(sampled$doi, sampled$article_id)
for (i in seq_along(papers)) papers[[i]]$info$doi <- doi_lookup[[ids[i]]]
saveRDS(papers, RDS_OUT)

message("Build complete: ", length(readRDS(RDS_OUT)), " papers in ", RDS_OUT)