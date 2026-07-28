<#
  Build a local, disposable Claude + Codex usage snapshot.
  CodeBurn provides the normalized usage and API-equivalent price estimates.
#>
param(
  [ValidateSet('today', 'week', '30days', 'month', 'all', 'lifetime')]
  [string]$Period = '30days',
  [switch]$KeepFile,
  [switch]$NoLaunch,
  [int]$DeleteAfter = 18
)

$ErrorActionPreference = 'Stop'
$AppDir = $PSScriptRoot
$Template = Join-Path $AppDir 'template.html'
$OutDir = Join-Path $env:TEMP 'ClaudeUsage'
$OutHtml = Join-Path $OutDir 'report.html'
$OutData = Join-Path $OutDir 'data.js'

function Resolve-CommandPath([string[]]$Names) {
  foreach ($name in $Names) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
  }
  return $null
}

function Read-JsonFile([string]$Path) {
  try {
    $raw = [IO.File]::ReadAllText($Path).Trim()
    if ($raw.StartsWith('{') -or $raw.StartsWith('[')) {
      return $raw | ConvertFrom-Json
    }
  } catch {}
  return $null
}

function Read-LatestRateLimitFromFile([string]$Path) {
  try {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
      $size = [Math]::Min([int64]8388608, $stream.Length)
      $null = $stream.Seek(-$size, [IO.SeekOrigin]::End)
      $buffer = New-Object byte[] $size
      $read = $stream.Read($buffer, 0, $buffer.Length)
      $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
      $lines = $text -split "`r?`n"
      for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -notmatch '"rate_limits"') { continue }
        try {
          $entry = $lines[$i] | ConvertFrom-Json
          if ($entry.payload.rate_limits) { return $entry.payload.rate_limits }
        } catch {}
      }
    } finally {
      $stream.Dispose()
    }
  } catch {}
  return $null
}

function Get-LatestCodexRateLimit {
  $sessions = Join-Path $env:USERPROFILE '.codex\sessions'
  if (-not (Test-Path $sessions)) { return $null }
  $files = Get-ChildItem -LiteralPath $sessions -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 6
  foreach ($file in $files) {
    $limits = Read-LatestRateLimitFromFile $file.FullName
    if ($limits) { return $limits }
  }
  return $null
}

$CodeBurn = Resolve-CommandPath @('codeburn.cmd', 'codeburn')
if (-not $CodeBurn) {
  throw 'CodeBurn is not installed. Run: npm install -g codeburn'
}
$CCUsage = Resolve-CommandPath @('ccusage.cmd', 'ccusage')

if (-not (Test-Path $OutDir)) {
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

[IO.File]::Copy($Template, $OutHtml, $true)
try { if (Test-Path $OutData) { [IO.File]::Delete($OutData) } } catch {}

if (-not $NoLaunch) {
  Start-Process $OutHtml | Out-Null
}

$jobs = @{}
foreach ($provider in @('claude', 'codex')) {
  $output = Join-Path $OutDir "_$provider.json"
  try { if (Test-Path $output) { [IO.File]::Delete($output) } } catch {}
  $jobs[$provider] = Start-Process -FilePath $CodeBurn `
    -ArgumentList @('report', '--period', $Period, '--provider', $provider, '--format', 'json') `
    -RedirectStandardOutput $output -WindowStyle Hidden -PassThru
}

$blocksOutput = Join-Path $OutDir '_claude-blocks.json'
if ($CCUsage) {
  try { if (Test-Path $blocksOutput) { [IO.File]::Delete($blocksOutput) } } catch {}
  $jobs['claudeBlocks'] = Start-Process -FilePath $CCUsage `
    -ArgumentList @('blocks', '--json') `
    -RedirectStandardOutput $blocksOutput -WindowStyle Hidden -PassThru
}

foreach ($job in $jobs.Values) {
  try { $job.WaitForExit(120000) | Out-Null } catch {}
}

$claude = Read-JsonFile (Join-Path $OutDir '_claude.json')
$codex = Read-JsonFile (Join-Path $OutDir '_codex.json')
$claudeBlocks = if ($CCUsage) { Read-JsonFile $blocksOutput } else { $null }
$codexLimits = Get-LatestCodexRateLimit

$payload = [ordered]@{
  generatedAt = [DateTimeOffset]::Now.ToString('o')
  period = $Period
  currency = 'USD'
  pricingNote = 'API reference price estimate; subscription plans and custom providers may bill differently.'
  source = [ordered]@{
    name = 'CodeBurn'
    version = (& $CodeBurn '--version' 2>$null | Out-String).Trim()
  }
  providers = [ordered]@{
    claude = $claude
    codex = $codex
  }
  limits = [ordered]@{
    claudeBlocks = $claudeBlocks
    codex = $codexLimits
  }
  appDir = $AppDir
}

$json = $payload | ConvertTo-Json -Depth 100 -Compress
$encoding = New-Object Text.UTF8Encoding($false)
$temporaryData = "$OutData.tmp"
[IO.File]::WriteAllText(
  $temporaryData,
  "window.__DATA__ = $json; if (window.__render__) window.__render__();",
  $encoding
)
try { if (Test-Path $OutData) { [IO.File]::Delete($OutData) } } catch {}
[IO.File]::Move($temporaryData, $OutData)

foreach ($name in @('_claude.json', '_codex.json', '_claude-blocks.json')) {
  try { [IO.File]::Delete((Join-Path $OutDir $name)) } catch {}
}

if ($NoLaunch) {
  Write-Output $OutHtml
  return
}

if (-not $KeepFile) {
  Start-Sleep -Seconds $DeleteAfter
  try { [IO.File]::Delete($OutData) } catch {}
  try { [IO.File]::Delete($OutHtml) } catch {}
}
