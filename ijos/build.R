# Build script: International Journal of Oral Science corpus for
# scienceverse/papers
#
# Produces:
#   ijos/sample.csv      the sampled DOIs (complete corpus, not a sample)
#   ijos/pdf/             724 PDF files (mostly CC-BY 4.0, some CC-BY-NC-ND)
#   ijos/manifest.csv    one row per paper with provenance metadata
#   ijos.rds              metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: httr2, metacheck (scienceverse/metacheck)
#   metacheck::email() set to a valid address for Unpaywall API
#   GROBID 0.9 instance (used: https://grobid.work.abed.cloud)
#
# IJOS has fewer than 1,000 articles total, so this is a COMPLETE corpus
# (every available open-access article), not a stratified sample.
#
# Open access via Springer Nature; published-version PDFs are served from
# nature.com with no Cloudflare-style bot protection -- httr2's default
# req_perform() follows the redirect/cookie chain automatically.
#
# Phases, reflecting the pipeline as actually run:
#   Phase 1: download         - fetch all DOIs, filter non-articles, download
#   Phase 2: fix_duplicates   - drop 2 duplicate DOI registrations of the
#                                same articles found in the CrossRef data
#   Phase 3: retry_missing    - recover articles with no Unpaywall PDF url
#                                by resolving the doi.org redirect to find
#                                Nature's real article slug
#   Phase 4: convert          - GROBID-convert PDFs, assemble RDS + manifest
#   Phase 5: doi_correction   - overwrite GROBID's unreliable header DOI
#                                with the verified CrossRef sample DOI

library(httr2)
suppressMessages(library(metacheck))

ISSN       <- "2049-3169"   # International Journal of Oral Science
EMAIL      <- metacheck::email()
YEARS      <- 2009:2026
PDF_DIR    <- "ijos/pdf"
XML_DIR    <- "ijos/xml"
GROBID_URL <- "https://grobid.work.abed.cloud/api/processFulltextDocument"
RDS_OUT    <- "ijos.rds"
MANIFEST   <- "ijos/manifest.csv"
SAMPLE_CSV <- "ijos/sample.csv"

