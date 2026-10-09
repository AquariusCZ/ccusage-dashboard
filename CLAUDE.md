# AI Usage

## Purpose

This personal Windows utility creates a local, disposable Claude Code and OpenAI Codex usage dashboard without uploading session content or credentials.

## Stack

- Windows PowerShell / PowerShell launcher and data assembly
- Local HTML, bundled pixel webfonts, CSS, and vanilla JavaScript dashboard
- CodeBurn for normalized Claude/Codex usage and API reference-price estimates
- ccusage for the active window's burn rate, projection, and hour-of-day profile
- Claude's OAuth usage endpoint for the real plan quota, with Claude Code's cached response and
  the Claude desktop app's plan-usage samples as labelled local fallbacks
- The official Codex CLI (`codex app-server`, through `src/codex-rate-limits.mjs`) for a ChatGPT
  login's plan quota, with session `rate_limits` as the labelled local fallback

## Commands

- Generate a debug snapshot: `powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\src\Generate-ClaudeReport.ps1 -NoLaunch -KeepFile`
- Run deterministic data tests: `powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\ReportData.Tests.ps1`
- Run static checks: `powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Static.Tests.ps1`
- Run generator orchestration tests: `powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Generator.Integration.Tests.ps1`
- Run installer process-tree tests: `powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\InstallJob.Tests.ps1`
- Run isolated installer transaction tests: `powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Installer.Integration.Tests.ps1`
- Run isolated uninstaller ownership tests: `powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Uninstaller.Integration.Tests.ps1`
- Verify a retained snapshot: `powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Verify-Snapshot.ps1 -DataPath <debug-dir>\data.js`
- Generate the screenshot-safe demo: `powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\New-DemoSnapshot.ps1 -OutputDirectory <demo-dir>`
- Run the real Edge progressive-load smoke test: `node .\tests\BrowserSmoke.mjs`
- Install locally: `powershell -ExecutionPolicy Bypass -File .\install.ps1`
- Open the installed app: `wscript.exe "$env:LOCALAPPDATA\ClaudeUsage\dashboard.vbs"`

## Rules

