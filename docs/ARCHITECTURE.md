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
       3. run CodeBurn Claude and Codex reports in parallel
       4. optionally run ccusage blocks for Claude window metadata
       5. read the latest locally available Codex rate-limit snapshot
       6. atomically write data.js
       7. delete report.html and data.js after a short browser-read grace period

report.html polls data.js
  -> window.__DATA__
  -> provider rail, KPIs, charts, project/model/session tables
```

## Data contract

`data.js` contains:

- `providers.claude` and `providers.codex`: CodeBurn JSON reports
- `limits.claudeBlocks`: optional ccusage block data
- `limits.codex`: latest rate-limit metadata when the configured provider exposes it
- `generatedAt`, `period`, `currency`, and source version metadata

The default period is 30 days. Cost is always labelled as an API reference-price estimate because subscription and custom-provider billing can differ.

## Design boundaries

- Source session stores are read-only.
- Aggregation runs locally and does not call a project backend.
- The browser receives a single static snapshot; there is no server-side application state.
- `data.js` is written through a temporary name and atomic move to prevent partial reads.
- The normal launcher preserves burn-after-read behavior. `-KeepFile` is for debugging only.
- Codex rate-limit fields may be absent with custom providers; the UI displays an explicit unavailable state.

## Repository and installation

Canonical source lives in `src/`. `install.ps1` copies those files to `%LOCALAPPDATA%\ClaudeUsage` and creates the desktop shortcut. Running the generator directly from `src/` is supported because it resolves `template.html` relative to `$PSScriptRoot`.

When the repository itself is checked out at `%LOCALAPPDATA%\ClaudeUsage`, root-level runtime copies are ignored by Git. The uninstall script detects `.git` and removes only those runtime copies, preserving the repository.

## Compatibility identifiers

The product name is `AI Usage`. The `%LOCALAPPDATA%\ClaudeUsage` and `%TEMP%\ClaudeUsage` directories, the `Generate-ClaudeReport.ps1` filename, the `ai-usage-ledger-theme` browser preference key, and the `ccusage-dashboard` repository slug are retained compatibility identifiers. Renaming them requires an explicit migration covering existing installs, shortcuts, uninstall behavior, saved user settings, and documentation links. The installer removes the previous `Claude用量仪表盘`, `Claude Usage Dashboard`, and `AI Usage Ledger` shortcuts before creating the current shortcut.

## Verification

- Parse `src/Generate-ClaudeReport.ps1` with the PowerShell AST parser.
- Generate a real snapshot with `-NoLaunch -KeepFile`.
- Parse `data.js` and verify both provider reports.
- Render at desktop and mobile widths; check console errors and horizontal overflow.
- Confirm all cost copy says API reference estimate rather than actual billing.
