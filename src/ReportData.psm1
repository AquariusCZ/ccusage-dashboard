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

function Assert-FiniteArithmeticResult([double]$Value, [string]$Operation) {
  if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) {
    throw "Non-finite arithmetic result while $Operation."
  }
  return $Value
}

function Test-FiniteNumberValue($Value, [bool]$AllowNegative = $true) {
  if ($null -eq $Value) { return $false }
  $numericType = [Type]::GetTypeCode($Value.GetType()) -in @(
    [TypeCode]::Byte, [TypeCode]::SByte, [TypeCode]::UInt16, [TypeCode]::UInt32,
    [TypeCode]::UInt64, [TypeCode]::Int16, [TypeCode]::Int32, [TypeCode]::Int64,
    [TypeCode]::Decimal, [TypeCode]::Double, [TypeCode]::Single
  )
  if (-not $numericType) { return $false }
  $number = [double]$Value
  if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $false }
  return $AllowNegative -or $number -ge 0
}

function Test-BoundedTextValue($Value, [int]$MaxLength, [bool]$AllowEmpty = $true) {
  if (-not ($Value -is [string]) -or $Value.Length -gt $MaxLength -or
      $Value -match '[\x00-\x1f\x7f]') { return $false }
  return $AllowEmpty -or -not [string]::IsNullOrWhiteSpace($Value)
}

# Strict mode cannot read `.PSObject.Properties.Name` on a record with no
# properties at all, which an empty JSON object parses to, so the members are
# walked instead of projected.
function Test-RecordProperty($Record, [string]$Name) {
  if (-not $Record) { return $false }
  foreach ($property in $Record.PSObject.Properties) {
    if ($property.Name -eq $Name) { return $true }
  }
  return $false
}

function Get-RecordNumber($Record, [string]$Name) {
  if (-not (Test-RecordProperty $Record $Name)) { return 0.0 }
  return ConvertTo-FiniteDouble $Record.$Name
}

function Get-RecordValue($Record, [string]$Name) {
  if (-not (Test-RecordProperty $Record $Name)) { return $null }
  return $Record.$Name
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
  $Cost = Assert-FiniteArithmeticResult $Cost 'building unattributed model cost'
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
  if (-not (Test-FiniteNumberValue $Residual) -or -not (Test-FiniteNumberValue $Tolerance $false)) {
    return $false
  }
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
  if (-not (Test-FiniteNumberValue $adjusted) -or $adjusted -lt -0.000000001) { return $false }
  $Rows[$largestIndex].cost = [Math]::Max(0.0, $adjusted)
  return $true
}

