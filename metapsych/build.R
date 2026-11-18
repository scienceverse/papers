# Build script: Meta-Psychology corpus for scienceverse/papers
#
# Produces:
#   metapsych/sample.csv       all CrossRef journal-article DOIs (complete
#                              corpus, no sampling) with their PDF links
#   metapsych/pdf/             PDF files (CC-BY 4.0)
#   metapsych/xml/             GROBID TEI-XML intermediate files
#   metapsych/conversion_log.csv  which GROBID server/version converted
#                              each PDF, and when
#   metapsych/manifest.csv     one row per paper with provenance metadata
#   metapsych.rds              metacheck paperlist (GitHub release asset)
#
# Requirements:
#   R packages: httr2, pdftools, stringi, metacheck (scienceverse/metacheck)
#   metacheck::email() set to a valid address (Unpaywall fallback only)
#   A GROBID server: the TU/e server (https://grobid.hti.ieis.tue.nl) is
#   preferred; it only accepts connections from the TU/e network/VPN, so
#   when it does not answer the script uses the GROBID 0.9 server on
#   Hugging Face (https://grobidOrg-grobid.hf.space), the same fallback
#   order metacheck::convert() uses.
#
# Meta-Psychology (Linnaeus University Press, ISSN 2003-2714) has 153
# CrossRef-registered journal articles (2017-2026), the same 153 articles
# listed on the journal's own issue pages, so this is a COMPLETE CORPUS.
# Every CrossRef record carries a CC-BY 4.0 license and a direct,
# version-of-record PDF link on open.lnu.se (intended for text mining),
# which is used as the download source; no bot protection was found.
#
# The journal performs a computational reproducibility check of accepted
# articles. The first page of each PDF states the article type, the
# open data / materials / analysis status, and who reproduced the
# analysis; phase 3 reads these fields into the manifest.
#
# Commentaries are kept: in Meta-Psychology they are peer-reviewed
# articles (often with their own analyses), unlike the short replies to
# letters that the "commentary on" title rule targets in other corpora.
# Editorials (by the article type printed on the first page) are dropped.
#
# The script is idempotent: every phase skips work already done on disk.
# Run from the repository root.

library(httr2)
suppressMessages(library(metacheck))

ISSN       <- "2003-2714"   # Meta-Psychology (online-only, single ISSN)
PREFIX     <- "metapsych"
PDF_DIR    <- "metapsych/pdf"
XML_DIR    <- "metapsych/xml"
SAMPLE_CSV <- "metapsych/sample.csv"
CONV_LOG   <- "metapsych/conversion_log.csv"
MANIFEST   <- "metapsych/manifest.csv"
RDS_OUT    <- "metapsych.rds"
GROBID_SERVERS <- c(TUE         = "https://grobid.hti.ieis.tue.nl",
                    HuggingFace = "https://grobidOrg-grobid.hf.space")
UA <- "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

