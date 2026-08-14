$ErrorActionPreference = 'SilentlyContinue'
$dest = Join-Path $env:LOCALAPPDATA 'ClaudeUsage'
$desktop = [Environment]::GetFolderPath('Desktop')

# The oldest shortcut name is Chinese. Windows PowerShell reads a BOM-less script
# in the system ANSI code page, so the literal would arrive as mojibake and never
# match the file on disk; the code points survive that reading intact.
$legacyChineseShortcut = 'Claude' + (-join [char[]](0x7528, 0x91CF, 0x4EEA, 0x8868, 0x76D8)) + '.lnk'

foreach ($name in @('AI Usage.lnk', 'AI Usage Ledger.lnk', 'Claude Usage Dashboard.lnk', $legacyChineseShortcut)) {
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
