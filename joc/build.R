# Build script: Journal of Cognition corpus for scienceverse/papers
#
# Produces:
#   joc/sample.csv   the sampled DOIs (complete corpus, not a sample)
#   joc/pdf/         447 PDF files (CC-BY 4.0)
#   joc/manifest.csv one row per paper with provenance metadata
#   joc.rds          metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: httr2, metacheck (scienceverse/metacheck)
#   GROBID 0.9 instance (used: https://grobid.work.abed.cloud)
#
# Journal of Cognition has only ~457 articles total (2017-2026), so this
# is a COMPLETE corpus, not a stratified sample.
#
# Open access via Ubiquity Press / OJS (Open Journal Systems). Unpaywall's
# reported "galley/download" URL for this journal redirects to the site's
# generic articles-listing page, not the actual PDF -- the real PDF link
# must be scraped from each article's own landing page.
#
# Phases, reflecting the pipeline as actually run:
#   Phase 1: download  - fetch all DOIs, filter non-articles, scrape PDF
#                         link from landing page HTML, download
#   Phase 2: convert   - GROBID-convert PDFs, assemble RDS + manifest
#   Phase 3: cleanup   - correct 5 missing/wrong GROBID-extracted DOIs,
#                         backfill 10 missing titles from CrossRef

library(httr2)
library(metacheck)

ISSN       <- "2514-4820"   # Journal of Cognition
YEARS      <- 2017:2026
PDF_DIR    <- "joc/pdf"
XML_DIR    <- "joc/xml"
GROBID_URL <- "https://grobid.work.abed.cloud/api/processFulltextDocument"
RDS_OUT    <- "joc.rds"
MANIFEST   <- "joc/manifest.csv"
SAMPLE_CSV <- "joc/sample.csv"

