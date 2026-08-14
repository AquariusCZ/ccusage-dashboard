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

function Get-ToolVersion([string]$CommandPath) {
  $raw = (& $CommandPath '--version' 2>$null | Out-String).Trim()
  $match = [regex]::Match($raw, '\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?')
  if ($match.Success) { return $match.Value }
  return $raw
}

foreach ($tool in @(
  @{ Command = 'codeburn'; Package = 'codeburn'; Label = 'CodeBurn'; Version = '0.9.19' },
  @{ Command = 'ccusage'; Package = 'ccusage'; Label = 'ccusage'; Version = '20.0.14' }
)) {
  $resolved = Get-Command "$($tool.Command).cmd" -ErrorAction SilentlyContinue
  if (-not $resolved) { $resolved = Get-Command $tool.Command -ErrorAction SilentlyContinue }
  $installedVersion = if ($resolved -and $tool.Version) {
    Get-ToolVersion $resolved.Source
  } else { $null }
  $needsInstall = -not $resolved -or ($tool.Version -and $installedVersion -ne $tool.Version)
  if (-not $needsInstall) {
    $suffix = if ($installedVersion) { " $installedVersion" } else { '' }
    Write-Host "  [ok] $($tool.Label)$suffix present" -ForegroundColor Green
  } else {
    $package = if ($tool.Version) { "$($tool.Package)@$($tool.Version)" } else { $tool.Package }
    Write-Host "  [..] installing $package globally"
    npm install -g $package | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to install $package." }
    $verified = Get-Command "$($tool.Command).cmd" -ErrorAction SilentlyContinue
    if (-not $verified) { $verified = Get-Command $tool.Command -ErrorAction SilentlyContinue }
    if (-not $verified) { throw "$($tool.Label) was installed but is not available on PATH." }
    $verifiedVersion = Get-ToolVersion $verified.Source
    if ($tool.Version -and $verifiedVersion -ne $tool.Version) {
      throw ("{0} {1} was requested, but PATH resolves {2}." -f $tool.Label, $tool.Version, $verifiedVersion)
    }
    Write-Host "  [ok] $($tool.Label) $verifiedVersion installed" -ForegroundColor Green
  }
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item (Join-Path $srcDir '*') -Destination $dest -Recurse -Force
foreach ($name in @('Generate-ClaudeReport.ps1', 'ReportData.psm1', 'template.html', 'dashboard.bat', 'dashboard.vbs', 'icon.ico')) {
  Unblock-File -LiteralPath (Join-Path $dest $name) -ErrorAction SilentlyContinue
}
Write-Host "  [ok] installed to $dest" -ForegroundColor Green

$desktop = [Environment]::GetFolderPath('Desktop')

# The oldest shortcut name is Chinese. Windows PowerShell reads a BOM-less script
# in the system ANSI code page, so the literal would arrive as mojibake and never
# match the file on disk; the code points survive that reading intact.
$legacyChineseShortcut = 'Claude' + (-join [char[]](0x7528, 0x91CF, 0x4EEA, 0x8868, 0x76D8)) + '.lnk'

foreach ($oldName in @($legacyChineseShortcut, 'Claude Usage Dashboard.lnk', 'AI Usage Ledger.lnk')) {
  $oldShortcut = Join-Path $desktop $oldName
  if (Test-Path $oldShortcut) { Remove-Item -LiteralPath $oldShortcut -Force }
}

# Explorer caches a shortcut's icon by (icon file path + index), not by the .lnk.
# Rewriting icon.ico in place therefore keeps the OLD artwork on the desktop even
# after the shortcut is deleted and recreated, and `ie4uinit -show` does not
# reliably evict it. Publishing the icon under a content-hashed filename changes
# the cache key, so a new icon appears immediately with no cache purge and no
# shell restart. icon.ico is still written for anyone referencing it by name.
$iconHash = (Get-FileHash (Join-Path $dest 'icon.ico') -Algorithm SHA256).Hash.Substring(0, 8).ToLower()
$iconPath = Join-Path $dest "icon-$iconHash.ico"
Copy-Item (Join-Path $dest 'icon.ico') $iconPath -Force
Get-ChildItem $dest -Filter 'icon-*.ico' -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -ne "icon-$iconHash.ico" } |
  Remove-Item -Force -ErrorAction SilentlyContinue

$wsh = New-Object -ComObject WScript.Shell
$shortcutPath = Join-Path $desktop 'AI Usage.lnk'
if (Test-Path $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force }
$shortcut = $wsh.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$shortcut.Arguments = '"' + (Join-Path $dest 'dashboard.vbs') + '"'
$shortcut.WorkingDirectory = $dest
$shortcut.IconLocation = "$iconPath,0"
$shortcut.WindowStyle = 1
$shortcut.Description = 'Local Claude and Codex AI usage dashboard'
$shortcut.Save()
try {
  Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\ie4uinit.exe') -ArgumentList '-show' -WindowStyle Hidden -Wait
} catch {}
Write-Host '  [ok] Desktop shortcut created' -ForegroundColor Green

Write-Host ''
Write-Host "  Done. Double-click 'AI Usage' on the Desktop." -ForegroundColor Cyan
Write-Host ''
Read-Host '  Press Enter to finish'
