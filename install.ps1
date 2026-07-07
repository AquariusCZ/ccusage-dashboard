#Requires -Version 5.1
<#
  ccusage-dashboard installer
  - checks Node.js + ccusage (installs ccusage if missing)
  - copies the program into %LOCALAPPDATA%\ClaudeUsage
  - creates a Desktop shortcut to the silent launcher
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host ""
Write-Host "  Claude Usage Dashboard - installer" -ForegroundColor Cyan
Write-Host "  ==================================="
Write-Host ""

$srcDir = Join-Path $PSScriptRoot 'src'
$dest   = Join-Path $env:LOCALAPPDATA 'ClaudeUsage'

# 1) Node.js
if (Get-Command node -ErrorAction SilentlyContinue) {
  Write-Host "  [ok] Node.js $(node -v)" -ForegroundColor Green
} else {
  Write-Host "  [!]  Node.js not found. Install the LTS from https://nodejs.org and re-run." -ForegroundColor Yellow
  Read-Host "  Press Enter to exit"; exit 1
}

# 2) ccusage
$hasCc = (Get-Command ccusage.cmd -ErrorAction SilentlyContinue) -or (Get-Command ccusage -ErrorAction SilentlyContinue)
if ($hasCc) {
  Write-Host "  [ok] ccusage present" -ForegroundColor Green
} else {
  Write-Host "  [..] installing ccusage globally (npm i -g ccusage) ..."
  npm install -g ccusage | Out-Null
  Write-Host "  [ok] ccusage installed" -ForegroundColor Green
}

# 3) copy program files
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item (Join-Path $srcDir '*') -Destination $dest -Recurse -Force
Get-ChildItem $dest -Recurse | Unblock-File -ErrorAction SilentlyContinue   # strip mark-of-the-web
Write-Host "  [ok] installed to $dest" -ForegroundColor Green

# 4) allow local scripts to run (RemoteSigned is the safe default)
try {
  $p = Get-ExecutionPolicy -Scope CurrentUser
  if ($p -in @('Restricted','Undefined','AllSigned')) {
    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
    Write-Host "  [ok] execution policy (CurrentUser) -> RemoteSigned" -ForegroundColor Green
  }
} catch {}

# 5) Desktop shortcut -> silent launcher (wscript + dashboard.vbs)
$wsh = New-Object -ComObject WScript.Shell
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude Usage Dashboard.lnk'
$sc = $wsh.CreateShortcut($lnk)
$sc.TargetPath       = Join-Path $env:SystemRoot 'System32\wscript.exe'
$sc.Arguments        = '"' + (Join-Path $dest 'dashboard.vbs') + '"'
$sc.WorkingDirectory = $dest
$sc.IconLocation     = (Join-Path $dest 'icon.ico') + ',0'
$sc.WindowStyle      = 1
$sc.Description       = 'Claude Code usage dashboard (ephemeral)'
$sc.Save()
Write-Host "  [ok] Desktop shortcut created" -ForegroundColor Green

Write-Host ""
Write-Host "  Done!  Double-click the 'Claude Usage Dashboard' shortcut to view your usage." -ForegroundColor Cyan
Write-Host "  Tip:   drag that shortcut onto the taskbar to pin it (Windows 11 blocks auto-pin)."
Write-Host ""
Read-Host "  Press Enter to finish"
