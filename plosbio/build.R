# Build script: PLOS Biology paper corpus for scienceverse/papers
#
# Produces:
#   plosbio/sample.csv      the sampled DOIs
#   plosbio/pdf/            1,000 PDF files (CC-BY 4.0 or CC0, per article)
#   plosbio/manifest.csv    one row per paper with provenance metadata
#   plosbio.rds              metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: httr2, metacheck (scienceverse/metacheck)
#   metacheck::email() set to a valid address for Unpaywall API
#   GROBID 0.9 instance (used: https://grobid.work.abed.cloud)
#
# This script reflects the pipeline as it was actually run, including
# rounds of resampling after data-quality review found bad rows in the
# initial CrossRef sample (see "Known gaps" in README.md):
#   Phase 1: download         - sample 1,000 DOIs, download PDFs
#   Phase 2: convert          - GROBID-convert PDFs, assemble RDS + manifest
#   Phase 3: replace_round_1  - fix 1 bogus "issue image" record (2016) and
#                                retry 9 transiently-failed downloads
#   Phase 4: replace_round_2  - fix 17 oversized PDFs (>GROBID upload limit,
#                                concentrated in 2016-2018)
#   Phase 5: replace_round_3  - fix 2 remaining non-articles missed by the
#                                initial title filter (an editorial
#                                announcement and an "Editorial Note")
#   Phase 6: doi_correction   - overwrite GROBID's unreliable header DOI
#                                with the verified CrossRef sample DOI
#
# Network calls use ssl_options = 2 (CURLSSLOPT_NO_REVOKE) to disable
# Windows Schannel's per-connection OCSP/CRL revocation checks, which can
# hang indefinitely if a CA's revocation endpoint is slow or unreachable.

library(httr2)
suppressMessages(library(metacheck))

ISSN       <- "1545-7885"               # PLOS Biology (electronic ISSN)
EMAIL      <- metacheck::email()
YEARS      <- 2016:2025
N_PER_YEAR <- 100
SEED       <- 20260619
PDF_DIR    <- "plosbio/pdf"
XML_DIR    <- "plosbio/xml"
GROBID_URL <- "https://grobid.work.abed.cloud/api/processFulltextDocument"
RDS_OUT    <- "plosbio.rds"
MANIFEST   <- "plosbio/manifest.csv"
SAMPLE_CSV <- "plosbio/sample.csv"
MAX_BYTES  <- 15 * 1024 * 1024   # replacement PDFs must stay under GROBID's limit

dir.create(PDF_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(XML_DIR, recursive = TRUE, showWarnings = FALSE)

is_nonarticle <- function(title) {
  grepl("(Correction|Retraction|Expression of Concern|Erratum|Withdrawal)(\\s+(Note|to|To))?:",
        title, ignore.case = TRUE) |
  grepl("^(Response|Reply) to [‘'\"]", title, ignore.case = TRUE) |
  grepl("commentary on", title, ignore.case = TRUE) |
  grepl("Reviewer and Editorial Board|^Call for Papers|^Editorial Board|^Editorial Note|^Acknowledge?ment|^Annual Report|Thank You|^Meeting [Rr]eport:",
        title, ignore.case = TRUE) |
  grepl("^Broadening the scope of", title, ignore.case = TRUE) |
  grepl("^10\\.1371/image\\.", title)
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
  paste0("https://journals.plos.org/plosbiology/article/file?id=", doi, "&type=printable")
}

download_pdf <- function(doi, dest, max_bytes = Inf) {
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
    sub("^plosbio\\.", "", x = _) |> sub("\\.xml$", "", x = _)
  manifest <- data.frame(
    doi             = sampled$doi,
    article_id      = sampled$article_id,
    title           = sampled$title,
    year            = sampled$year,
    pdf_file        = paste0("pdf/plosbio.", sampled$article_id, ".pdf"),
    xml_file        = paste0("xml/plosbio.", sampled$article_id, ".xml"),
    pdf_exists      = file.exists(file.path(PDF_DIR, paste0("plosbio.", sampled$article_id, ".pdf"))),
    xml_exists      = file.exists(file.path(XML_DIR,  paste0("plosbio.", sampled$article_id, ".xml"))),
    in_rds          = sampled$article_id %in% paper_ids,
    grobid_version  = "0.9",
    conversion_date = format(Sys.Date(), "%Y-%m-%d"),
    license         = "CC-BY 4.0 or CC0"  # PLOS applies CC0 to a subset of content
  )
  write.csv(manifest, MANIFEST, row.names = FALSE)
  message("Coverage: ", sum(manifest$in_rds), "/", nrow(manifest))
}

resample_replace <- function(bad_ids, max_bytes = Inf) {
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
    pool <- pool[sample(nrow(pool)), ]

    picked <- data.frame()
    for (i in seq_len(nrow(pool))) {
      if (nrow(picked) >= n_needed) break
      candidate <- pool[i, ]
      candidate$article_id <- sub("10.1371/journal.pbio.", "", candidate$doi, fixed = TRUE)
      dest <- file.path(PDF_DIR, paste0("plosbio.", candidate$article_id, ".pdf"))
      if (download_pdf(candidate$doi, dest, max_bytes)) picked <- rbind(picked, candidate)
      Sys.sleep(1)
    }
    replacements[[as.character(yr)]] <- picked
  }
  replacements <- do.call(rbind, replacements)

  sampled <- sampled[!(sampled$article_id %in% bad_ids), ]
  sampled <- rbind(sampled, replacements)
  write.csv(sampled, SAMPLE_CSV, row.names = FALSE)

  for (id in bad_ids) {
    unlink(file.path(PDF_DIR, paste0("plosbio.", id, ".pdf")))
    unlink(file.path(XML_DIR, paste0("plosbio.", id, ".xml")))
  }
}

