param(
  [switch]$NoPrompt
)
$ErrorActionPreference = 'Stop'
$dest = Join-Path $env:LOCALAPPDATA 'ClaudeUsage'
$desktop = [Environment]::GetFolderPath('Desktop')
$uninstallGateContents = "throw 'AI Usage uninstall is in progress. Run install.ps1 to recover an interrupted uninstall.'`r`n"
$uninstallTransactionId = [guid]::NewGuid().ToString('N')
$uninstallOwnerStartUtcTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
$isolatedUninstallTest = $false
if (-not [string]::IsNullOrWhiteSpace($env:AI_USAGE_UNINSTALL_TEST_ROOT)) {
  $testRoot = [IO.Path]::GetFullPath($env:AI_USAGE_UNINSTALL_TEST_ROOT)
  $expectedRoot = [IO.Path]::GetFullPath((Split-Path $env:TEMP -Parent))
  if (-not $testRoot.Equals($expectedRoot, [StringComparison]::OrdinalIgnoreCase) -or
      -not [IO.Path]::GetFileName($testRoot).StartsWith('ai-usage-uninstaller-test-', [StringComparison]::Ordinal)) {
    throw 'Refusing an unsafe uninstaller test root.'
  }
  $dest = Join-Path $testRoot 'ClaudeUsage'
  $desktop = Join-Path $testRoot 'Desktop'
  $isolatedUninstallTest = $true
}

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
  $currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
  if ($currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and
      -not $isolatedUninstallTest) {
    throw 'AI Usage is a per-user install. Run uninstall.ps1 without administrator elevation.'
  }
} finally {
  $currentIdentity.Dispose()
}

function Get-ContentAddressedIcon([string]$Path) {
  try {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $resolved = [IO.Path]::GetFullPath($Path)
    $expectedParent = [IO.Path]::GetFullPath($dest).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not [IO.Path]::GetDirectoryName($resolved).Equals($expectedParent, [StringComparison]::OrdinalIgnoreCase)) {
      return $null
    }
    $match = [regex]::Match([IO.Path]::GetFileName($resolved), '^icon-([0-9a-fA-F]{8})\.ico$')
    if (-not $match.Success) { return $null }
    $prefix = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.Substring(0, 8)
    if ($prefix -cne $match.Groups[1].Value.ToUpperInvariant()) { return $null }
    return $resolved
  } catch {
    return $null
  }
}

function Get-ExistingPathEntry([string]$Path) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  if (Test-Path -LiteralPath $fullPath) {
    return Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
  }
  $parent = [IO.Directory]::GetParent($fullPath)
  if (-not $parent -or -not (Test-Path -LiteralPath $parent.FullName -PathType Container)) { return $null }
  $leafName = [IO.Path]::GetFileName($fullPath)
  return @(Get-ChildItem -LiteralPath $parent.FullName -Force -ErrorAction Stop | Where-Object {
    $_.Name.Equals($leafName, [StringComparison]::OrdinalIgnoreCase)
  } | Select-Object -First 1)[0]
}

function Assert-NoReparsePath([string]$Path) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  $rootPath = [IO.Path]::GetPathRoot($fullPath)
  if ([string]::IsNullOrWhiteSpace($rootPath)) { throw "Path has no filesystem root: $Path" }
  $current = $fullPath
  while ($current) {
    $item = Get-ExistingPathEntry $current
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Refusing a reparse-point path: $current"
    }
    if ($current.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Equals(
        $rootPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
        [StringComparison]::OrdinalIgnoreCase)) { break }
    $parent = [IO.Directory]::GetParent($current)
    if (-not $parent) { throw "Could not validate the filesystem path: $Path" }
    $current = $parent.FullName
  }
}

function Assert-NoReparseTree([string]$Path) {
  Assert-NoReparsePath $Path
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
  $pending = New-Object Collections.Generic.Stack[string]
  $pending.Push([IO.Path]::GetFullPath($Path))
  while ($pending.Count) {
    $directory = $pending.Pop()
    foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing a reparse point below a managed path: $($item.FullName)"
      }
      if ($item.PSIsContainer) { $pending.Push($item.FullName) }
    }
  }
}

