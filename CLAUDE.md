# AI Usage

## Purpose

This personal Windows utility creates a local, disposable Claude Code and OpenAI Codex usage dashboard without uploading session content or credentials.

## Stack

- Windows PowerShell / PowerShell launcher and data assembly
- Self-contained HTML, CSS, and vanilla JavaScript dashboard
- CodeBurn for normalized Claude/Codex usage and API reference-price estimates
- ccusage only for optional Claude active-window metadata

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
