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

- The OAuth usage call is the app's only authenticated network request. Keep the token
  read-only, out of the payload, out of logs, and out of exception text. Any failure
  degrades with a stated reason; it never throws and never blanks the dashboard.
- CodeBurn may refresh its public LiteLLM price catalogue from GitHub when its local
  24-hour cache expires. Version `0.9.19` is the audited and required runtime; upgrades
  require re-auditing this boundary. It must never receive or upload credentials or
  rendered payloads.
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
  session store. Real project paths and account quota state are personal data.
- Keep `README.md` (English) and `README.zh-CN.md` (Chinese) in sync when behaviour changes.