dir.create(PDF_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(XML_DIR, recursive = TRUE, showWarnings = FALSE)

is_nonarticle <- function(title) {
  grepl("(Correction|Retraction|Expression of Concern|Erratum|Withdrawal)(\\s+(Note|to|To))?:",
        title, ignore.case = TRUE) |
  grepl("^(Response|Reply) to [‘'\"]", title, ignore.case = TRUE) |
  grepl("commentary on", title, ignore.case = TRUE) |
  grepl("Reviewer and Editorial Board|^Call for Papers|^Editorial Board|^Editorial Note|^Acknowledge?ment|^Annual Report|Thank You|^Meeting [Rr]eport:",
        title, ignore.case = TRUE) |
  grepl("the college years$|^Author Correction:|^Publisher Correction:", title, ignore.case = TRUE)
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

find_pdf_url <- function(doi) {
  landing_url <- paste0("https://www.journalofcognition.org/articles/", doi)
  resp <- tryCatch(
    request(landing_url) |> req_headers(`User-Agent` = "Mozilla/5.0") |>
      req_timeout(20) |> req_options(connecttimeout = 10, ssl_options = 2) |>
      req_error(is_error = \(r) FALSE) |> req_perform(),
    error = \(e) NULL
  )
  if (is.null(resp) || resp_status(resp) != 200) return(NULL)
  html <- resp_body_string(resp)
  m <- regmatches(html, regexpr('href="[^"]*\\.pdf[^"]*"', html))
  if (length(m) == 0 || !nzchar(m)) return(NULL)
  href <- gsub('href="|"', "", m)
  if (grepl("^https?://", href)) return(href)
  paste0("https://www.journalofcognition.org", href)
}

# == Phase 1: download ===========================================================

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

sampled <- dois_df
sampled$article_id <- gsub("[^A-Za-z0-9]", "", sub("^10\\.5334/", "", sampled$doi))
stopifnot(length(unique(sampled$article_id)) == nrow(sampled))
write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
message("Sample written: ", nrow(sampled), " articles -- complete corpus, no sampling")

for (i in seq_len(nrow(sampled))) {
  doi    <- sampled$doi[i]
  art_id <- sampled$article_id[i]
  dest   <- file.path(PDF_DIR, paste0("joc.", art_id, ".pdf"))
  if (file.exists(dest) && file.info(dest)$size > 10000) next

  pdf_url <- find_pdf_url(doi)
  if (is.null(pdf_url)) next

  ok <- tryCatch(
    request(pdf_url) |>
      req_headers(`User-Agent` = "Mozilla/5.0") |>
      req_timeout(30) |> req_options(connecttimeout = 10, ssl_options = 2) |>
      req_error(is_error = \(r) FALSE) |>
      req_perform(path = dest) |> resp_status() == 200,
    error = \(e) FALSE
  )
  if (ok) {
    header <- readBin(dest, "raw", n = 5)
    if (rawToChar(header) != "%PDF-") { ok <- FALSE; unlink(dest) }
  }
  if (!ok) unlink(dest)
  Sys.sleep(1)
}
message("PDFs on disk: ", length(list.files(PDF_DIR, pattern = "\\.pdf$")), " / ", nrow(sampled))

# == Phase 1b: Europe PMC fallback for landing pages with a broken/missing ==
# == PDF link =================================================================
# joc.84's PDF returned a persistent GCS AccessDenied error directly
# from the publisher's storage bucket (not transient -- excluded, no
# replacement, since this is a complete corpus). joc.136 had the same
# broken landing-page link but was recovered via its Europe PMC
# deposit instead. Call this for any DOI still missing after Phase 1.

recover_via_europepmc <- function(doi, art_id) {
  dest <- file.path(PDF_DIR, paste0("joc.", art_id, ".pdf"))
  resp <- tryCatch(
    request("https://www.ebi.ac.uk/europepmc/webservices/rest/search") |>
      req_url_query(query = paste0("DOI:", doi), format = "json") |>
      req_timeout(15) |> req_error(is_error = \(r) FALSE) |> req_perform(),
    error = \(e) NULL
  )
  if (is.null(resp) || resp_status(resp) != 200) return(FALSE)
  res <- resp_body_json(resp)$resultList$result
  if (length(res) == 0 || !identical(res[[1]]$hasPDF, "Y")) return(FALSE)
  pmcid <- res[[1]]$pmcid
  ok <- tryCatch(
    request(paste0("https://europepmc.org/articles/", pmcid, "?pdf=render")) |>
      req_headers(`User-Agent` = "Mozilla/5.0") |>
      req_timeout(30) |> req_error(is_error = \(r) FALSE) |>
      req_perform(path = dest) |> resp_status() == 200,
    error = \(e) FALSE
  )
  if (ok) {
    header <- readBin(dest, "raw", n = 5)
    if (rawToChar(header) != "%PDF-") ok <- FALSE
  }
  if (!ok) unlink(dest)
  ok
}

# == Phase 2: convert =============================================================

pdfs <- list.files(PDF_DIR, pattern = "\\.pdf$", full.names = TRUE)
already_xml <- tools::file_path_sans_ext(basename(list.files(XML_DIR, pattern = "\\.xml$")))
for (pdf in pdfs) {
  stem <- tools::file_path_sans_ext(basename(pdf))
  if (stem %in% already_xml) next
  out_xml <- file.path(XML_DIR, paste0(stem, ".xml"))
  tryCatch(convert_grobid(pdf, save_path = out_xml, api_url = GROBID_URL),
           error = function(e) message("ERROR ", stem, ": ", e$message))
  # note: joc.316 exceeds GROBID's upload size limit ("Payload Too
  # Large") -- a documented, accepted exclusion since this is a complete
  # corpus, not resampled
}

papers <- grobid_to_bibr(XML_DIR, save_path = NULL)
saveRDS(papers, RDS_OUT)
message("RDS saved: ", length(papers), " papers -> ", RDS_OUT)

paper_ids <- sapply(papers, function(p) basename(p$info$file_name)) |>
  sub("^joc\\.", "", x = _) |> sub("\\.xml$", "", x = _)
manifest <- data.frame(
  doi             = sampled$doi,
  article_id      = sampled$article_id,
  title           = sampled$title,
  year            = sampled$year,
  pdf_file        = paste0("pdf/joc.", sampled$article_id, ".pdf"),
  xml_file        = paste0("xml/joc.", sampled$article_id, ".xml"),
  pdf_exists      = file.exists(file.path(PDF_DIR, paste0("joc.", sampled$article_id, ".pdf"))),
  xml_exists      = file.exists(file.path(XML_DIR,  paste0("joc.", sampled$article_id, ".xml"))),
  in_rds          = sampled$article_id %in% paper_ids,
  grobid_version  = "0.9",
  conversion_date = format(Sys.Date(), "%Y-%m-%d"),
  license         = "CC-BY 4.0"
)
write.csv(manifest, MANIFEST, row.names = FALSE)
message("Coverage: ", sum(manifest$in_rds), "/", nrow(manifest))

# == Phase 3: cleanup =============================================================
# 5 articles had a missing or wrong GROBID-extracted DOI (one had picked
# up an unrelated journal's DOI from a reference citation); overwritten
# from the verified CrossRef sample DOI. 10 articles had real, substantial
# body text but no GROBID-extracted title; backfilled from CrossRef's
# bibliographic title for that DOI.

papers <- readRDS(RDS_OUT)
fnames <- sapply(papers, function(p) basename(p$info$file_name))
ids    <- sub("^joc\\.", "", fnames) |> sub("\\.xml$", "", x = _)

sample_doi   <- setNames(sampled$doi, sampled$article_id)
sample_title <- setNames(sampled$title, sampled$article_id)

n_doi_fixed <- n_title_fixed <- 0
for (i in seq_along(papers)) {
  expected_doi <- sample_doi[[ids[i]]]
  actual_doi   <- papers[[i]]$info$doi
  if (is.null(actual_doi) || !nzchar(actual_doi) || !identical(tolower(actual_doi), tolower(expected_doi %||% ""))) {
    papers[[i]]$info$doi <- expected_doi
    n_doi_fixed <- n_doi_fixed + 1
  }
  if (!nzchar(papers[[i]]$info$title %||% "")) {
    papers[[i]]$info$title <- sample_title[[ids[i]]]
    n_title_fixed <- n_title_fixed + 1
  }
}
message("Corrected DOI for ", n_doi_fixed, " papers; backfilled title for ", n_title_fixed)
saveRDS(papers, RDS_OUT)

message("Build complete: ", length(papers), " papers in ", RDS_OUT)