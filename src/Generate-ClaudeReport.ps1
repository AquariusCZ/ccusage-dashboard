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

<#
  Real Claude quota, from the same endpoint Claude Code itself uses.

  ccusage blocks only describe a rolling 5-hour *cost* window; they say nothing
  about how much of the plan is left, so a gauge built on them can only show
  elapsed time. The authoritative source is GET /api/oauth/usage.

  Red lines (mirrored from the AI Resume implementation, which learned them the
  hard way on 2026-08-08):
    1. the token is read-only - never refreshed, never written back;
    2. the token never reaches a log, an exception message, or the payload;
    3. under 60s of remaining life counts as expired - no request is made;
    4. any failure degrades to the ccusage window, and never throws;
    5. `limits[]` is authoritative for "am I actually blocked" - five_hour and
       seven_day alone miss it. Measured that day: weekly_all 93% read as fine
       while weekly_scoped was already 100% and requests were being refused.
#>
function Get-ClaudeOAuthUsage {
  # The endpoint rate-limits (observed 429 under repeated calls), and the app is
  # launched on demand, so a short cache keeps rapid relaunches from hammering it
  # and keeps the most important card populated when a call fails.
  $cachePath = Join-Path $OutDir 'quota-cache.json'
  $FreshSeconds = 120      # reuse without calling at all
  $StaleSeconds = 3600     # reuse, clearly labelled, only if the live call fails
  $cached = $null
  try {
    if (Test-Path $cachePath) {
      $raw = [IO.File]::ReadAllText($cachePath) | ConvertFrom-Json
      $age = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$raw.cachedAtUnix)
      if ($age -ge 0 -and $age -lt $StaleSeconds) { $cached = $raw }
      if ($cached -and $age -lt $FreshSeconds) {
        $hit = $cached.payload | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        Add-Member -InputObject $hit -NotePropertyName 'cachedAt' -NotePropertyValue $cached.cachedAt -Force
        return $hit
      }
    }
  } catch { $cached = $null }

  function Use-CachedQuota([string]$Reason) {
    if (-not $cached) { return [ordered]@{ ok = $false; reason = $Reason } }
    $hit = $cached.payload | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    Add-Member -InputObject $hit -NotePropertyName 'cachedAt' -NotePropertyValue $cached.cachedAt -Force
    Add-Member -InputObject $hit -NotePropertyName 'stale' -NotePropertyValue $true -Force
    Add-Member -InputObject $hit -NotePropertyName 'staleReason' -NotePropertyValue $Reason -Force
    return $hit
  }

  $credentials = Join-Path $env:USERPROFILE '.claude\.credentials.json'
  if (-not (Test-Path $credentials)) { return Use-CachedQuota 'no_credentials' }

  $token = $null
  try {
    $parsed = [IO.File]::ReadAllText($credentials) | ConvertFrom-Json
    $token = $parsed.claudeAiOauth.accessToken
    $expiresAt = $parsed.claudeAiOauth.expiresAt
  } catch {
    return Use-CachedQuota 'no_credentials'
  }
  if (-not $token) { return Use-CachedQuota 'no_credentials' }
  if ($expiresAt -and ($expiresAt - [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -lt 60000) {
    return Use-CachedQuota 'token_expired'
  }

  $response = $null
  try {
    $response = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' `
      -Headers @{ Authorization = "Bearer $token" } -Method Get -TimeoutSec 20
  } catch {
    # Deliberately does not surface the exception text: a failed request can echo
    # the Authorization header back in its message.
    $status = $null
    try { $status = [int]$_.Exception.Response.StatusCode } catch {}
    $reason = if ($status -in @(401, 403)) { "token_rejected_$status" }
              elseif ($status -eq 429) { 'rate_limited' }
              elseif ($status) { "http_$status" }
              else { 'failed_local' }
    return Use-CachedQuota $reason
  } finally {
    $token = $null
  }
  if (-not $response) { return Use-CachedQuota 'malformed_response' }

  function ConvertTo-Window($window) {
    if (-not $window) { return $null }
    return [ordered]@{
      utilization = $window.utilization
      resetsAt    = $window.resets_at
    }
  }

  $limits = @()
  foreach ($limit in @($response.limits)) {
    if (-not $limit) { continue }
    $model = $null
    try { $model = $limit.scope.model.display_name } catch {}
    $limits += [ordered]@{
      kind     = $limit.kind
      group    = $limit.group
      percent  = $limit.percent
      severity = $limit.severity
      resetsAt = $limit.resets_at
      isActive = $limit.is_active
      model    = $model
    }
  }

  $payload = [ordered]@{
    ok       = $true
    reason   = $null
    fiveHour = ConvertTo-Window $response.five_hour
    sevenDay = ConvertTo-Window $response.seven_day
    limits   = $limits
  }

  # Percentages and reset stamps only - no credential material reaches this file.
  try {
    [IO.File]::WriteAllText($cachePath, ([ordered]@{
      cachedAt     = [DateTimeOffset]::Now.ToString('o')
      cachedAtUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
      payload      = $payload
    } | ConvertTo-Json -Depth 20 -Compress), (New-Object Text.UTF8Encoding($false)))
  } catch {}

  return $payload
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

# CodeBurn aggregates models/projects/sessions per period, so a period the browser
# can switch to must be produced here - it cannot be re-derived from another period.
$PeriodKeys = @('week', '30days', 'all')
if ($PeriodKeys -notcontains $Period) { $PeriodKeys = @($Period) + $PeriodKeys }

# ccusage is a separate tool over the same read-only session files, so it may
# overlap with CodeBurn.
$blocksOutput = Join-Path $OutDir '_claude-blocks.json'
$blocksJob = $null
if ($CCUsage) {
  try { if (Test-Path $blocksOutput) { [IO.File]::Delete($blocksOutput) } } catch {}
  $blocksJob = Start-Process -FilePath $CCUsage `
    -ArgumentList @('blocks', '--json') `
    -RedirectStandardOutput $blocksOutput -WindowStyle Hidden -PassThru
}

# CodeBurn is NOT concurrency-safe: overlapping invocations leak each other's
# rows, so a `--provider codex` run can come back holding the union of both
# providers' models and projects while its overview stays correctly scoped.
# Verified 2026-08-08 - parallel gave codex/30days 10 models summing $7,585.72,
# sequential gave the correct 3 models summing $1,263.73. Keep these serial.
$scratch = @{}
foreach ($periodKey in $PeriodKeys) {
  foreach ($provider in @('claude', 'codex')) {
    $output = Join-Path $OutDir ("_{0}-{1}.json" -f $periodKey, $provider)
    $scratch["$periodKey/$provider"] = $output
    try { if (Test-Path $output) { [IO.File]::Delete($output) } } catch {}
    $run = Start-Process -FilePath $CodeBurn `
      -ArgumentList @('report', '--period', $periodKey, '--provider', $provider, '--format', 'json') `
      -RedirectStandardOutput $output -WindowStyle Hidden -PassThru
    try { $run.WaitForExit(120000) | Out-Null } catch {}
  }
}

if ($blocksJob) {
  try { $blocksJob.WaitForExit(120000) | Out-Null } catch {}
}

# Keep only the aggregates the dashboard renders. Notably drops shellCommands,
# which is both the bulkiest section and the closest thing to command content.
$KeepFields = @(
  'overview', 'daily', 'models', 'projects', 'topSessions',
  'activities', 'tools', 'mcpServers', 'skills', 'subagents', 'claudeAgentTypes'
)
function Select-ReportFields($Report) {
  if (-not $Report) { return $null }
  $slim = [ordered]@{}
  foreach ($field in $KeepFields) {
    if ($Report.PSObject.Properties.Name -contains $field) { $slim[$field] = $Report.$field }
  }
  return $slim
}

$reports = [ordered]@{}
foreach ($periodKey in $PeriodKeys) {
  $reports[$periodKey] = [ordered]@{
    claude = Select-ReportFields (Read-JsonFile $scratch["$periodKey/claude"])
    codex  = Select-ReportFields (Read-JsonFile $scratch["$periodKey/codex"])
  }
}

$claudeBlocks = if ($CCUsage) { Read-JsonFile $blocksOutput } else { $null }
$codexLimits = Get-LatestCodexRateLimit
$claudeQuota = Get-ClaudeOAuthUsage

$payload = [ordered]@{
  generatedAt = [DateTimeOffset]::Now.ToString('o')
  period = $Period
  currency = 'USD'
  pricingNote = 'API reference price estimate; subscription plans and custom providers may bill differently.'
  source = [ordered]@{
    name = 'CodeBurn'
    version = (& $CodeBurn '--version' 2>$null | Out-String).Trim()
  }
  periods = @($PeriodKeys)
  reports = $reports
  limits = [ordered]@{
    claudeQuota = $claudeQuota
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

foreach ($path in @($scratch.Values) + @($blocksOutput)) {
  try { [IO.File]::Delete($path) } catch {}
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
