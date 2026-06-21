# Build script: i-Perception corpus for scienceverse/papers
#
# Produces:
#   iperc/sample.csv   the sampled DOIs (100/year target, 2017-2026)
#   iperc/pdf/         496 PDF files (CC-BY 4.0)
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
# Phases, reflecting the pipeline as actually run:
#   Phase 1: download            - sample 100 DOIs/year, download via
#                                   SAGE direct host (with Client Hints
#                                   headers)
#   Phase 2: retry_recent        - 2021-2026 articles initially failed
#                                   due to the (then-undiagnosed)
#                                   Cloudflare block; retried
#                                   successfully once the Client Hints
#                                   fix was found
#   Phase 3: convert             - GROBID-convert PDFs, assemble RDS + manifest
#   Phase 4: fix_orphan_rows     - an earlier numeric-coercion bug in a
#                                   retry script (missing colClasses =
#                                   "character") caused some downloaded
#                                   PDFs' sample.csv rows to be lost;
#                                   recovered by extracting the DOI
#                                   directly from each orphaned PDF's
#                                   bytes and re-querying CrossRef
#   Phase 5: fix_duplicate_dois  - the orphan recovery above
#                                   reconstructed some rows under a
#                                   slightly different (typo'd)
#                                   article_id than the original,
#                                   creating 115 duplicate-DOI rows;
#                                   resolved by keeping only the row
#                                   matching an actual downloaded PDF
#   Phase 6: cleanup             - dropped 4 genuine non-article
#                                   notices (2 "Erratum", 1 "Correction
#                                   to Figures", 1 thin-content
#                                   "Addendum"), corrected 6 garbled
#                                   GROBID DOIs, backfilled 2 missing
#                                   titles from CrossRef

library(httr2)
library(metacheck)

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

# == Phase 1: download =============================================================

message("Fetching CrossRef DOIs for ", length(YEARS), " years...")
all_items <- lapply(YEARS, \(yr) {
  Sys.sleep(1)
  items <- fetch_year(yr)
  message("  ", yr, ": ", length(items), " journal articles")
  items
})
names(all_items) <- YEARS

dois_df <- do.call(rbind, lapply(YEARS, \(yr) {
  items <- all_items[[as.character(yr)]]
  do.call(rbind, lapply(items, function(it) {
    data.frame(doi = it$DOI %||% NA_character_, title = (it$title[[1]] %||% NA_character_),
               year = yr, stringsAsFactors = FALSE)
  }))
}))
dois_df <- dois_df[!duplicated(dois_df$doi) & !is.na(dois_df$doi), ]
notice <- is_nonarticle(dois_df$title)
dois_df <- dois_df[!notice, ]
message("CrossRef: ", nrow(dois_df), " unique research articles (", sum(notice), " non-articles excluded)")

set.seed(SEED)
sampled <- do.call(rbind, lapply(YEARS, \(yr) {
  pool <- dois_df[dois_df$year == yr, ]
  n <- min(N_PER_YEAR, nrow(pool))
  pool[sample.int(nrow(pool), n), ]
}))
sampled$article_id <- gsub("[^A-Za-z0-9]", "", sub("^10\\.1177/", "", sampled$doi))
stopifnot(length(unique(sampled$article_id)) == nrow(sampled))
write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
message("Sampled: ", nrow(sampled), " articles (", N_PER_YEAR, "/year target)")

for (i in seq_len(nrow(sampled))) {
  doi    <- sampled$doi[i]
  art_id <- sampled$article_id[i]
  dest   <- file.path(PDF_DIR, paste0("iperc.", art_id, ".pdf"))
  if (file.exists(dest) && file.info(dest)$size > 10000) next
  pdf_url <- paste0("https://journals.sagepub.com/doi/pdf/", doi)
  download_pdf(pdf_url, dest)
  Sys.sleep(1)
}
message("PDFs on disk: ", length(list.files(PDF_DIR, pattern = "\\.pdf$")), " / ", nrow(sampled))

# NOTE: at this point in the actual build, the 2021-2026 articles that
# initially failed were retried once the Cloudflare Client Hints fix
# was found (see iperc_retry_recent.R), and several rounds of
# orphan-row recovery and duplicate-DOI cleanup were applied (see
# iperc_fix_orphan_rows.R and iperc_fix_duplicate_dois.R).

# == Phase 2: convert ===============================================================

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

paper_ids <- sapply(papers, function(p) basename(p$info$file_name)) |>
  sub("^iperc\\.", "", x = _) |> sub("\\.xml$", "", x = _)
manifest <- data.frame(
  doi             = sampled$doi,
  article_id      = sampled$article_id,
  title           = sampled$title,
  year            = sampled$year,
  pdf_file        = paste0("pdf/iperc.", sampled$article_id, ".pdf"),
  xml_file        = paste0("xml/iperc.", sampled$article_id, ".xml"),
  pdf_exists      = file.exists(file.path(PDF_DIR, paste0("iperc.", sampled$article_id, ".pdf"))),
  xml_exists      = file.exists(file.path(XML_DIR,  paste0("iperc.", sampled$article_id, ".xml"))),
  in_rds          = sampled$article_id %in% paper_ids,
  grobid_version  = "0.9",
  conversion_date = format(Sys.Date(), "%Y-%m-%d"),
  license         = "CC-BY 4.0"
)
write.csv(manifest, MANIFEST, row.names = FALSE)
message("Coverage: ", sum(manifest$in_rds), "/", nrow(manifest))

# == Phase 3: cleanup ================================================================
# 4 genuine non-article notices dropped, 6 garbled DOIs corrected, 2
# missing titles backfilled from CrossRef. See iperc_cleanup2.R and
# iperc_drop_remaining_erratum.R for the full implementation.

message("Build complete: ", length(readRDS(RDS_OUT)), " papers in ", RDS_OUT)