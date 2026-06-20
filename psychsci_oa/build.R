# Build script: Psychological Science open-access subset corpus for
# scienceverse/papers
#
# Unlike the other corpora in this repository, this one starts from a
# pre-existing local collection of Psychological Science PDFs (not a
# fresh CrossRef sample), since most articles in this journal are not
# open access and SAGE's universal text-and-data-mining license does not
# permit redistribution.
#
# Produces:
#   psychsci_oa/sample.csv     the 270 open-access articles + license info
#   psychsci_oa/pdf/           270 PDF files (CC-BY 4.0 or CC-BY-NC 4.0/3.0)
#   psychsci_oa/manifest.csv   one row per paper with provenance metadata
#   psychsci_oa.rds             metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: httr2, metacheck (scienceverse/metacheck)
#   GROBID 0.9 instance (used: https://grobid.work.abed.cloud)
#   A pre-existing local folder of Psychological Science PDFs, named by
#   DOI suffix under the SAGE prefix 10.1177/ (this script does not
#   download them -- that collection must already exist)
#
# Phases, reflecting the pipeline as actually run:
#   Phase 1: license_check  - query CrossRef's license field for every
#                              PDF's DOI; classify as open only if a
#                              creativecommons.org URL is present
#                              (SAGE's TDM-only license does not count)
#   Phase 2: filter_copy    - copy the open-access subset into this
#                              corpus's own pdf/ folder, look up each
#                              article's real publication year from
#                              CrossRef
#   Phase 3: convert        - GROBID-convert PDFs, assemble RDS + manifest
#   Phase 4: doi_correction - overwrite GROBID's unreliable header DOI
#                              with the verified CrossRef DOI
#   Phase 5: cleanup        - 1 non-article (an "Erratum to ..." notice)
#                              excluded; 2 papers with real content but no
#                              GROBID-extracted title had their title
#                              backfilled from CrossRef instead of being
#                              excluded

library(httr2)
suppressMessages(library(metacheck))

SOURCE_DIR  <- "C:/Users/dlakens/OneDrive - TU Eindhoven/R/download_articles_code_and_data/psych_science"
PDF_DIR     <- "psychsci_oa/pdf"
XML_DIR     <- "psychsci_oa/xml"
GROBID_URL  <- "https://grobid.work.abed.cloud/api/processFulltextDocument"
RDS_OUT     <- "psychsci_oa.rds"
MANIFEST    <- "psychsci_oa/manifest.csv"
SAMPLE_CSV  <- "psychsci_oa/sample.csv"
LICENSE_CSV <- "psychsci_oa/license_check.csv"

