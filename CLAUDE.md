# AI Usage

## Purpose

This personal Windows utility creates a local, disposable Claude Code and OpenAI Codex usage dashboard without uploading session content or credentials.

## Stack

- Windows PowerShell / PowerShell launcher and data assembly
- Local HTML, bundled pixel webfonts, CSS, and vanilla JavaScript dashboard
- CodeBurn for normalized Claude/Codex usage and API reference-price estimates
- OpenCode's own SQLite store (`opencode.db`, read-only) for the DeepSeek API account's
  per-call cost and tokens, backed by a durable USD ledger, shown as a third provider when
  that store or its ledger exists
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
  24-hour cache expires. Version `0.9.27` is the audited and required runtime; `0.9.19` is
  still accepted because it publishes the same report and status contract, but it cannot be
  the default: its live model rows do not reconcile against its own headline (30 days on the
  author's machine: overview $5,434.65 against model rows totalling $6,561.45), so every
  period still pays for a durable status call. `0.9.27` reconciles them itself and reads its
  cache about twice as fast per invocation, which is why the version is worth pinning.
  Upgrading again requires re-auditing this boundary. It must never receive or upload
  credentials or rendered payloads.
- `0.9.27` replaces the session cache with a directory-backed store and rebuilds it once on
  the first run after the upgrade; that first launch is slow (about 20 s of collector time)
  and every later one is not. It also drops `avgCostPerSession` from project rows, so that
  field is optional in the snapshot contract, and it offers no `status` need on a report that
  already reconciles - the durable pass must therefore stay conditional, never presumed.
- The DeepSeek card is fed only by OpenCode's own per-call records. Current stores keep
  assistant messages in `session_message` joined to `session_v2`; the root-session
  expression groups child/subagent sessions under their parent, so the card counts
  top-level conversations. The legacy `message`/`session` pair is queried only when
  `sqlite3_prepare_v2` rejects the v2 shape (an older store); the two tables are never
  unioned because the same assistant message id appears in both, and the one legacy-only
  compaction row ($0.126) is intentionally not added. The store is opened read-only through
  the Windows-supplied `winsqlite3.dll`, no write, no network call, and never a read of
  OpenCode's credential or `auth.json`. Each assistant turn already carries its own `cost`
  and `tokens`, so that provider is labelled as API billing instead of a CodeBurn reference
  price. SQLite's `localtime` modifier returns NULL under `winsqlite3` when `TZ` is unset,
  so the local calendar day comes from the offset this process already knows.
- Deleted OpenCode sessions must not shrink DeepSeek history, so every run merges live rows
  into a durable USD ledger at `%LOCALAPPDATA%\AIUsage\deepseek-ledger.json` (versioned JSON;
  no key, prompt or response text; delete the file to clear the history). Live rows win the
  session|day|model key and ledger-only rows survive. Version 2 stores the one-time positive
  gap between retained snapshot daily totals and the rows at import in `recoveredDaily`; it
  is frozen there (later live usage cannot shrink it) and emitted as `deepseek-history` rows
  with cost and calls but no token detail. After a successful live read, rows whose session
  no longer exists are collapsed by date and model into anonymous `deleted` rows, so no
  deleted session id or project path is kept. The ledger records the live source shape (v2,
  legacyRoot or legacyFlat); when a later read reports a different shape, rows on dates the
  live data covers are dropped so child and root keys cannot double count. A failed or
  missing live read leaves the ledger untouched: no shape stamp, no recovery import and no
  anonymization. A corrupt,
  oversized or unsupported-version ledger is left untouched; only a missing or readable
  ledger is rewritten. DeepSeek's
  `GET /user/balance` is account-wide: a shared company account's balance cannot be split
  per API key, so OpenCode's provider records are the only attributable spend. A missing,
  unreadable, or DeepSeek-free store and ledger must leave the page exactly as it was with
  two providers: the snapshot's `providers[]` is what the UI renders, never a hard-coded pair.
  Until the first period is published, `providers[]` is the run's plan (DeepSeek is listed
  when the startup read found its rows); from then on it is what the published reports
  carry. A quota-only revision that dropped DeepSeek made the page remove its board and
  filter, then build both again on the first report. Known limitation: with a non-USD
  CodeBurn display currency DeepSeek's report is attached only once a status pass supplies
  the rate, so its filter can still appear after the reveal (its board no longer flickers).
