<#
  Generate-ClaudeReport.ps1
  1) drop the shell (loader) page and open the browser IMMEDIATELY
  2) run ccusage in PARALLEL, write data.js when ready
  3) the page polls data.js, then fades in the dashboard
  4) burn-after-read: remove the temp files afterwards (single fixed names -> no accumulation)

  Portable: reads its template/assets from its own folder ($PSScriptRoot),
  writes the transient report to %TEMP%\ClaudeUsage.
#>
param(
  [switch]$KeepFile,     # keep temp files (debug)
  [switch]$NoLaunch,     # do not open browser (headless test)
  [int]$DeleteAfter = 18 # seconds after data is ready before burning the files
)

$ErrorActionPreference = 'Stop'
$AppDir   = $PSScriptRoot
$Shell    = Join-Path $AppDir 'template.html'
$OutDir   = Join-Path $env:TEMP 'ClaudeUsage'
$OutHtml  = Join-Path $OutDir 'report.html'
$OutData  = Join-Path $OutDir 'data.js'

# resolve ccusage (prefer .cmd)
$CCUSAGE = $null
$c = Get-Command 'ccusage.cmd' -ErrorAction SilentlyContinue
if ($c) { $CCUSAGE = $c.Source } else {
  $c = Get-Command 'ccusage' -ErrorAction SilentlyContinue
  if ($c) { $CCUSAGE = $c.Source }
}
if (-not $CCUSAGE) { throw 'ccusage not found on PATH. Run:  npm install -g ccusage' }

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

# 1) place the shell page + clear any stale data.js so the page shows the loader
[System.IO.File]::Copy($Shell, $OutHtml, $true)
try { if (Test-Path $OutData) { [System.IO.File]::Delete($OutData) } } catch {}

# 2) open browser NOW (instant loader) before the slow work
if (-not $NoLaunch) { Start-Process $OutHtml | Out-Null }

# 3) run the four reports in parallel (each writes its stdout to a temp file)
$subs = @('monthly','daily','session','blocks')
$procs = @{}
foreach ($sub in $subs) {
  $of = Join-Path $OutDir "_$sub.json"
  try { if (Test-Path $of) { [System.IO.File]::Delete($of) } } catch {}
  $procs[$sub] = Start-Process -FilePath $CCUSAGE -ArgumentList $sub,'--json' `
                   -RedirectStandardOutput $of -WindowStyle Hidden -PassThru
}
foreach ($sub in $subs) { try { $procs[$sub].WaitForExit(90000) | Out-Null } catch {} }

function Read-Sub([string]$sub) {
  $of = Join-Path $OutDir "_$sub.json"
  try {
    $raw = ([System.IO.File]::ReadAllText($of)).Trim()
    if ($raw.StartsWith('{') -or $raw.StartsWith('[')) { return $raw }
  } catch {}
  return 'null'
}
$m = Read-Sub 'monthly'; $d = Read-Sub 'daily'; $s = Read-Sub 'session'; $b = Read-Sub 'blocks'
$ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$appEsc = $AppDir.Replace('\','\\')
$json = '{"monthly":' + $m + ',"daily":' + $d + ',"session":' + $s + ',"blocks":' + $b + ',"generatedAt":"' + $ts + '","appDir":"' + $appEsc + '"}'
try { $null = $json | ConvertFrom-Json } catch {
  $json = '{"monthly":null,"daily":null,"session":null,"blocks":null,"generatedAt":"' + $ts + '","appDir":"' + $appEsc + '"}'
}

# 4) write data.js atomically (tmp -> move) so the poller never reads a half-written file
$enc = New-Object System.Text.UTF8Encoding($false)
$tmp = $OutData + '.tmp'
[System.IO.File]::WriteAllText($tmp, ('window.__DATA__ = ' + $json + '; if(window.__render__)window.__render__();'), $enc)
try { if (Test-Path $OutData) { [System.IO.File]::Delete($OutData) } } catch {}
[System.IO.File]::Move($tmp, $OutData)

# cleanup the per-report temp files
foreach ($sub in $subs) { try { [System.IO.File]::Delete((Join-Path $OutDir "_$sub.json")) } catch {} }

if ($NoLaunch) { Write-Output $OutHtml; return }

# 5) burn after reading (page already loaded data.js into memory)
if (-not $KeepFile) {
  Start-Sleep -Seconds $DeleteAfter
  try { [System.IO.File]::Delete($OutData) } catch {}
  try { [System.IO.File]::Delete($OutHtml) } catch {}
}
