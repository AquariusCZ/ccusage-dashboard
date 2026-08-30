$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\ReportData.psm1') -Force

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Assert-Close([double]$Actual, [double]$Expected, [string]$Message) {
  if ([Math]::Abs($Actual - $Expected) -gt 0.000001) {
    throw "$Message (actual=$Actual expected=$Expected)"
  }
}

function New-Report([double]$Cost, [double]$NetCost, [object[]]$Models) {
  return [pscustomobject]@{
    currency = 'USD'
    overview = [pscustomobject]@{ cost = $Cost; netCost = $NetCost; tokens = [pscustomobject]@{} }
    daily = @()
    models = $Models
    projects = @()
    topSessions = @()
  }
}

function Model([string]$Name, [double]$Cost, [int]$Calls, [int64]$Tokens) {
  return [pscustomobject]@{
    name = $Name; cost = $Cost; calls = $Calls
    inputTokens = $Tokens; outputTokens = 0; cacheReadTokens = 0; cacheWriteTokens = 0
  }
}

$report = New-Report 100 40 @(
  (Model 'Opus 4.8' 60 6 6000),
  (Model 'Fable 5' 20 2 2000)
)
$status = [pscustomobject]@{
  cost = 100
  topModels = @(
    [pscustomobject]@{ name = 'claude-opus-4-8'; cost = 75; calls = 8; savingsUSD = 0; estimatedCostUSD = 0 },
    [pscustomobject]@{ name = 'claude-fable-5'; cost = 25; calls = 3; savingsUSD = 0; estimatedCostUSD = 0 }
  )
}
$merged = Merge-CodeBurnDurableModels -Report $report -StatusCurrent $status
$sum = [double](($merged.models | Measure-Object -Property cost -Sum).Sum)
Assert-Close $sum 100 'durable model rows must conserve the API reference total'
Assert-True ($merged.models[0].name -eq 'Opus 4.8') 'raw durable ids must retain the report display name'
Assert-True ($merged.models[0].tokensPartial -eq $true) 'live token detail must be marked partial when durable cost is higher'
Assert-True ($merged.costReconciliation.modelSource -eq 'durable_status') 'durable status should be the primary model source'
Assert-Close $merged.costReconciliation.referenceCost 100 'gross API reference cost must win over netCost'

$historicalOnly = Merge-CodeBurnDurableModels `
  -Report (New-Report 5 5 @()) `
  -StatusCurrent ([pscustomobject]@{ cost = 5; topModels = @([pscustomobject]@{ name = 'claude-haiku-4-5-20251001'; cost = 5; calls = 5 }) })
Assert-True ($historicalOnly.models[0].name -eq 'Haiku 4.5') 'historical-only Claude ids must remain readable'

$datedLive = Merge-CodeBurnDurableModels `
  -Report (New-Report 5 5 @((Model 'Haiku 4.5' 5 5 100))) `
  -StatusCurrent ([pscustomobject]@{ cost = 5; topModels = @([pscustomobject]@{ name = 'claude-haiku-4-5-20251001'; cost = 5; calls = 5 }) })
Assert-Close $datedLive.models[0].inputTokens 100 'dated raw Claude ids must merge with live friendly names'
Assert-True ($datedLive.models[0].tokensPartial -eq $false) 'matching durable calls and cost retain complete live tokens'

$sameCostMoreCalls = Merge-CodeBurnDurableModels `
  -Report (New-Report 5 5 @((Model 'Opus 4.8' 5 1 100))) `
  -StatusCurrent ([pscustomobject]@{ cost = 5; topModels = @([pscustomobject]@{ name = 'claude-opus-4-8'; cost = 5; calls = 2 }) })
Assert-True ($sameCostMoreCalls.models[0].tokensPartial -eq $true) 'durable calls beyond live calls make token counts partial even at equal cost'

