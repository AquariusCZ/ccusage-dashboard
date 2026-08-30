param(
  [ValidateSet('all', 'core', 'optional', 'rows', 'lifecycle')]
  [string]$TestGroup = 'all',
  [ValidateSet('all', 'coordination', 'debug-scratch')]
  [string]$LifecycleScenario = 'all'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('ai-usage-generator-test-%AI_USAGE_PATH_TOKEN%-' + [guid]::NewGuid().ToString('N'))
$runtime = Join-Path $sandbox 'runtime'
$stubs = Join-Path $sandbox 'stubs'
$codeBurnLog = Join-Path $sandbox 'codeburn.log'
$ccusageLog = Join-Path $sandbox 'ccusage.log'
$oldPath = $env:PATH
$oldTemp = $env:TEMP
$oldTmp = $env:TMP
$oldUserProfile = $env:USERPROFILE
$oldFailure = $env:AI_USAGE_STUB_FAILURE
$oldFailureMode = $env:AI_USAGE_STUB_FAILURE_MODE
$oldCCUsageExit = $env:AI_USAGE_CCUSAGE_EXIT
$oldCCUsageMode = $env:AI_USAGE_CCUSAGE_MODE
$oldCodeBurnLog = $env:AI_USAGE_CODEBURN_LOG
$oldCCUsageLog = $env:AI_USAGE_CCUSAGE_LOG
$oldPathToken = $env:AI_USAGE_PATH_TOKEN
$oldLaunchLog = $env:AI_USAGE_TEST_LAUNCH_LOG
$oldPendingRaceReady = $env:AI_USAGE_PENDING_RACE_READY
$oldCodeBurnHang = $env:AI_USAGE_CODEBURN_HANG
$oldCodeBurnPid = $env:AI_USAGE_CODEBURN_PID
$oldCodeBurnPoison = $env:AI_USAGE_CODEBURN_POISON
$oldCCUsageHang = $env:AI_USAGE_CCUSAGE_HANG
$oldCCUsagePid = $env:AI_USAGE_CCUSAGE_PID
$oldCCUsagePoison = $env:AI_USAGE_CCUSAGE_POISON
$oldOverlapMutex = $env:AI_USAGE_CODEBURN_OVERLAP_MUTEX
$oldOverlapMarker = $env:AI_USAGE_CODEBURN_OVERLAP_MARKER
$oldFinalPublishFault = $env:AI_USAGE_FINAL_PUBLISH_FAULT
$oldCodeBurnBarrierMatch = $env:AI_USAGE_CODEBURN_BARRIER_MATCH
$oldCodeBurnBarrierReady = $env:AI_USAGE_CODEBURN_BARRIER_READY
$oldCodeBurnBarrierRelease = $env:AI_USAGE_CODEBURN_BARRIER_RELEASE

function Read-Snapshot([string]$Path) {
  try {
    $raw = [IO.File]::ReadAllText($Path)
    $match = [regex]::Match($raw, '^window\.__DATA__\s*=\s*(.*);\s*if\s*\(', 'Singleline')
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Read-StartupFailure([string]$Path) {
  try {
    $raw = [IO.File]::ReadAllText($Path)
    $match = [regex]::Match($raw, '^window\.__GENERATION_FAILURE__\s*=\s*(.*);\s*if\s*\(', 'Singleline')
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Assert-NoFailureScriptResidue([string]$Directory, [string]$Label) {
  foreach ($name in @('failure.js', 'failure.js.tmp', 'failure.js.bak')) {
    if (Test-Path -LiteralPath (Join-Path $Directory $name)) {
      throw "$Label retained $name."
    }
  }
}

function Copy-Snapshot($Snapshot) {
  return ($Snapshot | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json
}

function Assert-SnapshotRejected($Snapshot, [string]$Name) {
  $path = Join-Path $sandbox ("invalid-contract-{0}.js" -f $Name)
  $json = $Snapshot | ConvertTo-Json -Depth 100 -Compress
  [IO.File]::WriteAllText(
    $path,
    "window.__DATA__ = $json; if (window.__render__) window.__render__();",
    (New-Object Text.UTF8Encoding($false))
  )
  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Verify-Snapshot.ps1') -DataPath $path *> $null
    $rejectedExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($rejectedExitCode -eq 0) { throw "$Name malformed snapshot contract was accepted." }
}

function Assert-ProgressiveContract($Scenario, [string]$Label) {
  $ordered = @($Scenario.SnapshotSequence | ForEach-Object { $_ })
  if ($ordered.Count -lt 2) { throw "$Label did not expose multiple progressive revisions." }
  $runIds = @($ordered | ForEach-Object { [string]$_.runId } | Select-Object -Unique)
  if ($runIds.Count -ne 1 -or [string]::IsNullOrWhiteSpace($runIds[0])) {
    throw "$Label snapshots did not share one nonempty runId."
  }
  $previousRevision = 0
  $previousPeriods = @()
  for ($index = 0; $index -lt $ordered.Count; $index++) {
    $snapshot = $ordered[$index]
    if ([int]$snapshot.revision -le $previousRevision) { throw "$Label revisions were not strictly increasing." }
    $currentPeriods = @($snapshot.periods)
    if (@($currentPeriods | Select-Object -Unique).Count -ne $currentPeriods.Count) {
      throw "$Label published duplicate period keys."
    }
    if ($currentPeriods.Count -lt $previousPeriods.Count) { throw "$Label removed a previously published period." }
    for ($periodIndex = 0; $periodIndex -lt $previousPeriods.Count; $periodIndex++) {
      if ($currentPeriods[$periodIndex] -ne $previousPeriods[$periodIndex]) {
        throw "$Label did not extend periods as an ordered prefix."
      }
    }
    if ($snapshot.complete -eq $true -and $index -ne ($ordered.Count - 1)) {
      throw "$Label published a nonterminal complete revision."
    }
    $previousRevision = [int]$snapshot.revision
    $previousPeriods = $currentPeriods
  }
  if ($ordered[-1].complete -ne $true -or @($ordered | Where-Object { $_.complete -eq $true }).Count -ne 1) {
    throw "$Label did not publish exactly one terminal complete revision."
  }
}

function Invoke-Scenario(
  [string]$Name,
  [string]$Failure,
  [int]$CCUsageExit = 0,
  [bool]$ProbeLegacyMutex = $false,
  [string]$FailureMode = 'before',
  [string]$CCUsageMode = '',
  [bool]$LaunchKeepFile = $false,
  [string]$Period = '',
  [string]$GeneratorPath = ''
) {
  $scenarioRoot = Join-Path $sandbox $Name
  $scenarioTemp = Join-Path $scenarioRoot 'temp'
  $profile = Join-Path $scenarioRoot 'profile'
  New-Item -ItemType Directory -Force -Path $scenarioTemp, $profile | Out-Null
  foreach ($log in @($codeBurnLog, $ccusageLog)) {
    if (Test-Path -LiteralPath $log) { [IO.File]::Delete($log) }
  }

  $env:TEMP = $scenarioTemp
  $env:TMP = $scenarioTemp
  $env:USERPROFILE = $profile
  $env:AI_USAGE_STUB_FAILURE = $Failure
  $env:AI_USAGE_STUB_FAILURE_MODE = $FailureMode
  $env:AI_USAGE_CCUSAGE_EXIT = [string]$CCUsageExit
  $env:AI_USAGE_CCUSAGE_MODE = $CCUsageMode
  $launchLog = Join-Path $scenarioRoot 'launch.log'
  $env:AI_USAGE_TEST_LAUNCH_LOG = $launchLog
  $legacyProbe = $null
  $legacyProbeHeld = $false
  if ($ProbeLegacyMutex) {
    $legacyProbe = [Threading.Mutex]::new($false, 'Local\AIUsage-CodeBurn')
    try {
      $legacyProbeHeld = $legacyProbe.WaitOne([TimeSpan]::FromMinutes(5))
    } catch [Threading.AbandonedMutexException] {
      $legacyProbeHeld = $true
    }
    if (-not $legacyProbeHeld) { throw 'Could not acquire the legacy mutex for the migration probe.' }
  }
  $stdout = Join-Path $scenarioRoot 'stdout.txt'
  $stderr = Join-Path $scenarioRoot 'stderr.txt'
  $startInfo = New-Object Diagnostics.ProcessStartInfo
  $startInfo.FileName = 'powershell.exe'
  if (-not $GeneratorPath) { $GeneratorPath = Join-Path $runtime 'Generate-ClaudeReport.ps1' }
  if ($LaunchKeepFile) {
    $launchWrapper = Join-Path $scenarioRoot 'launch-wrapper.ps1'
    $wrapperText = @'
param([Parameter(Mandatory = $true)][string]$GeneratorPath)
function Start-Process {
  param([Parameter(Position = 0)][string]$FilePath)
  [IO.File]::AppendAllText($env:AI_USAGE_TEST_LAUNCH_LOG, $FilePath + "`r`n", [Text.Encoding]::ASCII)
}
& $GeneratorPath -KeepFile
'@
    [IO.File]::WriteAllText($launchWrapper, $wrapperText, [Text.Encoding]::ASCII)
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $launchWrapper +
      '" -GeneratorPath "' + $GeneratorPath + '"'
  } else {
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' +
      $GeneratorPath + '" -NoLaunch -KeepFile'
    if ($Period) { $startInfo.Arguments += ' -Period "' + $Period + '"' }
  }
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = New-Object Diagnostics.Process
  $process.StartInfo = $startInfo
  if (-not $process.Start()) { throw "$Name generator scenario could not start." }
  if ($legacyProbeHeld) {
    try {
      Start-Sleep -Milliseconds 400
      $process.Refresh()
      if ($process.HasExited) { throw 'The generator did not wait for a legacy report mutex owner.' }
      if (Test-Path -LiteralPath $codeBurnLog) { throw 'The generator invoked CodeBurn while the legacy mutex was held.' }
    } finally {
      try { $legacyProbe.ReleaseMutex() } catch {}
      $legacyProbeHeld = $false
      try { $legacyProbe.Dispose() } catch {}
      $legacyProbe = $null
    }
  }

  $snapshots = @{}
  $snapshotSequence = New-Object Collections.Generic.List[object]
  $firstCodeBurnCount = $null
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
    foreach ($dataPath in @(Get-ChildItem -LiteralPath (Join-Path $scenarioTemp 'ClaudeUsage') -Filter 'data.js' -File -Recurse -ErrorAction SilentlyContinue)) {
      $snapshot = Read-Snapshot $dataPath.FullName
      if ($snapshot -and -not $snapshots.ContainsKey([int]$snapshot.revision)) {
        $snapshots[[int]$snapshot.revision] = $snapshot
        $snapshotSequence.Add($snapshot)
        if ($null -eq $firstCodeBurnCount) {
          $firstCodeBurnCount = @(Get-Content -LiteralPath $codeBurnLog -ErrorAction SilentlyContinue).Count
        }
      }
    }
    Start-Sleep -Milliseconds 20
    $process.Refresh()
  }
  if (-not $process.HasExited) {
    try { Stop-Process -Id $process.Id -Force } catch {}
    throw "$Name generator scenario timed out."
  }
  $process.WaitForExit()
  $process.Refresh()
  $exitCode = [int]$process.ExitCode
  $outputText = $process.StandardOutput.ReadToEnd()
  $errorText = $process.StandardError.ReadToEnd()
  [IO.File]::WriteAllText($stdout, $outputText, (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText($stderr, $errorText, (New-Object Text.UTF8Encoding($false)))
  if ($exitCode -ne 0) {
    throw "$Name generator scenario failed with exit code ${exitCode}: $errorText $outputText"
  }

  $reportReference = if ($LaunchKeepFile -and (Test-Path -LiteralPath $launchLog)) {
    @([IO.File]::ReadAllLines($launchLog) | Where-Object { $_ -match 'report\.html\?period=' }) | Select-Object -Last 1
  } else {
    @([IO.File]::ReadAllLines($stdout) | Where-Object { $_ -match 'report\.html$' }) | Select-Object -Last 1
  }
  $reportHtml = if ($LaunchKeepFile -and $reportReference) { ([Uri]$reportReference).LocalPath } else { $reportReference }
  if (-not $reportHtml) { throw "$Name generator scenario did not return a report path." }
  $dataPath = Join-Path (Split-Path $reportHtml -Parent) 'data.js'
  $final = Read-Snapshot $dataPath
  if (-not $final) { throw "$Name generator scenario did not retain a readable final snapshot." }
  if (-not $snapshots.ContainsKey([int]$final.revision)) { $snapshotSequence.Add($final) }
  $snapshots[[int]$final.revision] = $final

  $result = [pscustomobject]@{
    Snapshots = $snapshots
    SnapshotSequence = $snapshotSequence
    First = $snapshotSequence[0]
    FirstCodeBurnCount = $firstCodeBurnCount
    Final = $final
    DataPath = $dataPath
    CodeBurnCalls = @(Get-Content -LiteralPath $codeBurnLog -ErrorAction SilentlyContinue)
    CCUsageCalls = @(Get-Content -LiteralPath $ccusageLog -ErrorAction SilentlyContinue)
    LaunchCalls = @(Get-Content -LiteralPath $launchLog -ErrorAction SilentlyContinue)
  }
  try { $process.Dispose() } catch {}
  return $result
}

function Invoke-CCUsageBoundaryScenario([string]$Mode) {
  $scenarioRoot = Join-Path $sandbox $Mode
  $pidPath = Join-Path $scenarioRoot 'ccusage.pid'
  $poisonPath = Join-Path $scenarioRoot 'ccusage-poison.txt'
  $generatorPath = Join-Path $runtime 'Generate-ClaudeReport.ps1'
  if ($Mode -eq 'deadline-hang') {
    $generatorPath = Join-Path $runtime 'Generate-ClaudeReport-ccusage-deadline.ps1'
    $generatorText = [IO.File]::ReadAllText((Join-Path $runtime 'Generate-ClaudeReport.ps1'))
    $instrumentedText = $generatorText.Replace(
      '$CCUsageTimeoutMilliseconds = 120000',
      '$CCUsageTimeoutMilliseconds = 750'
    )
    if ($instrumentedText -ceq $generatorText) {
      throw 'Could not instrument the ccusage absolute deadline.'
    }
    [IO.File]::WriteAllText($generatorPath, $instrumentedText, [Text.Encoding]::ASCII)
  }

  $previousPidPath = $env:AI_USAGE_CCUSAGE_PID
  $previousPoisonPath = $env:AI_USAGE_CCUSAGE_POISON
  try {
    $env:AI_USAGE_CCUSAGE_PID = $pidPath
    $env:AI_USAGE_CCUSAGE_POISON = $poisonPath
    $result = Invoke-Scenario $Mode '' 0 $false 'before' $Mode $false '' $generatorPath
    if ($result.Final.generationError -or $result.Final.limits.claudeBlocks) {
      throw "$Mode did not degrade the optional ccusage collector cleanly."
    }
    if ($result.CCUsageCalls.Count -ne 1 -or -not (Test-Path -LiteralPath $pidPath)) {
      throw "$Mode did not start exactly one observable ccusage process."
    }
    $ccusagePid = [int]([IO.File]::ReadAllText($pidPath).Trim())
    if (Get-Process -Id $ccusagePid -ErrorAction SilentlyContinue) {
      throw "$Mode left its ccusage process alive after report completion."
    }
    if (Test-Path -LiteralPath $poisonPath) {
      throw "$Mode allowed ccusage to outlive its absolute output or time boundary."
    }
  } finally {
    if ($null -eq $previousPidPath) { Remove-Item Env:AI_USAGE_CCUSAGE_PID -ErrorAction SilentlyContinue }
    else { $env:AI_USAGE_CCUSAGE_PID = $previousPidPath }
    if ($null -eq $previousPoisonPath) { Remove-Item Env:AI_USAGE_CCUSAGE_POISON -ErrorAction SilentlyContinue }
    else { $env:AI_USAGE_CCUSAGE_POISON = $previousPoisonPath }
  }
}

function Start-NormalGenerator(
  [string]$WrapperPath,
  [string]$LaunchLog,
  [int]$DeleteAfter = 1,
  [string]$Period = '',
  [hashtable]$EnvironmentOverrides = $null,
  [string]$GeneratorPath = ''
) {
  $env:AI_USAGE_TEST_LAUNCH_LOG = $LaunchLog
  if (-not $GeneratorPath) { $GeneratorPath = Join-Path $runtime 'Generate-ClaudeReport.ps1' }
  $startInfo = New-Object Diagnostics.ProcessStartInfo
  $startInfo.FileName = 'powershell.exe'
  $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $WrapperPath +
    '" -GeneratorPath "' + $GeneratorPath +
    '" -DeleteAfter ' + $DeleteAfter
  if ($Period) { $startInfo.Arguments += ' -Period "' + $Period + '"' }
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  if ($EnvironmentOverrides) {
    foreach ($key in $EnvironmentOverrides.Keys) {
      $startInfo.EnvironmentVariables[[string]$key] = [string]$EnvironmentOverrides[$key]
    }
  }
  $process = New-Object Diagnostics.Process
  $process.StartInfo = $startInfo
  if (-not $process.Start()) { throw 'Could not start the normal generator lifecycle process.' }
  return $process
}

function Get-CompletedProcessResult([Diagnostics.Process]$Process, [int]$TimeoutMilliseconds = 45000) {
  if (-not $Process.WaitForExit($TimeoutMilliseconds)) {
    try { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue } catch {}
    throw ("A normal generator lifecycle process timed out (PID {0}, TEMP {1}, args {2})." -f `
      $Process.Id, $env:TEMP, $Process.StartInfo.Arguments)
  }
  $Process.WaitForExit()
  $Process.Refresh()
  return [pscustomobject]@{
    ExitCode = [int]$Process.ExitCode
    Output = $Process.StandardOutput.ReadToEnd() + $Process.StandardError.ReadToEnd()
  }
}

function Invoke-PendingAfterGlobalWaitScenario {
  $scenarioRoot = Join-Path $sandbox 'pending-after-global-wait'
  New-Item -ItemType Directory -Force -Path $scenarioRoot | Out-Null
  $instrumentedGenerator = Join-Path $runtime 'Generate-ClaudeReport-pending-race.ps1'
  $generatorText = [IO.File]::ReadAllText((Join-Path $runtime 'Generate-ClaudeReport.ps1'))
  $initialCheck = [regex]::Match($generatorText, '(?m)^Assert-NoPendingInstallation\r?$')
  if (-not $initialCheck.Success) { throw 'Could not locate the generator initial pending check.' }
  $newline = if ($generatorText.Contains("`r`n")) { "`r`n" } else { "`n" }
  $probeLine = 'if ($env:AI_USAGE_PENDING_RACE_READY) { [IO.File]::WriteAllText($env:AI_USAGE_PENDING_RACE_READY, ''ready'', [Text.Encoding]::ASCII) }'
  $generatorText = $generatorText.Insert($initialCheck.Index + $initialCheck.Length, $newline + $probeLine)
  [IO.File]::WriteAllText($instrumentedGenerator, $generatorText, [Text.Encoding]::ASCII)

  $readyPath = Join-Path $scenarioRoot 'initial-check-passed'
  $pendingPath = Join-Path $runtime '.install-pending'
  $env:AI_USAGE_PENDING_RACE_READY = $readyPath
  if (Test-Path -LiteralPath $codeBurnLog) { [IO.File]::Delete($codeBurnLog) }

  $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $mutex = [Threading.Mutex]::new($false, "Global\AIUsage-CodeBurn-$userSid")
  $mutexHeld = $false
  $process = $null
  try {
    try {
      $mutexHeld = $mutex.WaitOne([TimeSpan]::FromMinutes(5))
    } catch [Threading.AbandonedMutexException] {
      $mutexHeld = $true
    }
    if (-not $mutexHeld) { throw 'Could not acquire the global report mutex for the pending race probe.' }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $instrumentedGenerator + '" -NoLaunch -KeepFile'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Could not start the pending race generator.' }

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $readyPath) -and [DateTime]::UtcNow -lt $deadline) {
      if ($process.HasExited) { break }
      Start-Sleep -Milliseconds 20
      $process.Refresh()
    }
    if (-not (Test-Path -LiteralPath $readyPath)) {
      $early = Get-CompletedProcessResult $process 1000
      throw "The pending race generator did not pass its initial marker check: $($early.Output)"
    }

    [IO.File]::WriteAllText($pendingPath, "transaction=test`r`nstage=pending`r`n", [Text.Encoding]::ASCII)
    $mutex.ReleaseMutex()
    $mutexHeld = $false

    $result = Get-CompletedProcessResult $process 10000
    if ($result.ExitCode -eq 0 -or $result.Output -notmatch 'installation is incomplete') {
      throw "A marker created during the global mutex wait did not stop the generator: $($result.Output)"
    }
    if (@(Get-Content -LiteralPath $codeBurnLog -ErrorAction SilentlyContinue).Count -ne 0) {
      throw 'The pending race generator invoked CodeBurn after installation began.'
    }
  } finally {
    if ($mutexHeld) { try { $mutex.ReleaseMutex() } catch {} }
    try { $mutex.Dispose() } catch {}
    if ($process -and -not $process.HasExited) {
      try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($process) { try { $process.Dispose() } catch {} }
    foreach ($path in @($pendingPath, $instrumentedGenerator)) {
      if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) }
    }
  }
}

function Invoke-FailureRetryScenario([string]$Name, [string]$FailurePattern, [bool]$StartupFailure) {
  $scenarioRoot = Join-Path $sandbox $Name
  $scenarioTemp = Join-Path $scenarioRoot 'temp'
  $profile = Join-Path $scenarioRoot 'profile'
  New-Item -ItemType Directory -Force -Path $scenarioTemp, $profile | Out-Null
  foreach ($log in @($codeBurnLog, $ccusageLog)) {
    if (Test-Path -LiteralPath $log) { [IO.File]::Delete($log) }
  }

  $env:TEMP = $scenarioTemp
  $env:TMP = $scenarioTemp
  $env:USERPROFILE = $profile
  $env:AI_USAGE_STUB_FAILURE = $FailurePattern
  $env:AI_USAGE_STUB_FAILURE_MODE = 'before'
  $env:AI_USAGE_CCUSAGE_EXIT = '0'
  $env:AI_USAGE_CCUSAGE_MODE = ''

  $wrapperPath = Join-Path $scenarioRoot 'normal-wrapper.ps1'
  $wrapperText = @'
param(
  [Parameter(Mandatory = $true)][string]$GeneratorPath,
  [Parameter(Mandatory = $true)][int]$DeleteAfter,
  [string]$Period = ''
)
function Start-Process {
  param([Parameter(Position = 0)][string]$FilePath)
  [IO.File]::AppendAllText($env:AI_USAGE_TEST_LAUNCH_LOG, $FilePath + "`r`n", [Text.Encoding]::ASCII)
}
& $GeneratorPath -DeleteAfter $DeleteAfter
'@
  [IO.File]::WriteAllText($wrapperPath, $wrapperText, [Text.Encoding]::ASCII)

  $runtimeRoot = Join-Path $scenarioTemp 'ClaudeUsage'
  $dataPath = Join-Path $runtimeRoot 'data.js'
  $failurePath = Join-Path $runtimeRoot 'failure.js'
  $htmlPath = Join-Path $runtimeRoot 'report.html'
  $launchLog = Join-Path $scenarioRoot 'launch.log'
  $retryLaunchLog = Join-Path $scenarioRoot 'retry-launch.log'
  $statePath = Join-Path $runtimeRoot 'report-run.state'
  $ownerPath = Join-Path $runtimeRoot 'report-run.owner.json'
  $retryPath = Join-Path $runtimeRoot 'report-retry.request'
  $process = $null
  $retry = $null
  try {
    $process = Start-NormalGenerator $wrapperPath $launchLog 8
    $failure = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not $failure -and [DateTime]::UtcNow -lt $deadline) {
      if ($StartupFailure) {
        if (Test-Path -LiteralPath $failurePath) { $failure = Read-StartupFailure $failurePath }
      } elseif (Test-Path -LiteralPath $dataPath) {
          $snapshot = Read-Snapshot $dataPath
          if ($snapshot -and $snapshot.complete -eq $true -and $snapshot.generationError) { $failure = $snapshot }
      }
      if (-not $failure) {
        $process.Refresh()
        if ($process.HasExited) { break }
        Start-Sleep -Milliseconds 10
      }
    }
    if (-not $failure) {
      $early = Get-CompletedProcessResult $process 1000
      throw "Failed run did not publish a terminal browser signal: $($early.Output)"
    }
    if ($StartupFailure) {
      if ($failure.reason -ne 'initial_generation_failed' -or $failure.stage -ne 'default_usage') {
        throw 'Startup failure signal did not contain its classified stage.'
      }
      if (Test-Path -LiteralPath $dataPath) { throw 'Startup failure signal overwrote data.js instead of using failure.js.' }
    } elseif ($failure.generationError.reason -ne 'partial_generation_failed' -or
        $failure.generationError.stage -ne 'remaining_usage') {
      throw 'Partial failure snapshot did not contain its classified stage.'
    }
    if (@(Get-Content -LiteralPath $launchLog -ErrorAction SilentlyContinue).Count -ne 1) {
      throw 'Startup failure scenario did not launch exactly one page.'
    }
    if (-not (Test-Path -LiteralPath $statePath) -or [IO.File]::ReadAllText($statePath).Trim() -ne 'failed') {
      throw 'A failed run remained reusable as an active page.'
    }

    $retry = Start-NormalGenerator $wrapperPath $retryLaunchLog 0 '' @{
      AI_USAGE_STUB_FAILURE = ''
      AI_USAGE_STUB_FAILURE_MODE = 'before'
    }
    $requestDeadline = [DateTime]::UtcNow.AddSeconds(2)
    while (-not (Test-Path -LiteralPath $retryPath) -and [DateTime]::UtcNow -lt $requestDeadline) {
      Start-Sleep -Milliseconds 20
    }
    if (-not (Test-Path -LiteralPath $retryPath)) {
      throw 'A failed-run retry did not publish its bounded retry request.'
    }
    $ownerRecord = [IO.File]::ReadAllText($ownerPath) | ConvertFrom-Json
    if ([IO.File]::ReadAllText($retryPath).Trim() -cne [string]$ownerRecord.runId) {
      throw 'A failed-run retry request was not bound to the current owner runId.'
    }
    if ($StartupFailure -and $failure.runId -cne [string]$ownerRecord.runId) {
      throw 'Startup failure sidecar was not bound to the current owner runId.'
    }
    $retry.Refresh()
    if ($retry.HasExited -or @(Get-Content -LiteralPath $retryLaunchLog -ErrorAction SilentlyContinue).Count) {
      throw 'A retry reused the previous failed page instead of waiting for a fresh aggregation.'
    }

    $result = Get-CompletedProcessResult $process 6000
    if ($StartupFailure -and $result.ExitCode -eq 0) {
      throw 'Startup collector failure incorrectly returned a successful process exit.'
    }
    if (-not $StartupFailure -and $result.ExitCode -ne 0) {
      throw "Partial failure did not retain its usable terminal snapshot: $($result.Output)"
    }
    $retryResult = Get-CompletedProcessResult $retry 45000
    if ($retryResult.ExitCode -ne 0) { throw "A failed-run retry did not complete cleanly: $($retryResult.Output)" }
    $expectedCalls = if ($StartupFailure) { 13 } else { 17 }
    if (@(Get-Content -LiteralPath $codeBurnLog -ErrorAction SilentlyContinue).Count -ne $expectedCalls) {
      throw 'A failed-run retry did not perform exactly one fresh aggregation.'
    }
    $retryTargets = @(Get-Content -LiteralPath $retryLaunchLog -ErrorAction SilentlyContinue)
    if ($retryTargets.Count -ne 1 -or $retryTargets[0] -notmatch '\?period=30days$') {
      throw 'A failed-run retry did not launch the fresh default-period page.'
    }
    foreach ($path in @($dataPath, $failurePath, $htmlPath, $statePath, $ownerPath, $retryPath)) {
      if (Test-Path -LiteralPath $path) { throw 'Failed-run retry escaped normal burn-after-read cleanup.' }
    }
    Assert-NoFailureScriptResidue $runtimeRoot 'Failed-run retry cleanup'
  } finally {
    if ($process -and -not $process.HasExited) {
      try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($retry -and -not $retry.HasExited) {
      try { Stop-Process -Id $retry.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($process) { try { $process.Dispose() } catch {} }
    if ($retry) { try { $retry.Dispose() } catch {} }
  }
}

function Invoke-FailureReadGraceScenario {
  $scenarioRoot = Join-Path $sandbox 'failure-read-grace'
  $scenarioTemp = Join-Path $scenarioRoot 'temp'
  $profile = Join-Path $scenarioRoot 'profile'
  New-Item -ItemType Directory -Force -Path $scenarioTemp, $profile | Out-Null
  if (Test-Path -LiteralPath $codeBurnLog) { [IO.File]::Delete($codeBurnLog) }

  $env:TEMP = $scenarioTemp
  $env:TMP = $scenarioTemp
  $env:USERPROFILE = $profile
  $env:AI_USAGE_STUB_FAILURE = 'report|30days|claude'
  $env:AI_USAGE_STUB_FAILURE_MODE = 'before'
  $env:AI_USAGE_CCUSAGE_EXIT = '0'
  $env:AI_USAGE_CCUSAGE_MODE = ''

  $wrapperPath = Join-Path $scenarioRoot 'normal-wrapper.ps1'
  [IO.File]::WriteAllText($wrapperPath, @'
param(
  [Parameter(Mandatory = $true)][string]$GeneratorPath,
  [Parameter(Mandatory = $true)][int]$DeleteAfter,
  [string]$Period = ''
)
function Start-Process {
  param([Parameter(Position = 0)][string]$FilePath)
  [IO.File]::AppendAllText($env:AI_USAGE_TEST_LAUNCH_LOG, $FilePath + "`r`n", [Text.Encoding]::ASCII)
}
& $GeneratorPath -DeleteAfter $DeleteAfter
'@, [Text.Encoding]::ASCII)

  $runtimeRoot = Join-Path $scenarioTemp 'ClaudeUsage'
  $dataPath = Join-Path $runtimeRoot 'data.js'
  $failurePath = Join-Path $runtimeRoot 'failure.js'
  $htmlPath = Join-Path $runtimeRoot 'report.html'
  $statePath = Join-Path $runtimeRoot 'report-run.state'
  $ownerPath = Join-Path $runtimeRoot 'report-run.owner.json'
  $retryPath = Join-Path $runtimeRoot 'report-retry.request'
  $launchLog = Join-Path $scenarioRoot 'launch.log'
  $process = $null
  try {
    $process = Start-NormalGenerator $wrapperPath $launchLog 4
    $failure = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not $failure -and [DateTime]::UtcNow -lt $deadline) {
      if (Test-Path -LiteralPath $failurePath) { $failure = Read-StartupFailure $failurePath }
      if (-not $failure) { Start-Sleep -Milliseconds 20 }
    }
    if (-not $failure) { throw 'The failure read-grace probe did not publish its terminal signal.' }
    Start-Sleep -Milliseconds 2500
    $process.Refresh()
    if ($process.HasExited -or (Test-Path -LiteralPath $dataPath) -or
        -not (Test-Path -LiteralPath $failurePath) -or
        -not (Test-Path -LiteralPath $htmlPath) -or
        -not (Test-Path -LiteralPath $statePath) -or
        [IO.File]::ReadAllText($statePath).Trim() -ne 'failed') {
      throw 'A failed page without a retry request was removed before its normal read grace.'
    }
    if (Test-Path -LiteralPath $retryPath) {
      throw 'A failed owner fabricated a retry request without a waiting launch.'
    }
    $result = Get-CompletedProcessResult $process 10000
    if ($result.ExitCode -eq 0) { throw 'The startup failure read-grace probe returned success.' }
    foreach ($path in @($dataPath, $failurePath, $htmlPath, $statePath, $ownerPath, $retryPath)) {
      if (Test-Path -LiteralPath $path) { throw 'Failure read-grace cleanup left coordination residue.' }
    }
    Assert-NoFailureScriptResidue $runtimeRoot 'Failure read-grace cleanup'
  } finally {
    if ($process -and -not $process.HasExited) {
      try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($process) { try { $process.Dispose() } catch {} }
  }
}

function Invoke-FinalPublishFailureScenario {
  $scenarioRoot = Join-Path $sandbox 'final-publish-failure'
  $scenarioTemp = Join-Path $scenarioRoot 'temp'
  $profile = Join-Path $scenarioRoot 'profile'
  New-Item -ItemType Directory -Force -Path $scenarioTemp, $profile | Out-Null
  if (Test-Path -LiteralPath $codeBurnLog) { [IO.File]::Delete($codeBurnLog) }

  $env:TEMP = $scenarioTemp
  $env:TMP = $scenarioTemp
  $env:USERPROFILE = $profile
  $env:AI_USAGE_STUB_FAILURE = ''
  $env:AI_USAGE_STUB_FAILURE_MODE = 'before'
  $env:AI_USAGE_CCUSAGE_EXIT = '0'
  $env:AI_USAGE_CCUSAGE_MODE = ''

  $instrumented = Join-Path $runtime 'Generate-ClaudeReport-final-publish-fault.ps1'
  $generatorText = [IO.File]::ReadAllText((Join-Path $runtime 'Generate-ClaudeReport.ps1'))
  $anchor = 'function Write-DataScript([string]$ScriptText) {'
  $anchorIndex = $generatorText.IndexOf($anchor)
  if ($anchorIndex -lt 0) { throw 'Could not locate the final snapshot publication boundary.' }
  $newline = if ($generatorText.Contains("`r`n")) { "`r`n" } else { "`n" }
  $fault = @'
  if ($env:AI_USAGE_FINAL_PUBLISH_FAULT -and
      $ScriptText.Contains('"complete":true')) {
    [IO.File]::WriteAllText($env:AI_USAGE_FINAL_PUBLISH_FAULT, 'injected', [Text.Encoding]::ASCII)
    throw 'Injected final data.js publication failure.'
  }
'@
  $generatorText = $generatorText.Insert(
    $anchorIndex + $anchor.Length,
    $newline + $fault.TrimEnd("`r", "`n")
  )
  [IO.File]::WriteAllText($instrumented, $generatorText, [Text.Encoding]::ASCII)

  $wrapperPath = Join-Path $scenarioRoot 'normal-wrapper.ps1'
  [IO.File]::WriteAllText($wrapperPath, @'
param(
  [Parameter(Mandatory = $true)][string]$GeneratorPath,
  [Parameter(Mandatory = $true)][int]$DeleteAfter,
  [string]$Period = ''
)
function Start-Process {
  param([Parameter(Position = 0)][string]$FilePath)
  [IO.File]::AppendAllText($env:AI_USAGE_TEST_LAUNCH_LOG, $FilePath + "`r`n", [Text.Encoding]::ASCII)
}
& $GeneratorPath -DeleteAfter $DeleteAfter
'@, [Text.Encoding]::ASCII)

  $runtimeRoot = Join-Path $scenarioTemp 'ClaudeUsage'
  $dataPath = Join-Path $runtimeRoot 'data.js'
  $failurePath = Join-Path $runtimeRoot 'failure.js'
  $htmlPath = Join-Path $runtimeRoot 'report.html'
  $statePath = Join-Path $runtimeRoot 'report-run.state'
  $ownerPath = Join-Path $runtimeRoot 'report-run.owner.json'
  $retryPath = Join-Path $runtimeRoot 'report-retry.request'
  $faultPath = Join-Path $scenarioRoot 'final-publish.faulted'
  $ownerLog = Join-Path $scenarioRoot 'owner-launch.log'
  $retryLog = Join-Path $scenarioRoot 'retry-launch.log'
  $owner = $null
  $retry = $null
  try {
    $env:AI_USAGE_FINAL_PUBLISH_FAULT = $faultPath
    $owner = Start-NormalGenerator $wrapperPath $ownerLog 8 '' $null $instrumented
    $terminal = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not $terminal -and [DateTime]::UtcNow -lt $deadline) {
      if (Test-Path -LiteralPath $failurePath) { $terminal = Read-StartupFailure $failurePath }
      if (-not $terminal) { Start-Sleep -Milliseconds 20 }
    }
    $incomplete = Read-Snapshot $dataPath
    if (-not $terminal -or $terminal.reason -ne 'partial_generation_failed' -or
        $terminal.stage -ne 'final_publish' -or -not $incomplete -or $incomplete.complete -ne $false -or
        $terminal.runId -cne $incomplete.runId) {
      throw 'Persistent final data.js write failures did not publish a matching terminal sidecar.'
    }
    if (-not (Test-Path -LiteralPath $faultPath) -or
        -not (Test-Path -LiteralPath $statePath) -or
        [IO.File]::ReadAllText($statePath).Trim() -ne 'failed') {
      throw 'A final data.js write failure remained active or bypassed the injected boundary.'
    }
    $owner.Refresh()
    if ($owner.HasExited) { throw 'A final publication failure skipped its read grace.' }

    $retry = Start-NormalGenerator $wrapperPath $retryLog 0 '' @{
      AI_USAGE_FINAL_PUBLISH_FAULT = ''
    }
    $requestDeadline = [DateTime]::UtcNow.AddSeconds(2)
    while (-not (Test-Path -LiteralPath $retryPath) -and [DateTime]::UtcNow -lt $requestDeadline) {
      Start-Sleep -Milliseconds 20
    }
    if (-not (Test-Path -LiteralPath $retryPath)) {
      throw 'A final-publication retry did not request an early failed-page close.'
    }
    $ownerRecord = [IO.File]::ReadAllText($ownerPath) | ConvertFrom-Json
    if ([IO.File]::ReadAllText($retryPath).Trim() -cne [string]$ownerRecord.runId) {
      throw 'A final-publication retry targeted the wrong owner runId.'
    }

    $ownerResult = Get-CompletedProcessResult $owner 6000
    if ($ownerResult.ExitCode -eq 0) { throw 'Persistent final publication failure incorrectly returned success.' }
    $retryResult = Get-CompletedProcessResult $retry 45000
    if ($retryResult.ExitCode -ne 0) { throw "Fresh run after final publication failure failed: $($retryResult.Output)" }
    if (@(Get-Content -LiteralPath $codeBurnLog -ErrorAction SilentlyContinue).Count -ne 24) {
      throw 'A final-publication retry did not perform exactly one fresh aggregation.'
    }
    foreach ($path in @($dataPath, $failurePath, $htmlPath, $statePath, $ownerPath, $retryPath)) {
      if (Test-Path -LiteralPath $path) { throw 'Final-publication retry left burn-after-read residue.' }
    }
    Assert-NoFailureScriptResidue $runtimeRoot 'Final-publication retry cleanup'
  } finally {
    $env:AI_USAGE_FINAL_PUBLISH_FAULT = ''
    foreach ($process in @($owner, $retry)) {
      if ($process -and -not $process.HasExited) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
      }
      if ($process) { try { $process.Dispose() } catch {} }
    }
    if (Test-Path -LiteralPath $instrumented) { [IO.File]::Delete($instrumented) }
  }
}

function Invoke-FailureCoordinationLockScenario {
  $scenarioRoot = Join-Path $sandbox 'failure-coordination-lock'
  $scenarioTemp = Join-Path $scenarioRoot 'temp'
  $profile = Join-Path $scenarioRoot 'profile'
  New-Item -ItemType Directory -Force -Path $scenarioTemp, $profile | Out-Null
  if (Test-Path -LiteralPath $codeBurnLog) { [IO.File]::Delete($codeBurnLog) }

  $env:TEMP = $scenarioTemp
  $env:TMP = $scenarioTemp
  $env:USERPROFILE = $profile
  $env:AI_USAGE_STUB_FAILURE = 'report|week|claude'
  $env:AI_USAGE_STUB_FAILURE_MODE = 'before'
  $env:AI_USAGE_CCUSAGE_EXIT = '0'
  $env:AI_USAGE_CCUSAGE_MODE = ''

  $wrapperPath = Join-Path $scenarioRoot 'normal-wrapper.ps1'
  [IO.File]::WriteAllText($wrapperPath, @'
param(
  [Parameter(Mandatory = $true)][string]$GeneratorPath,
  [Parameter(Mandatory = $true)][int]$DeleteAfter,
  [string]$Period = ''
)
function Start-Process {
  param([Parameter(Position = 0)][string]$FilePath)
  [IO.File]::AppendAllText($env:AI_USAGE_TEST_LAUNCH_LOG, $FilePath + "`r`n", [Text.Encoding]::ASCII)
}
& $GeneratorPath -DeleteAfter $DeleteAfter
'@, [Text.Encoding]::ASCII)

  $runtimeRoot = Join-Path $scenarioTemp 'ClaudeUsage'
  $dataPath = Join-Path $runtimeRoot 'data.js'
  $htmlPath = Join-Path $runtimeRoot 'report.html'
  $statePath = Join-Path $runtimeRoot 'report-run.state'
  $ownerPath = Join-Path $runtimeRoot 'report-run.owner.json'
  $retryPath = Join-Path $runtimeRoot 'report-retry.request'
  $barrierReady = Join-Path $scenarioRoot 'failure.ready'
  $barrierRelease = Join-Path $scenarioRoot 'failure.release'
  $ownerLog = Join-Path $scenarioRoot 'owner-launch.log'
  $reuserLog = Join-Path $scenarioRoot 'reuser-launch.log'
  $owner = $null
  $reuser = $null
  $stateLock = $null
  $ownerLock = $null
  try {
    $env:AI_USAGE_CODEBURN_BARRIER_MATCH = 'report|week|claude'
    $env:AI_USAGE_CODEBURN_BARRIER_READY = $barrierReady
    $env:AI_USAGE_CODEBURN_BARRIER_RELEASE = $barrierRelease
    $owner = Start-NormalGenerator $wrapperPath $ownerLog 3
    $barrierDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $barrierReady) -and [DateTime]::UtcNow -lt $barrierDeadline) {
      if ($owner.HasExited) { break }
      Start-Sleep -Milliseconds 20
    }
    if (-not (Test-Path -LiteralPath $barrierReady)) {
      throw 'The coordination-lock probe did not reach its failure barrier.'
    }
    $stateLock = [IO.File]::Open($statePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $ownerLock = [IO.File]::Open($ownerPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    [IO.File]::WriteAllText($barrierRelease, 'release', [Text.Encoding]::ASCII)

    $terminal = $null
    $terminalDeadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not $terminal -and [DateTime]::UtcNow -lt $terminalDeadline) {
      $candidate = Read-Snapshot $dataPath
      if ($candidate -and $candidate.complete -eq $true -and $candidate.generationError) {
        $terminal = $candidate
      } else {
        Start-Sleep -Milliseconds 20
      }
    }
    if (-not $terminal -or $terminal.generationError.stage -ne 'remaining_usage') {
      throw 'The coordination-lock probe did not publish its terminal failed snapshot.'
    }
    if ([IO.File]::ReadAllText($statePath).Trim() -ne 'active' -or
        ([IO.File]::ReadAllText($ownerPath) | ConvertFrom-Json).phase -ne 'active') {
      throw 'The coordination-lock probe did not preserve both stale active records.'
    }

    $reuser = Start-NormalGenerator $wrapperPath $reuserLog 0 '' @{
      AI_USAGE_STUB_FAILURE = ''
      AI_USAGE_CODEBURN_BARRIER_MATCH = ''
      AI_USAGE_CODEBURN_BARRIER_READY = ''
      AI_USAGE_CODEBURN_BARRIER_RELEASE = ''
    }
    Start-Sleep -Milliseconds 500
    $reuser.Refresh()
    if ($reuser.HasExited -or (Test-Path -LiteralPath $reuserLog) -or
        (Test-Path -LiteralPath $retryPath)) {
      throw 'A failed-run kernel signal did not override two stale active coordination files.'
    }

    $ownerResult = Get-CompletedProcessResult $owner 10000
    if ($ownerResult.ExitCode -ne 0) { throw "Coordination-lock owner failed: $($ownerResult.Output)" }
    $reuser.Refresh()
    if ($reuser.HasExited -or (Test-Path -LiteralPath $reuserLog) -or
        (Test-Path -LiteralPath $retryPath)) {
      throw 'A stale active record became reusable after its failure Event disappeared.'
    }
    $stateLock.Dispose()
    $stateLock = $null
    $ownerLock.Dispose()
    $ownerLock = $null
    $reuserResult = Get-CompletedProcessResult $reuser 45000
    if ($reuserResult.ExitCode -ne 0) { throw "Coordination-lock fresh run failed: $($reuserResult.Output)" }
    if (@(Get-Content -LiteralPath $codeBurnLog -ErrorAction SilentlyContinue).Count -ne 17) {
      throw 'The coordination-lock scenario did not run one failed and one fresh aggregation.'
    }
    foreach ($path in @($dataPath, $htmlPath, $statePath, $ownerPath, $retryPath)) {
      if (Test-Path -LiteralPath $path) { throw 'Coordination-lock recovery left runtime residue.' }
    }
    Assert-NoFailureScriptResidue $runtimeRoot 'Coordination-lock recovery'
  } finally {
    $env:AI_USAGE_CODEBURN_BARRIER_MATCH = ''
    $env:AI_USAGE_CODEBURN_BARRIER_READY = ''
    $env:AI_USAGE_CODEBURN_BARRIER_RELEASE = ''
    if ($stateLock) { $stateLock.Dispose() }
    if ($ownerLock) { $ownerLock.Dispose() }
    foreach ($process in @($owner, $reuser)) {
      if ($process -and -not $process.HasExited) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
      }
      if ($process) { try { $process.Dispose() } catch {} }
    }
  }
}

function Invoke-MissingFailureSignalScenario {
  $scenarioRoot = Join-Path $sandbox 'missing-failure-signal'
  $scenarioTemp = Join-Path $scenarioRoot 'temp'
  $profile = Join-Path $scenarioRoot 'profile'
  New-Item -ItemType Directory -Force -Path $scenarioTemp, $profile | Out-Null
  if (Test-Path -LiteralPath $codeBurnLog) { [IO.File]::Delete($codeBurnLog) }

  $env:TEMP = $scenarioTemp
  $env:TMP = $scenarioTemp
  $env:USERPROFILE = $profile
  $env:AI_USAGE_STUB_FAILURE = ''
  $env:AI_USAGE_STUB_FAILURE_MODE = 'before'
  $env:AI_USAGE_CCUSAGE_EXIT = '0'
  $env:AI_USAGE_CCUSAGE_MODE = ''

  $wrapperPath = Join-Path $scenarioRoot 'normal-wrapper.ps1'
  [IO.File]::WriteAllText($wrapperPath, @'
param(
  [Parameter(Mandatory = $true)][string]$GeneratorPath,
  [Parameter(Mandatory = $true)][int]$DeleteAfter,
  [string]$Period = ''
)
function Start-Process {
  param([Parameter(Position = 0)][string]$FilePath)
  [IO.File]::AppendAllText($env:AI_USAGE_TEST_LAUNCH_LOG, $FilePath + "`r`n", [Text.Encoding]::ASCII)
}
& $GeneratorPath -DeleteAfter $DeleteAfter
'@, [Text.Encoding]::ASCII)

  $runtimeRoot = Join-Path $scenarioTemp 'ClaudeUsage'
  New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
  $dataPath = Join-Path $runtimeRoot 'data.js'
  $htmlPath = Join-Path $runtimeRoot 'report.html'
  $statePath = Join-Path $runtimeRoot 'report-run.state'
  $ownerPath = Join-Path $runtimeRoot 'report-run.owner.json'
  $launchLog = Join-Path $scenarioRoot 'launch.log'
  $runId = [guid]::NewGuid().ToString('N')
  [IO.File]::WriteAllText($htmlPath, '<!doctype html>', [Text.Encoding]::ASCII)
  [IO.File]::WriteAllText($statePath, 'active', [Text.Encoding]::ASCII)
  [IO.File]::WriteAllText($ownerPath, ([ordered]@{
    version = 1
    phase = 'active'
    runId = $runId
    ownerPid = $PID
    ownerStartUtcTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
    primaryPeriod = '30days'
    periods = @('30days', 'week', 'all')
  } | ConvertTo-Json -Depth 5 -Compress), [Text.Encoding]::UTF8)

  $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $mutex = [Threading.Mutex]::new($false, "Global\AIUsage-CodeBurn-$userSid")
  $mutexHeld = $false
  $process = $null
  try {
    try { $mutexHeld = $mutex.WaitOne([TimeSpan]::FromMinutes(5)) }
    catch [Threading.AbandonedMutexException] { $mutexHeld = $true }
    if (-not $mutexHeld) { throw 'Could not acquire the report mutex for the missing-Event probe.' }

    $process = Start-NormalGenerator $wrapperPath $launchLog 0
    Start-Sleep -Milliseconds 750
    $process.Refresh()
    if ($process.HasExited -or (Test-Path -LiteralPath $launchLog) -or
        (Test-Path -LiteralPath $codeBurnLog)) {
      throw 'A live active owner without its required failure Event was reused.'
    }

    $mutex.ReleaseMutex()
    $mutexHeld = $false
    $result = Get-CompletedProcessResult $process 45000
    if ($result.ExitCode -ne 0) { throw "Fresh run after a missing failure Event failed: $($result.Output)" }
    if (@(Get-Content -LiteralPath $codeBurnLog -ErrorAction SilentlyContinue).Count -ne 12) {
      throw 'The missing failure Event scenario did not perform exactly one fresh aggregation.'
    }
    foreach ($path in @($dataPath, $htmlPath, $statePath, $ownerPath)) {
      if (Test-Path -LiteralPath $path) { throw 'Missing failure Event recovery left runtime residue.' }
    }
    Assert-NoFailureScriptResidue $runtimeRoot 'Missing failure Event recovery'
  } finally {
    if ($mutexHeld) { try { $mutex.ReleaseMutex() } catch {} }
    try { $mutex.Dispose() } catch {}
    if ($process -and -not $process.HasExited) {
      try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($process) { try { $process.Dispose() } catch {} }
  }
}

function Invoke-PostLaunchCoordinationFailureScenario {
  $scenarioRoot = Join-Path $sandbox 'post-launch-coordination-failure'
  $scenarioTemp = Join-Path $scenarioRoot 'temp'
  $profile = Join-Path $scenarioRoot 'profile'
  New-Item -ItemType Directory -Force -Path $scenarioTemp, $profile | Out-Null
  if (Test-Path -LiteralPath $codeBurnLog) { [IO.File]::Delete($codeBurnLog) }

  $env:TEMP = $scenarioTemp
  $env:TMP = $scenarioTemp
  $env:USERPROFILE = $profile
  $env:AI_USAGE_STUB_FAILURE = ''
  $env:AI_USAGE_STUB_FAILURE_MODE = 'before'
  $env:AI_USAGE_CCUSAGE_EXIT = '0'
  $env:AI_USAGE_CCUSAGE_MODE = ''

  $wrapperPath = Join-Path $scenarioRoot 'barrier-wrapper.ps1'
  [IO.File]::WriteAllText($wrapperPath, @'
param(
  [Parameter(Mandatory = $true)][string]$GeneratorPath,
  [Parameter(Mandatory = $true)][int]$DeleteAfter,
  [string]$Period = ''
)
function Start-Process {
  param([Parameter(Position = 0)][string]$FilePath)
  [IO.File]::AppendAllText($env:AI_USAGE_TEST_LAUNCH_LOG, $FilePath + "`r`n", [Text.Encoding]::ASCII)
  [IO.File]::WriteAllText($env:AI_USAGE_LAUNCH_BARRIER_READY, 'ready', [Text.Encoding]::ASCII)
  while (-not (Test-Path -LiteralPath $env:AI_USAGE_LAUNCH_BARRIER_RELEASE)) {
    Start-Sleep -Milliseconds 20
  }
}
& $GeneratorPath -DeleteAfter $DeleteAfter
'@, [Text.Encoding]::ASCII)

  $runtimeRoot = Join-Path $scenarioTemp 'ClaudeUsage'
  $dataPath = Join-Path $runtimeRoot 'data.js'
  $failurePath = Join-Path $runtimeRoot 'failure.js'
  $htmlPath = Join-Path $runtimeRoot 'report.html'
  $statePath = Join-Path $runtimeRoot 'report-run.state'
  $ownerPath = Join-Path $runtimeRoot 'report-run.owner.json'
  $retryPath = Join-Path $runtimeRoot 'report-retry.request'
  $readyPath = Join-Path $scenarioRoot 'launch.ready'
  $releasePath = Join-Path $scenarioRoot 'launch.release'
  $launchLog = Join-Path $scenarioRoot 'launch.log'
  $process = $null
  $stateLock = $null
  $ownerLock = $null
  try {
    $process = Start-NormalGenerator $wrapperPath $launchLog 3 '' @{
      AI_USAGE_LAUNCH_BARRIER_READY = $readyPath
      AI_USAGE_LAUNCH_BARRIER_RELEASE = $releasePath
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $readyPath) -and [DateTime]::UtcNow -lt $deadline) {
      if ($process.HasExited) { break }
      Start-Sleep -Milliseconds 20
    }
    if (-not (Test-Path -LiteralPath $readyPath)) {
      throw 'The post-launch coordination probe did not reach its launch barrier.'
    }
    $stateLock = [IO.File]::Open($statePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $ownerLock = [IO.File]::Open($ownerPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    [IO.File]::WriteAllText($releasePath, 'release', [Text.Encoding]::ASCII)

    $failure = $null
    $failureDeadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not $failure -and [DateTime]::UtcNow -lt $failureDeadline) {
      if (Test-Path -LiteralPath $failurePath) { $failure = Read-StartupFailure $failurePath }
      if (-not $failure) { Start-Sleep -Milliseconds 20 }
    }
    if (-not $failure -or $failure.reason -ne 'initial_generation_failed' -or
        $failure.stage -ne 'startup') {
      throw 'A post-launch coordination write failure did not publish a terminal startup signal.'
    }
    $process.Refresh()
    if ($process.HasExited -or -not (Test-Path -LiteralPath $htmlPath)) {
      throw 'The post-launch failure skipped its normal browser read grace.'
    }
    if (@(Get-Content -LiteralPath $codeBurnLog -ErrorAction SilentlyContinue).Count) {
      throw 'The post-launch coordination failure invoked CodeBurn.'
    }

    $stateLock.Dispose()
    $stateLock = $null
    $ownerLock.Dispose()
    $ownerLock = $null
    $result = Get-CompletedProcessResult $process 10000
    if ($result.ExitCode -eq 0) { throw 'The post-launch coordination failure returned success.' }
    foreach ($path in @($dataPath, $failurePath, $htmlPath, $statePath, $ownerPath, $retryPath)) {
      if (Test-Path -LiteralPath $path) { throw 'Post-launch coordination failure left runtime residue.' }
    }
    Assert-NoFailureScriptResidue $runtimeRoot 'Post-launch coordination failure cleanup'
  } finally {
    if ($stateLock) { $stateLock.Dispose() }
    if ($ownerLock) { $ownerLock.Dispose() }
    if ($process -and -not $process.HasExited) {
      try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($process) { try { $process.Dispose() } catch {} }
  }
}

function Invoke-StartingReuseScenario {
  $scenarioRoot = Join-Path $sandbox 'starting-page-reuse'
  $scenarioTemp = Join-Path $scenarioRoot 'temp'
  $profile = Join-Path $scenarioRoot 'profile'
  New-Item -ItemType Directory -Force -Path $scenarioTemp, $profile | Out-Null
  foreach ($log in @($codeBurnLog, $ccusageLog)) {
    if (Test-Path -LiteralPath $log) { [IO.File]::Delete($log) }
  }
  $env:TEMP = $scenarioTemp
  $env:TMP = $scenarioTemp
  $env:USERPROFILE = $profile
  $env:AI_USAGE_STUB_FAILURE = ''
  $env:AI_USAGE_STUB_FAILURE_MODE = 'before'
  $env:AI_USAGE_CCUSAGE_EXIT = '0'
  $env:AI_USAGE_CCUSAGE_MODE = ''

  $instrumented = Join-Path $runtime 'Generate-ClaudeReport-starting-race.ps1'
  $generatorText = [IO.File]::ReadAllText((Join-Path $runtime 'Generate-ClaudeReport.ps1'))
  $anchor = "    if (-not (Write-RunOwnerPhase 'starting')) { throw 'Could not publish the dashboard owner record.' }"
  $anchorIndex = $generatorText.IndexOf($anchor)
  if ($anchorIndex -lt 0) { throw 'Could not locate the starting owner publication barrier.' }
  $newline = if ($generatorText.Contains("`r`n")) { "`r`n" } else { "`n" }
  $barrier = @'
    if ($env:AI_USAGE_STARTING_BARRIER_READY) {
      [IO.File]::WriteAllText($env:AI_USAGE_STARTING_BARRIER_READY, 'ready', [Text.Encoding]::ASCII)
      while (-not (Test-Path -LiteralPath $env:AI_USAGE_STARTING_BARRIER_RELEASE)) {
        Start-Sleep -Milliseconds 20
      }
    }
'@
  $insertAt = $anchorIndex + $anchor.Length
  $generatorText = $generatorText.Insert($insertAt, $newline + $barrier.TrimEnd("`r", "`n"))
  [IO.File]::WriteAllText($instrumented, $generatorText, [Text.Encoding]::ASCII)

  $wrapperPath = Join-Path $scenarioRoot 'normal-wrapper.ps1'
  [IO.File]::WriteAllText($wrapperPath, @'
param(
  [Parameter(Mandatory = $true)][string]$GeneratorPath,
  [Parameter(Mandatory = $true)][int]$DeleteAfter,
  [string]$Period = ''
)
function Start-Process {
  param([Parameter(Position = 0)][string]$FilePath)
  [IO.File]::AppendAllText($env:AI_USAGE_TEST_LAUNCH_LOG, $FilePath + "`r`n", [Text.Encoding]::ASCII)
}
& $GeneratorPath -DeleteAfter $DeleteAfter -Period $Period
'@, [Text.Encoding]::ASCII)

  $readyPath = Join-Path $scenarioRoot 'owner-starting.ready'
  $releasePath = Join-Path $scenarioRoot 'owner-starting.release'
  $ownerLog = Join-Path $scenarioRoot 'owner-launch.log'
  $reuseLog = Join-Path $scenarioRoot 'reuse-launch.log'
  $owner = $null
  $reuser = $null
  try {
    $owner = Start-NormalGenerator $wrapperPath $ownerLog 3 '30days' @{
      AI_USAGE_STARTING_BARRIER_READY = $readyPath
      AI_USAGE_STARTING_BARRIER_RELEASE = $releasePath
    } $instrumented
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $readyPath) -and [DateTime]::UtcNow -lt $deadline) {
      if ($owner.HasExited) { break }
      Start-Sleep -Milliseconds 20
      $owner.Refresh()
    }
    if (-not (Test-Path -LiteralPath $readyPath)) {
      $early = Get-CompletedProcessResult $owner 1000
      throw "The owner did not reach the starting barrier: $($early.Output)"
    }

    $reuser = Start-NormalGenerator $wrapperPath $reuseLog 3 'all' $null $instrumented
    Start-Sleep -Milliseconds 300
    $reuser.Refresh()
    if ($reuser.HasExited -or (Test-Path -LiteralPath $reuseLog) -or (Test-Path -LiteralPath $codeBurnLog)) {
      throw 'A launch in the starting window did not wait for the reusable page boundary.'
    }
    [IO.File]::WriteAllText($releasePath, 'release', [Text.Encoding]::ASCII)

    $reuseResult = Get-CompletedProcessResult $reuser 10000
    if ($reuseResult.ExitCode -ne 0) { throw "Starting-window page reuse failed: $($reuseResult.Output)" }
    $owner.Refresh()
    if ($owner.HasExited) { throw 'The starting-window reuser waited for the complete owner run.' }
    $reuseTargets = @(Get-Content -LiteralPath $reuseLog -ErrorAction SilentlyContinue)
    if ($reuseTargets.Count -ne 1 -or $reuseTargets[0] -notmatch '\?period=all$') {
      throw 'The reused page did not preserve the second launch period in its URL.'
    }

    $ownerResult = Get-CompletedProcessResult $owner 45000
    if ($ownerResult.ExitCode -ne 0) { throw "Starting-window owner failed: $($ownerResult.Output)" }
    if (@(Get-Content -LiteralPath $codeBurnLog -ErrorAction SilentlyContinue).Count -ne 12) {
      throw 'Starting-window page reuse triggered a duplicate aggregation.'
    }
  } finally {
    foreach ($process in @($owner, $reuser)) {
      if ($process -and -not $process.HasExited) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
      }
      if ($process) { try { $process.Dispose() } catch {} }
    }
    if (Test-Path -LiteralPath $instrumented) { [IO.File]::Delete($instrumented) }
  }
}

function Invoke-UnplannedPeriodScenario {
  $scenarioRoot = Join-Path $sandbox 'unplanned-period-wait'
  $scenarioTemp = Join-Path $scenarioRoot 'temp'
  $profile = Join-Path $scenarioRoot 'profile'
  New-Item -ItemType Directory -Force -Path $scenarioTemp, $profile | Out-Null
  foreach ($log in @($codeBurnLog, $ccusageLog)) {
    if (Test-Path -LiteralPath $log) { [IO.File]::Delete($log) }
  }
  $env:TEMP = $scenarioTemp
  $env:TMP = $scenarioTemp
  $env:USERPROFILE = $profile
  $env:AI_USAGE_STUB_FAILURE = ''
  $env:AI_USAGE_STUB_FAILURE_MODE = 'before'
  $env:AI_USAGE_CCUSAGE_EXIT = '0'
  $env:AI_USAGE_CCUSAGE_MODE = ''

  $wrapperPath = Join-Path $scenarioRoot 'normal-wrapper.ps1'
  [IO.File]::WriteAllText($wrapperPath, @'
param(
  [Parameter(Mandatory = $true)][string]$GeneratorPath,
  [Parameter(Mandatory = $true)][int]$DeleteAfter,
  [string]$Period = ''
)
function Start-Process {
  param([Parameter(Position = 0)][string]$FilePath)
  [IO.File]::AppendAllText($env:AI_USAGE_TEST_LAUNCH_LOG, $FilePath + "`r`n", [Text.Encoding]::ASCII)
}
& $GeneratorPath -DeleteAfter $DeleteAfter -Period $Period
'@, [Text.Encoding]::ASCII)
  $runtimeRoot = Join-Path $scenarioTemp 'ClaudeUsage'
  $statePath = Join-Path $runtimeRoot 'report-run.state'
  $ownerLog = Join-Path $scenarioRoot 'owner-launch.log'
  $waitingLog = Join-Path $scenarioRoot 'waiting-launch.log'
  $owner = $null
  $waiter = $null
  try {
    $owner = Start-NormalGenerator $wrapperPath $ownerLog 1 '30days'
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
      if ((Test-Path -LiteralPath $statePath) -and [IO.File]::ReadAllText($statePath).Trim() -eq 'active') { break }
      if ($owner.HasExited) { break }
      Start-Sleep -Milliseconds 20
      $owner.Refresh()
    }
    if (-not (Test-Path -LiteralPath $statePath) -or [IO.File]::ReadAllText($statePath).Trim() -ne 'active') {
      throw 'The unplanned-period owner never published an active page.'
    }
    $waiter = Start-NormalGenerator $wrapperPath $waitingLog 0 'today'
    Start-Sleep -Milliseconds 300
    $waiter.Refresh()
    if ($waiter.HasExited -or (Test-Path -LiteralPath $waitingLog)) {
      throw 'A period absent from the owner plan incorrectly reused its page.'
    }
    $ownerResult = Get-CompletedProcessResult $owner 45000
    if ($ownerResult.ExitCode -ne 0) { throw "Unplanned-period owner failed: $($ownerResult.Output)" }
    $waiterResult = Get-CompletedProcessResult $waiter 45000
    if ($waiterResult.ExitCode -ne 0) { throw "Unplanned-period fresh run failed: $($waiterResult.Output)" }
    $targets = @(Get-Content -LiteralPath $waitingLog -ErrorAction SilentlyContinue)
    if ($targets.Count -ne 1 -or $targets[0] -notmatch '\?period=today$') {
      throw 'The fresh unplanned-period run did not launch its requested period.'
    }
    if (@(Get-Content -LiteralPath $codeBurnLog -ErrorAction SilentlyContinue).Count -ne 28) {
      throw 'The unplanned period did not run exactly one fresh aggregation after the owner.'
    }
  } finally {
    foreach ($process in @($owner, $waiter)) {
      if ($process -and -not $process.HasExited) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
      }
      if ($process) { try { $process.Dispose() } catch {} }
    }
  }
}

function Invoke-NormalLifecycleScenario(
  [string]$Name,
  [bool]$LockRawScratch,
  [string]$OwnerPeriod = '30days',
  [string]$RecoveryPeriod = '30days',
  [bool]$LockRunStateOnComplete = $false
) {
  $scenarioRoot = Join-Path $sandbox $Name
  $scenarioTemp = Join-Path $scenarioRoot 'temp'
  $profile = Join-Path $scenarioRoot 'profile'
  New-Item -ItemType Directory -Force -Path $scenarioTemp, $profile | Out-Null
  foreach ($log in @($codeBurnLog, $ccusageLog)) {
    if (Test-Path -LiteralPath $log) { [IO.File]::Delete($log) }
  }
  $env:TEMP = $scenarioTemp
  $env:TMP = $scenarioTemp
  $env:USERPROFILE = $profile
  $env:AI_USAGE_STUB_FAILURE = ''
  $env:AI_USAGE_STUB_FAILURE_MODE = 'before'
  $env:AI_USAGE_CCUSAGE_EXIT = '0'
  $env:AI_USAGE_CCUSAGE_MODE = ''

  $wrapperPath = Join-Path $scenarioRoot 'normal-wrapper.ps1'
  $wrapperText = @'
param(
  [Parameter(Mandatory = $true)][string]$GeneratorPath,
  [Parameter(Mandatory = $true)][int]$DeleteAfter,
  [string]$Period = ''
)
function Start-Process {
  param([Parameter(Position = 0)][string]$FilePath)
  [IO.File]::AppendAllText($env:AI_USAGE_TEST_LAUNCH_LOG, $FilePath + "`r`n", [Text.Encoding]::ASCII)
}
if ($Period) {
  & $GeneratorPath -DeleteAfter $DeleteAfter -Period $Period
} else {
  & $GeneratorPath -DeleteAfter $DeleteAfter
}
'@
  [IO.File]::WriteAllText($wrapperPath, $wrapperText, [Text.Encoding]::ASCII)

  $runtimeRoot = Join-Path $scenarioTemp 'ClaudeUsage'
  $dataPath = Join-Path $runtimeRoot 'data.js'
  $failurePath = Join-Path $runtimeRoot 'failure.js'
  $htmlPath = Join-Path $runtimeRoot 'report.html'
  $statePath = Join-Path $runtimeRoot 'report-run.state'
  $ownerPath = Join-Path $runtimeRoot 'report-run.owner.json'
  $leasePath = Join-Path $runtimeRoot 'report-read.lease'
  $rawPath = Join-Path $runtimeRoot ("_{0}-claude-report.json" -f $OwnerPeriod)
  $ownerLaunchLog = Join-Path $scenarioRoot 'owner-launch.log'
  $reuseLaunchLog = Join-Path $scenarioRoot 'reuse-launch.log'
  $recoveryLaunchLog = Join-Path $scenarioRoot 'recovery-launch.log'
  $owner = $null
  $reuser = $null
  $recovery = $null
  $rawLock = $null
  $stateLock = $null
  $ownerCallCount = @(@($OwnerPeriod, 'week', '30days', 'all') | Select-Object -Unique).Count * 4
  $recoveryCallCount = @(@($RecoveryPeriod, 'week', '30days', 'all') | Select-Object -Unique).Count * 4
  try {
    $owner = Start-NormalGenerator $wrapperPath $ownerLaunchLog 1 $OwnerPeriod
    $first = $null
    $firstDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not $first -and [DateTime]::UtcNow -lt $firstDeadline) {
      if ($owner.HasExited) { break }
      $first = Read-Snapshot $dataPath
      if (-not $first) { Start-Sleep -Milliseconds 20 }
    }
    if (-not $first) {
      $early = Get-CompletedProcessResult $owner 1000
      throw "Normal lifecycle did not publish a first snapshot: $($early.Output)"
    }
    if ([IO.File]::ReadAllText($statePath).Trim() -ne 'active') {
      throw 'Normal lifecycle was not active after its first snapshot.'
    }
    $initialLease = [int64]([IO.File]::ReadAllText($leasePath).Trim())
    if ($LockRawScratch) {
      $rawDeadline = [DateTime]::UtcNow.AddSeconds(5)
      while (-not (Test-Path -LiteralPath $rawPath) -and [DateTime]::UtcNow -lt $rawDeadline) {
        Start-Sleep -Milliseconds 10
      }
      if (-not (Test-Path -LiteralPath $rawPath)) { throw 'Normal lifecycle raw scratch was not available for the lock probe.' }
      $rawLock = [IO.File]::Open($rawPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    }

    $reuser = Start-NormalGenerator $wrapperPath $reuseLaunchLog 1 $OwnerPeriod
    $reuseResult = Get-CompletedProcessResult $reuser 10000
    if ($reuseResult.ExitCode -ne 0) { throw "Concurrent page reuse failed: $($reuseResult.Output)" }
    if (@(Get-Content -LiteralPath $reuseLaunchLog -ErrorAction SilentlyContinue).Count -ne 1) {
      throw 'Concurrent launch did not reuse exactly one active page.'
    }
    if (@(Get-Content -LiteralPath $reuseLaunchLog -ErrorAction SilentlyContinue)[0] -notmatch ('\?period=' + [regex]::Escape($OwnerPeriod) + '$')) {
      throw 'Concurrent page reuse did not preserve the requested period in its URL.'
    }
    $renewedLease = [int64]([IO.File]::ReadAllText($leasePath).Trim())
    if ($renewedLease -le $initialLease) { throw 'Concurrent page reuse did not advance the read lease.' }

    $states = New-Object Collections.Generic.List[string]
    $lastSnapshot = $first
    $ownerDeadline = [DateTime]::UtcNow.AddSeconds(45)
    while (-not $owner.HasExited -and [DateTime]::UtcNow -lt $ownerDeadline) {
      if (Test-Path -LiteralPath $statePath) {
        try { [void]$states.Add([IO.File]::ReadAllText($statePath).Trim()) } catch {}
      }
      $candidate = Read-Snapshot $dataPath
      if ($candidate) {
        $lastSnapshot = $candidate
        if ($LockRunStateOnComplete -and $candidate.complete -eq $true -and -not $stateLock) {
          try {
            $stateLock = [IO.File]::Open($statePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            if ([IO.File]::ReadAllText($statePath).Trim() -ne 'active') {
              $stateLock.Dispose()
              $stateLock = $null
            }
          } catch {
            if ($stateLock) { $stateLock.Dispose(); $stateLock = $null }
          }
        }
      }
      Start-Sleep -Milliseconds 10
      $owner.Refresh()
    }
    $ownerResult = Get-CompletedProcessResult $owner 1000
    if ($ownerResult.ExitCode -ne 0) { throw "Normal lifecycle owner failed: $($ownerResult.Output)" }
    if (-not $lastSnapshot -or $lastSnapshot.complete -ne $true) {
      throw 'Normal lifecycle never exposed a complete snapshot before burn-after-read.'
    }
    if (@(Get-Content -LiteralPath $ownerLaunchLog -ErrorAction SilentlyContinue).Count -ne 1) {
      throw 'Normal lifecycle owner did not launch exactly one page.'
    }
    if (@(Get-Content -LiteralPath $codeBurnLog -ErrorAction SilentlyContinue).Count -ne $ownerCallCount) {
      throw 'Concurrent page reuse started a second CodeBurn aggregation.'
    }

    if ($LockRawScratch -or $LockRunStateOnComplete) {
      if ($LockRawScratch -and (-not (Test-Path -LiteralPath $rawPath) -or
          -not (Test-Path -LiteralPath $statePath) -or
          [IO.File]::ReadAllText($statePath).Trim() -ne 'cleanup_failed')) {
        throw 'A locked raw collector file did not leave observable cleanup_failed state.'
      }
      if ($LockRunStateOnComplete -and (-not $stateLock -or
          -not (Test-Path -LiteralPath $dataPath) -or
          -not (Test-Path -LiteralPath $htmlPath) -or
          [IO.File]::ReadAllText($statePath).Trim() -ne 'active')) {
        throw 'A locked closing-state write did not preserve the complete active page.'
      }
      if ($rawLock) { $rawLock.Dispose(); $rawLock = $null }
      if ($stateLock) { $stateLock.Dispose(); $stateLock = $null }
      $recovery = Start-NormalGenerator $wrapperPath $recoveryLaunchLog 1 $RecoveryPeriod
      $recoveryResult = Get-CompletedProcessResult $recovery 45000
      if ($recoveryResult.ExitCode -ne 0) { throw "Cleanup recovery launch failed: $($recoveryResult.Output)" }
      if (@(Get-Content -LiteralPath $codeBurnLog -ErrorAction SilentlyContinue).Count -ne ($ownerCallCount + $recoveryCallCount)) {
        throw 'Cleanup recovery did not run exactly one fresh aggregation.'
      }
    } elseif ($states -notcontains 'closing') {
      throw 'Normal lifecycle never published its closing state.'
    }

    foreach ($path in @($dataPath, $failurePath, $htmlPath, $statePath, $leasePath, $ownerPath, $rawPath)) {
      if (Test-Path -LiteralPath $path) { throw "Normal lifecycle retained burn-after-read file $([IO.Path]::GetFileName($path))." }
    }
    Assert-NoFailureScriptResidue $runtimeRoot 'Normal lifecycle cleanup'
  } finally {
    if ($rawLock) { $rawLock.Dispose() }
    if ($stateLock) { $stateLock.Dispose() }
    foreach ($process in @($owner, $reuser, $recovery)) {
      if ($process -and -not $process.HasExited) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
      }
      if ($process) { try { $process.Dispose() } catch {} }
    }
  }
}

function Invoke-DebugScratchRecoveryScenario([string]$Name) {
  $scenarioRoot = Join-Path $sandbox $Name
  $scenarioTemp = Join-Path $scenarioRoot 'temp'
  $profile = Join-Path $scenarioRoot 'profile'
  New-Item -ItemType Directory -Force -Path $scenarioTemp, $profile | Out-Null
  foreach ($log in @($codeBurnLog, $ccusageLog)) {
    if (Test-Path -LiteralPath $log) { [IO.File]::Delete($log) }
  }

  $env:TEMP = $scenarioTemp
  $env:TMP = $scenarioTemp
  $env:USERPROFILE = $profile
  $env:AI_USAGE_STUB_FAILURE = ''
  $env:AI_USAGE_STUB_FAILURE_MODE = 'before'
  $env:AI_USAGE_CCUSAGE_EXIT = '0'
  $env:AI_USAGE_CCUSAGE_MODE = ''

  $wrapperPath = Join-Path $scenarioRoot 'normal-wrapper.ps1'
  $wrapperText = @'
param(
  [Parameter(Mandatory = $true)][string]$GeneratorPath,
  [Parameter(Mandatory = $true)][int]$DeleteAfter
)
function Start-Process {
  param([Parameter(Position = 0)][string]$FilePath)
  [IO.File]::AppendAllText($env:AI_USAGE_TEST_LAUNCH_LOG, $FilePath + "`r`n", [Text.Encoding]::ASCII)
}
& $GeneratorPath -DeleteAfter $DeleteAfter
'@
  [IO.File]::WriteAllText($wrapperPath, $wrapperText, [Text.Encoding]::ASCII)

  $runtimeRoot = Join-Path $scenarioTemp 'ClaudeUsage'
  $barrierReady = Join-Path $scenarioRoot 'retained.ready'
  $barrierRelease = Join-Path $scenarioRoot 'retained.release'
  $retained = $null
  $recovery = $null
  $rawLock = $null
  try {
    $env:AI_USAGE_CODEBURN_BARRIER_MATCH = 'status|30days|claude'
    $env:AI_USAGE_CODEBURN_BARRIER_READY = $barrierReady
    $env:AI_USAGE_CODEBURN_BARRIER_RELEASE = $barrierRelease
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' +
      (Join-Path $runtime 'Generate-ClaudeReport.ps1') + '" -NoLaunch -KeepFile'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $retained = New-Object Diagnostics.Process
    $retained.StartInfo = $startInfo
    if (-not $retained.Start()) { throw 'Could not start the retained scratch recovery probe.' }

    $debugDirectory = $null
    $rawPath = $null
    $rawDeadline = [DateTime]::UtcNow.AddSeconds(20)
    while ((-not $rawLock -or -not (Test-Path -LiteralPath $barrierReady)) -and
        [DateTime]::UtcNow -lt $rawDeadline) {
      $debugDirectory = Get-ChildItem -LiteralPath $runtimeRoot -Directory -Filter 'debug-*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if ($debugDirectory -and -not $rawLock) {
        $rawPath = Join-Path $debugDirectory.FullName '_30days-claude-report.json'
        if (Test-Path -LiteralPath $rawPath) {
          try {
            $rawLock = [IO.File]::Open($rawPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
          } catch {}
        }
      }
      if (-not $rawLock) { Start-Sleep -Milliseconds 10 }
    }
    if (-not $rawLock -or -not (Test-Path -LiteralPath $barrierReady)) {
      throw 'Could not lock retained raw scratch at the cleanup barrier.'
    }
    [IO.File]::WriteAllText($barrierRelease, 'release', [Text.Encoding]::ASCII)

    $retainedResult = Get-CompletedProcessResult $retained 45000
    if ($retainedResult.ExitCode -ne 0) { throw "Retained scratch probe failed: $($retainedResult.Output)" }
    $debugData = Join-Path $debugDirectory.FullName 'data.js'
    $debugHtml = Join-Path $debugDirectory.FullName 'report.html'
    $snapshot = Read-Snapshot $debugData
    if (-not $snapshot -or $snapshot.complete -ne $true -or
        -not (Test-Path -LiteralPath $debugHtml) -or -not (Test-Path -LiteralPath $rawPath)) {
      throw 'A locked retained run did not preserve its final page and raw cleanup residue.'
    }

    $rawLock.Dispose()
    $rawLock = $null
    $env:AI_USAGE_CODEBURN_BARRIER_MATCH = ''
    $env:AI_USAGE_CODEBURN_BARRIER_READY = ''
    $env:AI_USAGE_CODEBURN_BARRIER_RELEASE = ''
    $recoveryLaunchLog = Join-Path $scenarioRoot 'recovery-launch.log'
    $recovery = Start-NormalGenerator $wrapperPath $recoveryLaunchLog 1
    $recoveryResult = Get-CompletedProcessResult $recovery 45000
    if ($recoveryResult.ExitCode -ne 0) { throw "Retained scratch recovery failed: $($recoveryResult.Output)" }
    if (Test-Path -LiteralPath $rawPath) {
      throw 'A later normal run did not remove exact raw scratch from the retained debug directory.'
    }
    if (-not (Test-Path -LiteralPath $debugData) -or -not (Test-Path -LiteralPath $debugHtml)) {
      throw 'Retained scratch recovery removed the explicit debug snapshot itself.'
    }
    Assert-NoFailureScriptResidue $debugDirectory.FullName 'Successful retained debug run'
    if (@(Get-Content -LiteralPath $codeBurnLog -ErrorAction SilentlyContinue).Count -ne 24) {
      throw 'Retained scratch recovery did not run exactly two complete aggregations.'
    }
  } finally {
    if (-not (Test-Path -LiteralPath $barrierRelease)) {
      try { [IO.File]::WriteAllText($barrierRelease, 'release', [Text.Encoding]::ASCII) } catch {}
    }
    $env:AI_USAGE_CODEBURN_BARRIER_MATCH = ''
    $env:AI_USAGE_CODEBURN_BARRIER_READY = ''
    $env:AI_USAGE_CODEBURN_BARRIER_RELEASE = ''
    if ($rawLock) { $rawLock.Dispose() }
    foreach ($process in @($retained, $recovery)) {
      if ($process -and -not $process.HasExited) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
      }
      if ($process) { try { $process.Dispose() } catch {} }
    }
  }
}

function Get-TestDescendantProcessIdentities([int]$RootProcessId) {
  $rows = @(Get-CimInstance Win32_Process -ErrorAction Stop |
    Select-Object @{ Name = 'Id'; Expression = { [int]$_.ProcessId } },
                  @{ Name = 'ParentId'; Expression = { [int]$_.ParentProcessId } })
  $pending = New-Object Collections.Generic.Queue[int]
  $pending.Enqueue($RootProcessId)
  $ids = New-Object Collections.Generic.List[int]
  while ($pending.Count) {
    $parentId = $pending.Dequeue()
    foreach ($row in @($rows | Where-Object { $_.ParentId -eq $parentId })) {
      if ($ids.Contains($row.Id)) { continue }
      $ids.Add($row.Id)
      $pending.Enqueue($row.Id)
    }
  }

  $identities = New-Object Collections.Generic.List[object]
  foreach ($id in $ids) {
    $process = Get-Process -Id $id -ErrorAction SilentlyContinue
    if (-not $process) { continue }
    try {
      $identities.Add([pscustomobject]@{
        Id = [int]$id
        StartTicks = [int64]$process.StartTime.ToFileTimeUtc()
      })
    } catch {}
  }
  return $identities.ToArray()
}

function Test-TestProcessIdentityAlive($Identity) {
  $process = Get-Process -Id ([int]$Identity.Id) -ErrorAction SilentlyContinue
  if (-not $process) { return $false }
  try { return [int64]$process.StartTime.ToFileTimeUtc() -eq [int64]$Identity.StartTicks } catch { return $false }
}

function Stop-TestProcessIdentity($Identity) {
  if (-not (Test-TestProcessIdentityAlive $Identity)) { return }
  try { Stop-Process -Id ([int]$Identity.Id) -Force -ErrorAction SilentlyContinue } catch {}
}

function Invoke-CollectorJobCompletionScenario {
  $scenarioRoot = Join-Path $sandbox 'collector-job-completion'
  New-Item -ItemType Directory -Force -Path $scenarioRoot | Out-Null
  $generatorText = [IO.File]::ReadAllText((Join-Path $runtime 'Generate-ClaudeReport.ps1'))
  $jobPattern = "(?s)# COLLECTOR_JOB_CSHARP_BEGIN\s+Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@\s+# COLLECTOR_JOB_CSHARP_END"
  $jobMatch = [regex]::Match($generatorText, $jobPattern)
  if (-not $jobMatch.Success) { throw 'Could not extract the collector Job implementation.' }
  if (-not ('AiUsage.CollectorJob' -as [type])) {
    Add-Type -TypeDefinition $jobMatch.Groups[1].Value
  }

  $childScript = Join-Path $scenarioRoot 'job-child.ps1'
  $rootScript = Join-Path $scenarioRoot 'job-root.ps1'
  $detachedRootScript = Join-Path $scenarioRoot 'job-detached-root.ps1'
  $naturalChildScript = Join-Path $scenarioRoot 'job-natural-child.ps1'
  $naturalRootScript = Join-Path $scenarioRoot 'job-natural-root.ps1'
  $identitiesPath = Join-Path $scenarioRoot 'children.txt'
  $readyPath = Join-Path $scenarioRoot 'ready.txt'
  $detachedIdentityPath = Join-Path $scenarioRoot 'detached-child.txt'
  $detachedReadyPath = Join-Path $scenarioRoot 'detached-ready.txt'
  $naturalIdentityPath = Join-Path $scenarioRoot 'natural-child.txt'
  [IO.File]::WriteAllText($childScript, @'
while ($true) { Start-Sleep -Seconds 1 }
'@, [Text.Encoding]::ASCII)
  [IO.File]::WriteAllText($rootScript, @'
param(
  [Parameter(Mandatory = $true)][string]$ChildScript,
  [Parameter(Mandatory = $true)][string]$IdentitiesPath,
  [Parameter(Mandatory = $true)][string]$ReadyPath
)
$children = New-Object Collections.Generic.List[Diagnostics.Process]
for ($index = 0; $index -lt 16; $index++) {
  $info = New-Object Diagnostics.ProcessStartInfo
  $info.FileName = 'powershell.exe'
  $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ChildScript + '"'
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $child = [Diagnostics.Process]::Start($info)
  $children.Add($child)
}
$lines = @($children | ForEach-Object {
  $_.Refresh()
  [string]$_.Id + '|' + [string]$_.StartTime.ToFileTimeUtc()
})
[IO.File]::WriteAllLines($IdentitiesPath, $lines, [Text.Encoding]::ASCII)
[IO.File]::WriteAllText($ReadyPath, 'ready', [Text.Encoding]::ASCII)
while ($true) { Start-Sleep -Seconds 1 }
'@, [Text.Encoding]::ASCII)
  [IO.File]::WriteAllText($detachedRootScript, @'
param(
  [Parameter(Mandatory = $true)][string]$ChildScript,
  [Parameter(Mandatory = $true)][string]$IdentityPath,
  [Parameter(Mandatory = $true)][string]$ReadyPath
)
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = 'powershell.exe'
$info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ChildScript + '"'
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$child = [Diagnostics.Process]::Start($info)
$child.Refresh()
[IO.File]::WriteAllText(
  $IdentityPath,
  ([string]$child.Id + '|' + [string]$child.StartTime.ToFileTimeUtc()),
  [Text.Encoding]::ASCII
)
[IO.File]::WriteAllText($ReadyPath, 'ready', [Text.Encoding]::ASCII)
$child.Dispose()
'@, [Text.Encoding]::ASCII)
  [IO.File]::WriteAllText($naturalChildScript, @'
Start-Sleep -Milliseconds 500
'@, [Text.Encoding]::ASCII)
  [IO.File]::WriteAllText($naturalRootScript, @'
param(
  [Parameter(Mandatory = $true)][string]$ChildScript,
  [Parameter(Mandatory = $true)][string]$IdentityPath
)
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = 'powershell.exe'
$info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ChildScript + '"'
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$child = [Diagnostics.Process]::Start($info)
$child.Refresh()
[IO.File]::WriteAllText(
  $IdentityPath,
  ([string]$child.Id + '|' + [string]$child.StartTime.ToFileTimeUtc()),
  [Text.Encoding]::ASCII
)
$child.Dispose()
'@, [Text.Encoding]::ASCII)

  $powerShellExe = Join-Path $PSHOME 'powershell.exe'
  $commandLine = '"' + $powerShellExe + '" -NoProfile -ExecutionPolicy Bypass -File "' + $rootScript +
    '" -ChildScript "' + $childScript + '" -IdentitiesPath "' + $identitiesPath +
    '" -ReadyPath "' + $readyPath + '"'
  $job = $null
  $detachedJob = $null
  $naturalJob = $null
  $identities = @()
  $detachedIdentity = $null
  $naturalIdentity = $null
  try {
    $naturalCommandLine = '"' + $powerShellExe + '" -NoProfile -ExecutionPolicy Bypass -File "' +
      $naturalRootScript + '" -ChildScript "' + $naturalChildScript + '" -IdentityPath "' +
      $naturalIdentityPath + '"'
    $naturalJob = [AiUsage.CollectorJob]::Start(
      $powerShellExe,
      $naturalCommandLine,
      $scenarioRoot,
      [string[]]@(),
      [string[]]@()
    )
    $naturalDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $naturalIdentityPath) -and [DateTime]::UtcNow -lt $naturalDeadline) {
      Start-Sleep -Milliseconds 20
    }
    if (-not (Test-Path -LiteralPath $naturalIdentityPath)) {
      throw 'The natural collector Job did not start its descendant.'
    }
    $naturalParts = [IO.File]::ReadAllText($naturalIdentityPath).Trim() -split '\|', 2
    $naturalIdentity = [pscustomobject]@{ Id = [int]$naturalParts[0]; StartTicks = [int64]$naturalParts[1] }
    if (-not $naturalJob.WaitForExit(10000) -or -not $naturalJob.HasExited -or
        $naturalJob.ExitCode -ne 0 -or (Test-TestProcessIdentityAlive $naturalIdentity)) {
      throw 'Collector WaitForExit did not observe a naturally empty Job process tree.'
    }

    $job = [AiUsage.CollectorJob]::Start(
      $powerShellExe,
      $commandLine,
      $scenarioRoot,
      [string[]]@(),
      [string[]]@()
    )
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $readyPath) -and [DateTime]::UtcNow -lt $deadline) {
      if ($job.HasExited) { break }
      Start-Sleep -Milliseconds 20
    }
    if (-not (Test-Path -LiteralPath $readyPath)) {
      throw 'The collector Job completion probe did not start its descendants.'
    }
    $identities = @(Get-Content -LiteralPath $identitiesPath | ForEach-Object {
      $parts = $_ -split '\|', 2
      [pscustomobject]@{ Id = [int]$parts[0]; StartTicks = [int64]$parts[1] }
    })
    if ($identities.Count -ne 16 -or
        @($identities | Where-Object { -not (Test-TestProcessIdentityAlive $_) }).Count) {
      throw 'The collector Job completion probe did not observe every live descendant.'
    }
    if (-not $job.TerminateAndWait(10000)) {
      throw 'TerminateAndWait did not observe the collector Job becoming empty.'
    }
    if (@($identities | Where-Object { Test-TestProcessIdentityAlive $_ }).Count) {
      throw 'TerminateAndWait returned while a collector Job descendant was still alive.'
    }

    $detachedCommandLine = '"' + $powerShellExe + '" -NoProfile -ExecutionPolicy Bypass -File "' +
      $detachedRootScript + '" -ChildScript "' + $childScript + '" -IdentityPath "' +
      $detachedIdentityPath + '" -ReadyPath "' + $detachedReadyPath + '"'
    $detachedJob = [AiUsage.CollectorJob]::Start(
      $powerShellExe,
      $detachedCommandLine,
      $scenarioRoot,
      [string[]]@(),
      [string[]]@()
    )
    $detachedDeadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $detachedReadyPath) -and [DateTime]::UtcNow -lt $detachedDeadline) {
      Start-Sleep -Milliseconds 20
    }
    if (-not (Test-Path -LiteralPath $detachedReadyPath)) {
      throw 'The detached collector root did not publish its child identity.'
    }
    $parts = [IO.File]::ReadAllText($detachedIdentityPath).Trim() -split '\|', 2
    $detachedIdentity = [pscustomobject]@{ Id = [int]$parts[0]; StartTicks = [int64]$parts[1] }
    if (-not (Test-TestProcessIdentityAlive $detachedIdentity)) {
      throw 'The detached collector descendant exited before the completion-boundary probe.'
    }
    if ($detachedJob.WaitForExit(500)) {
      throw 'Collector WaitForExit reported completion while a detached Job descendant was alive.'
    }
    if (-not $detachedJob.TerminateAndWait(10000) -or
        (Test-TestProcessIdentityAlive $detachedIdentity)) {
      throw 'Detached collector cleanup returned before its Job became empty.'
    }
  } finally {
    if ($naturalJob) { try { $naturalJob.Dispose() } catch {} }
    if ($job) { try { $job.Dispose() } catch {} }
    if ($detachedJob) { try { $detachedJob.Dispose() } catch {} }
    if ($naturalIdentity) { Stop-TestProcessIdentity $naturalIdentity }
    foreach ($identity in @($identities)) { Stop-TestProcessIdentity $identity }
    if ($detachedIdentity) { Stop-TestProcessIdentity $detachedIdentity }
  }
}

function Invoke-CollectorParentTerminationScenario {
  $scenarioRoot = Join-Path $sandbox 'collector-parent-termination'
  $scenarioTemp = Join-Path $scenarioRoot 'temp'
  $profile = Join-Path $scenarioRoot 'profile'
  New-Item -ItemType Directory -Force -Path $scenarioTemp, $profile | Out-Null
  $codeBurnPidPath = Join-Path $scenarioRoot 'codeburn.pid'
  $ccusagePidPath = Join-Path $scenarioRoot 'ccusage.pid'
  $codeBurnPoisonPath = Join-Path $scenarioRoot 'codeburn-poison.txt'
  $ccusagePoisonPath = Join-Path $scenarioRoot 'ccusage-poison.txt'
  $overlapPath = Join-Path $scenarioRoot 'codeburn-overlap.txt'

  $env:TEMP = $scenarioTemp
  $env:TMP = $scenarioTemp
  $env:USERPROFILE = $profile
  $env:AI_USAGE_STUB_FAILURE = ''
  $env:AI_USAGE_STUB_FAILURE_MODE = 'before'
  $env:AI_USAGE_CCUSAGE_EXIT = '0'
  $env:AI_USAGE_CCUSAGE_MODE = ''
  $env:AI_USAGE_CODEBURN_HANG = 'report|30days|claude'
  $env:AI_USAGE_CODEBURN_PID = $codeBurnPidPath
  $env:AI_USAGE_CODEBURN_POISON = $codeBurnPoisonPath
  $env:AI_USAGE_CCUSAGE_HANG = '1'
  $env:AI_USAGE_CCUSAGE_PID = $ccusagePidPath
  $env:AI_USAGE_CCUSAGE_POISON = $ccusagePoisonPath
  $env:AI_USAGE_CODEBURN_OVERLAP_MUTEX = 'Global\AIUsage-Test-CodeBurn-' + [guid]::NewGuid().ToString('N')
  $env:AI_USAGE_CODEBURN_OVERLAP_MARKER = $overlapPath

  $generator = $null
  $recovery = $null
  $identities = @()
  try {
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' +
      (Join-Path $runtime 'Generate-ClaudeReport.ps1') + '" -NoLaunch -KeepFile'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $generator = New-Object Diagnostics.Process
    $generator.StartInfo = $startInfo
    if (-not $generator.Start()) { throw 'Could not start the collector parent-termination probe.' }

    $readyDeadline = [DateTime]::UtcNow.AddSeconds(20)
    while ((-not (Test-Path -LiteralPath $codeBurnPidPath) -or
        -not (Test-Path -LiteralPath $ccusagePidPath)) -and [DateTime]::UtcNow -lt $readyDeadline) {
      $generator.Refresh()
      if ($generator.HasExited) {
        $generator.WaitForExit()
        throw ('The collector parent-termination probe exited early: ' +
          $generator.StandardError.ReadToEnd() + $generator.StandardOutput.ReadToEnd())
      }
      Start-Sleep -Milliseconds 20
    }
    if (-not (Test-Path -LiteralPath $codeBurnPidPath) -or
        -not (Test-Path -LiteralPath $ccusagePidPath)) {
      throw 'The collector parent-termination probe did not start both collectors.'
    }

    $codeBurnPid = [int][IO.File]::ReadAllText($codeBurnPidPath)
    $ccusagePid = [int][IO.File]::ReadAllText($ccusagePidPath)
    $identities = @(Get-TestDescendantProcessIdentities $generator.Id)
    if ($identities.Count -lt 2 -or
        $identities.Id -notcontains $codeBurnPid -or $identities.Id -notcontains $ccusagePid) {
      throw 'The collector parent-termination probe could not identify both live process trees.'
    }

    $callsBeforeWaiter = @(Get-Content -LiteralPath $codeBurnLog -ErrorAction SilentlyContinue).Count
    $recoveryInfo = New-Object Diagnostics.ProcessStartInfo
    $recoveryInfo.FileName = 'powershell.exe'
    $recoveryInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' +
      (Join-Path $runtime 'Generate-ClaudeReport.ps1') + '" -NoLaunch -KeepFile'
    $recoveryInfo.UseShellExecute = $false
    $recoveryInfo.CreateNoWindow = $true
    $recoveryInfo.RedirectStandardOutput = $true
    $recoveryInfo.RedirectStandardError = $true
    $recoveryInfo.EnvironmentVariables['AI_USAGE_CODEBURN_HANG'] = ''
    $recoveryInfo.EnvironmentVariables['AI_USAGE_CCUSAGE_HANG'] = ''
    $recovery = New-Object Diagnostics.Process
    $recovery.StartInfo = $recoveryInfo
    if (-not $recovery.Start()) { throw 'Could not start the waiting recovery generator.' }
    Start-Sleep -Milliseconds 500
    $recovery.Refresh()
    if ($recovery.HasExited -or
        @(Get-Content -LiteralPath $codeBurnLog -ErrorAction SilentlyContinue).Count -ne $callsBeforeWaiter) {
      throw 'The replacement generator did not wait behind the live report mutex owner.'
    }

    # Kill only the generator after the replacement is already waiting. Its Job
    # handles must terminate every descendant before the abandoned-lock waiter
    # is allowed to invoke another collector.
    Stop-Process -Id $generator.Id -Force
    $recoveryResult = Get-CompletedProcessResult $recovery 45000
    if ($recoveryResult.ExitCode -ne 0) {
      throw "A waiting generator did not recover after force termination: $($recoveryResult.Output)"
    }
    $recoveryHtml = @($recoveryResult.Output -split "`r?`n" | Where-Object { $_ -match 'report\.html$' }) | Select-Object -Last 1
    if (-not $recoveryHtml) { throw 'The recovered generator did not return a report path.' }
    $recoverySnapshot = Read-Snapshot (Join-Path (Split-Path $recoveryHtml -Parent) 'data.js')
    if (-not $recoverySnapshot -or $recoverySnapshot.complete -ne $true -or $recoverySnapshot.generationError) {
      throw 'The waiting generator did not publish a complete recovered snapshot.'
    }
    if (Test-Path -LiteralPath $overlapPath) {
      throw 'A new CodeBurn process overlapped the force-terminated generator descendant.'
    }
    if (-not $generator.WaitForExit(10000)) { throw 'The force-terminated generator did not exit.' }

    $exitDeadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
      $alive = @($identities | Where-Object { Test-TestProcessIdentityAlive $_ })
      if (-not $alive.Count) { break }
      Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $exitDeadline)
    if ($alive.Count) { throw 'A force-terminated generator left a collector descendant alive.' }
    if ((Test-Path -LiteralPath $codeBurnPoisonPath) -or (Test-Path -LiteralPath $ccusagePoisonPath)) {
      throw 'A collector descendant continued running after its generator was force-terminated.'
    }
  } finally {
    $env:AI_USAGE_CODEBURN_HANG = ''
    $env:AI_USAGE_CCUSAGE_HANG = ''
    if ($generator -and -not $generator.HasExited) {
      try { Stop-Process -Id $generator.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($recovery -and -not $recovery.HasExited) {
      try { Stop-Process -Id $recovery.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    foreach ($identity in @($identities | Sort-Object Id -Descending)) {
      Stop-TestProcessIdentity $identity
    }
    if ($generator) { try { $generator.Dispose() } catch {} }
    if ($recovery) { try { $recovery.Dispose() } catch {} }
  }
}

function Invoke-LegacyCollectorAbandonmentScenario {
  $scenarioRoot = Join-Path $sandbox 'legacy-collector-abandonment'
  $scenarioTemp = Join-Path $scenarioRoot 'temp'
  $profile = Join-Path $scenarioRoot 'profile'
  $legacyPackage = Join-Path $scenarioRoot 'node_modules\codeburn'
  New-Item -ItemType Directory -Force -Path $scenarioTemp, $profile, $legacyPackage | Out-Null
  $childScript = Join-Path $legacyPackage 'legacy-child.ps1'
  $ownerScript = Join-Path $scenarioRoot 'legacy-owner.ps1'
  $ownerReady = Join-Path $scenarioRoot 'owner.ready'
  $childReady = Join-Path $scenarioRoot 'child.ready'
  $childRelease = Join-Path $scenarioRoot 'child.release'
  $overlapPath = Join-Path $scenarioRoot 'codeburn-overlap.txt'
  $overlapMutexName = 'Global\AIUsage-Test-Legacy-CodeBurn-' + [guid]::NewGuid().ToString('N')

  [IO.File]::WriteAllText($childScript, @'
param([string]$ReadyPath, [string]$ReleasePath, [string]$MutexName)
$mutex = [Threading.Mutex]::new($false, $MutexName)
$held = $false
try {
  try { $held = $mutex.WaitOne([TimeSpan]::FromSeconds(10)) }
  catch [Threading.AbandonedMutexException] { $held = $true }
  if (-not $held) { throw 'Could not acquire the legacy overlap mutex.' }
  [IO.File]::WriteAllText($ReadyPath, [string]$PID, [Text.Encoding]::ASCII)
  while (-not (Test-Path -LiteralPath $ReleasePath)) { Start-Sleep -Milliseconds 20 }
} finally {
  if ($held) { try { $mutex.ReleaseMutex() } catch {} }
  try { $mutex.Dispose() } catch {}
}
'@, [Text.Encoding]::ASCII)
  [IO.File]::WriteAllText($ownerScript, @'
param([string]$UserSid, [string]$ChildScript, [string]$ChildReady, [string]$ChildRelease, [string]$OwnerReady, [string]$MutexName)
$global = [Threading.Mutex]::new($false, "Global\AIUsage-CodeBurn-$UserSid")
$local = [Threading.Mutex]::new($false, 'Local\AIUsage-CodeBurn')
$globalHeld = $false
$localHeld = $false
try {
  try { $globalHeld = $global.WaitOne([TimeSpan]::FromSeconds(10)) }
  catch [Threading.AbandonedMutexException] { $globalHeld = $true }
  try { $localHeld = $local.WaitOne([TimeSpan]::FromSeconds(10)) }
  catch [Threading.AbandonedMutexException] { $localHeld = $true }
  if (-not $globalHeld -or -not $localHeld) { throw 'Could not acquire legacy report mutexes.' }
  $info = New-Object Diagnostics.ProcessStartInfo
  $info.FileName = 'powershell.exe'
  $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ChildScript +
    '" -ReadyPath "' + $ChildReady + '" -ReleasePath "' + $ChildRelease +
    '" -MutexName "' + $MutexName + '"'
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $child = [Diagnostics.Process]::Start($info)
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  while (-not (Test-Path -LiteralPath $ChildReady) -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 20
  }
  if (-not (Test-Path -LiteralPath $ChildReady)) { throw 'Legacy child did not start.' }
  [IO.File]::WriteAllText($OwnerReady, [string]$child.Id, [Text.Encoding]::ASCII)
  while ($true) { Start-Sleep -Seconds 1 }
} finally {
  if ($localHeld) { try { $local.ReleaseMutex() } catch {} }
  if ($globalHeld) { try { $global.ReleaseMutex() } catch {} }
  try { $local.Dispose() } catch {}
  try { $global.Dispose() } catch {}
}
'@, [Text.Encoding]::ASCII)

  $previousTemp = $env:TEMP
  $previousTmp = $env:TMP
  $previousProfile = $env:USERPROFILE
  $previousOverlapMutex = $env:AI_USAGE_CODEBURN_OVERLAP_MUTEX
  $previousOverlapMarker = $env:AI_USAGE_CODEBURN_OVERLAP_MARKER
  $owner = $null
  $recovery = $null
  $childPid = 0
  try {
    $env:TEMP = $scenarioTemp
    $env:TMP = $scenarioTemp
    $env:USERPROFILE = $profile
    $env:AI_USAGE_CODEBURN_OVERLAP_MUTEX = $overlapMutexName
    $env:AI_USAGE_CODEBURN_OVERLAP_MARKER = $overlapPath
    if (Test-Path -LiteralPath $codeBurnLog) { [IO.File]::Delete($codeBurnLog) }

    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $ownerInfo = New-Object Diagnostics.ProcessStartInfo
    $ownerInfo.FileName = 'powershell.exe'
    $ownerInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ownerScript +
      '" -UserSid "' + $userSid + '" -ChildScript "' + $childScript +
      '" -ChildReady "' + $childReady + '" -ChildRelease "' + $childRelease +
      '" -OwnerReady "' + $ownerReady + '" -MutexName "' + $overlapMutexName + '"'
    $ownerInfo.UseShellExecute = $false
    $ownerInfo.CreateNoWindow = $true
    $owner = New-Object Diagnostics.Process
    $owner.StartInfo = $ownerInfo
    if (-not $owner.Start()) { throw 'Could not start the legacy mutex owner.' }
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $ownerReady) -and [DateTime]::UtcNow -lt $readyDeadline) {
      if ($owner.HasExited) { break }
      Start-Sleep -Milliseconds 20
      $owner.Refresh()
    }
    if (-not (Test-Path -LiteralPath $ownerReady)) { throw 'Legacy mutex owner did not become ready.' }
    $childPid = [int]([IO.File]::ReadAllText($ownerReady).Trim())

    $recoveryInfo = New-Object Diagnostics.ProcessStartInfo
    $recoveryInfo.FileName = 'powershell.exe'
    $recoveryInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' +
      (Join-Path $runtime 'Generate-ClaudeReport.ps1') + '" -NoLaunch -KeepFile'
    $recoveryInfo.UseShellExecute = $false
    $recoveryInfo.CreateNoWindow = $true
    $recoveryInfo.RedirectStandardOutput = $true
    $recoveryInfo.RedirectStandardError = $true
    $recovery = New-Object Diagnostics.Process
    $recovery.StartInfo = $recoveryInfo
    if (-not $recovery.Start()) { throw 'Could not start the legacy-abandonment waiter.' }
    Start-Sleep -Milliseconds 500
    $recovery.Refresh()
    if ($recovery.HasExited -or (Test-Path -LiteralPath $codeBurnLog)) {
      throw 'Legacy-abandonment waiter did not remain behind the live mutex owner.'
    }

    Stop-Process -Id $owner.Id -Force
    Start-Sleep -Milliseconds 500
    $recovery.Refresh()
    if (-not (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) {
      throw 'Legacy non-Job collector did not survive its parent long enough to exercise recovery.'
    }
    if ($recovery.HasExited -or (Test-Path -LiteralPath $codeBurnLog) -or (Test-Path -LiteralPath $overlapPath)) {
      throw 'Recovered generator did not wait for the legacy non-Job collector to exit.'
    }

    [IO.File]::WriteAllText($childRelease, 'release', [Text.Encoding]::ASCII)
    $childDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while ((Get-Process -Id $childPid -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $childDeadline) {
      Start-Sleep -Milliseconds 25
    }
    $result = Get-CompletedProcessResult $recovery 45000
    if ($result.ExitCode -ne 0 -or (Test-Path -LiteralPath $overlapPath)) {
      throw "Legacy abandoned-lock recovery failed or overlapped: $($result.Output)"
    }
  } finally {
    $env:TEMP = $previousTemp
    $env:TMP = $previousTmp
    $env:USERPROFILE = $previousProfile
    $env:AI_USAGE_CODEBURN_OVERLAP_MUTEX = $previousOverlapMutex
    $env:AI_USAGE_CODEBURN_OVERLAP_MARKER = $previousOverlapMarker
    foreach ($process in @($recovery, $owner)) {
      if ($process -and -not $process.HasExited) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
      }
      if ($process) { try { $process.Dispose() } catch {} }
    }
    if ($childPid -gt 0 -and (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) {
      try { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue } catch {}
    }
  }
}

try {
  New-Item -ItemType Directory -Force -Path $runtime, $stubs | Out-Null
  Copy-Item (Join-Path $root 'src\*') -Destination $runtime -Recurse -Force
  $env:AI_USAGE_PATH_TOKEN = 'expanded-path-must-not-be-used'

  $codeBurnStub = @'
$ErrorActionPreference = 'Stop'
$stubArgs = @($args)
if ($stubArgs -contains '--version') { Write-Output '0.9.19'; exit 0 }
function Value-After([string]$Name) {
  $index = [Array]::IndexOf($stubArgs, $Name)
  if ($index -ge 0 -and $index + 1 -lt $stubArgs.Count) { return [string]$stubArgs[$index + 1] }
  return ''
}
$operation = [string]$stubArgs[0]
$period = Value-After '--period'
$provider = Value-After '--provider'
$overlapMutex = $null
$overlapHeld = $false
if ($env:AI_USAGE_CODEBURN_OVERLAP_MUTEX) {
  $overlapMutex = [Threading.Mutex]::new($false, $env:AI_USAGE_CODEBURN_OVERLAP_MUTEX)
  try {
    $overlapHeld = $overlapMutex.WaitOne([TimeSpan]::Zero)
  } catch [Threading.AbandonedMutexException] {
    $overlapHeld = $true
  }
  if (-not $overlapHeld -and $env:AI_USAGE_CODEBURN_OVERLAP_MARKER) {
    [IO.File]::WriteAllText($env:AI_USAGE_CODEBURN_OVERLAP_MARKER, 'overlap', [Text.Encoding]::ASCII)
  }
}
Start-Sleep -Milliseconds 120
[IO.File]::AppendAllText($env:AI_USAGE_CODEBURN_LOG, "$operation|$period|$provider`r`n", [Text.Encoding]::ASCII)
if ($env:AI_USAGE_CODEBURN_BARRIER_MATCH -eq "$operation|$period|$provider") {
  [IO.File]::WriteAllText($env:AI_USAGE_CODEBURN_BARRIER_READY, 'ready', [Text.Encoding]::ASCII)
  while (-not (Test-Path -LiteralPath $env:AI_USAGE_CODEBURN_BARRIER_RELEASE)) {
    Start-Sleep -Milliseconds 20
  }
}
if ($env:AI_USAGE_CODEBURN_HANG -eq "$operation|$period|$provider") {
  [IO.File]::WriteAllText($env:AI_USAGE_CODEBURN_PID, [string]$PID, [Text.Encoding]::ASCII)
  Start-Sleep -Milliseconds 2000
  [IO.File]::WriteAllText($env:AI_USAGE_CODEBURN_POISON, 'orphaned', [Text.Encoding]::ASCII)
  while ($true) { Start-Sleep -Seconds 1 }
}
if ($overlapHeld) { try { $overlapMutex.ReleaseMutex() } catch {} }
if ($overlapMutex) { try { $overlapMutex.Dispose() } catch {} }
$isFailure = $env:AI_USAGE_STUB_FAILURE -eq "$operation|$period|$provider"
if ($isFailure -and $env:AI_USAGE_STUB_FAILURE_MODE -eq 'before') { exit 17 }
if ($isFailure -and $env:AI_USAGE_STUB_FAILURE_MODE -eq 'oversized') {
  [Console]::Out.Write(('x' * (17 * 1024 * 1024)))
  exit 0
}
$periodFactor = switch ($period) { 'week' { 1.0 } '30days' { 2.0 } 'all' { 3.0 } default { 0.5 } }
$providerFactor = if ($provider -eq 'claude') { 10.0 } else { 4.0 }
$cost = $periodFactor * $providerFactor
$overviewCost = switch ($env:AI_USAGE_STUB_FAILURE_MODE) {
  'null-cost' { if ($isFailure) { $null } else { $cost }; break }
  'bool-cost' { if ($isFailure) { $true } else { $cost }; break }
  'string-cost' { if ($isFailure) { '' } else { $cost }; break }
  default { $cost }
}
$calls = [int]($cost * 10)
$modelName = if ($provider -eq 'claude') { 'claude-stub-model' } else { 'codex-stub-model' }
if ($operation -eq 'report') {
  if ($isFailure -and $env:AI_USAGE_STUB_FAILURE_MODE -eq 'malformed') {
    Write-Output '{broken'
    exit 0
  }
  $daily = [object[]]@([pscustomobject][ordered]@{
    date = '2026-08-29'; cost = $cost; savings = 0; calls = $calls
    turns = 4; editTurns = 2; oneShotTurns = 1; oneShotRate = 50
  })
  $models = [object[]]@([pscustomobject][ordered]@{
    name = $modelName; calls = $calls; cost = $cost; savings = 0; estimatedCost = 0
    inputTokens = 100; outputTokens = 20; cacheReadTokens = 50; cacheWriteTokens = 10
  })
  $projects = [object[]]@([pscustomobject][ordered]@{
    name = "$provider-project"; path = "C:\Stub\$provider"; cost = $cost; savings = 0
    avgCostPerSession = ($cost / 2); calls = $calls; sessions = 2
  })
  $topSessions = [object[]]@([pscustomobject][ordered]@{
    sessionId = "$provider-session"; project = "$provider-project"; date = '2026-08-29'
    cost = $cost; savings = 0; calls = $calls
  })
  if ($isFailure) {
    if ($env:AI_USAGE_STUB_FAILURE_MODE -eq 'daily-object') { $daily = [pscustomobject][ordered]@{} }
    if ($env:AI_USAGE_STUB_FAILURE_MODE -eq 'daily-null') { $daily = [object[]]@($null) }
    if ($env:AI_USAGE_STUB_FAILURE_MODE -eq 'daily-bool-cost') { $daily[0].cost = $true }
    if ($env:AI_USAGE_STUB_FAILURE_MODE -eq 'daily-missing-date') {
      $daily = [object[]]@([pscustomobject][ordered]@{ cost = $cost; calls = $calls })
    }
    if ($env:AI_USAGE_STUB_FAILURE_MODE -eq 'daily-number-date') {
      $daily = [object[]]@([pscustomobject][ordered]@{ date = 20260829; cost = $cost; calls = $calls })
    }
    if ($env:AI_USAGE_STUB_FAILURE_MODE -eq 'daily-html-date') {
      $daily = [object[]]@([pscustomobject][ordered]@{ date = '<img src=x onerror=alert(1)>'; cost = $cost; calls = $calls })
    }
    if ($env:AI_USAGE_STUB_FAILURE_MODE -eq 'daily-invalid-calendar-date') {
      $daily = [object[]]@([pscustomobject][ordered]@{ date = '2026-99-99'; cost = $cost; calls = $calls })
    }
    if ($env:AI_USAGE_STUB_FAILURE_MODE -eq 'models-object') { $models = [pscustomobject][ordered]@{} }
    if ($env:AI_USAGE_STUB_FAILURE_MODE -eq 'model-bool-cost') { $models[0].cost = $true }
    if ($env:AI_USAGE_STUB_FAILURE_MODE -eq 'projects-object') { $projects = [pscustomobject][ordered]@{} }
    if ($env:AI_USAGE_STUB_FAILURE_MODE -eq 'project-string-cost') { $projects[0].cost = '1' }
    if ($env:AI_USAGE_STUB_FAILURE_MODE -eq 'sessions-object') { $topSessions = [pscustomobject][ordered]@{} }
    if ($env:AI_USAGE_STUB_FAILURE_MODE -eq 'session-null-cost') { $topSessions[0].cost = $null }
    if ($env:AI_USAGE_STUB_FAILURE_MODE -eq 'output-extra-fields') {
      Add-Member -InputObject $daily[0] -NotePropertyName 'prompt' -NotePropertyValue 'private prompt' -Force
      Add-Member -InputObject $models[0] -NotePropertyName 'toolArguments' -NotePropertyValue 'private args' -Force
      Add-Member -InputObject $projects[0] -NotePropertyName 'authorization' -NotePropertyValue 'Bearer private-token-value' -Force
      Add-Member -InputObject $topSessions[0] -NotePropertyName 'providerUrl' -NotePropertyValue 'https://private.example.test' -Force
    }
    if ($env:AI_USAGE_STUB_FAILURE_MODE -eq 'output-nested-fields') {
      $nestedSecret = [pscustomobject]@{ authorization = 'Bearer_DTO_BYPASS' }
      $daily[0].oneShotRate = $nestedSecret
      $projects[0].name = $nestedSecret
      $topSessions[0].project = $nestedSecret
    }
  }
  $reportCurrency = switch ($env:AI_USAGE_STUB_FAILURE_MODE) {
    'currency' { if ($isFailure) { 'EUR' } else { 'USD' }; break }
    'cny-no-rate' { 'CNY'; break }
    'currency-bool' { if ($isFailure) { $true } else { 'USD' }; break }
    'currency-array' { if ($isFailure) { ,([object[]]@('USD')) } else { 'USD' }; break }
    'currency-newline' { if ($isFailure) { "USD`n" } else { 'USD' }; break }
    default { 'USD' }
  }
  [pscustomobject][ordered]@{
    currency = $reportCurrency
    overview = [ordered]@{
      cost = $overviewCost; netCost = $cost
      savings = if ($isFailure -and $env:AI_USAGE_STUB_FAILURE_MODE -eq 'output-nested-fields') {
        [pscustomobject]@{ authorization = 'Bearer_DTO_BYPASS' }
      } else { 0 }
      estimatedCost = 0
      calls = $calls; sessions = 2; cacheHitPercent = 50
      tokens = [ordered]@{ input = 100; output = 20; cacheRead = 50; cacheWrite = 10 }
    }
    daily = $daily
    models = $models
    projects = $projects
    topSessions = $topSessions
  } | ConvertTo-Json -Depth 20 -Compress
  if ($isFailure -and $env:AI_USAGE_STUB_FAILURE_MODE -eq 'after') { exit 17 }
  exit 0
}
if ($operation -eq 'status') {
  $statusModelName = if ($isFailure -and $env:AI_USAGE_STUB_FAILURE_MODE -eq 'after') { 'poison-status-model' } else { $modelName }
  $topModels = [object[]]@([pscustomobject][ordered]@{
    name = $statusModelName; calls = $calls; cost = $cost; savingsUSD = 0; estimatedCostUSD = 0
  })
  if ($isFailure) {
    switch ($env:AI_USAGE_STUB_FAILURE_MODE) {
      'status-string' { $topModels = 'bad'; break }
      'status-number' { $topModels = 42; break }
      'status-missing-name' {
        $topModels = [object[]]@([pscustomobject][ordered]@{
          calls = $calls; cost = $cost; savingsUSD = 0; estimatedCostUSD = 0
        })
        break
      }
      'status-missing-calls' {
        $topModels = [object[]]@([pscustomobject][ordered]@{
          name = $statusModelName; cost = $cost; savingsUSD = 0; estimatedCostUSD = 0
        })
        break
      }
      'status-calls-overflow' {
        $topModels[0].calls = 1e20
        break
      }
    }
  }
  $statusCurrency = switch ($env:AI_USAGE_STUB_FAILURE_MODE) {
    'cny-no-rate' { [ordered]@{ code = 'CNY'; rate = $null; symbol = 'CNY' }; break }
    'status-bool-currency' { if ($isFailure) { $true } else { [ordered]@{ code = 'USD'; rate = 1; symbol = '$' } }; break }
    'status-array-currency' { if ($isFailure) { ,([object[]]@('USD')) } else { [ordered]@{ code = 'USD'; rate = 1; symbol = '$' } }; break }
    'status-newline-currency' { if ($isFailure) { [ordered]@{ code = "USD`n"; rate = 1; symbol = '$' } } else { [ordered]@{ code = 'USD'; rate = 1; symbol = '$' } }; break }
    default { [ordered]@{ code = 'USD'; rate = 1; symbol = '$' } }
  }
  [pscustomobject][ordered]@{
    currency = $statusCurrency
    current = [ordered]@{
      cost = $cost
      topModels = $topModels
    }
  } | ConvertTo-Json -Depth 20 -Compress
  if ($isFailure -and $env:AI_USAGE_STUB_FAILURE_MODE -eq 'after') { exit 17 }
  exit 0
}
exit 19
'@
  $ccusageStub = @'
$ErrorActionPreference = 'Stop'
$stubArgs = @($args)
if ($stubArgs -contains '--version') { Write-Output '20.0.20'; exit 0 }
Start-Sleep -Milliseconds 60
[IO.File]::AppendAllText($env:AI_USAGE_CCUSAGE_LOG, ($stubArgs -join '|') + "`r`n", [Text.Encoding]::ASCII)
if ($env:AI_USAGE_CCUSAGE_HANG) {
  [IO.File]::WriteAllText($env:AI_USAGE_CCUSAGE_PID, [string]$PID, [Text.Encoding]::ASCII)
  Start-Sleep -Milliseconds 2000
  [IO.File]::WriteAllText($env:AI_USAGE_CCUSAGE_POISON, 'orphaned', [Text.Encoding]::ASCII)
  while ($true) { Start-Sleep -Seconds 1 }
}
if ($env:AI_USAGE_CCUSAGE_MODE -eq 'blocks-object') {
  Write-Output '{"blocks":{}}'
  exit 0
}
if ($env:AI_USAGE_CCUSAGE_MODE -eq 'blocks-null') {
  Write-Output '{"blocks":[null]}'
  exit 0
}
if ($env:AI_USAGE_CCUSAGE_MODE -eq 'oversized') {
  [Console]::Out.Write(('x' * (17 * 1024 * 1024)))
  exit 0
}
if ($env:AI_USAGE_CCUSAGE_MODE -in @('oversized-then-hang', 'deadline-hang')) {
  [IO.File]::WriteAllText($env:AI_USAGE_CCUSAGE_PID, [string]$PID, [Text.Encoding]::ASCII)
  if ($env:AI_USAGE_CCUSAGE_MODE -eq 'oversized-then-hang') {
    [Console]::Out.Write(('x' * (17 * 1024 * 1024)))
    [Console]::Out.Flush()
  }
  Start-Sleep -Milliseconds 2000
  [IO.File]::WriteAllText($env:AI_USAGE_CCUSAGE_POISON, 'orphaned', [Text.Encoding]::ASCII)
  while ($true) { Start-Sleep -Seconds 1 }
}
$block = [ordered]@{
  startTime = '2026-08-29T00:00:00Z'; endTime = '2026-08-29T05:00:00Z'
  actualEndTime = '2026-08-29T01:00:00Z'; costUSD = 1.25
  isActive = $true; isGap = $false
}
if ($env:AI_USAGE_CCUSAGE_MODE -eq 'blocks-sensitive') {
  $block.prompt = 'private prompt'
  $block.authorization = 'Bearer private-token-value'
  $block.burnRate = [ordered]@{ costPerHour = 2.5; toolArguments = 'private args' }
}
if ($env:AI_USAGE_CCUSAGE_MODE -eq 'blocks-nested-fields') {
  $block.costUSD = [pscustomobject]@{ authorization = 'Bearer_DTO_BYPASS' }
}
[pscustomobject][ordered]@{
  blocks = @($block)
} | ConvertTo-Json -Depth 10 -Compress
if ($env:AI_USAGE_CCUSAGE_EXIT) { exit [int]$env:AI_USAGE_CCUSAGE_EXIT }
'@
  [IO.File]::WriteAllText((Join-Path $stubs 'codeburn-stub.ps1'), $codeBurnStub, (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $stubs 'ccusage-stub.ps1'), $ccusageStub, (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $stubs 'codeburn.cmd'), '@echo off' + "`r`n" + 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0codeburn-stub.ps1" %*' + "`r`n" + 'exit /b %errorlevel%' + "`r`n", [Text.Encoding]::ASCII)
  [IO.File]::WriteAllText((Join-Path $stubs 'ccusage.cmd'), '@echo off' + "`r`n" + 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ccusage-stub.ps1" %*' + "`r`n" + 'exit /b %errorlevel%' + "`r`n", [Text.Encoding]::ASCII)
  foreach ($package in @([pscustomobject]@{ Name = 'codeburn'; Version = '0.9.19' }, [pscustomobject]@{ Name = 'ccusage'; Version = '20.0.20' })) {
    $packageDirectory = Join-Path (Join-Path $stubs 'node_modules') $package.Name
    New-Item -ItemType Directory -Force -Path $packageDirectory | Out-Null
    $manifest = '{"name":"' + $package.Name + '","version":"' + $package.Version + '"}'
    [IO.File]::WriteAllText((Join-Path $packageDirectory 'package.json'), $manifest, [Text.Encoding]::ASCII)
  }

  $env:PATH = "$stubs;$oldPath"
  $env:AI_USAGE_CODEBURN_LOG = $codeBurnLog
  $env:AI_USAGE_CCUSAGE_LOG = $ccusageLog

  $tokens = $null
  $parseErrors = $null
  $generatorAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'src\Generate-ClaudeReport.ps1'), [ref]$tokens, [ref]$parseErrors
  )
  if ($parseErrors.Count) { throw 'Could not parse generator helpers for direct boundary tests.' }
  foreach ($functionName in @(
    'Write-TextFileWithRetry', 'Remove-FileWithRetry', 'Test-OutputRecordProperty',
    'Get-OutputRecordValue', 'Select-TypedOutputRecord', 'Select-ReportFields',
    'New-MalformedQuotaState', 'Test-OutputReasonCode', 'Select-ClaudeQuotaFields',
    'Select-CodexQuotaFields', 'Select-CodexRateLimits', 'Test-JsonRecordProperty',
    'Test-JsonNumberValue', 'Test-JsonFiniteNumberValue', 'Test-JsonInt64Value',
    'Test-JsonStringValue', 'Test-JsonNonEmptyStringValue', 'Test-JsonBooleanValue',
    'Test-JsonPercentValue', 'Test-FiniteJsonNumber', 'Test-JsonArrayValue',
    'Test-JsonRecordArray', 'Test-OutputRecordArray', 'Test-IsoCalendarDate', 'Test-JsonDateValue',
    'Select-UsableBlocks', 'Test-UsableBlocks',
    'Select-UsableStatus',
    'Stop-ProcessTree', 'Close-CollectorProcess', 'Assert-CollectorCleanupVerified',
    'Start-JsonCommand', 'Start-OptionalJsonCommand', 'Get-NpmPackageVersion', 'Get-CodexProviderFingerprint',
    'Get-ClaudeOAuthUsage', 'Invoke-BoundedJsonRequest', 'Get-CodexProviderQuota'
  )) {
    $definition = $generatorAst.Find({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    if (-not $definition) { throw "Generator helper $functionName is missing." }
    . ([scriptblock]::Create($definition.Extent.Text))
  }

  foreach ($invalidNumber in @($null, $true, $false, '', '1', [pscustomobject]@{})) {
    if (Test-JsonNumberValue $invalidNumber) { throw 'A nonnumeric JSON value passed finite-number validation.' }
  }
  foreach ($validNumber in @([int]0, [long]1, [decimal]1.5, [double]2.5)) {
    if (-not (Test-JsonNumberValue $validNumber)) { throw 'A valid JSON number failed finite-number validation.' }
  }
  if (Test-JsonNumberValue ([double]::NaN)) { throw 'NaN passed finite-number validation.' }
  if (Test-JsonNumberValue ([double]::PositiveInfinity)) { throw 'Infinity passed finite-number validation.' }
  if (-not (Test-JsonInt64Value ([int64]::MaxValue)) -or (Test-JsonInt64Value 1.5) -or
      (Test-JsonInt64Value 1e20)) { throw 'Int64 JSON validation accepted an out-of-range count.' }
  if (Test-JsonRecordArray ([object[]]@($null))) { throw 'A null collector row passed record-array validation.' }
  if (Test-JsonRecordArray ([object[]]@('bad'))) { throw 'A scalar collector row passed record-array validation.' }
  if (-not (Test-JsonRecordArray ([object[]]@([pscustomobject]@{ ok = $true })))) {
    throw 'A valid collector record failed record-array validation.'
  }
  if (-not (Test-OutputRecordArray ([object[]]@([ordered]@{ ok = $true })))) {
    throw 'An internally built ordered record failed output-array validation.'
  }
  foreach ($invalidPercent in @($true, '25', 100.01, [pscustomobject]@{})) {
    if (Test-JsonPercentValue $invalidPercent) { throw 'An invalid percentage passed strict validation.' }
  }
  if (-not (Test-JsonPercentValue 0) -or -not (Test-JsonPercentValue 100)) {
    throw 'A percentage boundary failed strict validation.'
  }

  Add-Type -AssemblyName System.Net.Http
  if (-not ('AiUsage.TestHttpHandler' -as [type])) {
    Add-Type -ReferencedAssemblies @([Net.Http.HttpClient].Assembly.Location) -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace AiUsage {
  public sealed class TestHttpHandler : HttpMessageHandler {
    readonly int statusCode;
    readonly byte[] body;
    readonly bool includeLength;
    readonly int delayMilliseconds;
    public int RequestCount { get; private set; }
    public string LastContentType { get; private set; }

    public TestHttpHandler(int statusCode, byte[] body, bool includeLength, int delayMilliseconds) {
      this.statusCode = statusCode;
      this.body = body;
      this.includeLength = includeLength;
      this.delayMilliseconds = delayMilliseconds;
    }

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken cancellationToken) {
      RequestCount++;
      LastContentType = request.Content == null || request.Content.Headers.ContentType == null
        ? null
        : request.Content.Headers.ContentType.ToString();
      if (delayMilliseconds > 0) await Task.Delay(delayMilliseconds, cancellationToken);
      var response = new HttpResponseMessage((HttpStatusCode)statusCode);
      var content = new StreamContent(new MemoryStream(body, false));
      if (!includeLength) content.Headers.ContentLength = null;
      response.Content = content;
      return response;
    }
  }
}
'@
  }
  $utf8 = [Text.Encoding]::UTF8
  $smallHandler = [AiUsage.TestHttpHandler]::new(200, $utf8.GetBytes('{"remaining":1}'), $true, 0)
  $smallHttp = Invoke-BoundedJsonRequest -Uri 'https://relay.example.test/usage' -Method GET `
    -Headers @{} -TimeoutSeconds 1 -MaxBytes 1024 -Handler $smallHandler
  if (-not $smallHttp.ok -or [int]$smallHttp.value.remaining -ne 1 -or $smallHandler.RequestCount -ne 1) {
    throw 'The bounded JSON transport did not return a small valid response.'
  }
  $contentHeaderHandler = [AiUsage.TestHttpHandler]::new(200, $utf8.GetBytes('{"remaining":1}'), $true, 0)
  $contentHeaderHttp = Invoke-BoundedJsonRequest -Uri 'https://relay.example.test/usage' -Method GET `
    -Headers @{ 'Content-Type' = 'application/json' } -TimeoutSeconds 1 -MaxBytes 1024 `
    -Handler $contentHeaderHandler
  if (-not $contentHeaderHttp.ok -or $contentHeaderHandler.LastContentType -ne 'application/json') {
    throw 'The bounded JSON transport did not forward an allowlisted Content-Type header.'
  }
  $exactBody = $utf8.GetBytes('{}' + (' ' * 1022))
  $exactHandler = [AiUsage.TestHttpHandler]::new(200, $exactBody, $true, 0)
  if (-not (Invoke-BoundedJsonRequest -Uri 'https://relay.example.test/usage' -Method GET `
      -Headers @{} -TimeoutSeconds 1 -MaxBytes 1024 -Handler $exactHandler).ok) {
    throw 'The bounded JSON transport rejected a response exactly at its byte limit.'
  }
  foreach ($includeLength in @($true, $false)) {
    $largeHandler = [AiUsage.TestHttpHandler]::new(200, (New-Object byte[] 1025), $includeLength, 0)
    $largeHttp = Invoke-BoundedJsonRequest -Uri 'https://relay.example.test/usage' -Method GET `
      -Headers @{} -TimeoutSeconds 1 -MaxBytes 1024 -Handler $largeHandler
    if ($largeHttp.ok -or $largeHttp.reason -ne 'response_too_large') {
      throw 'The bounded JSON transport accepted an oversized declared or streamed response.'
    }
  }
  $malformedHandler = [AiUsage.TestHttpHandler]::new(200, $utf8.GetBytes('{broken'), $false, 0)
  $malformedHttp = Invoke-BoundedJsonRequest -Uri 'https://relay.example.test/usage' -Method GET `
    -Headers @{} -TimeoutSeconds 1 -MaxBytes 1024 -Handler $malformedHandler
  if ($malformedHttp.ok -or $malformedHttp.reason -ne 'malformed_response') {
    throw 'The bounded JSON transport accepted malformed JSON.'
  }
  $redirectHandler = [AiUsage.TestHttpHandler]::new(302, $utf8.GetBytes('{"secret":"body"}'), $true, 0)
  $redirectHttp = Invoke-BoundedJsonRequest -Uri 'https://relay.example.test/usage' -Method GET `
    -Headers @{} -TimeoutSeconds 1 -MaxBytes 1024 -Handler $redirectHandler
  if ($redirectHttp.ok -or $redirectHttp.status -ne 302 -or $redirectHandler.RequestCount -ne 1) {
    throw 'The bounded JSON transport accepted or retried a redirect response.'
  }
  $slowHandler = [AiUsage.TestHttpHandler]::new(200, $utf8.GetBytes('{}'), $true, 2000)
  $slowHttp = Invoke-BoundedJsonRequest -Uri 'https://relay.example.test/usage' -Method GET `
    -Headers @{} -TimeoutSeconds 1 -MaxBytes 1024 -Handler $slowHandler
  if ($slowHttp.ok -or $slowHttp.reason -ne 'request_timed_out') {
    throw 'The bounded JSON transport did not cancel a timed-out request.'
  }
  if ((Test-JsonDateValue '2026-08-29') -or (Test-JsonDateValue 'not-a-date') -or
      -not (Test-JsonDateValue '2026-08-29T01:02:03Z')) {
    throw 'ISO timestamp validation did not enforce the documented shape.'
  }
  if ((Test-JsonStringValue "bad`ntext") -or (Test-JsonStringValue ('x' * 32768))) {
    throw 'Bounded scalar text validation accepted unsafe content.'
  }

  $manifestProbeRoot = Join-Path $sandbox 'manifest-probe'
  $manifestProbeCommand = Join-Path $manifestProbeRoot 'manifest-probe.cmd'
  $manifestProbePackage = Join-Path $manifestProbeRoot 'node_modules\manifest-probe'
  $manifestProbeLog = Join-Path $manifestProbeRoot 'invoked.txt'
  New-Item -ItemType Directory -Force -Path $manifestProbePackage | Out-Null
  [IO.File]::WriteAllText(
    $manifestProbeCommand,
    '@echo off' + "`r`n" + 'echo invoked>"' + $manifestProbeLog + '"' + "`r`n" + 'echo 1.2.3' + "`r`n",
    [Text.Encoding]::ASCII
  )
  $manifestProbePath = Join-Path $manifestProbePackage 'package.json'
  [IO.File]::WriteAllText($manifestProbePath, '{broken', [Text.Encoding]::ASCII)
  if ($null -ne (Get-NpmPackageVersion $manifestProbeCommand 'manifest-probe') -or
      (Test-Path -LiteralPath $manifestProbeLog)) {
    throw 'A damaged npm manifest executed the tool version fallback instead of failing closed.'
  }
  [IO.File]::Delete($manifestProbePath)
  if ($null -ne (Get-NpmPackageVersion $manifestProbeCommand 'manifest-probe') -or
      (Test-Path -LiteralPath $manifestProbeLog)) {
    throw 'A missing npm manifest executed the tool version fallback instead of failing closed.'
  }

  $oauthProfile = Join-Path $sandbox 'malformed-oauth-profile'
  $oauthCredentials = Join-Path $oauthProfile '.claude\.credentials.json'
  New-Item -ItemType Directory -Force -Path (Split-Path $oauthCredentials -Parent) | Out-Null
  [IO.File]::WriteAllText(
    $oauthCredentials,
    '{"claudeAiOauth":{"accessToken":"test-token","expiresAt":253402300799000}}',
    [Text.Encoding]::ASCII
  )
  $QuotaCachePath = Join-Path $oauthProfile 'quota-cache.json'
  $profileBeforeMalformedOAuth = $env:USERPROFILE
  try {
    $env:USERPROFILE = $oauthProfile
    function Invoke-RestMethod { return $script:testOAuthResponse }
    foreach ($malformedResponse in @(
      [pscustomobject]@{},
      [pscustomobject]@{ five_hour = $null; seven_day = $null; limits = [pscustomobject]@{} },
      [pscustomobject]@{ five_hour = [pscustomobject]@{}; seven_day = $null; limits = [object[]]@() }
    )) {
      [void](Remove-FileWithRetry $QuotaCachePath)
      $script:testOAuthResponse = $malformedResponse
      $malformedOAuth = Get-ClaudeOAuthUsage
      if ($malformedOAuth.ok -ne $false -or $malformedOAuth.reason -ne 'malformed_response') {
        throw 'A malformed successful Claude OAuth response did not degrade to malformed_response.'
      }
    }

    [void](Remove-FileWithRetry $QuotaCachePath)
    $script:testOAuthResponse = [pscustomobject]@{
      five_hour = $null; seven_day = $null; limits = [object[]]@()
    }
    $emptyOAuth = Get-ClaudeOAuthUsage
    if (-not $emptyOAuth.ok -or @($emptyOAuth.limits).Count -ne 0) {
      throw 'A valid empty Claude limits array did not survive normalization.'
    }

    [IO.File]::WriteAllText(
      $QuotaCachePath,
      ([ordered]@{
        cachedAtUnix = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeSeconds()
        payload = [ordered]@{
          ok = $true; reason = $null; fiveHour = $null; sevenDay = $null; limits = @()
        }
      } | ConvertTo-Json -Depth 10 -Compress),
      (New-Object Text.UTF8Encoding($false))
    )
    $script:testOAuthResponse = [pscustomobject]@{}
    $corruptOAuthCache = Get-ClaudeOAuthUsage
    if ($corruptOAuthCache.ok -ne $false -or $corruptOAuthCache.reason -ne 'malformed_response') {
      throw 'A malformed stale Claude cache envelope bypassed response degradation.'
    }
  } finally {
    $env:USERPROFILE = $profileBeforeMalformedOAuth
    Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
  }

  $sensitiveQuota = [pscustomobject]@{
    ok = $true; prompt = 'private prompt'
    limits = @([pscustomobject]@{ kind = 'session'; percent = 20; authorization = 'Bearer private-token-value' })
  }
  $sensitiveRelay = [pscustomobject]@{
    ok = $true; remaining = 5; providerUrl = 'https://private.example.test'
    windows = @([pscustomobject]@{ kind = 'weekly'; used = 5; limit = 10; toolArguments = 'private args' })
  }
  $sensitiveLimits = [pscustomobject]@{
    primary = [pscustomobject]@{ used_percent = 25; resets_at = 123; prompt = 'private prompt' }
    credits = [pscustomobject]@{ authorization = 'Bearer private-token-value' }
  }
  $safeBoundaryJson = @(
    Select-ClaudeQuotaFields $sensitiveQuota
    Select-CodexQuotaFields $sensitiveRelay
    Select-CodexRateLimits $sensitiveLimits
  ) | ConvertTo-Json -Depth 20 -Compress
  if ($safeBoundaryJson -match 'private|providerUrl|prompt|authorization|toolArguments|credits') {
    throw 'A quota DTO retained a non-contract or sensitive field.'
  }
  $normalizedLimits = Select-CodexRateLimits $sensitiveLimits
  if (-not $normalizedLimits.primary.resets_at -or
      [DateTimeOffset]::Parse($normalizedLimits.primary.resets_at).ToUnixTimeSeconds() -ne 123) {
    throw 'Official Codex Unix reset seconds were not normalized for the browser.'
  }
  $stringRateLimit = [pscustomobject]@{
    primary = [pscustomobject]@{ used_percent = 25; resets_at = '2026-08-29T01:02:03Z' }
  }
  if ($null -ne (Select-CodexRateLimits $stringRateLimit)) {
    throw 'Official Codex rate limits accepted a non-upstream reset timestamp type.'
  }
  $completeClaudeQuota = [pscustomobject][ordered]@{
    ok = $true; reason = $null; fiveHour = $null; sevenDay = $null; limits = @()
  }
  $completeCodexQuota = [pscustomobject][ordered]@{
    ok = $true; reason = $null; provider = 'Relay'; planName = 'Plan'; mode = 'subscription'
    isValid = $true; unit = 'USD'; remaining = 5; expiresAt = $null; windows = @()
  }
  if (-not (Select-ClaudeQuotaFields $completeClaudeQuota).ok -or
      -not (Select-CodexQuotaFields $completeCodexQuota).ok) {
    throw 'A complete successful quota DTO was rejected.'
  }
  $completeClaudeQuota.limits = @([pscustomobject]@{
    kind = 'weekly'; percent = $null; resetsAt = $null; isActive = $null
  })
  $completeCodexQuota.windows = @([pscustomobject]@{
    kind = 'weekly'; limit = 10; used = 5; percent = 50; startsAt = $null; resetsAt = $null
  })
  $singleClaudeQuota = Select-ClaudeQuotaFields $completeClaudeQuota
  $singleCodexQuota = Select-CodexQuotaFields $completeCodexQuota
  if (@($singleClaudeQuota.limits).Count -ne 1 -or
      @($singleCodexQuota.windows).Count -ne 1 -or
      $singleClaudeQuota.limits[0].kind -ne 'weekly' -or
      $singleCodexQuota.windows[0].kind -ne 'weekly') {
    throw 'A one-row quota array was lost or nested during DTO normalization.'
  }
  if ((Select-ClaudeQuotaFields ([pscustomobject]@{ ok = $true; reason = $null })).reason -ne 'malformed_response' -or
      (Select-CodexQuotaFields ([pscustomobject]@{ ok = $true; reason = $null })).reason -ne 'malformed_response') {
    throw 'A truncated successful quota DTO was accepted.'
  }

  $nestedSecret = [pscustomobject]@{ authorization = 'Bearer_DTO_BYPASS' }
  $strictReport = [pscustomobject][ordered]@{
    currency = 'USD'
    overview = [pscustomobject][ordered]@{
      cost = 1.0; netCost = 1.0; savings = 0.0; estimatedCost = 0.0
      calls = 2; sessions = 1; cacheHitPercent = 50.0
      tokens = [pscustomobject][ordered]@{ input = 10; output = 2; cacheRead = 5; cacheWrite = 1 }
    }
    daily = [object[]]@([pscustomobject][ordered]@{
      date = '2026-08-29'; cost = 1.0; savings = 0.0; calls = 2
      turns = 2; editTurns = 1; oneShotTurns = 0; oneShotRate = $null
    })
    models = [object[]]@([pscustomobject][ordered]@{
      name = 'model'; calls = 2; cost = 1.0; savings = 0.0; estimatedCost = 0.0
      inputTokens = 10; outputTokens = 2; cacheReadTokens = 5; cacheWriteTokens = 1
    })
    projects = [object[]]@([pscustomobject][ordered]@{
      name = 'project'; path = 'C:\Project'; cost = 1.0; savings = 0.0
      avgCostPerSession = $null; calls = 2; sessions = 1
    })
    topSessions = [object[]]@([pscustomobject][ordered]@{
      sessionId = 'session'; project = 'project'; date = $null
      cost = 1.0; savings = 0.0; calls = 2
    })
  }
  if ($null -eq (Select-ReportFields $strictReport)) {
    throw 'A valid strict report DTO was rejected.'
  }
  foreach ($nestedReportField in @('overview-savings', 'daily-rate', 'project-name', 'session-project')) {
    $badReport = ($strictReport | ConvertTo-Json -Depth 20 -Compress) | ConvertFrom-Json
    switch ($nestedReportField) {
      'overview-savings' { $badReport.overview.savings = $nestedSecret }
      'daily-rate' { $badReport.daily[0].oneShotRate = $nestedSecret }
      'project-name' { $badReport.projects[0].name = $nestedSecret }
      'session-project' { $badReport.topSessions[0].project = $nestedSecret }
    }
    if ($null -ne (Select-ReportFields $badReport)) {
      throw "A report DTO accepted an object in $nestedReportField."
    }
  }

  $badClaudeQuota = [pscustomobject]@{
    ok = $true
    fiveHour = [pscustomobject]@{ utilization = $nestedSecret; resetsAt = '2026-08-29T01:02:03Z' }
    limits = @()
  }
  $badCodexQuota = [pscustomobject]@{
    ok = $true; planName = $nestedSecret; remaining = 5
    windows = @([pscustomobject]@{
      kind = 'weekly'; limit = 10; used = 5; percent = 50
      startsAt = '2026-08-22T01:02:03Z'; resetsAt = '2026-08-29T01:02:03Z'
    })
  }
  $badRateLimits = [pscustomobject]@{
    primary = [pscustomobject]@{ used_percent = 25; resets_at = $nestedSecret }
  }
  $badBlocks = [pscustomobject]@{ blocks = @([pscustomobject]@{
    startTime = '2026-08-29T00:00:00Z'; endTime = '2026-08-29T05:00:00Z'
    actualEndTime = '2026-08-29T01:00:00Z'; costUSD = $nestedSecret
    isActive = $true; isGap = $false
  }) }
  $badStatus = [pscustomobject]@{
    currency = [pscustomobject]@{ code = 'USD'; rate = 1; symbol = $nestedSecret }
    current = [pscustomobject]@{
      cost = 1
      topModels = @([pscustomobject]@{ name = 'model'; calls = 1; cost = 1 })
    }
  }
  $strictBoundaryJson = @(
    Select-ClaudeQuotaFields $badClaudeQuota
    Select-CodexQuotaFields $badCodexQuota
    Select-CodexRateLimits $badRateLimits
    Select-UsableBlocks $badBlocks
    Select-UsableStatus $badStatus
  ) | ConvertTo-Json -Depth 20 -Compress
  if ($strictBoundaryJson -match 'authorization|Bearer_DTO_BYPASS' -or
      (Select-ClaudeQuotaFields $badClaudeQuota).reason -ne 'malformed_response' -or
      (Select-CodexQuotaFields $badCodexQuota).reason -ne 'malformed_response' -or
      $null -ne (Select-CodexRateLimits $badRateLimits) -or
      $null -ne (Select-UsableBlocks $badBlocks) -or
      $null -ne (Select-UsableStatus $badStatus)) {
    throw 'A nested object crossed a strict render-only DTO boundary.'
  }

  $lockedPath = Join-Path $sandbox 'locked-file.txt'
  [IO.File]::WriteAllText($lockedPath, 'old', [Text.Encoding]::ASCII)
  $lockedStream = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  try {
    if (Write-TextFileWithRetry $lockedPath 'new' 2) { throw 'A locked read-lease write reported success.' }
    if (Remove-FileWithRetry $lockedPath 2) { throw 'A locked stale snapshot delete reported success.' }
  } finally {
    $lockedStream.Dispose()
  }
  if (-not (Write-TextFileWithRetry $lockedPath 'new' 2)) { throw 'Read-lease write did not recover after the lock was released.' }
  if (-not (Remove-FileWithRetry $lockedPath 2)) { throw 'Snapshot delete did not recover after the lock was released.' }

  $cleanupProbe = [pscustomobject]@{ HasExited = $false }
  $cleanupProbe | Add-Member -MemberType ScriptMethod -Name TerminateAndWait -Value {
    param([int]$timeoutMilliseconds)
    return $false
  }
  $cleanupProbe | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
  $script:CollectorCleanupUncertain = $false
  Close-CollectorProcess $cleanupProbe
  $blockedCollectorStart = $false
  try {
    [void](Start-JsonCommand 'must-not-start.cmd' @() (Join-Path $sandbox 'must-not-start.json'))
  } catch {
    $blockedCollectorStart = $_.Exception.Message -eq `
      'Collector cleanup remains unverified; refusing to start another collector.'
  }
  if (-not $script:CollectorCleanupUncertain -or -not $blockedCollectorStart) {
    throw 'An unverified collector cleanup did not fail closed before the next process launch.'
  }
  $script:CollectorCleanupUncertain = $false

  function Start-JsonCommand { throw 'simulated optional collector launch failure' }
  $optionalOutput = Join-Path $sandbox 'optional-launch-output.json'
  $script:CollectorCleanupUncertain = $false
  [IO.File]::WriteAllText($optionalOutput, '{"stale":true}', [Text.Encoding]::ASCII)
  $optionalProcess = Start-OptionalJsonCommand 'ccusage.cmd' @('blocks', '--json', '--offline') $optionalOutput
  if ($optionalProcess) { throw 'An optional collector launch failure returned a process.' }
  if (Test-Path -LiteralPath $optionalOutput) { throw 'An optional collector launch failure retained stale output.' }
  $script:CollectorCleanupUncertain = $true
  [IO.File]::WriteAllText($optionalOutput, '{"stale":true}', [Text.Encoding]::ASCII)
  $uncertainLaunchThrew = $false
  try {
    [void](Start-OptionalJsonCommand 'ccusage.cmd' @('blocks', '--json', '--offline') $optionalOutput)
  } catch {
    $uncertainLaunchThrew = $true
  }
  if (-not $uncertainLaunchThrew -or (Test-Path -LiteralPath $optionalOutput)) {
    throw 'An uncertain optional collector cleanup was swallowed or retained stale output.'
  }
  $script:CollectorCleanupUncertain = $false

  $script:testCodexProvider = [pscustomobject]@{
    ok = $true; id = 'provider-a'; name = 'Duplicate Provider'; meta = '{}'; settingsConfig = '{}'
  }
  $script:testUsageRequestCalls = 0
  function Read-CcSwitchCodexProvider { return $script:testCodexProvider }
  function Get-CodexUsageRequest {
    $script:testUsageRequestCalls += 1
    return [ordered]@{ ok = $false; reason = 'usage_script_disabled' }
  }
  $CodexQuotaCachePath = Join-Path $sandbox 'provider-bound-quota-cache.json'
  $cachePayload = [ordered]@{
    cachedAt = [DateTimeOffset]::Now.ToString('o')
    cachedAtUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    providerId = 'provider-a'
    providerFingerprint = Get-CodexProviderFingerprint $script:testCodexProvider
    payload = [ordered]@{
      ok = $true; reason = $null; provider = 'Duplicate Provider'; planName = 'Cached plan'
      mode = 'subscription'; isValid = $true; unit = 'USD'; remaining = 5
      expiresAt = $null; windows = @()
    }
  }
  $legacyCachePayload = [ordered]@{
    cachedAt = $cachePayload.cachedAt
    cachedAtUnix = $cachePayload.cachedAtUnix
    payload = $cachePayload.payload
  }
  [IO.File]::WriteAllText(
    $CodexQuotaCachePath,
    ($legacyCachePayload | ConvertTo-Json -Depth 10 -Compress),
    (New-Object Text.UTF8Encoding($false))
  )
  $legacyQuota = Get-CodexProviderQuota
  if ($legacyQuota.ok -ne $false -or $legacyQuota.reason -ne 'usage_script_disabled' -or
      $script:testUsageRequestCalls -ne 1) {
    throw 'A legacy Codex quota cache without a stable provider ID was reused.'
  }

  [IO.File]::WriteAllText(
    $CodexQuotaCachePath,
    ($cachePayload | ConvertTo-Json -Depth 10 -Compress),
    (New-Object Text.UTF8Encoding($false))
  )
  $script:testCodexProvider = [pscustomobject]@{
    ok = $true; id = 'provider-b'; name = 'Duplicate Provider'; meta = '{}'; settingsConfig = '{}'
  }
  $script:testUsageRequestCalls = 0
  $mismatchedQuota = Get-CodexProviderQuota
  if ($mismatchedQuota.ok -ne $false -or $mismatchedQuota.reason -ne 'usage_script_disabled' -or
      $script:testUsageRequestCalls -ne 1) {
    throw 'A fresh Codex quota cache escaped after switching between same-name providers.'
  }
  $script:testCodexProvider = [pscustomobject]@{
    ok = $true; id = 'provider-a'; name = 'Duplicate Provider'; meta = '{}'; settingsConfig = '{}'
  }
  $script:testCodexProvider.settingsConfig = '{"auth":{"OPENAI_API_KEY":"rotated"}}'
  $script:testUsageRequestCalls = 0
  $rotatedQuota = Get-CodexProviderQuota
  if ($rotatedQuota.ok -ne $false -or $rotatedQuota.reason -ne 'usage_script_disabled' -or
      $script:testUsageRequestCalls -ne 1) {
    throw 'A fresh Codex quota cache survived an in-place credential rotation.'
  }
  $script:testCodexProvider.settingsConfig = '{}'
  $script:testUsageRequestCalls = 0
  $matchingQuota = Get-CodexProviderQuota
  if ($matchingQuota.ok -ne $true -or $matchingQuota.provider -ne 'Duplicate Provider' -or
      -not $matchingQuota.cachedAt -or $script:testUsageRequestCalls -ne 0) {
    throw 'A fresh Codex quota cache was not reused for the same active provider.'
  }
  $cachePayload.payload.planName = [pscustomobject]@{ authorization = 'Bearer_DTO_BYPASS' }
  [IO.File]::WriteAllText(
    $CodexQuotaCachePath,
    ($cachePayload | ConvertTo-Json -Depth 10 -Compress),
    (New-Object Text.UTF8Encoding($false))
  )
  $script:testUsageRequestCalls = 0
  $corruptedQuota = Get-CodexProviderQuota
  if ($corruptedQuota.ok -ne $false -or $corruptedQuota.reason -ne 'usage_script_disabled' -or
      $script:testUsageRequestCalls -ne 1 -or
      (($corruptedQuota | ConvertTo-Json -Depth 10 -Compress) -match 'authorization|Bearer_DTO_BYPASS')) {
    throw 'A malformed provider-bound Codex quota cache bypassed live recollection.'
  }
  $cachePayload.payload.planName = 'Cached plan'
  [IO.File]::WriteAllText(
    $CodexQuotaCachePath,
    ($cachePayload | ConvertTo-Json -Depth 10 -Compress),
    (New-Object Text.UTF8Encoding($false))
  )
  $script:testCodexProvider = [pscustomobject]@{ ok = $false; reason = 'ccswitch_unreadable' }
  $script:testUsageRequestCalls = 0
  $unavailableQuota = Get-CodexProviderQuota
  if ($unavailableQuota.ok -ne $true -or $unavailableQuota.provider -ne 'Duplicate Provider' -or
      $unavailableQuota.stale -ne $true -or $unavailableQuota.staleReason -ne 'ccswitch_unreadable' -or
      $script:testUsageRequestCalls -ne 0) {
    throw 'A fresh Codex quota cache hid an unavailable active-provider lookup.'
  }

  [IO.File]::WriteAllText(
    $CodexQuotaCachePath,
    ([ordered]@{
      cachedAtUnix = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeSeconds()
      providerId = 'provider-a'
      payload = $cachePayload.payload
    } | ConvertTo-Json -Depth 10 -Compress),
    (New-Object Text.UTF8Encoding($false))
  )
  $corruptUnavailableQuota = Get-CodexProviderQuota
  if ($corruptUnavailableQuota.ok -ne $false -or $corruptUnavailableQuota.reason -ne 'ccswitch_unreadable') {
    throw 'A malformed stale Codex cache envelope threw or bypassed provider-unavailable degradation.'
  }

  [void](Remove-FileWithRetry $CodexQuotaCachePath)
  $script:testCodexProvider = [pscustomobject]@{
    ok = $true; id = 'provider-a'; name = 'Duplicate Provider'; meta = '{}'; settingsConfig = '{}'
  }
  function Get-CodexUsageRequest {
    return [ordered]@{
      ok = $true; reason = $null; url = 'https://relay.example.test/usage'
      method = 'GET'; headers = @{}; timeoutSeconds = 1
    }
  }
  function Invoke-BoundedJsonRequest {
    return [pscustomobject][ordered]@{
      ok = $true; reason = $null; status = 200
      value = [pscustomobject]@{
        remaining = 1; mode = ('x' * 129); planName = 'Plan'; unit = 'USD'
      }
    }
  }
  try {
    $invalidLiveCodexQuota = Get-CodexProviderQuota
  } finally {
    Remove-Item Function:\Invoke-BoundedJsonRequest -ErrorAction SilentlyContinue
  }
  if ($invalidLiveCodexQuota.ok -ne $false -or $invalidLiveCodexQuota.reason -ne 'malformed_response' -or
      (Test-Path -LiteralPath $CodexQuotaCachePath)) {
    throw 'An invalid live Codex quota DTO was cached before final normalization.'
  }

  if ($TestGroup -in @('all', 'core')) {
    Invoke-PendingAfterGlobalWaitScenario

    $success = Invoke-Scenario 'success' '' 0 $true
    Assert-ProgressiveContract $success 'Successful generator scenario'
    if ($success.First.complete -ne $false) { throw 'First progressive snapshot was already complete.' }
    if (@($success.First.periods).Count -ne 1 -or $success.First.periods[0] -ne '30days') {
      throw 'First progressive snapshot did not contain only the default period.'
    }
    if ($success.FirstCodeBurnCount -ne 2) { throw "First snapshot required $($success.FirstCodeBurnCount) CodeBurn calls instead of two." }
    if ($success.CodeBurnCalls[0] -ne 'report|30days|claude' -or $success.CodeBurnCalls[1] -ne 'report|30days|codex') {
      throw 'Default provider reports were not the first CodeBurn operations.'
    }
    if ($success.Final.complete -ne $true -or $success.Final.generationError) { throw 'Successful generator scenario did not finish cleanly.' }
    if (@($success.Final.limits.claudeBlocks.blocks).Count -ne 1) { throw 'Successful ccusage output was not retained in the final snapshot.' }
    if ($success.CCUsageCalls.Count -ne 1 -or $success.CCUsageCalls[0] -ne 'blocks|--json|--offline') {
      throw 'ccusage was not invoked exactly once in offline JSON mode.'
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Verify-Snapshot.ps1') -DataPath $success.DataPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Successful generated snapshot failed contract verification.' }

    $stringRevision = Copy-Snapshot $success.Final
    $stringRevision.revision = '1'
    Assert-SnapshotRejected $stringRevision 'string-revision'
    $stringComplete = Copy-Snapshot $success.Final
    $stringComplete.complete = 'true'
    Assert-SnapshotRejected $stringComplete 'string-complete'
    $scalarPeriods = Copy-Snapshot $success.Final
    $scalarPeriods.periods = '30days'
    Assert-SnapshotRejected $scalarPeriods 'scalar-periods'

    $truncatedClaudeSuccess = Copy-Snapshot $success.Final
    $truncatedClaudeSuccess.limits.claudeQuota = [pscustomobject][ordered]@{
      ok = $true; fiveHour = $null; sevenDay = $null; limits = @()
    }
    Assert-SnapshotRejected $truncatedClaudeSuccess 'truncated-claude-success'
    $truncatedCodexSuccess = Copy-Snapshot $success.Final
    $truncatedCodexSuccess.limits.codexQuota = [pscustomobject][ordered]@{
      ok = $true; reason = $null; provider = 'Relay'; planName = 'Plan'
      isValid = $true; unit = 'USD'; remaining = 1; expiresAt = $null; windows = @()
    }
    Assert-SnapshotRejected $truncatedCodexSuccess 'truncated-codex-success'
    $missingClaudeFailureReason = Copy-Snapshot $success.Final
    $missingClaudeFailureReason.limits.claudeQuota = [pscustomobject]@{ ok = $false }
    Assert-SnapshotRejected $missingClaudeFailureReason 'missing-claude-failure-reason'
    $missingCodexFailureReason = Copy-Snapshot $success.Final
    $missingCodexFailureReason.limits.codexQuota = [pscustomobject]@{ ok = $false; reason = $null }
    Assert-SnapshotRejected $missingCodexFailureReason 'missing-codex-failure-reason'
    $mismatchedReportCurrency = Copy-Snapshot $success.Final
    $mismatchedReportCurrency.reports.'30days'.codex.currency = 'CNY'
    Assert-SnapshotRejected $mismatchedReportCurrency 'mismatched-report-currency'

    $truncatedClaudeQuota = Copy-Snapshot $success.Final
    $truncatedClaudeQuota.limits.claudeQuota = [pscustomobject]@{ ok = $true }
    Assert-SnapshotRejected $truncatedClaudeQuota 'truncated-claude-quota'
    $truncatedCodexQuota = Copy-Snapshot $success.Final
    $truncatedCodexQuota.limits.codexQuota = [pscustomobject]@{ ok = $true }
    Assert-SnapshotRejected $truncatedCodexQuota 'truncated-codex-quota'
    $reasonlessClaudeFailure = Copy-Snapshot $success.Final
    $reasonlessClaudeFailure.limits.claudeQuota = [pscustomobject]@{ ok = $false }
    Assert-SnapshotRejected $reasonlessClaudeFailure 'reasonless-claude-quota-failure'
    $reasonlessCodexFailure = Copy-Snapshot $success.Final
    $reasonlessCodexFailure.limits.codexQuota = [pscustomobject]@{ ok = $false }
    Assert-SnapshotRejected $reasonlessCodexFailure 'reasonless-codex-quota-failure'

    $uppercasePeriod = Invoke-Scenario 'uppercase-period' '' 0 $false 'before' '' $false 'ALL'
    if ($uppercasePeriod.First.period -cne 'all' -or $uppercasePeriod.First.periods[0] -cne 'all' -or
        $uppercasePeriod.CodeBurnCalls[0] -cne 'report|all|claude') {
      throw 'A case-insensitive PowerShell period was not normalized before CodeBurn or publication.'
    }

    $failure = Invoke-Scenario 'failure' 'report|week|claude' 17
    Assert-ProgressiveContract $failure 'Degraded generator scenario'
    if ($failure.Final.complete -ne $true) { throw 'Degraded generator scenario did not publish a terminal snapshot.' }
    if ($failure.Final.generationError.reason -ne 'partial_generation_failed' -or $failure.Final.generationError.stage -ne 'remaining_usage') {
      throw 'Degraded generator scenario did not publish its failure stage.'
    }
    if (@($failure.Final.periods).Count -ne 1 -or $failure.Final.periods[0] -ne '30days') {
      throw 'Degraded generator scenario lost or overstated the usable default period.'
    }
    if ($failure.Final.limits.claudeQuota.reason -ne 'not_collected' -or $failure.Final.limits.codexQuota.reason -ne 'not_collected') {
      throw 'Degraded generator scenario did not terminate pending quota states.'
    }
    if ($failure.Final.limits.claudeBlocks) { throw 'Nonzero ccusage output was accepted as valid block data.' }
    if (-not (Test-Path -LiteralPath $failure.DataPath)) { throw 'Degraded generator scenario deleted its usable snapshot.' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Verify-Snapshot.ps1') -DataPath $failure.DataPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Degraded generated snapshot failed contract verification.' }
  }

  if ($TestGroup -in @('all', 'optional')) {
    $statusFailure = Invoke-Scenario 'status-output-failure' 'status|30days|claude' 0 $false 'after'
    if ($statusFailure.Final.generationError) { throw 'An optional status failure incorrectly ended report generation.' }
    $statusModelNames = @($statusFailure.Final.reports.'30days'.claude.models | ForEach-Object { $_.name })
    if ($statusModelNames -contains 'poison-status-model') {
      throw 'A nonzero status process contributed its otherwise valid JSON output.'
    }

    foreach ($statusMode in @(
      'status-string', 'status-number', 'status-missing-name', 'status-missing-calls',
      'status-bool-currency', 'status-array-currency', 'status-newline-currency',
      'status-calls-overflow'
    )) {
      $statusShape = Invoke-Scenario $statusMode 'status|30days|claude' 0 $false $statusMode
      Assert-ProgressiveContract $statusShape "$statusMode generator scenario"
      if ($statusShape.Final.generationError -or @($statusShape.Final.periods).Count -ne 3) {
        throw "$statusMode optional status shape interrupted later periods."
      }
      $shapeModelNames = @($statusShape.Final.reports.'30days'.claude.models | ForEach-Object { $_.name })
      if ($shapeModelNames -notcontains 'claude-stub-model') {
        throw "$statusMode optional status shape did not fall back to the live report model."
      }
    }

    $malformed = Invoke-Scenario 'malformed-report' 'report|week|codex' 0 $false 'malformed'
    if ($malformed.Final.generationError.reason -ne 'partial_generation_failed' -or
        $malformed.Final.generationError.stage -ne 'remaining_usage') {
      throw 'Malformed zero-exit report output did not end in a classified degraded snapshot.'
    }
    if (@($malformed.Final.periods).Count -ne 1 -or $malformed.Final.periods[0] -ne '30days') {
      throw 'Malformed zero-exit report output published an incomplete provider period.'
    }

    $oversized = Invoke-Scenario 'oversized-report' 'report|week|codex' 0 $false 'oversized'
    if ($oversized.Final.generationError.reason -ne 'partial_generation_failed' -or
        $oversized.Final.generationError.stage -ne 'remaining_usage' -or
        @($oversized.Final.periods).Count -ne 1) {
      throw 'Oversized CodeBurn output did not terminate its Job and retain the last usable snapshot.'
    }

    $oversizedBlocks = Invoke-Scenario 'oversized-blocks' '' 0 $false 'before' 'oversized'
    if ($oversizedBlocks.Final.generationError -or $oversizedBlocks.Final.limits.claudeBlocks) {
      throw 'Oversized optional ccusage output did not degrade without interrupting report generation.'
    }
    Invoke-CCUsageBoundaryScenario 'oversized-then-hang'
    Invoke-CCUsageBoundaryScenario 'deadline-hang'

    $currencyConflict = Invoke-Scenario 'currency-conflict' 'report|week|codex' 0 $false 'currency'
    Assert-ProgressiveContract $currencyConflict 'Currency-conflict generator scenario'
    if ($currencyConflict.Final.generationError.reason -ne 'partial_generation_failed' -or
        $currencyConflict.Final.generationError.stage -ne 'remaining_usage') {
      throw 'A later-period currency conflict did not publish a classified terminal snapshot.'
    }
    if (@($currencyConflict.Final.periods).Count -ne 1 -or $currencyConflict.Final.periods[0] -ne '30days') {
      throw 'A rejected currency-conflict candidate escaped into the final snapshot.'
    }
    if (@($currencyConflict.Final.reports.PSObject.Properties.Name) -ne '30days' -or
        $currencyConflict.Final.currency.code -ne 'USD' -or
        [double]$currencyConflict.Final.reports.'30days'.claude.overview.cost -ne 20 -or
        [double]$currencyConflict.Final.reports.'30days'.codex.overview.cost -ne 8) {
      throw 'A rejected currency-conflict candidate changed the last published default-period data.'
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Verify-Snapshot.ps1') -DataPath $currencyConflict.DataPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Currency-conflict terminal snapshot failed contract verification.' }

    $cnyFallback = Invoke-Scenario 'cny-no-rate' '' 0 $false 'cny-no-rate'
    if ($cnyFallback.Final.generationError -or $cnyFallback.Final.currency.code -ne 'CNY' -or
        $null -ne $cnyFallback.Final.currency.rate -or $cnyFallback.Final.currency.symbol -ne 'CNY') {
      throw 'A non-USD report without optional status rates did not publish its explicit currency fallback.'
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Verify-Snapshot.ps1') -DataPath $cnyFallback.DataPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The non-USD no-rate fallback failed snapshot verification.' }

    foreach ($costMode in @('null-cost', 'bool-cost', 'string-cost')) {
      $invalidCost = Invoke-Scenario $costMode 'report|week|codex' 0 $false $costMode
      if ($invalidCost.Final.generationError.reason -ne 'partial_generation_failed' -or
          $invalidCost.Final.generationError.stage -ne 'remaining_usage' -or
          @($invalidCost.Final.periods).Count -ne 1) {
        throw "$costMode overview cost was not rejected before publication."
      }
    }

    foreach ($currencyMode in @('currency-bool', 'currency-array', 'currency-newline')) {
      $invalidCurrency = Invoke-Scenario $currencyMode 'report|week|codex' 0 $false $currencyMode
      if ($invalidCurrency.Final.generationError.reason -ne 'partial_generation_failed' -or
          $invalidCurrency.Final.generationError.stage -ne 'remaining_usage' -or
          @($invalidCurrency.Final.periods).Count -ne 1) {
        throw "$currencyMode report currency was not rejected before publication."
      }
    }
  }

  if ($TestGroup -in @('all', 'rows')) {
    foreach ($arrayMode in @('daily-object', 'models-object', 'projects-object', 'sessions-object')) {
      $invalidArray = Invoke-Scenario $arrayMode 'report|week|codex' 0 $false $arrayMode
      if ($invalidArray.Final.generationError.reason -ne 'partial_generation_failed' -or
          $invalidArray.Final.generationError.stage -ne 'remaining_usage' -or
          @($invalidArray.Final.periods).Count -ne 1) {
        throw "$arrayMode report field was not rejected before publication."
      }
    }

    foreach ($rowMode in @(
      'daily-null', 'daily-missing-date', 'daily-number-date', 'daily-html-date',
      'daily-invalid-calendar-date', 'daily-bool-cost', 'model-bool-cost',
      'project-string-cost', 'session-null-cost', 'output-nested-fields'
    )) {
      $invalidRow = Invoke-Scenario $rowMode 'report|week|codex' 0 $false $rowMode
      if ($invalidRow.Final.generationError.reason -ne 'partial_generation_failed' -or
          @($invalidRow.Final.periods).Count -ne 1) {
        throw "$rowMode report row was not rejected before publication."
      }
    }

    $sensitiveReport = Invoke-Scenario `
      'output-extra-fields' 'report|30days|claude' 0 $false 'output-extra-fields'
    $sensitiveReportRaw = [IO.File]::ReadAllText($sensitiveReport.DataPath)
    if ($sensitiveReport.Final.generationError -or
        $sensitiveReportRaw -match 'private prompt|private args|private-token-value|private\.example\.test|toolArguments|authorization|providerUrl') {
      throw 'A valid report with extra sensitive fields was not reduced to its explicit output DTO.'
    }

    $sensitiveBlocks = Invoke-Scenario 'blocks-sensitive' '' 0 $false 'before' 'blocks-sensitive'
    $sensitiveBlocksRaw = [IO.File]::ReadAllText($sensitiveBlocks.DataPath)
    if ($sensitiveBlocks.Final.generationError -or
        [double]$sensitiveBlocks.Final.limits.claudeBlocks.blocks[0].burnRate.costPerHour -ne 2.5 -or
        $sensitiveBlocksRaw -match 'private prompt|private args|private-token-value|prompt|authorization|toolArguments') {
      throw 'ccusage block enrichment was not reduced to its explicit output DTO.'
    }

    $invalidBlocks = Invoke-Scenario 'blocks-object' '' 0 $false 'before' 'blocks-object'
    if ($invalidBlocks.Final.generationError -or $invalidBlocks.Final.limits.claudeBlocks) {
      throw 'Malformed zero-exit ccusage blocks were not ignored.'
    }
    $nullBlocks = Invoke-Scenario 'blocks-null' '' 0 $false 'before' 'blocks-null'
    if ($nullBlocks.Final.generationError -or $nullBlocks.Final.limits.claudeBlocks) {
      throw 'A null ccusage block row was not ignored.'
    }
    $nestedBlocks = Invoke-Scenario 'blocks-nested-fields' '' 0 $false 'before' 'blocks-nested-fields'
    $nestedBlocksRaw = [IO.File]::ReadAllText($nestedBlocks.DataPath)
    if ($nestedBlocks.Final.generationError -or $nestedBlocks.Final.limits.claudeBlocks -or
        $nestedBlocksRaw -match 'authorization|Bearer_DTO_BYPASS') {
      throw 'A ccusage block object value crossed the render-only DTO boundary.'
    }

    $keepFileLaunch = Invoke-Scenario 'keep-file-launch' '' 0 $false 'before' '' $true
    if ($keepFileLaunch.Final.generationError -or $keepFileLaunch.LaunchCalls.Count -ne 1 -or
        -not (Test-Path -LiteralPath $keepFileLaunch.DataPath)) {
      throw 'The retained -KeepFile launcher did not open and retain its unique debug snapshot.'
    }
  }

  if ($TestGroup -in @('all', 'lifecycle')) {
    if ($LifecycleScenario -eq 'all') {
      Invoke-CollectorJobCompletionScenario
      Invoke-CollectorParentTerminationScenario
      Invoke-LegacyCollectorAbandonmentScenario
      Invoke-FailureReadGraceScenario
      Invoke-FailureRetryScenario 'startup-failure-retry' 'report|30days|claude' $true
      Invoke-FailureRetryScenario 'partial-failure-retry' 'report|week|claude' $false
      Invoke-FinalPublishFailureScenario
    }
    if ($LifecycleScenario -in @('all', 'coordination')) {
      Invoke-FailureCoordinationLockScenario
      Invoke-MissingFailureSignalScenario
      Invoke-PostLaunchCoordinationFailureScenario
    }
    if ($LifecycleScenario -eq 'all') {
      Invoke-StartingReuseScenario
      Invoke-UnplannedPeriodScenario
      Invoke-NormalLifecycleScenario 'normal-lifecycle' $false
      Invoke-NormalLifecycleScenario 'cleanup-recovery' $true
      Invoke-NormalLifecycleScenario 'cross-period-cleanup-recovery' $true 'today' '30days'
      Invoke-NormalLifecycleScenario 'closing-write-recovery' $false '30days' '30days' $true
    }
    if ($LifecycleScenario -in @('all', 'debug-scratch')) {
      Invoke-DebugScratchRecoveryScenario 'debug-scratch-recovery'
    }
  }

  Write-Output 'Generator.Integration.Tests.ps1: PASS'
} finally {
  $env:PATH = $oldPath
  $env:TEMP = $oldTemp
  $env:TMP = $oldTmp
  $env:USERPROFILE = $oldUserProfile
  $env:AI_USAGE_STUB_FAILURE = $oldFailure
  $env:AI_USAGE_STUB_FAILURE_MODE = $oldFailureMode
  $env:AI_USAGE_CCUSAGE_EXIT = $oldCCUsageExit
  $env:AI_USAGE_CCUSAGE_MODE = $oldCCUsageMode
  $env:AI_USAGE_CODEBURN_LOG = $oldCodeBurnLog
  $env:AI_USAGE_CCUSAGE_LOG = $oldCCUsageLog
  $env:AI_USAGE_PATH_TOKEN = $oldPathToken
  $env:AI_USAGE_TEST_LAUNCH_LOG = $oldLaunchLog
  $env:AI_USAGE_PENDING_RACE_READY = $oldPendingRaceReady
  $env:AI_USAGE_CODEBURN_HANG = $oldCodeBurnHang
  $env:AI_USAGE_CODEBURN_PID = $oldCodeBurnPid
  $env:AI_USAGE_CODEBURN_POISON = $oldCodeBurnPoison
  $env:AI_USAGE_CCUSAGE_HANG = $oldCCUsageHang
  $env:AI_USAGE_CCUSAGE_PID = $oldCCUsagePid
  $env:AI_USAGE_CCUSAGE_POISON = $oldCCUsagePoison
  $env:AI_USAGE_CODEBURN_OVERLAP_MUTEX = $oldOverlapMutex
  $env:AI_USAGE_CODEBURN_OVERLAP_MARKER = $oldOverlapMarker
  $env:AI_USAGE_FINAL_PUBLISH_FAULT = $oldFinalPublishFault
  $env:AI_USAGE_CODEBURN_BARRIER_MATCH = $oldCodeBurnBarrierMatch
  $env:AI_USAGE_CODEBURN_BARRIER_READY = $oldCodeBurnBarrierReady
  $env:AI_USAGE_CODEBURN_BARRIER_RELEASE = $oldCodeBurnBarrierRelease
  try {
    if ($env:AI_USAGE_KEEP_TEST_SANDBOX -eq '1') {
      Write-Warning "Retained generator test sandbox: $sandbox"
    } else {
      $resolved = [IO.Path]::GetFullPath($sandbox)
      $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
      if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
          [IO.Path]::GetFileName($resolved).StartsWith('ai-usage-generator-test-', [StringComparison]::Ordinal)) {
        if (Test-Path -LiteralPath $resolved) { [IO.Directory]::Delete($resolved, $true) }
      }
    }
  } catch {}
}
