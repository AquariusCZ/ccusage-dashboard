$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$uninstaller = Join-Path $root 'uninstall.ps1'
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('ai-usage-uninstaller-test-[literal]-' + [guid]::NewGuid().ToString('N'))
$oldTemp = $env:TEMP
$oldTmp = $env:TMP
$oldTestRoot = $env:AI_USAGE_UNINSTALL_TEST_ROOT

function Write-Ascii([string]$Path, [string]$Value) {
  $parent = Split-Path $Path -Parent
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path, $Value, [Text.Encoding]::ASCII)
}

function New-TestJunction([string]$Path, [string]$Target) {
  & $env:ComSpec /d /q /c ('mklink /J "' + $Path + '" "' + $Target + '"') | Out-Null
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Path)) {
    throw "Could not create the test junction $Path."
  }
}

function New-HashedIcon([string]$Directory, [string]$Contents) {
  $scratch = Join-Path $Directory ([guid]::NewGuid().ToString('N') + '.ico')
  Write-Ascii $scratch $Contents
  $hash = (Get-FileHash -LiteralPath $scratch -Algorithm SHA256).Hash
  $target = Join-Path $Directory ('icon-' + $hash.Substring(0, 8).ToLowerInvariant() + '.ico')
  [IO.File]::Move($scratch, $target)
  return $target
}

function New-TestShortcut([string]$Path, [string]$Destination, [string]$IconPath) {
  $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
  $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
  $shortcut.Arguments = '"' + (Join-Path $Destination 'dashboard.vbs') + '"'
  $shortcut.IconLocation = "$IconPath,0"
  $shortcut.Save()
}

