$ErrorActionPreference = 'SilentlyContinue'
$dest = Join-Path $env:LOCALAPPDATA 'ClaudeUsage'
Remove-Item $dest -Recurse -Force
Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude Usage Dashboard.lnk') -Force
Remove-Item (Join-Path $env:TEMP 'ClaudeUsage') -Recurse -Force
Write-Host "Removed ccusage-dashboard. (Node.js and ccusage were left installed.)" -ForegroundColor Green
Read-Host "Press Enter"