$truncated = Merge-CodeBurnDurableModels `
  -Report (New-Report 120 120 @((Model 'Opus 4.8' 80 8 8000))) `
  -StatusCurrent ([pscustomobject]@{ cost = 100; topModels = @([pscustomobject]@{ name = 'claude-opus-4-8'; cost = 100; calls = 10 }) })
Assert-True ($truncated.models[-1].kind -eq 'unattributed') 'a truncated durable list must expose its remainder'
Assert-Close $truncated.models[-1].cost 20 'the unattributed row must equal the exact remainder'

$fallback = Merge-CodeBurnDurableModels -Report (New-Report 100 100 @((Model 'Opus 4.8' 80 8 8000))) -StatusCurrent $null
Assert-True ($fallback.costReconciliation.modelSource -eq 'live_report_fallback') 'missing durable status must fall back without losing the dashboard'
Assert-Close ([double](($fallback.models | Measure-Object -Property cost -Sum).Sum)) 100 'fallback rows must still conserve the total'

$ahead = Merge-CodeBurnDurableModels `
  -Report (New-Report 100 100 @((Model 'Opus 4.8' 80 8 8000))) `
  -StatusCurrent ([pscustomobject]@{ cost = 101; topModels = @([pscustomobject]@{ name = 'claude-opus-4-8'; cost = 101; calls = 10 }) })
Assert-True ($ahead.costReconciliation.modelSource -eq 'live_report_fallback') 'a status snapshot ahead of the report must not overstate the report total'
Assert-Close ([double](($ahead.models | Measure-Object -Property cost -Sum).Sum)) 100 'ahead-of-report fallback must conserve the report total'

$contradictory = Merge-CodeBurnDurableModels -Report (New-Report 50 50 @((Model 'Opus 4.8' 80 8 8000))) -StatusCurrent $null
Assert-True ($contradictory.costReconciliation.modelSource -eq 'unattributed_fallback') 'contradictory live rows must not overstate the reference total'
Assert-True ($contradictory.models[0].kind -eq 'unattributed') 'contradictory live rows must degrade to an explicit neutral total'
Assert-Close ([double](($contradictory.models | Measure-Object -Property cost -Sum).Sum)) 50 'contradictory fallback must conserve the report total'

$rounding = Merge-CodeBurnDurableModels `
  -Report (New-Report 100 100 @((Model 'Opus 4.8' 99.997 8 8000))) `
  -StatusCurrent ([pscustomobject]@{ cost = 100; topModels = @([pscustomobject]@{ name = 'claude-opus-4-8'; cost = 99.997; calls = 8 }) })
Assert-Close ([double](($rounding.models | Measure-Object -Property cost -Sum).Sum)) 100 'sub-cent residuals must still reconcile exactly'
Assert-Close $rounding.costReconciliation.unattributedCost 0 'sub-cent residuals should not create a visible unattributed row'

$tinyUnattributed = Merge-CodeBurnDurableModels -Report (New-Report 0.003 0.003 @()) -StatusCurrent $null
Assert-True ($tinyUnattributed.models[0].kind -eq 'unattributed') 'a positive total without models must remain explicit even below tolerance'
Assert-Close $tinyUnattributed.costReconciliation.unattributedCost 0.003 'unattributed metadata must match the emitted row'
Assert-True ($tinyUnattributed.costReconciliation.modelTokensPartial -eq $true) 'an unattributed row has no complete token detail'

$cnyReport = New-Report 720 720 @((Model 'Opus 4.8' 360 5 5000))
$cnyReport.currency = 'CNY'
$cnyStatus = [pscustomobject]@{ cost = 100; topModels = @([pscustomobject]@{ name = 'claude-opus-4-8'; cost = 100; calls = 10; savingsUSD = 2; estimatedCostUSD = 3 }) }
$cnyMerged = Merge-CodeBurnDurableModels -Report $cnyReport -StatusCurrent $cnyStatus -StatusCurrency ([pscustomobject]@{ code = 'CNY'; rate = 7.2; symbol = 'CNY' })
Assert-Close ([double](($cnyMerged.models | Measure-Object -Property cost -Sum).Sum)) 720 'durable USD model costs must convert into the report currency'
Assert-Close $cnyMerged.models[0].savings 14.4 'durable USD savings must use the same report currency rate'
Assert-Close $cnyMerged.costReconciliation.statusCost 720 'status metadata must use the report currency'

