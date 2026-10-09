# Architecture

## Purpose

AI Usage is a local Windows dashboard that normalizes Claude Code and OpenAI Codex usage into one disposable browser snapshot. The dashboard displays metadata and aggregate usage only; it never renders prompt text, tool arguments, API keys, provider URLs, or authorization headers.

## Runtime flow

```text
Desktop shortcut
  -> dashboard.vbs (hidden wscript launcher)
  -> Generate-ClaudeReport.ps1
       1. refuse an existing install marker, then try the SID-scoped Global\ report mutex;
          a normal launch reuses a period-compatible active page when another generator owns it;
          a launch waiting behind a failed owner requests a bounded early close for that runId
       2. after owning Global, recheck the marker before taking Local or reading any collector
       3. copy template.html and bundled pixel fonts to %TEMP%\ClaudeUsage
       4. after uncontended preflight, open the loader before starting collectors
       5. start ccusage blocks --offline for Claude window metadata (may overlap)
       6. start the quota reads: the Claude OAuth request as an async HttpClient task when
          the CLI token is valid, and the Job-contained Codex helper for a ChatGPT login
       7. run the default period's two CodeBurn reports sequentially; between 100 ms wait
          slices, load the local quota records once and publish any changed quota state,
          so a quota-only revision (empty periods) reaches the page within about a second
       8. publish a cost-conserving revision of data.js; usage becomes visible
       9. run a status call only for a provider whose live models do not reconcile, and
          publish durable model attribution
      10. repeat report-first/status-when-needed for the remaining periods
      11. finish the quota reads within their own remaining budgets; replay the CC Switch
          relay only for an API-key Codex login
      12. atomically publish each revision and mark the last one complete; a failed final
          publication enters the same classified failed state, retries the terminal revision,
          then falls back to an independent runId-bound failure.js if data.js remains unwritable
      13. in finally, retry deletion of raw scratch on every path and delete final browser
          files after the normal read grace period; label an unreleased Windows lock as
          cleanup_failed so the next launch cleans it before opening a page
      14. release the mutex only after cleanup

report.html polls data.js until complete and serially probes failure.js while data is
missing or incomplete
  -> window.__DATA__
  -> gauges, hero, provider cards, trend, heatmap, donut, ranks, polar, tables
```

## Claude quota comes from the account, not from ccusage

ccusage blocks describe a rolling 5-hour **cost** window. They say nothing about
how much of the plan is left, so a gauge built on them can only show elapsed
time - which is not a quota and must not be presented as one.

The authoritative source is `GET https://api.anthropic.com/api/oauth/usage`,
authenticated with the OAuth access token Claude Code already stores at
`%USERPROFILE%\.claude\.credentials.json`. It returns `five_hour`, `seven_day`,
and a `limits[]` array whose entries are `session`, `weekly_all`, and
`weekly_scoped` (per-model, carrying `scope.model.display_name`).

**`limits[]` is authoritative for "am I blocked".** The two headline windows
alone miss it. Observed shape when a per-model limit is exhausted:

```text
{"kind":"session",       "percent":<low>,  "severity":"normal"}
{"kind":"weekly_all",    "percent":<high>, "severity":"critical"}
{"kind":"weekly_scoped", "percent":100,    "severity":"critical",
 "scope":{"model":{"display_name":"<model>"}}, "is_active":true}
```

The totals still read as "critical but running" while requests for that one model
are already being refused. The dashboard therefore raises an explicit alarm when
any single limit reaches 100%, not only when the totals do.

Red lines, mirrored from the reference implementation in the AI Resume project:

1. the token is read-only - never refreshed, never written back;
2. the token never reaches a log, an exception message, or `data.js`
   (the HTTP failure path deliberately drops the exception text, which can echo
   the `Authorization` header);
3. under 60 seconds of remaining life counts as expired - no request is made;
4. malformed credentials and request failures degrade to the newest local record, or
   to a stated reason, never throw.

The request is an `HttpClient` task started at launch with `ResponseContentRead`,
`MaxResponseContentBufferSize` = 1 MiB, redirects disabled, and one cancellation token over
the whole exchange. Because the body is buffered before the task completes, polling
`IsCompleted` between collector slices can never stall on a trickling response.

### When the CLI is signed out

A 2026-10-08 check on the target host found the standalone CLI signed out
(`claude auth status` reported `loggedIn: false`; `.credentials.json` kept empty token
strings after its refresh token expired) while the user worked in the Claude desktop app.
The desktop app keeps its own login encrypted with Electron safeStorage and runs its embedded
Claude Code with host-supplied auth, so the CLI token is never refreshed. Decrypting another
client's credential store was rejected outright. Two official records already on disk carry
the same quota without any credential:

- Claude Code's `~/.claude.json` holds `cachedUsageUtilization = { fetchedAtMs,
  accountUuid, utilization }`, a copy of the last `/api/oauth/usage` response with
  `five_hour`, `seven_day`, and `limits[]`. It is used only when `accountUuid` equals the
  file's own `oauthAccount.accountUuid`. Windows PowerShell's `ConvertFrom-Json` rejects this
  file because project keys repeat with different case, so it is parsed with
  `JavaScriptSerializer`, which also parses the 88 KB document in about 3 ms.
- The desktop app's `%APPDATA%\Claude\plan-usage-history.json` keeps `{ t, org, u: { fh, sd } }`
  samples: five-hour and seven-day utilization without reset times. Only samples for the
  signed-in organization are used; an unknown account with a mixed-organization history is
  rejected.

The newest of these and the app's own one-hour quota cache wins and is published with
`stale:true`, `staleReason` (why live failed, or `loading` while it is pending), `cachedAt`
(when the record was observed), and `source`. Records older than seven days are ignored. The
page never invents a reset time: a recorded window whose reset has passed, or whose record is
older than the window itself, renders as rolled over rather than with its old figure, and a
recorded per-model limit past its reset no longer raises the blocked alarm. The desktop app
samples only while its own usage view refreshes, so its record can lag; the card states the
time and suggests `claude auth login` for live figures.

### Network boundary

The OAuth request goes to Anthropic's own API with the user's own credential to
read the user's own quota - the same call Claude Code makes. No session content,
prompt text, or usage aggregate is sent, and a failure still leaves the local
dashboard usable.

The app itself makes at most two authenticated requests, both of them quota reads against
a provider the user has already configured, and both of them replaying a call that
tool already makes on its own: this one, and - for an API-key Codex login only - the Codex
relay usage call described below. For a ChatGPT Codex login, the official Codex CLI makes its
own rate-limit read with its own credential. None of them sends anything but the credential
that authenticates it. Any third authenticated destination, reading another client's
credential, and any app-owned upload remain changes to the product's premise.

The required CodeBurn 0.9.19 performs one additional upstream-controlled network
operation: when its 24-hour cache is absent or stale, its status/report commands call
`loadPricing()` and GETs the public LiteLLM model-price catalogue from GitHub. The
request is unauthenticated and carries no session content, credential, rendered
payload, or usage aggregate. This was verified against the installed Windows package,
not inferred from its public interface. The installer pins this version and the generator
rejects other versions; a dependency upgrade must recheck this boundary before changing
the pin. Any new app-owned upload remains a change to the product's premise.

CodeBurn is a local reader apart from that shared public catalogue refresh; status
reconciliation does not introduce another destination or send usage aggregates anywhere.
ccusage `20.0.20` normally refreshes public LiteLLM data and may query models.dev for
missing models. AI Usage invokes `blocks --offline`, which skips both paths and uses the
package's embedded catalogues. On the audited Windows x64 package, three offline runs
averaged 356.7 ms versus 2313.7 ms online, and a recursive comparison found no value-level
difference in the parsed block payload. Both the installer and generator pin that audited
version; an unreviewed global upgrade is rejected before session data is read.

CodeBurn has one conditional public network path: if the user configured a non-USD
display currency and its 24-hour exchange-rate cache is absent or stale, `loadCurrency()`
GETs `https://api.frankfurter.app/latest?from=USD&to=<code>`. Only the target ISO code is
sent; no credential, session content, rendered payload, or usage aggregate is included.
USD does not use this path. CodeBurn falls back to rate 1 when the fetch fails, and exposes
the active `{ code, symbol, rate }` in menubar JSON; AI Usage consumes that public value.

