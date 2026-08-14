# Architecture

## Purpose

AI Usage is a local Windows dashboard that normalizes Claude Code and OpenAI Codex usage into one disposable browser snapshot. The dashboard displays metadata and aggregate usage only; it never renders prompt text, tool arguments, API keys, provider URLs, or authorization headers.

## Runtime flow

```text
Desktop shortcut
  -> dashboard.vbs (hidden wscript launcher)
  -> Generate-ClaudeReport.ps1
       1. acquire the per-user Windows named mutex
       2. copy template.html and bundled pixel fonts to %TEMP%\ClaudeUsage
       3. open the browser immediately
       4. start ccusage blocks for Claude window metadata (may overlap)
       5. run CodeBurn status then report sequentially for every period x provider pair
       6. reconcile durable model costs with currently readable model details
       7. keep only the aggregates the dashboard renders
       8. read the latest locally available Codex rate-limit snapshot
       9. replay the CC Switch usage script of the current Codex provider
      10. atomically write data.js
      11. in finally, delete raw scratch on every path and delete final browser files
          after the normal read grace period
      12. release the mutex only after cleanup

report.html polls data.js
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
4. malformed credentials and request failures degrade to the ccusage window with a
   stated reason, never throw.

### Network boundary

The OAuth request goes to Anthropic's own API with the user's own credential to
read the user's own quota - the same call Claude Code makes. No session content,
prompt text, or usage aggregate is sent, and a failure still leaves the local
dashboard usable.

The app makes exactly two authenticated requests, both of them quota reads against
a provider the user has already configured, and both of them replaying a call that
tool already makes on its own: this one, and the Codex relay usage call described
below. Neither sends anything but the credential that authenticates it. Any third
authenticated destination, and any app-owned upload, remains a change to the
product's premise.

The required CodeBurn 0.9.19 performs one additional upstream-controlled network
operation: when its 24-hour cache is absent or stale, its status/report commands call
`loadPricing()` and GETs the public LiteLLM model-price catalogue from GitHub. The
request is unauthenticated and carries no session content, credential, rendered
payload, or usage aggregate. This was verified against the installed Windows package,
not inferred from its public interface. The installer pins this version and the generator
rejects other versions; a dependency upgrade must recheck this boundary before changing
the pin. Any new app-owned upload remains a change to the product's premise.

Both CodeBurn invocations are local readers apart from that shared public catalogue
refresh; status reconciliation does not introduce another destination or send usage
aggregates anywhere. The installed ccusage 20.0.14 package was also inspected on Windows and exposes no
explicit network request in this flow. Both the installer and generator pin that audited
version; an unreviewed global upgrade is rejected before session data is read.

CodeBurn has one conditional public network path: if the user configured a non-USD
display currency and its 24-hour exchange-rate cache is absent or stale, `loadCurrency()`
GETs `https://api.frankfurter.app/latest?from=USD&to=<code>`. Only the target ISO code is
sent; no credential, session content, rendered payload, or usage aggregate is included.
USD does not use this path. CodeBurn falls back to rate 1 when the fetch fails, and exposes
the active `{ code, symbol, rate }` in menubar JSON; AI Usage consumes that public value.

## Codex quota comes from the provider, not from the session record

`limits.codex` is scraped from the newest session transcript that carries a
`rate_limits` payload. Only the official OpenAI endpoint ever emits one, so a
relay-backed Codex provider leaves that card permanently empty however much quota
is left. The relay knows the answer; the session record never sees it.

CC Switch already solved this. Every provider row in `%USERPROFILE%\.cc-switch\cc-switch.db`
may carry a `usage_script` in `providers.meta`: one declared GET plus a JavaScript
extractor, polled every `autoQueryInterval` minutes, rendered as a balance. Nothing
about the result is written to disk, so the request has to be replayed rather than
read back.

The 2026-08-13 upstream inventory found no CLI, export, or local API for that
database, so it is opened read-only through the `winsqlite3.dll` that Windows already
ships - no new dependency, and no private cache is parsed. Only the current row is
read: `select name, meta, settings_config from providers where app_type='codex' and is_current=1`.
Switching providers in CC Switch therefore switches this card with it.

The declaration is reused; the extractor is not. `Get-CodexUsageRequest` reads the
endpoint, method, headers, and timeout, and resolves `{{baseUrl}}` from the
provider's TOML `model_providers.<model_provider>.base_url` and `{{apiKey}}` from its
`auth.OPENAI_API_KEY`. `ConvertTo-CodexQuota` then does its own extraction, because
the upstream extractor is JavaScript and because the card needs the whole
`subscription` block rather than the single balance CC Switch renders.

Red lines, mirroring the Claude quota call:

1. the API key is read-only, and never reaches the payload, a log, or an exception
   message - the failure path maps a status code and discards the exception text,
   which can echo the Authorization header back;
2. only `GET` and `HEAD` are replayed; a usage script that mutates is refused rather
   than trusted;
3. the endpoint must be `https`, and every placeholder must resolve or the call
   fails closed rather than sending a literal `{{...}}`;
4. a missing database, a busy database, a disabled script, and every transport
   failure degrade to a stated reason, never throw.

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
- CodeBurn 0.9.19 is still the latest published package, and upstream `main` retains the
  same split, so an upgrade does not solve the mismatch.

