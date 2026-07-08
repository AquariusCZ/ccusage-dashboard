<#
  Generate-ClaudeReport.ps1
  1) drop the shell (loader) page and open the browser IMMEDIATELY
  2) run ccusage in PARALLEL, write data.js when ready
  3) the page polls data.js, then fades in the dashboard
  4) burn-after-read: remove the temp files afterwards (single fixed names -> no accumulation)
#>
param(
  [switch]$KeepFile,     # keep temp files (debug)
  [switch]$NoLaunch,     # do not open browser (headless test)
  [int]$DeleteAfter = 18 # seconds after data is ready before burning the files
)

$ErrorActionPreference = 'Stop'
$AppDir   = Join-Path $env:LOCALAPPDATA 'ClaudeUsage'
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
if (-not $CCUSAGE) { throw 'ccusage not found on PATH' }

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

# rolling 5h session-reset estimate = (oldest message still within the last 5h) + 5h.
# Much closer to Claude's real session window than ccusage's gap-split block endTime.
$srJson = 'null'
try {
  $rootP = Join-Path $env:USERPROFILE '.claude\projects'
  if (Test-Path $rootP) {
    $nowU = [DateTimeOffset]::UtcNow; $cut = $nowU.AddHours(-11)
    $tl = New-Object System.Collections.Generic.List[DateTimeOffset]
    foreach ($jf in (Get-ChildItem $rootP -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -gt $cut.UtcDateTime })) {
      $raw2 = [System.IO.File]::ReadAllText($jf.FullName)
      foreach ($mm in [regex]::Matches($raw2, '"timestamp"\s*:\s*"([^"]+Z)"')) {
        try { $tt=[DateTimeOffset]::Parse($mm.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime(); if($tt -gt $cut -and $tt -le $nowU.AddMinutes(2)){ $tl.Add($tt) } } catch {}
      }
    }
    if ($tl.Count -gt 0) {
      $arr = $tl.ToArray(); [Array]::Sort($arr); $w5 = $nowU.AddHours(-5); $old = $null
      foreach ($tt in $arr) { if ($tt -gt $w5) { $old = $tt; break } }
      if ($old) { $rst = $old.AddHours(5); $secs = [int](($rst - $nowU).TotalSeconds); $srJson = '{"resetUtc":"' + $rst.ToString('o') + '","secondsUntilReset":' + $secs + ',"hasActivity":true}' }
      else { $srJson = '{"hasActivity":false}' }
    }
  }
} catch {}

$json = '{"monthly":' + $m + ',"daily":' + $d + ',"session":' + $s + ',"blocks":' + $b + ',"generatedAt":"' + $ts + '","appDir":"' + $appEsc + '","sessionReset":' + $srJson + '}'
try { $null = $json | ConvertFrom-Json } catch {
  $json = '{"monthly":null,"daily":null,"session":null,"blocks":null,"generatedAt":"' + $ts + '","appDir":"' + $appEsc + '","sessionReset":' + $srJson + '}'
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
