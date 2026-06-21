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