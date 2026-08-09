Set-StrictMode -Version 2.0

function ConvertTo-FiniteDouble($Value) {
  if ($null -eq $Value) { return 0.0 }
  try {
    $number = [double]$Value
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return 0.0 }
    return $number
  } catch {
    return 0.0
  }
}

function Get-RecordNumber($Record, [string]$Name) {
  if (-not $Record -or $Record.PSObject.Properties.Name -notcontains $Name) { return 0.0 }
  return ConvertTo-FiniteDouble $Record.$Name
}

function Copy-Record($Record) {
  $copy = [ordered]@{}
  if ($Record) {
    foreach ($property in $Record.PSObject.Properties) {
      $copy[$property.Name] = $property.Value
    }
  }
  return $copy
}

function Get-ModelMatchKey([string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
  $key = $Name.Trim().ToLowerInvariant()
  $rawClaudeId = $key -match '^(?:claude|anthropic)[\s._-]+'
  $key = $key -replace '^(?:claude|anthropic)[\s._-]+', ''
  if ($rawClaudeId) { $key = $key -replace '[-._]\d{8}$', '' }
  return ($key -replace '[^a-z0-9]', '')
}

function Get-FallbackModelDisplayName([string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Name)) { return 'Unknown model' }
  $claude = [regex]::Match($Name, '^claude-(opus|sonnet|haiku|fable)-(\d+)(?:-(\d+))?(?:-\d{8})?$')
  if ($claude.Success) {
    $family = [Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($claude.Groups[1].Value)
    $version = $claude.Groups[2].Value
    if ($claude.Groups[3].Success) { $version += '.' + $claude.Groups[3].Value }
    return "$family $version"
  }
  if ($Name -match '^deepseek-(.+)$') {
    $suffix = ($Matches[1] -replace '-', ' ')
    return 'DeepSeek ' + [Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($suffix)
  }
  return $Name
}

function Get-ReferenceCost($Report) {
  if (-not $Report -or -not $Report.overview) { return 0.0 }
  if ($Report.overview.PSObject.Properties.Name -contains 'cost' -and $null -ne $Report.overview.cost) {
    return ConvertTo-FiniteDouble $Report.overview.cost
  }
  return Get-RecordNumber $Report.overview 'netCost'
}

function Get-StatusCurrencyRate($StatusCurrency, [string]$ReportCurrency) {
  $target = if ([string]::IsNullOrWhiteSpace($ReportCurrency)) { 'USD' } else { $ReportCurrency.ToUpperInvariant() }
  if (-not $StatusCurrency) { return $(if ($target -eq 'USD') { 1.0 } else { 0.0 }) }
  $source = if ($StatusCurrency.PSObject.Properties.Name -contains 'code') { [string]$StatusCurrency.code } else { '' }
  if ($source.ToUpperInvariant() -ne $target) { return 0.0 }
  $rate = Get-RecordNumber $StatusCurrency 'rate'
  if ($rate -le 0) { return 0.0 }
  return $rate
}

function Resolve-DisplayCurrency {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][object[]]$ReportCurrencies,
    [object[]]$StatusCurrencies = @()
  )

  $codes = @($ReportCurrencies | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).ToUpperInvariant() } | Select-Object -Unique)
  if ($codes.Count -ne 1) { throw 'CodeBurn reports did not agree on one display currency.' }
  $code = [string]$codes[0]
  $match = @($StatusCurrencies | Where-Object {
    $_ -and $_.PSObject.Properties.Name -contains 'code' -and ([string]$_.code).ToUpperInvariant() -eq $code -and (Get-RecordNumber $_ 'rate') -gt 0
  }) | Select-Object -First 1
  return [pscustomobject][ordered]@{
    code   = $code
    rate   = if ($match) { Get-RecordNumber $match 'rate' } elseif ($code -eq 'USD') { 1.0 } else { $null }
    symbol = if ($match -and $match.PSObject.Properties.Name -contains 'symbol') { [string]$match.symbol } elseif ($code -eq 'USD') { '$' } else { $code }
  }
}

function New-UnattributedModel([double]$Cost) {
  return [pscustomobject][ordered]@{
    name             = 'unattributed'
    calls            = 0
    cost             = $Cost
    savings          = 0
    estimatedCost    = 0
    inputTokens      = 0
    outputTokens     = 0
    cacheReadTokens  = 0
    cacheWriteTokens = 0
    kind             = 'unattributed'
    costSource       = 'reconciliation'
    tokensPartial    = $true
  }
}

function Apply-ModelCostResidual($Rows, [double]$Residual, [double]$Tolerance) {
  if ([Math]::Abs($Residual) -le 0.000000001) { return $true }
  if ($Residual -gt $Tolerance -or $Rows.Count -eq 0) {
    if ($Residual -lt 0) { return $false }
    $Rows.Add((New-UnattributedModel $Residual))
    return $true
  }

  $largestIndex = 0
  $largestCost = -1.0
  for ($index = 0; $index -lt $Rows.Count; $index++) {
    $candidate = Get-RecordNumber $Rows[$index] 'cost'
    if ($candidate -gt $largestCost) {
      $largestCost = $candidate
      $largestIndex = $index
    }
  }
  $adjusted = $largestCost + $Residual
  if ($adjusted -lt -0.000000001) { return $false }
  $Rows[$largestIndex].cost = [Math]::Max(0.0, $adjusted)
  return $true
}

function Get-UnattributedCost($Rows) {
  $total = 0.0
  foreach ($row in $Rows) {
    if ($row -and $row.kind -eq 'unattributed') { $total += Get-RecordNumber $row 'cost' }
  }
  return $total
}

