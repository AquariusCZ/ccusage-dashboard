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

$codexOnlyCurrency = Resolve-DisplayCurrency `
  -ReportCurrencies @('CNY', 'CNY') `
  -StatusCurrencies @($null, [pscustomobject]@{ code = 'CNY'; rate = 7.2; symbol = 'CNY' })
Assert-Close $codexOnlyCurrency.rate 7.2 'display currency may use a valid status rate from either provider'
Assert-True ($codexOnlyCurrency.code -eq 'CNY') 'display currency must match every report'

Write-Output 'ReportData.Tests.ps1: PASS'
