# Meta-Psychology corpus

A complete corpus of 150 articles published in *Meta-Psychology* between
2018 and 2026, assembled for validation of AI and text-mining tools.
Meta-Psychology checks the computational reproducibility of the analyses
in the articles it accepts, and the manifest records, for each paper,
the open-science and reproducibility information printed on its first
page.

## Contents

| File | Description |
|------|--------------|
| `manifest.csv` | One row per paper: DOI, title, year, filenames, provenance, and the first-page open-science fields |
| `sample.csv` | All 153 CrossRef article records, with CrossRef's PDF link and the link each PDF was actually downloaded from |
| `conversion_log.csv` | GROBID server, version and date for each converted PDF |
| `metadata.json` | Dublin Core metadata for this corpus |
| `build.R` | Fully reproducible build script |
| `pdf/metapsych.<id>.pdf` | Original PDF files (150 files, not committed; `metapsych_pdf.zip` release asset) |
| `metapsych.rds` | Compiled metacheck paperlist (GitHub Release asset) |

## Coverage

- **Journal**: Meta-Psychology (ISSN 2003-2714)
- **Publisher**: Linnaeus University Press
- **Years**: 2018-2026 (publication year in CrossRef; the year inside the
  DOI is the submission year and is often earlier)
- **Papers**: 150. This is a **complete corpus**: CrossRef lists 153
  journal articles, the same 153 that appear on the journal's own issue
  pages; 3 editorials were excluded (see below).
- **License**: CC-BY 4.0 (every CrossRef record carries this license)

Papers per year: 2018 (1), 2019 (14), 2020 (11), 2021 (17), 2022 (20),
2023 (19), 2024 (34), 2025 (25), 2026 (9).

## How papers were selected and processed

1. All 153 journal-article DOIs retrieved from CrossRef using ISSN
   2003-2714; none matched the non-article title rules. The rule that
   excludes titles containing "commentary on" in other corpora is not
   used here: Meta-Psychology commentaries are peer-reviewed articles,
   often with their own analyses (59 of the 150 papers).
2. PDFs downloaded from the journal site (`open.lnu.se`). The current
   PDF link is read from each article's page, because CrossRef's PDF
   link was outdated for 7 articles (see Known gaps). Every file was
   checked to start with `%PDF-`, and a sample was opened to confirm it
   is the typeset published version.
3. PDFs converted to TEI-XML with GROBID 0.9.1 on the Hugging Face
   server (`https://grobidOrg-grobid.hf.space`). The TU/e GROBID server
   (`https://grobid.hti.ieis.tue.nl`) is preferred by `build.R` but was
   not reachable from outside the TU/e network on 2026-11-18.
4. The first-page header of each PDF was read with `pdftools` into the
   manifest columns `article_type`, `open_data`, `open_materials`,
   `open_code`, `open_analysis`, `open_reviews`, `preregistration` and
   `analysis_reproduced_by`. Values are kept as printed (e.g. both
   "Not Applicable" and "N/A" occur); the 2018 articles used an older
   header without most of these fields, so those cells are empty.
   87 papers name the person who reproduced the analysis.
5. Editorials excluded by the article type printed on page 1 ("Editorial":
   `10.15626/mp2017.1001`, `10.15626/mp.2023.4032`) plus the one-page
   inaugural editorial of the QRAP section (`10.15626/mp.2026.4892`,
   printed type "Questionable Research Ideas and Other Peculiarities").
   The two "Guest Editorial" pieces were kept: they are substantive
   articles, and one had its analysis reproduced.
6. XML assembled with `metacheck::grobid_to_bibr()` (metacheck 0.4.4.3).
   DOIs overwritten with the CrossRef DOI; papers matched to the
   manifest by file name.

See `build.R` for the complete pipeline (`phase1_download()`,
`phase2_convert()`, `phase3_assemble()`, `phase4_zip()`).

## Known gaps and data-quality notes

- **CrossRef's PDF link was outdated for 7 articles**, because the
  journal had replaced the PDF: 4 links returned 404
  (`mp.2019.1633`, `mp.2022.3422`, `mp.2023.3715`, `mp.2023.4020`) and 3
  still served the superseded file (`mp.2020.2470`, `mp.2022.3308`,
  `mp.2023.3688`). All 7 were downloaded from the current link on the
  article page; `sample.csv` records both links.
- **3 titles were taken from CrossRef** because GROBID extracted none:
  `mp.2023.3679`, `mp.2023.4008`, `mp.2024.4155`.
- **5 PDFs print a mistaken DOI on their first page** (an error in the
  journal's own typesetting), so they fail the "PDF contains its own DOI"
  check; each was opened and is the correct article: `mp.2018.872`
  (printed `10.15626/2018.872`), `mp.2018.878` (`10.17605/MP.2018.878`),
  `mp.2018.895` (`10.5626/MP.2018.895`), `mp.2018.984`
  (`10.15626/MP.2018.894`), `mp.2020.2458` (`10.15626/MP.2020-2458`).
  The paperlist uses the correct CrossRef DOI for all of them.
- No conversion failures, no papers without text, references or
  authors, no duplicate DOIs.

## Loading in R

```r
metacheck::papers_download('metapsych')
papers <- metacheck::papers_load('metapsych')
```
