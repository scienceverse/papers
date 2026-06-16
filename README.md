# papers

A shared repository of open-access scientific manuscripts for validating tools
that automatically check scientific papers. The goal is to provide a common,
citable benchmark corpus that developers of tools such as
[Statcheck](https://github.com/MicheleNuijten/statcheck),
[Regcheck](https://github.com/JamieCummins/regcheck),
[Metacheck](https://github.com/scienceverse/metacheck), and
[ESCIcheck](https://github.com/giladfeldman/escicheck)
can use to systematically test and validate their tools on real published
literature.

All papers in this repository are open-access and are shared in accordance
with their original licenses (typically CC-BY 4.0).

---

## Repository organisation

Each journal corpus lives in its own subfolder and contains:

```
<corpus>/
  README.md         description, coverage, and known gaps
  manifest.csv      one row per paper: DOI, title, year, filenames, provenance
  metadata.json     Dublin Core metadata describing the corpus as a dataset
  build.R           fully reproducible script to regenerate the corpus from scratch
  pdf/              original PDF files, named <corpus>.<article_id>.pdf
```

In addition, compiled **paperlist** objects (`.rds` files) are distributed as
GitHub Release assets and can be downloaded directly from R using metacheck
(see below). These are the primary format used by Metacheck, Regcheck, and
related tools.

### File formats

| Format | Location | Description |
|--------|----------|-------------|
| PDF | `<corpus>/pdf/` | Original publisher PDFs |
| Paperlist (`.rds`) | GitHub Release asset | Structured R objects extracted from PDFs via GROBID; the main format for tool validation |
| TEI-XML | not stored | Intermediate GROBID output used to generate paperlists |

Other formats (plain text, JSON) can be added to a corpus subfolder if needed.
If you need a format that is not yet available, please
[open an issue](https://github.com/scienceverse/papers/issues).

---

## Available corpora

| Corpus | Journal | Papers | Years | License |
|--------|---------|--------|-------|---------|
| [collabra](collabra/) | Collabra: Psychology | 749 | 2017-2026 | CC-BY 4.0 |

---

## Loading papers in R with metacheck

Install metacheck from GitHub if you have not already:

```r
# install.packages("pak")
pak::pkg_install("scienceverse/metacheck")
```

Then download and load a corpus:

```r
# See what corpora are available and whether they are cached locally
metacheck::papers_available()

# Download a corpus to your local cache (~18 MB for collabra)
metacheck::papers_download("collabra")

# Load the corpus into R as a paperlist object
papers <- metacheck::papers_load("collabra")

# Run a check module on all papers
results <- metacheck::module_run(papers, "ethics_check")

# Remove the cached corpus to free disk space
metacheck::papers_remove("collabra")
```

The paperlist format is a named list of paper objects, each containing full
text, section structure, references, figures, tables, equations, and
bibliographic metadata. It is the native input format for all metacheck
modules.

---

## FAIR principles

This repository is designed to be a FAIR (Findable, Accessible, Interoperable,
Reusable) data resource:

- **Findable**: every paper is identified by its DOI in `manifest.csv`; each
  corpus has a `metadata.json` file with Dublin Core metadata
- **Accessible**: all PDFs are open-access; paperlist files are freely
  downloadable via `metacheck::papers_download()`
- **Interoperable**: paperlist objects follow the
  [scienceverse](https://github.com/scienceverse) schema; metadata uses the
  Dublin Core standard
- **Reusable**: all corpora use open licenses; each `build.R` script fully
  reproduces the dataset from original sources

---

## Contributing

To add a new corpus, follow the structure above and open a pull request.
The `build.R` script should be fully self-contained and reproducible, and
`manifest.csv` should list every paper with its DOI and provenance. See
[collabra/build.R](collabra/build.R) for a worked example.
