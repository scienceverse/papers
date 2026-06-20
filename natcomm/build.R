# Build script: Nature Communications corpus for scienceverse/papers
#
# Produces:
#   natcomm/sample.csv   the sampled DOIs (100/year, 2017-2026)
#   natcomm/pdf/         1000 PDF files (mostly CC-BY 4.0, some CC-BY-NC-ND)
#   natcomm/manifest.csv one row per paper with provenance metadata
#   natcomm.rds          metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: httr2, metacheck (scienceverse/metacheck)
#   metacheck::email() set to a valid address for Unpaywall API
#   GROBID 0.9 instance (used: https://grobid.work.abed.cloud)
#
# Nature Communications publishes thousands of articles per year, so this
# is a STRATIFIED RANDOM SAMPLE (100/year, 2017-2026), not a complete
# corpus.
#
# Open access via Springer Nature; published-version PDFs are served from
# nature.com with no Cloudflare-style bot protection.
#
# Phases, reflecting the pipeline as actually run:
#   Phase 1: download       - sample 100 DOIs/year, download via Unpaywall
#                              with doi.org-redirect-resolved fallback
#   Phase 2: convert        - GROBID-convert PDFs, assemble RDS + manifest
#   Phase 3: cleanup        - replace 1 non-article ("Addendum: ..."
#                              notice not caught by the title filter),
#                              correct 1 garbled GROBID-extracted DOI,
#                              backfill 22 missing titles from CrossRef

library(httr2)
suppressMessages(library(metacheck))

ISSN       <- "2041-1723"   # Nature Communications
EMAIL      <- metacheck::email()
YEARS      <- 2017:2026
N_PER_YEAR <- 100
SEED       <- 20260620
PDF_DIR    <- "natcomm/pdf"
XML_DIR    <- "natcomm/xml"
GROBID_URL <- "https://grobid.work.abed.cloud/api/processFulltextDocument"
RDS_OUT    <- "natcomm.rds"
MANIFEST   <- "natcomm/manifest.csv"
SAMPLE_CSV <- "natcomm/sample.csv"

dir.create(PDF_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(XML_DIR, recursive = TRUE, showWarnings = FALSE)

is_nonarticle <- function(title) {
  grepl("(Correction|Retraction|Expression of Concern|Erratum|Withdrawal|Addendum)(\\s+(Note|to|To))?:",
        title, ignore.case = TRUE) |
  grepl("^(Response|Reply) to [‘'\"]", title, ignore.case = TRUE) |
  grepl("commentary on", title, ignore.case = TRUE) |
  grepl("Reviewer and Editorial Board|^Call for Papers|^Editorial Board|^Editorial Note|^Acknowledge?ment|^Annual Report|Thank You|^Meeting [Rr]eport:",
        title, ignore.case = TRUE) |
  grepl("^Author Correction:|^Publisher Correction:", title, ignore.case = TRUE)
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

resolve_nature_slug <- function(doi) {
  resp <- tryCatch(
    request(paste0("https://doi.org/", doi)) |>
      req_headers(`User-Agent` = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36") |>
      req_options(followlocation = FALSE) |>
      req_timeout(15) |> req_error(is_error = \(r) FALSE) |> req_perform(),
    error = \(e) NULL
  )
  loc <- resp$headers$location %||% NA_character_
  m <- regmatches(loc, regexpr("articles/[^&?]+", loc))
  if (length(m) == 0 || !nzchar(m)) return(NA_character_)
  sub("^articles/", "", m)
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

set.seed(SEED)
sampled <- do.call(rbind, lapply(YEARS, \(yr) {
  pool <- dois_df[dois_df$year == yr, ]
  n <- min(N_PER_YEAR, nrow(pool))
  pool[sample.int(nrow(pool), n), ]
}))
sampled$article_id <- gsub("[^A-Za-z0-9]", "", sub("^10\\.1038/", "", sampled$doi))
stopifnot(length(unique(sampled$article_id)) == nrow(sampled))
write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
message("Sampled: ", nrow(sampled), " articles (", N_PER_YEAR, "/year target)")

for (i in seq_len(nrow(sampled))) {
  doi    <- sampled$doi[i]
  art_id <- sampled$article_id[i]
  dest   <- file.path(PDF_DIR, paste0("natcomm.", art_id, ".pdf"))
  if (file.exists(dest) && file.info(dest)$size > 10000) next

  pdf_url <- tryCatch({
    resp <- request(paste0("https://api.unpaywall.org/v2/", doi, "?email=", EMAIL)) |>
      req_timeout(15) |> req_options(connecttimeout = 8, ssl_options = 2) |>
      req_error(is_error = \(r) FALSE) |> req_perform()
    if (resp_status(resp) == 200) resp_body_json(resp)[["best_oa_location"]][["url_for_pdf"]] else NULL
  }, error = \(e) NULL)

  ok <- FALSE
  if (!is.null(pdf_url) && nzchar(pdf_url)) ok <- download_pdf(pdf_url, dest)
  if (!ok) {
    slug <- resolve_nature_slug(doi)
    if (!is.na(slug)) ok <- download_pdf(paste0("https://www.nature.com/articles/", slug, ".pdf"), dest)
  }
  Sys.sleep(1)
}
message("PDFs on disk: ", length(list.files(PDF_DIR, pattern = "\\.pdf$")), " / ", nrow(sampled))

# NOTE: at this point in the actual build, 18 in-press 2026 articles and 7
# GROBID-conversion failures (6 oversized PDFs, 1 transient error) were
# each replaced with a fresh same-year draw -- see natcomm_replace_missing.R
# and natcomm_replace_oversized.R for the resample-and-replace logic.

# == Phase 2: convert =============================================================

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
  sub("^natcomm\\.", "", x = _) |> sub("\\.xml$", "", x = _)
manifest <- data.frame(
  doi             = sampled$doi,
  article_id      = sampled$article_id,
  title           = sampled$title,
  year            = sampled$year,
  pdf_file        = paste0("pdf/natcomm.", sampled$article_id, ".pdf"),
  xml_file        = paste0("xml/natcomm.", sampled$article_id, ".xml"),
  pdf_exists      = file.exists(file.path(PDF_DIR, paste0("natcomm.", sampled$article_id, ".pdf"))),
  xml_exists      = file.exists(file.path(XML_DIR,  paste0("natcomm.", sampled$article_id, ".xml"))),
  in_rds          = sampled$article_id %in% paper_ids,
  grobid_version  = "0.9",
  conversion_date = format(Sys.Date(), "%Y-%m-%d"),
  license         = "CC-BY 4.0 or CC-BY-NC-ND 4.0 -- check individual article"
)
write.csv(manifest, MANIFEST, row.names = FALSE)
message("Coverage: ", sum(manifest$in_rds), "/", nrow(manifest))

# == Phase 3: cleanup =============================================================
# 1 article was an "Addendum: ..." notice not caught by the title filter
# (replaced with a fresh same-year draw); 1 article had a garbled
# GROBID-extracted DOI (a "Matters Arising" commentary -- corrected from
# the verified CrossRef sample DOI); 22 articles had real, substantial
# body text but no GROBID-extracted title (backfilled from CrossRef's
# bibliographic title for that DOI). See natcomm_cleanup.R for the full
# implementation of this phase.

message("Build complete: ", length(readRDS(RDS_OUT)), " papers in ", RDS_OUT)