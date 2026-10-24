# Downloading and converting open-access articles: lessons learned

**Read this document before starting a new paper database.** Nearly
every mistake in here has recurred across multiple corpora when this
step was skipped -- the practical checklist near the end is the
fastest way to absorb it.

Notes from building several paper corpora (JDM, Collabra, PLOS Medicine,
BMC Medicine, International Journal of Oral Science, BMC Oral Health,
SCAN, i-Perception, Frontiers in Psychology, eLife, Open Mind) for
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
12. Before zipping PDFs for release, verify the zip's planned file list
    against the RDS's actual paper list (`setequal()` check) -- not
    "everything currently in the pdf/ folder". Re-verify by inspecting
    the zip's real entries after creation, not just before.
13. Spot-check that downloaded PDFs are the publisher's version of
    record, not a reformatted substitute -- a `%PDF-` header check only
    confirms "this is a PDF," not "this is the right PDF." Open a few
    real files (especially from any new/fallback download route) and
    check they look like a typeset journal article, not a one-column
    reflow or a wrong/different article.

## When a publisher's direct PDF host is bot-protected: try Europe PMC

Some publishers' own PDF hosts are protected in ways that block automated
downloads even for genuinely open-access articles (e.g. OUP's
`academic.oup.com` returns a Cloudflare JS challenge page, "Just a
moment...", instead of the PDF). When this happens, check whether the
article has a deposit in Europe PMC -- many journals (especially in
biomedicine and cognitive neuroscience, where NIH/Wellcome-funded authors
are common) are deposited there independently of the publisher's own site,
and Europe PMC's PDF host has no bot protection:

```r
get_pmcid <- function(doi) {
  resp <- httr2::request("https://www.ebi.ac.uk/europepmc/webservices/rest/search") |>
    httr2::req_url_query(query = paste0("DOI:", doi), format = "json") |>
    httr2::req_perform()
  res <- httr2::resp_body_json(resp)$resultList$result
  if (length(res) == 0 || !identical(res[[1]]$hasPDF, "Y")) return(NULL)
  res[[1]]$pmcid
}
# then download from:
# https://europepmc.org/articles/{PMCID}?pdf=render
```

This is not a universal fallback -- deposit coverage varies a lot by
journal and by year. It worked extremely well for one journal (~97%
success once OA was confirmed) but covered under 10% of a hybrid
journal's most recent few years, where deposits hadn't caught up yet. Treat it as
"try this, but verify the actual yield before assuming it closes the
gap" rather than a guaranteed substitute for the publisher's own host.

## Cloudflare can block a non-browser HTTP client even with a browser User-Agent

A request that gets a Cloudflare "Just a moment..." / 403 challenge page
isn't necessarily being rate-limited or IP-blocked -- check the response
headers for `cf-mitigated: challenge` and `critical-ch: Sec-CH-UA-...`.
Cloudflare can require the **Client Hints** headers a real browser sends
alongside a Chrome `User-Agent` string, and `httr2`'s default request
doesn't send them, so it gets flagged as a spoofed UA regardless of
request rate, IP reputation, or session cookies. Confirmed by reproducing
side-by-side: a plain `curl` request to the exact same URL succeeded
(different default headers), while the identical URL via `httr2` failed
with 403 every time -- until matching headers were added:

```r
httr2::request(url) |>
  httr2::req_headers(
    `User-Agent` = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    `Sec-CH-UA` = "\"Chromium\";v=\"120\", \"Google Chrome\";v=\"120\", \"Not=A?Brand\";v=\"99\"",
    `Sec-CH-UA-Mobile` = "?0",
    `Sec-CH-UA-Platform` = "\"Windows\""
  )
```

This fixed a publisher host that looked completely blocked (100% failure
after ~70 requests) with zero throttling once the headers were added --
don't add artificial delays to work around what might actually be a
header-fingerprinting issue, check the response headers first.

## `colClasses = "character"` is not just for the initial download script

The numeric-coercion bug (long-digit `article_id`/DOI-suffix strings
silently collapsing to lossy scientific notation under R's default
`read.csv()` type-guessing) isn't a one-time risk in the original download
script -- it recurs in **every** later script that reads the same
`sample.csv` again: resample/replace scripts, orphan-recovery scripts,
quality-audit scripts. Each of these is a fresh `read.csv()` call and each
needs `colClasses = "character"` independently; fixing it in one script
does not fix it in the others. If a later-stage script throws "subscript
out of bounds" on an `article_id` lookup, or `rbind()` mysteriously merges
two different articles' data into one row, suspect this first.

## `rbind()` against a bare `data.frame()` fails once real columns exist

Initializing an accumulator as `acc <- data.frame()` and then doing
`acc <- rbind(acc, new_row)` works fine for the *first* row (R is lenient
about rbinding into a truly empty 0-row-0-column frame), but if `acc` ever
needs to skip an iteration and get rbound again while still empty in a
*later* loop iteration where some other variable already has real columns,
or if you rbind two independently-built empty frames together at the end,
you can hit `Error: numbers of columns of arguments do not match`. This
surfaces especially in resample-by-year loops where a candidate year finds
zero replacements -- guard every `rbind()` onto a possibly-still-empty
accumulator:

```r
if (nrow(new_rows) > 0) acc <- if (nrow(acc) == 0) new_rows else rbind(acc, new_rows)
```

Also double check that both sides of a final `rbind()` (e.g. merging
resampled replacement rows back into the main `sampled` data frame) have
the **same columns in the same order** -- a `sample.csv` that picked up
extra columns over time (like `is_oa`/`license` added during a hybrid
journal's OA-checking phase) will not silently align with a replacement
data frame that only ever had the original 4 columns. Reindex with
`new_rows <- new_rows[, colnames(acc)]` before the final merge.

## Recovering a DOI from inside a binary PDF when the filename/CSV record is lost or wrong

If a `sample.csv` row gets dropped or corrupted (see the `colClasses` bug
above) but the PDF itself is still on disk, the DOI is very often
embedded as plain text inside the PDF's own bytes (in metadata, an
embedded XML stream, or just visible in a content stream) -- even though
the file as a whole is binary and not valid UTF-8 text. `rawToChar()` on
raw PDF bytes throws an "invalid multibyte string" error or
`regexpr()`/`regmatches()` silently fails to match anything, which looks
like "no DOI present" but is actually just an encoding failure. Filter to
printable ASCII bytes before converting to a string:

```r
extract_doi_from_pdf <- function(path, prefix = "10\\.1177/") {
  raw <- readBin(path, "raw", n = 200000)
  printable <- raw
  printable[!(raw >= as.raw(0x20) & raw <= as.raw(0x7e))] <- as.raw(0x20)
  txt <- rawToChar(printable)
  m <- regmatches(txt, regexpr(paste0(prefix, "[0-9]+"), txt))
  if (length(m) == 0 || !nzchar(m)) NA_character_ else m
}
```

Don't reconstruct a DOI by guessing from the filename alone (e.g.
`paste0("10.1177/", article_id)`) when the article_id itself came from a
process that touched the numeric-coercion bug -- the filename can be
off by one or two digits from the real DOI. Extracting straight from the
PDF's own bytes is more reliable, and only fall back to the filename
guess if no DOI string is found in the file.

## A "download succeeds but the bibliographic API call after it intermittently fails 60-80% of the time" pattern, with no identified root cause

Across two large corpus builds, a sequence of "check OA via Unpaywall,
then look up a PMCID via Europe PMC, then download" calls had a high
failure rate (60-80%) for the second and third steps specifically, in a
single long-running R session -- while every individual failing call,
re-tested in isolation seconds later (same DOI, same code, same session
pattern), succeeded without issue. This was not a rate limit (a 30-request
rapid-fire burst from a separate shell succeeded 30/30), not a Cloudflare
block (no challenge page in the response), and not a code bug (the
identical function works standalone). It was never root-caused.

What helped:
- A retry-once-after-a-short-pause wrapper around each API call
  recovered roughly half the gap (yield went from ~10-15% to ~30%).
- Simply **re-running the entire download script later** (it skips
  already-downloaded files) recovered most of the remainder -- one
  corpus went from 351/1000 to 803/1000 on a second full pass with no
  code changes at all. Whatever the underlying cause, it is not
  persistent across separate script invocations.
- Don't assume a low yield from one run is the ceiling for that
  journal/route -- if the access method is otherwise known to work
  (confirmed via isolated spot checks), a second full pass is worth
  trying before concluding the corpus must be published at a reduced size.

## GROBID "Internal Server Error" has (at least) two different causes

