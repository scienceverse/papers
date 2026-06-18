# PLOS Medicine corpus

A stratified random sample of 1,000 open-access articles published in
*PLOS Medicine* from 2016 to 2025, assembled for validation of AI and
text-mining tools.

## Contents

| File | Description |
|------|--------------|
| `manifest.csv` | One row per paper: DOI, title, year, filenames, provenance |
| `metadata.json` | Dublin Core metadata for this corpus |
| `build.R` | Fully reproducible build script |
| `pdf/plosmed.<id>.pdf` | Original PDF files (1,000 files, ~1.4 GB total) |
| `plosmed.rds` | Compiled metacheck paperlist (GitHub Release asset) |

## Coverage

- **Journal**: PLOS Medicine (ISSN 1549-1676)
- **Publisher**: Public Library of Science (PLOS)
- **Years**: 2016-2025
- **Papers**: 1,000 (stratified random sample, 100 per year)
- **License**: CC-BY 4.0 or CC0, depending on the article (PLOS applies CC0
  to a subset of content; check each paper's own license before reuse if
  this matters for your use case)

## How papers were processed

1. DOIs retrieved from CrossRef using ISSN 1549-1676, 2016-2025
2. Non-research records (corrections, errata, retractions, replies to
   letters, editorial notices such as "Call for Papers" or "Reviewer and
   Editorial Board Thank You") excluded by title pattern
3. Stratified random sample of 100 articles per year (seed: 20260618)
4. Open-access PDFs downloaded via Unpaywall API, falling back to the PLOS
   direct-download URL pattern
5. PDFs converted to TEI-XML using GROBID 0.9
6. XML files assembled into a metacheck paperlist using
   `metacheck::grobid_to_bibr()`

See `build.R` for the complete reproducible pipeline.

## Known gaps and data-quality notes

- **DOIs**: GROBID's header-extracted DOI was unreliable for a small number
  of articles (it occasionally picked up a DOI from elsewhere in the PDF
  rather than the article's own). All `doi` values in `plosmed.rds` and
  `manifest.csv` have been overwritten with the verified DOI from the
  original CrossRef sample, not GROBID's raw extraction.
- **Authors**: 4 papers (consortium/editorial-board bylines, e.g. malERA
  panel reports, "The PLOS Medicine Editors") have no structured author
  list extracted -- GROBID's author-block parser does not handle
  collective bylines. Title, DOI, and body text are unaffected.
- 9 articles from the initial random sample were excluded after the fact
  (1 non-article CrossRef mistyped as journal-article; 4 editorial/call-for-
  papers notices not caught by the initial title filter; 4 GROBID parsing
  failures or assembly errors) and replaced with fresh draws from the same
  per-year CrossRef pool, preserving the 100/year stratification.

## Loading in R

```r
metacheck::papers_download('plosmed')
papers <- metacheck::papers_load('plosmed')
```