$overflowLive = Merge-CodeBurnDurableModels `
  -Report (New-Report ([double]::MaxValue) ([double]::MaxValue) @(
    (Model 'Overflow A' ([double]::MaxValue) 1 1),
    (Model 'Overflow B' ([double]::MaxValue) 1 1)
  )) `
  -StatusCurrent $null
Assert-True ($overflowLive.costReconciliation.modelSource -eq 'unattributed_fallback') 'an overflowing live sum must degrade to one unattributed total'
Assert-True ($overflowLive.models.Count -eq 1 -and $overflowLive.models[0].kind -eq 'unattributed') 'overflowing live rows must not reach the render DTO'
Assert-True (-not (($overflowLive | ConvertTo-Json -Depth 20 -Compress) -match 'NaN|Infinity')) 'live overflow fallback must remain valid JSON'

$overflowStatus = Merge-CodeBurnDurableModels `
  -Report (New-Report 100 100 @((Model 'Opus 4.8' 100 1 1))) `
  -StatusCurrent ([pscustomobject]@{
    cost = [double]::MaxValue
    topModels = @([pscustomobject]@{ name = 'claude-opus-4-8'; cost = [double]::MaxValue; calls = 1 })
  }) `
  -StatusCurrency ([pscustomobject]@{ code = 'USD'; rate = 2; symbol = '$' })
Assert-True ($overflowStatus.costReconciliation.modelSource -eq 'live_report_fallback') 'overflowing optional status conversion must fall back to the live report'
Assert-Close $overflowStatus.costReconciliation.statusCost 0 'overflowing optional status metadata must be replaced with a finite neutral value'
Assert-True (-not (($overflowStatus | ConvertTo-Json -Depth 20 -Compress) -match 'NaN|Infinity')) 'status overflow fallback must remain valid JSON'

$overflowDurableSum = Merge-CodeBurnDurableModels `
  -Report (New-Report ([double]::MaxValue) ([double]::MaxValue) @((Model 'Overflow A' ([double]::MaxValue) 1 1))) `
  -StatusCurrent ([pscustomobject]@{
    cost = [double]::MaxValue
    topModels = @(
      [pscustomobject]@{ name = 'overflow-a'; cost = [double]::MaxValue; calls = 1 },
      [pscustomobject]@{ name = 'overflow-b'; cost = [double]::MaxValue; calls = 1 }
    )
  })
Assert-True ($overflowDurableSum.costReconciliation.modelSource -eq 'live_report_fallback') 'an overflowing durable model sum must fall back to finite live rows'
Assert-True (-not (($overflowDurableSum | ConvertTo-Json -Depth 20 -Compress) -match 'NaN|Infinity')) 'durable overflow fallback must remain valid JSON'

$codexOnlyCurrency = Resolve-DisplayCurrency `
  -ReportCurrencies @('CNY', 'CNY') `
  -StatusCurrencies @($null, [pscustomobject]@{ code = 'CNY'; rate = 7.2; symbol = 'CNY' })
Assert-Close $codexOnlyCurrency.rate 7.2 'display currency may use a valid status rate from either provider'
Assert-True ($codexOnlyCurrency.code -eq 'CNY') 'display currency must match every report'

$overflowingModelSum = Merge-CodeBurnDurableModels `
  -Report (New-Report ([double]::MaxValue) ([double]::MaxValue) @(
    (Model 'Model A' ([double]::MaxValue) 1 0),
    (Model 'Model B' ([double]::MaxValue) 1 0)
  )) `
  -StatusCurrent $null
Assert-True (-not [double]::IsInfinity([double]$overflowingModelSum.costReconciliation.modelSourceCost)) 'finite model costs must not publish Infinity after summation overflow'
Assert-True ($overflowingModelSum.costReconciliation.modelSource -eq 'unattributed_fallback') 'summation overflow must degrade to finite unattributed cost'

$overflowingRate = Merge-CodeBurnDurableModels `
  -Report (New-Report ([double]::MaxValue) ([double]::MaxValue) @()) `
  -StatusCurrent ([pscustomobject]@{ cost = [double]::MaxValue; topModels = @() }) `
  -StatusCurrency ([pscustomobject]@{ code = 'USD'; rate = 2; symbol = '$' })
