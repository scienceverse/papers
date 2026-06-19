# Downloading and converting open-access articles: lessons learned

Notes from building several paper corpora (JDM, Collabra, PLOS Medicine,
BMC Medicine, International Journal of Oral Science, BMC Oral Health) for
[scienceverse/papers](https://github.com/scienceverse/papers). Each corpus
follows the same pipeline: CrossRef for metadata and DOIs, Unpaywall for
open-access PDF locations, GROBID for PDF-to-XML conversion, and
`metacheck::grobid_to_bibr()` to assemble a paperlist.

## Finding the right ISSN

CrossRef's `/journals/{issn}/works` endpoint can behave inconsistently
depending on *which* ISSN you use for a journal with both print and
electronic ISSNs. For one journal (*Quantitative Economics*), the
electronic ISSN listed on the publisher's own site returned only 3 works
from this endpoint, while the print ISSN returned the correct 607. The
`/journals/{issn}` metadata endpoint (article counts, year breakdowns) can
also be checked independently of `/journals/{issn}/works` as a sanity check
-- if the two disagree sharply, try the other ISSN in the pair.

## Filtering out non-research records

CrossRef types many non-article records as `journal-article` even though
they are not original research: correction/erratum/retraction notices,
replies to letters, commentaries, editorial board announcements, "Call for
Papers" notices, and meeting reports. A title-based regex filter is
necessary in addition to the CrossRef `type` filter. Patterns that have
actually appeared across journals so far:

- `Correction:`, `Correction to:`, `Correction To:` (capitalization varies),
  `Author Correction:`, `Publisher Correction:`
- `Erratum:`, `Erratum to:`
- `Retraction:`, `Retraction Note:`
- `Expression of Concern:`
- `Withdrawal:`
- `Response to '...'`, `Reply to '...'` (replies to letters -- check the
  opening quote character, which can be a curly/smart quote)
- `... commentary on ...`
- `Reviewer and Editorial Board Thank You`, `Call for Papers:`,
  `Editorial Board`, `Acknowledgement`/`Acknowledgment`, `Annual Report`
- `Meeting report:`, `Meeting Report:`

None of these match a simple `^(Correction|...): ` anchored-at-start
pattern, because several use a `to`/`To` qualifier between the keyword and
the colon, or appear after a prefix like "Author "/"Publisher ". Anchor the
keyword group but allow an optional `(\s+(Note|to|To))?` before the colon,
and check separately for the reply-to-letter and editorial-notice patterns
which don't have a colon-after-keyword shape at all.

This filter will not catch everything on the first pass. After building a
corpus, re-scan titles in the **assembled RDS**, not just the CrossRef
sample -- GROBID sometimes fails to extract a title at all (empty
`titleStmt/title`) for short pieces like retraction notices, so a
"non-empty title but is actually a notice" sample-time check and an
"empty title" post-conversion check catch different things.

## Duplicate DOI registrations

CrossRef occasionally has two DOIs for the same article (e.g.
`10.4248/ijos.09061` and `10.4248/ijos09061` -- a dotted and undotted
registration of the same piece, seen in older articles). If your
`article_id` derivation strips non-alphanumeric characters (needed to turn
a DOI suffix into a safe filename), two such duplicate DOIs can collide
into the *same* `article_id`, silently shrinking your sample by one slot
per collision without an obvious error. After sampling, always check
`length(unique(sampled$article_id)) == nrow(sampled)` and investigate any
mismatch by looking at the colliding rows' titles (if the titles match,
it's a duplicate registration -- drop one of the two DOIs).

## Where the PDF actually is: Unpaywall, and why "best" isn't always best

Unpaywall's `best_oa_location` is usually the right place to start, but
check `oa_locations` (plural) too -- it lists every known OA copy, each
tagged with `host_type` (`publisher` vs `repository`) and `version`
(`publishedVersion`, `acceptedVersion`, or `submittedVersion`).

**If you need the publisher's typeset version of record, not a preprint,
filter for `version == "publishedVersion"` and prefer `host_type ==
"publisher"`.** A `repository` copy (e.g. on EconStor, arXiv, an
institutional repository) is very often a `submittedVersion` -- the
author's pre-review manuscript, which can differ from the published
article in pagination, content, and sometimes substance. Don't assume a
repository mirror is an acceptable substitute for the published version
without checking its `version` field.

Some journals have **no non-publisher OA copy at all** -- every
`oa_locations` entry is `host_type: publisher`. If that publisher is
blocked (see below), there may be no way to get the published version
through Unpaywall alone.

## Publisher access: a spectrum, not binary

Three publisher behaviors encountered so far, from worst to best:

**Wiley (`onlinelibrary.wiley.com`) -- effectively blocked.** Active,
adaptive Cloudflare bot protection. A request can occasionally succeed by
chance (one verified real-PDF download, with browser-like headers, a
session cookie from visiting the landing page first, and a `Referer`
header) but repeating the *exact same technique* on other DOIs mostly
produces 403s or redirect loops. This is not a stable, reproducible
pipeline -- treat it as blocked rather than spend time tuning headers
further. A headless browser (Playwright) might do better but was not
pursued: it requires installing a ~150-300MB Chromium binary, building and
debugging a scraper against active anti-bot defenses, and Cloudflare also
fingerprints headless browsers, so success isn't guaranteed even then.

**Springer/BMC/Nature (`link.springer.com`, `nature.com`,
`bmcmedicine.biomedcentral.com`, etc.) -- works reliably.** These show a
`303 See Other` redirect to an `idp.{publisher}.com` identity/session
endpoint, then a couple more redirects that set session cookies, ending at
the actual PDF. No CAPTCHA, no JS challenge. **`httr2`'s default
`req_perform()` already follows this whole chain and manages cookies
automatically -- no special session setup, cookie jar, or headers beyond a
normal `User-Agent` are needed.** Verified at 95-100% success rates across
hundreds of articles per journal.

**PLOS (`journals.plos.org`) -- works, has a documented direct-download
URL pattern.** `https://journals.plos.org/plosmedicine/article/file?id={doi}&type=printable`
works as a fallback when Unpaywall doesn't have a direct PDF link.

When a publisher works (Springer/Nature/PLOS), prefer it for the actual
download even if Unpaywall's `url_for_pdf` is empty for a given article --
the publisher's own direct-download URL pattern is often still
reconstructable (see next section), and is more likely to succeed than a
non-publisher fallback that may turn out to be a preprint.

## Reconstructing a publisher PDF URL when Unpaywall has none

Unpaywall's crawler doesn't index every article's PDF link, especially very
recent ones (it can lag behind a publisher actually putting the PDF
online). When `url_for_pdf` is empty/missing but `is_oa: true`, the article
is very likely still downloadable directly from the publisher -- you just
have to construct the URL yourself.

**Don't guess the URL pattern from a few examples and assume it
generalizes.** Nature article slugs are *not* uniform: older `10.1038/
ijos.2014.62`-style DOIs map to a slug with the dots stripped
(`ijos201462`), but newer `10.1038/s41368-018-0020-3`-style DOIs keep their
dashes as-is (`s41368-018-0020-3`). A naive "strip all punctuation from the
DOI suffix" transform works for one era and silently produces a 404 for
the other.

**The reliable fix: resolve `https://doi.org/{doi}` yourself and read the
real slug from the redirect's `Location` header**, rather than guessing:

```r
resolve_publisher_slug <- function(doi) {
  resp <- httr2::request(paste0("https://doi.org/", doi)) |>
    httr2::req_headers(`User-Agent` = "Mozilla/5.0 ...") |>
    httr2::req_options(followlocation = FALSE) |>   # stop at first redirect
    httr2::req_perform()
  resp$headers$location   # -> e.g. "https://www.nature.com/articles/s41368-018-0020-3"
}
```

This recovered 28 of 28 "no Unpaywall URL" articles in one corpus (after an
initial naive-pattern attempt recovered only 2 of 30) -- a meaningful
difference in the final corpus's completeness, achieved without fighting
any bot protection, since the doi.org redirect and the publisher's own
session redirects are both ordinary, intended-for-machines redirects.

## Verify every downloaded file is actually a PDF

A "successful" HTTP 200 response is not proof you got a PDF. The most
common failure mode is downloading an HTML page (a login wall, a journal
homepage, a cookie-consent redirect target) that happens to be large
enough to pass a naive `size > 10000 bytes` sanity check, and gets saved
with a `.pdf` extension anyway. This produced 3 silently-corrupt "PDFs" in
one corpus that GROBID correctly rejected with `Internal Server Error` --
which looked like a GROBID/server problem until the files were inspected
directly and turned out to be the journal's homepage HTML.

Always check the actual file header after download, not just the HTTP
status code and file size:

```r
header <- readBin(dest_path, "raw", n = 5)
is_real_pdf <- rawToChar(header) == "%PDF-"
```

Delete and treat as failed if this check fails, rather than trusting a 200
status code alone.

## Server-side conversion failures are sometimes transient

A batch of GROBID conversion failures with "Connection to the GROBID
server failed" or "Internal Server Error" partway through a long run can
be a temporary server-side outage rather than a problem with those specific
PDFs. The conversion scripts in this pipeline are idempotent (they skip
PDFs that already have a corresponding XML file), so simply re-running the
same script later, once the GROBID server is reachable again
(`curl -o /dev/null -w "%{http_code}" {grobid_url}/api/isalive`), will pick
up exactly the files that previously failed without redoing completed work.
Don't assume a batch of errors means those specific PDFs are bad until
you've confirmed the server was actually up throughout the run.

## DOIs extracted from the PDF by GROBID are not always reliable

GROBID's TEI header extraction occasionally returns a DOI that is *not*
the paper's own -- sometimes a DOI from the reference list, sometimes
seemingly a parsing artifact. Across two corpora, roughly 0.4-3% of papers
ended up with a wrong-but-plausible-looking DOI (correct publisher
prefix, just the wrong specific article) silently baked into
`paper$info$doi`. There is no XPath fix for this -- it's a genuine
extraction error in GROBID's output for some PDFs, not a metacheck bug.

Since a corpus built by sampling from CrossRef by DOI already knows the
correct DOI for every paper, **don't trust GROBID's extracted DOI at all
-- overwrite `paper$info$doi` from the original sample after assembly**:

```r
papers <- readRDS(rds_path)
ids <- sub("^prefix\\.", "", sapply(papers, \(p) basename(p$info$file_name))) |>
  sub("\\.xml$", "", x = _)
doi_lookup <- setNames(sampled$doi, sampled$article_id)
for (i in seq_along(papers)) papers[[i]]$info$doi <- doi_lookup[[ids[i]]]
```

## Matching sampled articles to assembled papers: use the filename, not the DOI

Because of the DOI-extraction unreliability above, a manifest column like
`in_rds = sampled$doi %in% sapply(papers, \(p) p$info$doi)` will be wrong
for exactly the papers where GROBID's extracted DOI doesn't match --
producing a manifest that *looks* like it's missing papers it actually
has. Match on the file name instead, which is set deterministically by the
conversion script and never touched by GROBID's parsing:

```r
present_ids <- sapply(papers, \(p) basename(p$info$file_name)) |>
  sub("^prefix\\.", "", x = _) |> sub("\\.xml$", "", x = _)
manifest$in_rds <- sampled$article_id %in% present_ids
```

## `grobid_to_bibr()` on a whole directory is slow, and per-file errors are silent by design

Running `grobid_to_bibr()` over ~1000 XML files can take 20-45 minutes (the
function wraps each file in its own `tryCatch` and continues past
individual failures, logging to `logger()` rather than stopping). For a
large corpus this assembly step, not the GROBID conversion itself, is
usually the slowest part of the pipeline.

If you only need to add a handful of newly-converted papers to an
already-assembled corpus, don't re-run `grobid_to_bibr()` over the whole
directory again -- parse just the new XML files and append:

```r
new_papers <- grobid_to_bibr(new_xml_paths, save_path = NULL)
combined <- c(readRDS(rds_path), new_papers)
class(combined) <- class(readRDS(rds_path))
saveRDS(combined, rds_path)
```

This turns a 20-45 minute rebuild into a few seconds for small follow-up
batches (e.g. retried downloads, or papers recovered after fixing a URL
bug).

## License fields: don't assume one license for an entire journal

Even within a single journal, articles can carry different CC licenses
(seen: a mix of CC-BY 4.0 and CC0 within one PLOS journal; CC-BY 4.0 mixed
with CC-BY-NC-ND within single issues of two different Nature/Springer
journals). Sample a handful of real CrossRef `license` fields across the
corpus rather than hard-coding a single license string in the manifest --
if it's genuinely mixed, say so ("CC-BY 4.0 or CC0, depending on the
article") rather than overclaiming uniformity.

## Practical checklist for a new corpus

1. Resolve the correct ISSN for CrossRef's `/works` endpoint (try both
   print and electronic if counts look wrong).