- Resolve quota state once per state change, not once per publish. A snapshot reuses the
  limits it resolved until `QuotaStateVersion` moves; the relay answer bumps that counter
  and the collection-stopped flag is part of the cache key, because either one would
  otherwise leave a "loading" card on a finished run or hide a relay balance.
- Pin ccusage `20.0.20` and invoke `blocks --json` without `--offline`. It GETs the public
  LiteLLM catalogue from GitHub, and `models.dev/api.json` only for a model LiteLLM lacks,
  never with a credential or usage data; each request has its own 10-second timeout. Its
  embedded offline snapshot lacked `claude-opus-5-5` and priced current windows at $0, so
  offline mode is not used. A failed fetch silently falls back to that snapshot with exit code
  0, and an unknown model then adds nothing to a block's cost, so pass `totalTokens`: render an
  active window with tokens but zero cost as unpriced, never as $0.00. ccusage names no
  unpriced model in captured output, so a block with tokens and no cost marks the models it
  names as unpriced in that run (not `<...>` placeholders, nor a model that stands alone in a
  block with a cost); flag any other block with a cost naming one of them `costIncomplete`
  (never publish the model names) and render its amounts as lower bounds (`≥`). Every snapshot
  reruns the blocks selector on the stored DTO, so it must return its own output unchanged.
  Hide the hour profile when any block in range is unpriced or flagged. Hold the window row with
  placeholders until ccusage answers or the run ends, and redraw the usage sections when
  `claudeBlocks` arrives after the first usage revision. The final ccusage wait keeps receiving
  and publishing quota answers. ccusage honours `HTTP(S)_PROXY`/`ALL_PROXY`
  only, not the Windows system proxy. Give the optional process one absolute 120-second budget and 16 MiB
  output cap from launch; every CodeBurn wait slice must enforce them, and final collection may
  wait only the remaining budget.
- When the user has selected a non-USD CodeBurn display currency, CodeBurn may refresh
  its public Frankfurter exchange-rate cache. Convert durable status USD amounts with
  the reported rate before merging, and keep CodeBurn plus ccusage costs in one currency.