A `convert_grobid()` call failing with "Internal Server Error" can mean
either of two structurally different problems, and they need different
handling:

1. **The downloaded "PDF" is actually an HTML page** (login wall,
   cookie-consent redirect, journal homepage) that passed a naive
   `size > 10000 bytes` check but isn't a real PDF at all. Verify with
   the `%PDF-` header check described above -- this should be caught at
   download time, not conversion time, but if it slips through, deleting
   and re-downloading (or finding an alternate source) fixes it.
2. **The PDF is a genuinely, structurally valid PDF file** (correct
   `%PDF-` header, correct `%%EOF` trailer, normal file size -- not
   oversized) that GROBID nonetheless consistently rejects on every
   retry, including after a fresh re-download confirms the file itself
   is fine. This has been seen for a small number of files across
   several corpora (roughly 1 in several hundred) and has no known fix --
   treat it as an accepted, documented exclusion (like an oversized PDF),
   not a bug to keep chasing.

Distinguish the two by inspecting the actual file (header, trailer, size)
before deciding which path applies -- don't assume every "Internal Server
Error" is type 1 just because that's the more common cause.

## If the GROBID server seems to have gone down mid-session, check your own network/VPN first

A sudden, total GROBID outage (every request times out with no response
at all, including a plain `curl .../api/isalive` to the base domain) is
often not the GROBID server itself -- it's much more likely that the
machine running the script lost its own internet connection, or a VPN
connected/disconnected/changed routing. Check basic connectivity to a
known-reliable host (e.g. `curl -o /dev/null -w "%{http_code}" https://api.crossref.org`)
before concluding the GROBID endpoint itself is down; if other external
APIs are also unreachable at the same moment, the problem is local, not
remote, and no amount of waiting for GROBID specifically will fix it.

## Uploading build artifacts to the papers repo

The pipeline scripts above produce local files (`{corpus}/README.md`,
`{corpus}/build.R`, `{corpus}/manifest.csv`, `{corpus}/metadata.json`,
plus the `.rds` and PDF zip(s) that go in a GitHub Release, not a commit).
The four small text/metadata files are pushed to the repo via the GitHub
Contents API rather than a normal `git push`, since this pipeline doesn't
keep a local git clone of `scienceverse/papers` -- it works directly
against the GitHub API from the `metacheck` working directory instead.

```r
library(httr2); library(jsonlite)

repo  <- "scienceverse/papers"
token <- system2("gh", c("auth", "token"), stdout = TRUE)
b64 <- function(x) gsub("\n", "", openssl::base64_encode(charToRaw(x)))

upload_file <- function(path, content, commit_msg) {
  url <- paste0("https://api.github.com/repos/", repo, "/contents/", path)
  existing <- tryCatch(
    request(url) |>
      req_headers(Authorization = paste("Bearer", token),
                  Accept = "application/vnd.github+json") |>
      req_error(is_error = \(r) FALSE) |> req_perform() |> resp_body_json(),
    error = \(e) list(sha = NULL)
  )
  body <- list(message = commit_msg, content = b64(content))
  if (!is.null(existing$sha)) body$sha <- existing$sha  # required to overwrite an existing file
  resp <- request(url) |>
    req_headers(Authorization = paste("Bearer", token),
                Accept = "application/vnd.github+json",
                `Content-Type` = "application/json") |>
    req_body_raw(toJSON(body, auto_unbox = TRUE)) |>
    req_method("PUT") |> req_error(is_error = \(r) FALSE) |> req_perform()
  cat(path, "->", resp_status(resp), "\n")  # 201 = created, 200 = updated
}

upload_file("{corpus}/README.md", paste(readLines("local_README.md"), collapse = "\n"), "Add {corpus} README")
```

`gh auth token` reuses the same GitHub CLI authentication already set up
for `gh release create`, so no separate PAT/secret is needed. The `sha`
of the existing file (if any) must be included in the PUT body to
overwrite it -- omitting it when the file already exists produces a 409
Conflict, not a silent overwrite.

For the `.rds` and PDF zip(s), use a GitHub Release instead (these are
binary/large and don't belong in a git-tracked file):

```bash
gh release create {corpus}-$(date +%Y-%m-%d) --repo scienceverse/papers \
  --title "{Corpus} corpus v1" --notes "..." \
  {corpus}.rds {corpus}_pdf.zip   # or _pdf_part1.zip _pdf_part2.zip if split
```

After creating the release, verify by downloading the `.rds` fresh to a
temp directory (`gh release download {tag} --repo scienceverse/papers
--pattern "{corpus}.rds"`) and confirming `length()` and `class()` match
expectations -- this catches a corrupted upload or a wrong asset before
calling the corpus done. **Also re-download the PDF zip(s) fresh and
count entries against the RDS paper count** -- see the next section for
why this specific check matters and has caught real bugs in published
releases.

## The PDF zip must be built from the RDS's file list, never from "whatever's in the pdf/ folder"

A corpus's local `pdf/` directory accumulates files that should **not**
ship in the final release zip: PDFs that failed GROBID conversion
permanently (oversized, or a structurally-valid-but-rejected file --
see "GROBID Internal Server Error has two causes" above), and PDFs for
articles dropped during quality-audit cleanup (non-article notices,
duplicate-DOI artifacts). Cleanup/exclusion scripts remove these
papers from the `.rds`, but routinely forget to also delete the
corresponding PDF file from disk. Building the zip with `Compress-Archive
-Path "pdf/*"` (or equivalent) then ships every leftover file
regardless of whether it survived into the corpus.

This bug shipped silently in at least three already-published releases
before being caught (`joc`: 1 stray oversized PDF; `ijos`: 4 stray
PDFs across a 2-part zip; `jdm`: 3 stray PDFs) and was caught a fourth
time before publishing (`iperc`: 13 stray files -- 9 permanent GROBID
rejects + 4 dropped non-articles -- found before the zip was ever
uploaded).

**Always derive the zip's file list from the RDS itself, immediately
before zipping, and verify the match before uploading:**

```r
papers <- readRDS(rds_path)
valid_ids <- sapply(papers, \(p) basename(p$info$file_name)) |>
  sub("^prefix\\.", "", x = _) |> sub("\\.xml$", "", x = _)

disk_ids <- list.files(pdf_dir, pattern = "\\.pdf$") |>
  sub("^prefix\\.", "", x = _) |> sub("\\.pdf$", "", x = _)

stopifnot(setequal(valid_ids, disk_ids))  # fix before zipping if this fails
```

If they don't match, move (don't delete -- keep for diagnostics) the
extra files out of `pdf/` into a scratch folder before zipping, rather
than trying to filter them out at zip-creation time. After zipping,
re-verify by listing the zip's actual entries (`zipfile.ZipFile(...).
namelist()` in Python, or `[System.IO.Compression.ZipFile]::OpenRead(...)
.Entries` in PowerShell) against the same `valid_ids` set -- don't trust
that the pre-zip folder state survived the zip step unchanged.

This check needs to run as a release-time step for **every** corpus,
not just ones you suspect have the problem -- the bug is silent (no
error, no warning) and the only symptom is a zip entry count that's
slightly higher than the RDS paper count, which is easy to not notice
unless you check for it deliberately.

## GitHub Releases can refuse to let you replace an asset ("immutable release")

Trying to delete or overwrite an asset on an older release can fail
with `HTTP 422: Cannot delete asset from an immutable release`, even
though the release isn't a draft or prerelease and asset replacement
works fine on other releases. This appears to be a per-release
immutability setting/policy on GitHub's side that isn't visible via
`gh release view`'s usual fields (`isDraft`, `isPrerelease`,
`publishedAt` all looked completely normal on an affected release).

There's no documented way found yet to lift this on an existing
release. The workaround: **publish a new release under a new tag**
with the corrected assets, then delete the old release entirely once
the new one is verified live:

```bash
gh release create {corpus}-$(date +%Y-%m-%d) --repo scienceverse/papers \
  --title "{Corpus} corpus v1" --notes "Corrected re-release: ..." \
  {corpus}.rds {corpus}_pdf.zip
# verify the new release is correct, THEN:
gh release delete {corpus}-OLD-DATE --repo scienceverse/papers --yes
```

Don't delete the old release until the new one's assets are confirmed
present and correct (fresh `gh release download` + count check) --
deleting first and having the new upload fail would leave the corpus
unpublished entirely.

## CrossRef's `date-parts` is a nested list -- `[1]` vs `[[1]]` matters

`it$published$\`date-parts\`` parses as `list(list(2017, 9))`, i.e. a
length-1 list whose single element is itself a list of integers (year,
month, [day]). Reaching for the year with a single `[1]` index
(`...$\`date-parts\`[[1]][1]`) looks correct but actually returns a
**length-1 list containing the integer**, not the bare integer --
because `[1]` on a list returns a sub-list, not the element, while
`[[1]]` returns the element itself. Building a `data.frame()` column
from this gives every row a list-column instead of an integer column,
and `do.call(rbind, list_of_these_rows)` then fails with `names do not
match previous names` (a confusing error that doesn't mention the real
cause at all).

