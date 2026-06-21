# eLife corpus

A stratified sample of 1000 articles published in *eLife* between 2017
and 2026, assembled for validation of AI and text-mining tools.

## Contents

| File | Description |
|------|--------------|
| `manifest.csv` | One row per paper: DOI, title, year, filenames, provenance |
| `metadata.json` | Dublin Core metadata for this corpus |
| `build.R` | Fully reproducible build script |
| `pdf/elife.<id>.pdf` | Original PDF files (1000 files, split across 3 zip parts) |
| `elife.rds` | Compiled metacheck paperlist (GitHub Release asset) |

## Coverage

- **Journal**: eLife (ISSN 2050-084X)
- **Publisher**: eLife Sciences Publications
- **Years**: 2017-2026 (target: 100 articles/year stratified random
  sample -- fully met)
- **Papers**: 1000
- **License**: CC-BY 4.0 (eLife is a fully open-access publisher,
  confirmed via CrossRef license sampling -- three license records per
  article: vor/am/tdm all CC-BY)

## How papers were processed

1. DOIs retrieved from CrossRef using ISSN 2050-084X, 2017-2026
2. Non-research records excluded by title pattern
3. 100 articles randomly sampled per year
4. PDFs downloaded via the DOI -> Unpaywall OA check -> Europe PMC
   PMCID lookup -> europepmc.org direct-PDF route, with a fallback to
   scraping the signed direct-download link from the elifesciences.org
   article landing page when Europe PMC had no deposit
5. PDFs converted to TEI-XML using GROBID 0.9
6. XML files assembled into a metacheck paperlist using
   `metacheck::grobid_to_bibr()`

See `build.R` for the complete reproducible pipeline.

## Known gaps and data-quality notes

- **eLife uses a "Reviewed Preprint" versioning scheme** for some
  articles: a DOI like `10.7554/eLife.88799` can have a separate,
  distinctly-registered DOI `10.7554/eLife.88799.3` for a specific
  reviewed-preprint revision. This required normalizing DOIs (stripping
  the version suffix) both when constructing the elifesciences.org
  landing-page URL (the URL has no version suffix) and when checking
  for duplicate articles during resampling -- an earlier resampling
  pass missed this normalization and briefly introduced a duplicate
  article under two different DOI registrations, caught and corrected
  before publishing.
- **The elifesciences.org landing-page scrape required three
  iterations to become reliable.** What initially looked like ordinary
  intermittent API flakiness (the same failure pattern documented for
  Unpaywall/Europe PMC elsewhere in this project) turned out to be
  three separate deterministic bugs: (1) the version-suffix DOI issue
  above causing 404s on the landing page URL itself; (2) the page
  links several PDFs (the article, a combined figures supplement, and
  per-figure source-data files) and an unanchored filename pattern
  could pick up a supplementary-data file instead of the article; (3)
  R's default regex engine occasionally mis-located the match start by
  one byte on certain UTF-8 pages, truncating the extracted URL's
  scheme (`ttps://` instead of `https://`) -- fixed with `perl = TRUE`.
  All three were root-caused and fixed; the corpus's PDFs were spot-
  checked afterward (page count, embedded title metadata) to confirm
  none were affected by the supplementary-data substitution bug before
  it was fixed (it wasn't -- the version-suffix bug had been blocking
  those specific DOIs from ever reaching that code path).
- **14 articles' PDFs exceeded GROBID's upload size limit** ("Payload
  Too Large") across the full build; each was resampled from the same
  year's CrossRef pool until a replacement was found, keeping year
  balance close to the 100/year target (final: 2024 at 101, 2026 at 99,
  all other years at exactly 100 -- a one-slot variance from a
  resample that drew its replacement from an adjacent year's pool).
- **441 articles** had a missing, garbled, or version-suffix-only
  differing GROBID-extracted DOI; corrected from the verified CrossRef
  sample DOI. **23 articles** had real, substantial content but no
  GROBID-extracted title (common for eLife's short "Insight" commentary
  pieces); backfilled from the CrossRef sample title.

## Loading in R

```r
metacheck::papers_load('elife')
papers <- metacheck::papers_load('elife')
```