# Build script: PLOS Medicine paper corpus for scienceverse/papers
#
# Produces:
#   plosmed/sample.csv      the sampled DOIs
#   plosmed/pdf/            1,000 PDF files (CC-BY 4.0 or CC0, per article)
#   plosmed/manifest.csv    one row per paper with provenance metadata
#   plosmed.rds              metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: httr2, metacheck (scienceverse/metacheck)
#   metacheck::email() set to a valid address for Unpaywall API
#   GROBID 0.9 instance (used: https://grobid.work.abed.cloud)
#
# This script reflects the pipeline as it was actually run, including two
# rounds of resampling after data-quality review found bad rows in the
# initial CrossRef sample (see "Known gaps" in README.md):
#   Phase 1: download         - sample 1,000 DOIs, download PDFs
#   Phase 2: convert          - GROBID-convert PDFs, assemble RDS + manifest
#   Phase 3: replace_round_1  - fix 1 bogus "issue image" record (2016)
#   Phase 4: replace_round_2  - fix 9 remaining non-articles/parse failures
#   Phase 5: doi_correction   - overwrite GROBID's unreliable header DOI
#                                with the verified CrossRef sample DOI
#
# Network calls use ssl_options = 2 (CURLSSLOPT_NO_REVOKE) to disable
# Windows Schannel's per-connection OCSP/CRL revocation checks, which can
# hang indefinitely if a CA's revocation endpoint is slow or unreachable.

library(httr2)
suppressMessages(library(metacheck))  # devtools::install_github("scienceverse/metacheck")

ISSN       <- "1549-1676"               # PLOS Medicine
EMAIL      <- metacheck::email()        # set with metacheck::email("you@example.com")
YEARS      <- 2016:2025
N_PER_YEAR <- 100
SEED       <- 20260618
PDF_DIR    <- "plosmed/pdf"
XML_DIR    <- "plosmed/xml"              # intermediate; not committed to repo
GROBID_URL <- "https://grobid.work.abed.cloud/api/processFulltextDocument"
RDS_OUT    <- "plosmed.rds"
MANIFEST   <- "plosmed/manifest.csv"
SAMPLE_CSV <- "plosmed/sample.csv"

