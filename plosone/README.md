# PLOS ONE corpus

A stratified random sample of 1,000 open-access articles published in
*PLOS ONE* from 2016 to 2025, assembled for validation of AI and
text-mining tools.

## Contents

| File | Description |
|------|--------------|
| `manifest.csv` | One row per paper: DOI, title, year, filenames, provenance |
| `metadata.json` | Dublin Core metadata for this corpus |
| `build.R` | Fully reproducible build script |
| `pdf/plosone.<id>.pdf` | Original PDF files (1,000 files) |
| `plosone.rds` | Compiled metacheck paperlist (GitHub Release asset) |

## Coverage

- **Journal**: PLOS ONE (ISSN 1932-6203)
- **Publisher**: Public Library of Science (PLOS)
- **Years**: 2016-2025
- **Papers**: 1,000 (stratified random sample, 100 per year, drawn from
  a pool of over 330,000 total articles -- PLOS ONE is by far the
  largest journal sampled for this repository)
- **License**: CC-BY 4.0 or CC0, depending on the article (PLOS applies
  CC0 to a subset of content; check each paper's own license before reuse
  if this matters for your use case)

## How papers were processed

1. DOIs retrieved from CrossRef using ISSN 1932-6203, 2016-2025
2. Non-research records (corrections, errata, retractions, replies to
   letters, editorial notices) excluded by title pattern
3. Stratified random sample of 100 articles per year (seed: 20260620)
4. Open-access PDFs downloaded via Unpaywall API, falling back to the
   PLOS direct-download URL pattern. PDFs whose file size exceeded
   GROBID's upload limit (~20MB+) were excluded and replaced with a
   smaller article from the same year.
5. PDFs converted to TEI-XML using GROBID 0.9
6. XML files assembled into a metacheck paperlist using
   `metacheck::grobid_to_bibr()`

See `build.R` for the complete reproducible pipeline.

## Known gaps and data-quality notes

- **DOIs**: GROBID's header-extracted DOI was unreliable for 2 articles
  (it picked up an unrelated DOI from elsewhere in the PDF). All `doi`
  values in `plosone.rds` and `manifest.csv` have been overwritten with
  the verified DOI from the original CrossRef sample, not GROBID's raw
  extraction.
- **Article IDs**: PLOS ONE's DOI suffixes are zero-padded to 7 digits
  (e.g. `0023765`). `article_id` is stored and read as a character
  string throughout the build pipeline -- reading `sample.csv` /
  `manifest.csv` with default `read.csv()` settings will silently strip
  the leading zero (R infers an all-digit character column as integer),
  breaking any lookup that depends on the exact filename. Always read
  with `colClasses = "character"` for the `article_id` column, or use
  `read.csv(..., colClasses = "character")` and re-cast other columns
  (e.g. `year`) manually afterward.
- 9 articles from the initial download failed due to PLOS rate-limiting a
  rapid sequence of requests; all 9 succeeded on retry with a longer delay
  between requests, so no replacement was needed.
- 8 articles from the initial sample had PDFs exceeding GROBID's upload
  size limit (concentrated in 2016-2018) and were replaced with fresh
  draws from the same per-year CrossRef pool, preserving the 100/year
  stratification.

## Loading in R

```r
metacheck::papers_load('plosone')
papers <- metacheck::papers_load('plosone')
```