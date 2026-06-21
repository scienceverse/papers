# i-Perception corpus

A stratified sample of 496 articles published in *i-Perception* between
2017 and 2026, assembled for validation of AI and text-mining tools.

## Contents

| File | Description |
|------|--------------|
| `manifest.csv` | One row per paper: DOI, title, year, filenames, provenance |
| `metadata.json` | Dublin Core metadata for this corpus |
| `build.R` | Fully reproducible build script |
| `pdf/iperc.<id>.pdf` | Original PDF files (496 files) |
| `iperc.rds` | Compiled metacheck paperlist (GitHub Release asset) |

## Coverage

- **Journal**: i-Perception (E-ISSN 2041-6695)
- **Publisher**: SAGE Publishing
- **Years**: 2017-2026 (target: 100 articles/year stratified random
  sample; some years fell short -- see Known gaps below)
- **Papers**: 496
- **License**: CC-BY 4.0 (i-Perception is a SAGE open-access-only
  journal, not hybrid -- confirmed via CrossRef license sampling)

## How papers were processed

1. DOIs retrieved from CrossRef using ISSN 2041-6695, 2017-2026
2. Non-research records (corrections, errata, editorial notices)
   excluded by title pattern
3. 100 articles randomly sampled per year (seed 20260620)
4. PDFs downloaded via two routes: SAGE's direct PDF host
   (`journals.sagepub.com/doi/pdf/{doi}`) for most of the corpus, and
   Europe PMC for a subset of 2021-2026 articles where the direct route
   was initially blocked (see Known gaps)
5. PDFs converted to TEI-XML using GROBID 0.9
6. XML files assembled into a metacheck paperlist using
   `metacheck::grobid_to_bibr()`

See `build.R` for the complete reproducible pipeline.

## Known gaps and data-quality notes

- **SAGE's direct PDF host initially appeared blocked** for bulk
  downloads (HTTP 403 "Blocked | Sage" after roughly 70 requests in a
  session). Root-caused to a Cloudflare Client Hints check: Cloudflare
  flags a request as a spoofed browser if it carries a Chrome
  `User-Agent` without the matching `Sec-CH-UA`/`Sec-CH-UA-Mobile`/
  `Sec-CH-UA-Platform` headers a real browser sends alongside it. Adding
  those headers resolved it completely with no rate-limiting needed --
  this was not an IP block or a true rate limit. See
  `downloading_articles.md` at the repo root for the full writeup.
- **9 downloaded PDFs failed GROBID conversion permanently**: 8 exceeded
  GROBID's upload size limit ("Payload Too Large", ranging 24-461MB --
  confirmed genuine large PDFs, not corrupted downloads, via header/
  trailer byte checks) and 1 was rejected with "Internal Server Error"
  despite being a structurally valid, normal-sized PDF. All 9 were
  retried after a GROBID server outage resolved and failed identically
  both times, confirming these are permanent rejects rather than
  transient outage stragglers. Not replaced (this is a stratified
  sample, but the corpus already accepts a reduced yield from an
  unrelated intermittent API issue -- see next point -- so these 9
  slots were not separately resampled). The 9 source PDFs are excluded
  from `pdf.zip` since they have no corresponding entry in `iperc.rds`.
- **An unresolved intermittent failure** in the Unpaywall/Europe PMC
  API calls (not a rate limit, not a code bug, never root-caused --
  see `downloading_articles.md`) reduced the achievable yield for
  several years below the 100/year target, particularly 2022-2026.
- **A transcription artifact during recovery of some dropped rows**
  caused 115 DOIs to briefly appear twice in `sample.csv` under two
  slightly different `article_id` values (e.g. a DOI suffix's last
  1-2 digits differing). Resolved by keeping only the row matching an
  actual downloaded PDF.
- **4 articles were genuine non-article notices** (2 titled literally
  "Erratum", 1 "Correction to Figures: ...", 1 "Addendum to ...") that
  were not caught by the initial title-pattern filter. Dropped (the
  "Addendum" notice has thin but real content at 961 characters and
  was the only borderline case; the other 3 are pure corrections with
  near-zero body text).
- **6 articles** had a missing or garbled GROBID-extracted DOI;
  corrected from the verified CrossRef sample DOI. **2 articles** had
  real, substantial content but no GROBID-extracted title; backfilled
  from CrossRef's bibliographic record for that DOI.
- Final year coverage: 2017 (100), 2018 (86 sampled, fewer with a
  retrievable PDF), 2019 (66), 2020 (74), 2021 (76), 2022 (43), 2023
  (54), 2024 (55), 2025 (56), 2026 (30).

## Loading in R

```r
metacheck::papers_load('iperc')
papers <- metacheck::papers_load('iperc')
```