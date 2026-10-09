# Validates a terminal (complete:true) snapshot. Quota-only and other incomplete
# revisions are transitional and are checked by the progressive-contract tests.
param([Parameter(Mandatory = $true)][string]$DataPath)
$ErrorActionPreference = 'Stop'

$raw = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $DataPath))
$match = [regex]::Match($raw, '^window\.__DATA__\s*=\s*(.*);\s*if\s*\(', 'Singleline')
if (-not $match.Success) { throw 'data.js does not match the expected snapshot wrapper.' }
$data = $match.Groups[1].Value | ConvertFrom-Json

function Test-Record($Value) {
  return $null -ne $Value -and $Value -is [pscustomobject]
}

function Test-JsonNumericType($Value) {
  if ($null -eq $Value) { return $false }
  return [Type]::GetTypeCode($Value.GetType()) -in @(
    [TypeCode]::Byte, [TypeCode]::SByte, [TypeCode]::UInt16, [TypeCode]::UInt32,
    [TypeCode]::UInt64, [TypeCode]::Int16, [TypeCode]::Int32, [TypeCode]::Int64,
    [TypeCode]::Decimal, [TypeCode]::Double, [TypeCode]::Single
  )
}

function Test-JsonFiniteNumber($Value, [bool]$AllowNegative = $false) {
  if (-not (Test-JsonNumericType $Value)) { return $false }
  $number = [double]$Value
  if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $false }
  return $AllowNegative -or $number -ge 0
}

function Test-JsonInt64($Value) {
  if (-not (Test-JsonFiniteNumber $Value)) { return $false }
  try {
    $number = [decimal]$Value
    return $number -le [decimal][int64]::MaxValue -and [decimal]::Truncate($number) -eq $number
  } catch {
    return $false
  }
}

function Test-BoundedString($Value, [int]$MaxLength = 32767, [bool]$AllowEmpty = $true) {
  if (-not ($Value -is [string]) -or $Value.Length -gt $MaxLength -or
      $Value -match '[\x00-\x1f\x7f]') { return $false }
  return $AllowEmpty -or -not [string]::IsNullOrWhiteSpace($Value)
}

function Test-IsoCalendarDate($Value) {
  if (-not ($Value -is [string])) { return $false }
  $parsed = [DateTime]::MinValue
  return [DateTime]::TryParseExact(
    $Value,
    'yyyy-MM-dd',
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::None,
    [ref]$parsed
  )
}

function Test-IsoTimestamp($Value) {
  if (-not (Test-BoundedString $Value 128 $false) -or
      $Value -notmatch '\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})\z') {
    return $false
  }
  $parsed = [DateTimeOffset]::MinValue
  return [DateTimeOffset]::TryParse(
    $Value,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind,
    [ref]$parsed
  )
}

function Test-Percent($Value) {
  return (Test-JsonFiniteNumber $Value) -and [double]$Value -le 100.0
}

function Test-ReasonCode($Value) {
  return $null -eq $Value -or ($Value -is [string] -and $Value.Length -le 128 -and $Value -cmatch '\A[a-z0-9_]+\z')
}

function Test-HasField($Record, [string]$Name) {
  if (-not (Test-Record $Record)) { return $false }
  return $null -ne $Record.PSObject.Properties[$Name]
}

function Assert-Fields($Value, [string]$Path, [string[]]$Required, [string[]]$Allowed) {
  if (-not (Test-Record $Value)) { throw "$Path is not a record." }
  $names = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
  foreach ($name in $Required) {
    if ($names -cnotcontains $name) { throw "$Path is missing $name." }
  }
  foreach ($name in $names) {
    if ($Allowed -cnotcontains $name) { throw "$Path contains non-contract field $name." }
  }
}

function Assert-RecordArray($Value, [string]$Path) {
  if (-not ($Value -is [Collections.IList]) -or $Value -is [string]) { throw "$Path is not an array." }
  foreach ($item in $Value) {
    if (-not (Test-Record $item)) { throw "$Path contains a non-record item." }
  }
}