dir.create(PDF_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(XML_DIR, recursive = TRUE, showWarnings = FALSE)

# == Phase 1: check license per DOI ============================================

pdfs <- list.files(SOURCE_DIR, pattern = "\\.pdf$", full.names = FALSE)
ids  <- tools::file_path_sans_ext(pdfs)
message("Total source PDFs: ", length(ids))

check_license <- function(doi) {
  resp <- tryCatch(
    request(paste0("https://api.crossref.org/works/", doi)) |>
      req_timeout(15) |> req_options(connecttimeout = 8, ssl_options = 2) |>
      req_error(is_error = \(r) FALSE) |> req_perform(),
    error = \(e) NULL
  )
  if (is.null(resp) || resp_status(resp) != 200) {
    return(list(title = NA_character_, license_url = NA_character_, is_open = NA))
  }
  m <- resp_body_json(resp)$message
  lic <- m$license
  urls <- if (!is.null(lic)) sapply(lic, function(l) l$URL %||% NA_character_) else NA_character_
  urls <- urls[!is.na(urls)]
  is_open <- any(grepl("creativecommons\\.org/(licenses|publicdomain)", urls))
  list(title = m$title[[1]] %||% NA_character_,
       license_url = paste(unique(urls), collapse = " | "), is_open = is_open)
}

results <- data.frame(article_id = ids, doi = paste0("10.1177/", ids),
                       title = NA_character_, license_url = NA_character_,
                       is_open = NA, stringsAsFactors = FALSE)
for (i in seq_len(nrow(results))) {
  r <- check_license(results$doi[i])
  results$title[i] <- r$title
  results$license_url[i] <- r$license_url
  results$is_open[i] <- r$is_open
  Sys.sleep(0.3)
}
write.csv(results, LICENSE_CSV, row.names = FALSE)
message("Open access: ", sum(results$is_open, na.rm = TRUE), " / ", nrow(results))

# == Phase 2: filter to open-access subset, copy PDFs, look up real year =====

open_rows <- results[results$is_open %in% TRUE, ]

get_year <- function(doi) {
  resp <- tryCatch(
    request(paste0("https://api.crossref.org/works/", doi)) |>
      req_timeout(15) |> req_options(connecttimeout = 8, ssl_options = 2) |>
      req_error(is_error = \(r) FALSE) |> req_perform(),
    error = \(e) NULL
  )
  if (is.null(resp) || resp_status(resp) != 200) return(NA_integer_)
  m <- resp_body_json(resp)$message
  parts <- (m$`published-print`$`date-parts` %||% m$`published-online`$`date-parts` %||%
            m$published$`date-parts`)[[1]]
  if (is.null(parts)) return(NA_integer_) else as.integer(parts[[1]])
}
open_rows$year <- vapply(open_rows$doi, get_year, integer(1))

for (i in seq_len(nrow(open_rows))) {
  src <- file.path(SOURCE_DIR, paste0(open_rows$article_id[i], ".pdf"))
  dest <- file.path(PDF_DIR, paste0("psychsci_oa.", open_rows$article_id[i], ".pdf"))
  if (file.exists(src)) file.copy(src, dest, overwrite = TRUE)
}
write.csv(open_rows, SAMPLE_CSV, row.names = FALSE)
message("Copied ", sum(file.exists(file.path(PDF_DIR, paste0("psychsci_oa.", open_rows$article_id, ".pdf")))),
        " / ", nrow(open_rows), " PDFs")

# == Phase 3: convert ============================================================

sampled <- read.csv(SAMPLE_CSV, stringsAsFactors = FALSE, colClasses = "character")
sampled$year <- as.integer(sampled$year)

pdfs2 <- list.files(PDF_DIR, pattern = "\\.pdf$", full.names = TRUE)
for (pdf in pdfs2) {
  stem <- tools::file_path_sans_ext(basename(pdf))
  out_xml <- file.path(XML_DIR, paste0(stem, ".xml"))
  if (file.exists(out_xml)) next
  tryCatch(convert_grobid(pdf, save_path = out_xml, api_url = GROBID_URL),
           error = function(e) message("ERROR ", stem, ": ", e$message))
}

papers <- grobid_to_bibr(XML_DIR, save_path = NULL)
saveRDS(papers, RDS_OUT)
message("RDS saved: ", length(papers), " papers")

paper_ids <- sapply(papers, function(p) basename(p$info$file_name)) |>
  sub("^psychsci_oa\\.", "", x = _) |> sub("\\.xml$", "", x = _)
manifest <- data.frame(
  doi = sampled$doi, article_id = sampled$article_id, title = sampled$title,
  year = sampled$year, license_url = sampled$license_url,
  pdf_file = paste0("pdf/psychsci_oa.", sampled$article_id, ".pdf"),
  xml_file = paste0("xml/psychsci_oa.", sampled$article_id, ".xml"),
  pdf_exists = file.exists(file.path(PDF_DIR, paste0("psychsci_oa.", sampled$article_id, ".pdf"))),
  xml_exists = file.exists(file.path(XML_DIR, paste0("psychsci_oa.", sampled$article_id, ".xml"))),
  in_rds = sampled$article_id %in% paper_ids,
  grobid_version = "0.9", conversion_date = format(Sys.Date(), "%Y-%m-%d")
)
write.csv(manifest, MANIFEST, row.names = FALSE)
message("Coverage: ", sum(manifest$in_rds), "/", nrow(manifest))

# == Phase 4: DOI correction =====================================================

papers <- readRDS(RDS_OUT)
fnames <- sapply(papers, function(p) basename(p$info$file_name))
ids2 <- sub("^psychsci_oa\\.", "", fnames) |> sub("\\.xml$", "", x = _)
doi_lookup <- setNames(sampled$doi, sampled$article_id)
for (i in seq_along(papers)) papers[[i]]$info$doi <- doi_lookup[[ids2[i]]]
saveRDS(papers, RDS_OUT)

# == Phase 5: cleanup -- drop 1 erratum, backfill title for 2 papers ==========

papers <- readRDS(RDS_OUT)
fnames <- sapply(papers, function(p) basename(p$info$file_name))
ids3 <- sub("^psychsci_oa\\.", "", fnames) |> sub("\\.xml$", "", x = _)

backfill_ids <- c("0956797620939054", "0956797620955209")
for (target in backfill_ids) {
  i <- which(ids3 == target)
  if (length(i) == 1 && !nzchar(papers[[i]]$info$title %||% "")) {
    resp <- request(paste0("https://api.crossref.org/works/10.1177/", target)) |>
      req_timeout(15) |> req_error(is_error = \(r) FALSE) |> req_perform()
    papers[[i]]$info$title <- resp_body_json(resp)$message$title[[1]]
  }
}

drop_id <- "09567976231188124"  # "Erratum to ..." notice, no real body content
keep <- ids3 != drop_id
papers <- papers[keep]
class(papers) <- "scivrs_paperlist"
saveRDS(papers, RDS_OUT)

m <- read.csv(MANIFEST, stringsAsFactors = FALSE, colClasses = "character")
m <- m[m$article_id != drop_id, ]
m$in_rds <- TRUE
write.csv(m, MANIFEST, row.names = FALSE)

message("Build complete: ", length(readRDS(RDS_OUT)), " papers in ", RDS_OUT)