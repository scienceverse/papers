# Build script: Frontiers in Psychology corpus for scienceverse/papers
#
# Produces:
#   frontiers/sample.csv   the sampled DOIs (100/year target, 2017-2026)
#   frontiers/pdf/         1000 PDF files (CC-BY 4.0)
#   frontiers/manifest.csv one row per paper with provenance metadata
#   frontiers.rds          metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: httr2, metacheck (scienceverse/metacheck)
#   metacheck::email() set to a valid address for Unpaywall API
#   GROBID 0.9 instance (used: https://grobid.work.abed.cloud)
#
# Frontiers in Psychology has roughly 51,000 articles in total, far too
# many for a complete corpus, so this is a STRATIFIED RANDOM SAMPLE
# (100/year target, 2017-2026), same approach as natcomm/scan/iperc.
# Frontiers is a fully open-access publisher (CC-BY 4.0 confirmed via
# CrossRef license sampling) with strong Europe PMC deposit coverage,
# so PDFs were sourced via the DOI -> Unpaywall OA check -> Europe PMC
# PMCID lookup -> europepmc.org direct-PDF route.
#
# Phases, reflecting the pipeline as actually run:
#   Phase 1: download  - see frontiers_download.R. Samples 100 DOIs/year,
#                         downloads via Unpaywall -> Europe PMC route.
#   Phase 2: resample   - several years (2018, 2022, 2025 -- and others
#                         affected by the intermittent Unpaywall/Europe
#                         PMC failure rate documented in
#                         downloading_articles.md) initially came up
#                         short of 100/year. Closed by resampling
#                         replacement DOIs from the same year and
#                         re-running phase 1's download loop against
#                         them, repeated until every year reached
#                         100/100.
#   Phase 3: convert    - see frontiers_convert.R. GROBID-converts all
#                         PDFs, assembles RDS + manifest.
#   Phase 4: cleanup    - 60 articles had a garbled or missing
#                         GROBID-extracted DOI (GROBID had pulled a
#                         reference's DOI instead of the article's own,
#                         a known failure mode on some PDF layouts);
#                         corrected from the verified CrossRef sample
#                         DOI. 4 articles had no GROBID-extracted title;
#                         backfilled from the CrossRef sample title.

# -- Phase 1+2: download (see frontiers_download.R for full implementation) --
# source("frontiers_download.R")   # run repeatedly per-year until 100/year

# -- Phase 3: convert (see frontiers_convert.R for full implementation) --
# source("frontiers_convert.R")

# -- Phase 4: cleanup ---------------------------------------------------------

suppressMessages(library(metacheck))

papers  <- readRDS("frontiers.rds")
sampled <- read.csv("frontiers/sample.csv", stringsAsFactors = FALSE)

fnames <- sapply(papers, function(p) basename(p$info$file_name))
ids    <- sub("^frontiers\\.", "", fnames) |> sub("\\.xml$", "", x = _)

sample_doi   <- setNames(sampled$doi, sampled$article_id)
sample_title <- setNames(sampled$title, sampled$article_id)

for (i in seq_along(papers)) {
  expected_doi <- sample_doi[[ids[i]]]
  actual_doi   <- papers[[i]]$info$doi
  if (is.null(actual_doi) || !nzchar(actual_doi) || !identical(tolower(actual_doi), tolower(expected_doi %||% ""))) {
    papers[[i]]$info$doi <- expected_doi
  }
  if (!nzchar(papers[[i]]$info$title %||% "")) {
    papers[[i]]$info$title <- sample_title[[ids[i]]]
  }
}

saveRDS(papers, "frontiers.rds")
message("Build complete: ", length(papers), " papers in frontiers.rds")