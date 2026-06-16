# papers

A repository of open-access paper corpora for validating AI and text-mining
tools, distributed as metacheck paperlist objects (`.rds`) via GitHub Releases.

## Available corpora

| Corpus | Journal | Papers | Years | License |
|--------|---------|--------|-------|---------|
| [collabra](collabra/) | Collabra: Psychology | 749 | 2017-2026 | CC-BY 4.0 |

## Usage in R

```r
# install metacheck if needed
# devtools::install_github('scienceverse/metacheck')

metacheck::papers_available()           # list available corpora
metacheck::papers_download('collabra')  # download a corpus
papers <- metacheck::papers_load('collabra')  # load into R
```

## Repository structure

Each corpus lives in its own subfolder:

```
<corpus>/
  README.md       - description, coverage, known gaps
  manifest.csv    - one row per paper: DOI, title, year, filenames, provenance
  metadata.json   - Dublin Core metadata for the corpus
  build.R         - fully reproducible script to regenerate the corpus
  pdf/            - original PDF files
```

The compiled `.rds` release asset is attached to a GitHub Release.

## FAIR principles

- **Findable**: every paper identified by DOI in `manifest.csv`; Dublin Core
  metadata in `metadata.json`
- **Accessible**: PDFs are open-access; RDS files freely downloadable via
  `papers_download()`
- **Interoperable**: paperlist objects follow the scienceverse schema;
  metadata uses Dublin Core
- **Reusable**: open licenses; `build.R` fully reproduces each dataset
