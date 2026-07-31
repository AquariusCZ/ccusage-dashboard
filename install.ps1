#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host ''
Write-Host '  AI Usage - installer' -ForegroundColor Cyan
Write-Host '  ==================='
Write-Host ''

$srcDir = Join-Path $PSScriptRoot 'src'
$dest = Join-Path $env:LOCALAPPDATA 'ClaudeUsage'

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Host '  [!] Node.js not found. Install the LTS release from https://nodejs.org and run this installer again.' -ForegroundColor Yellow
  Read-Host '  Press Enter to exit'
  exit 1
}
Write-Host "  [ok] Node.js $(node -v)" -ForegroundColor Green

foreach ($tool in @(
  @{ Command = 'codeburn'; Package = 'codeburn'; Label = 'CodeBurn' },
  @{ Command = 'ccusage'; Package = 'ccusage'; Label = 'ccusage' }
)) {
  $present = (Get-Command "$($tool.Command).cmd" -ErrorAction SilentlyContinue) -or (Get-Command $tool.Command -ErrorAction SilentlyContinue)
  if ($present) {
    Write-Host "  [ok] $($tool.Label) present" -ForegroundColor Green
  } else {
    Write-Host "  [..] installing $($tool.Package) globally"
    npm install -g $tool.Package | Out-Null
    Write-Host "  [ok] $($tool.Label) installed" -ForegroundColor Green
  }
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item (Join-Path $srcDir '*') -Destination $dest -Recurse -Force
foreach ($name in @('Generate-ClaudeReport.ps1', 'template.html', 'dashboard.bat', 'dashboard.vbs', 'icon.ico')) {
  Unblock-File -LiteralPath (Join-Path $dest $name) -ErrorAction SilentlyContinue
}
Write-Host "  [ok] installed to $dest" -ForegroundColor Green

try {
  $policy = Get-ExecutionPolicy -Scope CurrentUser
  if ($policy -in @('Restricted', 'Undefined', 'AllSigned')) {
    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
    Write-Host '  [ok] execution policy set to RemoteSigned for CurrentUser' -ForegroundColor Green
  }
} catch {}

$desktop = [Environment]::GetFolderPath('Desktop')
foreach ($oldName in @('Claude用量仪表盘.lnk', 'Claude Usage Dashboard.lnk', 'AI Usage Ledger.lnk')) {
  $oldShortcut = Join-Path $desktop $oldName
  if (Test-Path $oldShortcut) { Remove-Item -LiteralPath $oldShortcut -Force }
}

$wsh = New-Object -ComObject WScript.Shell
$shortcutPath = Join-Path $desktop 'AI Usage.lnk'
$shortcut = $wsh.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$shortcut.Arguments = '"' + (Join-Path $dest 'dashboard.vbs') + '"'
$shortcut.WorkingDirectory = $dest
$shortcut.IconLocation = (Join-Path $dest 'icon.ico') + ',0'
$shortcut.WindowStyle = 1
$shortcut.Description = 'Local Claude and Codex AI usage dashboard'
$shortcut.Save()
Write-Host '  [ok] Desktop shortcut created' -ForegroundColor Green

Write-Host ''
Write-Host "  Done. Double-click 'AI Usage' on the Desktop." -ForegroundColor Cyan
Write-Host ''
Read-Host '  Press Enter to finish'