dir.create(PDF_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(XML_DIR, recursive = TRUE, showWarnings = FALSE)

# Same title rules as the other corpora, minus "commentary on" (see above).
is_nonarticle <- function(title) {
  grepl("(Correction|Retraction|Expression of Concern|Erratum|Withdrawal)(\\s+(Note|to|To))?:",
        title, ignore.case = TRUE) |
  grepl("^(Response|Reply) to [‘'\"]", title, ignore.case = TRUE) |
  grepl("Reviewer and Editorial Board|^Call for Papers|^Editorial Board|^Editorial Note|^Acknowledge?ment|^Annual Report|Thank You|^Meeting [Rr]eport:",
        title, ignore.case = TRUE) |
  grepl("^Corrigendum|^Erratum\\s*:?\\s*$|^Erratum:", title, ignore.case = TRUE)
}

net <- function(req, timeout = 30) {
  req |> req_headers(`User-Agent` = UA) |>
    req_timeout(timeout) |> req_options(connecttimeout = 10, ssl_options = 2) |>
    req_error(is_error = \(r) FALSE)
}

fetch_all <- function() {
  acc <- list(); offset <- 0
  repeat {
    resp <- tryCatch(
      request(paste0("https://api.crossref.org/journals/", ISSN, "/works")) |>
        req_url_query(filter = "type:journal-article", rows = 500, offset = offset) |>
        net(60) |> req_perform(),
      error = \(e) NULL)
    if (is.null(resp) || resp_status(resp) != 200) stop("CrossRef request failed")
    items <- resp_body_json(resp)$message$items
    if (length(items) == 0) break
    acc <- c(acc, items)
    offset <- offset + length(items)
    if (length(items) < 500) break
    Sys.sleep(1)
  }
  acc
}

unpaywall_pdf <- function(doi) {
  resp <- tryCatch(
    request(paste0("https://api.unpaywall.org/v2/", doi)) |>
      req_url_query(email = metacheck::email()) |> net(20) |> req_perform(),
    error = \(e) NULL)
  if (is.null(resp) || resp_status(resp) != 200) return(NA_character_)
  loc <- resp_body_json(resp)$best_oa_location
  if (is.null(loc) || !identical(loc$version, "publishedVersion")) return(NA_character_)
  loc$url_for_pdf %||% NA_character_
}

# CrossRef's PDF link names a specific file ("galley") of the article; when
# the journal replaces the PDF (e.g. a corrected version), the old link
# either returns 404 or still serves the superseded file. The article's
# page on open.lnu.se always links the current PDF, so read it from there.
# Each Meta-Psychology article has exactly one galley (checked 2026-11-18).
current_pdf_url <- function(crossref_pdf_url) {
  id <- regmatches(crossref_pdf_url,
                   regexpr("(?<=article/download/)[0-9]+", crossref_pdf_url, perl = TRUE))
  if (!length(id)) return(NA_character_)
  base <- "https://open.lnu.se/index.php/metapsychology/article/"
  resp <- tryCatch(request(paste0(base, "view/", id)) |> net(30) |> req_perform(),
                   error = \(e) NULL)
  if (is.null(resp) || resp_status(resp) != 200) return(NA_character_)
  html <- resp_body_string(resp)
  galley <- unique(regmatches(html, gregexpr(paste0("(?<=article/view/", id, "/)[0-9]+"),
                                             html, perl = TRUE))[[1]])
  if (length(galley) != 1) return(NA_character_)
  paste0(base, "download/", id, "/", galley)
}

download_pdf <- function(url, dest, max_tries = 3) {
  for (attempt in seq_len(max_tries)) {
    ok <- tryCatch(
      request(url) |> net(60) |> req_perform(path = dest) |> resp_status() == 200,
      error = \(e) FALSE)
    if (ok && file.exists(dest)) {
      ok <- identical(rawToChar(readBin(dest, "raw", n = 5)), "%PDF-")
    } else ok <- FALSE
    if (ok) return(TRUE)
    unlink(dest)
    if (attempt < max_tries) Sys.sleep(2 * attempt)
  }
  FALSE
}

# == Phase 1: DOI list + download (idempotent -- call repeatedly) =============

phase1_download <- function() {
  if (!file.exists(SAMPLE_CSV)) {
    message("Fetching CrossRef records for ISSN ", ISSN, "...")
    items <- fetch_all()
    row <- function(it) {
      link <- Filter(\(l) identical(l$`content-type`, "application/pdf") &&
                          identical(l$`content-version`, "vor"), it$link %||% list())
      data.frame(
        doi     = tolower(it$DOI),
        title   = if (length(it$title)) gsub("\\s+", " ", trimws(it$title[[1]])) else NA_character_,
        year    = (it$published %||% it$created)$`date-parts`[[1]][[1]],
        pdf_url = if (length(link)) link[[1]]$URL else NA_character_,
        license = if (length(it$license)) it$license[[1]]$URL else NA_character_)
    }
    df <- do.call(rbind, lapply(items, row))
    df <- df[!duplicated(df$doi) & !is.na(df$doi), ]
    notice <- is_nonarticle(df$title)
    message("CrossRef: ", nrow(df), " journal articles, ", sum(notice),
            " non-article notices excluded by title")
    df <- df[!notice, ]
    # 10.15626/mp.2018.842 -> mp2018842 ; 10.15626/mp2017.1001 -> mp20171001
    df$article_id <- gsub("[^a-z0-9]", "", sub("^10\\.15626/", "", df$doi))
    stopifnot(length(unique(df$article_id)) == nrow(df))
    df <- df[order(df$doi), c("doi", "article_id", "title", "year", "pdf_url", "license")]
    write.csv(df, SAMPLE_CSV, row.names = FALSE)
    message("Written ", SAMPLE_CSV, ": ", nrow(df), " articles (complete journal)")
  }

  sampled <- read.csv(SAMPLE_CSV, colClasses = "character")
  if (!"pdf_source" %in% names(sampled)) sampled$pdf_source <- NA_character_
  n_ok <- n_fail <- 0
  for (i in seq_len(nrow(sampled))) {
    dest <- file.path(PDF_DIR, paste0(PREFIX, ".", sampled$article_id[i], ".pdf"))
    current <- current_pdf_url(sampled$pdf_url[i])
    have <- file.exists(dest) && identical(rawToChar(readBin(dest, "raw", n = 5)), "%PDF-")
    # skip only if the file on disk came from the journal's current PDF link
    if (have && !is.na(current) && identical(sampled$pdf_source[i], current)) next
    if (have && is.na(current)) next             # journal page unreachable; keep file
    ok <- FALSE
    for (url in unique(na.omit(c(current, sampled$pdf_url[i])))) {
      if (download_pdf(url, dest)) { ok <- TRUE; sampled$pdf_source[i] <- url; break }
    }
    if (!ok) {                                   # last resort: Unpaywall
      alt <- unpaywall_pdf(sampled$doi[i])
      if (!is.na(alt) && download_pdf(alt, dest)) { ok <- TRUE; sampled$pdf_source[i] <- alt }
    }
    if (ok) n_ok <- n_ok + 1 else {
      n_fail <- n_fail + 1; sampled$pdf_source[i] <- NA; message("FAILED: ", sampled$doi[i])
    }
    write.csv(sampled, SAMPLE_CSV, row.names = FALSE)
    Sys.sleep(1)
  }
  # compare only "<article>/<file>" -- some CrossRef links use the journal's
  # former host name (conferences.lnu.se) for the very same file
  file_part <- \(u) sub("^.*/article/download/", "", u)
  stale <- !is.na(sampled$pdf_source) & file_part(sampled$pdf_source) != file_part(sampled$pdf_url)
  message("Downloaded ", n_ok, ", failed ", n_fail, "; PDFs on disk: ",
          length(list.files(PDF_DIR, "\\.pdf$")), " / ", nrow(sampled),
          "; PDFs whose CrossRef link was outdated: ", sum(stale))
}

# == Phase 2: GROBID conversion (idempotent) ==================================

grobid_alive <- function(url) {
  resp <- tryCatch(request(paste0(url, "/api/isalive")) |> net(30) |> req_perform(),
                   error = \(e) NULL)
  !is.null(resp) && resp_status(resp) == 200 &&
    identical(trimws(resp_body_string(resp)), "true")
}

grobid_version <- function(url) {
  resp <- tryCatch(request(paste0(url, "/api/version")) |> net(30) |> req_perform(),
                   error = \(e) NULL)
  if (is.null(resp) || resp_status(resp) != 200) return(NA_character_)
  # newer servers answer {"version":"0.9.1",...}, older ones plain "0.8.2"
  v <- regmatches(resp_body_string(resp),
                  regexpr("[0-9]+\\.[0-9]+(\\.[0-9]+)?", resp_body_string(resp)))
  if (length(v)) v else NA_character_
}

phase2_convert <- function(server = NULL) {
  if (is.null(server)) {
    alive  <- vapply(GROBID_SERVERS, grobid_alive, logical(1))
    if (!any(alive)) stop("No GROBID server answers; check your connection")
    server <- GROBID_SERVERS[[which(alive)[1]]]
  }
  version <- grobid_version(server)
  message("Using GROBID ", version, " at ", server)

  log <- if (file.exists(CONV_LOG)) read.csv(CONV_LOG, colClasses = "character") else
    data.frame(stem = character(), server = character(), grobid_version = character(),
               conversion_date = character())
  pdfs <- list.files(PDF_DIR, "\\.pdf$", full.names = TRUE)
  n_done <- n_err <- 0
  for (pdf in pdfs) {
    stem <- tools::file_path_sans_ext(basename(pdf))
    out  <- file.path(XML_DIR, paste0(stem, ".xml"))
    if (file.exists(out)) next
    res <- NULL
    for (attempt in 1:3) {
      res <- tryCatch(convert_grobid(pdf, save_path = out, api_url = server),
                      error = \(e) { message("ERROR ", stem, " (try ", attempt, "): ",
                                             conditionMessage(e)); NULL })
      if (!is.null(res) && file.exists(out)) break
      Sys.sleep(5 * attempt)
    }
    if (file.exists(out)) {
      n_done <- n_done + 1
      log <- rbind(log, data.frame(stem = stem, server = server, grobid_version = version,
                                   conversion_date = format(Sys.Date())))
      write.csv(log, CONV_LOG, row.names = FALSE)
    } else n_err <- n_err + 1
  }
  message("Converted ", n_done, ", errors ", n_err, "; XML on disk: ",
          length(list.files(XML_DIR, "\\.xml$")), " / ", length(pdfs))
}

# == Phase 3: first-page header fields, assembly, audit, manifest =============

# Meta-Psychology prints a fixed block of fields at the top of page 1, e.g.
#   "Article type: Commentary", "Open data: Yes", "Analysis reproduced by: ..."
header_fields <- function(pdf) {
  txt <- tryCatch(pdftools::pdf_text(pdf)[1], error = \(e) "")
  grab <- function(label) {
    m <- regmatches(txt, regexpr(paste0(label, ":[ \t]*[^\n]*"), txt, perl = TRUE))
    if (!length(m)) return(NA_character_)
    v <- trimws(sub(paste0("^", label, ":"), "", m, perl = TRUE))
    # the header is laid out in three columns; cut at the next column's text
    v <- trimws(sub("\\s{2,}.*$", "", v, perl = TRUE))
    # one composed form of accented letters, so a name is spelled one way
    stringi::stri_trans_nfc(v)
  }
  data.frame(
    article_type        = grab("Article type"),
    open_data           = grab("Open data"),
    open_materials      = grab("Open materials"),
    open_code           = grab("Open code"),
    open_analysis       = grab("Open and reproducible analysis"),
    open_reviews        = grab("Open reviews and editorial process"),
    preregistration     = grab("Preregistration"),
    analysis_reproduced_by = grab("Analysis reproduced by"))
}

phase3_assemble <- function() {
  sampled <- read.csv(SAMPLE_CSV, colClasses = "character")
  sampled$pdf_path <- file.path(PDF_DIR, paste0(PREFIX, ".", sampled$article_id, ".pdf"))
  # after phase4_zip() the editorials' PDFs live in excluded_pdf/; their
  # first page is still needed to recognise them as editorials
  moved <- file.path("metapsych/excluded_pdf", basename(sampled$pdf_path))
  sampled$pdf_path <- ifelse(!file.exists(sampled$pdf_path) & file.exists(moved),
                             moved, sampled$pdf_path)
  sampled$xml_path <- file.path(XML_DIR, paste0(PREFIX, ".", sampled$article_id, ".xml"))

  hdr <- do.call(rbind, lapply(sampled$pdf_path, \(p)
    if (file.exists(p)) header_fields(p) else header_fields(tempfile())))
  sampled <- cbind(sampled, hdr)

  # drop editorials: article type printed on page 1 is exactly "Editorial"
  # (2 pieces), plus the 1-page inaugural editorial of the QRAP section,
  # whose printed type is the section name. "Guest Editorial" pieces are
  # kept: they are substantive articles, one with a reproduced analysis.
  editorial <- sampled$article_type %in% "Editorial" |
    grepl("^Inaugural Editorial", sampled$title)
  if (any(editorial)) message("Dropping editorials: ",
                              paste(sampled$doi[editorial], collapse = ", "))

  keep <- sampled[!editorial & file.exists(sampled$xml_path), ]
  papers <- grobid_to_bibr(keep$xml_path, save_path = NULL)

  # trust the CrossRef DOI, never GROBID's extracted one; match by file name
  ids <- sub(paste0("^", PREFIX, "\\."), "", basename(sapply(papers, \(p) p$info$file_name))) |>
    sub("\\.xml$", "", x = _)
  doi_lookup <- setNames(sampled$doi, sampled$article_id)
  for (i in seq_along(papers)) papers[[i]]$info$doi <- doi_lookup[[ids[i]]]

  # GROBID finds no title for a few short pieces (3 in the 2026-11-18 build);
  # fill only an empty title, from CrossRef
  title_lookup <- setNames(sampled$title, sampled$article_id)
  for (i in seq_along(papers)) {
    t <- papers[[i]]$info$title
    if (!length(t) || is.na(t) || !nzchar(trimws(t))) {
      papers[[i]]$info$title <- title_lookup[[ids[i]]]
      message("Title taken from CrossRef: ", ids[i])
    }
  }

  # audit: empty titles, near-empty text, duplicates
  titles <- sapply(papers, \(p) { t <- p$info$title; if (length(t) && !is.na(t)) t else "" })
  nchars <- sapply(papers, \(p) sum(nchar(p$text$text %||% "")))
  message("Audit: ", length(papers), " papers; empty titles: ", sum(!nzchar(titles)),
          "; under 2000 characters of text: ", sum(nchars < 2000),
          "; duplicate ids: ", sum(duplicated(ids)))
  if (any(nchars < 2000)) message("  short: ", paste(ids[nchars < 2000], collapse = ", "))
  if (any(!nzchar(titles))) message("  no title: ", paste(ids[!nzchar(titles)], collapse = ", "))
  # each PDF should print its own DOI in the first 3 pages; a miss means
  # "open it and look" (5 misses on 2026-11-18, all typos in the printed
  # DOI of the correct article -- listed in README.md)
  has_doi <- mapply(\(pdf, doi) {
    t <- tolower(gsub("[[:space:]]", "", paste(head(pdftools::pdf_text(pdf), 3), collapse = "")))
    grepl(doi, t, fixed = TRUE)
  }, keep$pdf_path, keep$doi)
  message("PDFs without their own DOI in the first 3 pages: ", sum(!has_doi),
          if (any(!has_doi)) paste0(" (", paste(keep$article_id[!has_doi], collapse = ", "), ")"))
  saveRDS(papers, RDS_OUT)

  conv <- if (file.exists(CONV_LOG)) read.csv(CONV_LOG, colClasses = "character") else
    data.frame(stem = character(), server = character(), grobid_version = character(),
               conversion_date = character())
  conv <- conv[!duplicated(conv$stem, fromLast = TRUE), ]
  conv$grobid_version <- sub('^.*"version":"([^"]+)".*$', "\\1", conv$grobid_version)
  m <- sampled[!editorial, ]
  stem <- paste0(PREFIX, ".", m$article_id)
  manifest <- data.frame(
    doi = m$doi, article_id = m$article_id, title = m$title, year = m$year,
    pdf_file = paste0("pdf/", stem, ".pdf"), xml_file = paste0("xml/", stem, ".xml"),
    pdf_exists = file.exists(m$pdf_path), xml_exists = file.exists(m$xml_path),
    in_rds = m$article_id %in% ids,
    grobid_server = conv$server[match(stem, conv$stem)],
    grobid_version = conv$grobid_version[match(stem, conv$stem)],
    conversion_date = conv$conversion_date[match(stem, conv$stem)],
    license = ifelse(grepl("creativecommons.org/licenses/by/4.0", m$license), "CC-BY 4.0", m$license),
    m[, names(hdr)])
  write.csv(manifest, MANIFEST, row.names = FALSE)
  message("Build complete: ", length(papers), " papers in ", RDS_OUT,
          "; manifest rows: ", nrow(manifest))
}

# == Phase 4: release zip of PDFs, built from the RDS's own file list ==========
# PDFs of excluded papers (the editorials) are moved -- not deleted -- to
# metapsych/excluded_pdf/ so pdf/ holds exactly the papers in the RDS.

phase4_zip <- function(zip_out = "metapsych_pdf.zip") {
  papers <- readRDS(RDS_OUT)
  ids  <- sub(paste0("^", PREFIX, "\\."), "", basename(sapply(papers, \(p) p$info$file_name))) |>
    sub("\\.xml$", "", x = _)
  disk <- sub(paste0("^", PREFIX, "\\."), "", list.files(PDF_DIR, "\\.pdf$")) |>
    sub("\\.pdf$", "", x = _)
  extra <- setdiff(disk, ids)
  if (length(extra)) {
    dir.create("metapsych/excluded_pdf", showWarnings = FALSE)
    file.rename(file.path(PDF_DIR, paste0(PREFIX, ".", extra, ".pdf")),
                file.path("metapsych/excluded_pdf", paste0(PREFIX, ".", extra, ".pdf")))
    message("Moved to metapsych/excluded_pdf: ", paste(extra, collapse = ", "))
  }
  files <- paste0(PREFIX, ".", ids, ".pdf")
  stopifnot(all(file.exists(file.path(PDF_DIR, files))))
  if (file.exists(zip_out)) stop(zip_out, " already exists; remove it first")
  zip::zip(zip_out, files = files, root = PDF_DIR)
  inside <- zip::zip_list(zip_out)$filename
  stopifnot(setequal(inside, files))
  message("Zip verified: ", length(inside), " PDFs in ", zip_out)
}

# == Run =======================================================================
# phase1_download()   # call again until PDFs on disk == rows in sample.csv
# phase2_convert()    # picks TU/e GROBID if reachable, else Hugging Face
# phase3_assemble()
# phase4_zip()
