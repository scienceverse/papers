# Judgment and Decision Making corpus

A complete corpus of 855 articles published in *Judgment and Decision Making*
from 2006 to 2022, assembled for validation of AI and text-mining tools.

## Coverage

- **Journal**: Judgment and Decision Making (ISSN 1930-2975)
- **Publisher**: Society for Judgment and Decision Making (independent, 2006-2022);
  Cambridge University Press (2023-)
- **Years**: 2006-2022 (independent era; CUP era not included as PDFs are paywalled)
- **Papers**: 855 (out of ~856 published; 1 excluded due to PDF size)
- **License**: CC-BY 4.0

## Contents

| File | Description |
|------|-------------|
| `manifest.csv` | One row per paper: DOI, title, filenames, provenance |
| `metadata.json` | Dublin Core metadata for this corpus |
| `build.R` | Fully reproducible build script |
| `pdf/jdm.jdmNNN*.pdf` | Original PDF files (855 files) |
| `jdm.rds` | Compiled metacheck paperlist (GitHub Release asset) |

## How papers were processed

1. All issue pages on https://jbaron.org/journal/ scraped for PDF links
   (135 issues, volumes 1-17, 2006-2022)
2. PDFs downloaded; non-article files (appendices, supplements, data files)
   removed by filename pattern (kept only `jdm.jdmNNN*.pdf`)
3. PDFs converted to TEI-XML using GROBID 0.8 at
   `https://grobid.hti.ieis.tue.nl`
   - 1 paper excluded: `jdm200330` (29.6 MB, exceeded server payload limit)
   - 2 non-papers removed after conversion: `jdm9115AnnotatedPrograms`,
     `jdm9226s` (supplement)
4. XML files assembled into a metacheck paperlist using
   `metacheck::grobid_to_bibr()`
5. DOIs patched in two passes:
   - **Automated**: CrossRef title matching (ISSN filter 1930-2975); 803 papers
     matched at <=15% edit distance; 32 more matched with title+author at <=30%
   - **Manual**: 6 papers from Vol. 2 Issue 6 (December 2007) not indexed in
     CrossRef; DOIs verified manually from cambridge.org on 2026-06-17

See `build.R` for the complete reproducible pipeline.

## Known gaps

- `jdm200330` (2020-03-30): excluded — PDF too large (29.6 MB) for GROBID
- 2023+ papers (Cambridge era): not included — PDFs are paywalled
- 45 papers had DOIs that could not be automatically matched; 38 were resolved
  manually or via relaxed matching; 7 remain without a verified JDM DOI

## Loading in R

```r
papers <- metacheck::papers_load('jdm')
```
