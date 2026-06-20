# Build script: PLOS ONE paper corpus for scienceverse/papers
#
# Produces:
#   plosone/sample.csv      the sampled DOIs
#   plosone/pdf/            1,000 PDF files (CC-BY 4.0 or CC0, per article)
#   plosone/manifest.csv    one row per paper with provenance metadata
#   plosone.rds              metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: httr2, metacheck (scienceverse/metacheck)
#   metacheck::email() set to a valid address for Unpaywall API
#   GROBID 0.9 instance (used: https://grobid.work.abed.cloud)
#
# IMPORTANT: PLOS ONE's DOI suffixes are zero-padded to 7 digits
# (e.g. "0023765"). article_id MUST be read/written as character
# throughout -- read.csv() will silently infer an all-digit character
# column as integer and strip the leading zero, breaking every filename
# lookup downstream. Always use colClasses = "character" when reading
# sample.csv / manifest.csv, and re-cast other columns (e.g. year)
# afterward.
#
# This script reflects the pipeline as it was actually run:
#   Phase 1: download         - sample 1,000 DOIs, download PDFs
#   Phase 2: convert          - GROBID-convert PDFs, assemble RDS + manifest
#   Phase 3: retry_transient  - 9 downloads failed due to PLOS rate-limiting
#                                a rapid request sequence; retried with a
#                                longer delay (no replacement needed, all 9
#                                succeeded)
#   Phase 4: replace_oversized - 8 PDFs exceeded GROBID's upload size limit
#                                (concentrated in 2016-2018), replaced with
#                                fresh draws from the same per-year pool
#   Phase 5: doi_correction   - overwrite GROBID's unreliable header DOI
#                                with the verified CrossRef sample DOI
#
# Network calls use ssl_options = 2 (CURLSSLOPT_NO_REVOKE) to disable
# Windows Schannel's per-connection OCSP/CRL revocation checks, which can
# hang indefinitely if a CA's revocation endpoint is slow or unreachable.

library(httr2)
suppressMessages(library(metacheck))

ISSN       <- "1932-6203"               # PLOS ONE
EMAIL      <- metacheck::email()
YEARS      <- 2016:2025
N_PER_YEAR <- 100
SEED       <- 20260620
PDF_DIR    <- "plosone/pdf"
XML_DIR    <- "plosone/xml"
GROBID_URL <- "https://grobid.work.abed.cloud/api/processFulltextDocument"
RDS_OUT    <- "plosone.rds"
MANIFEST   <- "plosone/manifest.csv"
SAMPLE_CSV <- "plosone/sample.csv"
MAX_BYTES  <- 15 * 1024 * 1024