```r
# Wrong -- yr is a list(2017), not 2017
yr <- it$published$`date-parts`[[1]][1]

# Right -- yr is 2017
yr <- it$published$`date-parts`[[1]][[1]]
```

This broke a complete-corpus build (small journal, no stratified
sampling needed) on the very first run, with every one of 295 articles
affected identically -- a useful tell that when *every* row has the
same structural problem, suspect an indexing bug in the row-construction
function rather than bad data from the API.

## OpenAlex was evaluated as a PDF-location source and found to add no value over Unpaywall

`api.openalex.org/works/doi:{doi}` was tested as a possible
alternative/supplement to Unpaywall for finding open-access PDF
locations, prompted by it being a newer, actively-maintained database.
Tested side-by-side on 9 DOIs from journals already in this pipeline:
8 of 9 returned a `pdf_url` identical to Unpaywall's `best_oa_location
.url_for_pdf`, and the 9th had no PDF URL in either source. OpenAlex
appears to draw from substantially the same underlying OA-detection
crawl as Unpaywall for these journals, so it is not worth adding as a
parallel lookup -- it didn't recover any DOI that Unpaywall missed in
this sample. This may not generalize to every journal/publisher, but
in the journals checked so far it added no measurable yield for the
added complexity of a second API.

## Same publisher access pattern (Cloudflare Client Hints) recurs across unrelated publishers

The Cloudflare Client Hints block (documented above for SAGE) is not
specific to SAGE -- the identical signature (`Cf-Mitigated: challenge`
on a request with a Chrome User-Agent but no `Sec-CH-UA`/`Sec-CH-UA-
Mobile`/`Sec-CH-UA-Platform` headers; resolved completely by adding
those three headers, no rate-limiting needed) was also found on MIT
Press's `direct.mit.edu` host. When a new publisher's PDF host returns
a 403 with no obvious CAPTCHA/JS-challenge page, check the response
headers for `Cf-Mitigated`/`Critical-Ch` **before** assuming it's a
harder block (like Wiley's) that isn't worth pursuing -- this specific
signature has a known, cheap fix and has now been seen on two unrelated
publishers using Cloudflare.
## Always verify the downloaded PDF is the publisher's version of record, not a reformatted substitute

Before accepting any PDF source as the answer for a corpus -- especially a
fallback/scraped route discovered mid-project -- check that the file
actually is the publisher's typeset version, not a Word-exported preprint,
an author manuscript, or some other reformatted stand-in that happens to
satisfy the `%PDF-` header check. The header check only confirms "this is a
PDF," not "this is the right PDF." Concretely:

- Prefer Unpaywall's `oa_locations` entries tagged `host_type: publisher`
  and `version: publishedVersion` over any `repository`/`submittedVersion`
  copy (already documented above) -- but also **spot-check a few actual
  downloaded files** by opening them, not just trusting the metadata tag.
- A publisher's own CDN/landing-page-scrape route (like
  `elifesciences.org`'s embedded download link, or a Silverchair
  `article-pdf/doi/...` URL) is generally trustworthy *if* it's coming
  straight from the publisher's own domain -- but verify the file size and
  page count look like a real article (a Word-exported single-page PDF or
  a 5KB file claiming to be a 12-page paper is a red flag) rather than
  just checking the header bytes.
- When introducing a new download route mid-corpus (not part of the
  original, already-verified pipeline), test it on 3-5 real files first:
  open them, confirm they have proper typeset formatting (running
  headers/footers, journal-style layout, page numbers in the publisher's
  format), not a one-column plain-text reflow.

This matters more than it might seem -- a corpus full of correctly-sized,
correctly-headered PDFs that are actually the *wrong* version (preprint
instead of VoR, or a different article entirely) would pass every
automated check in this pipeline and only surface as wrong when someone
actually reads the content.

## A single-character regex bug silently broke a working download route for an entire corpus

The `elifesciences.org` landing-page-scrape fallback (documented above --
extracting a `_hash=...`-signed direct PDF link from the article page's
HTML) looked like an unreliable/intermittent route: roughly 40-90% of
download attempts failed with `406 Not Acceptable: invalid signature`,
in a pattern that superficially resembled the already-documented
"intermittent Unpaywall/Europe PMC failure" issue (random-looking,
recovered partially on repeated full-script reruns). It was not that --
it was a single, deterministic bug, and treating it as "the known
intermittent thing" wasted three full retry passes before it was found.

The actual cause: the regex extracting the signed URL used a character
class that didn't include `%`:

```r
# Wrong -- silently truncates the hash if it contains a URL-encoded
# character (most commonly %3D, the encoded form of "=", which appears
# whenever the base64 hash has trailing padding)
regexpr('_hash=[A-Za-z0-9_-]+', html)

# Right -- allow percent-encoded escapes inside the hash too
regexpr('_hash=([A-Za-z0-9_-]|%[0-9A-Fa-f]{2})+', html)
```

A base64-encoded value ending in `=` padding gets URL-encoded to `%3D` in
an `href` attribute. A character class of `[A-Za-z0-9_-]+` stops matching
at the `%`, silently returning a hash that's missing its last 1-3
characters -- which is enough to fail server-side signature validation,
producing a clean, deterministic 406 every single time for that
specific URL, indistinguishable at a glance from a flaky/intermittent
failure (since *which* DOIs are affected looks essentially random --
it depends on whether that particular hash happened to need padding).

**The tell that should have caught this faster**: testing the *exact
same* extracted URL repeatedly (not re-extracting a fresh one each time)
gave a consistent 100% failure rate, not a mix of successes and
failures. True intermittent-API flakiness (the Unpaywall/Europe PMC
pattern) fails some fraction of attempts and succeeds on others for the
*identical* request. A bug that fails the *same* request every single
time is a deterministic bug in your own code or in how the request is
built, not server-side flakiness -- don't reach for "just retry it
more" without first confirming the failure is actually nondeterministic.

## Inspect the raw extracted URL/string before assuming a regex worked correctly

When scraping a value out of HTML (a signed URL, a CSRF token, an
embedded ID), printing "extraction succeeded: TRUE/FALSE" is not enough
verification -- a regex can match *something* and still silently return
a truncated or wrong substring. Print the actual extracted value and
compare it character-for-character against the raw HTML source (or
against a working example obtained another way, e.g. via the browser's
view-source) before trusting it in a pipeline, especially for any
extracted value that's used as-is in a follow-up request (a hash, a
token, an ID) where a 1-character truncation produces a clean failure
response rather than an obviously-malformed request.
## A journal can use multiple, incompatible DOI formats for the same article -- check for version suffixes

Some publishers register more than one DOI per article version under
their "Reviewed Preprint" / versioned-publication model (eLife does
this extensively: `10.7554/eLife.88799` for the canonical article and
`10.7554/eLife.88799.3` for a specific reviewed-preprint revision).
A URL-construction function that strips only the journal prefix
(`sub("^10\\.7554/eLife\\.", "", doi)`) leaves the version suffix
(`.3`) attached to what should be a bare article number, producing a
URL that 404s -- e.g. `elifesciences.org/articles/88799.3` instead of
the correct `elifesciences.org/articles/88799`.

This bug looked exactly like the already-documented "intermittent
Unpaywall/Europe PMC failure" pattern at first glance: failures that
seemed to affect a random-looking subset of DOIs, that didn't fully
resolve on a full-script rerun (some DOIs kept failing every time).
The actual tell that distinguishes "deterministic bug" from "real
intermittent flakiness": **151 of 158 stuck DOIs in this batch all
shared the same DOI shape** (a second `.{digits}` suffix) -- when a
large *specific, identifiable subset* of failures shares a structural
property, check whether your code handles that structural variant
correctly before assuming it's noise. Fix: strip a trailing version
suffix before building the URL:

```r
article_num <- sub("^10\\.7554/eLife\\.", "", doi, ignore.case = TRUE)
article_num <- sub("\\.[0-9]+$", "", article_num)   # strip ".3" etc
```

## When scraping a PDF link from an HTML page, anchor the filename pattern -- don't just match "looks like a PDF link"

An eLife article landing page links several different PDFs: the main
article (`elife-<num>-v<n>.pdf`), a combined figures supplement
(`elife-<num>-figures-v<n>.pdf`), and per-figure source data
(`elife-<num>-fig1-data1-v<n>.pdf`, etc), often with the supplementary
files appearing *before* the main article link in the page's HTML. A
regex pattern like `elife-[A-Za-z0-9.\-]+\.pdf` matches any of these,
and `regexpr()` (singular -- first match only) will silently return
whichever one happens to appear first in the document, which is often
a supplementary-data file, not the article. The download then
"succeeds" (200 status, valid `%PDF-` header, plausible-looking file
size for a short item) while actually containing the wrong content
entirely -- a different document than the one the manifest claims it
is.

Anchor the filename to the exact expected shape instead of a loose
character class:

```r
# Wrong -- matches the first elife-*.pdf link of any kind
'elife-[A-Za-z0-9.\\-]+\\.pdf'