fix_doi_from_sample <- function() {
  papers <- readRDS(RDS_OUT)
  sampled <- read.csv(SAMPLE_CSV, stringsAsFactors = FALSE)
  fnames <- sapply(papers, function(p) basename(p$info$file_name))
  ids <- sub("^plosbio\\.", "", fnames) |> sub("\\.xml$", "", x = _)
  doi_lookup <- setNames(sampled$doi, sampled$article_id)
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
sampled$article_id <- sub("10.1371/journal.pbio.", "", sampled$doi, fixed = TRUE)
stopifnot(length(unique(sampled$article_id)) == nrow(sampled))
write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
message("Sampled: ", nrow(sampled), " articles (", N_PER_YEAR, "/year target)")

for (i in seq_len(nrow(sampled))) {
  dest <- file.path(PDF_DIR, paste0("plosbio.", sampled$article_id[i], ".pdf"))
  if (file.exists(dest) && file.info(dest)$size > 10000) next
  download_pdf(sampled$doi[i], dest)
  Sys.sleep(1)
}
message("PDFs on disk: ", length(list.files(PDF_DIR, pattern = "\\.pdf$")), " / ", nrow(sampled))

# == Phase 2: convert ==========================================================

convert_all()
papers <- grobid_to_bibr(XML_DIR, save_path = NULL)
saveRDS(papers, RDS_OUT)
write_manifest()

# == Phase 3: fix issue-image record + retry transient download failures ======
# The initial sample included a bogus "PLoS Biology Issue Image" record
# CrossRef mistyped as journal-article; 9 other downloads failed
# transiently (PLOS rate-limiting -- they succeeded on a slower retry).

bad_ids_p3 <- "10.1371/image.pbio.v14.i09"
sampled <- read.csv(SAMPLE_CSV, stringsAsFactors = FALSE)
if (bad_ids_p3 %in% sampled$doi) resample_replace(bad_ids_p3)

have <- list.files(PDF_DIR, pattern = "\\.pdf$")
have_ids <- sub("^plosbio\\.", "", have) |> sub("\\.pdf$", "", x = _)
sampled <- read.csv(SAMPLE_CSV, stringsAsFactors = FALSE)
missing <- sampled[!(sampled$article_id %in% have_ids), ]
for (i in seq_len(nrow(missing))) {
  dest <- file.path(PDF_DIR, paste0("plosbio.", missing$article_id[i], ".pdf"))
  download_pdf(missing$doi[i], dest)
  Sys.sleep(2)  # longer delay avoids the rate-limiting that caused the failures
}

convert_all()
papers <- grobid_to_bibr(XML_DIR, save_path = NULL)
saveRDS(papers, RDS_OUT)
write_manifest()

# == Phase 4: replace oversized PDFs ===========================================
# 17 PDFs exceeded GROBID's upload size limit (~20MB+, image-heavy figures
# common in biology papers), concentrated in 2016-2018.

m <- read.csv(MANIFEST, stringsAsFactors = FALSE)
bad_ids_p4 <- m$article_id[!m$xml_exists]
if (length(bad_ids_p4) > 0) {
  resample_replace(bad_ids_p4, max_bytes = MAX_BYTES)
  convert_all()
  papers <- grobid_to_bibr(XML_DIR, save_path = NULL)
  saveRDS(papers, RDS_OUT)
  write_manifest()
}

# == Phase 5: replace remaining non-articles found by full-corpus audit ======
# 1 editorial announcement ("Broadening the scope of PLOS Biology...") and
# 1 "Editorial Note:" correction notice -- title patterns not caught by the
# initial is_nonarticle() filter (now fixed above to also catch these).

bad_ids_p5 <- c("3000248", "3003507")
sampled <- read.csv(SAMPLE_CSV, stringsAsFactors = FALSE)
bad_ids_p5 <- intersect(bad_ids_p5, sampled$article_id)
if (length(bad_ids_p5) > 0) {
  resample_replace(bad_ids_p5, max_bytes = MAX_BYTES)
  convert_all()
  papers <- grobid_to_bibr(XML_DIR, save_path = NULL)
  saveRDS(papers, RDS_OUT)
  write_manifest()
}

# == Phase 6: DOI correction ====================================================
# GROBID's header-extracted DOI was wrong for 5 of the final 1,000 papers
# (it picked up an unrelated DOI, including from entirely different
# journals in three cases). Overwrite from the known CrossRef sample DOI.

fix_doi_from_sample()

message("Build complete: ", length(readRDS(RDS_OUT)), " papers in ", RDS_OUT)