function Assert-NonnegativeNumber($Value, [string]$Path) {
  if (-not (Test-JsonFiniteNumber $Value)) { throw "$Path is not a finite nonnegative JSON number." }
}

function Assert-Int64($Value, [string]$Path) {
  if (-not (Test-JsonInt64 $Value)) { throw "$Path is not a nonnegative Int64 JSON number." }
}

function Assert-String($Value, [string]$Path, [int]$MaxLength = 32767, [bool]$AllowEmpty = $true) {
  if (-not (Test-BoundedString $Value $MaxLength $AllowEmpty)) { throw "$Path is not a bounded scalar string." }
}

function Assert-NullableTimestamp($Value, [string]$Path) {
  if ($null -ne $Value -and -not (Test-IsoTimestamp $Value)) { throw "$Path is not null or an ISO timestamp." }
}

function Assert-Report($Report, [string]$Path) {
  Assert-Fields $Report $Path `
    @('currency', 'overview', 'daily', 'models', 'projects', 'topSessions', 'costReconciliation') `
    @('currency', 'overview', 'daily', 'models', 'projects', 'topSessions', 'costReconciliation')
  if (-not ($Report.currency -is [string]) -or $Report.currency -notmatch '\A[A-Za-z]{3}\z') {
    throw "$Path.currency is invalid."
  }

  $overviewPath = "$Path.overview"
  Assert-Fields $Report.overview $overviewPath `
    @('cost', 'netCost', 'savings', 'estimatedCost', 'calls', 'sessions', 'cacheHitPercent', 'tokens') `
    @('cost', 'netCost', 'savings', 'estimatedCost', 'calls', 'sessions', 'cacheHitPercent', 'tokens')
  foreach ($field in @('cost', 'netCost', 'savings', 'estimatedCost')) {
    Assert-NonnegativeNumber $Report.overview.$field "$overviewPath.$field"
  }
  foreach ($field in @('calls', 'sessions')) { Assert-Int64 $Report.overview.$field "$overviewPath.$field" }
  if (-not (Test-Percent $Report.overview.cacheHitPercent)) { throw "$overviewPath.cacheHitPercent is invalid." }
  Assert-Fields $Report.overview.tokens "$overviewPath.tokens" `
    @('input', 'output', 'cacheRead', 'cacheWrite') @('input', 'output', 'cacheRead', 'cacheWrite')
  foreach ($field in @('input', 'output', 'cacheRead', 'cacheWrite')) {
    Assert-Int64 $Report.overview.tokens.$field "$overviewPath.tokens.$field"
  }

  foreach ($arrayField in @('daily', 'models', 'projects', 'topSessions')) {
    Assert-RecordArray $Report.$arrayField "$Path.$arrayField"
  }
  $index = 0
  foreach ($row in $Report.daily) {
    $rowPath = "$Path.daily[$index]"
    Assert-Fields $row $rowPath `
      @('date', 'cost', 'savings', 'calls', 'turns', 'editTurns', 'oneShotTurns', 'oneShotRate') `
      @('date', 'cost', 'savings', 'calls', 'turns', 'editTurns', 'oneShotTurns', 'oneShotRate')
    if (-not (Test-IsoCalendarDate $row.date)) { throw "$rowPath.date is invalid." }
    foreach ($field in @('cost', 'savings')) { Assert-NonnegativeNumber $row.$field "$rowPath.$field" }
    foreach ($field in @('calls', 'turns', 'editTurns', 'oneShotTurns')) { Assert-Int64 $row.$field "$rowPath.$field" }
    if ($null -ne $row.oneShotRate -and -not (Test-Percent $row.oneShotRate)) { throw "$rowPath.oneShotRate is invalid." }
    $index += 1
  }

  $index = 0
  foreach ($row in $Report.models) {
    $rowPath = "$Path.models[$index]"
    Assert-Fields $row $rowPath `
      @('name', 'calls', 'inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens', 'cost', 'savings', 'estimatedCost', 'kind', 'costSource', 'tokensPartial') `
      @('name', 'calls', 'inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens', 'cost', 'savings', 'estimatedCost', 'kind', 'costSource', 'tokensPartial')
    foreach ($field in @('name', 'kind', 'costSource')) { Assert-String $row.$field "$rowPath.$field" 32767 $false }
    foreach ($field in @('calls', 'inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens')) {
      Assert-Int64 $row.$field "$rowPath.$field"
    }
    foreach ($field in @('cost', 'savings', 'estimatedCost')) { Assert-NonnegativeNumber $row.$field "$rowPath.$field" }
    if (-not ($row.tokensPartial -is [bool])) { throw "$rowPath.tokensPartial is not a boolean." }
    $index += 1
  }

  $index = 0
  foreach ($row in $Report.projects) {
    $rowPath = "$Path.projects[$index]"
    Assert-Fields $row $rowPath `
      @('name', 'path', 'cost', 'savings', 'avgCostPerSession', 'calls', 'sessions') `
      @('name', 'path', 'cost', 'savings', 'avgCostPerSession', 'calls', 'sessions')
    Assert-String $row.name "$rowPath.name" 32767 $false
    Assert-String $row.path "$rowPath.path" 32767 $false
    foreach ($field in @('cost', 'savings')) { Assert-NonnegativeNumber $row.$field "$rowPath.$field" }
    if ($null -ne $row.avgCostPerSession) { Assert-NonnegativeNumber $row.avgCostPerSession "$rowPath.avgCostPerSession" }
    foreach ($field in @('calls', 'sessions')) { Assert-Int64 $row.$field "$rowPath.$field" }
    $index += 1
  }

  $index = 0
  foreach ($row in $Report.topSessions) {
    $rowPath = "$Path.topSessions[$index]"
    Assert-Fields $row $rowPath `
      @('sessionId', 'project', 'date', 'cost', 'savings', 'calls') `
      @('sessionId', 'project', 'date', 'cost', 'savings', 'calls')
    Assert-String $row.sessionId "$rowPath.sessionId" 32767 $false
    Assert-String $row.project "$rowPath.project" 32767 $false
    if ($null -ne $row.date -and -not (Test-IsoCalendarDate $row.date)) { throw "$rowPath.date is invalid." }
    foreach ($field in @('cost', 'savings')) { Assert-NonnegativeNumber $row.$field "$rowPath.$field" }
    Assert-Int64 $row.calls "$rowPath.calls"
    $index += 1
  }

  $reconciliationPath = "$Path.costReconciliation"
  Assert-Fields $Report.costReconciliation $reconciliationPath `
    @('referenceCost', 'statusCost', 'modelSource', 'modelSourceCost', 'unattributedCost', 'modelTokensPartial') `
    @('referenceCost', 'statusCost', 'modelSource', 'modelSourceCost', 'unattributedCost', 'modelTokensPartial')
  foreach ($field in @('referenceCost', 'statusCost', 'modelSourceCost', 'unattributedCost')) {
    Assert-NonnegativeNumber $Report.costReconciliation.$field "$reconciliationPath.$field"
  }
  Assert-String $Report.costReconciliation.modelSource "$reconciliationPath.modelSource" 32767 $false
  if (-not ($Report.costReconciliation.modelTokensPartial -is [bool])) {
    throw "$reconciliationPath.modelTokensPartial is not a boolean."
  }
  if ([Math]::Abs([double]$Report.overview.cost - [double]$Report.costReconciliation.referenceCost) -gt 0.01) {
    throw "$Path reconciliation reference differs from overview cost."
  }
  $modelSum = [double](($Report.models | Measure-Object -Property cost -Sum).Sum)
  if ([Math]::Abs([double]$Report.overview.cost - $modelSum) -gt 0.01) {
    throw "$Path model cost does not conserve overview cost."
  }
}

function Assert-ClaudeQuota($Quota, [string]$Path) {
  Assert-Fields $Quota $Path @('ok') @(
    'ok', 'reason', 'cachedAt', 'stale', 'staleReason', 'source', 'fiveHour', 'sevenDay', 'limits'
  )
  if (-not ($Quota.ok -is [bool])) { throw "$Path.ok is not a boolean." }
  if ((Test-HasField $Quota 'source') -and
      $Quota.source -cnotin @('oauth', 'cache', 'claude_code', 'claude_desktop')) {
    throw "$Path.source is not a known Claude quota source."
  }
  foreach ($field in @('reason', 'staleReason')) {
    if ((Test-HasField $Quota $field) -and -not (Test-ReasonCode $Quota.$field)) { throw "$Path.$field is invalid." }
  }
  if ((Test-HasField $Quota 'cachedAt') -and -not (Test-IsoTimestamp $Quota.cachedAt)) { throw "$Path.cachedAt is invalid." }
  if ((Test-HasField $Quota 'stale') -and -not ($Quota.stale -is [bool])) { throw "$Path.stale is not a boolean." }
  if ($Quota.ok) {
    foreach ($field in @('reason', 'fiveHour', 'sevenDay', 'limits')) {
      if (-not (Test-HasField $Quota $field)) { throw "$Path is missing $field for a successful quota result." }
    }
    if ($null -ne $Quota.reason) { throw "$Path.reason must be null for a successful quota result." }
  } else {
    if (-not (Test-HasField $Quota 'reason') -or
        -not (Test-BoundedString $Quota.reason 128 $false) -or
        $Quota.reason -notmatch '\A[a-z0-9_]+\z') {
      throw "$Path.reason must be a non-empty reason code for a failed quota result."
    }
  }
  if ((Test-HasField $Quota 'stale') -and $Quota.stale) {
    if (-not $Quota.ok -or -not (Test-HasField $Quota 'cachedAt') -or
        -not (Test-HasField $Quota 'staleReason') -or $null -eq $Quota.staleReason) {
      throw "$Path stale quota result is incomplete."
    }
  } elseif (Test-HasField $Quota 'staleReason') {
    throw "$Path has staleReason without stale:true."
  }
  $recorded = (Test-HasField $Quota 'stale') -and $Quota.stale
  if (($recorded -and -not (Test-HasField $Quota 'source')) -or
      ((Test-HasField $Quota 'source') -and $Quota.source -cin @('claude_code', 'claude_desktop') -and -not $recorded)) {
    throw "$Path does not label a recorded quota with its source."
  }
  foreach ($windowName in @('fiveHour', 'sevenDay')) {
    if (-not (Test-HasField $Quota $windowName) -or $null -eq $Quota.$windowName) { continue }
    $windowPath = "$Path.$windowName"
    Assert-Fields $Quota.$windowName $windowPath @('utilization', 'resetsAt') @('utilization', 'resetsAt')
    if (-not (Test-Percent $Quota.$windowName.utilization)) { throw "$windowPath.utilization is invalid." }
    Assert-NullableTimestamp $Quota.$windowName.resetsAt "$windowPath.resetsAt"
  }
  if (Test-HasField $Quota 'limits') {
    Assert-RecordArray $Quota.limits "$Path.limits"
    $index = 0
    foreach ($limit in $Quota.limits) {
      $limitPath = "$Path.limits[$index]"
      Assert-Fields $limit $limitPath @('kind', 'percent') @('kind', 'group', 'percent', 'severity', 'resetsAt', 'isActive', 'model')
      Assert-String $limit.kind "$limitPath.kind" 64 $false
      if ($limit.kind -notmatch '\A[a-z0-9_]+\z') { throw "$limitPath.kind is invalid." }
      if ($null -ne $limit.percent -and -not (Test-Percent $limit.percent)) { throw "$limitPath.percent is invalid." }
      foreach ($field in @('group', 'severity', 'model')) {
        if ((Test-HasField $limit $field) -and $null -ne $limit.$field) { Assert-String $limit.$field "$limitPath.$field" 1024 }
      }
      if ((Test-HasField $limit 'resetsAt')) { Assert-NullableTimestamp $limit.resetsAt "$limitPath.resetsAt" }
      if ((Test-HasField $limit 'isActive') -and $null -ne $limit.isActive -and -not ($limit.isActive -is [bool])) {
        throw "$limitPath.isActive is invalid."
      }
      $index += 1
    }
  }
}

function Assert-CodexQuota($Quota, [string]$Path) {
  Assert-Fields $Quota $Path @('ok') @(
    'ok', 'reason', 'provider', 'planName', 'mode', 'unit', 'isValid', 'stale',
    'remaining', 'expiresAt', 'cachedAt', 'staleReason', 'windows'
  )
  if (-not ($Quota.ok -is [bool])) { throw "$Path.ok is not a boolean." }
  foreach ($field in @('reason', 'staleReason')) {
    if ((Test-HasField $Quota $field) -and -not (Test-ReasonCode $Quota.$field)) { throw "$Path.$field is invalid." }
  }
  foreach ($spec in @(
    @{ Name = 'provider'; Max = 1024 }, @{ Name = 'planName'; Max = 1024 },
    @{ Name = 'mode'; Max = 128 }, @{ Name = 'unit'; Max = 16 }
  )) {
    if ((Test-HasField $Quota $spec.Name) -and $null -ne $Quota.($spec.Name)) {
      Assert-String $Quota.($spec.Name) "$Path.$($spec.Name)" $spec.Max
    }
  }
  foreach ($field in @('isValid', 'stale')) {
    if ((Test-HasField $Quota $field) -and -not ($Quota.$field -is [bool])) { throw "$Path.$field is not a boolean." }
  }
  if ($Quota.ok) {
    foreach ($field in @(
      'reason', 'provider', 'planName', 'mode', 'isValid', 'unit',
      'remaining', 'expiresAt', 'windows'
    )) {
      if (-not (Test-HasField $Quota $field)) { throw "$Path is missing $field for a successful quota result." }
    }
    if ($null -ne $Quota.reason) { throw "$Path.reason must be null for a successful quota result." }
  } else {
    if (-not (Test-HasField $Quota 'reason') -or
        -not (Test-BoundedString $Quota.reason 128 $false) -or
        $Quota.reason -notmatch '\A[a-z0-9_]+\z') {
      throw "$Path.reason must be a non-empty reason code for a failed quota result."
    }
  }
  if ((Test-HasField $Quota 'stale') -and $Quota.stale) {
    if (-not $Quota.ok -or -not (Test-HasField $Quota 'cachedAt') -or
        -not (Test-HasField $Quota 'staleReason') -or $null -eq $Quota.staleReason) {
      throw "$Path stale quota result is incomplete."
    }
  } elseif (Test-HasField $Quota 'staleReason') {
    throw "$Path has staleReason without stale:true."
  }
  if ((Test-HasField $Quota 'remaining') -and $null -ne $Quota.remaining -and
      -not (Test-JsonFiniteNumber $Quota.remaining $true)) { throw "$Path.remaining is invalid." }
  foreach ($field in @('expiresAt', 'cachedAt')) {
    if ((Test-HasField $Quota $field)) { Assert-NullableTimestamp $Quota.$field "$Path.$field" }
  }
  if (Test-HasField $Quota 'windows') {
    Assert-RecordArray $Quota.windows "$Path.windows"
    $index = 0
    foreach ($window in $Quota.windows) {
      $windowPath = "$Path.windows[$index]"
      Assert-Fields $window $windowPath `
        @('kind', 'limit', 'used', 'percent', 'startsAt', 'resetsAt') `
        @('kind', 'limit', 'used', 'percent', 'startsAt', 'resetsAt')
      Assert-String $window.kind "$windowPath.kind" 16 $false
      if ($window.kind -notin @('weekly', 'daily', 'monthly')) { throw "$windowPath.kind is invalid." }
      foreach ($field in @('limit', 'used')) { Assert-NonnegativeNumber $window.$field "$windowPath.$field" }
      if ($null -ne $window.percent -and -not (Test-Percent $window.percent)) { throw "$windowPath.percent is invalid." }
      Assert-NullableTimestamp $window.startsAt "$windowPath.startsAt"
      Assert-NullableTimestamp $window.resetsAt "$windowPath.resetsAt"
      $index += 1
    }
  }
}

function Assert-CodexOfficial($Quota, [string]$Path) {
  Assert-Fields $Quota $Path @('ok') @(
    'ok', 'reason', 'source', 'observedAt', 'planType', 'stale', 'staleReason', 'primary', 'secondary'
  )
  if (-not ($Quota.ok -is [bool])) { throw "$Path.ok is not a boolean." }
  foreach ($field in @('reason', 'staleReason')) {
    if ((Test-HasField $Quota $field) -and -not (Test-ReasonCode $Quota.$field)) { throw "$Path.$field is invalid." }
  }
  if ($Quota.ok) {
    foreach ($field in @('reason', 'source', 'observedAt', 'planType', 'primary', 'secondary')) {
      if (-not (Test-HasField $Quota $field)) { throw "$Path is missing $field for a successful quota result." }
    }
    if ($null -ne $Quota.reason) { throw "$Path.reason must be null for a successful quota result." }
    if ($Quota.source -cnotin @('app_server', 'session')) { throw "$Path.source is not a known Codex quota source." }
    if (-not (Test-IsoTimestamp $Quota.observedAt)) { throw "$Path.observedAt is invalid." }
    if ($null -ne $Quota.planType -and
        (-not ($Quota.planType -is [string]) -or $Quota.planType -cnotmatch '\A[a-z0-9_]{1,64}\z')) {
      throw "$Path.planType is invalid."
    }
    if ($null -eq $Quota.primary -and $null -eq $Quota.secondary) { throw "$Path has no rate-limit window." }
  } elseif (-not (Test-HasField $Quota 'reason') -or
      -not (Test-BoundedString $Quota.reason 128 $false) -or
      $Quota.reason -notmatch '\A[a-z0-9_]+\z') {
    throw "$Path.reason must be a non-empty reason code for a failed quota result."
  }
  if ((Test-HasField $Quota 'stale') -and $Quota.stale) {
    if (-not $Quota.ok -or -not (Test-HasField $Quota 'staleReason') -or $null -eq $Quota.staleReason) {
      throw "$Path stale quota result is incomplete."
    }
  } elseif (Test-HasField $Quota 'staleReason') {
    throw "$Path has staleReason without stale:true."
  }
  foreach ($windowName in @('primary', 'secondary')) {
    if (-not (Test-HasField $Quota $windowName) -or $null -eq $Quota.$windowName) { continue }
    $window = $Quota.$windowName
    $windowPath = "$Path.$windowName"
    Assert-Fields $window $windowPath @('used_percent', 'resets_at', 'window_minutes') @('used_percent', 'resets_at', 'window_minutes')
    if (-not (Test-Percent $window.used_percent)) { throw "$windowPath.used_percent is invalid." }
    Assert-NullableTimestamp $window.resets_at "$windowPath.resets_at"
    if ($null -ne $window.window_minutes -and
        (-not (Test-JsonInt64 $window.window_minutes) -or [double]$window.window_minutes -le 0)) {
      throw "$windowPath.window_minutes is invalid."
    }
  }
}

function Assert-ClaudeBlocks($Blocks, [string]$Path) {
  if ($null -eq $Blocks) { return }
  Assert-Fields $Blocks $Path @('blocks') @('blocks')
  Assert-RecordArray $Blocks.blocks "$Path.blocks"
  $index = 0
  foreach ($block in $Blocks.blocks) {
    $blockPath = "$Path.blocks[$index]"
    Assert-Fields $block $blockPath `
      @('costUSD', 'isActive', 'isGap', 'startTime', 'endTime') `
      @('costUSD', 'totalTokens', 'isActive', 'isGap', 'startTime', 'endTime', 'actualEndTime', 'burnRate', 'projection')
    Assert-NonnegativeNumber $block.costUSD "$blockPath.costUSD"
    if ((Test-HasField $block 'totalTokens') -and
        (-not (Test-JsonInt64 $block.totalTokens) -or [double]$block.totalTokens -lt 0)) {
      throw "$blockPath.totalTokens is not a nonnegative integer."
    }
    foreach ($field in @('isActive', 'isGap')) {
      if (-not ($block.$field -is [bool])) { throw "$blockPath.$field is not a boolean." }
    }
    foreach ($field in @('startTime', 'endTime')) {
      if (-not (Test-IsoTimestamp $block.$field)) { throw "$blockPath.$field is invalid." }
    }
    if (Test-HasField $block 'actualEndTime') { Assert-NullableTimestamp $block.actualEndTime "$blockPath.actualEndTime" }
    $start = [DateTimeOffset]::Parse($block.startTime, [Globalization.CultureInfo]::InvariantCulture)
    $end = [DateTimeOffset]::Parse($block.endTime, [Globalization.CultureInfo]::InvariantCulture)
    if ($end -lt $start) { throw "$blockPath ends before it starts." }
    if ((Test-HasField $block 'actualEndTime') -and $null -ne $block.actualEndTime) {
      $actualEnd = [DateTimeOffset]::Parse($block.actualEndTime, [Globalization.CultureInfo]::InvariantCulture)
      if ($actualEnd -lt $start -or $actualEnd -gt $end) { throw "$blockPath actualEndTime is outside its window." }
    }
    foreach ($nested in @(
      @{ Name = 'burnRate'; Field = 'costPerHour' },
      @{ Name = 'projection'; Field = 'totalCost' }
    )) {
      if ((Test-HasField $block $nested.Name) -and $null -ne $block.($nested.Name)) {
        $nestedPath = "$blockPath.$($nested.Name)"
        Assert-Fields $block.($nested.Name) $nestedPath @($nested.Field) @($nested.Field)
        Assert-NonnegativeNumber $block.($nested.Name).($nested.Field) "$nestedPath.$($nested.Field)"
      }
    }
    $index += 1
  }
}

Assert-Fields $data '$' `
  @('generatedAt', 'runId', 'revision', 'complete', 'generationError', 'period', 'currency', 'pricingNote', 'source', 'periods', 'reports', 'limits', 'appDir') `
  @('generatedAt', 'runId', 'revision', 'complete', 'generationError', 'period', 'currency', 'pricingNote', 'source', 'periods', 'reports', 'limits', 'appDir')
if (-not (Test-IsoTimestamp $data.generatedAt)) { throw 'Snapshot generatedAt metadata is invalid.' }
Assert-String $data.runId 'runId' 128 $false
Assert-Int64 $data.revision 'revision'
if ([int64]$data.revision -lt 1) { throw 'Snapshot revision must be positive.' }
if (-not ($data.complete -is [bool]) -or -not $data.complete) { throw 'Snapshot is not marked complete.' }
if ($null -ne $data.generationError) {
  Assert-Fields $data.generationError 'generationError' @('reason', 'stage') @('reason', 'stage')
  foreach ($field in @('reason', 'stage')) { Assert-String $data.generationError.$field "generationError.$field" 128 $false }
}
Assert-Fields $data.currency 'currency' @('code', 'rate', 'symbol') @('code', 'rate', 'symbol')
if (-not ($data.currency.code -is [string]) -or $data.currency.code -notmatch '\A[A-Za-z]{3}\z') {
  throw 'Snapshot currency code is invalid.'
}
$currencyCode = $data.currency.code.ToUpperInvariant()
if ($currencyCode -eq 'USD') {
  if (-not (Test-JsonFiniteNumber $data.currency.rate) -or [double]$data.currency.rate -ne 1) {
    throw 'Snapshot USD currency rate must be exactly 1.'
  }
} elseif ($null -ne $data.currency.rate -and
    (-not (Test-JsonFiniteNumber $data.currency.rate) -or [double]$data.currency.rate -le 0)) {
  throw 'Snapshot non-USD currency rate must be positive or null when unavailable.'
}
Assert-String $data.currency.symbol 'currency.symbol' 64
Assert-String $data.pricingNote 'pricingNote' 4096 $false
Assert-Fields $data.source 'source' @('name', 'version') @('name', 'version')
Assert-String $data.source.name 'source.name' 128 $false
Assert-String $data.source.version 'source.version' 128 $false
Assert-String $data.appDir 'appDir' 32767 $false

$validPeriods = @('today', 'week', '30days', 'month', 'all', 'lifetime')
if (-not ($data.periods -is [Collections.IList]) -or $data.periods -is [string]) {
  throw 'Snapshot periods metadata is not an array.'
}
$periods = @($data.periods)
if (-not ($data.period -is [string]) -or $validPeriods -cnotcontains $data.period -or
    $periods.Count -lt 1 -or $periods[0] -cne $data.period) {
  throw 'The default period is not published first.'
}
foreach ($periodKey in $periods) {
  if (-not ($periodKey -is [string]) -or $validPeriods -cnotcontains $periodKey) {
    throw 'Snapshot periods metadata contains an invalid key.'
  }
}
if (@($periods | Select-Object -Unique).Count -ne $periods.Count) {
  throw 'Snapshot periods metadata contains duplicate keys.'
}
Assert-Fields $data.reports 'reports' $periods $periods
foreach ($period in $periods) {
  Assert-Fields $data.reports.$period "reports.$period" @('claude', 'codex') @('claude', 'codex')
  foreach ($provider in @('claude', 'codex')) {
    $report = $data.reports.$period.$provider
    Assert-Report $report "reports.$period.$provider"
    if ($report.currency.ToUpperInvariant() -cne $currencyCode) {
      throw "reports.$period.$provider.currency differs from the display currency."
    }
  }
  $claudeNames = @($data.reports.$period.claude.models | Where-Object { $_.kind -ne 'unattributed' } | ForEach-Object name)
  $codexNames = @($data.reports.$period.codex.models | Where-Object { $_.kind -ne 'unattributed' } | ForEach-Object name)
  $overlap = @($claudeNames | Where-Object { $codexNames -contains $_ })
  if ($overlap.Count) { throw "Provider model overlap for ${period}: $($overlap -join ', ')" }
}

Assert-Fields $data.limits 'limits' @('claudeQuota', 'claudeBlocks', 'codexQuota', 'codex') `
  @('claudeQuota', 'claudeBlocks', 'codexQuota', 'codex')
Assert-ClaudeQuota $data.limits.claudeQuota 'limits.claudeQuota'
Assert-ClaudeBlocks $data.limits.claudeBlocks 'limits.claudeBlocks'
Assert-CodexQuota $data.limits.codexQuota 'limits.codexQuota'
Assert-CodexOfficial $data.limits.codex 'limits.codex'

function Assert-NoSensitiveFields($Value, [string]$Path = '$') {
  if ($null -eq $Value) { return }
  if ($Value -is [string]) {
    if ($Value -match '(?i)\bBearer\s+[A-Za-z0-9._-]{12,}' -or $Value -match '(?i)\bsk-[A-Za-z0-9_-]{16,}') {
      throw "Credential-like value found at $Path"
    }
    if ($Value -match '(?i)https?://') { throw "Provider endpoint found at $Path" }
    if ($Value -match '\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}') { throw "Token-shaped value found at $Path" }
    return
  }
  if ($Value -is [Collections.IEnumerable] -and $Value -isnot [Management.Automation.PSCustomObject]) {
    $index = 0
    foreach ($item in $Value) { Assert-NoSensitiveFields $item "$Path[$index]"; $index += 1 }
    return
  }
  foreach ($property in $Value.PSObject.Properties) {
    if ($property.Name -in @(
      'accessToken', 'claudeAiOauth', 'shellCommands', 'authorization',
      'toolArguments', 'prompt', 'providerId', 'providerFingerprint', 'accountFingerprint',
      'accountUuid', 'organizationUuid', 'oauthAccount', 'emailAddress', 'access_token',
      'refresh_token', 'id_token', 'OPENAI_API_KEY'
    )) {
      throw "Sensitive field found at $Path.$($property.Name)"
    }
    Assert-NoSensitiveFields $property.Value "$Path.$($property.Name)"
  }
}
Assert-NoSensitiveFields $data

Write-Output "Verify-Snapshot.ps1: PASS ($($data.periods -join ', '))"