# Right -- matches only "elife-<digits>-v<digits>.pdf", which is
# unique to the main article PDF
'elife-[0-9]+-v[0-9]+\\.pdf'
```

When auditing for this kind of contamination after the fact: check
file size against the *type* of content expected (a full research
article is rarely under ~300KB once compressed; a 2-4 page commentary
piece legitimately can be), and cross-reference the PDF's actual page
count (`pdfinfo`) and any embedded `/Title` metadata against the
expected article title -- don't rely on file size alone, since some
journals (eLife's "Insight" commentaries, for example) have
legitimately short full articles that look identical in size to a
mis-scraped supplementary file.

## R's default regex engine can mis-locate a match by one byte/character on some UTF-8 pages -- use `perl = TRUE`

A `regexpr()`/`regmatches()` call extracting a URL from scraped HTML
occasionally returned the match starting one character late --
`"ttps://elifesciences.org/..."` instead of `"https://...".` This
isn't a one-off typo in the matched text itself: the regex pattern
correctly starts with a literal `https://`, the text really does
contain a literal, complete `https://...` substring at that position,
and `substr()` (character-indexed) confirms the `h` is there -- but
`regexpr()`'s reported match-start position was one *byte* later than
the correct character position. The resulting truncated string fails
downstream with a low-level, confusing error (`Unsupported protocol
[elifesciences.org]: Protocol "ttps" not supported`) that doesn't look
like a regex bug at all.

This is a known category of issue with R's default TRE-based regex
engine on certain UTF-8 content (the exact trigger wasn't isolated --
suspected to be a multibyte character earlier in the same string
throwing off byte-vs-character offset bookkeeping in some code paths,
but not reproducible from a minimal example). It did not affect every
page -- only a handful of articles out of 1000 in one corpus -- which
made it look like sporadic flakiness rather than a deterministic
engine quirk.

**Fix: pass `perl = TRUE` to `regexpr()`/`gregexpr()` whenever
matching against scraped web content**, not just when you need a PCRE
feature TRE lacks. PCRE's UTF-8 handling does not have this off-by-one
issue:

```r
# Can silently mis-locate the match start on some UTF-8 input
regexpr(pattern, html)

# Reliable
regexpr(pattern, html, perl = TRUE)
```

If you see a downstream error mentioning a malformed/truncated version
of a string you extracted with `regexpr()` -- especially "missing its
first character" specifically -- suspect this before assuming the
source page changed or the upstream request was corrupted.

## A batch of "intermittent-looking" failures can be 2-3 unrelated deterministic bugs layered together

A retry loop that recovers some failures on each successive pass looks
exactly like the genuine intermittent-API-failure pattern documented
elsewhere in this file -- but isn't necessarily that. In one corpus,
a batch of ~390 stuck downloads turned out to be caused by three
separate, fully deterministic bugs (a URL-construction bug affecting
DOIs with version suffixes, a link-selection bug picking the wrong PDF
on some pages, and a regex engine quirk truncating the URL on others),
each affecting a different subset, fixed one at a time across several
rounds of "rerun and see what's still stuck." Naively reading "the
retry recovered some but not all" as confirmation of the known
intermittent-flakiness pattern, and just running more retries, would
have left the corpus permanently short by however many DOIs hit the
real bugs.

**Before accepting "intermittent flakiness, just retry" as the
explanation for a stalled retry, check whether the *same exact
request* (not a freshly re-fetched one) fails 100% of the time.** True
intermittent flakiness fails some attempts and succeeds on others for
the literal same request. A bug fails it every time. Also check
whether the stuck items share an identifiable structural property
(same DOI shape, same publication date range, same response size) --
genuine API flakiness doesn't correlate with input structure; a code
bug usually does.
## A stale background job can clobber a freshly-rebuilt RDS hours later -- check for orphaned jobs before trusting a file's contents

A long-running GROBID-conversion-and-assemble script (`elife_convert.R`,
which both converts PDFs *and* overwrites the corpus `.rds` at the end)
was started in the background early in a session, presumed finished or
abandoned, and forgotten about while other fixes were made by hand
(duplicate-DOI cleanup, DOI corrections, manifest rebuilds). The stale
job was still running. It finished much later, in the middle of
unrelated work, and silently overwrote the carefully-cleaned `.rds`
with its own stale, smaller, pre-fix version -- with no error, no
warning, just a background-task-completion notification that looked
routine.

**Any script that writes to a shared output file (the corpus `.rds`,
`sample.csv`, a manifest) should never be left running unaccounted for
once you start manually patching the same file by hand.** Before
trusting a file's row/paper count after a sequence of manual fixes,
check `ps aux` (or equivalent) for any process that might still be
mid-run against that same output path, especially after a long
multi-step debugging session where several variants of "the convert
script" were launched and not all of their outcomes were tracked. If
in doubt, kill or wait out every job touching that file before doing
the final rebuild, and do the final, authoritative version as one
clean, deliberate run -- not as one more increment on top of however
many background jobs happen to still be alive.

## A resample/dedup script must normalize DOI versions before comparing -- "already in the sample" needs the same normalization as everywhere else

A script resampling replacements for excluded slots checked
`!(pool$doi %in% existing_dois)` to avoid picking an article that was
already in the corpus. This compares exact DOI strings. For a journal
that registers a "Reviewed Preprint" version under a *different* DOI
than the canonical article (`10.7554/eLife.92805` vs
`10.7554/eLife.92805.3` -- both real, registered, resolving DOIs for
the same underlying paper), this check missed the collision entirely:
the resampled "replacement" was, in fact, a duplicate of an article
already in the sample, just registered under the other DOI variant.
The corpus briefly contained the same paper twice.

Any DOI-based duplicate/already-sampled check needs to normalize away
known version-suffix variation *before* comparing, not just compare
raw DOI strings -- the same normalization already needed for URL
construction (see the "multiple incompatible DOI formats" lesson
above) applies equally to deduplication logic. If you've already
written a `normalize_article_num()` helper for one purpose in a
script, reuse it for every comparison involving DOIs in that script,
not just the one that prompted writing it.

## Disk-full mid-write doesn't always fail cleanly -- and the partial file left behind isn't safe to trust

A 1000-file PDF zip (4.5GB) being written with PowerShell's
`Compress-Archive` ran the host filesystem out of space mid-write. The
write didn't simply fail and stop: `Compress-Archive` itself errored
out (`There is not enough space on the disk`), but **the partial
output file remained on disk and, in this instance, a separate
already-running background invocation of the same command kept writing
to it independently afterward**, growing it past 4GB over several more
minutes after the "failure" was already reported -- consuming freed
disk space again and producing a file that `zipfile.BadZipFile: File
is not a zip file` correctly rejected as corrupt once finally checked.

Lessons: (1) after any "disk full" error, check `df -h` immediately and
don't assume the operation actually stopped -- check whether the
process or any background sibling of it is still alive and still
writing, via process list and by watching the target file's size for a
few seconds (stable size across repeated checks = actually done; still
growing = still running). (2) Never treat a large binary artifact
(zip, RDS) as trustworthy just because it exists on disk with a
plausible-looking size after *any* error was reported during its
creation -- verify it opens/parses correctly (`zipfile.ZipFile(...)`,
`readRDS(...)`) before using it for anything, especially before
uploading it as a release asset. (3) Before any large zip/compress
operation, check free disk space against at least 2-3x the expected
output size up front, rather than discovering the shortfall mid-write.

## Background jobs that "complete" can still be invisible to you -- track what you actually launched, not what you assume finished

Across a single long working session, several variants of essentially
the same conversion/zip/resample script were launched in the
background (the script got fixed and relaunched multiple times as bugs
were found), and it became easy to lose track of which background task
IDs were genuinely done, which had been superseded, and which were
silently still running against stale inputs. This directly caused both
the RDS-clobbering incident and the runaway disk-filling zip above.

