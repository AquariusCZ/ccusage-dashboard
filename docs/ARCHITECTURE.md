# Architecture

## Purpose

AI Usage is a local Windows dashboard that normalizes Claude Code and OpenAI Codex usage into one disposable browser snapshot. The dashboard displays metadata and aggregate usage only; it never renders prompt text, tool arguments, API keys, provider URLs, or authorization headers.

## Runtime flow

```text
Desktop shortcut
  -> dashboard.vbs (hidden wscript launcher)
  -> Generate-ClaudeReport.ps1
       1. copy template.html to %TEMP%\ClaudeUsage\report.html
       2. open the browser immediately
       3. start ccusage blocks for Claude window metadata (may overlap)
       4. run CodeBurn sequentially for every period x provider pair
       5. keep only the aggregates the dashboard renders
       6. read the latest locally available Codex rate-limit snapshot
       7. atomically write data.js
       8. delete report.html and data.js after a short browser-read grace period

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
4. any failure degrades to the ccusage window with a stated reason, never throws.

### This is the one network call

Everything else in this tool is local. This request goes to Anthropic's own API,
with the user's own credential, to read the user's own quota - the same call
Claude Code makes. No session content, prompt text, or usage aggregate is sent.
If that call fails or the credential is absent, the dashboard still renders
completely from local data. Any change that would send more than this needs to
be treated as a change to the product's premise.

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
This costs roughly 9s instead of 3s for six report calls, which the loader covers.
Do not reintroduce parallelism for these calls. ccusage is a different tool over
the same read-only files and may still overlap.

## Data contract

`data.js` contains:

- `periods`: the period keys produced this run, currently `week`, `30days`, `all`
- `reports[periodKey].claude` / `reports[periodKey].codex`: trimmed CodeBurn reports
- `limits.claudeQuota`: `{ ok, reason, fiveHour, sevenDay, limits[] }` from the
  OAuth usage endpoint. `ok:false` carries a classified `reason`
  (`no_credentials`, `token_expired`, `token_rejected_401`, `failed_local`,
  `malformed_response`, `http_<status>`) and the UI states it in plain Chinese.
  The token itself is never present in this file.
- `limits.claudeBlocks`: optional ccusage block data, including `startTime`,
  `burnRate`, and `projection` for the active window - still the only source of
  burn rate and projected spend
- `limits.codex`: latest rate-limit metadata when the configured provider exposes
  it; frequently all-null on custom providers, which the UI states explicitly
- `generatedAt`, `period` (the default selection), `currency`, and source version

Each report keeps only `overview`, `daily`, `models`, `projects`, `topSessions`,
`activities`, `tools`, `mcpServers`, `skills`, `subagents`, and
`claudeAgentTypes`. `shellCommands` is dropped deliberately: it is the bulkiest
section and the closest thing in the payload to command content.

CodeBurn scopes `models` and `projects` per period, so a period the browser can
switch to has to be generated here - it cannot be re-derived from another period.

The default period is 30 days. Cost is always labelled as an API reference-price
estimate because subscription and custom-provider billing can differ. The model
donut totals only cost CodeBurn attributes to a named model, which can sit
slightly below the overview total; the section says so.

## Design boundaries

- Source session stores are read-only.
- Aggregation runs locally and does not call a project backend.
- The browser receives a single static snapshot; there is no server-side application state.
- `data.js` is written through a temporary name and atomic move to prevent partial reads.
- The normal launcher preserves burn-after-read behavior. `-KeepFile` is for debugging only.
- Codex rate-limit fields may be absent with custom providers; the UI displays an explicit unavailable state.

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

## Compatibility identifiers

The product name is `AI Usage`. The `%LOCALAPPDATA%\ClaudeUsage` and `%TEMP%\ClaudeUsage` directories, the `Generate-ClaudeReport.ps1` filename, the `ai-usage-ledger-theme` browser preference key, and the `ccusage-dashboard` repository slug are retained compatibility identifiers. Renaming them requires an explicit migration covering existing installs, shortcuts, uninstall behavior, saved user settings, and documentation links. The installer removes the previous `Claude用量仪表盘`, `Claude Usage Dashboard`, and `AI Usage Ledger` shortcuts before creating the current shortcut.

## Visual design

Rounded cards on a warm canvas, curved icons (round caps and joins throughout),
and a saturated multi-hue palette. Retro character comes from two places only:
**pixel numerals** and the **segmented block meters** - not from surface texture.

- **No scanline overlay.** A 1px repeating stripe across the page reads as
  texture in a mockup and as a legibility problem in daily use. It was removed
  for exactly that reason; do not reintroduce it.
- **Pixel numerals** are drawn from an inlined 5×7 bitmap in the template, not
  from a webfont - the file has to stay self-contained. Latin and numeric only,
  so it is used for figures and the wordmark while Chinese copy keeps the UI
  face. Every pixel figure ships with a real text node for screen readers and
  copy-paste.
- **Quota meters** are segmented blocks whose fill carries severity
  (green → amber → red), so the bar itself says how close to the wall you are.

Light and dark resolve with `light-dark()` off the root `color-scheme`; the
theme control is two-state (system default, or pinned opposite) and persists
under the `ai-usage-ledger-theme` key.

Chart forms follow the data's job rather than defaulting to bars: a sparkline
beside the hero figure, area+line for the daily series, a calendar heatmap plus
streak tiles and a 24-hour polar chart for activity, a donut for model
composition, and ranked bars for the project ranking. Charts render at the
container's real pixel width via `ResizeObserver`, so axis text stays at its
authored size instead of shrinking with a scaled viewBox.

Palettes are validated, not eyeballed - categorical slots clear adjacent CVD
ΔE ≥ 13.7 with chroma ≥ 0.11 inside each mode's lightness band, and the heatmap
ramp is single-hue with monotone lightness. Where a fill falls below 3:1 against
the surface, a labelled legend and a table view carry the value instead.

Two SVG gotchas worth keeping: wide polar spokes need `stroke-linecap: butt`
(a round cap balloons each spoke into an overlapping blob), and the donut's
centre figure is placed as a nested `<svg>` sized from `pixelWidth()` rather
than a fixed `foreignObject`, which silently clipped wider totals.

## Verification

- Parse `src/Generate-ClaudeReport.ps1` with the PowerShell AST parser.
- Generate a real snapshot with `-NoLaunch -KeepFile`.
- Parse `data.js`; confirm each period's `claude` and `codex` model name sets do
  not overlap, which is the tell for the CodeBurn concurrency bug above.
- Render at desktop and mobile widths; check console errors and horizontal
  overflow (`document.documentElement.scrollWidth` must equal the viewport).
- Exercise every period and provider combination, the chart/table toggle, and the
  theme toggle.
- Grep the generated `data.js` for `accessToken`, `Bearer`, `claudeAiOauth`, and
  `sk-ant` - all must be absent.
- Confirm all cost copy says API reference estimate rather than actual billing.
- After changing `icon.ico`, re-run the installer and confirm the desktop icon
  actually changed. See the icon-cache note below; a screenshot is not needed,
  `SHGetFileInfo` on the `.lnk` returns exactly what Explorer paints.
