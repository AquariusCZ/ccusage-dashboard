$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

foreach ($relative in @('src\Generate-ClaudeReport.ps1', 'src\ReportData.psm1', 'tests\New-DemoSnapshot.ps1', 'install.ps1', 'uninstall.ps1')) {
  $path = Join-Path $root $relative
  $tokens = $null
  $errors = $null
  [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  if ($errors.Count) { throw "$relative has PowerShell parse errors: $($errors[0].Message)" }
}

# Windows PowerShell reads a BOM-less script in the system ANSI code page, so a
# non-ASCII literal in a .ps1 becomes mojibake before it can reach a snapshot or
# match a file on disk. All visible copy lives in template.html, which is served as
# UTF-8 HTML; a name that must stay non-ASCII is built from its code points.
foreach ($relative in @(
  'src\Generate-ClaudeReport.ps1', 'src\ReportData.psm1',
  'tests\New-DemoSnapshot.ps1', 'tests\ReportData.Tests.ps1', 'tests\Static.Tests.ps1', 'tests\Verify-Snapshot.ps1',
  'install.ps1', 'uninstall.ps1'
)) {
  $bytes = [IO.File]::ReadAllBytes((Join-Path $root $relative))
  if (@($bytes | Where-Object { $_ -gt 127 }).Count) { throw "$relative contains non-ASCII bytes; build the value from code points instead" }
}

# The legacy Chinese shortcut both scripts clean up is exactly that case, and it is
# the one name a regression would silently strand on the desktop.
$legacyShortcutLiteral = "0x7528, 0x91CF, 0x4EEA, 0x8868, 0x76D8"
foreach ($relative in @('install.ps1', 'uninstall.ps1')) {
  $text = [IO.File]::ReadAllText((Join-Path $root $relative))
  if (-not $text.Contains($legacyShortcutLiteral)) { throw "$relative no longer removes the legacy Chinese desktop shortcut" }
}

$template = [IO.File]::ReadAllText((Join-Path $root 'src\template.html'))
$installer = [IO.File]::ReadAllText((Join-Path $root 'install.ps1'))
$uninstaller = [IO.File]::ReadAllText((Join-Path $root 'uninstall.ps1'))
if (-not $installer.Contains("'ReportData.psm1'")) { throw 'The installer does not publish the reconciliation module.' }
if (-not $uninstaller.Contains("'ReportData.psm1'")) { throw 'The uninstaller does not remove the reconciliation module mirror.' }
if (-not $template.Contains('id="modelDonut"')) { throw 'The model composition chart is missing.' }
foreach ($marker in @('id="trendCap"', 'id="activityCap"', 'id="modelCap"', 'quota-src', 'quota-offline-note')) {
  if ($template.Contains($marker)) { throw "Implementation copy leaked into the dashboard: $marker" }
}
if (-not $template.Contains('function cost(p) { var o = overview(p); return n(o.cost != null ? o.cost : o.netCost); }')) {
  throw 'The UI is not using gross API reference cost as its primary total.'
}
if ($template.Contains('currency: "USD"')) { throw 'The UI still hard-codes USD formatting.' }
if (-not $template.Contains('function currencyInfo()')) { throw 'The UI is not reading the snapshot currency contract.' }

$match = [regex]::Match($template, '(?s)<script>\s*(addEventListener\("error".*)</script>\s*</body>')
if (-not $match.Success) { throw 'Could not extract the dashboard script for syntax checking.' }
$tempJs = Join-Path ([IO.Path]::GetTempPath()) ("ai-usage-static-{0}.js" -f [guid]::NewGuid().ToString('N'))
try {
  [IO.File]::WriteAllText($tempJs, $match.Groups[1].Value, (New-Object Text.UTF8Encoding($false)))
  & node --check $tempJs
  if ($LASTEXITCODE -ne 0) { throw 'Dashboard JavaScript syntax check failed.' }
} finally {
  try { if (Test-Path $tempJs) { [IO.File]::Delete($tempJs) } } catch {}
}

Write-Output 'Static.Tests.ps1: PASS'