Assert-True (-not [double]::IsInfinity([double]$overflowingRate.costReconciliation.statusCost)) 'finite status cost and rate values must not publish Infinity after multiplication overflow'

# Codex relay quota, replayed from a CC Switch usage script
function New-UsageScriptMeta(
  [string]$Url,
  [string]$Method,
  [bool]$Enabled,
  [string]$HeaderValue,
  $Timeout = 10
) {
  $code = '({ request: { url: "' + $Url + '", method: "' + $Method + '", headers: { "Authorization": "' + $HeaderValue + '" } },' +
    ' extractor: function(response) { return { remaining: response?.remaining, unit: response?.unit ?? "USD" }; } })'
  return (@{ usage_script = @{ enabled = $Enabled; language = 'javascript'; timeout = $Timeout; code = $code } } | ConvertTo-Json -Depth 6 -Compress)
}

function New-ProviderConfig([string]$BaseUrl, [string]$ApiKey) {
  $toml = "model_provider = `"custom`"`nmodel = `"gpt-5.5`"`n`n[model_providers.custom]`nname = `"Relay`"`nbase_url = `"$BaseUrl`"`nwire_api = `"responses`"`n"
  $auth = if ($ApiKey) { @{ OPENAI_API_KEY = $ApiKey } } else { @{} }
  return (@{ auth = $auth; config = $toml } | ConvertTo-Json -Depth 6 -Compress)
}

$standardMeta = New-UsageScriptMeta '{{baseUrl}}/v1/usage' 'GET' $true 'Bearer {{apiKey}}'
$standardConfig = New-ProviderConfig 'https://relay.example.com' 'sk-relay-test-key'

$request = Get-CodexUsageRequest -MetaJson $standardMeta -SettingsConfigJson $standardConfig
Assert-True ($request.ok -eq $true) 'a standard CC Switch usage script must produce a request'
Assert-True ($request.url -eq 'https://relay.example.com/v1/usage') 'the baseUrl placeholder must resolve against the provider TOML'
Assert-True ($request.method -eq 'GET') 'the declared method must be preserved'
Assert-True ($request.headers['Authorization'] -eq 'Bearer sk-relay-test-key') 'the apiKey placeholder must resolve inside headers'
Assert-True ($request.headers['User-Agent'] -eq 'AI-Usage/1.0') 'a User-Agent must be supplied when the script omits one'
Assert-True ($request.timeoutSeconds -eq 10) 'the script timeout must carry through'

$trailingSlash = Get-CodexUsageRequest -MetaJson $standardMeta -SettingsConfigJson (New-ProviderConfig 'https://relay.example.com/' 'sk-relay-test-key')
Assert-True ($trailingSlash.url -eq 'https://relay.example.com/v1/usage') 'a trailing slash on base_url must not double up'

$ownAgent = Get-CodexUsageRequest `
  -MetaJson (@{ usage_script = @{ enabled = $true; timeout = 10; code = '({ request: { url: "{{baseUrl}}/v1/usage", method: "GET", headers: { "User-Agent": "cc-switch/1.0" } } })' } } | ConvertTo-Json -Depth 6 -Compress) `
  -SettingsConfigJson $standardConfig
