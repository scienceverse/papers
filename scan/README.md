# Social Cognitive and Affective Neuroscience (SCAN) corpus

A stratified sample of 803 articles published in *Social Cognitive and
Affective Neuroscience* between 2017 and 2026, assembled for validation
of AI and text-mining tools.

## Contents

| File | Description |
|------|--------------|
| `manifest.csv` | One row per paper: DOI, title, year, license, filenames, provenance |
| `metadata.json` | Dublin Core metadata for this corpus |
| `build.R` | Fully reproducible build script |
| `pdf/scan.<id>.pdf` | Original PDF files (803 files, split across release assets) |
| `scan.rds` | Compiled metacheck paperlist (GitHub Release asset) |

## Coverage

- **Journal**: Social Cognitive and Affective Neuroscience (ISSN 1749-5016)
- **Publisher**: Oxford University Press (OUP)
- **Years**: 2017-2026 (target: 100 articles/year stratified random
  sample; some years fell short because of two later exclusion rounds
  -- see Known gaps below)
- **Papers**: 803
- **License**: Mixed CC-BY 4.0, CC-BY-NC 4.0, CC-BY-NC-ND 4.0, and a
  minority of public-domain or unspecified-but-confirmed-OA records --
  check each article's own license in `manifest.csv` before reuse

## How papers were processed

SCAN is a **hybrid** journal (not every article is open access), unlike
most other corpora in this repository. Each sampled article's OA status
was verified individually via Unpaywall before download, rather than
assumed from the journal's overall policy.

1. DOIs retrieved from CrossRef using ISSN 1749-5016, 2017-2026
2. Non-research records (corrections, errata, corrigenda, editorial
   notices) excluded by title pattern
3. 100 articles randomly sampled per year (seed 20260620)
4. OA status confirmed per article via the Unpaywall API
5. OUP's direct PDF host (`academic.oup.com`) is protected by a
   Cloudflare JS challenge that blocks automated downloads even for
   genuinely open-access articles, so PDFs were instead retrieved via
   each article's Europe PMC deposit (`europepmc.org/articles/{PMCID}
   ?pdf=render`), resolved from the DOI via Europe PMC's REST search API
6. PDFs converted to TEI-XML using GROBID 0.9
7. XML files assembled into a metacheck paperlist using
   `metacheck::grobid_to_bibr()`

See `build.R` for the complete reproducible pipeline.

## Known gaps and data-quality notes

- **Oversized PDFs**: 50 articles' PDFs exceeded GROBID's upload size
  limit ("Payload Too Large"). Resampling found Europe PMC deposits for
  only 14 of the 50 needed replacements -- deposit coverage for this
  journal is sparse in several years, so this gap could not be fully
  closed. The 36 unreplaced slots reduce some years below the 100/year
  target (see the year breakdown in `manifest.csv`).
- **Non-article notices**: a full-corpus audit found 9 articles that
  were actually correction/erratum/editorial notices not caught by the
  initial title-pattern filter (8 "Corrigendum to: ..." / "Publisher's
  Note: ..." notices with genuinely thin content, plus one 2-page
  editorial note). These were dropped; resampling found Europe PMC
  replacements for 8 of the 9.
- **DOIs**: GROBID's header-extracted DOI was unreliable for 109
  articles (missing, truncated, or a citation's DOI picked up from the
  references section instead of the article's own). All affected `doi`
  values in `scan.rds` and `manifest.csv` have been overwritten with the
  verified DOI from the original CrossRef sample.
- 4 articles have real, substantial body text but GROBID failed to
  extract a title from the PDF; for these, the title was backfilled
  directly from CrossRef's bibliographic record for that DOI rather than
  excluding otherwise-good papers.
- Final year coverage: 2017 (100), 2018 (100), 2019 (71), 2020 (100),
  2021 (100), 2022 (61), 2023 (75), 2024 (78), 2025 (100), 2026 (46).

## Loading in R

```r
metacheck::papers_load('scan')
papers <- metacheck::papers_load('scan')
```