function Get-UninstallMarker([ValidateSet('pending', 'failed')][string]$Stage) {
  return "transaction=uninstall-$uninstallTransactionId`r`nownerPid=$PID`r`nownerStartUtcTicks=$uninstallOwnerStartUtcTicks`r`nstage=$Stage`r`n"
}

function Get-MigrationUsageProcessDisposition(
  [string]$Name,
  [string]$CommandLine,
  [ValidateSet('Same', 'Other', 'Unknown')][string]$OwnerState,
  [bool]$StillRunning
) {
  if ($Name -notin @('powershell.exe', 'pwsh.exe', 'cmd.exe', 'node.exe', 'codeburn.exe', 'ccusage.exe')) { return 'Ignore' }
  $hasCommandLine = -not [string]::IsNullOrWhiteSpace($CommandLine)
  $isExactCollector = $Name -in @('codeburn.exe', 'ccusage.exe')
  if ($hasCommandLine) {
    $isGenerator = $Name -in @('powershell.exe', 'pwsh.exe') -and
      $CommandLine -match '(?i)(?:^|[\\/\s''"])Generate-ClaudeReport\.ps1(?=$|[\s''"])'
    $isCollector = ($Name -eq 'cmd.exe' -and $CommandLine -match '(?i)(?:^|[\\/"\s])(?:codeburn|ccusage)\.cmd(?:["\s]|$)') -or
      ($Name -eq 'node.exe' -and $CommandLine -match '(?i)[\\/]node_modules[\\/](?:codeburn|ccusage)[\\/]') -or
      $isExactCollector
    if (-not $isGenerator -and -not $isCollector) { return 'Ignore' }
  } elseif (-not $isExactCollector -and $OwnerState -eq 'Unknown') {
    return 'Ignore'
  }
  if ($OwnerState -eq 'Other') { return 'Ignore' }
  if ($OwnerState -eq 'Same') { return 'Wait' }
  if (-not $hasCommandLine -and -not $isExactCollector) { return 'Ignore' }
  return $(if ($StillRunning) { 'Wait' } else { 'Ignore' })
}

function Get-MigrationUsageProcesses([string]$UserSid) {
  $matches = @()
  foreach ($process in @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)) {
    if ([int]$process.ProcessId -eq $PID) { continue }
    $name = [string]$process.Name
    $commandLine = [string]$process.CommandLine
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
      if ($name -notin @('powershell.exe', 'pwsh.exe', 'cmd.exe', 'node.exe', 'codeburn.exe', 'ccusage.exe')) { continue }
    } elseif (
        (Get-MigrationUsageProcessDisposition $name $commandLine 'Unknown' $true) -eq 'Ignore') { continue }
    $ownerState = 'Unknown'
    try {
      $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -OperationTimeoutSec 2 -ErrorAction Stop
      if ([int]$owner.ReturnValue -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$owner.Sid)) {
        $ownerState = if ([string]$owner.Sid -eq $UserSid) { 'Same' } else { 'Other' }
      }
    } catch {}
    $stillRunning = $true
    if ($ownerState -eq 'Unknown') {
      $stillRunning = $null -ne (Get-Process -Id ([int]$process.ProcessId) -ErrorAction SilentlyContinue)
    }
    if ((Get-MigrationUsageProcessDisposition $name $commandLine $ownerState $stillRunning) -eq 'Wait') {
      $matches += [pscustomobject]@{
        ProcessId = [int]$process.ProcessId
        Name = $name
        SessionId = [int]$process.SessionId
        OwnerState = $ownerState
        Reason = if ([string]::IsNullOrWhiteSpace($commandLine)) { 'unreadable command line' } else { 'managed usage process' }
      }
    }
  }
  return $matches
}

function Wait-MigrationUsageProcesses([string]$UserSid) {
  $deadline = [DateTime]::UtcNow.AddMinutes(5)
  $emptyScans = 0
  $active = @()
  while ([DateTime]::UtcNow -lt $deadline) {
    $active = @(Get-MigrationUsageProcesses $UserSid)
    if (-not $active.Count) {
      $emptyScans += 1
      if ($emptyScans -ge 2) { return }
    } else {
      $emptyScans = 0
    }
    Start-Sleep -Milliseconds 200
  }
  $summary = @($active | ForEach-Object { '{0}:{1}@session{2} ({3})' -f $_.Name, $_.ProcessId, $_.SessionId, $_.OwnerState }) -join ', '
  throw "A legacy AI Usage or CodeBurn process did not finish within five minutes: $summary."
}

