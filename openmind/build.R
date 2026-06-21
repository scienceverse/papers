# Build script: Open Mind corpus for scienceverse/papers
#
# Produces:
#   openmind/sample.csv   all 295 CrossRef DOIs (complete corpus, no sampling)
#   openmind/pdf/         293 PDF files (CC-BY 4.0)
#   openmind/manifest.csv one row per paper with provenance metadata
#   openmind.rds          metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: httr2, metacheck (scienceverse/metacheck)
#   metacheck::email() set to a valid address for Unpaywall API
#   GROBID 0.9 instance (used: https://grobid.work.abed.cloud)
#
# Open Mind has only 295 total CrossRef-registered articles, so this is
# a COMPLETE CORPUS (not a stratified sample) -- every research article
# published 2017-2026. Open Mind (MIT Press) is fully open access;
# CrossRef's license field is only populated for 259/295 records, so OA
# status is determined empirically via Unpaywall rather than trusting
# CrossRef's license field for this journal.
#
# Phases, reflecting the pipeline as actually run:
#   Phase 1: download   - see openmind_download.R. Fetches all 295 DOIs,
#                         downloads via Unpaywall best_oa_location with
#                         a retry-with-backoff wrapper (direct.mit.edu
#                         applies a probabilistic Cloudflare Client
#                         Hints check -- see README), falling back to
#                         Europe PMC where available.
#   Phase 2: resample   - 3 follow-up passes of the same idempotent
#                         download script recovered most of the initial
#                         gap (63 -> 134 -> 279 -> 289 -> 294 PDFs), plus
#                         1 article recovered manually via a
#                         landing-page PDF-link scrape (its only
#                         Unpaywall URL was a DOI redirect, not a direct
#                         PDF link).
#   Phase 3: convert    - GROBID-converts all PDFs (1 "Payload Too
#                         Large" exclusion), assembles RDS + manifest.
#   Phase 4: cleanup    - 1 genuine non-article notice dropped (bare
#                         "Erratum" title, no colon -- missed by the
#                         title-pattern filter), 3 garbled GROBID-
#                         extracted DOIs corrected from the verified
#                         CrossRef sample DOI.

# -- Phase 1+2: download (see openmind_download.R for full implementation) --
# source("openmind_download.R")   # idempotent; re-run to pick up retries

# -- Phase 3: convert (see openmind_convert.R for full implementation) --
# source("openmind_convert.R")

# -- Phase 4: cleanup ---------------------------------------------------------

suppressMessages(library(metacheck))

papers  <- readRDS("openmind.rds")
sampled <- read.csv("openmind/sample.csv", stringsAsFactors = FALSE)

fnames <- sapply(papers, function(p) basename(p$info$file_name))
ids    <- sub("^openmind\\.", "", fnames) |> sub("\\.xml$", "", x = _)

# Drop the 1 genuine non-article (bare "Erratum" title, no colon).
drop_idx <- which(ids == "opmie00106")
papers <- papers[-drop_idx]
ids <- ids[-drop_idx]

sample_doi <- setNames(sampled$doi, sampled$article_id)
for (i in seq_along(papers)) {
  expected_doi <- sample_doi[[ids[i]]]
  actual_doi   <- papers[[i]]$info$doi
  if (is.null(actual_doi) || !nzchar(actual_doi) || !identical(tolower(actual_doi), tolower(expected_doi %||% ""))) {
    papers[[i]]$info$doi <- expected_doi
  }
}

saveRDS(papers, "openmind.rds")
message("Build complete: ", length(papers), " papers in openmind.rds")