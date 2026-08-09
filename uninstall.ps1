$ErrorActionPreference = 'SilentlyContinue'
$dest = Join-Path $env:LOCALAPPDATA 'ClaudeUsage'
$desktop = [Environment]::GetFolderPath('Desktop')

foreach ($name in @('AI Usage.lnk', 'AI Usage Ledger.lnk', 'Claude Usage Dashboard.lnk', 'Claude用量仪表盘.lnk')) {
  Remove-Item -LiteralPath (Join-Path $desktop $name) -Force
}
Remove-Item -LiteralPath (Join-Path $env:TEMP 'ClaudeUsage') -Recurse -Force

if (Test-Path (Join-Path $dest '.git')) {
  foreach ($name in @('Generate-ClaudeReport.ps1', 'ReportData.psm1', 'template.html', 'dashboard.bat', 'dashboard.vbs', 'icon.ico')) {
    Remove-Item -LiteralPath (Join-Path $dest $name) -Force
  }
  Remove-Item -LiteralPath (Join-Path $dest 'fonts') -Recurse -Force
  # the content-hashed copies the installer publishes for the shortcut icon
  Get-ChildItem $dest -Filter 'icon-*.ico' | Remove-Item -Force
  Write-Host 'Removed the installed runtime copy. The Git repository was preserved.' -ForegroundColor Green
} else {
  Remove-Item -LiteralPath $dest -Recurse -Force
  Write-Host 'Removed AI Usage. Node.js, CodeBurn, and ccusage were left installed.' -ForegroundColor Green
}

Read-Host 'Press Enter'
