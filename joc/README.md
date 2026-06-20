# Journal of Cognition corpus

A complete corpus of 447 open-access articles published in *Journal of
Cognition* from 2017 to 2026, assembled for validation of AI and
text-mining tools.

## Contents

| File | Description |
|------|--------------|
| `manifest.csv` | One row per paper: DOI, title, year, filenames, provenance |
| `metadata.json` | Dublin Core metadata for this corpus |
| `build.R` | Fully reproducible build script |
| `pdf/joc.<id>.pdf` | Original PDF files (447 files) |
| `joc.rds` | Compiled metacheck paperlist (GitHub Release asset) |

## Coverage

- **Journal**: Journal of Cognition (ISSN 2514-4820)
- **Publisher**: Ubiquity Press, on behalf of the Society for Cognitive
  Studies (fully open access)
- **Years**: 2017-2026
- **Papers**: 447 (complete corpus, out of 457 total CrossRef DOIs)
- **License**: CC-BY 4.0

## How papers were processed

1. DOIs retrieved from CrossRef using ISSN 2514-4820, 2017-2026
2. Non-research records (corrections, errata, editorial notices)
   excluded by title pattern
3. The journal's OJS (Open Journal Systems) platform serves PDFs at
   URLs that Unpaywall does not resolve correctly for this journal --
   Unpaywall's reported `url_for_pdf` (a `.../galley/{id}/download/`
   shortcut) redirects to the generic articles-listing page, not the
   actual PDF. Instead, each article's landing page
   (`journalofcognition.org/articles/{doi}`) was fetched directly and
   the real PDF `href` extracted from its HTML
4. PDFs converted to TEI-XML using GROBID 0.9
5. XML files assembled into a metacheck paperlist using
   `metacheck::grobid_to_bibr()`

See `build.R` for the complete reproducible pipeline.

## Known gaps and data-quality notes

- **2 articles excluded before conversion**: `joc.84`'s PDF returned an
  `AccessDenied` error directly from the publisher's Google Cloud Storage
  bucket (the object itself appears to lack public read access -- not a
  transient issue, confirmed on repeated attempts); `joc.136` had the same
  OJS landing-page link broken but was recovered via its Europe PMC
  deposit (`PMC7792471`) instead.
- **1 article excluded after download**: `joc.316`'s PDF exceeded
  GROBID's upload size limit ("Payload Too Large"). Since this is a
  complete corpus (not a stratified sample), this article was excluded
  rather than resampled -- the corpus's value is being the full set of
  what's actually retrievable and convertible, not hitting an exact count.
- **DOIs**: GROBID's header-extracted DOI was missing or wrong for 5
  articles (one had picked up an unrelated *Behavior Research Methods*
  DOI from a citation in the references instead of the article's own).
  All 5 have been overwritten with the verified DOI from the original
  CrossRef sample.
- **Titles**: 10 articles have real, substantial body text (3K-186K
  characters) but GROBID failed to extract a title from the PDF (one
  extracted a running-header string instead of the real title). All 10
  titles have been backfilled from CrossRef's bibliographic record for
  that DOI.
- Final corpus: 447 of 457 total CrossRef-registered articles (8 excluded
  as non-research notices by the title filter, 2 inaccessible PDFs, 1
  oversized PDF).

## Loading in R

```r
metacheck::papers_load('joc')
papers <- metacheck::papers_load('joc')
```