function Test-AbandonedInstallProcess([string]$Name, [string]$CommandLine) {
  if ($Name -notin @('cmd.exe', 'node.exe', 'powershell.exe', 'pwsh.exe', 'npm.exe')) { return $false }
  if ($Name -eq 'npm.exe') { return $true }
  if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
  if ($Name -eq 'cmd.exe' -and
      ($CommandLine -match '(?i)AI_USAGE_INSTALL_JOB' -or
       $CommandLine -match '(?i)%AI_USAGE_INSTALL_COMMAND_PATH%' -or
       $CommandLine -match '(?i)(?:^|[\\/"\s])npm\.cmd(?:["\s]|$)')) {
    return $true
  }
  if ($Name -eq 'node.exe' -and
      ($CommandLine -match '(?i)[\\/]npm-cli\.js(?:["\s]|$)' -or
       $CommandLine -match '(?i)[\\/]node_modules[\\/](?:codeburn|ccusage)[\\/]')) {
    return $true
  }
  return $Name -in @('powershell.exe', 'pwsh.exe') -and
    $CommandLine -match '(?i)[\\/]npm-cli\.ps1(?:["\s]|$)'
}

function Get-AbandonedInstallProcesses([string]$UserSid) {
  $matches = @()
  foreach ($process in @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)) {
    if ([int]$process.ProcessId -eq $PID) { continue }
    $name = [string]$process.Name
    $commandLine = [string]$process.CommandLine
    $hasCommandLine = -not [string]::IsNullOrWhiteSpace($commandLine)
    if ($name -notin @('cmd.exe', 'node.exe', 'powershell.exe', 'pwsh.exe', 'npm.exe') -or
        ($hasCommandLine -and -not (Test-AbandonedInstallProcess $name $commandLine))) { continue }
    $ownerState = 'Unknown'
    try {
      $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -OperationTimeoutSec 2 -ErrorAction Stop
      if ([int]$owner.ReturnValue -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$owner.Sid)) {
        $ownerState = if ([string]$owner.Sid -eq $UserSid) { 'Same' } else { 'Other' }
      }
    } catch {}
    if ($ownerState -eq 'Other') { continue }
    if (-not $hasCommandLine -and $ownerState -ne 'Same' -and $name -ne 'npm.exe') { continue }
    if ($ownerState -eq 'Unknown' -and
        -not (Get-Process -Id ([int]$process.ProcessId) -ErrorAction SilentlyContinue)) { continue }
    $matches += [pscustomobject]@{ ProcessId = [int]$process.ProcessId; Name = $name; OwnerState = $ownerState }
  }
  return $matches
}

function Wait-AbandonedInstallProcesses([string]$UserSid) {
  $deadline = [DateTime]::UtcNow.AddMinutes(5)
  $emptyScans = 0
  $active = @()
  while ([DateTime]::UtcNow -lt $deadline) {
    $active = @(Get-AbandonedInstallProcesses $UserSid)
    if (-not $active.Count) {
      $emptyScans += 1
      if ($emptyScans -ge 2) { return }
    } else {
      $emptyScans = 0
    }
    Start-Sleep -Milliseconds 200
  }
  $summary = @($active | ForEach-Object { '{0}:{1} ({2})' -f $_.Name, $_.ProcessId, $_.OwnerState }) -join ', '
  throw "An npm process from an abandoned installation did not finish within five minutes: $summary."
}

