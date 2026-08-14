param(
  [string]$OutputDirectory,
  [string]$CurrencyCode = 'USD',
  [double]$CurrencyRate = 1.0,
  [string]$CurrencySymbol,
  [DateTimeOffset]$AsOf = [DateTimeOffset]::Now
)
$ErrorActionPreference = 'Stop'

# Quota meters count down against the reader's clock, so a snapshot pinned to a fixed
# past date renders every window as "about to reset" and the screenshots lose the one
# thing the meters are for. Everything time-shaped is anchored to $AsOf instead; pass
# -AsOf to pin a run. The aggregate figures stay fixed and synthetic either way.
function At([double]$Hours) { return $AsOf.AddHours($Hours).ToString('o') }
function OnDay([int]$Days) { return $AsOf.AddDays($Days).ToString('yyyy-MM-dd') }

$CurrencyCode = $CurrencyCode.ToUpperInvariant()
if ($CurrencyRate -le 0) { throw 'CurrencyRate must be positive.' }
if ([string]::IsNullOrWhiteSpace($CurrencySymbol)) { $CurrencySymbol = if ($CurrencyCode -eq 'USD') { '$' } else { $CurrencyCode } }

$root = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $OutputDirectory = Join-Path $env:TEMP 'AIUsageDemo'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

Copy-Item (Join-Path $root 'src\template.html') (Join-Path $OutputDirectory 'report.html') -Force
foreach ($font in @('ark-pixel-12px-monospaced-zh_cn.woff2', 'fusion-pixel-12px-monospaced-zh_hans.woff2')) {
  Copy-Item (Join-Path $root "src\fonts\$font") (Join-Path $OutputDirectory $font) -Force
}

function New-DailyRows([int]$Days, [double]$Total, [int]$Seed) {
  $end = $AsOf.Date
  $weights = @()
  for ($index = 0; $index -lt $Days; $index++) {
    $wave = 1.2 + [Math]::Sin(($index + $Seed) * 0.63) + [Math]::Cos(($index + $Seed) * 0.27) * 0.55
    $weights += [Math]::Max(0.08, $wave + (($index * $Seed) % 5) * 0.18)
  }
  $weightSum = ($weights | Measure-Object -Sum).Sum
  $rows = @()
  $running = 0.0
  for ($index = 0; $index -lt $Days; $index++) {
    $cost = if ($index -eq $Days - 1) { $Total - $running } else { [Math]::Round($Total * $weights[$index] / $weightSum, 6) }
    $running += $cost
    $calls = 40 + (($index * 17 + $Seed * 11) % 130)
    $rows += [pscustomobject][ordered]@{
      date = $end.AddDays($index - $Days + 1).ToString('yyyy-MM-dd')
      cost = $cost
      savings = [Math]::Round($cost * 0.08, 6)
      calls = $calls
      turns = [Math]::Max(1, [Math]::Round($calls / 3))
      editTurns = [Math]::Max(1, [Math]::Round($calls / 7))
      oneShotTurns = [Math]::Max(1, [Math]::Round($calls / 10))
      oneShotRate = 70 + (($index + $Seed) % 25)
    }
  }
  return $rows
}

function New-ModelRows([string]$Provider, [double]$Total, [int]$Calls, [int64]$TokenScale) {
  $specs = if ($Provider -eq 'claude') {
    @(@('Fable 5', 0.42), @('Opus 4.8', 0.31), @('Opus 5', 0.20), @('Sonnet 5', 0.07))
  } else {
    @(@('gpt-5.6-sol', 0.72), @('luna', 0.23), @('GPT-5.5', 0.05))
  }
  $rows = @()
  $running = 0.0
  for ($index = 0; $index -lt $specs.Count; $index++) {
    $cost = if ($index -eq $specs.Count - 1) { $Total - $running } else { [Math]::Round($Total * [double]$specs[$index][1], 6) }
    $running += $cost
    $share = [double]$specs[$index][1]
    $rows += [pscustomobject][ordered]@{
      name = [string]$specs[$index][0]
      calls = [Math]::Max(1, [Math]::Round($Calls * $share))
      cost = $cost
      savings = [Math]::Round($cost * 0.08, 6)
      estimatedCost = 0
      inputTokens = [int64]($TokenScale * $share * 0.08)
      outputTokens = [int64]($TokenScale * $share * 0.02)
      cacheReadTokens = [int64]($TokenScale * $share * 0.86)
      cacheWriteTokens = [int64]($TokenScale * $share * 0.04)
      kind = 'model'
      costSource = 'synthetic_demo'
      tokensPartial = $false
    }
  }
  return $rows
}

