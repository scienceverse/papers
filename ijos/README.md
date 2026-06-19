# International Journal of Oral Science corpus

A complete corpus of 724 open-access articles published in *International
Journal of Oral Science* from 2009 to 2026, assembled for validation of AI
and text-mining tools.

## Contents

| File | Description |
|------|--------------|
| `manifest.csv` | One row per paper: DOI, title, year, filenames, provenance |
| `metadata.json` | Dublin Core metadata for this corpus |
| `build.R` | Fully reproducible build script |
| `pdf/ijos.<id>.pdf` | Original PDF files (724 files, split across two release assets: `ijos_pdf_part1.zip`, `ijos_pdf_part2.zip`) |
| `ijos.rds` | Compiled metacheck paperlist (GitHub Release asset) |

## Coverage

- **Journal**: International Journal of Oral Science (ISSN 2049-3169)
- **Publisher**: Springer Nature (Nature Publishing Group)
- **Years**: 2009-2026
- **Papers**: 724 (complete corpus, out of 728 sampled DOIs)
- **License**: Mostly CC-BY 4.0; a minority of articles are CC-BY-NC-ND
  3.0/4.0 -- check each article's own license before reuse

## How papers were processed

1. DOIs retrieved from CrossRef using ISSN 2049-3169, 2009-2026
2. Non-research records (corrections, errata, meeting reports) excluded
   by title pattern
3. Two duplicate DOI registrations of the same articles removed (CrossRef
   occasionally has two DOIs for one article, e.g. `10.4248/ijos.09061`
   and `10.4248/ijos09061`)
4. Open-access PDFs downloaded via Unpaywall API. When Unpaywall had no
   direct PDF link (common for very recently published articles not yet
   re-crawled), the publisher's PDF URL was reconstructed by resolving the
   DOI's redirect chain (`doi.org/{doi}` -> Nature's real article slug),
   since Nature's article-slug format changed over the journal's history
   (older `ijos.YYYY.NN`-style DOIs map to dotless slugs, newer
   `s41368-...`-style DOIs keep their dashes)
5. PDFs converted to TEI-XML using GROBID 0.9
6. XML files assembled into a metacheck paperlist using
   `metacheck::grobid_to_bibr()`

See `build.R` for the complete reproducible pipeline.

## Known gaps and data-quality notes

- **DOIs**: GROBID's header-extracted DOI was unreliable for 87 articles
  (case mismatches and a few truncated DOI strings). All `doi` values in
  `ijos.rds` and `manifest.csv` have been overwritten with the verified
  DOI from the original CrossRef sample, not GROBID's raw extraction.
- 4 articles were excluded after download: 3 PDFs exceeded GROBID's
  upload size limit (21-26 MB, likely due to embedded high-resolution
  figures), and 1 PDF (`ijos.2013.73`) has a malformed internal structure
  that GROBID consistently rejects with an Internal Server Error even
  after a fresh re-download confirmed the file itself downloads correctly.

## Loading in R

```r
metacheck::papers_load('ijos')
papers <- metacheck::papers_load('ijos')
```