When relaunching a fixed version of a script that does the same job as
one already running or recently launched, explicitly account for the
previous instance first (confirm it finished via its actual task
notification, or confirm via `ps aux` that nothing matching it is
still alive) before starting the new one -- don't just launch the
fix and assume the old attempt is irrelevant because you "moved on."
If several iterations of fixing-and-relaunching the same script happen
in a short window, it's worth pausing to explicitly enumerate every
background task ID started so far for that file and confirm each
one's actual status before doing the final, authoritative run.
## `build.R` must be genuinely self-contained, not a narrative pointing at scripts you never share

`build.R` is the one artifact in this repo whose entire purpose is
reproducibility -- it's supposed to let someone else regenerate the
corpus from scratch. It is easy to violate this without noticing,
because the broken version still *reads* like a complete pipeline:

```r
# Phase 2: retry      - see corpus_retry_missing.R for full implementation
# source("corpus_retry_missing.R")
```

This looks like documentation of a real step, and the corpus genuinely
was built this way -- but if `corpus_retry_missing.R` only ever existed
as a one-off scratch file in your local working directory and was
never committed to the repo, anyone who clones the repo and runs
`build.R` hits a missing-file error (or, worse, the commented-out
`source()` line means it silently does nothing and the resulting
corpus is short). This bug shipped in 7 of 17 corpora in this
repository before being caught -- it is not an edge case, it is the
default failure mode of building a corpus interactively across many
small scratch scripts and only writing up the "real" `build.R`
afterward as a summary.

**Before publishing a corpus's `build.R`, grep it for any filename
ending in `.R` other than its own** (`grep -oE '[a-z_0-9]+\.R' build.R
| grep -v build.R`), and for every hit, confirm that file is either:
(a) inlined directly into `build.R` as a callable function, or (b)
actually committed alongside `build.R` in the same corpus folder. A
comment that *describes* what a missing script did is not a
substitute for the script's actual code -- if the original scratch
script is gone, reconstruct the logic from the README's "Known gaps"
narrative (which usually describes the fix in enough detail to
rewrite it) rather than leaving the comment as the only record.

**The practical pattern that avoids this entirely**: structure
`build.R` as a set of named phase functions (`phase1_download()`,
`phase2_retry_missing()`, `resample_replacement(id, year)`, etc.)
defined in the same file, with a `# == Run ==` comment block at the
bottom showing the call sequence actually used (commented out, since
some phases are conditional on what the previous phase found missing).
This way the file is simultaneously the full implementation and the
record of what was actually run -- there's no separate "real" script
that can drift out of sync with or never make it into the repo.

## Audit existing corpora for this same gap before assuming a new one is the only risk

This bug is retroactive, not just a one-time mistake to avoid going
forward -- any corpus published before this lesson was learned should
be checked. The check is cheap: `grep -oE '\b[a-z_0-9]+\.R\b'
{corpus}/build.R | sort -u | grep -v '^build\.R$'`, then for each hit,
confirm the file actually exists somewhere in the repo (`find . -name
'<hit>'` from the repo root). If a hit doesn't resolve to a real,
committed file, the corpus's `build.R` is not actually reproducible
regardless of how complete it looks at a glance.
## Entitled (paywalled) PDFs behind Cloudflare bot-detection need a real, *stealth* browser through the institutional proxy

The Cloudflare lessons above (Client Hints headers; Europe PMC fallback)
cover open-access PDFs whose *host* is bot-protected. A harder case
remains: papers your institution is **entitled** to but that are not
open-access, where the publisher (ScienceDirect/Elsevier is the worst
offender) serves the PDF only to a logged-in *browser session* and
additionally runs Cloudflare bot-detection on the PDF fetch. No `httr2`
trick reaches these -- there is no Unpaywall location, Europe PMC has no
deposit, and the PDF URL is a short-lived signed token minted by
JavaScript on click. The only thing that works is driving a **real
browser** (Playwright/Chromium) that (a) carries your institutional
login and (b) does not look automated to Cloudflare.

Two failure modes stack here, and you have to defeat both:

**1. The session/access layer.** Dutch (and many other) universities
provide access via an **EZproxy** that rewrites the host
(`www.sciencedirect.com` -> `www-sciencedirect-com.<proxy-host>`; dots
become dashes, existing dashes double). The EZproxy session cookie is
*session-scoped* -- it does **not** persist across a browser restart, and
it **times out faster than a multi-hundred-DOI run takes**. Practical
consequences: you cannot "log in once, reuse the saved profile later";
you must log in interactively in the *same* browser that does the
downloading, and you must expect long runs to die mid-way and be re-run
(so make the downloader restart-safe: skip any DOI whose PDF is already
on disk).

**2. The Cloudflare bot layer.** Even fully logged in, clicking "View
PDF" through Playwright's default Chromium gets a `403` on a
`.../cdn-cgi/verify/...` request and the real PDF host
(`pdf.sciencedirectassets.com`) is never reached -- because Playwright
advertises `navigator.webdriver = true` and launches with
`--enable-automation`. The fix is to launch a **stealth** context: drop
the automation flag and hide the webdriver fingerprint. After this, the
exact same click yields `>> DOWNLOAD ...-main.pdf` and a valid `%PDF-`.

A third, easily-missed detail: on ScienceDirect the "View PDF" anchor has
`target="_blank"`, so the PDF loads in a **popup tab**, not the page you
clicked from. You must hook the download/response listener on the *popup*,
not the opener. And set the Chromium profile to **download** PDFs rather
than render them inline (`plugins.always_open_pdf_externally = true` in
the profile's `Default/Preferences`), so a `download` event fires reliably
instead of the bytes disappearing into the internal PDF viewer.

How to diagnose which layer is failing (do this before writing the
downloader -- guessing wastes hours): open one entitled article in the
Playwright browser, log in, then trace the popup's network. A `403` on
`cdn-cgi/verify` means the bot layer (stealth needed). A popup that
bounces back to the article URL with no `pdf.sciencedirectassets.com`
request is the same bot block upstream. A `200` from
`pdf.sciencedirectassets.com` means you've won -- capture that response
or the download event.

Minimal reproducible downloader (Node + Playwright), verified against
ScienceDirect through a TU/e EZproxy. It logs in once interactively, then
clicks each article's View-PDF link and saves the popup's download:

```js
// elsevier_proxy_download.mjs
//   node elsevier_proxy_download.mjs dois.txt
// Prereq: npm i playwright ; one-time: launch ./pw_profile once, then patch
// plugins.always_open_pdf_externally=true into pw_profile/Default/Preferences.
import { chromium } from 'playwright';
import fs from 'fs'; import path from 'path'; import readline from 'readline';

const PROXY = 'dianus.libr.tue.nl';          // <-- your EZproxy host
const PDFDIR = './pdfs';
const proxify = (u) => {                      // EZproxy host-rewrite rule
  const m = u.match(/^(https?):\/\/([^/]+)(\/.*)?$/); if (!m) return u;
  const h = m[2].split(':')[0].replace(/-/g, '--').replace(/\./g, '-');
  return `https://${h}.${PROXY}${m[3] || '/'}`;
};
const safe = (d) => d.toLowerCase().replace(/[^a-z0-9]+/g, '_').slice(0, 120) + '.pdf';
const ask  = (q) => new Promise(r => { const rl = readline.createInterface(
  { input: process.stdin, output: process.stdout }); rl.question(q, a => { rl.close(); r(a); }); });
const sleep = ms => new Promise(r => setTimeout(r, ms));

const dois = fs.readFileSync(process.argv[2], 'utf8').split(/\r?\n/)
  .map(s => s.trim()).filter(Boolean);
const have = new Set(fs.readdirSync(PDFDIR).filter(f => f.endsWith('.pdf'))
  .map(f => f.replace(/\.pdf$/, '')));                    // restart-safe
const todo = dois.filter(d => !have.has(safe(d).replace(/\.pdf$/, '')));

// STEALTH launch: this is what defeats the Cloudflare bot check.
const ctx = await chromium.launchPersistentContext('./pw_profile', {
  headless: false, acceptDownloads: true,
  args: ['--disable-blink-features=AutomationControlled'],
  ignoreDefaultArgs: ['--enable-automation'],
});
await ctx.addInitScript(() => {
  Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
  window.chrome = { runtime: {} };
  Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3] });
  Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'] });
});