function Publish-UninstallGate([string]$Path) {
  Assert-NoReparsePath $Path
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
  $parent = Split-Path $Path -Parent
  $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.uninstall-' + $uninstallTransactionId + '.tmp')
  $replaceBackup = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.uninstall-' + $uninstallTransactionId + '.bak')
  try {
    if (Test-Path -LiteralPath $replaceBackup) {
      throw 'Refusing to overwrite an unowned uninstall gate backup.'
    }
    [IO.File]::WriteAllText($temporary, $uninstallGateContents, [Text.Encoding]::ASCII)
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
      try {
      if (Test-Path -LiteralPath $Path) {
        Assert-NoReparsePath $Path
          [IO.File]::Replace($temporary, $Path, $replaceBackup)
        } else {
          [IO.File]::Move($temporary, $Path)
        }
        break
      } catch {
        if ($attempt -ge 7) {
          throw "Could not publish uninstall gate for $Path. $($_.Exception.Message)"
        }
        Start-Sleep -Milliseconds (40 * ($attempt + 1))
      }
    }
    if (Test-Path -LiteralPath $replaceBackup) {
      [IO.File]::Delete($replaceBackup)
      if (Test-Path -LiteralPath $replaceBackup) { throw 'Could not remove the uninstall gate backup.' }
    }
  } finally {
    try { if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) } } catch {}
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
      [IO.File]::ReadAllText($Path) -cne $uninstallGateContents) {
    throw 'Could not publish the uninstall launch gate.'
  }
}

