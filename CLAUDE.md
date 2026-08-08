# AI Usage

## Purpose

This personal Windows utility creates a local, disposable Claude Code and OpenAI Codex usage dashboard without uploading session content or credentials.

## Stack

- Windows PowerShell / PowerShell launcher and data assembly
- Self-contained HTML, CSS, and vanilla JavaScript dashboard
- CodeBurn for normalized Claude/Codex usage and API reference-price estimates
- ccusage for the active window's burn rate, projection, and hour-of-day profile
- Claude's OAuth usage endpoint for the real plan quota

## Commands

- Generate a debug snapshot: `powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\src\Generate-ClaudeReport.ps1 -NoLaunch -KeepFile`
- Install locally: `powershell -ExecutionPolicy Bypass -File .\install.ps1`
- Open the installed app: `wscript.exe "$env:LOCALAPPDATA\ClaudeUsage\dashboard.vbs"`

## Rules

- `CLAUDE.md` is the only project rule source. Do not add `AGENTS.md` or duplicate rule files.
- Treat Claude and Codex session stores as read-only inputs.
- Never display or commit prompt text, tool arguments, API keys, provider URLs, or authorization headers.
- Label all cost as an API reference-price estimate, not actual subscription or provider billing.
- Keep canonical runtime files in `src/`; root-level copies are an ignored installed mirror.
- Preserve the legacy `ClaudeUsage` runtime paths, `Generate-ClaudeReport.ps1` filename, and `ai-usage-ledger-theme` browser preference key unless a migration also covers install, upgrade, uninstall, and user-setting compatibility.
- Preserve burn-after-read for normal launches and keep `-KeepFile` limited to debugging.
- Use Chinese UI copy and verify desktop/mobile layout, focus visibility, dark mode, and reduced motion.

## Quota, network, and concurrency

- The OAuth usage call is the only network request. Keep the token read-only, out of the
  payload, out of logs, and out of exception text. Any failure degrades with a stated
  reason; it never throws and never blanks the dashboard.
- Run CodeBurn **one process at a time**. It is not concurrency-safe and overlapping runs
  silently mix providers' models and projects. See `docs/ARCHITECTURE.md`.
- Treat `limits[]` as authoritative for "am I blocked", not just `five_hour` / `seven_day`.

## Type and visual rules

- Three faces, one job each: **pixel** bitmap for display figures only (hero total,
  provider totals, activity tile values), **mono** for anything tabular or inline-numeric,
  **sans** for all prose, labels, and every Chinese string.
- One radius scale, one accent per provider, one theme for the whole page.
- No scanline or stripe overlays. They were removed for legibility; do not reintroduce.
- Validate any new categorical or sequential palette with the dataviz validator rather
  than eyeballing it.

## Publishing

- Screenshots in `docs/` must be rendered from synthetic demo data, never from a real
  session store. Real project paths and account quota state are personal data.
- Keep `README.md` (English) and `README.zh-CN.md` (Chinese) in sync when behaviour changes.
