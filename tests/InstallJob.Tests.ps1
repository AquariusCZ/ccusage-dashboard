$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

if ($env:OS -ne 'Windows_NT') {
  Write-Output 'InstallJob.Tests.ps1: SKIP (Windows only)'
  exit 0
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('ai-usage-install-job-test-' + [guid]::NewGuid().ToString('N'))
$harnessPath = Join-Path $sandbox 'job-harness.ps1'
$workerPath = Join-Path $sandbox 'worker.ps1'
$workerCommand = Join-Path $sandbox 'worker.cmd'
$exitCommand = Join-Path $sandbox 'exit.cmd'
$captureCommand = Join-Path $sandbox 'capture.cmd'
$floodScript = Join-Path $sandbox 'flood.ps1'
$floodCommand = Join-Path $sandbox 'flood.cmd'
$capturePath = Join-Path $sandbox 'capture.out'
$floodPath = Join-Path $sandbox 'flood.out'
$timeoutCapturePath = Join-Path $sandbox 'timeout.out'
$naturalChildPath = Join-Path $sandbox 'natural-child.ps1'
$naturalRootPath = Join-Path $sandbox 'natural-root.ps1'
$naturalCommand = Join-Path $sandbox 'natural.cmd'
$naturalPidPath = Join-Path $sandbox 'natural.pid'
$naturalCompletedDirectory = Join-Path $sandbox 'natural-completed'
$pidPath = Join-Path $sandbox 'worker.pid'
$completedPath = Join-Path $sandbox 'worker.completed'
$stdoutPath = Join-Path $sandbox 'harness.stdout.log'
$stderrPath = Join-Path $sandbox 'harness.stderr.log'
$harnessProcess = $null
$workerPid = $null
$workerIdentity = $null

function Read-WorkerIdentity([string]$Path) {
  $parts = [IO.File]::ReadAllText($Path).Trim() -split '\|', 2
  if ($parts.Count -ne 2) { throw 'The Job worker identity is malformed.' }
  return [pscustomobject]@{ Id = [int]$parts[0]; StartTicks = [int64]$parts[1] }
}

function Test-WorkerIdentityAlive($Identity) {
  if (-not $Identity) { return $false }
  $process = Get-Process -Id ([int]$Identity.Id) -ErrorAction SilentlyContinue
  if (-not $process) { return $false }
  try { return [int64]$process.StartTime.ToFileTimeUtc() -eq [int64]$Identity.StartTicks }
  catch { return $false }
  finally { $process.Dispose() }
}

try {
  New-Item -ItemType Directory -Force -Path $sandbox | Out-Null

  $installerText = [IO.File]::ReadAllText((Join-Path $root 'install.ps1'))
  $jobPattern = "(?s)# INSTALL_JOB_CSHARP_BEGIN\s+Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@\s+# INSTALL_JOB_CSHARP_END"
  $jobMatch = [regex]::Match($installerText, $jobPattern)
  if (-not $jobMatch.Success) { throw 'Could not extract the installer Job Object implementation.' }
  Add-Type -TypeDefinition $jobMatch.Groups[1].Value

  $harness = @'
param(
  [Parameter(Mandatory = $true)][string]$InstallerPath,
  [Parameter(Mandatory = $true)][string]$WorkerCommand,
  [Parameter(Mandatory = $true)][string]$WorkingDirectory
)
$ErrorActionPreference = 'Stop'
$installer = [IO.File]::ReadAllText($InstallerPath)
$pattern = "(?s)# INSTALL_JOB_CSHARP_BEGIN\s+Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@\s+# INSTALL_JOB_CSHARP_END"
$match = [regex]::Match($installer, $pattern)
if (-not $match.Success) { throw 'Could not extract the installer Job Object implementation.' }
Add-Type -TypeDefinition $match.Groups[1].Value
$commandInterpreter = Join-Path $env:SystemRoot 'System32\cmd.exe'
$commandLine = '"' + $commandInterpreter + '" /d /s /c ""' + $WorkerCommand + '""'
[void][AiUsage.InstallJob]::Run($commandInterpreter, $commandLine, $WorkingDirectory, 60000)
'@
  $worker = @'
$ErrorActionPreference = 'Stop'
$startedUtcTicks = (Get-Process -Id $PID).StartTime.ToFileTimeUtc()
[IO.File]::WriteAllText($env:AI_USAGE_JOB_PID_FILE, ([string]$PID + '|' + [string]$startedUtcTicks), [Text.Encoding]::ASCII)
Start-Sleep -Seconds 30
[IO.File]::WriteAllText($env:AI_USAGE_JOB_COMPLETED_FILE, 'completed', [Text.Encoding]::ASCII)
'@
  $command = @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0worker.ps1"
exit /b %errorlevel%
'@
  $exitCommandText = @'
@echo off
exit /b %1
'@
  $captureCommandText = @'
@echo off
echo captured
'@
  $floodScriptText = @'
[Console]::Out.Write(('X' * 2097152))
'@
  $floodCommandText = @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0flood.ps1"
exit /b %errorlevel%
'@
  $naturalChild = @'
param(
  [Parameter(Mandatory = $true)][string]$CompletedPath,
  [Parameter(Mandatory = $true)][int]$DelayMilliseconds
)
Start-Sleep -Milliseconds $DelayMilliseconds
[IO.File]::WriteAllText($CompletedPath, 'completed', [Text.Encoding]::ASCII)
'@
  $naturalRoot = @'
param(
  [Parameter(Mandatory = $true)][string]$ChildPath,
  [Parameter(Mandatory = $true)][string]$PidPath,
  [Parameter(Mandatory = $true)][string]$CompletedDirectory
)
[void][IO.Directory]::CreateDirectory($CompletedDirectory)
$identities = New-Object Collections.Generic.List[string]
for ($index = 0; $index -lt 16; $index++) {
  $completedPath = Join-Path $CompletedDirectory ("child-$index.completed")
  $delay = 500 + ($index * 50)
  $info = New-Object Diagnostics.ProcessStartInfo
  $info.FileName = 'powershell.exe'
  $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ChildPath +
    '" -CompletedPath "' + $completedPath + '" -DelayMilliseconds ' + $delay
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $child = [Diagnostics.Process]::Start($info)
  $child.Refresh()
  $identities.Add(
    ([string]$child.Id + '|' + [string]$child.StartTime.ToFileTimeUtc() + '|' + $completedPath)
  )
  $child.Dispose()
}
[IO.File]::WriteAllLines($PidPath, $identities.ToArray(), [Text.Encoding]::ASCII)
'@
  $naturalCommandText = @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0natural-root.ps1" -ChildPath "%~dp0natural-child.ps1" -PidPath "%~dp0natural.pid" -CompletedDirectory "%~dp0natural-completed"
exit /b %errorlevel%
'@
  [IO.File]::WriteAllText($harnessPath, $harness, [Text.Encoding]::ASCII)
  [IO.File]::WriteAllText($workerPath, $worker, [Text.Encoding]::ASCII)
  [IO.File]::WriteAllText($workerCommand, $command, [Text.Encoding]::ASCII)
  [IO.File]::WriteAllText($exitCommand, $exitCommandText, [Text.Encoding]::ASCII)
  [IO.File]::WriteAllText($captureCommand, $captureCommandText, [Text.Encoding]::ASCII)
  [IO.File]::WriteAllText($floodScript, $floodScriptText, [Text.Encoding]::ASCII)
  [IO.File]::WriteAllText($floodCommand, $floodCommandText, [Text.Encoding]::ASCII)
  [IO.File]::WriteAllText($naturalChildPath, $naturalChild, [Text.Encoding]::ASCII)
  [IO.File]::WriteAllText($naturalRootPath, $naturalRoot, [Text.Encoding]::ASCII)
  [IO.File]::WriteAllText($naturalCommand, $naturalCommandText, [Text.Encoding]::ASCII)

  $env:AI_USAGE_JOB_PID_FILE = $pidPath
  $env:AI_USAGE_JOB_COMPLETED_FILE = $completedPath
  $arguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $harnessPath + '"'),
    '-InstallerPath', ('"' + (Join-Path $root 'install.ps1') + '"'),
    '-WorkerCommand', ('"' + $workerCommand + '"'),
    '-WorkingDirectory', ('"' + $sandbox + '"')
  ) -join ' '
  $harnessProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -PassThru `
    -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  while (-not (Test-Path -LiteralPath $pidPath) -and [DateTime]::UtcNow -lt $deadline) {
    if ($harnessProcess.HasExited) {
      $stderr = if (Test-Path -LiteralPath $stderrPath) { [IO.File]::ReadAllText($stderrPath) } else { '' }
      throw "The Job Object harness exited before its descendant started: $stderr"
    }
    Start-Sleep -Milliseconds 50
  }
  if (-not (Test-Path -LiteralPath $pidPath)) { throw 'The Job Object descendant did not start.' }

  $workerIdentity = Read-WorkerIdentity $pidPath
  $workerPid = $workerIdentity.Id
  if (-not (Test-WorkerIdentityAlive $workerIdentity)) {
    throw 'The Job Object descendant exited before the parent termination probe.'
  }

  Stop-Process -Id $harnessProcess.Id -Force
  [void]$harnessProcess.WaitForExit(10000)

  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  while ((Test-WorkerIdentityAlive $workerIdentity) -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 50
  }
  if (Test-WorkerIdentityAlive $workerIdentity) {
    throw 'The npm descendant survived forced termination of the installer parent.'
  }
  Start-Sleep -Milliseconds 300
  if (Test-Path -LiteralPath $completedPath) {
    throw 'The terminated npm descendant continued to completion.'
  }

  $commandInterpreter = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $naturalLine = '"' + $commandInterpreter + '" /d /s /c ""' + $naturalCommand + '""'
  if ([AiUsage.InstallJob]::Run($commandInterpreter, $naturalLine, $sandbox, 10000) -ne 0 -or
      -not (Test-Path -LiteralPath $naturalPidPath)) {
    throw 'The installer Job did not complete its multiple-descendant probe.'
  }
  $naturalIdentities = @([IO.File]::ReadAllLines($naturalPidPath))
  if ($naturalIdentities.Count -ne 16) { throw 'The installer Job probe did not start all descendants.' }
  foreach ($naturalIdentity in $naturalIdentities) {
    $naturalParts = $naturalIdentity -split '\|', 3
    if ($naturalParts.Count -ne 3 -or -not (Test-Path -LiteralPath $naturalParts[2])) {
      throw 'The installer Job returned before every natural descendant completed.'
    }
    $naturalProcess = Get-Process -Id ([int]$naturalParts[0]) -ErrorAction SilentlyContinue
    if ($naturalProcess) {
      try {
        if ([int64]$naturalProcess.StartTime.ToFileTimeUtc() -eq [int64]$naturalParts[1]) {
          throw 'The installer Job reported completion while a natural descendant remained alive.'
        }
      } finally {
        $naturalProcess.Dispose()
      }
    }
  }

  $zeroLine = '"' + $commandInterpreter + '" /d /s /c ""' + $exitCommand + '" 0"'
  $nonzeroLine = '"' + $commandInterpreter + '" /d /s /c ""' + $exitCommand + '" 17"'
  if ([AiUsage.InstallJob]::Run($commandInterpreter, $zeroLine, $sandbox, 10000) -ne 0) {
    throw 'The Job Object runner changed a successful exit code.'
  }
  if ([AiUsage.InstallJob]::Run($commandInterpreter, $nonzeroLine, $sandbox, 10000) -ne 17) {
    throw 'The Job Object runner changed a nonzero exit code.'
  }

  $captureLine = '"' + $commandInterpreter + '" /d /s /c ""' + $captureCommand + '" > "' + $capturePath + '""'
  if ([AiUsage.InstallJob]::RunWithOutputLimit(
      $commandInterpreter, $captureLine, $sandbox, 10000, $capturePath, 1048576) -ne 0 -or
      -not (Test-Path -LiteralPath $capturePath) -or
      [IO.File]::ReadAllText($capturePath).Trim() -ne 'captured') {
    throw 'The bounded Job capture path did not preserve normal stdout.'
  }

  $floodLine = '"' + $commandInterpreter + '" /d /s /c ""' + $floodCommand + '" > "' + $floodPath + '""'
  $floodRejected = $false
  try {
    [void][AiUsage.InstallJob]::RunWithOutputLimit(
      $commandInterpreter, $floodLine, $sandbox, 10000, $floodPath, 1048576
    )
  } catch {
    if ($_.Exception.Message -notmatch 'output exceeded') { throw }
    $floodRejected = $true
  }
  if (-not $floodRejected) { throw 'The bounded Job capture path accepted excessive stdout.' }

  foreach ($path in @($pidPath, $completedPath)) {
    if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) }
  }
  $timeoutLine = '"' + $commandInterpreter + '" /d /s /c ""' + $workerCommand + '""'
  $timedOut = $false
  try {
    [void][AiUsage.InstallJob]::Run($commandInterpreter, $timeoutLine, $sandbox, 3000)
  } catch {
    if ($_.Exception.Message -notmatch 'timed out') { throw }
    $timedOut = $true
  }
  if (-not $timedOut) { throw 'The Job Object runner did not report its timeout.' }
  if (Test-Path -LiteralPath $pidPath) {
    $workerIdentity = Read-WorkerIdentity $pidPath
    $workerPid = $workerIdentity.Id
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ((Test-WorkerIdentityAlive $workerIdentity) -and [DateTime]::UtcNow -lt $deadline) {
      Start-Sleep -Milliseconds 25
    }
    if (Test-WorkerIdentityAlive $workerIdentity) {
      throw 'The timed-out Job Object worker remained alive.'
    }
  }
  Start-Sleep -Milliseconds 300
  if (Test-Path -LiteralPath $completedPath) { throw 'The timed-out Job Object worker continued to completion.' }

  foreach ($path in @($pidPath, $completedPath)) {
    if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) }
  }
  $captureTimeoutLine = '"' + $commandInterpreter + '" /d /s /c ""' + $workerCommand + '" > "' + $timeoutCapturePath + '""'
  $captureTimedOut = $false
  try {
    [void][AiUsage.InstallJob]::RunWithOutputLimit(
      $commandInterpreter, $captureTimeoutLine, $sandbox, 3000, $timeoutCapturePath, 1048576
    )
  } catch {
    if ($_.Exception.Message -notmatch 'timed out') { throw }
    $captureTimedOut = $true
  }
  if (-not $captureTimedOut) { throw 'The bounded Job capture path did not report its timeout.' }
  if (Test-Path -LiteralPath $pidPath) {
    $workerIdentity = Read-WorkerIdentity $pidPath
    $workerPid = $workerIdentity.Id
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ((Test-WorkerIdentityAlive $workerIdentity) -and [DateTime]::UtcNow -lt $deadline) {
      Start-Sleep -Milliseconds 25
    }
    if (Test-WorkerIdentityAlive $workerIdentity) {
      throw 'The timed-out bounded-capture worker remained alive.'
    }
  }

  Write-Output 'InstallJob.Tests.ps1: PASS'
} finally {
  Remove-Item Env:AI_USAGE_JOB_PID_FILE -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_JOB_COMPLETED_FILE -ErrorAction SilentlyContinue
  if ($harnessProcess -and -not $harnessProcess.HasExited) {
    try { Stop-Process -Id $harnessProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
  }
  if (Test-WorkerIdentityAlive $workerIdentity) {
    try { Stop-Process -Id ([int]$workerIdentity.Id) -Force -ErrorAction SilentlyContinue } catch {}
  }
  try {
    $resolved = [IO.Path]::GetFullPath($sandbox)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved).StartsWith('ai-usage-install-job-test-', [StringComparison]::Ordinal)) {
      if (Test-Path -LiteralPath $resolved) { [IO.Directory]::Delete($resolved, $true) }
    }
  } catch {}
}