Assert-True ($ownAgent.headers['User-Agent'] -eq 'cc-switch/1.0') 'a script that declares its own User-Agent must keep it'
$contentTypeRequest = Get-CodexUsageRequest `
  -MetaJson (@{ usage_script = @{ enabled = $true; timeout = 10; code = '({ request: { url: "{{baseUrl}}/v1/usage", method: "GET", headers: { "Authorization": "Bearer {{apiKey}}", "Content-Type": "application/json" } } })' } } | ConvertTo-Json -Depth 6 -Compress) `
  -SettingsConfigJson $standardConfig
Assert-True ($contentTypeRequest.ok -and $contentTypeRequest.headers['Content-Type'] -eq 'application/json') 'an upstream Content-Type declaration must survive request parsing'

Assert-True ((Get-CodexUsageRequest -MetaJson '{}' -SettingsConfigJson $standardConfig).reason -eq 'usage_script_missing') 'a provider without a usage script must say so'
Assert-True ((Get-CodexUsageRequest -MetaJson (New-UsageScriptMeta '{{baseUrl}}/v1/usage' 'GET' $false 'Bearer {{apiKey}}') -SettingsConfigJson $standardConfig).reason -eq 'usage_script_disabled') 'a disabled usage script must not be replayed'
Assert-True ((Get-CodexUsageRequest -MetaJson (New-UsageScriptMeta '{{baseUrl}}/v1/usage' 'POST' $true 'Bearer {{apiKey}}') -SettingsConfigJson $standardConfig).reason -eq 'unsupported_method') 'a mutating usage script must be refused, not trusted'
Assert-True ((Get-CodexUsageRequest -MetaJson $standardMeta -SettingsConfigJson (New-ProviderConfig 'http://relay.example.com' 'sk-relay-test-key')).reason -eq 'insecure_endpoint') 'a plaintext endpoint must be refused'
Assert-True ((Get-CodexUsageRequest -MetaJson $standardMeta -SettingsConfigJson (New-ProviderConfig '' 'sk-relay-test-key')).reason -eq 'no_base_url') 'a provider without base_url must degrade with a reason'
$mismatchedProviderConfig = @{
  auth = @{ OPENAI_API_KEY = 'sk-relay-test-key' }
  config = "model_provider = `"trusted`"`n`n[model_providers.attacker]`nbase_url = `"https://attacker.example.test`"`n"
} | ConvertTo-Json -Depth 6 -Compress
Assert-True ((Get-CodexUsageRequest -MetaJson $standardMeta -SettingsConfigJson $mismatchedProviderConfig).reason -eq 'no_base_url') 'a missing selected provider section must not fall back to another provider base_url'
$commentedBaseConfig = @{
  auth = @{ OPENAI_API_KEY = 'sk-relay-test-key' }
  config = "model_provider = `"trusted`"`n[model_providers.trusted]`n# base_url = `"https://comment-attacker.example.test`"`n"
} | ConvertTo-Json -Depth 6 -Compress
Assert-True ((Get-CodexUsageRequest -MetaJson $standardMeta -SettingsConfigJson $commentedBaseConfig).reason -eq 'no_base_url') 'a commented base_url must never become a credential destination'
$commentedSectionConfig = @{
  auth = @{ OPENAI_API_KEY = 'sk-relay-test-key' }
  config = "model_provider = `"trusted`"`n# [model_providers.trusted]`nbase_url = `"https://comment-attacker.example.test`"`n"
} | ConvertTo-Json -Depth 6 -Compress
Assert-True ((Get-CodexUsageRequest -MetaJson $standardMeta -SettingsConfigJson $commentedSectionConfig).reason -eq 'no_base_url') 'a commented provider section must never become a credential destination'
$nestedProviderConfig = @{
  auth = @{ OPENAI_API_KEY = 'sk-relay-test-key' }
  config = "[other]`nmodel_provider = `"attacker`"`n[model_providers.attacker]`nbase_url = `"https://attacker.example.test`"`n"
} | ConvertTo-Json -Depth 6 -Compress
Assert-True ((Get-CodexUsageRequest -MetaJson $standardMeta -SettingsConfigJson $nestedProviderConfig).reason -eq 'no_base_url') 'a model_provider key inside another TOML table must not select a credential destination'
$lateProviderConfig = @{
  auth = @{ OPENAI_API_KEY = 'sk-relay-test-key' }
  config = "[model_providers.attacker]`nbase_url = `"https://attacker.example.test`"`nmodel_provider = `"attacker`"`n"
} | ConvertTo-Json -Depth 6 -Compress
Assert-True ((Get-CodexUsageRequest -MetaJson $standardMeta -SettingsConfigJson $lateProviderConfig).reason -eq 'no_base_url') 'a model_provider assignment after the first TOML table must not be treated as top-level'
Assert-True ((Get-CodexUsageRequest -MetaJson $standardMeta -SettingsConfigJson (New-ProviderConfig 'https://relay.example.com' '')).reason -eq 'no_api_key') 'a provider without a key must degrade with a reason'
Assert-True ((Get-CodexUsageRequest -MetaJson (New-UsageScriptMeta 'https://relay.example.com/v1/usage?key={{apiKey}}' 'GET' $true '') -SettingsConfigJson $standardConfig).reason -eq 'credential_in_url') 'an API key placeholder in a URL must be refused before expansion'
Assert-True ((Get-CodexUsageRequest -MetaJson (New-UsageScriptMeta 'https://attacker.example/v1/usage' 'GET' $true 'Bearer {{apiKey}}') -SettingsConfigJson $standardConfig).reason -eq 'credential_scope_mismatch') 'a credential-bearing request must be derived from the selected provider base_url'
Assert-True ((Get-CodexUsageRequest -MetaJson (New-UsageScriptMeta '{{baseUrl}}.attacker.example/v1/usage' 'GET' $true 'Bearer {{apiKey}}') -SettingsConfigJson $standardConfig).reason -eq 'credential_scope_mismatch') 'a base_url prefix lookalike must not receive provider credentials'
Assert-True ((Get-CodexUsageRequest -MetaJson (New-UsageScriptMeta '{{baseUrl}}:444/v1/usage' 'GET' $true 'Bearer {{apiKey}}') -SettingsConfigJson $standardConfig).reason -eq 'credential_scope_mismatch') 'a different endpoint port must not receive provider credentials'
foreach ($forbiddenHeader in @(
  'Host', 'proxy-authorization', 'Connection', 'X-HTTP-Method-Override',
  'Forwarded', 'X-Forwarded-Host', 'X-Original-Host', 'X-Host', 'X-Original-URL', 'X-Rewrite-URL'
)) {
  $forbiddenMeta = @{ usage_script = @{
      enabled = $true
      timeout = 10
      code = '({ request: { url: "{{baseUrl}}/v1/usage", method: "GET", headers: { "' +
        $forbiddenHeader + '": "{{apiKey}}" } } })'
    } } | ConvertTo-Json -Depth 6 -Compress
  Assert-True ((Get-CodexUsageRequest -MetaJson $forbiddenMeta -SettingsConfigJson $standardConfig).reason -eq 'unsupported_header') "the $forbiddenHeader header must not override request routing, proxy credentials, or method semantics"
}
$crlfHeaderMeta = @{ usage_script = @{
    enabled = $true
    timeout = 10
    code = '({ request: { url: "{{baseUrl}}/v1/usage", method: "GET", headers: { "Authorization": "Bearer {{apiKey}}", "Accept": "safe' +
      "`r`n" + 'X-Forwarded-Host: attacker.example" } } })'
  } } | ConvertTo-Json -Depth 6 -Compress