let pending = null;                            // { dest, done }
const hook = (p) => {                          // hook BOTH opener and popup
  p.on('download', async d => { if (pending && !pending.done) {
    try { await d.saveAs(pending.dest); pending.done = true; } catch {} } });
  p.on('response', async r => { if (pending && !pending.done &&
    (r.headers()['content-type'] || '').includes('pdf')) {
    try { const b = await r.body();
      if (b.slice(0, 5).toString() === '%PDF-') {
        fs.writeFileSync(pending.dest, b); pending.done = true; } } catch {} } });
};
ctx.on('page', hook);
const page = ctx.pages()[0] || await ctx.newPage(); hook(page);

await page.goto(proxify('https://www.sciencedirect.com/journal/addictive-behaviors'),
  { waitUntil: 'domcontentloaded' }).catch(() => {});
await ask('Log into the institution in this window, then press ENTER... ');
console.log('webdriver hidden:',
  (await page.evaluate(() => navigator.webdriver)) === undefined);   // expect true

let ok = 0, fail = 0;
for (const doi of todo) {
  const dest = path.join(PDFDIR, safe(doi)); pending = { dest, done: false };
  try {
    await page.goto(proxify(`https://doi.org/${doi}`),
      { waitUntil: 'domcontentloaded', timeout: 60000 });
    await sleep(2500);
    const a = await page.$('a[href*="/pdf"]');                 // the View-PDF link
    if (a) {
      const [popup] = await Promise.all([
        page.waitForEvent('popup', { timeout: 20000 }).catch(() => null),
        a.click({ timeout: 8000 }).catch(() => {}),
      ]);
      if (popup) { hook(popup);                                // PDF loads in popup
        for (let t = 0; t < 20 && !pending.done; t++) await sleep(1000);
        await popup.close().catch(() => {}); }
    }
  } catch {}
  const good = pending.done && fs.existsSync(dest) && fs.statSync(dest).size > 2000;
  if (good) ok++; else { fail++;
    if (fs.existsSync(dest) && fs.statSync(dest).size <= 2000) fs.unlinkSync(dest); }
  await sleep(2000 + Math.random() * 2000);                    // be polite
}
console.log(`ok=${ok} fail=${fail}`);
await ctx.close(); process.exit(0);
```

To patch the profile preference before the first run (so PDFs download
rather than render inline), after launching `./pw_profile` once so the
file exists:

```python
import json
p = "pw_profile/Default/Preferences"
d = json.load(open(p, encoding="utf-8"))
d.setdefault("plugins", {})["always_open_pdf_externally"] = True
json.dump(d, open(p, "w", encoding="utf-8"))
```

**Scope and ethics.** This is for retrieving papers your institution is
licensed for, for a specific, bounded author/topic corpus (a fair-use
research use), at a human-like rate (the `sleep()` calls are not
optional) -- not for bulk-harvesting a publisher's catalogue. Keep the
DOI list explicit and finite, stop on repeated blocks rather than
hammering, and never store institutional credentials in a script (the
login happens interactively in the real browser; the script only reuses
the live session).

**What this does *not* solve.** Journals your institution does not
subscribe to show a paywall/"Get access" page after login -- those are
genuinely unavailable and no amount of stealth changes that. To separate
"we have access but the scraper missed it" from "we have no access",
audit each still-missing DOI's landing page through the live session and
classify it (a PDF link present but unfetched => technical; "purchase /
get access" copy => no entitlement). Reporting a real download *success
rate* requires that audit -- a raw failure count conflates the two, and
it is easy to fool yourself into reading "low success rate" as "blocked"
when half of it is simply "not subscribed."

## A hybrid journal's institutional-proxy PDF host can need NO stealth at all -- check before assuming it does

The BES (British Ecological Society) journals corpus needed neither
Europe PMC (coverage was ~2-5% -- see "under 10% for a hybrid journal"
above, confirmed again here) nor the stealth-Playwright treatment
documented for ScienceDirect. A PLAIN, non-stealth Playwright session
(no automation-flag suppression, no `navigator.webdriver` override) hit
zero Cloudflare blocks through the TU/e EZproxy for either OA or
genuinely closed/paywalled Wiley articles, once logged in -- confirmed
by inspecting network responses directly (a 200 on
`application/pdf` from `.../doi/pdfdirect/...`, no `cdn-cgi/verify` 403
anywhere in the log). Wiley is the same publisher the "effectively
blocked" Cloudflare lesson above was written about, for the ece3
corpus -- but that finding was about UNAUTHENTICATED `httr2` requests
to Wiley's OA content; it does not generalize to an AUTHENTICATED
browser session through an institutional proxy. Don't assume stealth
measures are needed for a new publisher/access route just because the
same publisher was hard-blocked in a different, unauthenticated
context. Diagnose on one real article first (as the existing checklist
already says) and only add stealth if the diagnostic actually shows a
`cdn-cgi` challenge or a 403 with Cloudflare headers.

## A synthetic click can silently do nothing on some pages, with no error, until a human clicks the identical link

On several large (15MB+), figure-heavy BES/Wiley articles, Playwright's
element click produced no popup, no download, and no error -- the
popup-wait simply timed out every time, repeatably, for those specific
articles. A real human click on the exact same visible link, in the
same open browser window, completed the download immediately. The
cause was not isolated (the leading hypothesis is that Wiley's click
handler for the download button requires a genuine trusted user-gesture
event that a synthetic click doesn't satisfy for that particular button
variant, but this was not confirmed against the page's JS). This did
not correlate with OA/closed status, only roughly with file size.

Practical fix: don't chase this in code. Run the batch downloader
non-headless (as this pipeline already does for the login step) and
leave it running where the operator can see it; when it stalls on one
article with no progress for longer than the timeout, click the link
once by hand and let the script's download/response listeners pick up
the resulting file exactly as they would from a synthetic click -- they
don't care who or what triggered the event. Do not spend time trying to
make the synthetic click "more real" (extra delays, mouse movement
simulation, etc.) before confirming with a diagnostic run whether this
is even reproducible on a given publisher -- it may be specific to one
button implementation, not a general Playwright limitation.

## A download stuck at an exact, round byte count across repeated retries is not random flakiness -- stop retrying automatically

Two PDF downloads from the same run were observed truncated at exactly
262144 bytes (256KB, i.e. 2^18) -- not once, but identically on a
second automated retry attempt, hours apart. Both files passed a naive
"did a file get written and is it a real PDF" check (valid `%PDF-`
header) despite being genuinely incomplete (no `%%EOF` trailer). This
matches the general pattern already documented elsewhere in this file
("the same exact request fails 100% of the time = a deterministic
cause, not flakiness") -- but the specific tell here is worth calling
out on its own: an exact power-of-two byte count repeating across
retries points at a fixed buffer/chunk-size cutoff somewhere in the
proxy or connection stack, not at "the network dropped at a random
point." Retrying the identical automated path a third time is unlikely
to help. The fix that worked: download that one specific file by hand
in the visible browser instead of through the scripted path, which
produced a complete, correctly-sized file on the first manual attempt.
Always verify a "successful" download with BOTH the `%PDF-` header
check already documented above AND a trailer check (checking that
`%%EOF` appears in the file's last ~1000 bytes) -- the header check
alone let both truncated files through undetected until GROBID's
conversion failure ("Internal Server Error" on a structurally
incomplete file) surfaced the problem indirectly.

## GROBID's own upload-size limit can be hit by a paper whose bloat is invisible to a naive "count the embedded images" check

A GROBID server can enforce its own upload size cap independent of
anything about PDF structure quality (confirmed: 20MB on one TU/e
instance, via a real, reproducible 413 Payload Too Large on 14 of 1857
papers in one corpus, all 16-50MB figure-heavy articles). The
non-obvious part: not all PDF bloat is embedded raster images. Removing
every embedded image (PyMuPDF's per-object image deletion, or the
equivalent) can save almost nothing for a subset of oversized files --
confirmed on a real case, a 41.8MB, 9-page PDF whose embedded images
totalled 15KB, yet one single page's decompressed content stream alone
was 207MB. The bloat there was vector-graphics bloat: a plot/map/figure
exported as tens of thousands of individual line/path drawing
instructions instead of a compressed bitmap -- common from R/ggplot2
and matplotlib exports with many data points (e.g. a dense scatterplot
or a high-resolution map rendered as vector polygons rather than
rasterized). This does not show up as an "image" in any PDF library's
image-listing API at all; it is inline drawing commands in the page's
own content stream. Detect it by comparing each page's DECOMPRESSED
content-stream size (sum the decompressed size of every content stream
object on the page) against a generous threshold (5MB was used here; a
normal text/figure page is usually under 100KB) -- checking the on-disk
file size tells you nothing page-by-page, since the whole file is
compressed again on save.

The fix, since GROBID only reads the text layer and never needs the
original visual appearance: for any page whose content stream is
vector-bloated, wipe its content stream entirely and delete its images,
then re-insert JUST the page's own extracted text as a plain text box,
at a small font size, spilling onto freshly inserted blank pages if it
doesn't fit at that size on one page. This is lossless for GROBID's
purposes (99.9%+ of extractable text confirmed preserved by character
count, before vs. after, across all 18 affected files in this corpus)
and is NOT a visual reproduction -- it does not need to look like the
original page, only contain the same words.

A real bug hit while building this: PyMuPDF's `insert_textbox()`
returns a NEGATIVE number (the overflow deficit, in points) when the
text does not fit, and in that failure case it inserts NOTHING at
all -- silently. A first attempt at this fix picked a single fixed font
size (8pt) and called `insert_textbox()` once per page; for a genuinely
text-dense page this failed to fit, returned negative, and silently
zeroed out that page's text entirely (confirmed: a 3039-character
discussion section dropped to 0 extractable characters on that page).
Always check the return value is non-negative before trusting that text
was actually inserted; do not assume success from the absence of an
exception. The robust fix is a binary search on how much of the
remaining text fits at a fixed small font size (6pt worked reliably),
committing only the winning length once found, then spilling the
remainder onto a newly inserted page and repeating -- this handles
arbitrarily large text blocks without ever guessing wrong and silently
losing content.

Neither `pdftools::pdf_compress()` nor `qpdf::pdf_compress()` (R)
solves either bloat case. Both were tested directly against real
oversized files from this corpus before reaching for Python: on a
pure-image-bloat file, `pdftools::pdf_compress()` (poppler/Ghostscript
image re-quantization) saved 49.5MB to 48.9MB (1.2%); on the
pure-vector-bloat file described above, `qpdf::pdf_compress()` (lossless
stream re-compression) saved 41.8MB to 41.4MB (1.0%). Neither R package
exposes per-object image deletion or page-content-stream editing --
they only re-encode what is already there. PyMuPDF (Python) is
currently the only tool in this pipeline's toolbox capable of the
actual removal needed. If a future R package gains this capability,
re-evaluate; until then, treat "shrink an oversized PDF for GROBID" as
a Python-only step in an otherwise R-based pipeline, and say so
explicitly in the corpus's own docs rather than silently mixing
languages without explanation.

## The GitHub Contents API silently returns EMPTY content for files over roughly 1MB -- always check the byte count of what you actually got, not just the HTTP status

Copying an existing file within a repo via the Contents API (GET
contents to read, then PUT contents to write elsewhere) works perfectly
for small files, but for a 3.2MB file the GET request returned HTTP 200
with an empty-content encoding and an EMPTY content field -- no error,
no truncation warning, just nothing. The subsequent PUT then
"succeeded" (also HTTP 200) and created a real file at the new path
that was genuinely 0 bytes. Every layer reported success; only checking
the new file's actual size afterward revealed the problem. This is a
documented GitHub API behavior (the Contents API GET endpoint only
inlines content up to roughly 1MB), not a bug in any particular client
library or script.

The fix: for anything that might exceed ~1MB, read the content via the
Git Blobs API instead (using the blob `sha` from the Contents API's own
metadata response, which is always present regardless of file size) --
that endpoint returns full content regardless of size. Always verify a
copy by re-fetching the new path's size and comparing it to the
original's size before deleting the original -- a copy-then-delete-
original workflow is only as safe as that verification step; skipping
it, or trusting a 200 status code alone, can silently replace a real
file with an empty one.

## A CrossRef field returned lowercased can create silent duplicate records on every re-run if compared case-sensitively

`rcrossref::cr_works()` returns each record's own `doi` field lowercased
by CrossRef itself, even when the DOI you queried with contained
uppercase characters (e.g. querying a DOI containing `2041-210X` returns
a record with `2041-210x`). A resumable fetch loop that checks which
known DOIs are not yet in the already-fetched set will treat every DOI
containing uppercase letters as perpetually missing, since the case
never matches -- re-fetching and re-appending it on every single
re-run. This produced 241 duplicate rows (out of 1857 total DOIs) in
one corpus before being caught, all sharing the same journal prefix
containing uppercase letters -- a large, specific, identifiable subset
sharing a structural property, which is exactly the tell (documented
elsewhere in this file) that should prompt looking for a deterministic
cause rather than accepting it as noise.

Fix: compare DOIs case-insensitively everywhere in a resumable CrossRef
pipeline (lowercase both sides of every comparison), and deduplicate by
the lowercased key at every checkpoint save, not only at the very
end -- a resumed run reloads the checkpoint file and repeats whatever
comparison logic produced the duplicates in the first place, so a fix
that only runs once at the end does not prevent the bug from recurring
on the next resume.

## `rcrossref::cr_works()`'s date fields are already flat strings -- the raw-CrossRef-JSON date-parts gotcha does not apply to it

The existing "CrossRef's date-parts is a nested list" lesson above is
about parsing the raw CrossRef REST API JSON directly (e.g. via a plain
`httr2` request, as ece3's `build.R` does for its own DOI discovery).
It does NOT apply to `rcrossref::cr_works()`'s already-parsed output:
that function's publication-date columns come back as plain strings
like "2021-10" or "2021", not as a nested date-parts structure. Code
that defensively unwraps a nested list here will silently extract the
wrong thing -- confirmed: this produced a manifest year column full of
"2021-10"-style strings instead of plain "2021", which only became
visible on a manual spot-check of the output, not from any error or
warning. Check which CrossRef access path you're actually using
(`rcrossref` vs. a raw JSON request) before reusing date-extraction
code from elsewhere in this pipeline -- the two paths return
differently-shaped data for the same underlying field, and code correct
for one silently produces wrong-but-plausible-looking output for the
other.

## A rejected tool call can still have executed against the real filesystem before the rejection registers

A background shell command was interrupted by an explicit user
rejection ("the tool use was rejected... STOP what you are doing") --
but hours later, on this same corpus, hundreds of files existed on disk
under a filename convention that only that specific interrupted
command's code path could have produced, with genuinely correct,
non-corrupted content matched by DOI. The command had evidently run to
completion (or very close to it) against the real filesystem despite
the interruption message implying it had been stopped. This is not the
"stale background job" pattern already documented above (a job that
keeps running in the background and is simply forgotten about) -- this
was a job the operator explicitly, actively rejected, that nonetheless
left a complete result.

Practical lesson: a "the tool use was rejected" message is a statement
about whether the harness will act on the result or continue the
conversation from that point -- it is not a guarantee that the
underlying OS-level process the tool call started never ran or was
killed mid-execution. If unexplained files, renamed files, or state
changes turn up that don't match anything knowingly run, check whether
a recently rejected command's own code (not just currently
visible/running processes) could explain them, by testing a specific,
falsifiable prediction its logic would make (here: "if this copy-based
rename function ran, the DOI-named ORIGINAL of every renamed file
should still exist, since the function copies rather than moves") --
rather than defaulting to a vaguer explanation (background sync
software, an unrelated stray process) that happens to fit the
timestamp alone but does not survive a content-level check.

## Reorganizing a single-corpus repo into a multi-corpus layout: move-then-verify-then-delete, never delete-then-recreate

A private corpus repo held exactly one corpus with all its files flat
at the repo root, plus a large committed `.rds` that duplicated an
existing GitHub Release asset of the exact same size -- itself worth
flagging as a likely earlier mistake rather than silently preserving: a
compiled artifact that the repo's own README already calls a "Release
asset" should not also be a committed git blob. Adding a second corpus
under the same flat convention would have collided with every one of
those filenames. The safe order for this kind of reorg, used here
without incident: for each file, (1) COPY it to its new subfolder path
(using the Git Blobs API for anything over ~1MB -- see the
Contents-API-empty-content lesson above), (2) verify the copy's size
matches the original's exactly, (3) ONLY THEN delete the original from
its old path. Never delete first and recreate second -- a failed or
empty-content copy (see above) combined with an already-deleted
original is unrecoverable without a separate backup, whereas a failed
copy caught before deletion costs nothing. This same copy-verify-delete
order applies to renaming/reorganizing release assets too, though this
specific reorg didn't need to touch those (GitHub Releases are keyed by
tag/repo, not by any repo file path, so a repo-content reorg like this
one never requires touching existing release assets at all).

## Lessons from a DOI list supplied by someone else (Glasgow SPN corpus, mixed publishers)

The corpora above were sampled from CrossRef per journal. The Glasgow SPN
corpus (`papers_private`, 1035 papers from ~440 journals) started instead
from a list of DOIs exported from a university repository, and had to
reach ~30 publishers, half of them behind a paywall. Most of what follows
is about that situation.

### A DOI list from a repository export needs cleaning and checking, one DOI at a time

- **Escaped characters.** 19 of 1101 DOIs contained `\_` instead of `_`
  (`10.1162/imag\_a\_00001`), presumably from a LaTeX or Markdown export.
  CrossRef returns 404 for these. Remove backslashes before anything else.
- **DataCite DOIs.** OSF, arXiv, PsychArchives and Dagstuhl DOIs are
  registered with DataCite, not CrossRef: `api.crossref.org/works/{doi}`
  returns 404 for them. Look up `api.datacite.org/dois/{doi}` when CrossRef
  has nothing, before concluding a DOI is wrong.
- **Truncated and missing DOIs.** One DOI was missing its last digit and
  four rows had no DOI. Both were recovered by a CrossRef
  `query.bibliographic` search on the title of the repository record,
  accepting only an exact title match (lowercase, alphanumerics only).
  Repository pages do not all have a `DC.title` meta tag; fall back to the
  page's `<title>`.
- **Preprint DOIs in the list.** A repository list can contain the DOI of
  the preprint rather than of the journal article (19 here). Decide with
  the corpus owner whether these stay, are dropped, or are replaced by the
  published version (CrossRef's `is-preprint-of` relation) -- it is not a
  download question, and is easy to miss because the PDF downloads fine.
- **OSF preprints may have no PDF at all.** Five PsyArXiv/EdArXiv
  preprints had a Word file as their primary file. The OSF API needs the
  version suffix (`api.osf.io/v2/preprints/abcde_v1/`; without `_v1` it
  returned 502), and `?embed=primary_file` also returned 502, so look the
  file up via `relationships.primary_file.links.related.href` in a second
  request and check its name ends in `.pdf`.

### A supplement passes the title check -- check for the article's own DOI too

A first version of the browser downloader saved an Elsevier supplementary
file (`...-mmc1.pdf`) as the article. It had a valid `%PDF-`/`%%EOF`, a
plausible size, and the full article title on page 1 -- supplements repeat
the title. What it lacked was the article's DOI. Across 1035 PDFs, 993 had
their own DOI (whitespace removed, lowercased) in the text of the first
three pages; the 42 that did not were all checked by hand and were all
correct (eLife, Science Advances, Lancet journals, preprints and some small
journals print the DOI at the end or not at all), so "title present AND DOI
present" is a cheap first-pass filter that sends ~4% of files to a manual
look.

The cause was link scraping on a page full of other articles' links. A
ScienceDirect article page has one "View PDF" link for the article and
dozens more in the reference list, all with identical link text. Rules
that worked:

- ScienceDirect: only the `/pdfft` link whose path contains the article's
  own PII (`/pii/<PII>/pdfft?...`), taken from the article URL.
- Any other generic "PDF" link: only if it contains the DOI suffix, and
  never if it matches `supplement|suppl|mmc\d|/esm/|figure|appendix`.
- Prefer `citation_pdf_url` and known publisher URL patterns over scraping.

### ScienceDirect rate-limits the shared institutional proxy -- stop on the first 429

After ~50 ScienceDirect articles at one every 10-25 seconds through the
TU/e EZproxy, every further request was answered with **HTTP 429** and a
redirect to an Elsevier support page. Every user of the institution shares
the proxy's IP address, so carrying on risks the institution's access, not
just the download run. What worked:

- The downloader stops by itself at the first 429 response from any host.
- After a pause of about an hour, the remaining Elsevier articles at
  **one per minute** gave no further 429s. Other publishers' articles were
  downloaded in the gaps (a per-DOI-prefix minimum interval, e.g.
  `--slow 10.1016=60`), so the slow pace for one publisher does not slow
  the whole run.
- HighWire's maintenance page (`maintenance.highwire.org/maintenance-disruption.html`)
  is also served with status 429. That is an outage on their side, not a
  rate limit; exclude it from the stop rule.

### Keep one browser open and attach to it, instead of launching one per run

The EZproxy session cookie is lost whenever a Playwright-launched browser
closes, so every test, diagnostic and retry run needed a new interactive
login. Instead, start Playwright's own Chromium once by hand with a
debugging port, log in there, and have every script attach to it:

```bash
chrome.exe --user-data-dir=pw_profile --remote-debugging-port=9222 \
  --disable-blink-features=AutomationControlled https://<proxied-start-page>
