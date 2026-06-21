# Open Mind corpus

A complete corpus of 293 articles published in *Open Mind* between
2017 and 2026, assembled for validation of AI and text-mining tools.

## Contents

| File | Description |
|------|--------------|
| `manifest.csv` | One row per paper: DOI, title, year, filenames, provenance |
| `metadata.json` | Dublin Core metadata for this corpus |
| `build.R` | Fully reproducible build script |
| `pdf/openmind.<id>.pdf` | Original PDF files (293 files) |
| `openmind.rds` | Compiled metacheck paperlist (GitHub Release asset) |

## Coverage

- **Journal**: Open Mind (E-ISSN 2470-2986)
- **Publisher**: MIT Press
- **Years**: 2017-2026
- **Papers**: 293 (this is a **complete corpus** -- Open Mind has only
  295 total CrossRef-registered journal-article records; 1 was a
  genuine non-article notice (bare "Erratum" title) and 1 PDF exceeded
  GROBID's upload size limit, both excluded)
- **License**: CC-BY 4.0 (Open Mind is a fully open-access MIT Press
  journal; CrossRef's `license` field was empty for 36/295 records
  despite this, confirmed empirically via Unpaywall rather than
  trusting CrossRef's field for this journal)

## How papers were processed

1. All 295 DOIs retrieved from CrossRef using ISSN 2470-2986 (no
   sampling needed -- this is the entire journal)
2. Non-research records excluded by title pattern (0 caught at this
   stage; 1 bare-"Erratum"-titled notice slipped through and was caught
   in the post-conversion audit instead)
3. PDFs downloaded via Unpaywall's `best_oa_location` URL, falling back
   to Europe PMC where available
4. PDFs converted to TEI-XML using GROBID 0.9
5. XML files assembled into a metacheck paperlist using
   `metacheck::grobid_to_bibr()`

See `build.R` for the complete reproducible pipeline.

## Known gaps and data-quality notes

- **MIT Press's PDF host (`direct.mit.edu`) is behind the same
  Cloudflare Client Hints check** documented for SAGE/i-Perception:
  requests with a Chrome User-Agent but no `Sec-CH-UA`/`Sec-CH-UA-
  Mobile`/`Sec-CH-UA-Platform` headers get flagged (`Cf-Mitigated:
  challenge`). Unlike SAGE, this check appeared to apply
  *probabilistically* even with the correct headers present (spot
  checks: 1 success in 5 identical requests) -- mitigated with a
  4-try retry-with-backoff wrapper around the download, which
  recovered the large majority of cases across two follow-up passes
  (63 -> 134 -> 279 -> 289 -> 294 PDFs across successive runs).
- **1 article's only resolvable PDF link was a DOI redirect**, not a
  direct PDF URL (Unpaywall's `best_oa_location.url` pointed at
  `doi.org/...` rather than a `direct.mit.edu` PDF link). Recovered by
  resolving the DOI redirect to the article landing page and scraping
  the `article-pdf/doi/...` link from the page HTML directly (same
  general technique as the eLife corpus's landing-page scrape).
- **1 PDF exceeded GROBID's upload size limit** ("Payload Too Large")
  and was excluded -- not replaced, since this is a complete corpus
  rather than a sample (no replacement candidate exists).
- **1 article was a genuine non-article notice**: a bare "Erratum"
  title (no colon, no trailing text -- the same edge case documented
  for i-Perception) that slipped through the title-pattern filter and
  was caught and dropped during the post-conversion quality audit.
- **3 articles** had a missing or garbled GROBID-extracted DOI;
  corrected from the verified CrossRef sample DOI.
- Final year coverage: 2017 (15), 2018 (4), 2019 (9), 2020 (8), 2021
  (14), 2022 (18), 2023 (45), 2024 (61), 2025 (89), 2026 (32) -- these
  reflect Open Mind's actual publication volume by year, not a
  sampling target (this is the complete journal).

## Loading in R

```r
metacheck::papers_load('openmind')
papers <- metacheck::papers_load('openmind')
```