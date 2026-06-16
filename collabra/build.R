# Build script: Collabra Psychology paper corpus for scienceverse/papers
#
# Produces:
#   collabra/manifest.csv   — one row per paper with provenance metadata
#   collabra/pdf/           — 749 PDF files (CC-BY licensed)
#   collabra.rds            — metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: rcrossref, httr2, metacheck (scienceverse/metacheck)
#   GROBID 0.9 instance (used: https://grobid.work.abed.cloud)
#   metacheck::email() set to a valid address for OpenAlex API
#
# Steps:
#   1. Fetch all Collabra DOIs from CrossRef
#   2. Download PDFs (open access via Unpaywall)
#   3. Convert PDFs to TEI-XML via GROBID 0.9
#   4. Assemble XML files into a metacheck paperlist and save as RDS

library(rcrossref)
library(httr2)
library(metacheck)  # devtools::install_github("scienceverse/metacheck")

ISSN        <- "2474-7394"               # Collabra: Psychology
EMAIL       <- metacheck::email()        # set with metacheck::email("you@example.com")
PDF_DIR     <- "collabra/pdf"
XML_DIR     <- "collabra/xml"           # intermediate; not committed to repo
GROBID_URL  <- "https://grobid.work.abed.cloud/api/processFulltextDocument"
RDS_OUT     <- "collabra.rds"
MANIFEST    <- "collabra/manifest.csv"

dir.create(PDF_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(XML_DIR, recursive = TRUE, showWarnings = FALSE)

# ── Step 1: Fetch all DOIs from CrossRef ─────────────────────────────────────

years <- 2015:as.integer(format(Sys.Date(), "%Y"))
all_works <- lapply(years, function(yr) {
  Sys.sleep(2)
  tryCatch(
    cr_journals(
      issn   = ISSN,
      works  = TRUE,
      limit  = 1000,
      filter = c(
        from_pub_date  = paste0(yr, "-01-01"),
        until_pub_date = paste0(yr, "-12-31")
      )
    )$data,
    error = function(e) { message("Year ", yr, " failed: ", e$message); NULL }
  )
})
dois_df <- do.call(rbind, Filter(Negate(is.null), all_works))
dois_df <- dois_df[!duplicated(dois_df$doi), ]
dois_df$article_id <- sub("10.1525/collabra.", "", dois_df$doi, fixed = TRUE)
message("CrossRef: ", nrow(dois_df), " unique DOIs")

# ── Step 2: Download PDFs via Unpaywall ──────────────────────────────────────
# NOTE: UC Press (online.ucpress.edu) blocks automated downloads.
# Use Unpaywall to resolve OA PDF URLs, then download manually or via
# browser automation. PDFs must be placed in PDF_DIR as collabra.<id>.pdf

for (i in seq_len(nrow(dois_df))) {
  doi    <- dois_df$doi[i]
  art_id <- dois_df$article_id[i]
  dest   <- file.path(PDF_DIR, paste0("collabra.", art_id, ".pdf"))
  if (file.exists(dest)) next

  uw <- tryCatch({
    resp <- request(paste0("https://api.unpaywall.org/v2/", doi, "?email=", EMAIL)) |>
      req_error(is_error = \(r) FALSE) |>
      req_perform()
    if (resp_status(resp) == 200) resp_body_json(resp) else NULL
  }, error = \(e) NULL)

  pdf_url <- uw[["best_oa_location"]][["url_for_pdf"]]
  if (is.null(pdf_url) || !nzchar(pdf_url)) {
    message("[", i, "/", nrow(dois_df), "] No PDF URL: ", doi)
    next
  }

  tryCatch(
    download.file(pdf_url, dest, mode = "wb", quiet = TRUE),
    error = function(e) message("[", i, "] Download failed: ", e$message)
  )
  Sys.sleep(2)
}

# ── Step 3: Convert PDFs to XML via GROBID 0.9 ───────────────────────────────

pdfs        <- list.files(PDF_DIR, pattern = "\\.pdf$", full.names = TRUE)
already_xml <- tools::file_path_sans_ext(basename(list.files(XML_DIR, pattern = "\\.xml$")))
n_done <- n_skip <- n_err <- 0

for (i in seq_along(pdfs)) {
  stem <- tools::file_path_sans_ext(basename(pdfs[i]))
  if (stem %in% already_xml) { n_skip <- n_skip + 1; next }

  out_xml <- file.path(XML_DIR, paste0(stem, ".xml"))
  result  <- tryCatch(
    convert_grobid(pdfs[i], save_path = out_xml, api_url = GROBID_URL),
    error = function(e) { message("ERROR ", stem, ": ", e$message); NULL }
  )
  if (!is.null(result)) n_done <- n_done + 1 else n_err <- n_err + 1
  if ((n_done + n_err) %% 10 == 0)
    message("[", i, "/", length(pdfs), "] done=", n_done, " skip=", n_skip, " err=", n_err)
}
message("Conversion done: ", n_done, " converted, ", n_skip, " skipped, ", n_err, " errors")

# ── Step 4: Assemble RDS ─────────────────────────────────────────────────────

papers <- grobid_to_bibr(XML_DIR, save_path = NULL)
saveRDS(papers, RDS_OUT)
message("RDS saved: ", length(papers), " papers -> ", RDS_OUT)

# ── Step 5: Write manifest ───────────────────────────────────────────────────

paper_dois <- sapply(papers, function(p) p$info$doi)
manifest <- data.frame(
  doi             = dois_df$doi,
  article_id      = dois_df$article_id,
  title           = dois_df$title,
  year            = substr(dois_df$published.online, 1, 4),
  pdf_file        = paste0("pdf/collabra.", dois_df$article_id, ".pdf"),
  xml_file        = paste0("xml/collabra.", dois_df$article_id, ".xml"),
  pdf_exists      = file.exists(file.path(PDF_DIR, paste0("collabra.", dois_df$article_id, ".pdf"))),
  xml_exists      = file.exists(file.path(XML_DIR,  paste0("collabra.", dois_df$article_id, ".xml"))),
  in_rds          = dois_df$doi %in% paper_dois,
  grobid_version  = "0.9",
  conversion_date = format(Sys.Date(), "%Y-%m-%d"),
  license         = "CC-BY 4.0"
)
write.csv(manifest, MANIFEST, row.names = FALSE)
message("Manifest written: ", MANIFEST)
message("Coverage: ", sum(manifest$in_rds), "/", nrow(manifest), " papers in RDS")