Assert-True ((Get-CodexUsageRequest -MetaJson $crlfHeaderMeta -SettingsConfigJson $standardConfig).reason -eq 'unsupported_header') 'a CRLF value must not inject a forbidden routing header after allowlist validation'
Assert-True ((Get-CodexUsageRequest -MetaJson (New-UsageScriptMeta '{{baseUrl}}/v1/usage' 'GET' $true 'Bearer {{sessionToken}}') -SettingsConfigJson $standardConfig).reason -eq 'unresolved_placeholder') 'an unsupported placeholder must fail closed rather than be sent literally'
Assert-True ((Get-CodexUsageRequest -MetaJson 'not json' -SettingsConfigJson $standardConfig).reason -eq 'usage_script_unreadable') 'unreadable provider metadata must degrade with a reason'

$fractionalTimeout = Get-CodexUsageRequest -MetaJson (New-UsageScriptMeta '{{baseUrl}}/v1/usage' 'GET' $true 'Bearer {{apiKey}}' 0.1) -SettingsConfigJson $standardConfig
$minimumTimeout = Get-CodexUsageRequest -MetaJson (New-UsageScriptMeta '{{baseUrl}}/v1/usage' 'GET' $true 'Bearer {{apiKey}}' 1) -SettingsConfigJson $standardConfig
$maximumTimeout = Get-CodexUsageRequest -MetaJson (New-UsageScriptMeta '{{baseUrl}}/v1/usage' 'GET' $true 'Bearer {{apiKey}}' 60) -SettingsConfigJson $standardConfig
$oversizedTimeout = Get-CodexUsageRequest -MetaJson (New-UsageScriptMeta '{{baseUrl}}/v1/usage' 'GET' $true 'Bearer {{apiKey}}' 60.1) -SettingsConfigJson $standardConfig
Assert-True ($fractionalTimeout.timeoutSeconds -eq 10) 'a fractional timeout must not truncate to an infinite zero timeout'
Assert-True ($minimumTimeout.timeoutSeconds -eq 1) 'the minimum integral timeout must be preserved'
Assert-True ($maximumTimeout.timeoutSeconds -eq 60) 'the maximum integral timeout must be preserved'
Assert-True ($oversizedTimeout.timeoutSeconds -eq 10) 'an oversized fractional timeout must fall back to the bounded default'