function New-ProjectRows([string]$Provider, [double]$Total, [int]$Calls, [int]$Sessions) {
  $names = if ($Provider -eq 'claude') { @('Signal Lab', 'Resume Studio', 'Usage Dashboard') } else { @('Resume Studio', 'Data Workbench', 'Usage Dashboard') }
  $shares = @(0.48, 0.31, 0.21)
  $rows = @()
  $running = 0.0
  for ($index = 0; $index -lt $names.Count; $index++) {
    $cost = if ($index -eq $names.Count - 1) { $Total - $running } else { [Math]::Round($Total * $shares[$index], 6) }
    $running += $cost
    $projectSessions = [Math]::Max(1, [Math]::Round($Sessions * $shares[$index]))
    $rows += [pscustomobject][ordered]@{
      name = $names[$index]
      path = "C:\Demo\$($names[$index] -replace ' ', '-')"
      cost = $cost
      savings = [Math]::Round($cost * 0.08, 6)
      avgCostPerSession = $cost / $projectSessions
      calls = [Math]::Max(1, [Math]::Round($Calls * $shares[$index]))
      sessions = $projectSessions
    }
  }
  return $rows
}

function New-DemoReport([string]$Provider, [string]$PeriodKey, [int]$Days, [double]$Total, [int]$Calls, [int]$Sessions, [int64]$TokenScale) {
  $models = @(New-ModelRows $Provider $Total $Calls $TokenScale)
  $projects = @(New-ProjectRows $Provider $Total $Calls $Sessions)
  $seed = if ($Provider -eq 'claude') { 3 } else { 7 }
  return [pscustomobject][ordered]@{
    currency = $CurrencyCode
    overview = [pscustomobject][ordered]@{
      cost = $Total
      proxiedCost = 0
      netCost = $Total
      savings = [Math]::Round($Total * 0.08, 6)
      estimatedCost = 0
      calls = $Calls
      sessions = $Sessions
      cacheHitPercent = if ($Provider -eq 'claude') { 97.8 } else { 94.6 }
      tokens = [pscustomobject][ordered]@{
        input = [int64]($TokenScale * 0.08)
        output = [int64]($TokenScale * 0.02)
        cacheRead = [int64]($TokenScale * 0.86)
        cacheWrite = [int64]($TokenScale * 0.04)
      }
    }
    daily = @(New-DailyRows $Days $Total $seed)
    models = $models
    projects = $projects
    topSessions = @(
      [pscustomobject][ordered]@{ sessionId = "demo-$Provider-01"; project = $projects[0].name; date = (OnDay -1); cost = [Math]::Round($Total * 0.13, 6); savings = 0; calls = [Math]::Round($Calls * 0.08) },
      [pscustomobject][ordered]@{ sessionId = "demo-$Provider-02"; project = $projects[1].name; date = (OnDay -4); cost = [Math]::Round($Total * 0.09, 6); savings = 0; calls = [Math]::Round($Calls * 0.06) }
    )
    costReconciliation = [pscustomobject][ordered]@{
      referenceCost = $Total
      statusCost = $Total
      modelSource = 'synthetic_demo'
      modelSourceCost = $Total
      unattributedCost = 0
      modelTokensPartial = $false
    }
  }
}

$periods = [ordered]@{
  week = [ordered]@{ days = 7; claude = 648.40; codex = 214.60; claudeCalls = 3280; codexCalls = 1840; claudeSessions = 186; codexSessions = 42; claudeTokens = 620000000; codexTokens = 280000000 }
  '30days' = [ordered]@{ days = 30; claude = 2846.00; codex = 934.00; claudeCalls = 12180; codexCalls = 6940; claudeSessions = 742; codexSessions = 126; claudeTokens = 2840000000; codexTokens = 1260000000 }
  all = [ordered]@{ days = 48; claude = 5120.00; codex = 1680.00; claudeCalls = 21940; codexCalls = 12420; claudeSessions = 1284; codexSessions = 224; claudeTokens = 5120000000; codexTokens = 2240000000 }
}