## Codex quota follows the login Codex uses

Codex's `auth.json` records `auth_mode`; only that field is read. Its credentials are never
opened by this app.

### ChatGPT login: the official CLI answers

A ChatGPT login is limited by the account's own plan, which no relay or session file knows
precisely. The 2026-10-08 upstream check found the answer already exposed by the official CLI:
`codex app-server` serves `account/rateLimits/read` (schema `GetAccountRateLimitsResponse`,
generated offline with `codex app-server generate-json-schema`), the call behind Codex's own
`/status`. It returns `rateLimits` plus `rateLimitsByLimitId`, each window carrying
`usedPercent`, `windowDurationMins`, and Unix-second `resetsAt`, and `planType`. Codex owns,
refreshes, and sends its credential; AI Usage never sees it. On the target host the read took
about 1.8 seconds.

`src/codex-rate-limits.mjs` is the smallest client: it starts the CLI (an npm `.cmd` shim is
run through `cmd.exe` with the path in the environment, so a literal percent pair is never
expanded), sends `initialize`, `initialized`, and `account/rateLimits/read` as newline-delimited
JSON-RPC, selects the `codex` bucket, prints one whitelisted JSON object, and ends stdin so
app-server exits. A wedged child tree is stopped with `taskkill /T`. Windows PowerShell 5.1
cannot drive this protocol directly: its redirected stdin writes a UTF-8 BOM that app-server
rejects as invalid JSON, and file-redirected stdin ends the session before the answer. The
generator runs the helper through the same Job-contained collector path as ccusage, with one
absolute 30-second budget and a 1 MiB output cap, concurrently with CodeBurn.

Since 2026-09 every Codex turn writes several rate-limit buckets into the session transcript,
and the last line is often `base_model_inference` (`gpt-reserve`) at 0% rather than the plan
bucket. The previous reader took the last line and, separately, validated the already-converted
snapshot a second time, which rejected its own ISO reset and silently dropped every official
quota. The session record is now read for the newest `limit_id` `codex` entry (or a pre-bucket
entry without `limit_id`), converted exactly once, and used only as the labelled fallback when
the live read fails or is still pending.

### API-key login through a relay

`limits.codex` official data never reaches a relay-backed provider, so that card would stay
empty however much quota is left. The relay knows the answer; the session record never sees
it.

CC Switch already solved this. Every provider row in `%USERPROFILE%\.cc-switch\cc-switch.db`
may carry a `usage_script` in `providers.meta`: one declared GET plus a JavaScript
extractor, polled every `autoQueryInterval` minutes, rendered as a balance. Nothing
about the result is written to disk, so the request has to be replayed rather than
read back.

The 2026-08-30 upstream recheck pinned `farion1231/cc-switch` v3.20.1 at commit
`d8065cc628fcd373d00c4363d718095f19e78c9e`. It found no CLI, export, or local API for that
database, so it is opened read-only through the `winsqlite3.dll` that Windows already
ships - no new dependency, and no private cache is parsed. Only the current row is
read: `select id, name, meta, settings_config from providers where app_type='codex' and is_current=1`.
The schema confirms `(id, app_type)` is the primary key while `name` is not unique and there is
no `updated_at`; updates overwrite `settings_config` and `meta` in place. Fresh cache identity
therefore combines the stable row ID with a SHA-256 fingerprint of ID, name, meta, and settings.
Switching providers or changing the key, endpoint, or usage script invalidates the fresh cache.

The declaration is reused; the extractor is not. `Get-CodexUsageRequest` reads the
endpoint, method, audited headers, and timeout. It parses `model_provider` as a complete,
non-comment, unique top-level TOML assignment before the first table, then resolves
`{{baseUrl}}` only from that exact
`model_providers.<model_provider>` section; duplicate or malformed assignments fail closed.
`{{apiKey}}` comes from `auth.OPENAI_API_KEY`. `ConvertTo-CodexQuota` then does its own
extraction, because the upstream extractor is JavaScript and because the card needs the whole
`subscription` block rather than the single balance CC Switch renders.

Red lines, mirroring the Claude quota call:

1. the API key is read-only, and never reaches the payload, a log, or an exception
   message - the failure path maps a status code and discards the exception text,
   which can echo the Authorization header back;
2. only `GET` and `HEAD` are replayed; a usage script that mutates is refused rather
   than trusted;
3. the endpoint must be `https`, and every placeholder must resolve or the call
   fails closed rather than sending a literal `{{...}}`;
4. a substituted key is accepted only when the declared URL uses `{{baseUrl}}` and the final
   scheme, DNS host, and effective port equal the selected provider origin;
5. header names are restricted to `Accept`, `Accept-Encoding`, `Accept-Language`, `Api-Key`,
   `Authorization`, `Cache-Control`, `Content-Type`, `New-Api-User`, `Pragma`, `User-Agent`, and
   `X-API-Key`, and all C0/DEL control characters are rejected before and after substitution;
6. a missing database, a busy database, a disabled script, and every transport
   failure degrade to a stated reason, never throw.

The pinned upstream templates use only `Authorization`, `User-Agent`, `Content-Type`, and
`New-Api-User`; the current local Codex usage script uses the first two. Upstream supplies no
configuration-version identity suitable for fresh cache reuse. The small additional
metadata/API-key forms above are explicit compatibility choices. Arbitrary forwarded, proxy,
rewrite, host, and routing headers are not replayed.

The relay transport uses Windows PowerShell 5.1's `HttpClient` with redirects disabled.
`ResponseHeadersRead` avoids buffering an untrusted body, while one cancellation token covers
both response headers and streamed body reads. Declared and undeclared-length bodies are capped
at 1 MiB after gzip/deflate decompression. Non-success responses are classified without reading
their body, and transport failures discard exception text so a URL or authorization header cannot
leak into the snapshot or console. .NET rejects `Content-Type` on `HttpRequestHeaders`; the
transport therefore attaches that one audited upstream header to an empty `HttpContent` instance,
while every other allowed name remains a request header.

**Subscription windows are shared across keys; usage figures are not.** One
subscription can back several API keys. The response splits accordingly: `usage`,
`daily_usage`, and `model_stats` count the calling key alone, while `subscription`
counts the whole plan. The card reads only the subscription block, so it stays
correct when the same plan is used through more than one endpoint. `weekly_window_start`
is the only anchor a relay reports, so the reset is derived as start + 7 days; a
window whose limit is `0` is unmetered and renders usage without a meter.

Relay amounts carry their own `unit`. Only `USD` shares the snapshot's conversion
rate; any other unit is rendered verbatim rather than converted.

## Durable model-cost reconciliation

The 2026-08-09 upstream inventory found a deliberate split in CodeBurn 0.9.19:

- `report --format json` takes `overview.cost` from durable local aggregates, but builds
  `models` from session files that are still readable now;
- `status --format menubar-json` exposes durable `current.topModels` through a public
  command, capped at 20 rows;
- CodeBurn 0.9.23 is available, but the 2026-08-29 platform audit found material cost,
  call, and session differences against 0.9.19 over the same source store. Its faster
  scanning is therefore not a drop-in performance patch; upgrading remains a separate
  data-semantics migration.

AI Usage therefore reuses the upstream public status shape instead of parsing CodeBurn's
private cache or reimplementing its pricing logic. For each period/provider pair it runs
report first and publishes it through the existing cost-conserving fallback. When that
fallback leaves any remainder (or drops a contradictory allocation), it then runs
status and republishes the period with durable cost/call totals merged into report model
rows, so names and currently readable token details remain available. A report whose live
rows sum exactly to `overview.cost` skips status: every session is still readable, so the merge
would name the same models at the same costs, and past the 20-row status cap the live rows are
the more complete list. A non-USD report still runs status until one call has supplied
CodeBurn's exchange rate, because status is its only public source.
Status improves attribution; it is not required for a correct headline total.

Report costs are already converted to CodeBurn's active display currency, while menubar
`current.cost` and `topModels` remain USD. The merge multiplies durable cost, savings, and
estimated-cost fields by `status.currency.rate` and requires the status/report currency
codes to agree. If no usable rate exists for a non-USD report, the live-report fallback
still conserves the converted overview total. ccusage window costs are USD and are
converted at render time with the same snapshot rate; when that rate is unavailable,
those three optional window amounts show `-` instead of being mislabelled.

The invariant is strict:

```text
sum(displayed model costs) == overview.cost
```

`overview.cost` is the gross API reference-price estimate. `overview.netCost` reflects
CodeBurn optimisation semantics and is not used as the dashboard's reference-price
headline. If status is missing, ahead of the report, or truncated, live model rows remain
visible and a neutral `unattributed` row conserves the unresolved remainder. Historical
model token totals can be incomplete after source logs disappear: nonzero partial values
are labelled with `>=` in the UI, while rows with no readable token detail show `-`.
If live rows themselves exceed the reference total beyond rounding tolerance, their model
allocation is contradictory: AI Usage drops that allocation and exposes the full reference
total as unattributed instead of scaling or silently clipping named models.

`costReconciliation` records `referenceCost`, `statusCost`, `modelSource`,
`modelSourceCost`, `unattributedCost`, and `modelTokensPartial` for verification and
future migrations. It contains aggregates only.

## CodeBurn is not concurrency-safe

Overlapping CodeBurn invocations leak rows into each other. A `--provider codex`
run that overlaps a `--provider claude` run returns the **union** of both
providers' `models` and `projects` while its `overview` stays correctly scoped,
so the dashboard silently double-counts.

Measured over one session store, same period, same flags:

| run mode | codex / 30days models | matches the codex overview? |
|---|---|---|
| parallel | 10, the union of both providers | no, roughly 6x too high |
| sequential | 3, codex only | yes |

The tell is cheap to check: the two providers' model name sets must not overlap.

`Generate-ClaudeReport.ps1` therefore runs CodeBurn **one process at a time**.
Calls inside a report are sequential, and `Global\AIUsage-CodeBurn-<user SID>` also
serializes separate launcher processes across Windows terminal sessions until their shared
temporary files are cleaned. The user SID prevents unrelated accounts from sharing a lock.
Installer transactions are serialized separately by `Global\AIUsage-Install-<SID>`. A
migration first establishes `.install-pending`, publishes the pending-aware generator, and
then drains old generators and CodeBurn processes while holding neither report mutex. Holding
Global or Local during this drain could deadlock with an already-started generator waiting for
that same lock. The installer enumerates `Win32_Process`, recognizes the generator by a filename
boundary rather than one absolute path, resolves each candidate through `GetOwnerSid`, and waits
for every already started managed generator or CodeBurn process owned by the current SID across
Windows Sessions. After two empty scans it acquires Global followed by the previous
current-Session `Local\AIUsage-CodeBurn` mutex, the same order used by the generator. A process
with a positive generator/CodeBurn match and an unresolved owner remains blocking while its
  PID is alive. An unreadable command line in any Session, including Session 0, is resolved by SID:
  same-user candidates wait conservatively and other-user candidates are ignored. If owner lookup
  fails, only a live process whose executable is exactly `codeburn.exe` or `ccusage.exe` remains
  blocking; an unknown PowerShell/Node/cmd process is ignored. This distinguishes the target host's
  long-lived Session 0 system PowerShell from a native collector without making the former block
  every install.
New launches see the marker and fail closed; a launch that passed its first check before the
marker appeared rechecks immediately after it acquires Global and exits before Local or any
collector read.
The upstream inventory found no CodeBurn locking, migration, or parent-death primitive usable
on Windows; ccusage likewise exposes no parent-lifetime contract. .NET `Process.Start` cannot
atomically associate a new process with a Job Object. The project therefore reuses the same
platform-verified Win32 path as the installer: every CodeBurn and ccusage `cmd.exe` root is
created through `STARTUPINFOEX` plus `PROC_THREAD_ATTRIBUTE_JOB_LIST` inside an independent
kill-on-close Job Object. The generator retains both the process and Job handles for that
  collector's complete lifetime. A timeout or oversized output explicitly terminates the Job and
  polls `JobObjectBasicAccountingInformation.ActiveProcesses` until two observations report zero
  before the next collector may start. A plain `WaitForSingleObject` on the Job handle was tested
  and does not signal when this process tree becomes empty on the target Windows host. A
  force-terminated or crashed generator makes the kernel close its
  Job handles and terminate every cmd/Node/PowerShell descendant. A force-kill integration probe
immediately starts a replacement and uses a separate named test mutex to prove that the old and
new CodeBurn processes never overlap.

Explicit disposal also treats Job drain as a correctness condition: it checks
`TerminateJobObject`, gives the accounting state a final bounded 10-second drain, always closes the
kill-on-close Job and process handles, and marks cleanup uncertain on a timeout or Win32 failure.
This deadline matters because termination-pending kernel I/O is not guaranteed to complete in a
finite interval. Before releasing the report mutex, that exceptional path performs two empty
same-SID process scans; if it cannot prove quiescence, the process exits without releasing the mutex
so the replacement owner receives an abandoned mutex and repeats the scan. Installer command
cleanup follows the same rule before npm rollback.

The uncertainty flag is also a launch barrier, not merely a final diagnostic. Every collector start
checks it before process creation; CodeBurn completion and each 100 ms ccusage heartbeat propagate
it immediately. Optional status and ccusage errors degrade only after cleanup was verified, so their
normal best-effort behavior cannot swallow an uncertain Job and start a later CodeBurn process.

Process-start failure uses a separate two-part proof because Job membership itself may be the
failed operation. It first requests direct-root termination, then whole-Job termination, waits for
the root process handle to signal, and observes `ActiveProcesses == 0` twice before closing thread,
process, and finally Job handles. If membership or either exit proof is unavailable, the dedicated
cleanup exception triggers the conservative same-SID scan and prevents any later collector or npm
operation from starting on an uncertain process tree.

