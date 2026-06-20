# Psychological Science open-access subset corpus

A corpus of 270 articles published in *Psychological Science*, filtered
down from a larger locally-held collection to only those independently
confirmed to carry an open Creative Commons license (CC-BY or CC-BY-NC),
assembled for validation of AI and text-mining tools.

## Contents

| File | Description |
|------|--------------|
| `manifest.csv` | One row per paper: DOI, title, year, license URL, filenames, provenance |
| `metadata.json` | Dublin Core metadata for this corpus |
| `build.R` | Fully reproducible build script (license-check + filter step) |
| `pdf/psychsci_oa.<id>.pdf` | Original PDF files (270 files) |
| `psychsci_oa.rds` | Compiled metacheck paperlist (GitHub Release asset) |

## Coverage

- **Journal**: Psychological Science (ISSN 0956-7976, electronic ISSN 1467-9280)
- **Publisher**: SAGE Publications, for the Association for Psychological Science
- **Years**: 2014-2026 (uneven distribution -- see Known gaps below)
- **Papers**: 270, filtered from a locally-held collection of 1,903 PDFs
- **License**: CC-BY 4.0 or CC-BY-NC 4.0/3.0, per article -- check
  `manifest.csv`'s `license_url` column for the specific license of any
  given paper

## How this corpus was built

Unlike the other corpora in this repository, this one did not start with
a fresh CrossRef sample -- it started from a much larger, **already
downloaded** local collection of 1,903 *Psychological Science* PDFs
(SAGE DOI prefix `10.1177/`). Most articles in that journal are **not**
open access (SAGE journals typically only grant a text-and-data-mining
license, not a redistributable Creative Commons license), so before
building this corpus, every one of the 1,903 PDFs was checked against
CrossRef's `license` field for its DOI:

1. For each PDF, the DOI (`10.1177/{filename}`) was queried against
   CrossRef's `/works/{doi}` endpoint.
2. An article was classified **open** only if at least one of its
   license URLs pointed to `creativecommons.org/licenses/*` or
   `creativecommons.org/publicdomain/*`. SAGE's universal
   text-and-data-mining license (`journals.sagepub.com/page/policies/
   text-and-data-mining-license`) does **not** count as open on its own
   -- it permits computational analysis under a publisher agreement, not
   redistribution.
3. Of 1,903 PDFs checked, only **271** had a genuine CC license; 1,592
   did not (closed or TDM-only), and 40 had no CrossRef record to check.
4. Those 271 PDFs were copied into this corpus's `pdf/` folder and
   converted with GROBID; the publication year for each was looked up
   from CrossRef separately (not derivable from the DOI suffix).

See `build.R` for the complete reproducible pipeline, including the
license-classification logic.

## Known gaps and data-quality notes

- **Year distribution is uneven and skewed recent**: this corpus is *not*
  a stratified sample -- it is every open-access article that happened to
  be in the original 1,903-PDF local collection. Coverage by year:
  2014 (2), 2017 (7), 2018 (5), 2019 (9), 2020 (21), 2021 (51), 2022 (46),
  2023 (53), 2024 (32), 2025 (35), 2026 (1). There are no articles at all
  from 2015 or 2016 in this corpus -- this reflects gaps in the original
  local collection and/or in which articles SAGE made open access in
  those years, not a deliberate exclusion.
- **DOIs**: GROBID's header-extracted DOI was unreliable for 7 articles.
  All `doi` values in `psychsci_oa.rds` and `manifest.csv` have been
  overwritten with the verified DOI used to query CrossRef in the first
  place.
- 1 article was excluded after a full-corpus audit (an "Erratum to ..."
  notice with no real body content). 2 articles had real, substantial
  content but GROBID failed to extract a title from the PDF; for these
  two only, the title was backfilled directly from CrossRef's
  bibliographic record for that DOI (the same source used to confirm the
  license in the first place) rather than excluding otherwise-good
  papers.
- This corpus does **not** represent "all open-access Psychological
  Science articles" -- it represents the open-access subset of one
  particular local PDF collection. A genuinely complete open-access
  corpus for this journal would need a fresh CrossRef-wide scan rather
  than starting from a pre-existing download.

## Loading in R

```r
metacheck::papers_load('psychsci_oa')
papers <- metacheck::papers_load('psychsci_oa')
```