dir.create(PDF_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(XML_DIR, recursive = TRUE, showWarnings = FALSE)

is_nonarticle <- function(title) {
  grepl("(Correction|Retraction|Expression of Concern|Erratum|Withdrawal)(\\s+(Note|to|To))?:",
        title, ignore.case = TRUE) |
  grepl("^(Response|Reply) to [‘'\"]", title, ignore.case = TRUE) |
  grepl("commentary on", title, ignore.case = TRUE) |
  grepl("Reviewer and Editorial Board|^Call for Papers|^Editorial Board|^Editorial Note|^Acknowledge?ment|^Annual Report|Thank You|^Meeting [Rr]eport:",
        title, ignore.case = TRUE) |
  grepl("^Broadening the scope of", title, ignore.case = TRUE)
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

plos_fallback_url <- function(doi) {
  paste0("https://journals.plos.org/plosone/article/file?id=", doi, "&type=printable")
}

download_pdf <- function(doi, dest, max_bytes = Inf, delay = 2) {
  pdf_url <- tryCatch({
    resp <- request(paste0("https://api.unpaywall.org/v2/", doi, "?email=", EMAIL)) |>
      req_timeout(15) |> req_options(connecttimeout = 8, ssl_options = 2) |>
      req_error(is_error = \(r) FALSE) |> req_perform()
    if (resp_status(resp) == 200) resp_body_json(resp)[["best_oa_location"]][["url_for_pdf"]] else NULL
  }, error = \(e) NULL)
  if (is.null(pdf_url) || !nzchar(pdf_url)) pdf_url <- plos_fallback_url(doi)

  ok <- tryCatch(
    request(pdf_url) |> req_headers(`User-Agent` = "Mozilla/5.0") |>
      req_timeout(30) |> req_options(connecttimeout = 10, ssl_options = 2) |>
      req_error(is_error = \(r) FALSE) |> req_perform(path = dest) |> resp_status() == 200,
    error = \(e) FALSE
  )
  if (ok) {
    header <- readBin(dest, "raw", n = 5)
    if (rawToChar(header) != "%PDF-") ok <- FALSE
  }
  if (ok && file.info(dest)$size > max_bytes) ok <- FALSE
  if (!ok) unlink(dest)
  Sys.sleep(delay)
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
  sampled <- read.csv(SAMPLE_CSV, stringsAsFactors = FALSE, colClasses = "character")
  sampled$year <- as.integer(sampled$year)
  papers  <- readRDS(RDS_OUT)
  paper_ids <- sapply(papers, function(p) basename(p$info$file_name)) |>
    sub("^plosone\\.", "", x = _) |> sub("\\.xml$", "", x = _)
  manifest <- data.frame(
    doi             = sampled$doi,
    article_id      = sampled$article_id,
    title           = sampled$title,
    year            = sampled$year,
    pdf_file        = paste0("pdf/plosone.", sampled$article_id, ".pdf"),
    xml_file        = paste0("xml/plosone.", sampled$article_id, ".xml"),
    pdf_exists      = file.exists(file.path(PDF_DIR, paste0("plosone.", sampled$article_id, ".pdf"))),
    xml_exists      = file.exists(file.path(XML_DIR,  paste0("plosone.", sampled$article_id, ".xml"))),
    in_rds          = sampled$article_id %in% paper_ids,
    grobid_version  = "0.9",
    conversion_date = format(Sys.Date(), "%Y-%m-%d"),
    license         = "CC-BY 4.0 or CC0"
  )
  write.csv(manifest, MANIFEST, row.names = FALSE)
  message("Coverage: ", sum(manifest$in_rds), "/", nrow(manifest))
}

resample_replace <- function(bad_ids, max_bytes = Inf) {
  sampled <- read.csv(SAMPLE_CSV, stringsAsFactors = FALSE, colClasses = "character")
  sampled$year <- as.integer(sampled$year)
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
    pool <- pool[sample(nrow(pool)), ]

    picked <- data.frame()
    for (i in seq_len(nrow(pool))) {
      if (nrow(picked) >= n_needed) break
      candidate <- pool[i, ]
      candidate$article_id <- sub("10.1371/journal.pone.", "", candidate$doi, fixed = TRUE)
      dest <- file.path(PDF_DIR, paste0("plosone.", candidate$article_id, ".pdf"))
      if (download_pdf(candidate$doi, dest, max_bytes)) picked <- rbind(picked, candidate)
    }
    replacements[[as.character(yr)]] <- picked
  }
  replacements <- do.call(rbind, replacements)

  sampled <- sampled[!(sampled$article_id %in% bad_ids), ]
  sampled <- rbind(sampled, replacements)
  write.csv(sampled, SAMPLE_CSV, row.names = FALSE)

  for (id in bad_ids) {
    unlink(file.path(PDF_DIR, paste0("plosone.", id, ".pdf")))
    unlink(file.path(XML_DIR, paste0("plosone.", id, ".xml")))
  }
}

fix_doi_from_sample <- function() {
  papers <- readRDS(RDS_OUT)
  m <- read.csv(MANIFEST, stringsAsFactors = FALSE, colClasses = "character")
  fnames <- sapply(papers, function(p) basename(p$info$file_name))
  ids <- sub("^plosone\\.", "", fnames) |> sub("\\.xml$", "", x = _)
  doi_lookup <- setNames(m$doi, m$article_id)
  for (i in seq_along(papers)) papers[[i]]$info$doi <- doi_lookup[[ids[i]]]
  saveRDS(papers, RDS_OUT)
}

# == Phase 1: download =========================================================

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
sampled$article_id <- sub("10.1371/journal.pone.", "", sampled$doi, fixed = TRUE)
stopifnot(length(unique(sampled$article_id)) == nrow(sampled))
write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
message("Sampled: ", nrow(sampled), " articles (", N_PER_YEAR, "/year target)")

for (i in seq_len(nrow(sampled))) {
  dest <- file.path(PDF_DIR, paste0("plosone.", sampled$article_id[i], ".pdf"))
  if (file.exists(dest) && file.info(dest)$size > 10000) next
  download_pdf(sampled$doi[i], dest)
}
message("PDFs on disk: ", length(list.files(PDF_DIR, pattern = "\\.pdf$")), " / ", nrow(sampled))

# == Phase 2: convert ==========================================================

convert_all()
papers <- grobid_to_bibr(XML_DIR, save_path = NULL)
saveRDS(papers, RDS_OUT)
write_manifest()

# == Phase 3: retry transient download failures =================================
# A rapid sequence of requests can trigger PLOS rate-limiting; the affected
# downloads succeed on retry with a longer delay, no replacement needed.

sampled <- read.csv(SAMPLE_CSV, stringsAsFactors = FALSE, colClasses = "character")
have <- list.files(PDF_DIR, pattern = "\\.pdf$")
have_ids <- sub("^plosone\\.", "", have) |> sub("\\.pdf$", "", x = _)
missing <- sampled[!(sampled$article_id %in% have_ids), ]
for (i in seq_len(nrow(missing))) {
  dest <- file.path(PDF_DIR, paste0("plosone.", missing$article_id[i], ".pdf"))
  download_pdf(missing$doi[i], dest, delay = 3)
}
message("PDFs on disk after retry: ", length(list.files(PDF_DIR, pattern = "\\.pdf$")), " / ", nrow(sampled))

convert_all()
papers <- grobid_to_bibr(XML_DIR, save_path = NULL)
saveRDS(papers, RDS_OUT)
write_manifest()

# == Phase 4: replace oversized PDFs ============================================

m <- read.csv(MANIFEST, stringsAsFactors = FALSE, colClasses = "character")
bad_ids <- m$article_id[m$xml_exists == "FALSE"]
if (length(bad_ids) > 0) {
  resample_replace(bad_ids, max_bytes = MAX_BYTES)
  convert_all()
  papers <- grobid_to_bibr(XML_DIR, save_path = NULL)
  saveRDS(papers, RDS_OUT)
  write_manifest()
}

# == Phase 5: DOI correction =====================================================

fix_doi_from_sample()

message("Build complete: ", length(readRDS(RDS_OUT)), " papers in ", RDS_OUT)