AI Usage therefore reuses the upstream public status shape instead of parsing CodeBurn's
private cache or reimplementing its pricing logic. For each period/provider pair it runs
status first and report second, then merges durable cost/call totals into report model
rows so names and currently readable token details remain available.

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
Calls inside a report are sequential, and a per-user Windows named .NET mutex also
serializes separate launcher processes until their shared temporary files are cleaned.
The upstream inventory found no CodeBurn locking primitive usable on Windows; the
built-in mutex was platform-verified before adoption. Each child process has a hard
timeout; Windows `taskkill /T /F` terminates the npm wrapper and its Node descendants,
and their process IDs are checked before the mutex can be released. Status reconciliation
makes twelve serial CodeBurn calls for the three periods and two providers. A full-history
Windows run measured roughly 23s on the audited machine; the loader covers that interval.
Do not reintroduce parallelism for these calls. ccusage is a different tool over the same
read-only files and may still overlap.

## Data contract

`data.js` contains:

- `periods`: the period keys produced this run, currently `week`, `30days`, `all`
- `reports[periodKey].claude` / `reports[periodKey].codex`: trimmed CodeBurn reports
  whose `models` cost sum equals `overview.cost`; each also carries aggregate-only
  `costReconciliation` metadata described above
- `limits.claudeQuota`: `{ ok, reason, fiveHour, sevenDay, limits[] }` from the
  OAuth usage endpoint. `ok:false` carries a classified `reason`
  (`no_credentials`, `malformed_credentials`, `token_expired`, `token_rejected_401`,
  `token_rejected_403`, `rate_limited`, `failed_local`, `malformed_response`,
  `http_<status>`) and the UI states it in plain Chinese.
  The token itself is never present in this file.
- `limits.claudeBlocks`: optional ccusage block data, including `startTime`,
  `burnRate`, and `projection` for the active window - still the only source of
  burn rate and projected spend
- `limits.codexQuota`: `{ ok, reason, provider, planName, mode, isValid, unit,
  remaining, expiresAt, windows[] }` replayed from the current CC Switch provider's
  usage script, where each window is `{ kind, limit, used, percent, startsAt, resetsAt }`
  and `percent` is null for an unmetered window. `ok:false` carries a classified
  `reason` (`no_ccswitch`, `sqlite_unavailable`, `ccswitch_unreadable`,
  `no_current_provider`, `usage_script_missing`, `usage_script_disabled`,
  `usage_script_unreadable`, `provider_config_unreadable`, `no_endpoint`,
  `no_base_url`, `no_api_key`, `unsupported_method`, `insecure_endpoint`,
  `unresolved_placeholder`, `key_rejected_401`, `key_rejected_403`, `rate_limited`,
  `failed_local`, `malformed_response`, `http_<status>`) and the UI states it in
  plain Chinese. Neither the API key nor the provider endpoint is present in this file.
- `limits.codex`: latest rate-limit metadata when the configured provider exposes
  it; only the official OpenAI endpoint emits it, so it is the fallback source and
  `limits.codexQuota` takes precedence when both are present
- `generatedAt`, `period` (the default selection), `currency`, and source version

`currency` is `{ code, symbol, rate }`. `code` is the report display currency, `rate` is
the public USD-to-code rate CodeBurn used when available, and the UI prefixes non-USD
figures with the ISO code so the hand-drawn bitmap totals remain unambiguous.

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
- The browser receives a single static snapshot; there is no server-side application state.
- `data.js` is written through a temporary name and atomic move to prevent partial reads.
- The normal launcher preserves burn-after-read behavior. `-KeepFile` is for debugging only.
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
cache purge and no shell restart. Stale `icon-*.ico` copies are removed on each
install, and `icon.ico` is still written under its canonical name.

To check what the shell actually resolves, call `SHGetFileInfo` with
`SHGFI_ICON` on the `.lnk` and save the returned bitmap. That is what Explorer
paints, cache included, and it does not require capturing the screen.

The icon itself is pixel art authored on a 16x16 grid and scaled by whole
multiples with nearest-neighbour, so every size stays crisp. It belongs to the
same retro family as the dashboard's 5x7 bitmap numerals and block meters.

## Repository and installation

Canonical source lives in `src/`. `install.ps1` copies those files to `%LOCALAPPDATA%\ClaudeUsage` and creates the desktop shortcut. Running the generator directly from `src/` is supported because it resolves `template.html` relative to `$PSScriptRoot`.

When the repository itself is checked out at `%LOCALAPPDATA%\ClaudeUsage`, root-level runtime copies are ignored by Git. The uninstall script detects `.git` and removes only those runtime copies, preserving the repository.

Normal launches retain the legacy `%TEMP%\ClaudeUsage\report.html` path while the
named mutex covers its complete lifetime. `-KeepFile` and `-NoLaunch` are debugging
modes: every run receives an independent `debug-<timestamp>-<pid>` directory so a later
debug run cannot overwrite a retained snapshot. The two quota caches alone remain shared
at the runtime root: `quota-cache.json` and `codex-quota-cache.json`. Both hold quota
state only, with a 120-second fresh window and a 3600-second labelled-stale window.

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
  truncation, missing-status, and ahead-status fallbacks.
- Run `tests/Static.Tests.ps1` to parse the PowerShell scripts and module and syntax-check
  the dashboard JavaScript with Node.
- Run `tests/New-DemoSnapshot.ps1` and verify its `data.js`; this deterministic fixture is
  also the only permitted source for the committed README screenshots.
- Generate a real snapshot with `-NoLaunch -KeepFile`.
- Run `tests/Verify-Snapshot.ps1` against `data.js`; confirm each period/provider model
  sum equals `overview.cost`, reconciliation metadata is present, sensitive markers are
  absent, and Claude/Codex model name sets do not overlap.
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