2. Check total article count: if under ~1000, build a complete corpus
   (like JDM/Collabra); if over, stratify by year (100/year is the
   convention used so far, skip years too sparse to contribute meaningfully).
3. Sample CrossRef DOIs, applying the non-article title filter (see list
   above) before sampling, not after.
4. Check `length(unique(article_id)) == nrow(sampled)` and investigate any
   collision (likely a duplicate DOI registration for the same article).
5. Test PDF accessibility on ~15-40 sample DOIs *before* committing to a
   full download run: check Unpaywall's `version`/`host_type`, and actually
   attempt a download (not just an HTTP HEAD) to rule out publisher
   bot-blocking.
6. Download with the file-header check (`%PDF-`), not just HTTP status.
7. After the main download pass, check for articles with no Unpaywall PDF
   URL and retry them via the publisher's own resolved redirect slug
   (`doi.org` + `followlocation = FALSE`) before giving up on them.
8. Convert via GROBID; the scripts are idempotent, so a transient server
   outage just means re-running later.
9. Assemble with `grobid_to_bibr()`; for small follow-up batches, append
   rather than rebuild.
10. Overwrite `paper$info$doi` from the known-correct sample DOI; match
    manifest `in_rds` by filename, not DOI.
11. Full-corpus audit (not just a spot-check): empty titles, near-zero
    extracted text, remaining non-article titles, duplicate DOIs/article
    IDs -- each of these has independently turned up real problems that a
    30-60 paper sample check missed.