function Get-UnattributedCost($Rows) {
  $total = 0.0
  foreach ($row in $Rows) {
    if ($row -and $row.kind -eq 'unattributed') {
      $total = Assert-FiniteArithmeticResult ($total + (Get-RecordNumber $row 'cost')) 'summing unattributed model cost'
    }
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
    $candidateSum = $sum + (Get-RecordNumber $copy 'cost')
    if (-not (Test-FiniteNumberValue $candidateSum $false)) {
      $rows.Clear()
      if ($ReferenceCost -gt 0) { $rows.Add((New-UnattributedModel $ReferenceCost)) }
      return [pscustomobject][ordered]@{
        rows             = $rows.ToArray()
        source           = 'unattributed_fallback'
        sourceCost       = 0.0
        unattributedCost = [Math]::Max(0.0, $ReferenceCost)
        tokensPartial    = $true
      }
    }
    $sum = $candidateSum
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
  $statusCostValid = Test-FiniteNumberValue $statusCost $false
  if (-not $statusCostValid) { $statusCost = 0.0 }
  $result = $null
  $statusModels = @()
  if ($StatusCurrent -and $StatusCurrent.PSObject.Properties.Name -contains 'topModels') {
    $statusModels = @($StatusCurrent.topModels)
  }
  $useDurable = $statusCostValid -and $statusRate -gt 0 -and $statusModels.Count -gt 0 -and
    ($statusCost -le $referenceCost -or ($statusCost - $referenceCost) -le $Tolerance)

  if ($useDurable) {
    $rows = New-Object Collections.Generic.List[object]
    $durableSum = 0.0
    $durableValid = $true
    $anyPartialTokens = $false
    foreach ($model in $statusModels) {
      if (-not $model) { continue }
      $key = Get-ModelMatchKey ([string]$model.name)
      $live = if ($key -and $liveByKey.ContainsKey($key)) { $liveByKey[$key] } else { $null }
      $row = Copy-Record $live
      $durableCost = (Get-RecordNumber $model 'cost') * $statusRate
      $durableSavings = (Get-RecordNumber $model 'savingsUSD') * $statusRate
      $durableEstimatedCost = (Get-RecordNumber $model 'estimatedCostUSD') * $statusRate
      if (-not (Test-FiniteNumberValue $durableCost $false) -or
          -not (Test-FiniteNumberValue $durableSavings $false) -or
          -not (Test-FiniteNumberValue $durableEstimatedCost $false)) {
        $durableValid = $false
        break
      }
      $liveCost = Get-RecordNumber $live 'cost'
      $durableCalls = Get-RecordNumber $model 'calls'
      $liveCalls = Get-RecordNumber $live 'calls'
      $costDifference = $durableCost - $liveCost
      $tokensPartial = (-not $live) -or ([Math]::Abs($costDifference) -gt $Tolerance) -or ($durableCalls -ne $liveCalls)
      $row['name'] = if ($live) { [string]$live.name } else { Get-FallbackModelDisplayName ([string]$model.name) }
      $row['calls'] = [int64]$durableCalls
      $row['cost'] = $durableCost
      $row['savings'] = $durableSavings
      $row['estimatedCost'] = $durableEstimatedCost
      foreach ($tokenField in @('inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens')) {
        if (-not $row.Contains($tokenField)) { $row[$tokenField] = 0 }
      }
      $row['kind'] = 'model'
      $row['costSource'] = 'durable_status'
      $row['tokensPartial'] = $tokensPartial
      $copy = [pscustomobject]$row
      $rows.Add($copy)
      $candidateSum = $durableSum + $durableCost
      if (-not (Test-FiniteNumberValue $candidateSum $false)) {
        $durableValid = $false
        break
      }
      $durableSum = $candidateSum
      $anyPartialTokens = $anyPartialTokens -or $tokensPartial
    }

    if ($durableValid -and
        ($durableSum -le $referenceCost -or ($durableSum - $referenceCost) -le $Tolerance)) {
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

function Get-CodexBaseUrlFromToml([string]$Toml) {
  if ([string]::IsNullOrWhiteSpace($Toml)) { return '' }
  $lines = @([regex]::Split($Toml, '\r?\n'))
  $providerKey = ''
  $providerPattern = '^[\t ]*model_provider[\t ]*=[\t ]*(["''])([^"'']+)\1[\t ]*(?:#.*)?$'
  foreach ($line in $lines) {
    if ($line.TrimStart().StartsWith('#')) { continue }
    if ($line -match '^[\t ]*\[') { break }
    $match = [regex]::Match($line, $providerPattern)
    if ($match.Success) {
      if ($providerKey) { return '' }
      $providerKey = $match.Groups[2].Value
    } elseif ($line -match '^[\t ]*model_provider[\t ]*=') {
      return ''
    }
  }
  if ($providerKey -notmatch '\A[A-Za-z0-9_-]+\z') { return '' }

  $selectedSectionSeen = $false
  $inSelectedSection = $false
  $baseUrl = ''
  $sectionPattern = '^[\t ]*\[model_providers\.([A-Za-z0-9_-]+)\][\t ]*(?:#.*)?$'
  $basePattern = '^[\t ]*base_url[\t ]*=[\t ]*(["''])([^"'']+)\1[\t ]*(?:#.*)?$'
  foreach ($line in $lines) {
    if ($line.TrimStart().StartsWith('#')) { continue }
    if ($line -match '^[\t ]*\[') {
      $section = [regex]::Match($line, $sectionPattern)
      $inSelectedSection = $section.Success -and
        $section.Groups[1].Value.Equals($providerKey, [StringComparison]::Ordinal)
      if ($inSelectedSection) {
        if ($selectedSectionSeen) { return '' }
        $selectedSectionSeen = $true
      }
      continue
    }
    if (-not $inSelectedSection) { continue }
    $baseMatch = [regex]::Match($line, $basePattern)
    if ($baseMatch.Success) {
      if ($baseUrl) { return '' }
      $baseUrl = $baseMatch.Groups[2].Value
    } elseif ($line -match '^[\t ]*base_url[\t ]*=') {
      return ''
    }
  }
  return $baseUrl
}

<#
  Codex quota for third-party relays, rebuilt from CC Switch's own provider record.

  Upstream inventory, 2026-08-13: OpenAI's `rate_limits` only reach a session
  transcript when Codex talks to the official endpoint. A relay-backed provider
  never emits them, so `limits.codex` stays empty no matter how much quota is
  actually left. CC Switch already solved this: each provider may carry a
  `usage_script` in `providers.meta` that declares one GET and an extractor, and
  CC Switch polls it every `autoQueryInterval` minutes. Nothing about the result
  is persisted, so the request has to be replayed rather than read back.

  This reuses CC Switch's *declaration* - endpoint, method, headers, timeout -
  and does its own extraction, because the extractor is JavaScript and because
  the dashboard needs the whole subscription block, not just the balance CC
  Switch renders.

  Red lines, same as the Claude quota call:
    1. the API key is read-only, and never reaches the payload, a log, or an
       exception message;
    2. only GET and HEAD are replayed - a usage script that mutates is refused
       rather than trusted;
    3. the endpoint must be https, and every placeholder must resolve;
    4. any failure degrades with a stated reason and never throws.
#>
function Get-CodexUsageRequest {
  [CmdletBinding()]
  param(
    [string]$MetaJson,
    [string]$SettingsConfigJson
  )

  function Fail([string]$Reason) { return [pscustomobject][ordered]@{ ok = $false; reason = $Reason } }

  $script = $null
  try {
    if (-not [string]::IsNullOrWhiteSpace($MetaJson)) {
      $script = Get-RecordValue ($MetaJson | ConvertFrom-Json) 'usage_script'
    }
  } catch {
    return Fail 'usage_script_unreadable'
  }
  if (-not $script) { return Fail 'usage_script_missing' }
  if ((Get-RecordValue $script 'enabled') -ne $true) { return Fail 'usage_script_disabled' }

  $code = [string](Get-RecordValue $script 'code')
  if ([string]::IsNullOrWhiteSpace($code)) { return Fail 'usage_script_missing' }

  # Only the declarative request half is read. The extractor is JavaScript and is
  # deliberately not evaluated.
  $requestStart = $code.IndexOf('request')
  if ($requestStart -lt 0) { return Fail 'no_endpoint' }
  $requestEnd = $code.IndexOf('extractor', $requestStart)
  $requestBlock = if ($requestEnd -gt $requestStart) { $code.Substring($requestStart, $requestEnd - $requestStart) } else { $code.Substring($requestStart) }

  $urlMatch = [regex]::Match($requestBlock, 'url\s*:\s*["'']([^"'']+)["'']')
  if (-not $urlMatch.Success) { return Fail 'no_endpoint' }
  $url = $urlMatch.Groups[1].Value.Trim()

  $method = 'GET'
  $methodMatch = [regex]::Match($requestBlock, 'method\s*:\s*["'']([^"'']+)["'']')
  if ($methodMatch.Success) { $method = $methodMatch.Groups[1].Value.Trim().ToUpperInvariant() }
  if ($method -notin @('GET', 'HEAD')) { return Fail 'unsupported_method' }

  # Brace matching is not an option here: a `{{apiKey}}` placeholder closes with
  # the same character the header object does. Header names are the only quoted
  # keys in the block, so the pairs are read directly, minus the reserved names a
  # differently-written script might quote.
  $headers = @{}
  # Upstream CC Switch 3.20.1 templates use Authorization, User-Agent,
  # Content-Type, and New-Api-User. The remaining names are ordinary,
  # non-routing request metadata or common API-key forms.
  # An allowlist is deliberate: HttpClient accepts proxy and rewrite headers that
  # can move a same-origin credential beyond the provider selected by the user.
  $allowedHeaderNames = @(
    'Accept', 'Accept-Encoding', 'Accept-Language', 'Api-Key', 'Authorization',
    'Cache-Control', 'Content-Type', 'New-Api-User', 'Pragma', 'User-Agent', 'X-API-Key'
  )
  $headersStart = $requestBlock.IndexOf('headers')
  if ($headersStart -ge 0) {
    $headerBlock = $requestBlock.Substring($headersStart)
    foreach ($pair in [regex]::Matches($headerBlock, '["'']([^"'']+)["'']\s*:\s*["'']([^"'']*)["'']')) {
      $name = $pair.Groups[1].Value
      if ($name -in @('url', 'method', 'timeout')) { continue }
      $value = $pair.Groups[2].Value
      if ($allowedHeaderNames -inotcontains $name -or $value -match '[\x00-\x1F\x7F]') {
        return Fail 'unsupported_header'
      }
      $headers[$name] = $value
    }
  }

  $config = $null
  try {
    if (-not [string]::IsNullOrWhiteSpace($SettingsConfigJson)) { $config = $SettingsConfigJson | ConvertFrom-Json }
  } catch {
    return Fail 'provider_config_unreadable'
  }

  $apiKey = [string](Get-RecordValue (Get-RecordValue $config 'auth') 'OPENAI_API_KEY')
  $toml = [string](Get-RecordValue $config 'config')

  $baseUrl = Get-CodexBaseUrlFromToml $toml
  $baseUrl = $baseUrl.Trim().TrimEnd('/')

  $declaredUrl = $url
  if ($url.Contains('{{baseUrl}}') -and -not $baseUrl) { return Fail 'no_base_url' }
  if ($url.Contains('{{apiKey}}')) { return Fail 'credential_in_url' }
  $needsKey = (@($headers.Values) -join "`n").Contains('{{apiKey}}')
  if ($needsKey -and -not $apiKey) { return Fail 'no_api_key' }
  if ($needsKey -and -not $declaredUrl.Contains('{{baseUrl}}')) {
    return Fail 'credential_scope_mismatch'
  }

  function Expand-Placeholder([string]$Value) {
    return $Value.Replace('{{baseUrl}}', $baseUrl).Replace('{{apiKey}}', $apiKey)
  }

  $url = Expand-Placeholder $url
  $resolved = @{}
  foreach ($name in @($headers.Keys)) {
    $value = Expand-Placeholder ([string]$headers[$name])
    if ($value -match '[\x00-\x1F\x7F]') { return Fail 'unsupported_header' }
    $resolved[$name] = $value
  }
  # A relay WAF can answer 403 to a request with no User-Agent at all.
  if (-not ($resolved.Keys | Where-Object { $_ -ieq 'User-Agent' })) { $resolved['User-Agent'] = 'AI-Usage/1.0' }

  if ($url -match '\{\{[^}]*\}\}' -or (@($resolved.Values) -join "`n") -match '\{\{[^}]*\}\}') {
    return Fail 'unresolved_placeholder'
  }
  $endpointUri = $null
  if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$endpointUri) -or
      $endpointUri.Scheme -ine 'https') {
    return Fail 'insecure_endpoint'
  }
  if ($needsKey) {
    $providerUri = $null
    if (-not [Uri]::TryCreate($baseUrl, [UriKind]::Absolute, [ref]$providerUri) -or
        $providerUri.Scheme -ine 'https' -or
        -not $endpointUri.Scheme.Equals($providerUri.Scheme, [StringComparison]::OrdinalIgnoreCase) -or
        -not $endpointUri.DnsSafeHost.Equals($providerUri.DnsSafeHost, [StringComparison]::OrdinalIgnoreCase) -or
        $endpointUri.Port -ne $providerUri.Port) {
      return Fail 'credential_scope_mismatch'
    }
  }

  $timeout = 10
  $timeoutValue = Get-RecordValue $script 'timeout'
  if (Test-FiniteNumberValue $timeoutValue $false) {
    $timeoutCandidate = [double]$timeoutValue
    if ($timeoutCandidate -ge 1 -and $timeoutCandidate -le 60 -and
        [Math]::Floor($timeoutCandidate) -eq $timeoutCandidate) {
      $timeout = [int]$timeoutCandidate
    }
  }

  return [pscustomobject][ordered]@{
    ok             = $true
    reason         = $null
    url            = $url
    method         = $method
    headers        = $resolved
    timeoutSeconds = $timeout
  }
}

<#
  Turns a relay usage response into card state. Mirrors CC Switch's extractor
  fallbacks (`remaining ?? quota.remaining ?? balance`) and adds the subscription
  windows CC Switch collects but does not render.

  `weekly_window_start` is the only anchor a relay reports; the reset is derived
  as start + 7 days, which is what a rolling weekly allowance means. Windows with
  a zero limit are unlimited and produce a usage figure but no meter.
#>
function ConvertTo-CodexQuota {
  [CmdletBinding()]
  param(
    $Response,
    [string]$ProviderName
  )

  function Fail { return [pscustomobject][ordered]@{ ok = $false; reason = 'malformed_response' } }
  if (-not ($Response -is [pscustomobject])) { return Fail }
  if (-not [string]::IsNullOrWhiteSpace($ProviderName) -and
      -not (Test-BoundedTextValue $ProviderName 1024 $false)) { return Fail }

  $quota = Get-RecordValue $Response 'quota'
  if ($null -ne $quota -and -not ($quota -is [pscustomobject])) { return Fail }
  $remaining = Get-RecordValue $Response 'remaining'
  if ($null -eq $remaining) { $remaining = Get-RecordValue $quota 'remaining' }
  if ($null -eq $remaining) { $remaining = Get-RecordValue $Response 'balance' }
  if ($null -ne $remaining -and -not (Test-FiniteNumberValue $remaining)) { return Fail }

  $unit = Get-RecordValue $Response 'unit'
  if ($null -eq $unit) { $unit = Get-RecordValue $quota 'unit' }
  if ($null -eq $unit) { $unit = 'USD' }
  if (-not ($unit -is [string]) -or [string]::IsNullOrWhiteSpace($unit) -or
      $unit.Length -gt 16 -or $unit -match '[\x00-\x1f\x7f]') { return Fail }

  $isValid = Get-RecordValue $Response 'is_active'
  if ($null -eq $isValid) { $isValid = Get-RecordValue $Response 'isValid' }
  if ($null -eq $isValid) { $isValid = $true }
  if (-not ($isValid -is [bool])) { return Fail }

  $subscription = Get-RecordValue $Response 'subscription'
  if ($null -ne $subscription -and -not ($subscription -is [pscustomobject])) { return Fail }
  $windows = New-Object Collections.Generic.List[object]
  $hasQuotaState = $null -ne $remaining
  $specs = @(
    @{ kind = 'weekly'; limit = 'weekly_limit_usd'; used = 'weekly_usage_usd'; start = 'weekly_window_start'; days = 7 },
    @{ kind = 'daily'; limit = 'daily_limit_usd'; used = 'daily_usage_usd'; start = 'daily_window_start'; days = 1 },
    @{ kind = 'monthly'; limit = 'monthly_limit_usd'; used = 'monthly_usage_usd'; start = 'monthly_window_start'; days = 0 }
  )
  foreach ($spec in $specs) {
    if (-not (Test-RecordProperty $subscription $spec.used)) { continue }
    $usedValue = Get-RecordValue $subscription $spec.used
    if (-not (Test-FiniteNumberValue $usedValue $false)) { return Fail }
    $limitValue = Get-RecordValue $subscription $spec.limit
    if ($null -ne $limitValue -and -not (Test-FiniteNumberValue $limitValue $false)) { return Fail }
    $limit = if ($null -eq $limitValue) { 0.0 } else { [double]$limitValue }
    $used = [double]$usedValue
    $startsAt = Get-RecordValue $subscription $spec.start
    if ($null -ne $startsAt -and -not (Test-BoundedTextValue $startsAt 128)) { return Fail }
    if (-not [string]::IsNullOrWhiteSpace($startsAt)) {
      try { $startsAt = ([DateTimeOffset]::Parse($startsAt)).ToString('o') } catch { return Fail }
    } else {
      $startsAt = $null
    }
    $resetsAt = $null
    if ($startsAt -and $spec.days -gt 0) {
      try {
        $resetsAt = ([DateTimeOffset]::Parse($startsAt)).AddDays($spec.days).ToString('o')
      } catch {
        return Fail
      }
    }
    $windows.Add([pscustomobject][ordered]@{
      kind     = $spec.kind
      limit    = $limit
      used     = $used
      percent  = if ($limit -gt 0) { [Math]::Min(100.0, $used / $limit * 100.0) } else { $null }
      startsAt = if ($startsAt) { $startsAt } else { $null }
      resetsAt = $resetsAt
    })
    $hasQuotaState = $true
  }

  if (-not $hasQuotaState) { return Fail }
  $expiresAt = Get-RecordValue $subscription 'expires_at'
  if ($null -ne $expiresAt -and -not (Test-BoundedTextValue $expiresAt 128)) { return Fail }
  if (-not [string]::IsNullOrWhiteSpace($expiresAt)) {
    try { $expiresAt = ([DateTimeOffset]::Parse($expiresAt)).ToString('o') } catch { return Fail }
  } else {
    $expiresAt = $null
  }
  foreach ($textField in @('planName', 'mode')) {
    $textValue = Get-RecordValue $Response $textField
    $maxLength = if ($textField -eq 'mode') { 128 } else { 1024 }
    if ($null -ne $textValue -and -not (Test-BoundedTextValue $textValue $maxLength)) { return Fail }
  }

  return [pscustomobject][ordered]@{
    ok         = $true
    reason     = $null
    provider   = if ([string]::IsNullOrWhiteSpace($ProviderName)) { $null } else { $ProviderName }
    planName   = [string](Get-RecordValue $Response 'planName')
    mode       = [string](Get-RecordValue $Response 'mode')
    isValid    = $isValid
    unit       = $unit.ToUpperInvariant()
    remaining  = if ($null -eq $remaining) { $null } else { [double]$remaining }
    expiresAt  = if ($null -eq $expiresAt) { $null } else { $expiresAt }
    windows    = $windows.ToArray()
  }
}

# Reads one field from either a ConvertFrom-Json record or a JavaScriptSerializer
# dictionary. The leading comma keeps a JSON array an array instead of letting
# the pipeline unroll it.
function Get-AnyValue($Record, [string]$Name) {
  if ($null -eq $Record) { return $null }
  if ($Record -is [Collections.IDictionary]) {
    if (([Collections.IDictionary]$Record).Contains($Name)) { return ,$Record[$Name] }
    return $null
  }
  if ($Record -is [pscustomobject] -and (Test-RecordProperty $Record $Name)) { return ,$Record.$Name }
  return $null
}

function Test-AnyRecord($Value) {
  return $Value -is [Collections.IDictionary] -or $Value -is [pscustomobject]
}

function Test-AnyArray($Value) {
  return $Value -is [Collections.IList] -and -not ($Value -is [string])
}

function ConvertTo-IsoTimestamp($Value) {
  if (-not (Test-BoundedTextValue $Value 128 $false) -or
      $Value -notmatch '\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})\z') {
    return $null
  }
  $parsed = [DateTimeOffset]::MinValue
  if (-not [DateTimeOffset]::TryParse(
      $Value, [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return $null }
  return $parsed.ToString('o')
}

function ConvertFrom-UnixSecondsValue($Value) {
  if (-not (Test-FiniteNumberValue $Value $false)) { return $null }
  $number = [double]$Value
  if ($number -le 0 -or $number -gt 253402300799 -or [Math]::Floor($number) -ne $number) { return $null }
  return [DateTimeOffset]::FromUnixTimeSeconds([int64]$number).ToString('o')
}

function ConvertTo-QuotaPercent($Value) {
  if (-not (Test-FiniteNumberValue $Value $false)) { return $null }
  return [Math]::Min(100.0, [Math]::Max(0.0, [double]$Value))
}

<#
  One Claude usage document, wherever it was read from.

  The live OAuth endpoint and Claude Code's own `cachedUsageUtilization` copy of it
  share one shape: `five_hour`, `seven_day`, and the authoritative `limits[]`.
  Utilization above 100 is clamped so an overage still reads as exhausted instead
  of failing the whole card.
#>
function ConvertTo-ClaudeQuotaPayload {
  [CmdletBinding()]
  param($Usage)

  if (-not (Test-AnyRecord $Usage)) { return $null }
  foreach ($required in @('five_hour', 'seven_day', 'limits')) {
    if ($Usage -is [Collections.IDictionary]) {
      if (-not ([Collections.IDictionary]$Usage).Contains($required)) { return $null }
    } elseif (-not (Test-RecordProperty $Usage $required)) {
      return $null
    }
  }

  $windows = [ordered]@{}
  foreach ($pair in @(@('fiveHour', 'five_hour'), @('sevenDay', 'seven_day'))) {
    $window = Get-AnyValue $Usage $pair[1]
    if ($null -eq $window) { $windows[$pair[0]] = $null; continue }
    if (-not (Test-AnyRecord $window)) { return $null }
    $utilization = ConvertTo-QuotaPercent (Get-AnyValue $window 'utilization')
    if ($null -eq $utilization) { return $null }
    $resetsRaw = Get-AnyValue $window 'resets_at'
    $resetsAt = if ($null -eq $resetsRaw) { $null } else { ConvertTo-IsoTimestamp $resetsRaw }
    if ($null -ne $resetsRaw -and $null -eq $resetsAt) { return $null }
    $windows[$pair[0]] = [ordered]@{ utilization = $utilization; resetsAt = $resetsAt }
  }

  $rawLimits = Get-AnyValue $Usage 'limits'
  if (-not (Test-AnyArray $rawLimits)) { return $null }
  $limits = New-Object Collections.Generic.List[object]
  foreach ($limit in $rawLimits) {
    if (-not (Test-AnyRecord $limit)) { return $null }
    $kind = Get-AnyValue $limit 'kind'
    if (-not (Test-BoundedTextValue $kind 64 $false) -or $kind -cnotmatch '\A[a-z0-9_]+\z') { return $null }
    $percentRaw = Get-AnyValue $limit 'percent'
    $percent = if ($null -eq $percentRaw) { $null } else { ConvertTo-QuotaPercent $percentRaw }
    if ($null -ne $percentRaw -and $null -eq $percent) { return $null }
    $resetsRaw = Get-AnyValue $limit 'resets_at'
    $resetsAt = if ($null -eq $resetsRaw) { $null } else { ConvertTo-IsoTimestamp $resetsRaw }
    if ($null -ne $resetsRaw -and $null -eq $resetsAt) { return $null }
    $isActive = Get-AnyValue $limit 'is_active'
    if ($null -ne $isActive -and -not ($isActive -is [bool])) { return $null }
    $model = Get-AnyValue (Get-AnyValue (Get-AnyValue $limit 'scope') 'model') 'display_name'
    $row = [ordered]@{ kind = $kind }
    foreach ($text in @(@('group', (Get-AnyValue $limit 'group')), @('severity', (Get-AnyValue $limit 'severity')), @('model', $model))) {
      $value = $text[1]
      if ($null -ne $value -and -not (Test-BoundedTextValue $value 1024)) { return $null }
      $row[$text[0]] = $value
    }
    $row['percent'] = $percent
    $row['resetsAt'] = $resetsAt
    $row['isActive'] = $isActive
    $limits.Add([pscustomobject]$row)
  }

  return [pscustomobject][ordered]@{
    ok       = $true
    reason   = $null
    fiveHour = if ($windows.fiveHour) { [pscustomobject]$windows.fiveHour } else { $null }
    sevenDay = if ($windows.sevenDay) { [pscustomobject]$windows.sevenDay } else { $null }
    limits   = $limits.ToArray()
  }
}

<#
  Claude Code keeps its last usage response in ~/.claude.json as
  `cachedUsageUtilization = { fetchedAtMs, accountUuid, utilization }`. It is only
  trusted for the account Claude Code reports as signed in, and only while young
  enough that its weekly window can still be current.
#>
function ConvertTo-ClaudeCodeCachedQuota {
  [CmdletBinding()]
  param(
    $Cache,
    [string]$AccountUuid,
    [int64]$NowMilliseconds,
    [int64]$MaxAgeMilliseconds
  )

  if (-not (Test-AnyRecord $Cache) -or [string]::IsNullOrWhiteSpace($AccountUuid)) { return $null }
  $cachedAccount = Get-AnyValue $Cache 'accountUuid'
  if (-not ($cachedAccount -is [string]) -or $cachedAccount -cne $AccountUuid) { return $null }
  $fetchedAt = Get-AnyValue $Cache 'fetchedAtMs'
  if (-not (Test-FiniteNumberValue $fetchedAt $false)) { return $null }
  $observed = [int64][Math]::Floor([double]$fetchedAt)
  if ($observed -le 0 -or $observed -gt ($NowMilliseconds + 300000) -or
      ($NowMilliseconds - $observed) -gt $MaxAgeMilliseconds) { return $null }
  $payload = ConvertTo-ClaudeQuotaPayload (Get-AnyValue $Cache 'utilization')
  if (-not $payload) { return $null }
  return [pscustomobject][ordered]@{
    source = 'claude_code'
    observedAtMilliseconds = $observed
    payload = $payload
  }
}

<#
  The Claude desktop app samples plan usage into plan-usage-history.json as
  `{ t, org, u: { fh, sd } }`: five-hour and seven-day utilization, without reset
  times. Only samples for the signed-in organization are considered; with no known
  organization, a history that mixes organizations is rejected outright.
#>
function ConvertTo-ClaudeDesktopQuota {
  [CmdletBinding()]
  param(
    $History,
    [string]$OrganizationUuid,
    [int64]$NowMilliseconds,
    [int64]$MaxAgeMilliseconds,
    [ValidateRange(1, 100000)][int]$MaxSamples = 5000
  )

  $samples = Get-AnyValue $History 'samples'
  if (-not (Test-AnyArray $samples)) { return $null }
  $organizations = New-Object Collections.Generic.HashSet[string]
  $best = $null
  $bestTime = [int64]0
  # The app appends samples in time order, so a bounded tail holds every candidate
  # inside the age limit; an unbounded history cannot stall the collector slice.
  $first = [Math]::Max(0, $samples.Count - $MaxSamples)
  for ($index = $first; $index -lt $samples.Count; $index++) {
    $sample = $samples[$index]
    if (-not (Test-AnyRecord $sample)) { continue }
    $org = Get-AnyValue $sample 'org'
    if (-not (Test-BoundedTextValue $org 128 $false)) { continue }
    $time = Get-AnyValue $sample 't'
    if (-not (Test-FiniteNumberValue $time $false)) { continue }
    $observed = [int64][Math]::Floor([double]$time)
    if ($observed -le 0 -or $observed -gt ($NowMilliseconds + 300000) -or
        ($NowMilliseconds - $observed) -gt $MaxAgeMilliseconds) { continue }
    if (-not [string]::IsNullOrWhiteSpace($OrganizationUuid) -and $org -cne $OrganizationUuid) { continue }
    [void]$organizations.Add($org)
    if ($observed -gt $bestTime) {
      $best = $sample
      $bestTime = $observed
    }
  }
  if (-not $best -or $organizations.Count -ne 1) { return $null }

  $usage = Get-AnyValue $best 'u'
  if (-not (Test-AnyRecord $usage)) { return $null }
  $fiveHour = ConvertTo-QuotaPercent (Get-AnyValue $usage 'fh')
  $sevenDay = ConvertTo-QuotaPercent (Get-AnyValue $usage 'sd')
  if ($null -eq $fiveHour -and $null -eq $sevenDay) { return $null }
  return [pscustomobject][ordered]@{
    source = 'claude_desktop'
    observedAtMilliseconds = $bestTime
    payload = [pscustomobject][ordered]@{
      ok       = $true
      reason   = $null
      fiveHour = if ($null -eq $fiveHour) { $null } else { [pscustomobject][ordered]@{ utilization = $fiveHour; resetsAt = $null } }
      sevenDay = if ($null -eq $sevenDay) { $null } else { [pscustomobject][ordered]@{ utilization = $sevenDay; resetsAt = $null } }
      limits   = @()
    }
  }
}

function Select-NewestQuotaCandidate {
  [CmdletBinding()]
  param([object[]]$Candidates)

  $best = $null
  foreach ($candidate in @($Candidates)) {
    if (-not $candidate -or -not (Test-RecordProperty $candidate 'observedAtMilliseconds')) { continue }
    if (-not $best -or [int64]$candidate.observedAtMilliseconds -gt [int64]$best.observedAtMilliseconds) {
      $best = $candidate
    }
  }
  return $best
}

<#
  Codex login mode, from the `auth_mode` field Codex writes into auth.json. No other
  field is consulted, so no credential is ever read. A missing file, a missing field,
  or a value this app does not know is `unknown`, never a guess.
#>
function Get-CodexAuthModeFromDocument {
  [CmdletBinding()]
  param($Document)

  if (-not (Test-AnyRecord $Document)) { return 'unknown' }
  $mode = Get-AnyValue $Document 'auth_mode'
  if (-not ($mode -is [string])) { return 'unknown' }
  $normalized = $mode.Trim().ToLowerInvariant()
  if ($normalized.StartsWith('chatgpt')) { return 'chatgpt' }
  if ($normalized -in @('apikey', 'api_key')) { return 'apikey' }
  return 'unknown'
}

<#
  One official Codex rate-limit snapshot as the browser contract.

  Two upstream spellings reach here: `codex app-server`'s camelCase
  `account/rateLimits/read` result, and the snake_case `rate_limits` Codex writes
  into session transcripts. Both carry Unix-second resets. Only the `codex` bucket
  is the plan quota; other buckets (for example `base_model_inference`) are skipped
  by the caller.
#>
function ConvertTo-CodexOfficialQuota {
  [CmdletBinding()]
  param(
    $Snapshot,
    [ValidateSet('app_server', 'session')][string]$Source,
    [DateTimeOffset]$ObservedAt
  )

  if (-not (Test-AnyRecord $Snapshot)) { return $null }
  $limitId = Get-AnyValue $Snapshot 'limitId'
  if ($null -eq $limitId) { $limitId = Get-AnyValue $Snapshot 'limit_id' }
  if ($null -ne $limitId -and $limitId -cne 'codex') { return $null }

  $windows = [ordered]@{}
  foreach ($name in @('primary', 'secondary')) {
    $window = Get-AnyValue $Snapshot $name
    if ($null -eq $window) { $windows[$name] = $null; continue }
    if (-not (Test-AnyRecord $window)) { return $null }
    $usedRaw = Get-AnyValue $window 'usedPercent'
    if ($null -eq $usedRaw) { $usedRaw = Get-AnyValue $window 'used_percent' }
    $used = ConvertTo-QuotaPercent $usedRaw
    if ($null -eq $used) { return $null }
    $resetsRaw = Get-AnyValue $window 'resetsAt'
    if ($null -eq $resetsRaw) { $resetsRaw = Get-AnyValue $window 'resets_at' }
    $resetsAt = if ($null -eq $resetsRaw) { $null } else { ConvertFrom-UnixSecondsValue $resetsRaw }
    if ($null -ne $resetsRaw -and $null -eq $resetsAt) { return $null }
    $minutesRaw = Get-AnyValue $window 'windowDurationMins'
    if ($null -eq $minutesRaw) { $minutesRaw = Get-AnyValue $window 'window_minutes' }
    $minutes = $null
    if ($null -ne $minutesRaw) {
      if (-not (Test-FiniteNumberValue $minutesRaw $false) -or [double]$minutesRaw -le 0 -or
          [double]$minutesRaw -gt 5256000 -or [Math]::Floor([double]$minutesRaw) -ne [double]$minutesRaw) {
        return $null
      }
      $minutes = [int64]$minutesRaw
    }
    $windows[$name] = [pscustomobject][ordered]@{
      used_percent   = $used
      resets_at      = $resetsAt
      window_minutes = $minutes
    }
  }
  if (-not $windows.primary -and -not $windows.secondary) { return $null }

  $plan = Get-AnyValue $Snapshot 'planType'
  if ($null -eq $plan) { $plan = Get-AnyValue $Snapshot 'plan_type' }
  # Upstream plan types are lowercase snake case; normalize rather than reject the
  # whole snapshot over a casing difference.
  $plan = if ($plan -is [string] -and $plan -match '\A[A-Za-z0-9_]{1,64}\z') { $plan.ToLowerInvariant() } else { $null }

  return [pscustomobject][ordered]@{
    ok         = $true
    reason     = $null
    source     = $Source
    observedAt = $ObservedAt.ToString('o')
    planType   = $plan
    primary    = $windows.primary
    secondary  = $windows.secondary
  }
}

<#
  Newest plan-quota snapshot in one transcript tail. Newer Codex releases write
  several buckets per turn and the last line is often not the plan bucket, so
  lines are scanned from the end for `limit_id` `codex` (or a pre-bucket record
  without any `limit_id`).
#>
function Select-CodexSessionRateLimit {
  [CmdletBinding()]
  param([string[]]$Lines)

  for ($index = $Lines.Count - 1; $index -ge 0; $index--) {
    $line = $Lines[$index]
    if ([string]::IsNullOrEmpty($line) -or $line.IndexOf('"rate_limits"') -lt 0) { continue }
    try { $entry = $line | ConvertFrom-Json } catch { continue }
    $payload = Get-AnyValue $entry 'payload'
    $limits = Get-AnyValue $payload 'rate_limits'
    if (-not (Test-AnyRecord $limits)) { continue }
    $limitId = Get-AnyValue $limits 'limit_id'
    if ($null -ne $limitId -and $limitId -cne 'codex') { continue }
    $stamp = ConvertTo-IsoTimestamp (Get-AnyValue $entry 'timestamp')
    if (-not $stamp) { continue }
    return [pscustomobject][ordered]@{
      observedAt = [DateTimeOffset]::Parse($stamp, [Globalization.CultureInfo]::InvariantCulture)
      snapshot   = $limits
    }
  }
  return $null
}

Export-ModuleMember -Function Merge-CodeBurnDurableModels, Resolve-DisplayCurrency, Get-CodexUsageRequest, ConvertTo-CodexQuota,
  ConvertTo-ClaudeQuotaPayload, ConvertTo-ClaudeCodeCachedQuota, ConvertTo-ClaudeDesktopQuota, Select-NewestQuotaCandidate,
  Get-CodexAuthModeFromDocument, ConvertTo-CodexOfficialQuota, Select-CodexSessionRateLimit