The official built-in mutex, named event, Job Object, and `Win32_Process/GetOwnerSid` CIM surfaces
were platform-verified on the target Windows host, so no new process dependency was introduced.
The 2026-08-29 upstream inventory found no CodeBurn or ccusage API for reporting a generator's
failure to a second Windows launcher. A per-run .NET `EventWaitHandle` therefore supplies that
missing platform coordination without changing either collector. The three periods and two
providers make six serial report calls plus at most six status calls. Do not
reintroduce parallelism for these calls. ccusage and the Codex quota helper are different
tools over different files and may still overlap.

The 2026-08-30 upstream recheck also found no collector-owned browser publication protocol,
terminal sidecar, or Windows parent-lifetime budget that AI Usage could wrap. CodeBurn and
ccusage expose CLI output only; neither can tell an already-open static page that a later atomic
`data.js` replacement was denied. The app therefore owns the minimal `failure.js` protocol
described below and enforces ccusage lifetime through the same platform Job Object rather than
reimplementing either collector's aggregation or parsing.

Both audited collectors are npm `.cmd` shims on Windows. PowerShell 5.1 can expose a null
`ExitCode` when such a shim is launched directly with redirected output; converting that
null to `int` produces a false zero. The generator therefore owns an explicit `cmd.exe`
process and parses its JSON file only after a real zero exit code. A syntactically valid
partial output from a nonzero process is discarded. Zero is still only a transport-level
success: exact managed scratch for every legal period is deleted before launch, JSON `null`,
strings, and booleans cannot be coerced into numeric fields, and every rendered array must
contain records only. A report must contain every rendered field, a finite nonnegative
`overview.cost`, an exact `yyyy-MM-dd` date for every daily row, and a scalar three-letter
currency code before either provider is admitted into a period. Optional status must also carry
finite cost values, Int64-range integral call counts, and a record-only `topModels`; malformed
status or ccusage blocks are ignored rather than ending later periods. PowerShell accepts
`ValidateSet` values case-insensitively, so the entry period is normalized to lowercase before
CodeBurn sees it and the snapshot validator compares period keys ordinally.

The optional ccusage process receives one absolute 120-second budget and a 16 MiB output cap
from the instant it is started. Every 100 ms CodeBurn wait slice checks that same ccusage Job;
the final local-limits phase waits only the remaining budget and never starts a second 120-second
window. Either boundary terminates and drains the complete optional Job, deletes its output, and
continues with an otherwise valid report. The integration stub covers both a process that writes
past 16 MiB and then hangs and a process that hangs until a shortened test deadline.

Validation is not the publication boundary. The generator rebuilds every nested report row,
Claude quota window, Codex quota window, official rate limit, and ccusage block as an explicit
render-only DTO. Collector-owned extra fields such as prompts, tool arguments, authorization
headers, and URLs therefore cannot cross into `data.js` even when the surrounding object is
otherwise valid. Relay quota conversion also requires at least one recognized response shape
and exact JSON numeric/boolean types; `{}`, nonnumeric balances, and string booleans become
`malformed_response` rather than a successful zero balance. The browser independently filters
every external list through `Array.isArray`
and removes falsey/non-object rows and invalid calendar dates before rendering. Dynamic date
labels are HTML-escaped even after validation.

The official Codex boundary was checked against `openai/codex`'s
`codex-rs/protocol/src/protocol.rs`, where `RateLimitWindow.used_percent` is `f64` and
`resets_at` is `Option<i64>` in Unix seconds. The collector boundary therefore accepts only a
finite `[0,100]` JSON number plus a nullable Int64 reset value, then converts the reset to ISO
text for the browser. It does not accept the ISO-shaped fixture value that older demo data used.

### Quota-first startup, 2026-10-08

A real run on the target host before this change published the first 30-day usage at
7.4 seconds and completed at 41.7 seconds; both quota cards arrived only in the last revision
and were wrong (signed-out CLI, relay script missing, official limits dropped). Each CodeBurn
call costs about 2.7 to 3.5 seconds, of which about 1 second is Node and bundle start-up and
most of the rest loads and validates CodeBurn's 76 MB session cache; the period hardly matters.

Changes and measured effect (single runs, same host, warm caches):

| change | effect |
|---|---|
| quota reads start at launch and run concurrently | live Codex quota at 3.7 s instead of after the last report |
| local quota records published between collector slices | quota-only revision at about 1.5 s |
| status pass skipped where live models already reconcile | 12 CodeBurn calls became 9 for this store |
| `NODE_COMPILE_CACHE` for collectors | about 0.35 s less per CodeBurn call once warm |
| quota change counter instead of per-slice serialization | removed about 1 s of heartbeat overhead before the first usage |

First usage stays at about 8 seconds because it is two serial CodeBurn calls; the complete
revision moved to about 33 seconds. Rejected alternatives: parallel CodeBurn (proven provider
contamination), CodeBurn internals in one Node process (module-private API, and the session
cache is still reloaded per range), CodeBurn `web`/MCP (no full report contract), a persisted
previous snapshot (the user chose to keep burn-after-read), and decrypting the Claude desktop
app's login for live Claude quota (another client's protected credential).

### Startup optimization decision record

One 2026-08-29 observation on this Windows host measured 33.045 seconds from process launch to
the only `data.js` write. The
twelve CodeBurn calls accounted for 29.396 seconds; parsing the 203 KB snapshot in Node
took about 0.364 ms, and the two local fonts total 1.19 MB. The browser was waiting for
aggregation, not loading a heavy page.

Several upstream-first alternatives were measured before changing the orchestration:

| option | result | decision |
|---|---|---|
| CodeBurn `web` / MCP | long-lived cache, but no complete model-token, project, and session report contract | reject |
| CodeBurn `export` | about 3.9 s and 23 MB, but not durable and no full-history contract | reject |
| CodeBurn 0.9.23 | faster scan, but materially different cost/call/session semantics on the same store | keep 0.9.19 |
| persist the previous full snapshot | near-instant, but retains project paths and session identifiers across launches | reject |
| parallel CodeBurn calls | faster, but proven provider contamination | reject |
| default-period progressive publish | exact existing public CLI contract and unchanged final result | adopt |

One deployed run produced its first correct 30-day snapshot at 5.382 seconds, durable
30-day model attribution at 10.271 seconds, all three selectable periods at 24.472 seconds,
and the complete revision at 32.789 seconds. Time to the first usable snapshot publication fell
by 83.7%; the
full enrichment time is intentionally similar because the same audited data still arrives.
A post-hardening deployed smoke run on the same host measured 7.080 seconds, 12.750 seconds,
28.520 seconds, and 36.030 seconds at the same four snapshot milestones. That observation
reduced first-snapshot publication time by 78.6% against the original 33.045-second observation;
full completion varies with the session store and optional quota latency and is not the
optimization target. These are single-run diagnostics, not a regression threshold: cache state
and input size were not fixed, and the measurement stops at atomic `data.js` publication. The
browser can add up to its 500 ms polling interval plus render time. A cold CodeBurn public-price
cache, and a cold exchange-rate cache for non-USD display, can also add their network timeout.
Provider quota reads start at launch and run concurrently with the local reports, so their
network timeout can no longer hold the page behind the loader or delay a usage revision. A second normal launch while the mutex is
held opens the already-running report instead of waiting through its cleanup grace period.
That reuse first advances a read-lease timestamp. The owner waits a fresh grace period from
the latest lease and switches the run state to `closing` before deletion; a launch racing
that transition waits for the mutex instead of opening a half-removed report. State and lease
writes use bounded retries and must succeed before a page can be opened or reused. If Windows
keeps raw scratch locked, final browser files still burn after the read grace, the run state
becomes `cleanup_failed`, and the next launch removes that residue before opening a page.

