# Build script: Judgment and Decision Making paper corpus for scienceverse/papers
#
# Produces:
#   jdm/manifest.csv        one row per paper with provenance metadata
#   jdm/pdf/                855 PDF files (CC-BY licensed)
#   jdm.rds                 metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: rvest, httr2, rcrossref, metacheck (scienceverse/metacheck)
#   GROBID instance (default: TU/e server https://grobid.hti.ieis.tue.nl)
#   metacheck::email() set to a valid address
#
# Steps:
#   1. Scrape all issue pages on jbaron.org to collect PDF URLs
#   2. Download PDFs; remove non-article files (supplements, appendices)
#   3. Convert PDFs to TEI-XML via GROBID 0.8
#   4. Assemble XML files into a metacheck paperlist
#   5. Patch missing/wrong DOIs via CrossRef title matching
#   6. Manually patch 8 papers from Vol. 2 Issue 6 (Dec 2007) not in CrossRef,
#      and remove 2 non-paper entries (annotated programs, supplement)
#   7. Write manifest.csv and save RDS

library(rvest)
library(httr2)
library(rcrossref)
suppressMessages(library(metacheck))

BASE_URL   <- "https://jbaron.org/journal/"
PDF_DIR    <- "jdm/pdf"
XML_DIR    <- "jdm/xml"
RDS_OUT    <- "jdm.rds"
MANIFEST   <- "jdm/manifest.csv"
GROBID_URL <- "https://grobid.hti.ieis.tue.nl"

dir.create(PDF_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(XML_DIR, recursive = TRUE, showWarnings = FALSE)

# ── Step 1: Scrape PDF URLs from all issue pages ──────────────────────────────
issue_pages <- c(
  paste0("vol1.", 1:2, ".htm"),
  paste0("vol2.", 1:6, ".htm"),
  paste0("vol3.", 1:5, ".htm"),
  paste0("vol3.", 6:8, ".html"),
  paste0("vol4.", 1:7, ".html"),
  paste0("vol5.", 1:7, ".html"),
  paste0("vol6.", 1:8, ".html"),
  paste0("vol7.", 1:6, ".html"),
  paste0("vol8.", 1:6, ".html"),
  paste0("vol9.", 1:6, ".html"),
  paste0("vol10.", 1:6, ".html"),
  paste0("vol11.", 1:6, ".html"),
  paste0("vol12.", 1:6, ".html"),
  paste0("vol13.", 1:6, ".html"),
  paste0("vol14.", 1:6, ".html"),
  paste0("vol15.", 1:6, ".html"),
  paste0("vol16.", 1:6, ".html"),
  paste0("vol17.", 1:6, ".html")
)

message("Scraping ", length(issue_pages), " issue pages...")
all_pdfs <- character(0)
for (pg in issue_pages) {
  links <- tryCatch({
    page  <- read_html(paste0(BASE_URL, pg))
    hrefs <- html_attr(html_nodes(page, "a"), "href")
    hrefs <- hrefs[!is.na(hrefs) & grepl("\\.pdf$", hrefs, ignore.case = TRUE)]
    sapply(hrefs, function(h) if (grepl("^https?://", h)) h else paste0(BASE_URL, h))
  }, error = function(e) character(0))
  all_pdfs <- c(all_pdfs, links)
  Sys.sleep(0.5)
}
all_pdfs <- unique(all_pdfs)
message("Found ", length(all_pdfs), " unique PDF URLs")

# ── Step 2: Download PDFs ─────────────────────────────────────────────────────
for (i in seq_along(all_pdfs)) {
  url  <- all_pdfs[i]
  dest <- file.path(PDF_DIR, paste0("jdm.", basename(url)))
  if (file.exists(dest) && file.info(dest)$size > 10000) next
  tryCatch(
    request(url) |> req_timeout(30) |> req_error(is_error = \(r) FALSE) |>
      req_perform(path = dest),
    error = function(e) message("ERR: ", basename(url), " - ", e$message)
  )
  Sys.sleep(0.5)
}

# Remove non-article files — keep only jdm.jdmNNN*.pdf
non_articles <- list.files(PDF_DIR, pattern = "\\.pdf$", full.names = TRUE)
non_articles <- non_articles[!grepl("/jdm\\.jdm\\d", non_articles)]
if (length(non_articles)) {
  message("Removing ", length(non_articles), " non-article files")
  file.remove(non_articles)
}
message("Article PDFs: ", length(list.files(PDF_DIR, pattern = "\\.pdf$")))

# ── Step 3: Convert PDFs to XML via GROBID ───────────────────────────────────
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
  if ((n_done + n_err) %% 20 == 0)
    message(sprintf("[%d/%d] done=%d skip=%d err=%d", i, length(pdfs), n_done, n_skip, n_err))
}
message(sprintf("Conversion: %d done, %d skipped, %d errors", n_done, n_skip, n_err))

# ── Step 4: Assemble paperlist ────────────────────────────────────────────────
# Note: jdm.jdm200330.xml excluded — PDF was 30 MB (payload too large for GROBID)
# Note: jdm.jdm9115AnnotatedPrograms and jdm.jdm9226s are non-papers — excluded below
papers <- grobid_to_bibr(XML_DIR, save_path = NULL)
message("Papers assembled: ", length(papers))