try {
  $temp = Join-Path $sandbox 'temp'
  $destination = Join-Path $sandbox 'ClaudeUsage'
  $desktop = Join-Path $sandbox 'Desktop'
  New-Item -ItemType Directory -Force -Path $temp, $destination, $desktop,
    (Join-Path $destination '.git'),
    (Join-Path $destination 'src\fonts') | Out-Null
  $env:TEMP = $temp
  $env:TMP = $temp
  $env:AI_USAGE_UNINSTALL_TEST_ROOT = $sandbox

  $tokens = $null
  $parseErrors = $null
  $uninstallerAst = [Management.Automation.Language.Parser]::ParseFile(
    $uninstaller, [ref]$tokens, [ref]$parseErrors
  )
  if ($parseErrors.Count) { throw 'Could not parse uninstaller migration helpers.' }
  $migrationFunctions = @{}
  foreach ($functionName in @(
    'Get-MigrationUsageProcessDisposition', 'Get-MigrationUsageProcesses', 'Wait-MigrationUsageProcesses'
  )) {
    $definition = $uninstallerAst.Find({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    if (-not $definition) { throw "Uninstaller helper $functionName is missing." }
    $migrationFunctions[$functionName] = $definition.Extent.Text
  }

  & {
    . ([scriptblock]::Create($migrationFunctions['Get-MigrationUsageProcessDisposition']))
    foreach ($case in @(
      @('powershell.exe', 'powershell -File .\Generate-ClaudeReport.ps1', 'Same', $true, 'Wait'),
      @('pwsh.exe', 'pwsh -File src/Generate-ClaudeReport.ps1', 'Same', $true, 'Wait'),
      @('powershell.exe', 'powershell -File NotGenerate-ClaudeReport.ps1', 'Same', $true, 'Ignore'),
      @('cmd.exe', 'cmd /c codeburn.cmd report', 'Unknown', $true, 'Wait'),
      @('cmd.exe', 'cmd /c ccusage.cmd blocks', 'Unknown', $true, 'Wait'),
      @('node.exe', 'node C:\npm\node_modules\ccusage\dist\index.js', 'Same', $true, 'Wait'),
      @('codeburn.exe', '', 'Same', $true, 'Wait'),
      @('codeburn.exe', '', 'Other', $true, 'Ignore'),
      @('codeburn.exe', '', 'Unknown', $true, 'Wait'),
      @('codeburn.exe', '', 'Unknown', $false, 'Ignore'),
      @('ccusage.exe', '', 'Same', $true, 'Wait'),
      @('ccusage.exe', '', 'Other', $true, 'Ignore'),
      @('ccusage.exe', '', 'Unknown', $true, 'Wait'),
      @('ccusage.exe', '', 'Unknown', $false, 'Ignore'),
      @('pwsh.exe', '', 'Same', $true, 'Wait'),
      @('pwsh.exe', '', 'Other', $true, 'Ignore'),
      @('pwsh.exe', '', 'Unknown', $true, 'Ignore'),
      @('pwsh.exe', 'pwsh -File unrelated.ps1', 'Same', $true, 'Ignore')
    )) {
      $actual = Get-MigrationUsageProcessDisposition $case[0] $case[1] $case[2] $case[3]
      if ($actual -ne $case[4]) {
        throw "Uninstaller migration disposition was $actual instead of $($case[4]) for $($case[1])."
      }
    }
  }

  & {
    . ([scriptblock]::Create($migrationFunctions['Get-MigrationUsageProcessDisposition']))
    . ([scriptblock]::Create($migrationFunctions['Get-MigrationUsageProcesses']))
    $testSid = 'S-1-5-21-424242'
    function Get-CimInstance {
      [CmdletBinding()]
      param([string]$ClassName)
      return @(
        [pscustomobject]@{ ProcessId = 424241; Name = 'pwsh.exe'; CommandLine = $null; SessionId = 0 },
        [pscustomobject]@{ ProcessId = 424242; Name = 'pwsh.exe'; CommandLine = $null; SessionId = 0 },
        [pscustomobject]@{ ProcessId = 424243; Name = 'ccusage.exe'; CommandLine = $null; SessionId = 0 },
        [pscustomobject]@{ ProcessId = 424244; Name = 'ccusage.exe'; CommandLine = $null; SessionId = 0 },
        [pscustomobject]@{ ProcessId = 424245; Name = 'svchost.exe'; CommandLine = $null; SessionId = 0 }
      )
    }
    $script:uninstallOwnerQueries = 0
    function Invoke-CimMethod {
      [CmdletBinding()]
      param($InputObject, [string]$MethodName, [int]$OperationTimeoutSec)
      $script:uninstallOwnerQueries += 1
      if ($InputObject.ProcessId -eq 424241) { return [pscustomobject]@{ ReturnValue = 0; Sid = $testSid } }
      if ($InputObject.ProcessId -eq 424242) { return [pscustomobject]@{ ReturnValue = 0; Sid = 'S-1-5-18' } }
      throw 'owner unavailable'
    }
    function Get-Process {
      [CmdletBinding()]
      param([int]$Id)
      if ($Id -eq 424243) { return [pscustomobject]@{ Id = $Id } }
      return $null
    }
    $matches = @(Get-MigrationUsageProcesses $testSid)
    if ($matches.Count -ne 2 -or
        @($matches | ForEach-Object ProcessId) -join ',' -ne '424241,424243' -or
        $matches[0].OwnerState -ne 'Same' -or $matches[1].OwnerState -ne 'Unknown' -or
        $script:uninstallOwnerQueries -ne 4) {
      throw 'The uninstaller Session 0 scan did not enforce Same/Other/Unknown ownership policy.'
    }
  }

  & {
    . ([scriptblock]::Create($migrationFunctions['Wait-MigrationUsageProcesses']))
    $script:uninstallMigrationScans = 0
    function Get-MigrationUsageProcesses {
      param([string]$UserSid)
      $script:uninstallMigrationScans += 1
      if ($script:uninstallMigrationScans -eq 1) {
        return [pscustomobject]@{
          ProcessId = 424243; Name = 'ccusage.exe'; SessionId = 0; OwnerState = 'Unknown'
        }
      }
      return @()
    }
    function Start-Sleep { param([int]$Milliseconds) }
    Wait-MigrationUsageProcesses 'S-1-5-21-424242'
    if ($script:uninstallMigrationScans -ne 3) {
      throw 'Uninstaller migration cleanup did not require two stable empty scans after ccusage.'
    }
  }

  $reparseTarget = Join-Path $sandbox 'junction-target'
  $reparseSentinel = Join-Path $reparseTarget 'sentinel.txt'
  New-Item -ItemType Directory -Force -Path $reparseTarget | Out-Null
  Write-Ascii $reparseSentinel 'outside managed destination'
  Write-Ascii (Join-Path $destination 'src\fonts\font.woff2') 'source font'
  $reparseLink = Join-Path $destination 'fonts'
  New-TestJunction $reparseLink $reparseTarget
  $savedErrorAction = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $reparseOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstaller -NoPrompt 2>&1
    $reparseExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $savedErrorAction
  }
  if ($reparseExitCode -eq 0 -or ($reparseOutput -join "`n") -notmatch 'reparse') {
    throw "The uninstaller accepted a reparse point in a managed path: $($reparseOutput -join ' ')"
  }
  if ([IO.File]::ReadAllText($reparseSentinel) -cne 'outside managed destination' -or
      @(Get-ChildItem -LiteralPath $reparseTarget -Force).Count -ne 1 -or
      (Test-Path -LiteralPath (Join-Path $destination '.install-pending'))) {
    throw 'The rejected reparse-point uninstall changed its target or transaction state.'
  }
  [IO.Directory]::Delete($reparseLink, $false)
  [IO.Directory]::Delete($destination, $true)
  New-Item -ItemType Directory -Force -Path $destination,
    (Join-Path $destination '.git'), (Join-Path $destination 'fonts'),
    (Join-Path $destination 'src\fonts') | Out-Null

  foreach ($name in @('Generate-ClaudeReport.ps1', 'ReportData.psm1', 'template.html', 'dashboard.bat', 'dashboard.vbs')) {
    Write-Ascii (Join-Path $destination $name) 'managed runtime'
    Write-Ascii (Join-Path (Join-Path $destination 'src') $name) 'source runtime'
  }
  Write-Ascii (Join-Path $destination 'fonts\font.woff2') 'managed font'
  Write-Ascii (Join-Path $destination 'src\fonts\font.woff2') 'source font'
  Write-Ascii (Join-Path $destination 'extra-managed.txt') 'managed from source inventory'
  Write-Ascii (Join-Path $destination 'src\extra-managed.txt') 'source inventory extension'
  Write-Ascii (Join-Path $destination 'repository-sentinel.txt') 'keep'
  $legacyFixedBackupSentinel = Join-Path $destination '.Generate-ClaudeReport.ps1.uninstall-backup'
  Write-Ascii $legacyFixedBackupSentinel 'unowned fixed-name sentinel'

  $sourceIcon = Join-Path $destination 'icon.ico'
  Write-Ascii $sourceIcon 'current managed icon'
  $currentHash = (Get-FileHash -LiteralPath $sourceIcon -Algorithm SHA256).Hash
  $currentHashedIcon = Join-Path $destination ('icon-' + $currentHash.Substring(0, 8).ToLowerInvariant() + '.ico')
  [IO.File]::Copy($sourceIcon, $currentHashedIcon)
  $shortcutOwnedIcon = New-HashedIcon $destination 'previous managed icon'
  $unreferencedHashedIcon = New-HashedIcon $destination 'user content-addressed icon'
  $unrelatedIcon = Join-Path $destination 'icon-cafebabe.ico'
  Write-Ascii $unrelatedIcon 'unrelated user icon'

  $shortcutPath = Join-Path $desktop 'AI Usage.lnk'
  New-TestShortcut $shortcutPath $destination $shortcutOwnedIcon

  Write-Ascii (Join-Path $destination '.install-pending') "transaction=interrupted`r`nstage=pending`r`n"
  $pendingPath = Join-Path $destination '.install-pending'
  $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

  # The install mutex must serialize uninstall, and a failed gate publication must
  # fail closed with a recovery marker instead of claiming success.
  $lockedRuntimePath = Join-Path $destination 'Generate-ClaudeReport.ps1'
  $runtimeLock = [IO.File]::Open($lockedRuntimePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
  $installProbe = [Threading.Mutex]::new($false, "Global\AIUsage-Install-$userSid")
  $installProbeHeld = $false
  $failureProcess = $null
  try {
    try { $installProbeHeld = $installProbe.WaitOne([TimeSpan]::FromMinutes(5)) }
    catch [Threading.AbandonedMutexException] { $installProbeHeld = $true }
    if (-not $installProbeHeld) { throw 'Could not acquire the install mutex for the uninstaller wait test.' }

    $failureInfo = New-Object Diagnostics.ProcessStartInfo
    $failureInfo.FileName = 'powershell.exe'
    $failureInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $uninstaller + '" -NoPrompt'
    $failureInfo.UseShellExecute = $false
    $failureInfo.CreateNoWindow = $true
    $failureInfo.RedirectStandardOutput = $true
    $failureInfo.RedirectStandardError = $true
    $failureProcess = New-Object Diagnostics.Process
    $failureProcess.StartInfo = $failureInfo
    if (-not $failureProcess.Start()) { throw 'Could not start the uninstaller failure test.' }
    Start-Sleep -Milliseconds 500
    $failureProcess.Refresh()
    if ($failureProcess.HasExited -or
        [IO.File]::ReadAllText($pendingPath) -notmatch '(?m)^transaction=interrupted\r?$' -or
        -not (Test-Path -LiteralPath $shortcutPath)) {
      throw 'The uninstaller did not wait on the install mutex before publishing or deleting.'
    }
    $installProbe.ReleaseMutex()
    $installProbeHeld = $false

    if (-not $failureProcess.WaitForExit(30000)) { throw 'The uninstaller did not finish after a managed-file deletion failed.' }
    $failureProcess.WaitForExit()
    $failureResult = $failureProcess.StandardOutput.ReadToEnd() + $failureProcess.StandardError.ReadToEnd()
    if ($failureProcess.ExitCode -eq 0) { throw 'The uninstaller reported success after a managed-file deletion failed.' }
    if ($failureResult -match '(?m)^Removed (?:AI Usage|the installed runtime copy)') {
      throw 'The uninstaller printed a success message after a managed-file deletion failed.'
    }
    if (-not (Test-Path -LiteralPath $pendingPath) -or
        [IO.File]::ReadAllText($pendingPath) -notmatch '(?m)^stage=failed\r?$') {
      throw 'The uninstaller did not retain a failed transaction marker after a deletion error.'
    }
    if (-not (Test-Path -LiteralPath $lockedRuntimePath)) {
      throw 'The locked managed runtime unexpectedly disappeared during the failure test.'
    }
    if ($failureResult -notmatch 'Generate-ClaudeReport\.ps1') {
      throw 'The failure test did not reach the locked generator gate publication.'
    }
  } finally {
    if ($installProbeHeld) { try { $installProbe.ReleaseMutex() } catch {} }
    try { $installProbe.Dispose() } catch {}
    if ($failureProcess -and -not $failureProcess.HasExited) { try { Stop-Process -Id $failureProcess.Id -Force } catch {} }
    if ($failureProcess) { try { $failureProcess.Dispose() } catch {} }
    try { $runtimeLock.Dispose() } catch {}
  }

  # Rewriting the existing shortcut keeps the ownership setup explicit for success.
  New-TestShortcut $shortcutPath $destination $shortcutOwnedIcon

  $drainDirectory = Join-Path $sandbox 'drain'
  $drainScript = Join-Path $drainDirectory 'Generate-ClaudeReport.ps1'
  $drainReady = Join-Path $drainDirectory 'ready'
  $drainRelease = Join-Path $drainDirectory 'release'
  Write-Ascii $drainScript @'
param([string]$ReadyPath, [string]$ReleasePath)
[IO.File]::WriteAllText($ReadyPath, 'ready', [Text.Encoding]::ASCII)
while (-not (Test-Path -LiteralPath $ReleasePath)) { Start-Sleep -Milliseconds 20 }
'@

  $reportMutex = [Threading.Mutex]::new($false, "Global\AIUsage-CodeBurn-$userSid")
  $reportMutexHeld = $false
  $legacyMutex = [Threading.Mutex]::new($false, 'Local\AIUsage-CodeBurn')
  $legacyMutexHeld = $false
  $process = $null
  $drainProcess = $null
  try {
    try { $reportMutexHeld = $reportMutex.WaitOne([TimeSpan]::FromMinutes(5)) }
    catch [Threading.AbandonedMutexException] { $reportMutexHeld = $true }
    if (-not $reportMutexHeld) { throw 'Could not acquire the report mutex for the uninstaller wait test.' }
    try { $legacyMutexHeld = $legacyMutex.WaitOne([TimeSpan]::FromMinutes(5)) }
    catch [Threading.AbandonedMutexException] { $legacyMutexHeld = $true }
    if (-not $legacyMutexHeld) { throw 'Could not acquire the legacy mutex for the uninstaller wait test.' }

    $drainInfo = New-Object Diagnostics.ProcessStartInfo
    $drainInfo.FileName = 'powershell.exe'
    $drainInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $drainScript +
      '" -ReadyPath "' + $drainReady + '" -ReleasePath "' + $drainRelease + '"'
    $drainInfo.UseShellExecute = $false
    $drainInfo.CreateNoWindow = $true
    $drainProcess = New-Object Diagnostics.Process
    $drainProcess.StartInfo = $drainInfo
    if (-not $drainProcess.Start()) { throw 'Could not start the legacy report drain test.' }
    $drainDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $drainDeadline -and -not (Test-Path -LiteralPath $drainReady)) {
      Start-Sleep -Milliseconds 20
    }
    if (-not (Test-Path -LiteralPath $drainReady)) { throw 'The legacy report drain helper did not become ready.' }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $uninstaller + '" -NoPrompt'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Could not start the uninstaller wait test.' }

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $pendingText = ''
    while ([DateTime]::UtcNow -lt $deadline) {
      try { $pendingText = [IO.File]::ReadAllText($pendingPath) } catch { $pendingText = '' }
      if ($pendingText -match '(?m)^transaction=uninstall-' -and $pendingText -match '(?m)^stage=pending\r?$') { break }
      Start-Sleep -Milliseconds 20
    }
    $process.Refresh()
    if ($process.HasExited -or -not (Test-Path -LiteralPath (Join-Path $destination 'dashboard.vbs')) -or
        $pendingText -notmatch '(?m)^transaction=uninstall-' -or $pendingText -notmatch '(?m)^stage=pending\r?$') {
      throw 'The uninstaller did not publish its marker and wait for the legacy report process.'
    }
    $gatePublished = $false
    $gateDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $gateDeadline -and -not $gatePublished) {
      try { $gatePublished = [IO.File]::ReadAllText($lockedRuntimePath) -match 'AI Usage uninstall is in progress' }
      catch { $gatePublished = $false }
      if (-not $gatePublished) { Start-Sleep -Milliseconds 20 }
    }
    if (-not $gatePublished) {
      throw 'The uninstaller did not publish its launch gate before draining legacy processes.'
    }
    Write-Ascii $drainRelease 'release'
    if (-not $drainProcess.WaitForExit(10000)) { throw 'The legacy report drain helper did not finish after release.' }
    Start-Sleep -Milliseconds 500
    $process.Refresh()
    if ($process.HasExited -or -not (Test-Path -LiteralPath (Join-Path $destination 'dashboard.vbs'))) {
      throw 'The uninstaller did not wait for the Global report mutex after draining the legacy process.'
    }

    # This launch occurs after the old-process drain. The canonical gate must
    # still reject it while the uninstaller is blocked on the Global mutex.
    $savedErrorAction = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $gateOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lockedRuntimePath 2>&1
      $gateExitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $savedErrorAction
    }
    if ($gateExitCode -eq 0 -or ($gateOutput -join "`n") -notmatch 'uninstall is in progress') {
      throw 'The published uninstall gate allowed a late supported generator launch.'
    }

    # Force a failure after the gate and first managed deletion have committed.
    $deletionTarget = Join-Path $destination 'ReportData.psm1'
    $deletionLock = [IO.File]::Open($deletionTarget, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)

    $reportMutex.ReleaseMutex()
    $reportMutexHeld = $false
    Start-Sleep -Milliseconds 500
    $process.Refresh()
    if ($process.HasExited -or -not (Test-Path -LiteralPath (Join-Path $destination 'dashboard.vbs'))) {
      throw 'The uninstaller did not wait for the Local report mutex after releasing Global.'
    }
    $legacyMutex.ReleaseMutex()
    $legacyMutexHeld = $false
    if (-not $process.WaitForExit(30000)) { throw 'The uninstaller did not finish after both report locks were released.' }
    $process.WaitForExit()
    $result = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
    if ($process.ExitCode -eq 0) { throw 'The uninstaller reported success after a managed deletion failed.' }
    if ($result -match '(?m)^Removed (?:AI Usage|the installed runtime copy)') {
      throw 'The uninstaller printed a success message after a partial managed deletion.'
    }
    if ($result -notmatch 'ReportData\.psm1') { throw 'The partial deletion test did not reach its locked target.' }
    if (-not (Test-Path -LiteralPath $pendingPath) -or
        [IO.File]::ReadAllText($pendingPath) -notmatch '(?m)^stage=failed\r?$') {
      throw 'The uninstaller did not retain a failed marker after a partial deletion.'
    }
    if (Test-Path -LiteralPath $lockedRuntimePath) {
      throw 'The partial deletion test did not remove the generator before reaching the locked module.'
    }
    if (-not (Test-Path -LiteralPath $deletionTarget)) {
      throw 'The locked module disappeared during the partial deletion test.'
    }
    if (-not (Test-Path -LiteralPath $shortcutPath)) {
      throw 'The partial deletion removed the shortcut that proves old icon ownership for retry.'
    }
  } finally {
    if ($deletionLock) { try { $deletionLock.Dispose() } catch {} }
    if ($legacyMutexHeld) { try { $legacyMutex.ReleaseMutex() } catch {} }
    if ($reportMutexHeld) { try { $reportMutex.ReleaseMutex() } catch {} }
    try { $legacyMutex.Dispose() } catch {}
    try { $reportMutex.Dispose() } catch {}
    if ($drainProcess -and -not $drainProcess.HasExited) { try { Stop-Process -Id $drainProcess.Id -Force } catch {} }
    if ($drainProcess) { try { $drainProcess.Dispose() } catch {} }
    if ($process -and -not $process.HasExited) { try { Stop-Process -Id $process.Id -Force } catch {} }
    if ($process) { try { $process.Dispose() } catch {} }
  }

  # Retry the deliberately partial state without reconstructing runtime or ownership evidence.
  $result = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstaller -NoPrompt 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Repository uninstaller retry failed: $result" }

  foreach ($removed in @(
    'Generate-ClaudeReport.ps1', 'ReportData.psm1', 'template.html', 'dashboard.bat',
    'dashboard.vbs', 'extra-managed.txt', 'icon.ico', 'fonts'
  )) {
    if (Test-Path -LiteralPath (Join-Path $destination $removed)) {
      throw "Uninstaller retained managed runtime path $removed."
    }
  }
  foreach ($removedPath in @($shortcutPath, $currentHashedIcon, $shortcutOwnedIcon)) {
    if (Test-Path -LiteralPath $removedPath) { throw "Uninstaller retained owned path $removedPath." }
  }
  if (Test-Path -LiteralPath (Join-Path $destination '.install-pending')) {
    throw 'Repository uninstallation retained a stale installation marker.'
  }
  foreach ($preservedPath in @(
    (Join-Path $destination '.git'), (Join-Path $destination 'repository-sentinel.txt'),
    $unrelatedIcon, $unreferencedHashedIcon, $legacyFixedBackupSentinel
  )) {
    if (-not (Test-Path -LiteralPath $preservedPath)) { throw "Uninstaller removed unowned path $preservedPath." }
  }

  # Recreate a repository install and fail while deleting the second/current
  # hashed icon. The source icon must remain as retry ownership evidence after
  # the shortcut-owned previous icon has already been removed.
  New-Item -ItemType Directory -Force -Path (Join-Path $destination 'fonts') | Out-Null
  foreach ($name in @('Generate-ClaudeReport.ps1', 'ReportData.psm1', 'template.html', 'dashboard.bat', 'dashboard.vbs')) {
    Write-Ascii (Join-Path $destination $name) 'managed runtime'
  }
  Write-Ascii (Join-Path $destination 'fonts\font.woff2') 'managed font'
  Write-Ascii $sourceIcon 'retry current managed icon'
  $currentHash = (Get-FileHash -LiteralPath $sourceIcon -Algorithm SHA256).Hash
  $currentHashedIcon = Join-Path $destination ('icon-' + $currentHash.Substring(0, 8).ToLowerInvariant() + '.ico')
  [IO.File]::Copy($sourceIcon, $currentHashedIcon)
  $shortcutOwnedIcon = New-HashedIcon $destination 'retry previous managed icon'
  New-TestShortcut $shortcutPath $destination $shortcutOwnedIcon

  # Permit the uninstaller's ownership hash read while denying deletion.
  $iconLock = [IO.File]::Open($currentHashedIcon, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    $savedErrorAction = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $result = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstaller -NoPrompt 2>&1
      $iconExitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $savedErrorAction
    }
    if ($iconExitCode -eq 0) {
      throw ('The uninstaller reported success while the current hashed icon was locked. ' +
        "source=$(Test-Path -LiteralPath $sourceIcon) current=$(Test-Path -LiteralPath $currentHashedIcon) " +
        "shortcut=$(Test-Path -LiteralPath $shortcutPath) output=$($result -join ' ')")
    }
    if ($result -match '(?m)^Removed (?:AI Usage|the installed runtime copy)') {
      throw 'The icon deletion failure printed an uninstall success message.'
    }
    if (-not (Test-Path -LiteralPath $sourceIcon) -or
        -not (Test-Path -LiteralPath $currentHashedIcon) -or
        -not (Test-Path -LiteralPath $shortcutPath)) {
      throw 'The icon deletion failure discarded ownership evidence required for retry.'
    }
    if (Test-Path -LiteralPath $shortcutOwnedIcon) {
      throw 'The icon deletion failure did not reach the second/current hashed icon.'
    }
    if (-not (Test-Path -LiteralPath $pendingPath) -or
        [IO.File]::ReadAllText($pendingPath) -notmatch '(?m)^stage=failed\r?$') {
      throw 'The icon deletion failure did not retain a failed transaction marker.'
    }
  } finally {
    $iconLock.Dispose()
  }

  $result = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstaller -NoPrompt 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Repository icon-deletion retry failed: $result" }
  foreach ($removedPath in @($sourceIcon, $currentHashedIcon, $shortcutPath, $pendingPath)) {
    if (Test-Path -LiteralPath $removedPath) { throw "Uninstaller retry retained owned path $removedPath." }
  }
  foreach ($preservedPath in @($unrelatedIcon, $unreferencedHashedIcon)) {
    if (-not (Test-Path -LiteralPath $preservedPath)) { throw "Uninstaller retry removed unowned path $preservedPath." }
  }

  $interruptedUninstallId = '42424242424242424242424242424242'
  $interruptedGateTemp = Join-Path $destination ('.Generate-ClaudeReport.ps1.uninstall-' + $interruptedUninstallId + '.tmp')
  $interruptedGateBackup = Join-Path $destination ('.Generate-ClaudeReport.ps1.uninstall-' + $interruptedUninstallId + '.bak')
  Write-Ascii $pendingPath ("transaction=uninstall-$interruptedUninstallId`r`nownerPid=424242`r`nownerStartUtcTicks=1`r`nstage=pending`r`n")
  Write-Ascii $interruptedGateTemp 'interrupted gate temporary'
  Write-Ascii $interruptedGateBackup 'interrupted gate backup'
  $residueMutex = [Threading.Mutex]::new($false, "Global\AIUsage-CodeBurn-$userSid")
  $residueMutexHeld = $false
  $interruptedProcess = $null
  try {
    try { $residueMutexHeld = $residueMutex.WaitOne([TimeSpan]::FromMinutes(5)) }
    catch [Threading.AbandonedMutexException] { $residueMutexHeld = $true }
    if (-not $residueMutexHeld) { throw 'Could not acquire the report mutex for interrupted residue recovery.' }

    $interruptedInfo = New-Object Diagnostics.ProcessStartInfo
    $interruptedInfo.FileName = 'powershell.exe'
    $interruptedInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $uninstaller + '" -NoPrompt'
    $interruptedInfo.UseShellExecute = $false
    $interruptedInfo.CreateNoWindow = $true
    $interruptedInfo.RedirectStandardOutput = $true
    $interruptedInfo.RedirectStandardError = $true
    $interruptedProcess = New-Object Diagnostics.Process
    $interruptedProcess.StartInfo = $interruptedInfo
    if (-not $interruptedProcess.Start()) { throw 'Could not start interrupted residue recovery.' }

    $residueDeadline = [DateTime]::UtcNow.AddSeconds(10)
    $replacementMarker = ''
    $replacementTransactionId = $null
    while ([DateTime]::UtcNow -lt $residueDeadline) {
      try { $replacementMarker = [IO.File]::ReadAllText($pendingPath) } catch { $replacementMarker = '' }
      $replacementMatch = [regex]::Match(
        $replacementMarker,
        ("^transaction=uninstall-([0-9a-f]{{32}})`r?`nownerPid={0}`r?`nownerStartUtcTicks=\d+`r?`nstage=pending" -f $interruptedProcess.Id)
      )
      if ($replacementMatch.Success) {
        $replacementTransactionId = $replacementMatch.Groups[1].Value
        break
      }
      if ($interruptedProcess.HasExited) { break }
      Start-Sleep -Milliseconds 20
    }
    if ($interruptedProcess.HasExited -or -not $replacementTransactionId) {
      throw 'Interrupted residue recovery did not replace the marker before waiting on the report mutex.'
    }
    foreach ($removedPath in @($interruptedGateTemp, $interruptedGateBackup)) {
      if (Test-Path -LiteralPath $removedPath) {
        throw "Interrupted residue recovery replaced its marker before removing old owned residue: $removedPath"
      }
    }

    Stop-Process -Id $interruptedProcess.Id -Force
    if (-not $interruptedProcess.WaitForExit(10000)) { throw 'Force-terminated residue recovery did not exit.' }
    if (-not (Test-Path -LiteralPath $pendingPath) -or
        [IO.File]::ReadAllText($pendingPath) -notmatch ("^transaction=uninstall-{0}`r?`n" -f $replacementTransactionId)) {
      throw 'Force-terminated residue recovery lost its replacement ownership marker.'
    }
  } finally {
    if ($interruptedProcess -and -not $interruptedProcess.HasExited) {
      try { Stop-Process -Id $interruptedProcess.Id -Force } catch {}
    }
    if ($interruptedProcess) { try { $interruptedProcess.Dispose() } catch {} }
    if ($residueMutexHeld) { try { $residueMutex.ReleaseMutex() } catch {} }
    try { $residueMutex.Dispose() } catch {}
  }

  $result = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstaller -NoPrompt 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Interrupted uninstall residue recovery failed: $result" }
  foreach ($removedPath in @($pendingPath, $interruptedGateTemp, $interruptedGateBackup)) {
    if (Test-Path -LiteralPath $removedPath) { throw "Uninstaller retained owned gate residue $removedPath." }
  }

  [IO.Directory]::Delete((Join-Path $destination '.git'), $true)
  $result = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstaller -NoPrompt 2>&1
  if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $destination)) {
    throw "Standalone uninstaller did not remove its explicit runtime directory: $result"
  }

  Write-Output 'Uninstaller.Integration.Tests.ps1: PASS'
} finally {
  $env:TEMP = $oldTemp
  $env:TMP = $oldTmp
  $env:AI_USAGE_UNINSTALL_TEST_ROOT = $oldTestRoot
  try {
    $resolved = [IO.Path]::GetFullPath($sandbox)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved).StartsWith('ai-usage-uninstaller-test-', [StringComparison]::Ordinal)) {
      if (Test-Path -LiteralPath $resolved) { [IO.Directory]::Delete($resolved, $true) }
    }
  } catch {}
}