A 2026-08-30 real-process/real-Edge smoke run measured 9.484 seconds from spawning the source
generator to `#app.show` with the first 30-day revision. After the final security and parser
hardening, repeat runs measured 8.436 seconds from `src/` and 8.455 seconds from the installed
runtime mirror. The automated budget is 25 seconds. The test starts a fresh headless Edge
concurrently, consumes the exact URL the generator hands
to `Start-Process`, and requires the matching `active` owner plus read lease before navigating.
Its wrapper records that URL instead of invoking Windows ShellExecute, so the number covers the
real generator, a cold isolated Edge process, local-file loading, and rendering, but not the
user's default-browser association or shortcut/ShellExecute latency. Those remain deployment
smoke checks rather than part of the repeatable performance threshold. The final deployed desktop
shortcut smoke published its first coordinated snapshot in 8.213 seconds and the generator then
completed and released its owner record; that observation verifies the ShellExecute chain but does
not claim DOM-visible timing.

The final pre-release verification after the bounded-disposal and launch-barrier hardening measured
9.518 seconds from `src/`, 8.470 seconds from the installed runtime mirror, and 8.479 seconds from
the real desktop shortcut to its first coordinated 30-day snapshot. That shortcut run subsequently
removed its owner, state, and data files and left zero CodeBurn or ccusage processes.

## Data contract

`data.js` contains:

- `runId`: a unique identifier for one generator process; a lower revision from a new run
  supersedes a higher revision left in an older browser tab
- `revision`: a strictly increasing integer for this run; the browser ignores repeats
- `complete`: false while later periods or quota fields are still arriving, true in the
  final revision
- `generationError`: null on the normal path, or `{ reason, stage }` with reason fixed to
  `partial_generation_failed` when a failure after the first usable publish ends enrichment
  without deleting the available report
- `periods`: the period keys currently available, with the requested/default period first;
  the normal sequence grows from `[]` (quota-only revisions) to `30days`, then `30days`,
  `week`, `all`. A quota-only revision has empty `reports` and a provisional USD `currency`;
  the page shows the quota cards and holds the usage sections behind one status card
- `reports[periodKey].claude` / `reports[periodKey].codex`: trimmed CodeBurn reports
  whose `models` cost sum equals `overview.cost`; each also carries aggregate-only
  `costReconciliation` metadata described above
