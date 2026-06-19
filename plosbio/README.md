# PLOS Biology corpus

A stratified random sample of 1,000 open-access articles published in
*PLOS Biology* from 2016 to 2025, assembled for validation of AI and
text-mining tools.

## Contents

| File | Description |
|------|--------------|
| `manifest.csv` | One row per paper: DOI, title, year, filenames, provenance |
| `metadata.json` | Dublin Core metadata for this corpus |
| `build.R` | Fully reproducible build script |
| `pdf/plosbio.<id>.pdf` | Original PDF files (1,000 files) |
| `plosbio.rds` | Compiled metacheck paperlist (GitHub Release asset) |

## Coverage

- **Journal**: PLOS Biology (ISSN 1545-7885)
- **Publisher**: Public Library of Science (PLOS)
- **Years**: 2016-2025
- **Papers**: 1,000 (stratified random sample, 100 per year)
- **License**: CC-BY 4.0 or CC0, depending on the article (PLOS applies
  CC0 to a subset of content; check each paper's own license before reuse
  if this matters for your use case)

## How papers were processed

1. DOIs retrieved from CrossRef using ISSN 1545-7885, 2016-2025
2. Non-research records (corrections, errata, retractions, replies to
   letters, editorial notices, "Editorial Note" corrections, issue-cover
   images mistyped as articles) excluded by title pattern
3. Stratified random sample of 100 articles per year (seed: 20260619)
4. Open-access PDFs downloaded via Unpaywall API, falling back to the
   PLOS direct-download URL pattern. PDFs whose file size exceeded
   GROBID's upload limit (~20MB+, common for image-heavy biology figures)
   were excluded and replaced with a smaller article from the same year.
5. PDFs converted to TEI-XML using GROBID 0.9
6. XML files assembled into a metacheck paperlist using
   `metacheck::grobid_to_bibr()`

See `build.R` for the complete reproducible pipeline.

## Known gaps and data-quality notes

- **DOIs**: GROBID's header-extracted DOI was unreliable for 5 articles
  (it picked up an unrelated DOI from elsewhere in the PDF, including
  three cases of an entirely different journal's DOI). All `doi` values
  in `plosbio.rds` and `manifest.csv` have been overwritten with the
  verified DOI from the original CrossRef sample, not GROBID's raw
  extraction.
- 20 articles from the initial random sample were excluded after the fact
  (1 bogus "PLoS Biology Issue Image" record CrossRef mistyped as
  journal-article; 17 PDFs that exceeded GROBID's upload size limit,
  concentrated in 2016-2018; 1 editorial announcement and 1 "Editorial
  Note" correction notice not caught by the initial title filter) and
  replaced with fresh draws from the same per-year CrossRef pool,
  preserving the 100/year stratification.

## Loading in R

```r
metacheck::papers_load('plosbio')
papers <- metacheck::papers_load('plosbio')
```