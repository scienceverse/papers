# Build script: Journal of Sports Science and Medicine (JSSM) corpus
# for scienceverse/papers
#
# Produces:
#   jssm/pdf_index.csv   every discovered (volume, issue, startpage, url)
#   jssm/sample.csv        1,000 sampled articles
#   jssm/pdf/              1,000 PDF files (CC-BY 4.0 or CC-BY-NC-ND 4.0)
#   jssm/manifest.csv      one row per paper with provenance metadata
#   jssm.rds                metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: httr2, metacheck (scienceverse/metacheck)
#   metacheck::email() set to a valid address (not used for PDF download
#   here, but kept for parity with other build scripts)
#   GROBID 0.9 instance (used: https://grobid.work.abed.cloud)
#
# This corpus was built differently from the others in this repository.
# CrossRef's index for JSSM is sparse (470 DOIs total, almost none before
# ~2021), and the journal's "newarchives.php" browse page is a
# client-rendered SPA with no server-side content for plain HTTP
# requests. Instead:
#   Phase 1: crawl       - discover every article PDF directly from the
#                           site's own open directory listings
#                           (jssm.org/volume{N}/iss{1-4}/cap/, volumes
#                           13-25 only -- volumes 1-9 redirect to the
#                           homepage and are not reachable this way)
#   Phase 2: doi_match   - reconstruct each article's likely DOI from
#                           volume->year (year = volume + 2001) and start
#                           page (10.52082/jssm.{year}.{startpage}), query
#                           CrossRef for a verified title where possible
#   Phase 3: sample      - randomly sample 1,000 of ~1,132 candidates
#   Phase 4: download    - download all sampled PDFs directly from
#                           jssm.org (no Unpaywall needed -- the
#                           publisher's own site is the only OA copy and
#                           is directly reachable)
#   Phase 5: convert     - GROBID-convert PDFs, assemble RDS + manifest;
#                           papers with no CrossRef title get GROBID's own
#                           extracted title instead (title_source column)
#   Phase 6: replace_bad - 23 papers excluded after a full-corpus audit
#                           (1 retraction notice; 22 with no usable title
#                           from either CrossRef or GROBID) and replaced
#                           with fresh draws from the same candidate pool
#
# Network calls use ssl_options = 2 (CURLSSLOPT_NO_REVOKE) to disable
# Windows Schannel's per-connection OCSP/CRL revocation checks, which can
# hang indefinitely if a CA's revocation endpoint is slow or unreachable.

library(httr2)
suppressMessages(library(metacheck))

VOLUMES    <- 13:25   # corresponds to years 2014-2026
SEED       <- 20260620
N_TARGET   <- 1000
PDF_DIR    <- "jssm/pdf"
XML_DIR    <- "jssm/xml"
GROBID_URL <- "https://grobid.work.abed.cloud/api/processFulltextDocument"
RDS_OUT    <- "jssm.rds"
MANIFEST   <- "jssm/manifest.csv"
SAMPLE_CSV <- "jssm/sample.csv"
INDEX_CSV  <- "jssm/pdf_index.csv"

