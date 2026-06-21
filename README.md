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

**18 corpora, 15,179 papers, as of 2026-06-21.**

If you are building a new corpus for this repository, read
[downloading_articles.md](downloading_articles.md) first -- it documents
dozens of lessons learned (publisher-specific access patterns, GROBID
conversion pitfalls, common bugs in DOI/sampling logic, and the release
checklist) from building the corpora below. Skipping it means re-discovering
the same problems from scratch.

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

18 corpora, 15,179 papers in total.

| Corpus | Journal | Papers | Years | License |
|--------|---------|--------|-------|---------|
| [bmcmed](bmcmed/) | BMC Medicine | 1000 | 2016-2025 | CC-BY 4.0 |
| [bmcoral](bmcoral/) | BMC Oral Health | 1000 | 2016-2025 | Mostly CC-BY 4.0 |
| [collabra](collabra/) | Collabra: Psychology | 748 | 2017-2026 | CC-BY 4.0 |
| [ece3](ece3/) | Ecology and Evolution | 1543 | 2011-2026 | Mixed CC-BY 4.0/3.0, CC-BY-NC 3.0 |
| [elife](elife/) | eLife | 1000 | 2017-2026 | CC-BY 4.0 |
| [frontiers](frontiers/) | Frontiers in Psychology | 1000 | 2017-2026 | CC-BY 4.0 |
| [ijos](ijos/) | International Journal of Oral Science | 724 | 2009-2026 | Mostly CC-BY 4.0 |
| [iperc](iperc/) | i-Perception | 496 | 2017-2026 | CC-BY 4.0 |
| [jdm](jdm/) | Judgment and Decision Making | 855 | 2006-2022 | CC-BY 4.0 |
| [joc](joc/) | Journal of Cognition | 447 | 2017-2026 | CC-BY 4.0 |
| [jssm](jssm/) | Journal of Sports Science and Medicine | 1000 | 2014-2026 | CC-BY 4.0 or CC-BY-NC-ND 4.0 |
| [natcomm](natcomm/) | Nature Communications | 1000 | 2017-2026 | Mostly CC-BY 4.0 |
| [openmind](openmind/) | Open Mind | 293 | 2017-2026 | CC-BY 4.0 |
| [plosbio](plosbio/) | PLOS Biology | 1000 | 2016-2025 | CC-BY 4.0 or CC0 |
| [plosmed](plosmed/) | PLOS Medicine | 1000 | 2016-2025 | CC-BY 4.0 or CC0 |
| [plosone](plosone/) | PLOS ONE | 1000 | 2016-2025 | CC-BY 4.0 or CC0 |
| [psychsci_oa](psychsci_oa/) | Psychological Science (OA subset) | 270 | 2014-2026 | CC-BY 4.0 or CC-BY-NC |
| [scan](scan/) | Social Cognitive and Affective Neuroscience | 803 | 2017-2026 | Mixed CC-BY variants |

Each corpus's `README.md` documents its specific coverage, sampling method
(complete corpus vs. stratified random sample), and known gaps/exclusions.

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