dir.create(PDF_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(XML_DIR, recursive = TRUE, showWarnings = FALSE)

is_nonarticle <- function(title) {
  grepl("(Correction|Retraction|Expression of Concern|Erratum|Withdrawal)(\\s+(Note|to|To))?:",
        title, ignore.case = TRUE) |
  grepl("^(Response|Reply) to [‘'\"]", title, ignore.case = TRUE) |
  grepl("commentary on", title, ignore.case = TRUE) |
  grepl("Reviewer and Editorial Board|^Call for Papers|^Editorial Board|^Acknowledge?ment|^Annual Report|Thank You",
        title, ignore.case = TRUE) |
  grepl("^Meeting [Rr]eport:", title)
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

# == Phase 1: download ==========================================================

message("Fetching CrossRef DOIs for ", length(YEARS), " years...")
dois_df <- do.call(rbind, lapply(YEARS, \(yr) {
  Sys.sleep(1)
  items <- fetch_year(yr)
  message("  ", yr, ": ", length(items), " journal articles")
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
sampled$article_id <- gsub("[^A-Za-z0-9]", "", sub("^10\\.\\d+/", "", sampled$doi))
write.csv(sampled, SAMPLE_CSV, row.names = FALSE)

for (i in seq_len(nrow(sampled))) {
  dest <- file.path(PDF_DIR, paste0("ijos.", sampled$article_id[i], ".pdf"))
  if (file.exists(dest) && file.info(dest)$size > 10000) next
  pdf_url <- get_pdf_url(sampled$doi[i])
  if (!is.null(pdf_url)) download_pdf(pdf_url, dest)
  Sys.sleep(1)
}
message("PDFs on disk: ", length(list.files(PDF_DIR, pattern = "\\.pdf$")), " / ", nrow(sampled))

# == Phase 2: fix duplicate DOI registrations ===================================
# CrossRef has two DOIs for some early articles, e.g. 10.4248/ijos.09061 and
# 10.4248/ijos09061 -- a dotted and undotted registration of the same piece.
# Stripping non-alphanumeric characters for article_id collapses both to the
# same filename, so drop the dotted ("with separators") duplicate of each pair.

sampled <- read.csv(SAMPLE_CSV, stringsAsFactors = FALSE)
dup_doi_pairs <- c("10.4248/ijos.09061", "10.4248/ijos.09019")
dup_doi_pairs <- intersect(dup_doi_pairs, sampled$doi)
if (length(dup_doi_pairs) > 0) {
  sampled <- sampled[!(sampled$doi %in% dup_doi_pairs), ]
  write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
  message("Dropped ", length(dup_doi_pairs), " duplicate DOI registration(s)")
}
stopifnot(length(unique(sampled$article_id)) == nrow(sampled))

# == Phase 3: retry missing (no Unpaywall url) ===================================
# Unpaywall's crawler lags behind very recent publications; when is_oa is
# true but url_for_pdf is empty, the article is usually still downloadable
# directly from the publisher -- resolve the real article slug from the
# doi.org redirect rather than guessing Nature's URL pattern (which is NOT
# uniform: old-style DOIs strip dots, new-style DOIs keep dashes).

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

have <- list.files(PDF_DIR, pattern = "\\.pdf$")
have_ids <- sub("^ijos\\.", "", have) |> sub("\\.pdf$", "", x = _)
missing <- sampled[!(sampled$article_id %in% have_ids), ]
for (i in seq_len(nrow(missing))) {
  slug <- resolve_nature_slug(missing$doi[i])
  if (is.na(slug)) next
  dest <- file.path(PDF_DIR, paste0("ijos.", missing$article_id[i], ".pdf"))
  download_pdf(paste0("https://www.nature.com/articles/", slug, ".pdf"), dest)
  Sys.sleep(1)
}
message("PDFs on disk after retry: ", length(list.files(PDF_DIR, pattern = "\\.pdf$")), " / ", nrow(sampled))

# == Phase 4: convert ============================================================

pdfs <- list.files(PDF_DIR, pattern = "\\.pdf$", full.names = TRUE)
already_xml <- tools::file_path_sans_ext(basename(list.files(XML_DIR, pattern = "\\.xml$")))
for (pdf in pdfs) {
  stem <- tools::file_path_sans_ext(basename(pdf))
  if (stem %in% already_xml) next
  out_xml <- file.path(XML_DIR, paste0(stem, ".xml"))
  tryCatch(convert_grobid(pdf, save_path = out_xml, api_url = GROBID_URL),
           error = function(e) message("ERROR ", stem, ": ", e$message))
  # note: 3 PDFs exceed GROBID's upload size limit ("Payload Too Large")
  # and 1 PDF (ijos.2013.73) has a malformed internal structure GROBID
  # consistently rejects -- both are documented, accepted exclusions
}

papers <- grobid_to_bibr(XML_DIR, save_path = NULL)
saveRDS(papers, RDS_OUT)
message("RDS saved: ", length(papers), " papers -> ", RDS_OUT)

paper_ids <- sapply(papers, function(p) basename(p$info$file_name)) |>
  sub("^ijos\\.", "", x = _) |> sub("\\.xml$", "", x = _)
manifest <- data.frame(
  doi             = sampled$doi,
  article_id      = sampled$article_id,
  title           = sampled$title,
  year            = sampled$year,
  pdf_file        = paste0("pdf/ijos.", sampled$article_id, ".pdf"),
  xml_file        = paste0("xml/ijos.", sampled$article_id, ".xml"),
  pdf_exists      = file.exists(file.path(PDF_DIR, paste0("ijos.", sampled$article_id, ".pdf"))),
  xml_exists      = file.exists(file.path(XML_DIR,  paste0("ijos.", sampled$article_id, ".xml"))),
  in_rds          = sampled$article_id %in% paper_ids,
  grobid_version  = "0.9",
  conversion_date = format(Sys.Date(), "%Y-%m-%d"),
  license         = "Mostly CC-BY 4.0; some CC-BY-NC-ND -- check individual article"
)
write.csv(manifest, MANIFEST, row.names = FALSE)
message("Coverage: ", sum(manifest$in_rds), "/", nrow(manifest))

# == Phase 5: DOI correction =====================================================
# GROBID's header-extracted DOI was unreliable for 87 articles (case
# mismatches and a few truncated DOI strings). Overwrite from the known
# CrossRef sample DOI rather than trusting GROBID's extraction.

papers <- readRDS(RDS_OUT)
fnames <- sapply(papers, function(p) basename(p$info$file_name))
ids <- sub("^ijos\\.", "", fnames) |> sub("\\.xml$", "", x = _)
doi_lookup <- setNames(sampled$doi, sampled$article_id)
for (i in seq_along(papers)) papers[[i]]$info$doi <- doi_lookup[[ids[i]]]
saveRDS(papers, RDS_OUT)

message("Build complete: ", length(readRDS(RDS_OUT)), " papers in ", RDS_OUT)