- `CLAUDE.md` is the only project rule source. Do not add `AGENTS.md` or duplicate rule files.
- Treat Claude and Codex session stores, Claude Code's `~/.claude.json`, the Claude desktop app's
  `plan-usage-history.json` (in `%APPDATA%\Claude` or the packaged MSIX build's package folder),
  Codex's `auth.json`, and the CC Switch database as read-only inputs.
  Read only `auth_mode` from Codex's `auth.json`, and never open the desktop app's encrypted
  login (`oauth:tokenCache`, Electron safeStorage).
- Keep every PowerShell file pure ASCII. Windows PowerShell reads a BOM-less script in the
  system ANSI code page, so a non-ASCII literal is mojibake before it can reach a snapshot
  or match a file on disk. All visible copy belongs in `template.html`, which is served as
  UTF-8; a value that must stay non-ASCII, such as the legacy Chinese shortcut name, is
  built from its code points.
- Never display or commit prompt text, tool arguments, API keys, provider URLs, or authorization headers.
- Label all cost as an API reference-price estimate, not actual subscription or provider billing.
- Keep canonical runtime files in `src/`; root-level copies are an ignored installed mirror.
- Preserve the legacy `ClaudeUsage` runtime paths, `Generate-ClaudeReport.ps1` filename, and `ai-usage-ledger-theme` browser preference key unless a migration also covers install, upgrade, uninstall, and user-setting compatibility.
- Preserve burn-after-read for normal launches and keep `-KeepFile` limited to debugging.
- Use Chinese UI copy and verify desktop/mobile layout, focus visibility, dark mode, and reduced motion.
- Keep visible copy focused on data, state, and actions. Put collection mechanics, field names,
  and reconciliation details in documentation rather than dashboard captions.

## Quota, network, and concurrency

- The app itself makes at most two authenticated network requests, both quota reads against a
  provider the user already configured: Claude's OAuth usage endpoint with a valid Claude Code
  CLI token, and - only for an API-key Codex login - the relay usage call replayed from CC
  Switch. For a ChatGPT Codex login it never replays the relay; it asks the official Codex CLI
  for the plan quota instead (`codex app-server`, `account/rateLimits/read`), and Codex sends
  its own credential. Keep every credential read-only, out of the payload, out of logs, and out
  of exception text. Any failure degrades with a stated reason; it never throws and never
  blanks the dashboard. A third authenticated destination, or reading another client's
  credential, is a change to the product's premise, not an implementation detail.
- When the Claude CLI has no valid token (the desktop app keeps its own login and never
  refreshes the CLI's), show the newest local official record instead: Claude Code's
  `cachedUsageUtilization` only for the signed-in `oauthAccount.accountUuid`, or the desktop
  app's plan-usage samples only for the signed-in organization (a mixed-organization history
  with no known account is rejected). Label `source`, `cachedAt`, and `staleReason`; never
  invent reset times the record does not carry. Parse `~/.claude.json` with
  `JavaScriptSerializer`: it repeats project keys that differ only in case, which Windows
  PowerShell `ConvertFrom-Json` rejects. Read the desktop samples from both `%APPDATA%\Claude`
  and the MSIX package folder `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude`
  (Anthropic-signed package `Claude`; another signer gives another family name) and judge
  them together: Windows redirects the packaged app's new AppData files into the package
  folder, which only the app's own process tree sees at `%APPDATA%`, while a file that existed
  before packaging is updated in place. When a desktop sample is the newest record, keep an
  older same-account record's model limits that were exhausted with a reset still ahead;
  the sample measures only the five-hour and seven-day windows. Verify file visibility outside
  the Claude app (for example with `APPDATA` pointed at an empty folder), because a session
  inside it sees the redirected view.
- Official Codex quota uses only the plan bucket, `limit_id` `codex` (or a pre-bucket record
  without `limit_id`); `base_model_inference` and other buckets are not the plan. Convert
  Unix-second resets to ISO exactly once in `ConvertTo-CodexOfficialQuota`; the published DTO
  validator must accept its own output unchanged.
- Bind the Claude quota cache to a SHA-256 digest of the CLI login's organization and Claude
  Code's signed-in account; never reuse it across a digest change or as a live answer while the
  CLI token is missing or expired. Only an API-key Codex login replays the relay; a ChatGPT or
  unrecognized login never does. The official Codex CLI may refresh its own `auth.json` when it
  answers; that is its normal behavior, and this app never writes the file.
- The Codex helper never reads Codex credentials or `auth.json`; it starts the CLI with the
  command path passed through the environment so `cmd.exe` cannot expand a literal percent
  pair, whitelists the snapshot fields it prints, and stops the whole child tree on timeout.
  It is a Job-contained optional collector with one absolute 30-second budget and a 1 MiB
  output cap.
- Codex quota on a relay provider comes from CC Switch's `usage_script`, read read-only
  from `.cc-switch\cc-switch.db` through the Windows-supplied `winsqlite3.dll`. Reuse the
  script's declared request only; never evaluate its JavaScript extractor, never replay a
  method other than GET or HEAD, never send an unresolved placeholder, and never parse CC
  Switch's private caches. Resolve `{{baseUrl}}` only from the exact TOML section selected by
  the unique top-level `model_provider`. Never put a credential in the URL. Allow only
  `Accept`, `Accept-Encoding`, `Accept-Language`, `Api-Key`, `Authorization`, `Cache-Control`,
  `Content-Type`, `New-Api-User`, `Pragma`, `User-Agent`, and `X-API-Key`; reject C0/DEL
  characters. Send a substituted credential only when the final HTTPS scheme, DNS host, and
  port match that selected provider. Official Codex `rate_limits` stay the fallback source.
- Read a relay's subscription windows, not its per-key usage: one plan can back several
  keys, and only `subscription` counts the whole plan.
- Bind fresh Codex quota cache reuse to both CC Switch's stable `providers.id` and a SHA-256
  fingerprint of that row's ID, name, `meta`, and `settings_config`; the row is updated in
  place and has no `updated_at`. Keep both values in the local cache envelope only, never
  expose them in `data.js`, and invalidate legacy envelopes or an in-place credential,
  endpoint, or usage-script change.
- CodeBurn may refresh its public LiteLLM price catalogue from GitHub when its local
  24-hour cache expires. Version `0.9.19` is the audited and required runtime; upgrades
  require re-auditing this boundary. It must never receive or upload credentials or
  rendered payloads.
- Pin ccusage `20.0.20` and invoke `blocks --json` without `--offline`. It GETs the public
  LiteLLM catalogue from GitHub, and `models.dev/api.json` only for a model LiteLLM lacks,
  never with a credential or usage data; each request has its own 10-second timeout. Its
  embedded offline snapshot lacked `claude-opus-5-5` and priced current windows at $0, so
  offline mode is not used. A failed fetch silently falls back to that snapshot with exit code
  0, and an unknown model then adds nothing to a block's cost, so pass `totalTokens`: render an
  active window with tokens but zero cost as unpriced, never as $0.00, and hide the hour profile
  when any block in range is unpriced. Redraw the usage sections when `claudeBlocks` arrives
  after the first usage revision. ccusage honours `HTTP(S)_PROXY`/`ALL_PROXY` only, not the
  Windows system proxy. Give the optional process one absolute 120-second budget and 16 MiB
  output cap from launch; every CodeBurn wait slice must enforce them, and final collection may
  wait only the remaining budget.
- When the user has selected a non-USD CodeBurn display currency, CodeBurn may refresh
  its public Frankfurter exchange-rate cache. Convert durable status USD amounts with
  the reported rate before merging, and keep CodeBurn plus ccusage costs in one currency.
- CodeBurn 0.9.19's report overview is durable while its model rows are limited to
  currently readable sessions. Reconcile model costs through CodeBurn's public local
  `status --format menubar-json` output; never read or parse CodeBurn's private cache.
- The API reference-price headline is `overview.cost`, not `overview.netCost`. For every
  period and provider, displayed model costs must sum to that headline. Represent any
  unresolved remainder explicitly as unattributed cost, and mark incomplete per-model
  token counts as lower bounds instead of presenting them as complete totals.
- Run the CodeBurn durable status pass only when a period's live report leaves any remainder or a
  contradictory allocation, or when a non-USD report still lacks CodeBurn's exchange rate (status
  is its only public source). A report whose live models sum exactly to `overview.cost` names the
  same models at the same costs, so it skips status. Collectors run with `NODE_COMPILE_CACHE` under
  `%TEMP%\ClaudeUsage\node-compile-cache` (V8 bytecode of collector code only, never usage).
