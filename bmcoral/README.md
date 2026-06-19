# BMC Oral Health corpus

A stratified random sample of 1,000 open-access articles published in
*BMC Oral Health* from 2016 to 2025, assembled for validation of AI and
text-mining tools.

## Contents

| File | Description |
|------|--------------|
| `manifest.csv` | One row per paper: DOI, title, year, filenames, provenance |
| `metadata.json` | Dublin Core metadata for this corpus |
| `build.R` | Fully reproducible build script |
| `pdf/bmcoral.<id>.pdf` | Original PDF files (1,000 files) |
| `bmcoral.rds` | Compiled metacheck paperlist (GitHub Release asset) |

## Coverage

- **Journal**: BMC Oral Health (ISSN 1472-6831)
- **Publisher**: BioMed Central / Springer Nature
- **Years**: 2016-2025
- **Papers**: 1,000 (stratified random sample, 100 per year)
- **License**: Mostly CC-BY 4.0; a minority of articles are
  CC-BY-NC-ND 4.0 -- check each article's own license before reuse

## How papers were processed

1. DOIs retrieved from CrossRef using ISSN 1472-6831, 2016-2025
2. Non-research records (corrections, errata, retractions, replies to
   letters, meeting reports) excluded by title pattern
3. Stratified random sample of 100 articles per year (seed: 20260619)
4. Open-access PDFs downloaded via Unpaywall API, falling back to the
   Springer `link.springer.com/content/pdf` direct-download URL pattern
5. PDFs converted to TEI-XML using GROBID 0.9
6. XML files assembled into a metacheck paperlist using
   `metacheck::grobid_to_bibr()`

See `build.R` for the complete reproducible pipeline.

## Known gaps and data-quality notes

- **DOIs**: every paper's `doi` value in `bmcoral.rds` and
  `manifest.csv` was overwritten with the verified DOI from the original
  CrossRef sample (rather than trusting GROBID's raw header extraction),
  consistent with the approach used for the other corpora in this
  repository.
- 21 articles from the initial random sample were excluded after the fact
  (1 PDF exceeded GROBID's upload size limit; 20 had a GROBID parsing gap
  that left `titleStmt/title` empty despite substantial extracted body
  text) and replaced with fresh draws from the same per-year CrossRef
  pool, preserving the 100/year stratification.

## Loading in R

```r
metacheck::papers_load('bmcoral')
papers <- metacheck::papers_load('bmcoral')
```