dir.create(PDF_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(XML_DIR, recursive = TRUE, showWarnings = FALSE)

is_nonarticle <- function(title) {
  grepl("(Correction|Retraction|Expression of Concern|Erratum|Withdrawal)(\\s+(Note|to|To))?:",
        title, ignore.case = TRUE) |
  grepl("^(Response|Reply) to [‘'\"]", title, ignore.case = TRUE) |
  grepl("commentary on", title, ignore.case = TRUE) |
  grepl("Reviewer and Editorial Board|^Call for Papers|^Editorial Board|^Editorial Note|^Acknowledge?ment|^Annual Report|Thank You|^Meeting [Rr]eport:",
        title, ignore.case = TRUE)
}

download_pdf <- function(url, dest) {
  ok <- tryCatch(
    request(url) |> req_headers(`User-Agent` = "Mozilla/5.0") |>
      req_timeout(30) |> req_options(connecttimeout = 10, ssl_options = 2) |>
      req_error(is_error = \(r) FALSE) |> req_perform(path = dest) |> resp_status() == 200,
    error = \(e) FALSE
  )
  if (ok) {
    header <- readBin(dest, "raw", n = 5)
    if (rawToChar(header) != "%PDF-") ok <- FALSE
  }
  if (!ok) unlink(dest)
  Sys.sleep(1)
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
  sampled$year <- as.integer(sampled$year); sampled$volume <- as.integer(sampled$volume)
  sampled$startpage <- as.integer(sampled$startpage)
  papers <- readRDS(RDS_OUT)
  paper_ids <- sapply(papers, function(p) basename(p$info$file_name)) |>
    sub("^jssm\\.", "", x = _) |> sub("\\.xml$", "", x = _)
  grobid_titles <- setNames(sapply(papers, function(p) p$info$title %||% NA_character_), paper_ids)

  final_title <- sampled$title
  needs_grobid <- is.na(final_title) | !nzchar(final_title)
  final_title[needs_grobid] <- grobid_titles[sampled$article_id[needs_grobid]]

  manifest <- data.frame(
    doi = sampled$doi, article_id = sampled$article_id, title = final_title,
    title_source = ifelse(!is.na(sampled$doi) & nzchar(sampled$doi), "crossref", "grobid"),
    year = sampled$year, volume = sampled$volume, startpage = sampled$startpage,
    pdf_file = paste0("pdf/jssm.", sampled$article_id, ".pdf"),
    xml_file = paste0("xml/jssm.", sampled$article_id, ".xml"),
    pdf_exists = file.exists(file.path(PDF_DIR, paste0("jssm.", sampled$article_id, ".pdf"))),
    xml_exists = file.exists(file.path(XML_DIR, paste0("jssm.", sampled$article_id, ".xml"))),
    in_rds = sampled$article_id %in% paper_ids,
    grobid_version = "0.9", conversion_date = format(Sys.Date(), "%Y-%m-%d"),
    license = "CC-BY 4.0 or CC-BY-NC-ND 4.0 -- check individual article"
  )
  write.csv(manifest, MANIFEST, row.names = FALSE)
  message("Coverage: ", sum(manifest$in_rds), "/", nrow(manifest))
}

# == Phase 1: crawl the site's own directory listings ===========================

list_issue_pdfs <- function(vol, iss) {
  url <- paste0("http://jssm.org/volume", vol, "/iss", iss, "/cap/")
  resp <- tryCatch(
    request(url) |> req_timeout(20) |> req_options(connecttimeout = 10, ssl_options = 2) |>
      req_error(is_error = \(r) FALSE) |> req_perform(),
    error = \(e) NULL
  )
  if (is.null(resp) || resp_status(resp) != 200) return(NULL)
  html <- resp_body_string(resp)
  hrefs <- regmatches(html, gregexpr('href="[^"]*\\.pdf"', html))[[1]]
  hrefs <- gsub('href="|"', "", hrefs)
  if (length(hrefs) == 0) return(NULL)
  startpage <- sub(paste0(".*jssm-", vol, "-(\\d+)\\.pdf$"), "\\1", hrefs)
  data.frame(volume = vol, issue = iss, startpage = as.integer(startpage),
             pdf_path = hrefs, stringsAsFactors = FALSE)
}

all_rows <- list()
for (vol in VOLUMES) for (iss in 1:4) {
  rows <- list_issue_pdfs(vol, iss)
  if (!is.null(rows)) all_rows[[paste(vol, iss)]] <- rows
  Sys.sleep(0.5)
}
index <- do.call(rbind, all_rows)
index <- index[!is.na(index$volume) & index$startpage != 0, ]
index$pdf_url <- paste0("http://jssm.org", index$pdf_path)
write.csv(index, INDEX_CSV, row.names = FALSE)
message("PDF index: ", nrow(index), " article PDFs found")

# == Phase 2: reconstruct DOI, query CrossRef for verified title ===============

index$year <- index$volume + 2001
index$doi  <- paste0("10.52082/jssm.", index$year, ".", index$startpage)

meta_rows <- list()
for (i in seq_len(nrow(index))) {
  resp <- tryCatch(
    request(paste0("https://api.crossref.org/works/", index$doi[i])) |>
      req_timeout(15) |> req_options(connecttimeout = 8, ssl_options = 2) |>
      req_error(is_error = \(r) FALSE) |> req_perform(),
    error = \(e) NULL
  )
  if (!is.null(resp) && resp_status(resp) == 200) {
    m <- resp_body_json(resp)$message
    meta_rows[[length(meta_rows) + 1]] <- data.frame(
      doi = index$doi[i], title = m$title[[1]] %||% NA_character_,
      year = index$year[i], volume = index$volume[i], startpage = index$startpage[i],
      pdf_url = index$pdf_url[i], stringsAsFactors = FALSE
    )
  }
  Sys.sleep(0.3)
}
meta <- do.call(rbind, meta_rows)
meta <- meta[!is.na(meta$title) & !is_nonarticle(meta$title), ]
message("CrossRef-confirmed: ", nrow(meta), " / ", nrow(index))

# == Phase 3: sample 1,000 from all candidates (confirmed + unconfirmed) ======

confirmed_keys <- paste(meta$volume, meta$startpage)
index$key <- paste(index$volume, index$startpage)
unconfirmed <- index[!(index$key %in% confirmed_keys), ]
unconfirmed$doi <- NA_character_
unconfirmed$title <- NA_character_

candidates <- rbind(meta[, c("doi","title","year","volume","startpage","pdf_url")],
                     unconfirmed[, c("doi","title","year","volume","startpage","pdf_url")])

set.seed(SEED)
sampled <- candidates[sample.int(nrow(candidates), min(N_TARGET, nrow(candidates))), ]
sampled$article_id <- ifelse(
  !is.na(sampled$doi),
  gsub("[^A-Za-z0-9]", "", sub("10.52082/jssm.", "", sampled$doi, fixed = TRUE)),
  paste0("v", sampled$volume, "p", sampled$startpage)
)
stopifnot(length(unique(sampled$article_id)) == nrow(sampled))
write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
message("Sampled: ", nrow(sampled))

# == Phase 4: download =========================================================

for (i in seq_len(nrow(sampled))) {
  dest <- file.path(PDF_DIR, paste0("jssm.", sampled$article_id[i], ".pdf"))
  if (file.exists(dest) && file.info(dest)$size > 10000) next
  download_pdf(sampled$pdf_url[i], dest)
}
message("PDFs on disk: ", length(list.files(PDF_DIR, pattern = "\\.pdf$")), " / ", nrow(sampled))

# == Phase 5: convert ===========================================================

convert_all()
papers <- grobid_to_bibr(XML_DIR, save_path = NULL)
saveRDS(papers, RDS_OUT)
write_manifest()

# == Phase 6: replace bad rows found by full-corpus audit ======================
# 1 retraction notice + 22 papers where GROBID failed to extract a usable
# title (regardless of whether a CrossRef DOI existed).

m <- read.csv(MANIFEST, stringsAsFactors = FALSE, colClasses = "character")
papers <- readRDS(RDS_OUT)
fnames <- sapply(papers, function(p) basename(p$info$file_name))
ids <- sub("^jssm\\.", "", fnames) |> sub("\\.xml$", "", x = _)
title_len <- sapply(papers, function(p) nchar(p$info$title %||% ""))
total_chars <- sapply(papers, function(p) sum(nchar(p$text$text %||% ""), na.rm = TRUE))
bad_quality <- ids[title_len == 0 | total_chars < 3000]
bad_retraction <- m$article_id[grepl("^RETRACTION", m$title, ignore.case = TRUE)]
bad_ids <- union(bad_quality, bad_retraction)

if (length(bad_ids) > 0) {
  sampled <- read.csv(SAMPLE_CSV, stringsAsFactors = FALSE, colClasses = "character")
  sampled$volume <- as.integer(sampled$volume); sampled$startpage <- as.integer(sampled$startpage)
  already <- paste(sampled$volume, sampled$startpage)
  index$key <- paste(index$volume, index$startpage)
  unmatched <- index[!(index$key %in% already), ]

  set.seed(SEED)
  picked <- unmatched[sample.int(nrow(unmatched), length(bad_ids)), ]
  picked$year <- picked$volume + 2001
  picked$doi <- NA_character_; picked$title <- NA_character_
  picked$article_id <- paste0("v", picked$volume, "p", picked$startpage)

  new_rows <- picked[, c("doi","title","year","volume","startpage","pdf_url","article_id")]
  sampled <- sampled[!(sampled$article_id %in% bad_ids), names(new_rows)]
  sampled <- rbind(sampled, new_rows)
  write.csv(sampled, SAMPLE_CSV, row.names = FALSE)

  for (id in bad_ids) {
    unlink(file.path(PDF_DIR, paste0("jssm.", id, ".pdf")))
    unlink(file.path(XML_DIR, paste0("jssm.", id, ".xml")))
  }
  for (i in seq_len(nrow(picked))) {
    dest <- file.path(PDF_DIR, paste0("jssm.", picked$article_id[i], ".pdf"))
    download_pdf(picked$pdf_url[i], dest)
  }

  convert_all()
  papers <- grobid_to_bibr(XML_DIR, save_path = NULL)
  saveRDS(papers, RDS_OUT)
  write_manifest()
}

message("Build complete: ", length(readRDS(RDS_OUT)), " papers in ", RDS_OUT)