```
```python
ctx = p.chromium.connect_over_cdp("http://127.0.0.1:9222").contexts[0]
page = ctx.new_page()   # work in a tab of your own; close only that tab at the end
```

A browser started this way has no `--enable-automation` flag, so
`navigator.webdriver` is false without any init-script tricks.
ScienceDirect's PDF link passed its Cloudflare check (`crasolve`) in this
browser for most articles (until the rate limit below), where the same
links had failed repeatedly in a Playwright-launched browser. Set
`plugins.always_open_pdf_externally` in the profile's `Default/Preferences`
before starting it, so that PDFs fire a `download` event.

**Run only one downloader against the shared browser at a time.**
`context.on("response")` and download listeners are context-wide: a second
process attached to the same browser would see -- and save -- the first
process's PDFs under its own DOIs.

### On the institution's VPN, try the publisher directly when it fails through the proxy

On the TU/e VPN the publishers see a TU/e IP address, so access works
without the EZproxy host rewriting. Several sites that failed through the
proxy worked directly: JAMA, Ovid/Wolters Kluwer (`journals.lww.com` now
redirects there), MDPI (Akamai "Access Denied" through the proxy), De
Gruyter ("Max challenge attempts exceeded"), Royal Society
(`ERR_BLOCKED_BY_CLIENT` on the proxied doi.org link). A second pass in
direct mode over everything that failed through the proxy recovered ~25
papers. Also, the TU/e GROBID server and the EZproxy itself were not
reachable from a home connection without the VPN (GROBID returned a
firewall "Web Page Blocked" page with HTTP 500) -- check the VPN before
debugging either.

### Publisher-specific notes

- **IEEE**: the article URL lands on `stamp/stamp.jsp?arnumber=N`, a frame
  around the PDF. Fetch `ieeexplore.ieee.org/stampPDF/getPDF.jsp?tp=&arnumber=N&ref=`.
- **APA PsycNet**: the page loads slowly (`doiLanding?doi=` -> fulltext
  page); a fixed 10-15 second wait finds nothing. Wait for the selector
  `a[href*="/fulltext/"][href$=".pdf"]` (up to 45 s). The PDF link carries
  the PsycNet record ID, not the DOI. Without a PsycArticles subscription
  only open-access articles have the link.
- **JAMA**: the PDF link redirects back to the abstract unless you are
  signed in with a personal JAMA account -- even when the institution can
  read the full text in HTML. Not solvable with institutional access alone.
- **Nature-family, Science, BMJ journals**: check entitlement before
  assuming a technical failure -- a paywall text on the page ("access
  through your institution", "buy article", ...) means no subscription.
  Log a paywall flag per DOI; it separates "no access" from "download bug".

### Smaller pitfalls

- **Playwright sync API: `time.sleep()` freezes event processing.** A
  login-wait loop that polled `page.url` with `time.sleep(3)` never saw
  the page change; use `page.wait_for_timeout(3000)`, which lets the
  event loop run.
- **A to-do list goes stale when another step runs at the same time.**
  The browser run's DOI list was made while the open-access download was
  still running; check that the PDF does not exist yet right before each
  DOI, not only when the list is made -- otherwise papers are fetched twice
  and rate-limited slots are wasted.
- **`strip_images.py` can run for hours on one file.** On a 19.4MB Nature
  paper the text-rebuild step was still running after 30 minutes of CPU
  time. Give each call a time limit (`system2(..., timeout = 300)`) and
  convert such a file unshrunk if it is under GROBID's limit (files of
  19.4MB and 20.7MB = 19.8MiB were accepted).
- **A CSV log whose first write never reached the disk has no header.**
  A run killed before the buffered header was written left an empty file;
  the next run saw the file existed and skipped the header. Write the
  header when the file is missing *or empty*.
- **Europe PMC author manuscripts.** When only publisher versions are
  wanted, skip Europe PMC results with `authMan == "Y"` or
  `epmcAuthMan == "Y"`.
- **Download stamps.** PDFs fetched with institutional access (also some
  fetched by a script over the VPN, e.g. Annual Reviews) carry a stamp
  naming the institution and IP address; mention it in the README of a
  corpus that is shared.
