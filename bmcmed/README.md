# BMC Medicine corpus

A stratified random sample of 1,000 open-access articles published in
*BMC Medicine* from 2016 to 2025, assembled for validation of AI and
text-mining tools.

## Contents

| File | Description |
|------|--------------|
| `manifest.csv` | One row per paper: DOI, title, year, filenames, provenance |
| `metadata.json` | Dublin Core metadata for this corpus |
| `build.R` | Fully reproducible build script |
| `pdf/bmcmed.<id>.pdf` | Original PDF files (1,000 files, ~1.7 GB total) |
| `bmcmed.rds` | Compiled metacheck paperlist (GitHub Release asset) |

## Coverage

- **Journal**: BMC Medicine (ISSN 1741-7015)
- **Publisher**: BioMed Central / Springer Nature
- **Years**: 2016-2025
- **Papers**: 1,000 (stratified random sample, 100 per year)
- **License**: CC-BY 4.0

## How papers were processed

1. DOIs retrieved from CrossRef using ISSN 1741-7015, 2016-2025
2. Non-research records (corrections, errata, retractions, replies to
   letters and commentaries) excluded by title pattern
3. Stratified random sample of 100 articles per year (seed: 20260618)
4. Open-access PDFs downloaded via Unpaywall API, falling back to the BMC
   `track/pdf` direct-download URL pattern
5. PDFs converted to TEI-XML using GROBID 0.9
6. XML files assembled into a metacheck paperlist using
   `metacheck::grobid_to_bibr()`

See `build.R` for the complete reproducible pipeline.

## Known gaps and data-quality notes

- **DOIs**: GROBID's header-extracted DOI was unreliable for 33 articles
  (it sometimes picked up a DOI from the reference list or elsewhere in the
  PDF instead of the article's own header DOI). All `doi` values in
  `bmcmed.rds` and `manifest.csv` have been overwritten with the verified
  DOI from the original CrossRef sample, not GROBID's raw extraction.
- 36 articles from the initial random sample were excluded after the fact
  (1 download failure; 8 GROBID conversion failures during a transient
  server outage; 5 GROBID parsing failures with empty title metadata,
  3 of which were retraction notices; 22 correction/erratum/reply-to-letter
  notices that CrossRef mistyped as `journal-article` and were not caught
  by the initial title filter) and replaced with fresh draws from the same
  per-year CrossRef pool, preserving the 100/year stratification.

## Loading in R

```r
papers <- metacheck::papers_load('bmcmed')
```