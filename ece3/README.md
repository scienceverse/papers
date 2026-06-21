# Ecology and Evolution corpus

A stratified sample of 1,543 articles published in *Ecology and
Evolution* between 2011 and 2026, assembled for validation of AI and
text-mining tools.

## Contents

| File | Description |
|------|--------------|
| `manifest.csv` | One row per paper: DOI, title, year, license, filenames, provenance |
| `metadata.json` | Dublin Core metadata for this corpus |
| `build.R` | Fully reproducible build script |
| `pdf/ece3.<id>.pdf` | Original PDF files (1,543 files, split across release assets) |
| `ece3.rds` | Compiled metacheck paperlist (GitHub Release asset) |

## Coverage

- **Journal**: Ecology and Evolution (ISSN 2045-7758)
- **Publisher**: Wiley (John Wiley & Sons)
- **Years**: 2011-2026 (target: 100 articles/year stratified random
  sample; 2011 only had 79 total articles in CrossRef for that year, and
  several other years fell slightly short of 100 because of download
  failures and one excluded non-article notice -- see Known gaps below)
- **Papers**: 1,543
- **License**: Mixed. Ecology and Evolution is a fully open-access
  journal, but the specific CC license varies by article: a random
  sample of 60 manifest entries found 49 CC-BY 4.0, 6 CC-BY 3.0, 4
  CC-BY-NC 3.0, and 1 article with only a generic Wiley
  terms-and-conditions link (no explicit CC license recorded in
  CrossRef). Check each article's own license before reuse -- do not
  assume CC-BY for the whole corpus.

## How papers were processed

Every *Ecology and Evolution* article is open access, but Wiley's own
PDF host (`onlinelibrary.wiley.com`) is effectively blocked for
automated downloads by active, adaptive Cloudflare bot protection (see
`downloading_articles.md`'s "Publisher access: a spectrum" section).
Every sampled DOI tested ahead of the full build had a Europe PMC
deposit with a downloadable PDF, so this corpus was downloaded entirely
via Europe PMC instead of attempting the Wiley host.

1. DOIs retrieved from CrossRef using ISSN 2045-7758, 2011-2026
2. Non-research records (corrections, errata, corrigenda, editorial
   notices) excluded by title pattern
3. 100 articles randomly sampled per year (seed 20260621)
4. OA status confirmed per article via the Unpaywall API (all 1,579
   sampled articles returned `is_oa: TRUE`, as expected for a fully-OA
   journal)
5. PDFs retrieved via each article's Europe PMC deposit
   (`europepmc.org/articles/{PMCID}?pdf=render`), resolved from the DOI
   via Europe PMC's REST search API
6. PDFs converted to TEI-XML using GROBID 0.9
7. XML files assembled into a metacheck paperlist using
   `metacheck::grobid_to_bibr()`

See `build.R` for the complete reproducible pipeline.

## Known gaps and data-quality notes

- **Intermittent download failures**: the initial download pass
  recovered 1,314/1,579 sampled articles (83%). Spot-checking several
  "failed" DOIs showed their Europe PMC PDFs downloaded successfully
  when retried in isolation seconds later -- the documented
  intermittent-failure pattern for long-running API call sequences, not
  a real coverage gap. Two full reruns of the (idempotent) download
  script recovered nearly all of the rest: 1,528, then 1,554/1,579
  (98.4%) after the second pass. The remaining 25 articles had no
  resolvable Europe PMC deposit and were accepted as a genuine, small
  gap rather than retried further.
- **Oversized PDFs**: 11 of the 1,554 downloaded PDFs exceeded GROBID's
  upload size limit ("Payload Too Large", files ranging 21-82MB) and
  were excluded without replacement.
- **One mistyped non-article notice**: `10.1002/ece3.8917`, a one-
  sentence erratum, was typed as `journal-article` in CrossRef with a
  title field containing only a non-breaking space -- invisible to the
  title-pattern filter, which matches on text. Found during a
  full-corpus audit (near-zero extracted text) and replaced with a
  same-year resample (`10.1002/ece3.9322`).
- **DOIs**: GROBID's header-extracted DOI was unreliable for 34
  articles; all affected `doi` values in `ece3.rds` and `manifest.csv`
  have been overwritten with the verified DOI from the original
  CrossRef sample.
- 10 articles have real, substantial body text but GROBID failed to
  extract a title from the PDF; for these, the title was backfilled
  directly from CrossRef's bibliographic record for that DOI.
- Final year coverage: 2011 (78), 2012 (94), 2013 (99), 2014 (100), 2015
  (100), 2016 (100), 2017 (100), 2018 (100), 2019 (100), 2020 (100), 2021
  (98), 2022 (98), 2023 (95), 2024 (94), 2025 (96), 2026 (91).

## Loading in R

```r
metacheck::papers_load('ece3')
papers <- metacheck::papers_load('ece3')
```
