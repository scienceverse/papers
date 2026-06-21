# Build script: eLife corpus for scienceverse/papers
#
# Produces:
#   elife/sample.csv   the sampled DOIs (100/year target, 2017-2026)
#   elife/pdf/         1000 PDF files (CC-BY 4.0)
#   elife/manifest.csv one row per paper with provenance metadata
#   elife.rds          metacheck paperlist object (GitHub release asset)
#
# Requirements:
#   R packages: httr2, metacheck (scienceverse/metacheck)
#   metacheck::email() set to a valid address for Unpaywall API
#   GROBID 0.9 instance (used: https://grobid.work.abed.cloud)
#
# eLife has roughly 22,400 articles in total, far too many for a
# complete corpus, so this is a STRATIFIED RANDOM SAMPLE (100/year
# target, 2017-2026). eLife is a fully open-access publisher (CC-BY
# 4.0 confirmed via CrossRef license sampling).
#
# Phases, reflecting the pipeline as actually run:
#   Phase 1: download   - see elife_download.R. Samples 100 DOIs/year,
#                         downloads via Unpaywall -> Europe PMC route.
#   Phase 2: retry      - the Unpaywall/Europe PMC route alone only
#                         reached ~608/1000 on the first pass (the
#                         intermittent API-failure pattern documented
#                         in downloading_articles.md, compounded by
#                         genuinely sparser Europe PMC deposit coverage
#                         for recent years). See elife_retry_missing.R:
#                         added an elifesciences.org landing-page
#                         scrape fallback (extracts the signed
#                         direct-download PDF link from the article
#                         page's HTML) for DOIs Europe PMC had no
#                         deposit for.
#   Phase 3: bug fixes  - the scrape fallback needed three separate
#                         fixes before it was reliable: (a) strip a
#                         trailing DOI version suffix (eLife's
#                         "Reviewed Preprint" scheme, e.g. ".3") before
#                         constructing the landing-page URL -- left
#                         unstripped, this 404s; (b) anchor the PDF
#                         filename pattern to "elife-<num>-v<n>.pdf"
#                         exactly, since the page also links a combined
#                         figures PDF and per-figure source-data PDFs
#                         that an unanchored pattern could match
#                         instead; (c) pass perl = TRUE to regexpr(),
#                         since R's default regex engine occasionally
#                         mis-located the match start by one byte on
#                         some UTF-8 pages, truncating the URL's scheme.
#                         After these fixes, repeated retry passes
#                         closed the gap to 1000/1000.
#   Phase 4: convert    - GROBID-converts all PDFs (14 "Payload Too
#                         Large" exclusions across the full build,
#                         each resampled from the same year), assembles
#                         RDS + manifest.
#   Phase 5: cleanup    - 441 garbled/missing/version-suffix-only
#                         DOIs corrected from the verified CrossRef
#                         sample DOI, 23 missing titles backfilled
#                         (eLife's short "Insight" commentary pieces
#                         often have no GROBID-extracted title). One
#                         resampled replacement (elife.92805) was found
#                         to duplicate an already-sampled article
#                         registered under a different DOI-version
#                         (elife.92805.3) -- caught via DOI-normalized
#                         duplicate detection and replaced.

# -- Phase 1+2+3: download + retry (see elife_download.R and
# -- elife_retry_missing.R for full implementation)
# source("elife_download.R")
# source("elife_retry_missing.R")   # idempotent; rerun until 1000/1000

# -- Phase 4: convert (see elife_convert.R for full implementation) --
# source("elife_convert.R")

# -- Phase 5: cleanup ---------------------------------------------------------

suppressMessages(library(metacheck))

papers  <- readRDS("elife.rds")
sampled <- read.csv("elife/sample.csv", stringsAsFactors = FALSE, colClasses = "character")

fnames <- sapply(papers, function(p) basename(p$info$file_name))
ids    <- sub("^elife\\.", "", fnames) |> sub("\\.xml$", "", x = _)

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

saveRDS(papers, "elife.rds")
message("Build complete: ", length(papers), " papers in elife.rds")