# Nature Communications corpus

A stratified sample of 1000 articles published in *Nature Communications*
between 2017 and 2026 (100 per year), assembled for validation of AI and
text-mining tools.

## Contents

| File | Description |
|------|--------------|
| `manifest.csv` | One row per paper: DOI, title, year, filenames, provenance |
| `metadata.json` | Dublin Core metadata for this corpus |
| `build.R` | Fully reproducible build script |
| `pdf/natcomm.<id>.pdf` | Original PDF files (1000 files, split across two release assets: `natcomm_pdf_part1.zip`, `natcomm_pdf_part2.zip`) |
| `natcomm.rds` | Compiled metacheck paperlist (GitHub Release asset) |

## Coverage

- **Journal**: Nature Communications (ISSN 2041-1723)
- **Publisher**: Springer Nature (Nature Publishing Group)
- **Years**: 2017-2026, exactly 100 articles per year (stratified random
  sample, not a complete corpus -- this journal publishes thousands of
  articles per year)
- **Papers**: 1000
- **License**: Mostly CC-BY 4.0; a minority of articles are CC-BY-NC-ND
  4.0 -- check each article's own license before reuse

## How papers were processed

1. DOIs retrieved from CrossRef using ISSN 2041-1723, 2017-2026
2. Non-research records (corrections, errata, addenda, meeting reports)
   excluded by title pattern
3. 100 articles randomly sampled per year (seed 20260620)
4. Open-access PDFs downloaded via Unpaywall API. When Unpaywall had no
   direct PDF link (common for very recently published articles not yet
   re-crawled), the publisher's PDF URL was reconstructed by resolving
   the DOI's redirect chain (`doi.org/{doi}` -> nature.com's real
   article slug)
5. PDFs converted to TEI-XML using GROBID 0.9
6. XML files assembled into a metacheck paperlist using
   `metacheck::grobid_to_bibr()`

See `build.R` for the complete reproducible pipeline.

## Known gaps and data-quality notes

- **Resampling**: 18 articles initially sampled from 2026 were in-press
  (PDF not yet rendered on nature.com) and were replaced with fresh 2026
  draws. 7 articles failed GROBID conversion (6 PDFs too large for the
  conversion endpoint's upload limit, 1 transient HTTP failure) and were
  replaced with fresh same-year draws. 1 further article turned out to be
  an "Addendum: ..." notice (a correction-style record not caught by the
  title-pattern filter) and was replaced with one more same-year draw.
  Each replacement preserves the exact 100/year stratification.
- **DOIs**: GROBID's header-extracted DOI was unreliable for 1 article
  (a "Matters Arising" commentary, where GROBID picked up a garbled
  DOI string). Its `doi` value in `natcomm.rds` and `manifest.csv` has
  been overwritten with the verified DOI from the original CrossRef
  sample.
- 22 articles have real, substantial body text but GROBID failed to
  extract a title from the PDF; for these, the title was backfilled
  directly from CrossRef's bibliographic record for that DOI rather than
  excluding otherwise-good papers.

## Loading in R

```r
metacheck::papers_load('natcomm')
papers <- metacheck::papers_load('natcomm')
```