- `limits.claudeQuota`: `{ ok, reason, source, fiveHour, sevenDay, limits[] }`. `source` is
  `oauth` (live), `cache` (the app's own quota cache), `claude_code`
  (`cachedUsageUtilization`), or `claude_desktop` (desktop plan-usage samples, which carry
  no reset times or per-model limits). A non-live record adds `stale:true`, `staleReason`,
  and `cachedAt` (when it was observed). `ok:false` carries a classified `reason`
  (`loading`, `not_collected`, `no_credentials`, `malformed_credentials`, `token_expired`, `token_rejected_401`,
  `token_rejected_403`, `rate_limited`, `request_timed_out`, `failed_local`, `malformed_response`,
  `http_<status>`) and the UI states it in plain Chinese.
  The token and the account identifiers are never present in this file.
- `limits.claudeBlocks`: optional ccusage block data, including `startTime`,
  `burnRate`, and `projection` for the active window - still the only source of
  burn rate and projected spend
- `limits.codexQuota`: `{ ok, reason, provider, planName, mode, isValid, unit,
  remaining, expiresAt, windows[] }` replayed from the current CC Switch provider's
  usage script, where each window is `{ kind, limit, used, percent, startsAt, resetsAt }`
  and `percent` is null for an unmetered window. It is attempted only for an API-key login; for a
  ChatGPT or unrecognized login it is `{ ok:false, reason:'official_account' }`. Otherwise `ok:false` carries a classified
  `reason` (`loading`, `not_collected`, `no_ccswitch`, `sqlite_unavailable`, `ccswitch_unreadable`,
  `no_current_provider`, `usage_script_missing`, `usage_script_disabled`,
  `usage_script_unreadable`, `provider_config_unreadable`, `no_endpoint`,
  `no_base_url`, `no_api_key`, `credential_in_url`, `credential_scope_mismatch`,
  `unsupported_header`, `unsupported_method`, `insecure_endpoint`, `unresolved_placeholder`,
  `key_rejected_401`, `key_rejected_403`, `rate_limited`, `failed_local`, `request_timed_out`,
  `response_too_large`, `malformed_response`, `http_<status>`) and the UI states it in
  plain Chinese. Neither the API key nor the provider endpoint is present in this file.
- `limits.codex`: the official plan quota, `{ ok, reason, source, observedAt, planType,
  primary, secondary }` where `source` is `app_server` (live through the Codex CLI) or
  `session` (the newest `codex` bucket in a session transcript) and each window is
  `{ used_percent, resets_at, window_minutes }` with an ISO `resets_at`. A session record shown
  because the live read failed or is pending adds `stale:true` and `staleReason`. `ok:false`
  carries `loading`, `not_collected`, `not_logged_in`, `api_key_login`, `codex_cli_missing`,
  `app_server_unavailable`, `account_unavailable`, `no_rate_limits`, `request_timed_out`, `response_too_large`,
  `failed_local`, or `malformed_response`. A successful relay quota takes precedence on the
  card; only an API-key login consults the relay
- `generatedAt`, `period` (the default selection), `currency`, and source version

`failure.js` is a separate atomic terminal channel. It contains only
`window.__GENERATION_FAILURE__ = { reason, stage, runId, generatedAt }` and never exception text,
collector output, credentials, or report data. With an existing snapshot the browser accepts it
only when `runId` matches `data.js`; without data it accepts only `initial_generation_failed`,
after the owner has removed both stale output files before launch. Both reasons and stages are
closed enums: reasons are `initial_generation_failed` and `partial_generation_failed`; stages are
`startup`, `default_usage`, `remaining_usage`, `local_limits`, `claude_quota`, `codex_quota`, and
`final_publish`. `runId` must be a nonempty string of at most 128 characters and `generatedAt`
must parse as a date.
Missing or malformed fields leave the sidecar nonterminal and polling continues. The page probes
it only while `data.js` is absent or `complete:false`, and stops both request streams after a valid
terminal signal.

`currency` is `{ code, symbol, rate }`. `code` is the report display currency, `rate` is
exactly `1` for USD, the positive public USD-to-code rate CodeBurn used when available, or
explicitly `null` for a non-USD report whose optional status calls supplied no usable rate.
The UI prefixes non-USD
figures with the ISO code so the hand-drawn bitmap totals remain unambiguous. Both report and
status currency codes must be scalar ASCII letters with exactly three characters; booleans,
arrays, whitespace, and trailing newlines are rejected rather than coerced.

Each report keeps only `currency`, `overview`, `daily`, `models`, `projects`, and `topSessions`.
Every other CodeBurn section is dropped; `shellCommands` is called out deliberately
because it is the bulkiest section and the closest thing in the payload to command
content.

CodeBurn scopes `models` and `projects` per period, so a period the browser can
switch to has to be generated here - it cannot be re-derived from another period.

The default period is 30 days. Cost is always labelled as an API reference-price
estimate because subscription and custom-provider billing can differ. The model donut
must equal the overview total; any cost CodeBurn cannot assign to a returned model is an
explicit neutral remainder rather than a hidden gap.

## Design boundaries

- Source session stores are read-only.
- Aggregation runs locally and does not call a project backend.
- The browser receives versioned static snapshots; there is no server-side application state.
- `data.js` is written through a temporary name and same-volume atomic replacement, so a
  poller sees either the previous complete file or the next complete file, never partial JSON.
  Windows sharing violations use a bounded exponential retry while preserving the old target.
- A failure before the first usage publish atomically writes a terminal `failure.js` containing
  only a reason, stage, run ID, and timestamp. The
  loader stops polling and reports the failure immediately; normal burn-after-read still removes
  the signal and page. A period candidate enters the committed in-memory report set only when its
  atomic snapshot write succeeds. A later failure therefore restores the last published period
  set, publishes `complete:true`, classifies the stage, changes untouched quota states to
  `not_collected`, and preserves the normal read grace. Final `complete:true` publication is
  inside that same state machine: a final write failure retries a classified terminal revision;
  if `data.js` remains unwritable, the independent `failure.js` atomically terminates the already
  usable page without overwriting its last incomplete revision. Both paths change the coordination
  records to `failed`, so an incomplete page can never remain reusable. With no second launch,
  a failed page keeps the full normal grace for a cold
  browser. A waiting launch validates the live failed owner, writes that exact `runId` to
  `report-retry.request`, and then waits; only this request shortens the owner's remaining grace
  to at most two seconds. A new owner deletes stale requests before publishing `starting`.
  The owner and state records are separate files, so Windows readers can simultaneously deny
  writes to both and leave two stale `active` values after a real failure. Every normal run therefore
  creates a manual-reset `Global\AIUsage-ReportFailed-<SID>-<runId>` event before publishing
  `starting`. The failure path signals this kernel event before attempting either file transition,
  and active-page reuse checks it after validating the owner's PID and start time. The signal is
  monotonic for the live run and the owner retains its handle through read grace and cleanup; it is
  not persistent state and disappears when the last handle closes. The run ID prevents an older
  event from poisoning a new owner. This uses the platform-verified .NET/Windows named-event
  primitive because the upstream collectors expose no Windows launcher or failure-state contract.
- The normal launcher preserves burn-after-read behavior. `-KeepFile` is for debugging only;
  it opens and retains its unique debug directory directly and never joins the shared lease.
- Codex rate-limit fields are absent on relay providers; the card then reads the relay's own
  quota, and states an explicit unavailable reason when neither source answers.
- The CC Switch database is opened read-only and never written; its private caches are not parsed.

## The desktop icon cache

Explorer caches a shortcut's icon by **(icon file path + index)**, not by the
`.lnk`. Rewriting `icon.ico` in place therefore leaves the previous artwork on
the desktop, and deleting plus recreating the shortcut does not help because the
icon path is unchanged. `ie4uinit.exe -show` did not reliably evict it either.

`install.ps1` publishes the icon under a content-hashed name,
`icon-<sha256[0..7]>.ico`, and points the shortcut at that. New artwork changes
the filename, which changes the cache key, so it appears immediately with no
cache purge and no shell restart. After a shortcut commits, the installer removes only
the previous content-addressed icon that the old shortcut actually referenced. Other
icon-like files are never selected by a wildcard. `icon.ico` is still written under its
canonical name.

To check what the shell actually resolves, call `SHGetFileInfo` with
`SHGFI_ICON` on the `.lnk` and save the returned bitmap. That is what Explorer
paints, cache included, and it does not require capturing the screen.

The icon itself is pixel art authored on a 16x16 grid and scaled by whole
multiples with nearest-neighbour, so every size stays crisp. It belongs to the
same retro family as the dashboard's 5x7 bitmap numerals and block meters.

## Repository and installation

Canonical source lives in `src/`. `install.ps1` stages those files under `%LOCALAPPDATA%` and
verifies their manifest, hashes, PowerShell syntax, and ASCII requirement before it takes the
SID-scoped `Global\AIUsage-Install-<SID>` transaction mutex. Under that mutex it backs up the
managed runtime, atomically writes `.install-pending`, publishes the pending-aware generator,
and drains same-SID legacy generator/CodeBurn processes in every Session. The drain deliberately
holds neither report mutex: an already-started generator may be waiting on Global or Local, so
holding either while waiting for that process would create a five-minute lock cycle. The marker
and pending-aware installed generator stop new supported launches while the drain is in progress.
After two empty process scans, the installer acquires the SID-scoped Global report mutex and then
the current-Session legacy Local mutex, matching the generator's lock order. Only then does it
capture npm rollback baselines or mutate dependencies. Package state comes from `npm root -g`
manifests and the exact PATH command; version output is accepted only after a zero exit code. An
unreadable manifest, damaged shim, or nonzero shim is repaired by a forced install. CodeBurn
0.9.19 declares Node `>=22.13.0`; the installer therefore requires a stable release at or above
that version and accepts only a complete `vX.Y.Z` or `X.Y.Z` line. A warning containing a version
and a `22.13.0-rc` prerelease are both rejected.

The installer publishes only managed runtime files, which matters when the installation
directory is also the Git checkout. Each target is replaced atomically and verified against
the staged hash before the desktop shortcut commits. The marker is published before the
pending-aware generator and both precede the process drain and first dependency mutation.
Thus a forced termination between marker and generator still leaves the complete old runtime
and old dependencies; one after the generator leaves a fail-closed runtime until `install.ps1`
is rerun. A failed recovery that entered with an existing marker deliberately retains the
pending-aware generator.

Before publishing a marker or mutating runtime state, installer and uninstaller walk existing
components of their managed source, destination, transaction, and report-temp paths and reject
reparse points. Recursive trees are inspected one directory at a time without following a link,
and atomic publication/deletion helpers recheck the affected path. Integration tests place a
junction inside the managed destination and verify that an outside sentinel remains unchanged.
These path checks protect the supported per-user workflow from pre-existing redirection; they do
not turn path-based PowerShell I/O into a general defence against a hostile same-user process that
can replace a component between check and use. Running the installer elevated is outside the
supported deployment model and is rejected before production mutation. A narrowly validated test
mode permits elevated Windows CI only when destination, desktop, temp roots, Node, and npm are all
inside its isolated test sandbox.

The SID-scoped `Global\AIUsage-*` names coordinate cooperating installations and Sessions; they
are not an authentication boundary. A hostile second local account that can pre-create one of
these predictable kernel-object names may cause an immediate access failure or bounded denial of
service. The utility does not grant that account access to report data or credentials, but hardened
hostile multi-user desktops would require a private namespace or broker outside this per-user tool's
scope.

Every npm mutation is created inside a Windows Job Object with
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` and verified with `IsProcessInJob`. If PowerShell is
force-terminated, the kernel terminates the npm wrapper and all descendants before another
installer can acquire the mutex. The 2026-08-29 upstream inventory rejected the old
`CREATE_SUSPENDED` then `AssignProcessToJobObject` sequence because killing the parent between
those calls can strand a suspended child. Windows 10+'s official
`PROC_THREAD_ATTRIBUTE_JOB_LIST` attaches the Job during `CreateProcessW`; it was verified on
this Windows 10 x64 host under Windows PowerShell 5.1, including a parent already inside a Job.
The Win32 API is the platform implementation; Vanara supplied a mature lifetime reference but
does not expose a complete directly usable JOB_LIST mapping, so adding that dependency would
not remove the required interop. The `npm root -g` and exact PATH version probes use the same
Job creation path, redirect stdout to a transaction-owned file, discard stderr, time out after
30 seconds, and reject more than 1 MiB of stdout. This avoids redirected-pipe backpressure and
prevents an untrusted or damaged shim from hanging installation or escaping process-tree cleanup.
If creation succeeds but startup or ownership transfer then fails, cleanup independently terminates
the live root and the whole Job, waits for the root handle to signal, and requires two stable empty
Job observations before closing handles. A missing membership or exit proof raises
`InstallJobCleanupException`: later probes and npm commands are refused, npm rollback stops before
another mutation, and the same-SID fallback scan must prove quiescence.
A caught failure restores package versions, runtime files, shortcut, and icon in reverse order. Old
icons are retired under the lock and only when the previous shortcut proves ownership; an
already existing target-hash icon is backed up and restored if a later step fails. The
installer first creates a private `-init-<GUID>` directory, writes the complete owning PID and
process start time, and atomically renames that directory into the discoverable transaction
namespace. After a successful recovery it removes only dead owner-tagged transaction directories,
exact installer temp/backup names, and its stale `report-run.state=closing`; a concurrently waiting
installer remains intact. An hour-old initialization shell may be removed only when it is empty or
contains nothing except a malformed `.owner`; any unknown content is preserved.
Command paths are passed to `cmd.exe` through a process environment variable with delayed
expansion disabled, so a valid npm path containing a literal `%NAME%` segment is not rewritten.
The broad same-SID npm process scan is reserved for an abandoned install mutex or a dedicated
`InstallJobCleanupException`, meaning this installer's Job could not prove that its descendants
drained. A normal runtime publication or verification failure rolls back immediately and does not
wait for an unrelated long-lived `npm-cli.ps1`; the isolated regression test keeps such a process
alive while forcing a locked-file publication failure.
The installer never swaps or deletes the full destination tree. Running the generator directly
from `src/` remains supported; it resolves assets relative to `$PSScriptRoot` and checks both
the local and canonical installation markers.

When the repository itself is checked out at `%LOCALAPPDATA%\ClaudeUsage`, root-level runtime
copies are ignored by Git. The uninstall script detects `.git` and removes only those runtime
copies, preserving the repository.

Uninstall is a serialized transaction rather than a best-effort file sweep. It takes
`Global\AIUsage-Install-<SID>`, writes `.install-pending`, and atomically replaces the canonical
installed generator with a fail-closed launch gate. That replacement is the linearization point:
old supported launchers that started before it are a finite set drained through `Win32_Process`,
while every supported launch after it reaches only the gate. The uninstaller then takes the
SID-scoped Global report mutex and the legacy current-Session Local mutex, rechecks that the gate
did not change, and only then deletes. This project-specific gate uses the Windows atomic file
replacement already required by installation; CodeBurn and ccusage expose no install/uninstall
coordination primitive on Windows.

Every managed removal uses terminating errors and verifies absence. In repository mode the
shortcut is retained until managed runtime files and ownership-proven hashed icons are gone,
because its icon reference is the evidence a retry needs to remove an older managed icon. A
failure after marker publication rewrites the marker as `stage=failed`, leaves the remaining
runtime fail closed (the gate may already be absent after a partial delete), and does not print
success. Rerunning install repairs the runtime; rerunning uninstall completes from the partial
state. Before a retry replaces an older uninstall marker, it removes only the exact gate temp and
backup names proven by that marker. A second force termination therefore leaves the new marker as
the complete ownership record instead of orphaning residue from the older PID. Direct execution
of an arbitrary old generator copied outside the canonical install path is outside this gate's
boundary.

Normal launches retain the legacy `%TEMP%\ClaudeUsage\report.html` path while the
named mutex covers its complete lifetime. `-KeepFile` and `-NoLaunch` are debugging
modes: every run receives an independent `debug-<timestamp>-<pid>` directory so a later
debug run cannot overwrite a retained snapshot. The two quota caches alone remain shared
at the runtime root: `quota-cache.json` and `codex-quota-cache.json`. Both hold quota
state plus bounded identity/invalidation metadata, with a 120-second fresh window and a
3600-second labelled-stale window. The Claude cache is bound to a SHA-256 digest of the CLI
login's organization and Claude Code's signed-in account and organization; an account switch,
a missing digest, or a legacy envelope is never reused, and a fresh entry stands in for a request
only while the CLI token is still valid. A Codex
cache is fresh only when the current CC Switch provider can be read and both its stable
`providers.id` and SHA-256 configuration fingerprint match the cache envelope; display names
are not unique and provider rows are updated in place. Neither cache identity enters `data.js`.
Old envelopes without both fields, provider changes, and in-place meta/settings changes invalidate
fresh reuse, while an unreadable provider may use the old value only as an explicitly labelled
stale fallback. The cache stores only the digest, never raw provider metadata, settings, URLs, or
credentials.

## Compatibility identifiers

The product name is `AI Usage`. The `%LOCALAPPDATA%\ClaudeUsage` and `%TEMP%\ClaudeUsage` directories, the `Generate-ClaudeReport.ps1` filename, the `ai-usage-ledger-theme` browser preference key, and the `ccusage-dashboard` repository slug are retained compatibility identifiers. Renaming them requires an explicit migration covering existing installs, shortcuts, uninstall behavior, saved user settings, and documentation links. The installer removes the previous `Claude用量仪表盘`, `Claude Usage Dashboard`, and `AI Usage Ledger` shortcuts before creating the current shortcut.

## Visual design

Compact cards use hard borders, small radii, offset shadows, square controls,
curved icons, and a saturated multi-hue data palette. The result borrows tactile
control states from [98.css](https://github.com/jdan/98.css), pixel restraint from
[NES.css](https://github.com/nostalgic-css/NES.css), and desktop hierarchy from
[system.css](https://github.com/sakofchit/system.css) and
[7.css](https://github.com/khang-nd/7.css) without importing any framework.

- **No scanline overlay.** A 1px repeating stripe across the page reads as
  texture in a mockup and as a legibility problem in daily use. It was removed
  for exactly that reason; do not reintroduce it.
- **One pixel stack for the whole UI.** Ark Pixel Font 12px monospaced `zh_cn`
  is primary; Fusion Pixel Font 12px monospaced `zh_hans` is the per-glyph
  fallback. Both are bundled locally under OFL-1.1, copied beside the disposable
  report, and deleted with it. Ark's upstream README explicitly warns that its
  12px face still lacks many Han characters and recommends Fusion as the
  transition. A FontTools audit against `src/template.html` found six Han
  characters missing from Ark and zero missing from the combined stack. Browser
  synthesis is disabled so requested emphasis cannot blur the bitmap strokes;
  prose stays on the native 12px grid and larger numeric emphasis uses whole
  multiples where the bundled face is used.
- **Pixel numerals** remain hand-drawn 5×7 bitmap figures for the hero, provider
  totals, activity tiles, and wordmark. Each ships with a real text node for
  screen readers and copy-paste.
- **Quota meters** are segmented blocks whose fill carries severity
  (green → amber → red), so the bar itself says how close to the wall you are.

Light and dark resolve with `light-dark()` off the root `color-scheme`; the
theme control is two-state (system default, or pinned opposite) and persists
under the `ai-usage-ledger-theme` key.

Chart forms follow the data's job rather than defaulting to bars: a smooth sparkline
beside the hero figure, area+curve for the daily series, a larger calendar heatmap plus
streak tiles and a 24-hour polar chart for activity, a donut for model
composition, and ranked bars for the project ranking. Charts render at the
container's real pixel width via `ResizeObserver`, so axis text stays at its
authored size instead of shrinking with a scaled viewBox. Long calendar periods
keep a readable minimum cell size and scroll inside the heatmap pane rather than
overflowing the page. Each chart contributes one Tab stop; its data points use a
roving focus model with arrow, Home, and End keys, and every point has an accessible
value label. Focus, pointer, and touch expose the same tooltip, while an outside tap
dismisses it.

Daily curves use a small local cubic path helper with horizontal endpoint
tangents. Each segment stays between its two sample values, avoiding the peak
overshoot that a generic spline can introduce. Entry, meter, heatmap, and control
animations use transforms and opacity; path drawing animates `stroke-dashoffset`.
`prefers-reduced-motion` reduces both durations and delays to effectively
instantaneous state changes.

Palettes are validated, not eyeballed - categorical slots clear adjacent CVD
ΔE ≥ 13.7 with chroma ≥ 0.11 inside each mode's lightness band. The heatmap uses
a five-step amber-to-plum thermal ramp: adjacent OKLab distance is at least 13.9
in light mode and 12.7 in dark mode under normal vision, and at least 11.3 / 10.8
under full protanopia, deuteranopia, or tritanopia simulation. Daily values are
log-normalised between the active period's 10th and 90th percentiles, which keeps
a single spike from flattening the remaining days. The legend prints those bounds,
and every cell tooltip also reports its 1-5 intensity, so colour is not the only
carrier of magnitude.

Two SVG gotchas worth keeping: wide polar spokes need `stroke-linecap: butt`
(a round cap balloons each spoke into an overlapping blob), and the donut's
centre figure is placed as a nested `<svg>` sized from `pixelWidth()` rather
than a fixed `foreignObject`, which silently clipped wider totals.

## Verification

- Run `tests/ReportData.Tests.ps1` for durable/live merge, gross-vs-net selection,
  truncation, missing-status and ahead-status fallbacks, exact top-level TOML/section selection,
  request-header allowlisting, C0/DEL rejection, Claude usage documents from both parsers,
  account- and organization-bound local records, Codex login modes, plan-bucket selection, and
  one-time Unix-to-ISO reset conversion.
- Run `tests/Static.Tests.ps1` to parse the PowerShell scripts and module and syntax-check
  the dashboard JavaScript with Node.
- Run `tests/Generator.Integration.Tests.ps1` to execute the generator against deterministic
  stub CLIs. It verifies the two-call first publish, legacy mutex migration, ccusage offline
  ingestion, literal-percent paths, nonzero-output rejection, zero-exit schema validation,
  empty and one-row DTO arrays, strict currency/date boundaries including non-USD/no-rate
  fallback, monotonic producer revisions, transactional currency-conflict
  rejection, the pending-marker recheck after a Global wait, `-KeepFile`, active page
  reuse/lease/closing, burn-after-read, cross-period and retained-debug locked-raw cleanup
  recovery, parent force termination with Job-contained collectors and immediate non-overlapping
  restart, Job-handle completion with sixteen live descendants, full failed-page grace without a
  waiter, runId-bound early retry, persistent final-publication fault injection with the separate
  failure sidecar, ccusage oversized-then-hang and absolute-deadline termination, simultaneous
  write-denying
  locks on both coordination files with the kernel failure event overriding their stale `active`
  values, exactly one fresh recovery aggregation, final contract, and a retained terminal snapshot
  after a later CodeBurn failure. Direct cache tests also prove that same-ID key, URL, or usage-script
  changes invalidate fresh Codex quota reuse. Quota-first scenarios prove that quota-only
  revisions precede the first usage revision, that reconciled reports skip status (six calls),
  that a ChatGPT login publishes the stub app-server's `codex` bucket without credentials or
  other buckets and never consults the relay, that a hung app-server falls back to the labelled
  session record and leaves no process behind, that an account error is classified, and that a
  signed-out CLI shows the desktop record from the first revision. Direct tests cover the async
  Claude transport (pending, 401, redirect, malformed, timeout, oversized, unsendable header),
  Claude Code and desktop records including another account's data, and idempotent official
  Codex DTO validation.
- Run `tests/InstallJob.Tests.ps1` to force-kill an installer harness and prove that the
  kernel terminates its descendant process tree; it also covers zero, nonzero, timeout, bounded
  capture, oversized-output exits, and a root that exits while sixteen descendants finish at
  staggered times.
- Run `tests/Installer.Integration.Tests.ps1` against an isolated destination, desktop, and
  stub npm root. It covers successful commit, local-mutex and cross-Session process waiting,
  runtime replacement failure, existing-pending recovery, strict stable Node version parsing,
  a correct-version/nonzero PATH shim,
  post-shortcut rollback including a preexisting target-hash icon, full-installer force termination
  and forward recovery, literal-percent npm paths, two concurrent complete installers, residue
  cleanup, an unrelated long-lived npm-like process during ordinary publication rollback, icon
  ownership, stderr backpressure, and corrupt manifest repair without touching real
  installation/npm state. Every scenario resolves a fixed Node shim from the same sandbox, so an
  elevated Windows CI runner cannot fall through to a machine-global executable.
- Run `tests/Uninstaller.Integration.Tests.ps1` against an isolated destination and desktop. It
  covers install-lock serialization, gate publication failure, the late-launch gate after process
  drain, Global-then-Local waiting, partial managed deletion with a retained failed marker, direct
  retry, repository preservation, junction rejection, and shortcut-backed icon ownership. The
  test directly extracts the uninstaller's own process helpers to verify Same/Other/Unknown SID
  classification in Session 0 and two stable empty scans after ccusage. Cross-Session enumeration
  is exercised through the same SID/CIM code path, but CI does not create a second
  interactive Windows logon.
- Run `tests/New-DemoSnapshot.ps1` and verify its `data.js`; this deterministic fixture is
  also the only permitted source for the committed README screenshots.
- Run `node tests/BrowserSmoke.mjs` to exercise local `file://` incomplete-to-complete
  revisions in real headless Edge, including a quota-only first revision, official Codex window
  labels, recorded-quota labelling and rolled-over windows, cross-run revision reset, deferred URL selection,
  focus/state preservation, completion polling stop, desktop/mobile overflow, screenshots,
  mismatched failure run IDs, independent startup/partial terminal sidecars, rejection of missing
  or malformed sidecar fields without stopping polling, terminal polling stop, and runtime exceptions.
- Run `node tests/BrowserSmoke.mjs --real-generator <generator-path>` for the optional
  process-to-Edge `#app.show` budget. It consumes the generator's captured launch URL and verifies
  `active` owner/lease state, but deliberately does not claim Windows ShellExecute coverage.
- Generate a real snapshot with `-NoLaunch -KeepFile`.
- Run `tests/Verify-Snapshot.ps1` against `data.js`; confirm the exact field whitelist and
  scalar types/ranges for reports, both quota sources, official limits, and ccusage blocks;
  each period/provider model sum equals `overview.cost`; sensitive markers are absent; and
  Claude/Codex model name sets do not overlap.
- Render at desktop and mobile widths; check console errors and horizontal
  overflow (`document.documentElement.scrollWidth` must equal `clientWidth`).
- Exercise every period and provider combination, the chart/table toggle, and the
  theme toggle.
- Grep the generated `data.js` for `accessToken`, `Bearer`, `claudeAiOauth`, and
  `sk-ant` - all must be absent.
- Confirm all cost copy says API reference estimate rather than actual billing.
- After changing `icon.ico`, re-run the installer and confirm the desktop icon
  actually changed. See the icon-cache note below; a screenshot is not needed,
  `SHGetFileInfo` on the `.lnk` returns exactly what Explorer paints.
