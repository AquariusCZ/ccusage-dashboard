# AI Usage

## Purpose

This personal Windows utility creates a local, disposable Claude Code and OpenAI Codex usage dashboard without uploading session content or credentials.

## Stack

- Windows PowerShell / PowerShell launcher and data assembly
- Local HTML, bundled pixel webfonts, CSS, and vanilla JavaScript dashboard
- CodeBurn for normalized Claude/Codex usage and API reference-price estimates
- ccusage for the active window's burn rate, projection, and hour-of-day profile
- Claude's OAuth usage endpoint for the real plan quota

## Commands

- Generate a debug snapshot: `powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\src\Generate-ClaudeReport.ps1 -NoLaunch -KeepFile`
- Run deterministic data tests: `powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\ReportData.Tests.ps1`
- Run static checks: `powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Static.Tests.ps1`
- Verify a retained snapshot: `powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Verify-Snapshot.ps1 -DataPath <debug-dir>\data.js`
- Generate the screenshot-safe demo: `powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\New-DemoSnapshot.ps1 -OutputDirectory <demo-dir>`
- Install locally: `powershell -ExecutionPolicy Bypass -File .\install.ps1`
- Open the installed app: `wscript.exe "$env:LOCALAPPDATA\ClaudeUsage\dashboard.vbs"`

## Rules

- `CLAUDE.md` is the only project rule source. Do not add `AGENTS.md` or duplicate rule files.
- Treat Claude and Codex session stores, and the CC Switch database, as read-only inputs.
- Keep runtime and test PowerShell files pure ASCII. Windows PowerShell reads a BOM-less
  script in the system ANSI code page, so a non-ASCII literal reaches the snapshot as
  mojibake. All visible copy belongs in `template.html`, which is served as UTF-8.
- Never display or commit prompt text, tool arguments, API keys, provider URLs, or authorization headers.
- Label all cost as an API reference-price estimate, not actual subscription or provider billing.
- Keep canonical runtime files in `src/`; root-level copies are an ignored installed mirror.
- Preserve the legacy `ClaudeUsage` runtime paths, `Generate-ClaudeReport.ps1` filename, and `ai-usage-ledger-theme` browser preference key unless a migration also covers install, upgrade, uninstall, and user-setting compatibility.
- Preserve burn-after-read for normal launches and keep `-KeepFile` limited to debugging.
- Use Chinese UI copy and verify desktop/mobile layout, focus visibility, dark mode, and reduced motion.
- Keep visible copy focused on data, state, and actions. Put collection mechanics, field names,
  and reconciliation details in documentation rather than dashboard captions.

## Quota, network, and concurrency

- The app makes exactly two authenticated network requests, both quota reads against a
  provider the user already configured: Claude's OAuth usage endpoint, and the Codex
  relay usage call replayed from CC Switch. Keep every credential read-only, out of the
  payload, out of logs, and out of exception text. Any failure degrades with a stated
  reason; it never throws and never blanks the dashboard. A third authenticated
  destination is a change to the product's premise, not an implementation detail.
- Codex quota on a relay provider comes from CC Switch's `usage_script`, read read-only
  from `.cc-switch\cc-switch.db` through the Windows-supplied `winsqlite3.dll`. Reuse the
  script's declared request only; never evaluate its JavaScript extractor, never replay a
  method other than GET or HEAD, never send an unresolved placeholder, and never parse CC
  Switch's private caches. Official Codex `rate_limits` stay the fallback source.
- Read a relay's subscription windows, not its per-key usage: one plan can back several
  keys, and only `subscription` counts the whole plan.
- CodeBurn may refresh its public LiteLLM price catalogue from GitHub when its local
  24-hour cache expires. Version `0.9.19` is the audited and required runtime; upgrades
  require re-auditing this boundary. It must never receive or upload credentials or
  rendered payloads.
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
- Run CodeBurn **one process at a time across launcher processes**. It is not
  concurrency-safe and overlapping runs silently mix providers' models and projects.
  See `docs/ARCHITECTURE.md`.
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
  state are personal data.
- Keep `README.md` (English) and `README.zh-CN.md` (Chinese) in sync when behaviour changes.
