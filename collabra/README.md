# Collabra: Psychology corpus

A complete corpus of all 749 open-access articles published in
*Collabra: Psychology* from 2017 to June 2026, assembled for validation of
AI and text-mining tools.

## Contents

| File | Description |
|------|-------------|
| `manifest.csv` | One row per paper: DOI, title, year, filenames, provenance |
| `metadata.json` | Dublin Core metadata for this corpus |
| `build.R` | Fully reproducible build script |
| `pdf/collabra.<id>.pdf` | Original PDF files (749 files, ~915 MB total) |
| `collabra.rds` | Compiled metacheck paperlist (GitHub Release asset) |

## Coverage

- **Journal**: Collabra: Psychology (ISSN 2474-7394)
- **Publisher**: University of California Press
- **Years**: 2017-2026
- **Papers**: 749 (complete as of 2026-06-16)
- **License**: CC-BY 4.0

## How papers were processed

1. DOIs retrieved from CrossRef using ISSN 2474-7394
2. Open-access PDFs downloaded via Unpaywall API
3. PDFs converted to TEI-XML using GROBID 0.9
4. XML files assembled into a metacheck paperlist using
   `metacheck::grobid_to_bibr()`

See `build.R` for the complete reproducible pipeline.

## Known gaps

- `10.1525/collabra.161957`: required manual re-download from PsyArXiv
  due to corrupted PDF from UC Press
- `10.1525/collabra.35903`: required manual download

## Loading in R

```r
metacheck::papers_load('collabra')
papers <- metacheck::papers_load('collabra')
```
