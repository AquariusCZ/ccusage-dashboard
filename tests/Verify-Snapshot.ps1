param([Parameter(Mandatory = $true)][string]$DataPath)
$ErrorActionPreference = 'Stop'

$raw = [IO.File]::ReadAllText((Resolve-Path $DataPath))
$match = [regex]::Match($raw, '^window\.__DATA__\s*=\s*(.*);\s*if\s*\(', 'Singleline')
if (-not $match.Success) { throw 'data.js does not match the expected snapshot wrapper.' }
$data = $match.Groups[1].Value | ConvertFrom-Json
if (-not $data.currency -or -not $data.currency.code) { throw 'Snapshot currency metadata is missing.' }

foreach ($period in @($data.periods)) {
  foreach ($provider in @('claude', 'codex')) {
    $report = $data.reports.$period.$provider
    if (-not $report) { throw "Missing report: $period/$provider" }
    $reference = [double]$report.overview.cost
    $modelSum = [double](($report.models | Measure-Object -Property cost -Sum).Sum)
    if ([Math]::Abs($reference - $modelSum) -gt 0.01) {
      throw "Model cost does not conserve overview cost for $period/${provider}: overview=$reference models=$modelSum"
    }
    if (-not $report.costReconciliation) { throw "Missing cost reconciliation metadata for $period/$provider" }
  }

  $claudeNames = @($data.reports.$period.claude.models | Where-Object { $_.kind -ne 'unattributed' } | ForEach-Object name)
  $codexNames = @($data.reports.$period.codex.models | Where-Object { $_.kind -ne 'unattributed' } | ForEach-Object name)
  $overlap = @($claudeNames | Where-Object { $codexNames -contains $_ })
  if ($overlap.Count) { throw "Provider model overlap for ${period}: $($overlap -join ', ')" }
}

function Assert-NoSensitiveFields($Value, [string]$Path = '$') {
  if ($null -eq $Value) { return }
  if ($Value -is [string]) {
    if ($Value -match '(?i)\bBearer\s+[A-Za-z0-9._-]{12,}' -or $Value -match '(?i)sk-ant-[A-Za-z0-9_-]{8,}') {
      throw "Credential-like value found at $Path"
    }
    return
  }
  if ($Value -is [Collections.IEnumerable] -and $Value -isnot [Management.Automation.PSCustomObject]) {
    $index = 0
    foreach ($item in $Value) { Assert-NoSensitiveFields $item "$Path[$index]"; $index++ }
    return
  }
  foreach ($property in $Value.PSObject.Properties) {
    if ($property.Name -in @('accessToken', 'claudeAiOauth', 'shellCommands', 'authorization', 'toolArguments', 'prompt')) {
      throw "Sensitive field found at $Path.$($property.Name)"
    }
    Assert-NoSensitiveFields $property.Value "$Path.$($property.Name)"
  }
}
Assert-NoSensitiveFields $data

Write-Output "Verify-Snapshot.ps1: PASS ($($data.periods -join ', '))"