- Run CodeBurn **one process at a time across launcher processes**. It is not
  concurrency-safe and overlapping runs silently mix providers' models and projects.
  Create every CodeBurn, ccusage, and Codex quota helper root atomically inside its own
  kill-on-close Windows Job Object through `PROC_THREAD_ATTRIBUTE_JOB_LIST`, and retain the
  Job handle for the collector lifetime. A normal Job handle is not a completion event on this Windows host;
  completion and forced cleanup must poll
  `JobObjectBasicAccountingInformation.ActiveProcesses` to a stable zero before another
  CodeBurn process starts. After a process is created but before ownership transfers, any
  startup failure must terminate the live root and whole Job independently, wait for the root
  handle, and prove the Job stably empty. Any unproven startup or lifetime cleanup immediately
  blocks later collectors until the same-SID fallback scan succeeds. A force-terminated generator
  must therefore lose every collector descendant before a
  replacement recovers its abandoned report mutex. See
  `docs/ARCHITECTURE.md`.
- Keep the default period first and publish progressive snapshots with increasing
  `revision` and `complete:false`; identify each process with a unique `runId`. The browser
  remains on the requested period when it arrives and polls until the final `complete:true`
  revision. Quota reads start at launch and run concurrently - the Claude request as a
  bounded async `HttpClient` task, the Codex helper as a Job-contained process - so provider
  latency can never delay a usage publish. A changed quota state is published between
  collector slices, which makes quota-only revisions (empty `periods`) precede the first usage
  revision; never publish while a period candidate is being committed, and detect changes with
  the quota state counter rather than re-serializing every slice. After the first usage
  publish, later failures must terminate with a retained
  `generationError` snapshot rather than blanking an already usable dashboard. A failure
  before the first usage snapshot must atomically publish a terminal, credential-free
  `failure.js` sidecar so the loader stops immediately instead of polling until its timeout.
  With existing data, accept that sidecar only for the same `runId`; without data, accept only
  `initial_generation_failed`. Final
  `complete:true` publication belongs to the same failure state machine: a transient final
  write failure must publish a classified terminal retry; if `data.js` remains unwritable,
  publish the same run's failure sidecar and mark the owner failed, never leave an active
  incomplete page. Without a retry request, failed pages retain the normal browser
  read grace. A waiting launch must never reuse a failed page; it may shorten that grace only by
  writing the current owner's exact `runId` to `report-retry.request`, then it waits for a fresh run.
  Each normal run also owns a manual-reset
  `Global\AIUsage-ReportFailed-<SID>-<runId>` event. Signal it before best-effort file state changes,
  and reject active-page reuse when it is set even if write-denying locks leave both coordination
  files stale. CodeBurn and ccusage expose no Windows failure-coordination contract; retain the
  platform-verified .NET named event instead of adding another file-only protocol. The lifecycle
  tests must keep the simultaneous state/owner write-lock case and prove exactly one fresh retry.
  Accept `failure.js` only when reason, stage, run ID, and parseable timestamp all match the
  closed protocol; malformed sidecars remain nonterminal and polling continues.
