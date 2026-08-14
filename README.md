# AI Usage

[![Verify](https://github.com/AquariusCZ/ccusage-dashboard/actions/workflows/verify.yml/badge.svg)](https://github.com/AquariusCZ/ccusage-dashboard/actions/workflows/verify.yml)

*[中文说明](README.zh-CN.md)*

A local Windows dashboard for Claude Code and OpenAI Codex usage. It shows your real
Claude quota, compares both tools, and estimates cost from public API prices without
uploading session content.

Cost figures are for comparison and trend tracking. They are not subscription charges
or provider bills.

<table>
  <tr>
    <td width="72%"><img src="docs/dashboard.png" alt="AI Usage desktop dashboard"></td>
    <td width="28%"><img src="docs/mobile.png" alt="AI Usage mobile dashboard"></td>
  </tr>
</table>

## What it shows

- Real Claude 5-hour and 7-day quota windows, including per-model limits when available.
- Real Codex quota, from the official rate limits or from your relay's own subscription.
- Claude and Codex totals, shares, calls, sessions, tokens, and cache usage.
- Last 7 days, last 30 days, and full-history views.
- Daily trends, activity calendar, streaks, and Claude hour-of-day usage.
- Model composition, project ranking, high-usage sessions, and detailed tables.
- Light and dark themes, responsive layouts, keyboard navigation, and reduced motion.

Model costs always reconcile to the headline estimate. Any unresolved difference appears
as **unattributed cost**, and incomplete token totals are marked as lower bounds.

Codex quota has two sources. Official Codex publishes `rate_limits` into the local session
record. A relay provider does not, so AI Usage instead replays the quota call CC Switch
already defines for that provider, reading its balance, subscription window, and reset
from the relay itself. Switching
providers in CC Switch switches the card with it. Usage and cost views remain available
when neither source answers.

## Install

Requirements are Windows 10 or 11 and Node.js LTS. The command below also needs Git.
Without Git, download the repository ZIP, extract it, and run `install.bat`.

```powershell
git clone https://github.com/AquariusCZ/ccusage-dashboard.git
cd ccusage-dashboard
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

You can also double-click `install.bat`. The installer pins the audited CodeBurn and
ccusage versions, copies the runtime to `%LOCALAPPDATA%\ClaudeUsage`, and creates an
**AI Usage** desktop shortcut. Open that shortcut whenever you want a fresh snapshot.
CodeBurn and ccusage are installed as global npm packages and remain installed when
AI Usage is removed. The installer does not change your persistent PowerShell execution
policy.

## Privacy

- Claude Code and Codex session stores, and the CC Switch database, are read-only inputs.
- Prompt text, tool arguments, provider URLs, authorization headers, and credentials are
  excluded from the browser payload and logs.
- Normal launches keep temporary report files for a short read window, then delete them
  automatically.
- The retained quota caches contain quota state and timestamps, never a token or API key.

The runtime has four documented network paths. The Frankfurter request is inactive while
CodeBurn uses its default USD display currency, and the Codex relay request is inactive
unless CC Switch has a relay provider selected with its usage query enabled.

| Purpose | Destination | Data sent |
|---|---|---|
| Read the real Claude quota | Anthropic OAuth usage endpoint | Existing Claude Code OAuth token in the authorization header; no session content or usage aggregate |
| Read the real Codex quota | The relay endpoint CC Switch already queries | Existing Codex API key in the authorization header; no session content or usage aggregate |
| Refresh public model prices | GitHub raw content | Public catalogue request; no credential or usage data |
| Refresh a non-USD exchange rate | Frankfurter public API | Target ISO currency code only |

Both credentials remain read-only and never enter a snapshot, log, or error message, and
neither provider endpoint is written into the snapshot. Quota failures do not prevent the
local dashboard from rendering.

## How it works

1. The hidden launcher starts `Generate-ClaudeReport.ps1`.
2. CodeBurn and ccusage aggregate local Claude and Codex metadata.
3. The generator reconciles model costs, adds the real Claude and Codex quota, and writes
   a minimal temporary snapshot.
4. The browser opens the local dashboard; normal launches then remove the temporary files.

CodeBurn runs one process at a time because its report command is not concurrency-safe.
A per-user Windows mutex protects both calls within one report and separate dashboard
launches.

See [Architecture](docs/ARCHITECTURE.md) for the data flow, cost reconciliation, currency
handling, network boundary, and design decisions.

## Useful commands

Generate and retain a debug snapshot.

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\src\Generate-ClaudeReport.ps1 -NoLaunch -KeepFile
```

The command writes a separate `%TEMP%\ClaudeUsage\debug-<timestamp>-<pid>\` directory
and does not delete it automatically. The snapshot contains local aggregates and project
paths, so review it before sharing.

Run the local verification suite.

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\ReportData.Tests.ps1
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Static.Tests.ps1
```

Uninstall the local runtime and shortcut.

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

## Data sources

- [CodeBurn](https://github.com/getagentseal/codeburn) normalizes Claude and Codex usage
  and applies public API reference prices.
- [ccusage](https://github.com/ccusage/ccusage) supplies active-window burn data and the
  Claude hour-of-day profile.
- Anthropic's OAuth usage endpoint supplies the real Claude plan quota.
- CC Switch supplies the quota query for the Codex provider it currently has selected; its
  database is read read-only and never written.

Screenshots use synthetic data generated by `tests/New-DemoSnapshot.ps1`.

## License

[MIT](LICENSE)