function ConvertTo-LiveFallbackModels($Report, [double]$ReferenceCost, [double]$Tolerance) {
  $rows = New-Object Collections.Generic.List[object]
  $sum = 0.0
  foreach ($model in @($Report.models)) {
    if (-not $model) { continue }
    $row = Copy-Record $model
    $row['kind'] = 'model'
    $row['costSource'] = 'live_report'
    $row['tokensPartial'] = $false
    $copy = [pscustomobject]$row
    $rows.Add($copy)
    $sum += Get-RecordNumber $copy 'cost'
  }

  $gap = $ReferenceCost - $sum
  if ($gap -lt -$Tolerance) {
    $rows.Clear()
    if ($ReferenceCost -gt 0) { $rows.Add((New-UnattributedModel $ReferenceCost)) }
    return [pscustomobject][ordered]@{
      rows             = $rows.ToArray()
      source           = 'unattributed_fallback'
      sourceCost       = $sum
      unattributedCost = [Math]::Max(0.0, $ReferenceCost)
      tokensPartial    = $true
    }
  }
  if (-not (Apply-ModelCostResidual $rows $gap $Tolerance)) { throw 'Could not reconcile live model costs.' }
  $unattributed = Get-UnattributedCost $rows
  return [pscustomobject][ordered]@{
    rows             = $rows.ToArray()
    source           = 'live_report_fallback'
    sourceCost       = $sum
    unattributedCost = $unattributed
    tokensPartial    = ($unattributed -gt 0)
  }
}

function Merge-CodeBurnDurableModels {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]$Report,
    $StatusCurrent,
    $StatusCurrency,
    [double]$Tolerance = 0.005
  )

  if (-not $Report) { return $null }
  $referenceCost = Get-ReferenceCost $Report
  $liveByKey = @{}
  foreach ($model in @($Report.models)) {
    if (-not $model) { continue }
    $key = Get-ModelMatchKey ([string]$model.name)
    if ($key -and -not $liveByKey.ContainsKey($key)) { $liveByKey[$key] = $model }
  }

  $reportCurrency = if ($Report.PSObject.Properties.Name -contains 'currency') { [string]$Report.currency } else { 'USD' }
  $statusRate = Get-StatusCurrencyRate $StatusCurrency $reportCurrency
  $statusCost = (Get-RecordNumber $StatusCurrent 'cost') * $statusRate
  $result = $null
  $statusModels = @()
  if ($StatusCurrent -and $StatusCurrent.PSObject.Properties.Name -contains 'topModels') {
    $statusModels = @($StatusCurrent.topModels)
  }
  $useDurable = $statusRate -gt 0 -and $statusModels.Count -gt 0 -and $statusCost -le ($referenceCost + $Tolerance)

  if ($useDurable) {
    $rows = New-Object Collections.Generic.List[object]
    $durableSum = 0.0
    $anyPartialTokens = $false
    foreach ($model in $statusModels) {
      if (-not $model) { continue }
      $key = Get-ModelMatchKey ([string]$model.name)
      $live = if ($key -and $liveByKey.ContainsKey($key)) { $liveByKey[$key] } else { $null }
      $row = Copy-Record $live
      $durableCost = (Get-RecordNumber $model 'cost') * $statusRate
      $liveCost = Get-RecordNumber $live 'cost'
      $durableCalls = Get-RecordNumber $model 'calls'
      $liveCalls = Get-RecordNumber $live 'calls'
      $tokensPartial = (-not $live) -or ([Math]::Abs($durableCost - $liveCost) -gt $Tolerance) -or ($durableCalls -ne $liveCalls)
      $row['name'] = if ($live) { [string]$live.name } else { Get-FallbackModelDisplayName ([string]$model.name) }
      $row['calls'] = [int64]$durableCalls
      $row['cost'] = $durableCost
      $row['savings'] = (Get-RecordNumber $model 'savingsUSD') * $statusRate
      $row['estimatedCost'] = (Get-RecordNumber $model 'estimatedCostUSD') * $statusRate
      foreach ($tokenField in @('inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens')) {
        if (-not $row.Contains($tokenField)) { $row[$tokenField] = 0 }
      }
      $row['kind'] = 'model'
      $row['costSource'] = 'durable_status'
      $row['tokensPartial'] = $tokensPartial
      $copy = [pscustomobject]$row
      $rows.Add($copy)
      $durableSum += $durableCost
      $anyPartialTokens = $anyPartialTokens -or $tokensPartial
    }

    if ($durableSum -le ($referenceCost + $Tolerance)) {
      $gap = $referenceCost - $durableSum
      if (Apply-ModelCostResidual $rows $gap $Tolerance) {
        $unattributed = Get-UnattributedCost $rows
        $anyPartialTokens = $anyPartialTokens -or ($unattributed -gt 0)
        $result = [pscustomobject][ordered]@{
          rows             = $rows.ToArray()
          source           = 'durable_status'
          sourceCost       = $durableSum
          unattributedCost = $unattributed
          tokensPartial    = $anyPartialTokens
        }
      }
    }
  }

  if (-not $result) {
    $result = ConvertTo-LiveFallbackModels $Report $referenceCost $Tolerance
  }

  $Report.models = @($result.rows)
  Add-Member -InputObject $Report -NotePropertyName 'costReconciliation' -NotePropertyValue ([pscustomobject][ordered]@{
    referenceCost      = $referenceCost
    statusCost         = $statusCost
    modelSource        = $result.source
    modelSourceCost    = $result.sourceCost
    unattributedCost   = $result.unattributedCost
    modelTokensPartial = $result.tokensPartial
  }) -Force
  return $Report
}

Export-ModuleMember -Function Merge-CodeBurnDurableModels, Resolve-DisplayCurrency