- Treat a collector's zero exit code as necessary but insufficient. Delete stale scratch
  before launch, require readable JSON plus every rendered report field, exact JSON-number
  types for finite costs, record-only arrays, exact `yyyy-MM-dd` daily dates, and an exact
  three-letter currency code. Preserve legitimate empty arrays at DTO boundaries. Rebuild
  every report, quota, rate-limit, and blocks row as an
  explicit render-only DTO; never pass a collector-owned nested object into `data.js`.
  Relay quota must contain a recognized shape with exact numeric/boolean types or return
  `malformed_response`. Its `HttpClient` transport must disable redirects, apply one
  cancellation token to headers and body, and reject more than 1 MiB after decompression;
  no transport failure may expose a URL, header, credential, or exception text. Status calls
  must be integral and inside Int64; malformed optional
  status/blocks output is ignored, while a malformed required report fails the candidate.
  Official Codex `rate_limits` follows `openai/codex`'s
  `codex-rs/protocol/src/protocol.rs`: `used_percent` is `f64` and `resets_at` is an optional
  Unix-seconds `i64`. Accept that integer boundary exactly and normalize it to ISO text only
  inside the render DTO.
  Normalize `-Period` to lowercase before invoking CodeBurn and validate snapshot keys with
  an ordinal comparison. Retry burn-after-read cleanup,
  leave `report-run.state=cleanup_failed` when Windows keeps a sensitive scratch file locked,
  and make the next launch clean that residue before opening a page.