$usage = [pscustomobject]@{
  isValid = $true
  mode = 'unrestricted'
  planName = 'Weekly 600 Plan'
  remaining = 245.67
  unit = 'USD'
  subscription = [pscustomobject]@{
    daily_limit_usd = 0; daily_usage_usd = 274.05
    weekly_limit_usd = 600; weekly_usage_usd = 354.33; weekly_window_start = '2026-08-13T11:56:30+08:00'
    monthly_limit_usd = 0; monthly_usage_usd = 354.33
    expires_at = '2026-08-28T08:40:42+08:00'
  }
}
$codexQuota = ConvertTo-CodexQuota -Response $usage -ProviderName 'Relay'
Assert-True ($codexQuota.ok -eq $true) 'a relay usage response must produce quota state'
Assert-Close $codexQuota.remaining 245.67 'the relay balance must survive extraction'
Assert-True ($codexQuota.unit -eq 'USD') 'the relay unit must be normalised'
Assert-True ($codexQuota.provider -eq 'Relay') 'the card must know which provider answered'
$weekly = @($codexQuota.windows | Where-Object { $_.kind -eq 'weekly' })[0]
Assert-Close $weekly.percent 59.055 'the weekly meter must be usage over limit'
Assert-True (([DateTimeOffset]$weekly.resetsAt) -eq ([DateTimeOffset]'2026-08-20T11:56:30+08:00')) 'a rolling weekly window resets seven days after it starts'
$daily = @($codexQuota.windows | Where-Object { $_.kind -eq 'daily' })[0]
Assert-True ($null -eq $daily.percent) 'a zero limit is unmetered and must not render a meter'
Assert-Close $daily.used 274.05 'an unmetered window still reports its usage'

$fallbackShape = ConvertTo-CodexQuota -Response ([pscustomobject]@{
  is_active = $false
  quota = [pscustomobject]@{ remaining = 12.5; unit = 'cny' }
}) -ProviderName $null
Assert-Close $fallbackShape.remaining 12.5 'the quota.remaining fallback must match CC Switch extraction'
Assert-True ($fallbackShape.unit -eq 'CNY') 'the quota.unit fallback must match CC Switch extraction'
Assert-True ($fallbackShape.isValid -eq $false) 'is_active must win over the permissive default'
Assert-True ($fallbackShape.windows.Count -eq 0) 'a response without a subscription block must not invent windows'