$reports = [ordered]@{}
foreach ($entry in $periods.GetEnumerator()) {
  $v = $entry.Value
  $reports[$entry.Key] = [ordered]@{
    claude = New-DemoReport 'claude' $entry.Key $v.days ($v.claude * $CurrencyRate) $v.claudeCalls $v.claudeSessions $v.claudeTokens
    codex = New-DemoReport 'codex' $entry.Key $v.days ($v.codex * $CurrencyRate) $v.codexCalls $v.codexSessions $v.codexTokens
  }
}

$payload = [ordered]@{
  generatedAt = $AsOf.ToString('o')
  period = '30days'
  currency = [ordered]@{ code = $CurrencyCode; rate = $CurrencyRate; symbol = $CurrencySymbol }
  pricingNote = 'Synthetic API reference price estimate.'
  source = [ordered]@{ name = 'CodeBurn'; version = '0.9.19' }
  periods = @('week', '30days', 'all')
  reports = $reports
  limits = [ordered]@{
    claudeQuota = [ordered]@{
      ok = $true
      fiveHour = [ordered]@{ utilization = 38; resetsAt = (At 2.75) }
      sevenDay = [ordered]@{ utilization = 64; resetsAt = (At 78) }
      limits = @(
        [ordered]@{ kind = 'session'; percent = 38; resetsAt = (At 2.75) },
        [ordered]@{ kind = 'weekly_all'; percent = 64; resetsAt = (At 78) },
        [ordered]@{ kind = 'weekly_scoped'; percent = 72; resetsAt = (At 78); model = 'Fable 5'; isActive = $true }
      )
    }
    claudeBlocks = [ordered]@{ blocks = @(
      [ordered]@{ startTime = (At -600); endTime = (At -595); actualEndTime = (At -595.9); costUSD = 18.4; isActive = $false; isGap = $false },
      [ordered]@{ startTime = (At -430); endTime = (At -425); actualEndTime = (At -425.3); costUSD = 24.1; isActive = $false; isGap = $false },
      [ordered]@{ startTime = (At -260); endTime = (At -255); actualEndTime = (At -255.6); costUSD = 31.8; isActive = $false; isGap = $false },
      [ordered]@{ startTime = (At -140); endTime = (At -135); actualEndTime = (At -135.5); costUSD = 26.6; isActive = $false; isGap = $false },
      [ordered]@{ startTime = (At -50); endTime = (At -45); actualEndTime = (At -45.2); costUSD = 38.2; isActive = $false; isGap = $false },
      [ordered]@{ startTime = (At -2.25); endTime = (At 2.75); actualEndTime = (At 0); costUSD = 12.5; isActive = $true; isGap = $false; burnRate = [ordered]@{ costPerHour = 2.4 }; projection = [ordered]@{ totalCost = 18.8 } }
    ) }
    codexQuota = [ordered]@{
      ok = $true
      reason = $null
      provider = 'Demo Relay'
      planName = 'Weekly 500 Plan'
      mode = 'unrestricted'
      isValid = $true
      unit = 'USD'
      remaining = 231.60
      expiresAt = (At 528)
      windows = @(
        [ordered]@{ kind = 'weekly'; limit = 500; used = 268.40; percent = 53.68; startsAt = (At -74); resetsAt = (At 94) },
        [ordered]@{ kind = 'daily'; limit = 0; used = 96.20; percent = $null; startsAt = $null; resetsAt = $null }
      )
    }
    codex = [ordered]@{
      primary = [ordered]@{ used_percent = 44; resets_at = (At 1.75) }
      secondary = [ordered]@{ used_percent = 18; resets_at = (At 156) }
    }
  }
  appDir = 'C:\Demo\AIUsage'
}

$json = $payload | ConvertTo-Json -Depth 100 -Compress
$encoding = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'data.js'), "window.__DATA__ = $json; if (window.__render__) window.__render__();", $encoding)
Write-Output (Join-Path $OutputDirectory 'report.html')
