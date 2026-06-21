# Frontiers in Psychology corpus

A stratified sample of 1000 articles published in *Frontiers in
Psychology* between 2017 and 2026, assembled for validation of AI and
text-mining tools.

## Contents

| File | Description |
|------|--------------|
| `manifest.csv` | One row per paper: DOI, title, year, filenames, provenance |
| `metadata.json` | Dublin Core metadata for this corpus |
| `build.R` | Fully reproducible build script |
| `pdf/frontiers.<id>.pdf` | Original PDF files (1000 files) |
| `frontiers.rds` | Compiled metacheck paperlist (GitHub Release asset) |

## Coverage

- **Journal**: Frontiers in Psychology (ISSN 1664-1078)
- **Publisher**: Frontiers Media
- **Years**: 2017-2026 (target: 100 articles/year stratified random
  sample -- fully met, 100/100 every year)
- **Papers**: 1000
- **License**: CC-BY 4.0 (Frontiers is a fully open-access publisher,
  confirmed via CrossRef license sampling)

## How papers were processed

1. DOIs retrieved from CrossRef using ISSN 1664-1078, 2017-2026.
   Frontiers in Psychology has roughly 51,000 articles in total, far
   too many for a complete corpus, so this is a stratified random
   sample.
2. Non-research records (corrections, errata, editorial notices)
   excluded by title pattern
3. 100 articles randomly sampled per year
4. PDFs downloaded via the DOI -> Unpaywall OA check -> Europe PMC
   PMCID lookup -> `europepmc.org` direct-PDF route (Frontiers has
   strong Europe PMC deposit coverage)
5. PDFs converted to TEI-XML using GROBID 0.9
6. XML files assembled into a metacheck paperlist using
   `metacheck::grobid_to_bibr()`

See `build.R` for the complete reproducible pipeline.

## Known gaps and data-quality notes

- **Several years initially came up short of the 100/year target**
  during the first download pass, due to a mix of an unresolved
  intermittent Unpaywall/Europe PMC API failure rate (see
  `downloading_articles.md` at the repo root) and a few CrossRef
  year-fetch glitches (some years briefly returned 0 results on a
  given query despite real articles existing -- resolved by
  re-querying). All gaps were closed by resampling replacement DOIs
  from the same year until 100/year was reached for every year,
  2017-2026.
- **60 articles had a garbled or missing GROBID-extracted DOI**: in
  most cases GROBID had extracted a DOI belonging to one of the
  article's own references instead of the article's own DOI (a known
  GROBID failure mode on some PDF layouts). All 60 were corrected
  using the verified CrossRef sample DOI.
- **4 articles** had real, substantial content but no
  GROBID-extracted title; backfilled from the CrossRef sample title.
- No duplicate DOIs, no duplicate article IDs, no thin-content
  papers (<1000 characters), and no non-article notices slipped
  through the title filter.

## Loading in R

```r
metacheck::papers_load('frontiers')
papers <- metacheck::papers_load('frontiers')
```