# Remove known non-papers
non_paper_stems <- c("jdm.jdm9115AnnotatedPrograms", "jdm.jdm9226s")
remove_idx <- which(sapply(papers, function(p) {
  tools::file_path_sans_ext(basename(p$info$file_name %||% "")) %in% non_paper_stems
}))
if (length(remove_idx)) papers <- papers[-remove_idx]
message("After removing non-papers: ", length(papers))

# ── Step 5: Patch DOIs via CrossRef title matching ────────────────────────────
jdm_prefix <- "10.1017"

fetch_cr <- function(offset) {
  for (attempt in 1:3) {
    result <- tryCatch(
      cr_journals(issn = "1930-2975", works = TRUE, limit = 500, offset = offset,
                  filter = c(from_pub_date = "2001-01-01", until_pub_date = "2024-01-01")),
      error = function(e) { Sys.sleep(5); NULL }
    )
    if (!is.null(result)) return(result$data)
  }
  NULL
}
chunks <- lapply(c(0, 500, 1000), function(off) { Sys.sleep(2); fetch_cr(off) })
cr <- do.call(rbind, Filter(Negate(is.null), chunks))
cr$title_clean <- tolower(trimws(sapply(cr$title,
  function(t) if (is.list(t)) t[[1]] else as.character(t))))
cr$first_author <- sapply(cr$author, function(a) {
  if (is.null(a) || !is.data.frame(a) || nrow(a) == 0) return("")
  tolower(trimws(a$family[1]))
})
message("CrossRef papers fetched: ", nrow(cr))

needs_patch <- which(sapply(papers, function(p) !startsWith(p$info$doi %||% "", jdm_prefix)))
n_patched <- 0
for (j in needs_patch) {
  title     <- tolower(trimws(papers[[j]]$info$title %||% ""))
  first_auth <- tolower(trimws(if (nrow(papers[[j]]$author) > 0) papers[[j]]$author$family[1] else ""))
  if (!nzchar(title)) next

  dists <- adist(title, cr$title_clean)[1, ]
  best  <- which.min(dists)
  score <- dists[best] / max(nchar(title), nchar(cr$title_clean[best]), 1)

  if (score <= 0.15) {
    papers[[j]]$info$doi <- cr$doi[best]; n_patched <- n_patched + 1; next
  }
  if (nzchar(first_auth)) {
    sub_cr <- cr[cr$first_author == first_auth, ]
    if (nrow(sub_cr) > 0) {
      sub_d <- adist(title, sub_cr$title_clean)[1, ]
      sb    <- which.min(sub_d)
      sc    <- sub_d[sb] / max(nchar(title), nchar(sub_cr$title_clean[sb]), 1)
      if (sc <= 0.30) {
        papers[[j]]$info$doi <- sub_cr$doi[sb]; n_patched <- n_patched + 1; next
      }
    }
  }
}
message(sprintf("DOI patching: %d patched via CrossRef", n_patched))

# ── Step 6: Manual DOI patches ────────────────────────────────────────────────
# Vol. 2 Issue 6 (December 2007) papers not indexed in CrossRef.
# DOIs verified manually from cambridge.org/core/journals/judgment-and-decision-making
# on 2026-06-17.
manual_patches <- list(
  # title                                                    DOI
  "Metacognitive judgment and denial of deficit"           = "10.1017/S1930297500000504",
  "Context effects in games"                               = "10.1017/S1930297500000528",
  "Weighing waiting"                                       = "10.1017/S1930297500000498",
  "An examination of ambiguity aversion"                   = "10.1017/S193029750000053X",
  "Easy does it"                                           = "10.1017/S1930297500000516",
  "Action orientation, consistency and feelings of regret" = "10.1017/S1930297500000474"
)
for (j in seq_along(papers)) {
  title <- papers[[j]]$info$title %||% ""
  if (startsWith(papers[[j]]$info$doi %||% "", jdm_prefix)) next
  for (kw in names(manual_patches)) {
    if (grepl(kw, title, ignore.case = TRUE)) {
      papers[[j]]$info$doi <- manual_patches[[kw]]
      break
    }
  }
}

# ── Step 7: Write manifest and save RDS ──────────────────────────────────────
dois    <- sapply(papers, function(p) p$info$doi %||% "")
titles  <- sapply(papers, function(p) p$info$title %||% "")
fnames  <- sapply(papers, function(p) basename(p$info$file_name %||% ""))

manifest <- data.frame(
  doi             = dois,
  title           = titles,
  xml_file        = fnames,
  pdf_file        = sub("\\.xml$", ".pdf", fnames),
  has_jdm_doi     = startsWith(dois, jdm_prefix),
  grobid_version  = "0.8",
  conversion_date = "2026-06-17",
  license         = "CC-BY 4.0",
  stringsAsFactors = FALSE
)
write.csv(manifest, MANIFEST, row.names = FALSE)

saveRDS(papers, RDS_OUT)

jdm_doi <- sum(startsWith(dois, jdm_prefix))
message(sprintf("Final: %d papers, %d with JDM DOI", length(papers), jdm_doi))
message("Manifest: ", MANIFEST)
message("RDS: ", RDS_OUT)