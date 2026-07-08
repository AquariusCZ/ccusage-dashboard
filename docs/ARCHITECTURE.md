# Architecture

## What it is

A zero-install, **ephemeral** usage dashboard: click a shortcut → the browser opens instantly with a loading animation → a beautiful HTML dashboard fades in a few seconds later → the temp files delete themselves. Nothing accumulates; nothing is uploaded.

## Flow

```
Desktop shortcut ─► dashboard.vbs (wscript, hidden)
                       └─► Generate-ClaudeReport.ps1
                              1. copy template.html ──► %TEMP%\ClaudeUsage\report.html
                              2. open browser NOW  (shows the loader)
                              3. run ccusage monthly/daily/session/blocks --json  (in PARALLEL)
                              4. write data.js  (atomic: tmp → move)
                              5. wait ~12s, then delete report.html + data.js   (burn-after-read)

report.html (shell)  ──polls──►  data.js   (when it appears, window.__render__() runs → dashboard fades in)
```

## Why this shape

- **Instant + animated.** The browser is opened *before* the slow work, showing a loader, so the ~5s of parallel `ccusage` calls feel responsive instead of a blank wait.
- **Shell + data split.** `template.html` is a static shell containing all the CSS/JS and a poller that repeatedly injects `data.js` via a `<script>` tag (a `fetch()` of a local file is CORS-blocked; a script tag is not). When `data.js` lands it sets `window.__DATA__` and calls the render function.
- **Burn-after-read.** Only ever one temp file set, in `%TEMP%`, deleted a few seconds after the browser has loaded it into memory. The page keeps rendering after the files are gone.

## Files

| File (`%LOCALAPPDATA%\ClaudeUsage`) | Role |
|---|---|
| `template.html` | the shell: loader animation + all dashboard CSS/JS + the `data.js` poller |
| `Generate-ClaudeReport.ps1` | gather data (parallel), inject, open browser, burn |
| `dashboard.vbs` | silent (no-console) launcher |
| `dashboard.bat` | fallback launcher (shows a console) |
| `icon.ico` | shortcut icon |

## Gotchas handled

- **Parallel data.** The four `ccusage … --json` calls run concurrently via `Start-Process -RedirectStandardOutput`, cutting cold-start time ~15s → ~5s.
- **Atomic data.js.** Written to a temp name then moved, so the poller never reads a half-written file.
- **Encoding.** `template.html` is UTF-8 with `<meta charset>`; the report is written UTF-8 (no BOM).
- **AV-safe launcher.** Uses a `wscript`-hidden `.vbs`, never the `.lnk → powershell -WindowStyle Hidden -ExecutionPolicy Bypass` pattern that some antivirus (e.g. Huorong/火绒) deletes.

## Data source

Everything derives from [`ccusage`](https://github.com/ryoppippi/ccusage)'s JSON: `monthly`/`daily`/`session` share a shape (`period`, token fields, `totalCost`, `modelBreakdowns`), and `blocks` gives the 5-hour billing windows (with the active window's reset time). All amounts are **API-equivalent** cost, not subscription billing.