dir.create(PDF_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(XML_DIR, recursive = TRUE, showWarnings = FALSE)

# excludes non-research notices CrossRef still types as "journal-article":
# corrections/errata/retractions ("X:" or "X to:" forms), reply-to-letter
# responses and commentaries, and editorial/administrative notices
is_nonarticle <- function(title) {
  grepl("(Correction|Retraction|Expression of Concern|Erratum|Withdrawal)(\\s+(Note|to))?:",
        title, ignore.case = TRUE) |
  grepl("^(Response|Reply) to [‘'\"]", title, ignore.case = TRUE) |
  grepl("commentary on", title, ignore.case = TRUE) |
  grepl("Reviewer and Editorial Board|^Call for Papers|^Editorial Board|^Acknowledge?ment|^Annual Report|Thank You",
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

plos_fallback_url <- function(doi) {
  paste0("https://journals.plos.org/plosmedicine/article/file?id=", doi, "&type=printable")
}

download_pdf <- function(doi, dest) {
  if (file.exists(dest) && file.info(dest)$size > 10000) return(TRUE)
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
  # verify it's actually a PDF, not an HTML error/redirect page saved with a .pdf name
  if (ok) {
    header <- readBin(dest, "raw", n = 5)
    if (rawToChar(header) != "%PDF-") { ok <- FALSE; unlink(dest) }
  }
  ok
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
message("CrossRef: ", nrow(dois_df), " unique research articles across ", length(YEARS),
        " years (", sum(notice), " non-articles excluded)")

set.seed(SEED)
sampled <- do.call(rbind, lapply(YEARS, \(yr) {
  pool <- dois_df[dois_df$year == yr, ]
  pool[sample.int(nrow(pool), min(N_PER_YEAR, nrow(pool))), ]
}))
sampled$article_id <- sub("10.1371/journal.pmed.", "", sampled$doi, fixed = TRUE)
write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
message("Sampled: ", nrow(sampled), " articles (", N_PER_YEAR, "/year target)")

for (i in seq_len(nrow(sampled))) {
  dest <- file.path(PDF_DIR, paste0("plosmed.", sampled$article_id[i], ".pdf"))
  ok <- download_pdf(sampled$doi[i], dest)
  if (!ok) message("[", i, "/", nrow(sampled), "] download failed: ", sampled$doi[i])
  Sys.sleep(1)
}
message("PDFs on disk: ", length(list.files(PDF_DIR, pattern = "\\.pdf$")), " / ", nrow(sampled))

# == Phase 2: convert ==========================================================

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
convert_all()

papers <- grobid_to_bibr(XML_DIR, save_path = NULL)
saveRDS(papers, RDS_OUT)
message("RDS saved: ", length(papers), " papers -> ", RDS_OUT)

write_manifest <- function() {
  sampled <- read.csv(SAMPLE_CSV, stringsAsFactors = FALSE)
  papers  <- readRDS(RDS_OUT)
  paper_ids <- sapply(papers, function(p) basename(p$info$file_name)) |>
    sub("^plosmed\\.", "", x = _) |> sub("\\.xml$", "", x = _)
  manifest <- data.frame(
    doi             = sampled$doi,
    article_id      = sampled$article_id,
    title           = sampled$title,
    year            = sampled$year,
    pdf_file        = paste0("pdf/plosmed.", sampled$article_id, ".pdf"),
    xml_file        = paste0("xml/plosmed.", sampled$article_id, ".xml"),
    pdf_exists      = file.exists(file.path(PDF_DIR, paste0("plosmed.", sampled$article_id, ".pdf"))),
    xml_exists      = file.exists(file.path(XML_DIR,  paste0("plosmed.", sampled$article_id, ".xml"))),
    in_rds          = sampled$article_id %in% paper_ids,
    grobid_version  = "0.9",
    conversion_date = format(Sys.Date(), "%Y-%m-%d"),
    license         = "CC-BY 4.0 or CC0"  # PLOS applies CC0 to a subset of content
  )
  write.csv(manifest, MANIFEST, row.names = FALSE)
  message("Manifest written: ", MANIFEST, ". Coverage: ", sum(manifest$in_rds), "/", nrow(manifest))
}
write_manifest()

# == Phase 3 & 4: resample bad rows ============================================
# Data-quality review found 5 bad rows in the initial sample, replaced with
# fresh draws from the same per-year CrossRef pool (excluding DOIs already
# sampled), preserving 100/year stratification:
#  - 1 bogus "PLoS Medicine Issue Image" record (DOI 10.1371/image.pmed.v13.i09,
#    article_id field happened to be the bare DOI since it didn't match the
#    journal.pmed. prefix used to derive article_id)
#  - 4 editorial/administrative notices not caught by is_nonarticle() on the
#    first pass: 2 "Reviewer and Editorial Board Thank You" notices
#    (article_id 1002281, 1002765) and 2 "Call for Papers" notices
#    (article_id 1004010, 1004014)

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
    picked$article_id <- sub("10.1371/journal.pmed.", "", picked$doi, fixed = TRUE)
    replacements[[as.character(yr)]] <- picked
  }
  replacements <- do.call(rbind, replacements)

  sampled <- sampled[!(sampled$article_id %in% bad_ids), ]
  sampled <- rbind(sampled, replacements)
  write.csv(sampled, SAMPLE_CSV, row.names = FALSE)

  for (id in bad_ids) {
    unlink(file.path(PDF_DIR, paste0("plosmed.", id, ".pdf")))
    unlink(file.path(XML_DIR, paste0("plosmed.", id, ".xml")))
  }
  for (i in seq_len(nrow(replacements))) {
    dest <- file.path(PDF_DIR, paste0("plosmed.", replacements$article_id[i], ".pdf"))
    download_pdf(replacements$doi[i], dest)
    Sys.sleep(1)
  }
}

bad_ids <- c("10.1371/image.pmed.v13.i09", "1002281", "1002765", "1004010", "1004014")
resample_replace(bad_ids)

convert_all()
new_papers <- grobid_to_bibr(
  list.files(XML_DIR, pattern = "\\.xml$", full.names = TRUE), save_path = NULL
)
saveRDS(new_papers, RDS_OUT)
write_manifest()

# == Phase 5: DOI correction ===================================================
# GROBID's header-extracted DOI was occasionally wrong (it picked up a DOI
# from elsewhere in the PDF rather than the article's own). Since every
# paper was sampled from CrossRef by DOI, the correct DOI is already known
# and does not depend on GROBID's extraction.

fix_doi_from_sample <- function() {
  papers <- readRDS(RDS_OUT)
  sampled <- read.csv(SAMPLE_CSV, stringsAsFactors = FALSE)
  fnames <- sapply(papers, function(p) basename(p$info$file_name))
  ids <- sub("^plosmed\\.", "", fnames) |> sub("\\.xml$", "", x = _)
  doi_lookup <- setNames(sampled$doi, sampled$article_id)
  for (i in seq_along(papers)) {
    papers[[i]]$info$doi <- doi_lookup[[ids[i]]]
  }
  saveRDS(papers, RDS_OUT)
}
fix_doi_from_sample()

message("Build complete: ", length(readRDS(RDS_OUT)), " papers in ", RDS_OUT)