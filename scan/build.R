# Build script: Social Cognitive and Affective Neuroscience (SCAN)
# corpus for scienceverse/papers
#
# Produces:
#   scan/sample.csv   the sampled DOIs (100/year target, 2017-2026)
#   scan/pdf/         803 PDF files (mixed CC-BY/CC-BY-NC/CC-BY-NC-ND/public domain)
#   scan/manifest.csv one row per paper with provenance metadata
#   scan.rds          metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: httr2, metacheck (scienceverse/metacheck)
#   metacheck::email() set to a valid address for Unpaywall API
#   GROBID 0.9 instance (used: https://grobid.work.abed.cloud)
#
# SCAN publishes more articles per year than fit a complete corpus, so
# this is a STRATIFIED RANDOM SAMPLE (100/year target, 2017-2026).
#
# Unlike most other corpora in this repository, SCAN is a HYBRID
# journal -- not every article is open access. Each sampled article's
# OA status is verified individually via Unpaywall rather than assumed.
#
# OUP's direct PDF host (academic.oup.com) is behind a Cloudflare JS
# challenge that blocks automated downloads even for genuinely
# open-access articles, so PDFs are retrieved via each article's Europe
# PMC deposit instead.
#
# Phases, reflecting the pipeline as actually run:
#   Phase 1: download           - sample 100 DOIs/year, verify OA via
#                                  Unpaywall, download via Europe PMC
#   Phase 2: replace_oversized  - 50 PDFs exceeded GROBID's upload size
#                                  limit; resample same-year replacements
#                                  via Europe PMC (only 14/50 found --
#                                  sparse deposit coverage for some years)
#   Phase 3: convert            - GROBID-convert PDFs, assemble RDS + manifest
#   Phase 4: audit_nonarticles  - full-corpus audit found 9 articles that
#                                  were actually correction/erratum/
#                                  editorial notices not caught by the
#                                  title filter; replace via Europe PMC
#                                  (8/9 found)
#   Phase 5: cleanup            - correct 109 garbled/missing GROBID DOIs,
#                                  backfill 4 missing titles from CrossRef

library(httr2)
suppressMessages(library(metacheck))

ISSN       <- "1749-5016"   # Social Cognitive and Affective Neuroscience
EMAIL      <- metacheck::email()
YEARS      <- 2017:2026
N_PER_YEAR <- 100
SEED       <- 20260620
PDF_DIR    <- "scan/pdf"
XML_DIR    <- "scan/xml"
GROBID_URL <- "https://grobid.work.abed.cloud/api/processFulltextDocument"
RDS_OUT    <- "scan.rds"
MANIFEST   <- "scan/manifest.csv"
SAMPLE_CSV <- "scan/sample.csv"

dir.create(PDF_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(XML_DIR, recursive = TRUE, showWarnings = FALSE)

is_nonarticle <- function(title) {
  grepl("(Correction|Retraction|Expression of Concern|Erratum|Withdrawal|Corrigendum|Addendum|Publisher.s Note)(\\s+(Note|to|To))?:?",
        title, ignore.case = TRUE) |
  grepl("^(Response|Reply) to [‘'\"]", title, ignore.case = TRUE) |
  grepl("commentary on", title, ignore.case = TRUE) |
  grepl("Reviewer and Editorial Board|^Call for Papers|^Editorial Board|^Editorial Note|^Acknowledge?ment|^Annual Report|Thank You|^Meeting [Rr]eport:",
        title, ignore.case = TRUE) |
  grepl("the college years$|^Author Correction:|^Publisher Correction:", title, ignore.case = TRUE) |
  grepl("gears up for|^In [Mm]emoriam", title, ignore.case = TRUE)
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

# == Phase 1: download ============================================================

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
sampled$article_id <- gsub("[^A-Za-z0-9]", "", sub("^10\\.1093/", "", sampled$doi))
stopifnot(length(unique(sampled$article_id)) == nrow(sampled))
sampled$is_oa <- NA
sampled$license <- NA_character_
write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
message("Sampled: ", nrow(sampled), " articles (", N_PER_YEAR, "/year target)")

for (i in seq_len(nrow(sampled))) {
  doi    <- sampled$doi[i]
  art_id <- sampled$article_id[i]
  dest   <- file.path(PDF_DIR, paste0("scan.", art_id, ".pdf"))
  if (file.exists(dest) && file.info(dest)$size > 10000) next

  oa <- check_oa(doi)
  sampled$is_oa[i] <- oa$is_oa
  sampled$license[i] <- oa$license
  if (!isTRUE(oa$is_oa)) next

  pmcid <- get_pmcid(doi)
  if (is.null(pmcid)) next

  pdf_url <- paste0("https://europepmc.org/articles/", pmcid, "?pdf=render")
  download_pdf(pdf_url, dest)
  Sys.sleep(1)
}
write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
message("PDFs on disk: ", length(list.files(PDF_DIR, pattern = "\\.pdf$")), " / ", nrow(sampled))

# NOTE: at this point in the actual build, 50 oversized PDFs and 9
# non-article notices were each identified and partially replaced --
# see scan_replace_oversized.R and scan_replace_nonarticles.R for the
# resample-and-replace logic (only 14/50 and 8/9 replacements were
# found, respectively, due to sparse Europe PMC deposit coverage for
# some years).

# == Phase 2: convert ==============================================================

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
  sub("^scan\\.", "", x = _) |> sub("\\.xml$", "", x = _)
manifest <- data.frame(
  doi             = sampled$doi,
  article_id      = sampled$article_id,
  title           = sampled$title,
  year            = sampled$year,
  license         = sampled$license,
  pdf_file        = paste0("pdf/scan.", sampled$article_id, ".pdf"),
  xml_file        = paste0("xml/scan.", sampled$article_id, ".xml"),
  pdf_exists      = file.exists(file.path(PDF_DIR, paste0("scan.", sampled$article_id, ".pdf"))),
  xml_exists      = file.exists(file.path(XML_DIR,  paste0("scan.", sampled$article_id, ".xml"))),
  in_rds          = sampled$article_id %in% paper_ids,
  grobid_version  = "0.9",
  conversion_date = format(Sys.Date(), "%Y-%m-%d")
)
write.csv(manifest, MANIFEST, row.names = FALSE)
message("Coverage: ", sum(manifest$in_rds), "/", nrow(manifest))

# == Phase 3: cleanup ===============================================================
# 109 articles had a missing/truncated/wrong GROBID-extracted DOI
# (corrected from the verified CrossRef sample DOI); 4 articles had
# real, substantial body text but no GROBID-extracted title (backfilled
# from CrossRef's bibliographic title for that DOI). See
# scan_cleanup2.R for the full implementation of this phase.

message("Build complete: ", length(readRDS(RDS_OUT)), " papers in ", RDS_OUT)