function Remove-ManagedPath([string]$Path, [switch]$Recurse) {
  if (-not (Get-ExistingPathEntry $Path)) { return }
  Assert-NoReparsePath $Path
  if ($Recurse) { Assert-NoReparseTree $Path }
  try {
    if ($Recurse) {
      Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } else {
      Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
  } catch {
    throw "Could not remove managed path $Path. $($_.Exception.Message)"
  }
  if (Get-ExistingPathEntry $Path) { throw "Could not remove managed path $Path." }
}

$installMutex = $null
$installMutexHeld = $false
$installMutexAbandoned = $false
$runMutex = $null
$runMutexHeld = $false
$runMutexAbandoned = $false
$legacyRunMutex = $null
$legacyRunMutexHeld = $false
$legacyRunMutexAbandoned = $false
$pendingPath = Join-Path $dest '.install-pending'
$pendingWritten = $false
$uninstallComplete = $false
$uninstallGatePublished = $false

try {
  Assert-NoReparsePath $dest
  Assert-NoReparsePath $desktop
  $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $installMutex = [Threading.Mutex]::new($false, "Global\AIUsage-Install-$userSid")
  try { $installMutexHeld = $installMutex.WaitOne([TimeSpan]::FromMinutes(5)) }
  catch [Threading.AbandonedMutexException] {
    $installMutexHeld = $true
    $installMutexAbandoned = $true
  }
  if (-not $installMutexHeld) { throw 'Another AI Usage installer did not finish within five minutes.' }
  if ($installMutexAbandoned) { Wait-AbandonedInstallProcesses $userSid }

  if (Test-Path -LiteralPath $dest) {
    if (Test-Path -LiteralPath (Join-Path $dest '.git')) {
      $safetySourceRoot = Join-Path $dest 'src'
      if (-not (Test-Path -LiteralPath $safetySourceRoot -PathType Container)) {
        throw 'Repository runtime source inventory is missing.'
      }
      Assert-NoReparseTree $safetySourceRoot
      foreach ($sourceItem in @(Get-ChildItem -LiteralPath $safetySourceRoot -Force -Recurse)) {
        $relative = $sourceItem.FullName.Substring($safetySourceRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
        Assert-NoReparsePath (Join-Path $dest $relative)
      }
    } else {
      Assert-NoReparseTree $dest
    }
    Assert-NoReparsePath $pendingPath
    if (Test-Path -LiteralPath $pendingPath -PathType Leaf) {
      $previousMarker = [IO.File]::ReadAllText($pendingPath)
      $previousUninstall = [regex]::Match(
        $previousMarker,
        '^transaction=uninstall-([0-9a-fA-F]{32})\r?\nownerPid=(\d+)\r?\nownerStartUtcTicks=(\d+)\r?\nstage=(?:pending|failed)\r?\n?$'
      )
      if ($previousUninstall -and $previousUninstall.Success) {
        $previousTransactionId = $previousUninstall.Groups[1].Value
        $previousPid = [int]$previousUninstall.Groups[2].Value
        $previousStartTicks = [int64]$previousUninstall.Groups[3].Value
        $previousOwner = Get-Process -Id $previousPid -ErrorAction SilentlyContinue
        if ($previousOwner) {
          try {
            if ([int64]$previousOwner.StartTime.ToUniversalTime().Ticks -eq $previousStartTicks) {
              throw 'The previous uninstall transaction owner is still running.'
            }
          } finally {
            $previousOwner.Dispose()
          }
        }
        foreach ($residue in @(
          (Join-Path $dest ('.Generate-ClaudeReport.ps1.uninstall-' + $previousTransactionId + '.tmp')),
          (Join-Path $dest ('.Generate-ClaudeReport.ps1.uninstall-' + $previousTransactionId + '.bak'))
        )) {
          Remove-ManagedPath $residue
        }
      }
    }
    [IO.File]::WriteAllText(
      $pendingPath,
      (Get-UninstallMarker 'pending'),
      [Text.Encoding]::ASCII
    )
    $pendingWritten = $true

    # A marker-unaware legacy launcher can start in another Session after the
    # process drain. Replace its generator first so every supported launch made
    # after this point fails closed; anything already started is drained below.
    $generatorPath = Join-Path $dest 'Generate-ClaudeReport.ps1'
    if (Test-Path -LiteralPath $generatorPath -PathType Leaf) {
      Publish-UninstallGate $generatorPath
      $uninstallGatePublished = $true
    }
  }

  # Old releases used only a Session-local mutex. Drain matching same-SID
  # processes before taking either report lock so cross-Session runs also finish.
  Wait-MigrationUsageProcesses $userSid

  $runMutex = [Threading.Mutex]::new($false, "Global\AIUsage-CodeBurn-$userSid")
  try { $runMutexHeld = $runMutex.WaitOne([TimeSpan]::FromMinutes(5)) }
  catch [Threading.AbandonedMutexException] {
    $runMutexHeld = $true
    $runMutexAbandoned = $true
  }
  if (-not $runMutexHeld) { throw 'A running AI Usage report did not finish within five minutes.' }

  $legacyRunMutex = [Threading.Mutex]::new($false, 'Local\AIUsage-CodeBurn')
  try { $legacyRunMutexHeld = $legacyRunMutex.WaitOne([TimeSpan]::FromMinutes(5)) }
  catch [Threading.AbandonedMutexException] {
    $legacyRunMutexHeld = $true
    $legacyRunMutexAbandoned = $true
  }
  if (-not $legacyRunMutexHeld) { throw 'A legacy AI Usage report did not finish within five minutes.' }
  if ($runMutexAbandoned -or $legacyRunMutexAbandoned) {
    # The mutex owner can die just before its Job handle closes. Do not delete
    # runtime or scratch until two consecutive same-SID process scans are empty.
    Wait-MigrationUsageProcesses $userSid
  }

  if ($uninstallGatePublished -and
      (-not (Test-Path -LiteralPath $generatorPath -PathType Leaf) -or
       [IO.File]::ReadAllText($generatorPath) -cne $uninstallGateContents)) {
    throw 'The uninstall launch gate changed while waiting for active reports.'
  }

  $ownedIcons = @()
  $primaryShortcut = Join-Path $desktop 'AI Usage.lnk'
  if (Test-Path -LiteralPath $primaryShortcut) {
    try {
      $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($primaryShortcut)
      $iconLocation = [string]$shortcut.IconLocation
      $separator = $iconLocation.LastIndexOf(',')
      if ($separator -ge 0 -and $iconLocation.Substring($separator + 1).Trim() -match '^-?\d+$') {
        $iconLocation = $iconLocation.Substring(0, $separator)
      }
      $shortcutIcon = Get-ContentAddressedIcon $iconLocation.Trim().Trim([char]34)
      if ($shortcutIcon) { $ownedIcons += $shortcutIcon }
    } catch {}
  }
  $sourceIcon = Join-Path $dest 'icon.ico'
  if (Test-Path -LiteralPath $sourceIcon -PathType Leaf) {
    try {
      $sourceHash = (Get-FileHash -LiteralPath $sourceIcon -Algorithm SHA256).Hash
      $hashedIcon = Join-Path $dest ('icon-' + $sourceHash.Substring(0, 8).ToLowerInvariant() + '.ico')
      if ((Get-ContentAddressedIcon $hashedIcon) -and
          (Get-FileHash -LiteralPath $hashedIcon -Algorithm SHA256).Hash -ceq $sourceHash) {
        $ownedIcons += [IO.Path]::GetFullPath($hashedIcon)
      }
    } catch {}
  }

# The oldest shortcut name is Chinese. Windows PowerShell reads a BOM-less script
# in the system ANSI code page, so the literal would arrive as mojibake and never
# match the file on disk; the code points survive that reading intact.
$legacyChineseShortcut = 'Claude' + (-join [char[]](0x7528, 0x91CF, 0x4EEA, 0x8868, 0x76D8)) + '.lnk'

function Remove-AiUsageShortcuts {
  foreach ($name in @('AI Usage.lnk', 'AI Usage Ledger.lnk', 'Claude Usage Dashboard.lnk', $legacyChineseShortcut)) {
    Remove-ManagedPath (Join-Path $desktop $name)
  }
}

Remove-ManagedPath (Join-Path $env:TEMP 'ClaudeUsage') -Recurse

if (Test-Path -LiteralPath (Join-Path $dest '.git')) {
  $repositorySourceRoot = Join-Path $dest 'src'
  if (-not (Test-Path -LiteralPath $repositorySourceRoot -PathType Container)) {
    throw 'Repository runtime source inventory is missing.'
  }
  Assert-NoReparseTree $repositorySourceRoot
  $managedRelativeFiles = @(Get-ChildItem -LiteralPath $repositorySourceRoot -File -Recurse | ForEach-Object {
    $_.FullName.Substring($repositorySourceRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
  })
  foreach ($relative in $managedRelativeFiles) {
    if ($relative -eq 'icon.ico') { continue }
    Remove-ManagedPath (Join-Path $dest $relative)
  }
  foreach ($ownedIcon in @($ownedIcons | Select-Object -Unique)) {
    Remove-ManagedPath $ownedIcon
  }
  # The source icon proves ownership of the current content-addressed icon on a
  # retry, while the shortcut proves ownership of the previous one. Remove both
  # only after every hashed icon is gone.
  Remove-ManagedPath $sourceIcon
  $managedDirectories = @(Get-ChildItem -LiteralPath $repositorySourceRoot -Directory -Recurse |
    Sort-Object { $_.FullName.Length } -Descending)
  foreach ($sourceDirectory in $managedDirectories) {
    $relative = $sourceDirectory.FullName.Substring($repositorySourceRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
    $targetDirectory = Join-Path $dest $relative
    if ((Test-Path -LiteralPath $targetDirectory -PathType Container) -and
        -not @(Get-ChildItem -LiteralPath $targetDirectory -Force).Count) {
      Assert-NoReparsePath $targetDirectory
      [IO.Directory]::Delete($targetDirectory, $false)
    }
  }
  Remove-AiUsageShortcuts
  Remove-ManagedPath $pendingPath
  $pendingWritten = $false
  $uninstallComplete = $true
  Write-Host 'Removed the installed runtime copy. The Git repository was preserved.' -ForegroundColor Green
} else {
  Remove-AiUsageShortcuts
  Remove-ManagedPath $dest -Recurse
  $pendingWritten = $false
  $uninstallComplete = $true
  Write-Host 'Removed AI Usage. Node.js, CodeBurn, and ccusage were left installed.' -ForegroundColor Green
}
} finally {
  if ($pendingWritten -and -not $uninstallComplete -and (Test-Path -LiteralPath $dest)) {
    try {
      Assert-NoReparsePath $pendingPath
      [IO.File]::WriteAllText(
        $pendingPath,
        (Get-UninstallMarker 'failed'),
        [Text.Encoding]::ASCII
      )
    } catch {}
  }
  if ($legacyRunMutexHeld) { try { $legacyRunMutex.ReleaseMutex() } catch {} }
  if ($runMutexHeld) { try { $runMutex.ReleaseMutex() } catch {} }
  if ($installMutexHeld) { try { $installMutex.ReleaseMutex() } catch {} }
  if ($legacyRunMutex) { try { $legacyRunMutex.Dispose() } catch {} }
  if ($runMutex) { try { $runMutex.Dispose() } catch {} }
  if ($installMutex) { try { $installMutex.Dispose() } catch {} }
}

if (-not $NoPrompt) { Read-Host 'Press Enter' }