- The page's currency switch converts locally from one USD-based table published in the
  snapshot. The generator fetches `api.frankfurter.dev` once per 24 hours (unauthenticated,
  6 s budget, 64 KiB cap, cached under the runtime root) and degrades to USD-only when the
  fetch fails; the request carries no credential and no usage data, and the page never
  calls out. Amounts stay quoted in CodeBurn's configured currency in the report itself.
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
  the quota state counter rather than re-serializing every slice. Publish `plannedPeriods`
  (the full `$PeriodKeys` plan) from the first revision: before any report exists the
  switcher must show the run's plan greyed out rather than collapsing to a single button,
  and once data arrives it offers only the periods it can actually show. The switcher is
  patched in place, so a period simply brightens when its report lands. The page derives the
  same plan from its launch `?period=` before the first revision (the requested period, then
  `week`, `30days`, `all`), so keep that order in step with `$PeriodKeys`. After the first usage
  publish, later failures must terminate with a retained
  `generationError` snapshot rather than blanking an already usable dashboard. A failure
  before the first usage snapshot must atomically publish a terminal, credential-free
  `failure.js` sidecar so the page stops immediately instead of polling until its timeout.
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
- Publish `progress` with every revision: `done` out of `total` (3) counts real steps - the
  first snapshot ends startup (quota reads started, the local DeepSeek ledger read), then the
  default period's Claude report, then its Codex report - and `stage` names the step that is
  running. The page is its own first frame: there is no full-screen loader. That frame waits,
  at most 1.2 s, for the pixel fonts (both requested from the head, side by side; Fusion
  would otherwise wait for Ark) and the first data read - until then the canvas shows
  alone and nothing transitions - and then fades in once (110 ms). Inside that cap text never
  lands after its box and the period pill never slides to a re-measured width (fonts slower
  than the cap land on a page already showing, and it measures again); usage that is already
  readable is simply there instead of a wait card that leaves at once. The quota row
  shows first, and the usage area waits in the hero's slot with one perler-bead board per step
  (DeepSeek for startup, then Claude, then Codex; boards sit in the provider cards' order). A
  board completes only when `done` passes its step, and a readable default period completes
  all of them. Startup also punches every board's pegs row by row, so it shows progress on a
  setup without DeepSeek. Inside a running step beads land at a constant rate from the fixed,
  deliberately long `BEAD_STEPS` times (code constants, not browser history): 90% at the
  expected end, then slowing without ever stopping, so a normal run never stalls and a quick
  step jumps ahead. A finished step sweeps its remaining beads in 240 ms and is ironed (open
  rings close into the solid mark). The status line names the real step and adds "请稍候" once
  a step passes its expected time - it never claims what is usual, and never shows a step count
  or an estimated time. On a failure the board that was running says "中断". While usage waits,
  the status line is the page's one live region (`#stamp` is muted until the reveal). A script
  error reports itself but never blocks a reveal. Keep `BEAD_STEPS` in step with the
  generator's `ProgressTotal` and its `claude`, `codex` loop; `Static.Tests.ps1` checks both.
- Remember the reader's folds and views in `localStorage` under `ai-usage-ledger-prefs`: a
  provider card keeps its cost/token view, and a quota card is only rendered when its plan
  has a metered window (a Free plan has none, so the card is absent rather than empty).
  While the first quota read is pending, the previous run's answer decides, so the row does
  not appear and disappear on every launch. The same store keeps what the first frame needs
  before any snapshot: `lastProviders` (which boards and filter buttons to show; written only by
  a revision that carries a report, only ever gaining a provider until the final revision,
  which writes the exact list), `quotaShape`
  (each quota card's meter and stats labels plus the box it filled at that width and fold -
  layout sizes, never values) and `fxShown` (whether the currency switch holds its place). A
  placeholder or a loading quota card takes that remembered box and eases to its real height
  when the answer lands. A record shown while the live answer is on its way (`staleReason`
  `loading`) is labelled in the card's head (`刷新中`, its source and time) rather than in a
  row of its own, and like a loading card it holds the remembered box and is not remembered
  itself, so the card keeps the size it had last time; only a record that stays (no login, a
  failed read) gets its stale line. Such a refreshing record is not yet an answer for
  the Codex card either: the previous run's answer decides whether that card shows, because an
  old session's windows made a Free plan's card appear for a moment on every launch. Every
  `file://` page shares this store: sanitize it on load (nested maps that are not plain objects
  are dropped) and never put anything sensitive in it. Within a run the bead boards only ever
  gain a provider; the DeepSeek filter follows the boards until usage is shown and the
  snapshot after that, and a filter that is no longer offered falls back to all (pressed
  state, focus and URL included). A fold or view change is a transition, never a re-render
  jump, and `prefers-reduced-motion` collapses all of it.
- Treat `limits[]` as authoritative for "am I blocked", not just `five_hour` / `seven_day`.

## Type and visual rules

- Use the bundled 12px pixel stack for the whole interface: Ark Pixel Font `zh_cn`
  first, Fusion Pixel Font `zh_hans` as the broader-coverage fallback. Keep the hand-drawn
  5x7 bitmap figures for large totals and tile values.
- One radius scale, one accent per provider, one theme for the whole page.
- The root reserves the scrollbar's lane (`scrollbar-gutter: stable`): the page crosses the
  window's height while it loads, and a scrollbar that came and went shifted everything
  sideways. Measure horizontal overflow as `scrollWidth - offsetWidth`: `clientWidth` includes
  that empty lane on a short page and would hide a real overflow of up to 15 px.
- No scanline or stripe overlays. They were removed for legibility; do not reintroduce.
- Daily series use smooth, non-overshooting cubic curves. Motion must degrade through
  `prefers-reduced-motion` and must not be required to read any value.
- Validate any new categorical or sequential palette with the dataviz validator rather
  than eyeballing it.
- Provider marks are perler-bead mosaics: one `<circle r=".42">` per filled cell, no
  `shape-rendering`, `fill="currentColor"`. DeepSeek's whale is the official LobeHub path
  downsampled to a 16-cell grid, Claude is the blocky mascot and Codex the official mark at 16
  cells, and "all" stays at 12. The usage boards read each mark's grid from its symbol, and a
  board is never drawn below the same 2.5px bead pitch (48px on the phone strip). A 44px chip with a 40px glyph keeps the bead pitch at 2.5px, the
  smallest size where beads still read as beads; at 26px in the filter row they degrade to
  a dotted silhouette, which is the accepted trade for brand fidelity.
- Motion uses one token set taken from IBM Carbon's productive motion: standard
  `cubic-bezier(.2,0,.38,.9)`, entrance `cubic-bezier(0,0,.38,.9)`, and 70/110/150/240/400 ms
  for a bead landing, fades, small movement, expansion and the one-time data draw.
  Micro-interactions stay in Carbon's 90-120 ms band with ease-out on user input. State
  changes are transitions, not keyframes, so a second update retargets instead of restarting.
  No ad-hoc durations or easings; no overshoot, glare sweeps, confetti or soft shimmer. The
  only timing constants outside the scale are sequencing: `--stagger` (20 ms between items),
  `--stagger-fine` (12 ms between a meter's blocks, with the meter's count lasting as long as
  that sweep) and `--caret-blink` (the system caret rate); a discrete appearance is `steps(1)`,
  not a duration. The first frame's 1.2 s cap is a safety limit, not motion.
- The usage reveal is a same-document View Transition of exactly two kinds of element: the wait
  card becomes the hero card in place (`usage-slot`, clipped, old content out in 70 ms before
  the hero fades in) and, on a wide screen, each bead board flies into its provider card's
  chip when that chip is in view. The root is not captured, so the quota above stays live and
  clickable. On a phone the wait card is a strip docked to the bottom edge and leaves as one
  piece. Without View Transitions, with reduced motion, or in a background tab it is a plain
  swap with no hold. Readable usage is revealed even if the run fails while the boards are
  finishing. Every queued hand-over is bound to its run: a newer run or a report that is no
  longer readable cancels it. A revision that lands during the morph is drawn when it lands.
- Entrance motion belongs to the reveal only (`#app.intro`), and only with motion on - under
  reduced motion its 0.01 ms fade would still paint one empty frame: usage sections fade in 20 ms
  apart (`section-in`), bars grow from their baseline (`grow-x`), the trend line draws once
  (`draw-line`), markers follow it, and ranked rows cascade (`row-in`). The quota row is
  patched in place, never rebuilt (`applyQuota`): each row sits in a slot keyed by its meter
  label or its kind. A matching row morphs - its blocks fill or drain 12 ms apart in the
  direction the value moves while its figure counts on the standard curve, and changed text
  fades in - and a row that comes or goes opens or closes its slot (240 ms). What is under the
  row depends only on the row's own height, so `#quota` eases to its new height and clips while
  it does, and nothing under it jumps. A card that goes stays where it was, out of the row's
  flow, and fades; one that arrives fades in at its place; a card that stays slides and resizes
  to its new box. An answer that lands mid-way starts from wherever the last one got to. Closing rows and cards stay in the
  DOM until they are gone, marked `data-leaving`, `aria-hidden` and `inert`; read what the
  page shows with `:not([data-leaving])`. The intro
  class is removed only when no finite animation is still running - charts redraw on their
  first resize, so it looks again after each batch - with a 1.6 s cap, and a revision after the
  reveal ends the entrance before redrawing instead of restarting it. Updates change values
  through transitions instead, `renderQuota` skips an identical patch (compared with the last
  generated string; the DOM re-serializes `<use/>`), and the hero figure pulses only when the
  reader changes the period or the filter.

## Publishing

- Screenshots in `docs/` must be rendered from synthetic demo data, never from a real
  session store. Use `tests/New-DemoSnapshot.ps1`; real project paths and account quota
  state are personal data. Keep `dashboard.png` at 1280x1000 and `mobile.png` at 520x1200,
  and re-render both whenever a card visible in them changes (`AI_USAGE_DOCS_DIR=docs` with
  `node tests/BrowserSmoke.mjs`). `loading.gif` is the README's opening: a 1280x900 light
  desktop run of the demo with remembered preferences, screencast frames over real time and
  scaled to 720px; re-record it whenever the loading sequence changes.
- The demo anchors every timestamp to generation time, so quota meters always show a live
  countdown; pass `-AsOf` to pin a run. Fixed past dates render every window as "about to
  reset" and the meters stop showing anything.
- Start any scripted Edge with `--disable-sync --disable-extensions`. A fresh profile otherwise
  signs in to the Windows user's Edge account and syncs extensions; about 28 s in, one of them
  opened a welcome tab that sent the page under test to the background, which throttled its
  polling to once a second and stopped its animation frames.
- Capture screenshots through the DevTools Protocol with real time elapsing. Chromium's
  `--screenshot` with `--virtual-time-budget` does not advance CSS animation time, which
  leaves the sparkline stroke stuck at `stroke-dashoffset: 1` and silently publishes a
  chart with no line.
- Keep `README.md` (English) and `README.zh-CN.md` (Chinese) in sync when behaviour changes.