- The installer serializes transactions with `Global\AIUsage-Install-<SID>`, stages and
  verifies runtime files before mutation, and leaves `.install-pending` in place until
  dependency and runtime publication both verify. During migration it writes the marker before
  the pending-aware generator, drains same-SID legacy generator/CodeBurn processes across
  Windows Sessions without holding either report mutex, then acquires Global followed by the
  legacy Local mutex before npm changes. A matched process whose owner cannot be resolved stays
  blocking while it is alive. npm command paths travel through an environment variable so
  literal percent pairs are not expanded by `cmd.exe`; version/root probes and each mutation
  are created atomically inside a kill-on-close Windows Job Object through
  `PROC_THREAD_ATTRIBUTE_JOB_LIST`. Captured probes have a 30-second timeout and 1 MiB stdout
  limit. Any failure after process creation must request direct-root termination and whole-Job
  termination, prove the root handle signalled and the Job was stably empty, then close every
  native handle. Unproven membership or cleanup raises the dedicated cleanup exception and
  blocks later npm work until the conservative same-SID scan succeeds. Scan broadly for
  same-SID npm processes only after an abandoned install mutex or a
  dedicated Job cleanup-verification failure; ordinary publication failures must roll back
  without waiting for unrelated npm work. Node must be a stable `22.13.0+` release and its complete `--version` output must be
  exactly `vX.Y.Z` or `X.Y.Z`; warnings and prereleases are not accepted.
  Rollback baselines come from the active npm root plus a zero-exit exact PATH command. Restore a
  preexisting target-hash icon on rollback. The installed generator must refuse to run while the
  marker exists and recheck it after acquiring Global, before Local or any collector read;
  publish the transaction directory only after a complete PID/start-time owner record exists.
  Successful recovery removes only dead installer-owned transactions, aged empty initialization
  shells, exact atomic residue, and stale coordination state while preserving a concurrently
  waiting installer and every incomplete shell that contains unknown data. Installer and
  uninstaller migration scans must resolve unreadable candidate command lines by SID in every
  Session, including Session 0: same-SID candidates wait, other-SID candidates are ignored,
  and an unresolved owner waits only for a live exact `codeburn.exe` or `ccusage.exe`.
  Reject reparse points in managed source, destination, transaction, and report-temp paths
  before mutation, and recheck the affected path at each atomic publication or deletion.
  Production install and uninstall are per-user operations and must reject an elevated token;
  isolated integration-test paths may opt into an elevated CI token only while every mutable
  path and executable remains inside the validated test sandbox.
- The uninstaller takes the install mutex, writes `.install-pending`, atomically replaces the
  canonical generator with a launch gate, drains already-started same-SID legacy processes,
  then takes Global followed by Local and rechecks the gate before any deletion. In repository
  mode it verifies each managed deletion and retains the shortcut until runtime and owned-icon
  removal succeeds, so a retry still has icon-ownership evidence. Any partial failure leaves a
  `stage=failed` marker and never prints success. A retry removes residue proven by the previous
  uninstall marker before replacing that marker, so a second force termination cannot orphan it.
- Treat `limits[]` as authoritative for "am I blocked", not just `five_hour` / `seven_day`.

## Type and visual rules

- Use the bundled 12px pixel stack for the whole interface: Ark Pixel Font `zh_cn`
  first, Fusion Pixel Font `zh_hans` as the broader-coverage fallback. Keep the hand-drawn
  5x7 bitmap figures for large totals and tile values.
- One radius scale, one accent per provider, one theme for the whole page.
- No scanline or stripe overlays. They were removed for legibility; do not reintroduce.
- Daily series use smooth, non-overshooting cubic curves. Motion must degrade through
  `prefers-reduced-motion` and must not be required to read any value.
- Validate any new categorical or sequential palette with the dataviz validator rather
  than eyeballing it.

## Publishing

- Screenshots in `docs/` must be rendered from synthetic demo data, never from a real
  session store. Use `tests/New-DemoSnapshot.ps1`; real project paths and account quota
  state are personal data. Keep `dashboard.png` at 1280x1000 and `mobile.png` at 520x1200,
  and re-render both whenever a card visible in them changes.
- The demo anchors every timestamp to generation time, so quota meters always show a live
  countdown; pass `-AsOf` to pin a run. Fixed past dates render every window as "about to
  reset" and the meters stop showing anything.
- Capture screenshots through the DevTools Protocol with real time elapsing. Chromium's
  `--screenshot` with `--virtual-time-budget` does not advance CSS animation time, which
  leaves the sparkline stroke stuck at `stroke-dashoffset: 1` and silently publishes a
  chart with no line.
- Keep `README.md` (English) and `README.zh-CN.md` (Chinese) in sync when behaviour changes.
