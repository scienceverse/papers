# Journal of Sports Science and Medicine (JSSM) corpus

A random sample of 1,000 open-access articles published in the *Journal
of Sports Science and Medicine* (JSSM) from 2014 to 2026, assembled for
validation of AI and text-mining tools.

## Contents

| File | Description |
|------|--------------|
| `manifest.csv` | One row per paper: DOI (where available), title, year, volume, start page, filenames, provenance, title source |
| `metadata.json` | Dublin Core metadata for this corpus |
| `build.R` | Fully reproducible build script |
| `pdf/jssm.<id>.pdf` | Original PDF files (1,000 files) |
| `jssm.rds` | Compiled metacheck paperlist (GitHub Release asset) |

## Coverage

- **Journal**: Journal of Sports Science and Medicine (ISSN 1303-2968)
- **Years**: 2014-2026 (volumes 13-25)
- **Papers**: 1,000 (random sample from ~1,132 articles found on the
  journal's own site across this volume range)
- **License**: CC-BY 4.0 or CC-BY-NC-ND 4.0, depending on the article --
  check each paper's own license before reuse

## Why this corpus was built differently from the others in this repo

CrossRef's index for this journal is unusually sparse: only 470 DOIs
total, and almost none before ~2021 (e.g. 0 indexed articles for 2014,
2015, 2016, 2018, 2019, or 2020; 1 for 2017). The journal's own
"browse archive" page (`jssm.org/newarchives.php`) is a client-rendered
single-page app with no server-side content reachable by a plain HTTP
request, so it could not be scraped directly either.

Instead, this corpus was built by:

1. Discovering the site's real article-PDF location directly:
   `jssm.org/volume{N}/iss{1-4}/cap/` is a plain Apache/LiteSpeed
   directory listing of PDFs named `jssm-{N}-{startpage}.pdf`. This path
   only exists for volume 10 onward (volumes 1-9, i.e. 2002-2010, redirect
   to the homepage and were not reachable this way).
2. Crawling volumes 13-25 (2014-2026) this way to find every article PDF
   (~1,132 found, after excluding the issue's "page 0" cover/front-matter
   file).
3. Reconstructing each article's likely DOI from its volume (volume =
   year - 2001, confirmed against known examples) and start page (DOI
   pattern: `10.52082/jssm.{year}.{startpage}`), then querying CrossRef
   for each reconstructed DOI to get a verified title where available.
   This matched 434 of the ~1,132 candidates (the rest predate CrossRef's
   coverage for this journal).
4. Randomly sampling 1,000 of the ~1,132 candidates, downloading all
   their PDFs, and converting with GROBID. For the ~566 papers with no
   CrossRef match, **title and authors come entirely from GROBID's own
   extraction from the PDF**, not from CrossRef -- see `title_source` in
   `manifest.csv` (`"crossref"` or `"grobid"`).

See `build.R` for the complete reproducible pipeline.

## Known gaps and data-quality notes

- **DOI coverage**: only 434 of the 1,000 papers have a verified CrossRef
  DOI. The other 566 have an empty `doi` field in `jssm.rds` and
  `manifest.csv` -- their title and author metadata comes from GROBID's
  own PDF header extraction, which is somewhat less reliable than
  CrossRef's bibliographic record. Check `title_source` in `manifest.csv`
  before relying on a paper's title/DOI for citation purposes.
- **Pre-2014 articles are not included**: volumes 1-9 (2002-2010) are not
  reachable at the directory-listing path used to discover articles, and
  CrossRef has only 4 indexed articles for that period. This corpus
  starts at volume 13 (2014).
- 23 articles from the initial random sample were excluded after the
  fact (1 retraction notice; 22 where GROBID failed to extract a usable
  title even though most had substantial body text) and replaced with
  fresh draws from the same candidate pool.
- Volume 25 (2026) is the current, still-publishing volume and is
  under-represented relative to complete volumes.

## Loading in R

```r
metacheck::papers_load('jssm')
papers <- metacheck::papers_load('jssm')
```