$balanceOnly = ConvertTo-CodexQuota -Response ([pscustomobject]@{ balance = 7 }) -ProviderName 'Relay'
Assert-Close $balanceOnly.remaining 7 'the balance fallback must match CC Switch extraction'
Assert-True ($balanceOnly.isValid -eq $true) 'a response that says nothing about validity is assumed valid'
Assert-True ((ConvertTo-CodexQuota -Response $null).reason -eq 'malformed_response') 'an empty response must degrade with a reason'
foreach ($invalidResponse in @(
  [pscustomobject]@{},
  [pscustomobject]@{ remaining = 'not-a-number' },
  [pscustomobject]@{ remaining = 5; isValid = 'false' },
  [pscustomobject]@{ subscription = 'not-a-record' },
  [pscustomobject]@{ subscription = [pscustomobject]@{ weekly_usage_usd = 'bad'; weekly_limit_usd = 10 } }
)) {
  Assert-True ((ConvertTo-CodexQuota -Response $invalidResponse).reason -eq 'malformed_response') 'malformed relay quota data must fail closed'
}

$invalidExpiry = ($usage | ConvertTo-Json -Depth 10 -Compress) | ConvertFrom-Json
$invalidExpiry.subscription.expires_at = 'not-a-date'
Assert-True ((ConvertTo-CodexQuota -Response $invalidExpiry -ProviderName 'Relay').reason -eq 'malformed_response') 'an invalid subscription expiry must fail closed'

$invalidMonthlyStart = ($usage | ConvertTo-Json -Depth 10 -Compress) | ConvertFrom-Json
Add-Member -InputObject $invalidMonthlyStart.subscription -NotePropertyName 'monthly_window_start' -NotePropertyValue 'not-a-date' -Force
Assert-True ((ConvertTo-CodexQuota -Response $invalidMonthlyStart -ProviderName 'Relay').reason -eq 'malformed_response') 'an invalid unmetered window start must fail closed'

$overflowingWindowStart = ($usage | ConvertTo-Json -Depth 10 -Compress) | ConvertFrom-Json
$overflowingWindowStart.subscription.weekly_window_start = '9999-12-31T23:59:59Z'
Assert-True ((ConvertTo-CodexQuota -Response $overflowingWindowStart -ProviderName 'Relay').reason -eq 'malformed_response') 'a parseable window start whose reset overflows must fail closed'

$invalidPlanText = ($usage | ConvertTo-Json -Depth 10 -Compress) | ConvertFrom-Json
$invalidPlanText.planName = "bad`nplan"
Assert-True ((ConvertTo-CodexQuota -Response $invalidPlanText -ProviderName 'Relay').reason -eq 'malformed_response') 'control characters in relay text must fail closed'
Assert-True ((ConvertTo-CodexQuota -Response $usage -ProviderName ('x' * 1025)).reason -eq 'malformed_response') 'an oversized provider name must fail closed'
Assert-True ((ConvertTo-CodexQuota -Response ([pscustomobject]@{ remaining = 1; mode = ('x' * 129) }) -ProviderName 'Relay').reason -eq 'malformed_response') 'an oversized relay mode must fail before caching'

$overflowingWeeklyDate = [pscustomobject]@{
  subscription = [pscustomobject]@{
    weekly_usage_usd = 1
    weekly_limit_usd = 10
    weekly_window_start = '9999-12-31T23:59:59+00:00'
  }
}
Assert-True ((ConvertTo-CodexQuota -Response $overflowingWeeklyDate -ProviderName 'Relay').reason -eq 'malformed_response') 'an overflowing derived reset date must degrade instead of throwing'

Write-Output 'ReportData.Tests.ps1: PASS'
