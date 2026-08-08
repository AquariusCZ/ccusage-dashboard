# AI Usage

*[中文说明](README.zh-CN.md)*

A local, burn-after-read Windows dashboard for AI coding spend. It reads the session
metadata **Claude Code** and **OpenAI Codex** already keep on disk, shows your real
Claude plan quota, and deletes its own report when you close it.

![Desktop dashboard](docs/dashboard.png)

<p align="center"><img src="docs/mobile.png" width="360" alt="AI Usage on a narrow viewport"></p>

## What it shows

- **Real Claude quota**, not a guess: the 5-hour session window, the 7-day total, and any
  per-model limit, straight from your account. If a single limit hits 100% the dashboard
  says so in plain language, because a per-model limit can be exhausted while the totals
  still look healthy.
- **Claude and Codex side by side**, filterable to either one.
- **Three periods** you can switch between in the browser: last 7 days, last 30 days, all.
- Daily cost trend, an activity calendar with streak counts, an hour-of-day profile,
  model composition, and a project ranking.
- Light and dark, desktop and mobile.

Cost figures are an **API reference-price estimate**. Subscription plans, custom gateways,
enterprise agreements, and relay services all bill differently. The dashboard never claims
to show your invoice.

## Privacy

- Session stores are read-only inputs. Nothing is written back to them.
- Prompt text, tool arguments, API keys, provider URLs, and authorization headers are
  never rendered, never written to the snapshot, and never committed.
- `shellCommands` is deliberately dropped from the payload: it is the closest thing in
  the data to command content.
- The generated report and its data file are deleted after a short read window. Use
  `-KeepFile` only when debugging.

### The one network call

Quota comes from `GET https://api.anthropic.com/api/oauth/usage`, authenticated with the
OAuth token Claude Code already stores locally. It is the same call Claude Code makes,
with your own credential, to read your own quota. **No session content, prompt text, or
usage aggregate leaves the machine.** The token is read-only, never refreshed, never
written back, and never reaches the snapshot, a log, or an error message. If the call
fails or you are not logged in, the dashboard states the reason and still renders
everything else from local data.

## Data sources

- [CodeBurn](https://github.com/getagentseal/codeburn) normalizes Claude and Codex
  sessions and applies public API prices.
- [ccusage](https://github.com/ccusage/ccusage) supplies the active window's burn rate
  and projected spend, plus the hour-of-day profile.
- Claude's OAuth usage endpoint supplies the plan quota.

## Requirements

- Windows 10 or 11
- Node.js LTS
- CodeBurn and ccusage (the installer adds them if missing)

## Install

```powershell
git clone https://github.com/AquariusCZ/ccusage-dashboard.git
cd ccusage-dashboard
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Or double-click `install.bat`. The installer checks for Node.js, installs any missing
CLI dependency, copies `src/` to `%LOCALAPPDATA%\ClaudeUsage`, and creates an
`AI Usage` shortcut on the desktop.

The runtime directory, the `Generate-ClaudeReport.ps1` filename, and the
`ai-usage-ledger-theme` preference key are retained compatibility identifiers from an
earlier Claude-only version. They do not mean the app only counts Claude.

## Usage

Double-click **AI Usage** on the desktop.

To produce a snapshot without launching a browser:

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\src\Generate-ClaudeReport.ps1 -NoLaunch -KeepFile
```

Output lands in `%TEMP%\ClaudeUsage\report.html` and `data.js`.

| Path | Role |
|---|---|
| `src/Generate-ClaudeReport.ps1` | Collects usage and quota, writes the one-shot snapshot |
| `src/template.html` | Self-contained UI: charts, filters, light and dark |
| `src/dashboard.vbs` | Launcher with no console window |
| `install.ps1` | Dependencies, file copy, desktop shortcut |
| `docs/ARCHITECTURE.md` | Data flow, privacy boundary, and the traps worth knowing |

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

When the repository itself lives at `%LOCALAPPDATA%\ClaudeUsage`, the uninstaller removes
only the runtime copies. `.git`, `src/`, docs, and history are left alone.

## Notes for contributors

Two findings are documented in `docs/ARCHITECTURE.md` and are easy to regress:

1. **CodeBurn is not concurrency-safe.** Overlapping invocations leak rows between
   providers, so a `--provider codex` run can return both providers' models while its
   overview stays correctly scoped. The generator runs CodeBurn one process at a time.
2. **`limits[]` is authoritative for "am I blocked".** The two headline windows alone
   miss a per-model limit that is already exhausted.

Screenshots in `docs/` are rendered from synthetic demo data, never from a real session
store.

## License

[MIT](LICENSE)
