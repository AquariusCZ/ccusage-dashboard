$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$installerPath = Join-Path $root 'install.ps1'
$srcDir = Join-Path $root 'src'
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('ai-usage-installer-test-[literal]-' + [guid]::NewGuid().ToString('N'))
$activeProcesses = New-Object Collections.Generic.List[Diagnostics.Process]
$environmentNames = @(
  'LOCALAPPDATA', 'TEMP', 'TMP', 'PATH', 'AI_USAGE_INSTALL_TEST_NPM_ROOT',
  'AI_USAGE_INSTALL_TEST_BIN', 'AI_USAGE_INSTALL_TEST_NPM_LOG',
  'AI_USAGE_INSTALL_TEST_GATE_SPEC', 'AI_USAGE_INSTALL_TEST_GATE_READY',
    'AI_USAGE_INSTALL_TEST_GATE_RELEASE', 'AI_USAGE_INSTALL_TEST_VERSION_COUNT_DIR',
    'AI_USAGE_INSTALL_TEST_NODE_GATE_READY', 'AI_USAGE_INSTALL_TEST_NODE_GATE_RELEASE',
    'AI_USAGE_INSTALL_TEST_VERSION_FAULT_PACKAGE', 'AI_USAGE_INSTALL_TEST_VERSION_FAULT_AT',
    'AI_USAGE_INSTALL_TEST_VERSION_STDERR_PACKAGE',
    'AI_USAGE_INSTALL_TEST_OLD_RUN_READY', 'AI_USAGE_INSTALL_TEST_OLD_RUN_RELEASE',
    'AI_USAGE_INSTALL_TEST_OVERLAP_MUTEX', 'AI_USAGE_INSTALL_TEST_OVERLAP_MARKER',
  'AI_USAGE_NPM_PATH_TOKEN'
)
$originalEnvironment = @{}
foreach ($name in $environmentNames) {
  $item = Get-Item ("Env:$name") -ErrorAction SilentlyContinue
  $originalEnvironment[$name] = if ($item) { $item.Value } else { $null }
}

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

function Set-FakePackage([pscustomobject]$Scenario, [string]$Package, [string]$Version) {
  $packageDir = Join-Path $Scenario.NpmRoot $Package
  New-Item -ItemType Directory -Force -Path $packageDir | Out-Null
  Write-Ascii (Join-Path $packageDir 'package.json') ('{"name":"' + $Package + '","version":"' + $Version + '"}')
  $wrapper = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0tool-version.ps1`" `"$Package`"`r`nexit /b %errorlevel%`r`n"
  Write-Ascii (Join-Path $Scenario.BinDir ($Package + '.cmd')) $wrapper
}

function Get-FakePackageVersion([pscustomobject]$Scenario, [string]$Package) {
  $manifest = Join-Path (Join-Path $Scenario.NpmRoot $Package) 'package.json'
  if (-not (Test-Path -LiteralPath $manifest)) { return $null }
  return [string](([IO.File]::ReadAllText($manifest) | ConvertFrom-Json).version)
}

function New-Scenario([string]$Name, [bool]$LiteralPercentPath = $false) {
  $scenarioRoot = Join-Path $sandbox $Name
  $localAppData = Join-Path $scenarioRoot 'localappdata'
  $temp = Join-Path $scenarioRoot 'temp'
  $dest = Join-Path $scenarioRoot 'runtime'
  $desktop = Join-Path $scenarioRoot 'desktop'
  $npmRoot = Join-Path $scenarioRoot 'npm\node_modules'
  $binDir = if ($LiteralPercentPath) {
    Join-Path $scenarioRoot 'npm\%AI_USAGE_NPM_PATH_TOKEN%\bin'
  } else {
    Join-Path $scenarioRoot 'npm\bin'
  }
  $versionCountDir = Join-Path $scenarioRoot 'version-counts'
  foreach ($directory in @($localAppData, $temp, $dest, $desktop, $npmRoot, $binDir, $versionCountDir)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
  }

  $scenario = [pscustomobject]@{
    Name = $Name
    Root = $scenarioRoot
    LocalAppData = $localAppData
    Temp = $temp
    Destination = $dest
    Desktop = $desktop
    NpmRoot = $npmRoot
    BinDir = $binDir
    NpmCommand = Join-Path $binDir 'npm.cmd'
    NpmLog = Join-Path $scenarioRoot 'npm.log'
    VersionCountDir = $versionCountDir
    GateReady = Join-Path $scenarioRoot 'gate.ready'
    GateRelease = Join-Path $scenarioRoot 'gate.release'
    NodeGateReady = Join-Path $scenarioRoot 'node-gate.ready'
    NodeGateRelease = Join-Path $scenarioRoot 'node-gate.release'
  }

  $toolVersion = @'
param([Parameter(Mandatory = $true)][string]$Package)
$manifest = Join-Path (Join-Path $env:AI_USAGE_INSTALL_TEST_NPM_ROOT $Package) 'package.json'
if (-not (Test-Path -LiteralPath $manifest)) { exit 44 }
$value = [IO.File]::ReadAllText($manifest) | ConvertFrom-Json
if ($env:AI_USAGE_INSTALL_TEST_VERSION_STDERR_PACKAGE -eq $Package) {
  [Console]::Error.Write(('E' * 1048576))
}
$countPath = Join-Path $env:AI_USAGE_INSTALL_TEST_VERSION_COUNT_DIR ($Package + '.txt')
$count = 1
if (Test-Path -LiteralPath $countPath) { $count = 1 + [int]([IO.File]::ReadAllText($countPath).Trim()) }
[IO.File]::WriteAllText($countPath, [string]$count, [Text.Encoding]::ASCII)
if ($env:AI_USAGE_INSTALL_TEST_VERSION_FAULT_PACKAGE -eq $Package -and
    $env:AI_USAGE_INSTALL_TEST_VERSION_FAULT_AT -and
    $count -eq [int]$env:AI_USAGE_INSTALL_TEST_VERSION_FAULT_AT) {
  Write-Output ([string]$value.version)
  exit 17
}
Write-Output ([string]$value.version)
'@
  $fakeNpm = @'
$ErrorActionPreference = 'Stop'
$stubArgs = @($args)
$overlapMutex = $null
$overlapHeld = $false
if ($env:AI_USAGE_INSTALL_TEST_OVERLAP_MUTEX) {
  $overlapMutex = [Threading.Mutex]::new($false, $env:AI_USAGE_INSTALL_TEST_OVERLAP_MUTEX)
  try { $overlapHeld = $overlapMutex.WaitOne([TimeSpan]::Zero) }
  catch [Threading.AbandonedMutexException] { $overlapHeld = $true }
  if (-not $overlapHeld -and $env:AI_USAGE_INSTALL_TEST_OVERLAP_MARKER) {
    [IO.File]::WriteAllText($env:AI_USAGE_INSTALL_TEST_OVERLAP_MARKER, 'overlap', [Text.Encoding]::ASCII)
  }
}
try {
$globalRoot = [IO.Path]::GetFullPath($env:AI_USAGE_INSTALL_TEST_NPM_ROOT)
$binDir = [IO.Path]::GetFullPath($env:AI_USAGE_INSTALL_TEST_BIN)
if ($stubArgs.Count -eq 2 -and $stubArgs[0] -eq 'root' -and $stubArgs[1] -eq '-g') {
  Write-Output $globalRoot
  exit 0
}
if ($stubArgs.Count -lt 3 -or $stubArgs[1] -ne '-g') { exit 41 }
$operation = $stubArgs[0]
$spec = $stubArgs[2]
[IO.File]::AppendAllText($env:AI_USAGE_INSTALL_TEST_NPM_LOG, ($stubArgs -join '|') + "`r`n", [Text.Encoding]::ASCII)
if ($operation -eq 'install') {
  $separator = $spec.LastIndexOf('@')
  if ($separator -le 0) { exit 42 }
  $package = $spec.Substring(0, $separator)
  $version = $spec.Substring($separator + 1)
  $packageDir = Join-Path $globalRoot $package
  New-Item -ItemType Directory -Force -Path $packageDir | Out-Null
  $manifest = '{"name":"' + $package + '","version":"' + $version + '"}'
  [IO.File]::WriteAllText((Join-Path $packageDir 'package.json'), $manifest, (New-Object Text.UTF8Encoding($false)))
  $wrapper = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0tool-version.ps1`" `"$package`"`r`nexit /b %errorlevel%`r`n"
  [IO.File]::WriteAllText((Join-Path $binDir ($package + '.cmd')), $wrapper, [Text.Encoding]::ASCII)
  if ($env:AI_USAGE_INSTALL_TEST_GATE_SPEC -and $spec -eq $env:AI_USAGE_INSTALL_TEST_GATE_SPEC) {
    [IO.File]::WriteAllText($env:AI_USAGE_INSTALL_TEST_GATE_READY, [string]$PID, [Text.Encoding]::ASCII)
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $env:AI_USAGE_INSTALL_TEST_GATE_RELEASE)) {
      if ([DateTime]::UtcNow -ge $deadline) { exit 43 }
      Start-Sleep -Milliseconds 20
    }
  }
  exit 0
}
if ($operation -eq 'uninstall') {
  $package = $spec
  $packageDir = Join-Path $globalRoot $package
  if (Test-Path -LiteralPath $packageDir) { [IO.Directory]::Delete($packageDir, $true) }
  $wrapperPath = Join-Path $binDir ($package + '.cmd')
  if (Test-Path -LiteralPath $wrapperPath) { [IO.File]::Delete($wrapperPath) }
  exit 0
}
exit 45
} finally {
  if ($overlapHeld) { try { $overlapMutex.ReleaseMutex() } catch {} }
  if ($overlapMutex) { try { $overlapMutex.Dispose() } catch {} }
}
'@
  $npmWrapper = @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0npm-cli.ps1" %*
exit /b %errorlevel%
'@
  Write-Ascii (Join-Path $binDir 'tool-version.ps1') $toolVersion
  Write-Ascii (Join-Path $binDir 'npm-cli.ps1') $fakeNpm
  Write-Ascii $scenario.NpmCommand $npmWrapper
  return $scenario
}

function Set-ScenarioEnvironment([pscustomobject]$Scenario) {
  $env:LOCALAPPDATA = $Scenario.LocalAppData
  $env:TEMP = $Scenario.Temp
  $env:TMP = $Scenario.Temp
  $env:PATH = $Scenario.BinDir + [IO.Path]::PathSeparator + $originalEnvironment['PATH']
  $env:AI_USAGE_INSTALL_TEST_NPM_ROOT = $Scenario.NpmRoot
  $env:AI_USAGE_INSTALL_TEST_BIN = $Scenario.BinDir
  $env:AI_USAGE_INSTALL_TEST_NPM_LOG = $Scenario.NpmLog
  $env:AI_USAGE_INSTALL_TEST_VERSION_COUNT_DIR = $Scenario.VersionCountDir
  $env:AI_USAGE_NPM_PATH_TOKEN = 'expanded-path-must-not-be-used'
  Remove-Item Env:AI_USAGE_INSTALL_TEST_GATE_SPEC -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_GATE_READY -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_GATE_RELEASE -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_OVERLAP_MUTEX -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_OVERLAP_MARKER -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_NODE_GATE_READY -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_NODE_GATE_RELEASE -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_VERSION_FAULT_PACKAGE -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_VERSION_FAULT_AT -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_VERSION_STDERR_PACKAGE -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_OLD_RUN_READY -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_OLD_RUN_RELEASE -ErrorAction SilentlyContinue
}

function Seed-OldRuntime([pscustomobject]$Scenario) {
  $hashes = @{}
  foreach ($source in @(Get-ChildItem -LiteralPath $srcDir -File -Recurse)) {
    $relative = $source.FullName.Substring($srcDir.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
    $target = Join-Path $Scenario.Destination $relative
    Write-Ascii $target ("old-runtime:$relative")
    $hashes[$relative] = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
  }
  return $hashes
}

function Assert-OldRuntime([pscustomobject]$Scenario, [hashtable]$ExpectedHashes, [bool]$KeepPendingAwareGenerator = $false) {
  foreach ($relative in $ExpectedHashes.Keys) {
    $target = Join-Path $Scenario.Destination $relative
    if (-not (Test-Path -LiteralPath $target)) { throw "Rollback removed the original runtime file $relative." }
    $expectedHash = $ExpectedHashes[$relative]
    if ($KeepPendingAwareGenerator -and $relative -eq 'Generate-ClaudeReport.ps1') {
      $expectedHash = (Get-FileHash -LiteralPath (Join-Path $srcDir $relative) -Algorithm SHA256).Hash
    }
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $expectedHash) {
      throw "[$($Scenario.Name)] Rollback did not restore the original runtime file $relative."
    }
  }
}

function Assert-PublishedRuntime([pscustomobject]$Scenario) {
  foreach ($source in @(Get-ChildItem -LiteralPath $srcDir -File -Recurse)) {
    $relative = $source.FullName.Substring($srcDir.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
    $target = Join-Path $Scenario.Destination $relative
    if (-not (Test-Path -LiteralPath $target)) { throw "Installer did not publish $relative." }
    $sourceHash = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
    $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if ($sourceHash -ne $targetHash) {
      throw "[$($Scenario.Name)] Published runtime hash differs for ${relative}: expected $sourceHash, actual $targetHash."
    }
  }
}

function Start-Installer([pscustomobject]$Scenario) {
  $arguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $installerPath + '"'),
    '-Destination', ('"' + $Scenario.Destination + '"'),
    '-DesktopDirectory', ('"' + $Scenario.Desktop + '"'),
    '-NpmCommand', ('"' + $Scenario.NpmCommand + '"'), '-NoPrompt'
  ) -join ' '
  $startInfo = New-Object Diagnostics.ProcessStartInfo
  $startInfo.FileName = 'powershell.exe'
  $startInfo.Arguments = $arguments
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = New-Object Diagnostics.Process
  $process.StartInfo = $startInfo
  if (-not $process.Start()) { throw 'Could not start the isolated installer.' }
  $activeProcesses.Add($process)
  return [pscustomobject]@{ Process = $process }
}

function Wait-Installer([pscustomobject]$Invocation, [int]$TimeoutMilliseconds = 60000) {
  if (-not $Invocation.Process.WaitForExit($TimeoutMilliseconds)) {
    try { Stop-Process -Id $Invocation.Process.Id -Force -ErrorAction SilentlyContinue } catch {}
    [void]$Invocation.Process.WaitForExit(10000)
    $timeoutOutput = $Invocation.Process.StandardOutput.ReadToEnd() + $Invocation.Process.StandardError.ReadToEnd()
    throw "The isolated installer did not finish before the test timeout: $timeoutOutput"
  }
  $Invocation.Process.WaitForExit()
  $Invocation.Process.Refresh()
  $exitCode = $Invocation.Process.ExitCode
  $stdout = $Invocation.Process.StandardOutput.ReadToEnd()
  $stderr = $Invocation.Process.StandardError.ReadToEnd()
  return [pscustomobject]@{ ExitCode = $exitCode; Output = $stdout + $stderr }
}

function Assert-NoTransactionResidue([pscustomobject]$Scenario) {
  if (@(Get-ChildItem -LiteralPath $Scenario.LocalAppData -Directory -Filter '.ClaudeUsage-install-*' -ErrorAction SilentlyContinue).Count) {
    throw 'The installer left a transaction directory in the isolated local app data root.'
  }
  $runState = Join-Path (Join-Path $Scenario.Temp 'ClaudeUsage') 'report-run.state'
  if (Test-Path -LiteralPath $runState) { throw 'The installer left report-run.state behind.' }
  foreach ($rootPath in @($Scenario.Destination, $Scenario.Desktop)) {
    $residue = @(Get-ChildItem -LiteralPath $rootPath -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
      $_.Name -match '^\..+\.install-[0-9a-fA-F]{32}\.tmp(?:\.bak)?$'
    })
    if ($residue.Count) { throw 'The installer left atomic publication residue behind.' }
  }
}

function Find-TransactionRootForPid([pscustomobject]$Scenario, [int]$OwnerPid) {
  foreach ($directory in @(Get-ChildItem -LiteralPath $Scenario.LocalAppData -Directory -Filter '.ClaudeUsage-install-*' -ErrorAction SilentlyContinue)) {
    if ($directory.Name -cnotmatch '^\.ClaudeUsage-install-[0-9a-fA-F]{32}$') { continue }
    $ownerPath = Join-Path $directory.FullName '.owner'
    if (-not (Test-Path -LiteralPath $ownerPath)) { continue }
    try {
      if ([IO.File]::ReadAllText($ownerPath) -match ("^pid={0}\r?\n" -f $OwnerPid)) { return $directory.FullName }
    } catch {}
  }
  return $null
}

function Invoke-RollbackScenario([string]$Name, [bool]$PreexistingPending) {
  $scenario = New-Scenario $Name
  Set-ScenarioEnvironment $scenario
  Set-FakePackage $scenario 'codeburn' '0.9.19'
  Set-FakePackage $scenario 'ccusage' '20.0.14'
  $oldHashes = Seed-OldRuntime $scenario
  $pendingPath = Join-Path $scenario.Destination '.install-pending'
  if ($PreexistingPending) { Write-Ascii $pendingPath "transaction=interrupted`r`nstage=pending`r`n" }

  $env:AI_USAGE_INSTALL_TEST_GATE_SPEC = 'ccusage@20.0.20'
  $env:AI_USAGE_INSTALL_TEST_GATE_READY = $scenario.GateReady
  $env:AI_USAGE_INSTALL_TEST_GATE_RELEASE = $scenario.GateRelease
  $invocation = Start-Installer $scenario

  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while (-not (Test-Path -LiteralPath $scenario.GateReady) -and [DateTime]::UtcNow -lt $deadline) {
    if ($invocation.Process.HasExited) {
      $early = Wait-Installer $invocation
      throw "Installer exited before the rollback fault was injected: $($early.Output)"
    }
    Start-Sleep -Milliseconds 25
  }
  if (-not (Test-Path -LiteralPath $scenario.GateReady)) { throw 'The npm upgrade gate was not reached.' }
  if ((Get-FakePackageVersion $scenario 'ccusage') -ne '20.0.20') {
    throw 'The rollback test did not observe the upgraded dependency before publication failure.'
  }

  $lockedTarget = Join-Path $scenario.Destination 'template.html'
  $lock = [IO.File]::Open($lockedTarget, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    Write-Ascii $scenario.GateRelease 'release'
    $result = Wait-Installer $invocation
  } finally {
    $lock.Dispose()
  }
  Remove-Item Env:AI_USAGE_INSTALL_TEST_GATE_SPEC -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_GATE_READY -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_GATE_RELEASE -ErrorAction SilentlyContinue

  if ($result.ExitCode -eq 0) { throw 'The locked runtime target did not fail publication.' }
  if ($PreexistingPending) {
    if ($result.Output -notmatch 'pending marker was retained') { throw 'Recovery failure did not report retained pending state.' }
    if (-not (Test-Path -LiteralPath $pendingPath)) { throw 'Recovery failure removed a preexisting pending marker.' }
  } else {
    if ($result.Output -notmatch 'was rolled back') { throw 'Publication failure did not report a completed rollback.' }
    if (Test-Path -LiteralPath $pendingPath) { throw 'Clean rollback left a new pending marker behind.' }
  }
  Assert-OldRuntime $scenario $oldHashes $PreexistingPending
  if ((Get-FakePackageVersion $scenario 'codeburn') -ne '0.9.19' -or
      (Get-FakePackageVersion $scenario 'ccusage') -ne '20.0.14') {
    throw 'Dependency versions were not restored after runtime publication failed.'
  }
  Assert-NoTransactionResidue $scenario
}

try {
  New-Item -ItemType Directory -Force -Path $sandbox | Out-Null

  $tokens = $null
  $parseErrors = $null
  $installerAst = [Management.Automation.Language.Parser]::ParseFile(
    $installerPath, [ref]$tokens, [ref]$parseErrors
  )
  if ($parseErrors.Count) { throw 'Could not parse installer process-disposition helper.' }
  $dispositionDefinition = $installerAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq 'Get-MigrationUsageProcessDisposition'
  }, $true)
  if (-not $dispositionDefinition) { throw 'Installer process-disposition helper is missing.' }
  . ([scriptblock]::Create($dispositionDefinition.Extent.Text))
  $processDefinition = $installerAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq 'Get-MigrationUsageProcesses'
  }, $true)
  if (-not $processDefinition) { throw 'Installer migration process enumerator is missing.' }
  $waitDefinition = $installerAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq 'Wait-MigrationUsageProcesses'
  }, $true)
  if (-not $waitDefinition) { throw 'Installer migration process wait helper is missing.' }
  $abandonedTestDefinition = $installerAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq 'Test-AbandonedInstallProcess'
  }, $true)
  $abandonedProcessDefinition = $installerAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq 'Get-AbandonedInstallProcesses'
  }, $true)
  $toolVersionDefinition = $installerAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq 'Get-ToolVersion'
  }, $true)
  $exactVersionDefinition = $installerAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq 'Get-ExactReleaseVersion'
  }, $true)
  $cmdCaptureDefinition = $installerAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq 'Invoke-CmdCapture'
  }, $true)
  $npmDefinition = $installerAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq 'Invoke-Npm'
  }, $true)
  if (-not $abandonedTestDefinition -or -not $abandonedProcessDefinition -or
      -not $toolVersionDefinition -or -not $exactVersionDefinition -or
      -not $cmdCaptureDefinition -or -not $npmDefinition) {
    throw 'Installer cleanup-boundary helpers are missing.'
  }
  $dispositionCases = @(
    @('powershell.exe', 'powershell -File .\Generate-ClaudeReport.ps1', 'Same', $true, 'Wait'),
    @('pwsh.exe', 'pwsh -File src/Generate-ClaudeReport.ps1', 'Same', $true, 'Wait'),
    @('powershell.exe', 'powershell -File NotGenerate-ClaudeReport.ps1', 'Same', $true, 'Ignore'),
    @('powershell.exe', 'powershell -File Generate-ClaudeReport.ps1.bak', 'Same', $true, 'Ignore'),
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
    @('pwsh.exe', '', 'Unknown', $false, 'Ignore'),
    @('pwsh.exe', 'pwsh -File unrelated.ps1', 'Same', $true, 'Ignore')
  )
  foreach ($case in $dispositionCases) {
    $actual = Get-MigrationUsageProcessDisposition $case[0] $case[1] $case[2] $case[3]
    if ($actual -ne $case[4]) {
      throw "Migration process disposition was $actual instead of $($case[4]) for $($case[1])."
    }
  }

  & {
    . ([scriptblock]::Create($dispositionDefinition.Extent.Text))
    . ([scriptblock]::Create($processDefinition.Extent.Text))
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
    $script:ownerQueries = 0
    function Invoke-CimMethod {
      [CmdletBinding()]
      param($InputObject, [string]$MethodName, [int]$OperationTimeoutSec)
      $script:ownerQueries += 1
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
        $script:ownerQueries -ne 4) {
      throw 'The Session 0 migration scan did not enforce Same/Other/Unknown ownership policy.'
    }
  }

  & {
    . ([scriptblock]::Create($waitDefinition.Extent.Text))
    $script:migrationScans = 0
    function Get-MigrationUsageProcesses {
      param([string]$UserSid)
      $script:migrationScans += 1
      if ($script:migrationScans -eq 1) {
        return [pscustomobject]@{
          ProcessId = 424243; Name = 'ccusage.exe'; SessionId = 0; OwnerState = 'Unknown'
        }
      }
      return @()
    }
    function Start-Sleep { param([int]$Milliseconds) }
    Wait-MigrationUsageProcesses 'S-1-5-21-424242'
    if ($script:migrationScans -ne 3) {
      throw 'Migration cleanup did not require two stable empty scans after the last ccusage process.'
    }
  }

  & {
    . ([scriptblock]::Create($abandonedTestDefinition.Extent.Text))
    . ([scriptblock]::Create($abandonedProcessDefinition.Extent.Text))
    $testSid = 'S-1-5-21-515151'
    function Get-CimInstance {
      [CmdletBinding()]
      param([string]$ClassName)
      return @(
        [pscustomobject]@{ ProcessId = 515151; Name = 'node.exe'; CommandLine = $null },
        [pscustomobject]@{ ProcessId = 515152; Name = 'cmd.exe'; CommandLine = $null },
        [pscustomobject]@{ ProcessId = 515153; Name = 'powershell.exe'; CommandLine = $null },
        [pscustomobject]@{ ProcessId = 515154; Name = 'npm.exe'; CommandLine = $null },
        [pscustomobject]@{ ProcessId = 515155; Name = 'node.exe'; CommandLine = 'node unrelated.js' },
        [pscustomobject]@{ ProcessId = 515156; Name = 'node.exe'; CommandLine = 'node C:\npm\npm-cli.js install -g codeburn' }
      )
    }
    function Invoke-CimMethod {
      [CmdletBinding()]
      param($InputObject, [string]$MethodName, [int]$OperationTimeoutSec)
      if ($InputObject.ProcessId -in @(515151, 515155, 515156)) {
        return [pscustomobject]@{ ReturnValue = 0; Sid = $testSid }
      }
      if ($InputObject.ProcessId -eq 515152) {
        return [pscustomobject]@{ ReturnValue = 0; Sid = 'S-1-5-18' }
      }
      throw 'owner unavailable'
    }
    function Get-Process {
      [CmdletBinding()]
      param([int]$Id)
      if ($Id -eq 515154) { return [pscustomobject]@{ Id = $Id } }
      return $null
    }
    $matches = @(Get-AbandonedInstallProcesses $testSid)
    if ($matches.Count -ne 3 -or
        @($matches | ForEach-Object ProcessId) -join ',' -ne '515151,515154,515156') {
      throw 'Abandoned npm cleanup did not conservatively retain unreadable same-SID shells.'
    }
  }

  & {
    . ([scriptblock]::Create($toolVersionDefinition.Extent.Text))
    . ([scriptblock]::Create($exactVersionDefinition.Extent.Text))
    function Invoke-CmdCapture { throw 'synthetic version probe failure' }
    $previousCleanupRequired = $script:installProcessCleanupRequired
    try {
      $script:installProcessCleanupRequired = $true
      foreach ($probe in @('Get-ToolVersion', 'Get-ExactReleaseVersion')) {
        $threw = $false
        try { & $probe 'synthetic.cmd' | Out-Null } catch { $threw = $true }
        if (-not $threw) { throw "$probe swallowed an uncertain Job cleanup failure." }
      }
      $script:installProcessCleanupRequired = $false
      if ($null -ne (Get-ToolVersion 'synthetic.cmd') -or
          $null -ne (Get-ExactReleaseVersion 'synthetic.cmd')) {
        throw 'An ordinary version-probe failure no longer degrades to an unavailable version.'
      }
    } finally {
      $script:installProcessCleanupRequired = $previousCleanupRequired
    }
  }

  & {
    . ([scriptblock]::Create($cmdCaptureDefinition.Extent.Text))
    . ([scriptblock]::Create($npmDefinition.Extent.Text))
    $previousCleanupRequired = $script:installProcessCleanupRequired
    $script:guardBoundaryReached = $false
    function Test-SafeCommandArguments { $script:guardBoundaryReached = $true }
    try {
      $script:installProcessCleanupRequired = $true
      foreach ($operation in @('capture', 'npm')) {
        $threw = $false
        try {
          if ($operation -eq 'capture') {
            [void](Invoke-CmdCapture 'synthetic.cmd' @('--version'))
          } else {
            Invoke-Npm @('install', '-g', 'codeburn@0.9.19') 'synthetic failure'
          }
        } catch {
          $threw = $true
        }
        if (-not $threw) { throw "The $operation path ignored an uncertain prior cleanup." }
      }
      if ($script:guardBoundaryReached) {
        throw 'An installer command crossed the pre-launch guard while cleanup was uncertain.'
      }
    } finally {
      $script:installProcessCleanupRequired = $previousCleanupRequired
      $script:guardBoundaryReached = $false
    }
  }

  $invalidNodeCases = @(
    [pscustomobject]@{ Name = 'old-node'; Output = 'v20.0.0' },
    [pscustomobject]@{ Name = 'noisy-node'; Output = 'warning: requires npm 99.0.0' },
    [pscustomobject]@{ Name = 'prerelease-node'; Output = 'v22.13.0-rc.1' }
  )
  foreach ($nodeCase in $invalidNodeCases) {
    $invalidNode = New-Scenario $nodeCase.Name
    Set-ScenarioEnvironment $invalidNode
    Write-Ascii (Join-Path $invalidNode.BinDir 'node.cmd') ("@echo off`r`necho " + $nodeCase.Output + "`r`nexit /b 0`r`n")
    $invalidNodeResult = Wait-Installer (Start-Installer $invalidNode)
    if ($invalidNodeResult.ExitCode -eq 0 -or $invalidNodeResult.Output -notmatch 'requires Node\.js 22\.13\.0 or newer') {
      throw "The installer accepted invalid Node.js output: $($nodeCase.Output)"
    }
    Assert-NoTransactionResidue $invalidNode
  }

  $reparse = New-Scenario 'reparse-point-rejection'
  Set-ScenarioEnvironment $reparse
  Set-FakePackage $reparse 'codeburn' '0.9.19'
  Set-FakePackage $reparse 'ccusage' '20.0.20'
  $reparseTarget = Join-Path $reparse.Root 'junction-target'
  $reparseSentinel = Join-Path $reparseTarget 'sentinel.txt'
  New-Item -ItemType Directory -Force -Path $reparseTarget | Out-Null
  Write-Ascii $reparseSentinel 'outside managed destination'
  $reparseLink = Join-Path $reparse.Destination 'fonts'
  New-TestJunction $reparseLink $reparseTarget
  try {
    $reparseResult = Wait-Installer (Start-Installer $reparse)
    if ($reparseResult.ExitCode -eq 0 -or $reparseResult.Output -notmatch 'reparse') {
      throw "The installer accepted a reparse point in a managed destination path: $($reparseResult.Output)"
    }
    if ([IO.File]::ReadAllText($reparseSentinel) -cne 'outside managed destination' -or
        @(Get-ChildItem -LiteralPath $reparseTarget -Force).Count -ne 1 -or
        (Test-Path -LiteralPath (Join-Path $reparse.Destination '.install-pending'))) {
      throw 'The rejected reparse-point install changed its target or published a transaction marker.'
    }
    Assert-NoTransactionResidue $reparse
  } finally {
    if (Test-Path -LiteralPath $reparseLink) { [IO.Directory]::Delete($reparseLink, $false) }
  }

  # The owner record must exist before the first captured external probe. A
  # force-kill here leaves capture residue, which the next committed installer
  # may remove only after proving that the recorded owner process is dead.
  $nodeProbeKill = New-Scenario 'node-probe-kill-recovery'
  Set-ScenarioEnvironment $nodeProbeKill
  Set-FakePackage $nodeProbeKill 'codeburn' '0.9.19'
  Set-FakePackage $nodeProbeKill 'ccusage' '20.0.20'
  [void](Seed-OldRuntime $nodeProbeKill)
  $nodeGateScript = @'
$ErrorActionPreference = 'Stop'
[IO.File]::WriteAllText($env:AI_USAGE_INSTALL_TEST_NODE_GATE_READY, [string]$PID, [Text.Encoding]::ASCII)
$deadline = [DateTime]::UtcNow.AddSeconds(30)
while (-not (Test-Path -LiteralPath $env:AI_USAGE_INSTALL_TEST_NODE_GATE_RELEASE)) {
  if ([DateTime]::UtcNow -ge $deadline) { exit 51 }
  Start-Sleep -Milliseconds 20
}
Write-Output 'v24.18.0'
'@
  Write-Ascii (Join-Path $nodeProbeKill.BinDir 'node-gate.ps1') $nodeGateScript
  Write-Ascii (Join-Path $nodeProbeKill.BinDir 'node.cmd') ("@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0node-gate.ps1`"`r`nexit /b %errorlevel%`r`n")
  $env:AI_USAGE_INSTALL_TEST_NODE_GATE_READY = $nodeProbeKill.NodeGateReady
  $env:AI_USAGE_INSTALL_TEST_NODE_GATE_RELEASE = $nodeProbeKill.NodeGateRelease
  $nodeProbeInvocation = Start-Installer $nodeProbeKill
  $nodeGateDeadline = [DateTime]::UtcNow.AddSeconds(30)
  while (-not (Test-Path -LiteralPath $nodeProbeKill.NodeGateReady) -and [DateTime]::UtcNow -lt $nodeGateDeadline) {
    if ($nodeProbeInvocation.Process.HasExited) { break }
    Start-Sleep -Milliseconds 20
  }
  if (-not (Test-Path -LiteralPath $nodeProbeKill.NodeGateReady)) {
    throw 'The force-kill Node probe did not reach its gate.'
  }
  $nodeProbeChildPid = [int]([IO.File]::ReadAllText($nodeProbeKill.NodeGateReady).Trim())
  $nodeProbeTransaction = Find-TransactionRootForPid $nodeProbeKill $nodeProbeInvocation.Process.Id
  if (-not $nodeProbeTransaction) {
    throw 'The installer did not publish a complete owner record before its Node probe.'
  }
  Stop-Process -Id $nodeProbeInvocation.Process.Id -Force
  $nodeProbeKilledResult = Wait-Installer $nodeProbeInvocation 10000
  if ($nodeProbeKilledResult.ExitCode -eq 0) { throw 'Force-terminated Node probe installer reported success.' }
  $nodeProbeChildDeadline = [DateTime]::UtcNow.AddSeconds(10)
  while ((Get-Process -Id $nodeProbeChildPid -ErrorAction SilentlyContinue) -and
      [DateTime]::UtcNow -lt $nodeProbeChildDeadline) {
    Start-Sleep -Milliseconds 25
  }
  if (Get-Process -Id $nodeProbeChildPid -ErrorAction SilentlyContinue) {
    throw 'Force-terminating the installer did not kill its Node probe child process.'
  }
  if (-not (Test-Path -LiteralPath $nodeProbeTransaction)) {
    throw 'Force-terminating the Node probe unexpectedly removed its interrupted transaction.'
  }
  if (-not @(Get-ChildItem -LiteralPath $nodeProbeTransaction -File -Filter '.capture-*.stdout' -ErrorAction SilentlyContinue).Count) {
    throw 'The force-kill Node probe did not leave the expected captured-output residue.'
  }
  Remove-Item Env:AI_USAGE_INSTALL_TEST_NODE_GATE_READY -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_NODE_GATE_RELEASE -ErrorAction SilentlyContinue
  Write-Ascii (Join-Path $nodeProbeKill.BinDir 'node.cmd') "@echo off`r`necho v24.18.0`r`nexit /b 0`r`n"
  $nodeProbeRecovery = Wait-Installer (Start-Installer $nodeProbeKill)
  if ($nodeProbeRecovery.ExitCode -ne 0) {
    throw "Node probe recovery install failed: $($nodeProbeRecovery.Output)"
  }
  if (Test-Path -LiteralPath $nodeProbeTransaction) {
    throw 'A committed recovery retained the dead owner-tagged Node probe transaction.'
  }
  Assert-PublishedRuntime $nodeProbeKill
  Assert-NoTransactionResidue $nodeProbeKill

  $success = New-Scenario 'success'
  Set-ScenarioEnvironment $success
  Set-FakePackage $success 'codeburn' '0.9.19'
  Set-FakePackage $success 'ccusage' '20.0.14'
  [void](Seed-OldRuntime $success)
  $oldManagedIcon = Join-Path $success.Destination 'icon-deadbeef.ico'
  $unrelatedIcon = Join-Path $success.Destination 'icon-cafebabe.ico'
  Write-Ascii $oldManagedIcon 'previous managed icon'
  Write-Ascii $unrelatedIcon 'unrelated user file'
  $oldShortcutPath = Join-Path $success.Desktop 'AI Usage.lnk'
  $oldShortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($oldShortcutPath)
  $oldShortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
  $oldShortcut.Arguments = '"' + (Join-Path $success.Destination 'dashboard.vbs') + '"'
  $oldShortcut.WorkingDirectory = $success.Destination
  $oldShortcut.IconLocation = "$oldManagedIcon,0"
  $oldShortcut.Save()

  $legacyProbe = [Threading.Mutex]::new($false, 'Local\AIUsage-CodeBurn')
  $legacyProbeHeld = $false
  try {
    try {
      $legacyProbeHeld = $legacyProbe.WaitOne([TimeSpan]::FromMinutes(5))
    } catch [Threading.AbandonedMutexException] {
      $legacyProbeHeld = $true
    }
    if (-not $legacyProbeHeld) { throw 'Could not acquire the legacy mutex for the installer migration probe.' }
    $successInvocation = Start-Installer $success
    $legacyWaitDeadline = [DateTime]::UtcNow.AddSeconds(30)
    $successPending = Join-Path $success.Destination '.install-pending'
    while (-not (Test-Path -LiteralPath $successPending) -and [DateTime]::UtcNow -lt $legacyWaitDeadline) {
      if ($successInvocation.Process.HasExited) { break }
      Start-Sleep -Milliseconds 25
    }
    $successInvocation.Process.Refresh()
    if ($successInvocation.Process.HasExited) { throw 'The installer did not wait for a legacy report mutex owner.' }
    if (-not (Test-Path -LiteralPath $successPending)) {
      throw 'The installer did not establish its pending marker before waiting on the legacy mutex.'
    }
    $generatorTarget = Join-Path $success.Destination 'Generate-ClaudeReport.ps1'
    $generatorSourceHash = (Get-FileHash -LiteralPath (Join-Path $srcDir 'Generate-ClaudeReport.ps1') -Algorithm SHA256).Hash
    $generatorPublished = $false
    $generatorDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not $generatorPublished -and [DateTime]::UtcNow -lt $generatorDeadline) {
      try {
        $generatorPublished = (Get-FileHash -LiteralPath $generatorTarget -Algorithm SHA256).Hash -eq $generatorSourceHash
      } catch { $generatorPublished = $false }
      if (-not $generatorPublished) {
        if ($successInvocation.Process.HasExited) { break }
        Start-Sleep -Milliseconds 25
      }
    }
    if (-not $generatorPublished) {
      throw 'The installer did not publish the pending-aware generator before waiting on the legacy mutex.'
    }
    if ((Get-FakePackageVersion $success 'ccusage') -ne '20.0.14') {
      throw 'The installer mutated npm while the legacy report mutex was held.'
    }
  } finally {
    if ($legacyProbeHeld) { try { $legacyProbe.ReleaseMutex() } catch {} }
    try { $legacyProbe.Dispose() } catch {}
  }

  $successResult = Wait-Installer $successInvocation
  if ($successResult.ExitCode -ne 0) {
    throw "Isolated installation exited $($successResult.ExitCode): $($successResult.Output)"
  }
  Assert-PublishedRuntime $success
  if ((Get-FakePackageVersion $success 'codeburn') -ne '0.9.19' -or
      (Get-FakePackageVersion $success 'ccusage') -ne '20.0.20') {
    throw 'Successful installation did not leave the pinned dependency versions.'
  }
  if (Test-Path -LiteralPath (Join-Path $success.Destination '.install-pending')) {
    throw 'Successful installation left its pending marker behind.'
  }
  $shortcutPath = Join-Path $success.Desktop 'AI Usage.lnk'
  if (-not (Test-Path -LiteralPath $shortcutPath)) { throw 'Successful installation did not publish its shortcut.' }
  $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
  $expectedTarget = Join-Path $env:SystemRoot 'System32\wscript.exe'
  if (-not ([IO.Path]::GetFullPath($shortcut.TargetPath)).Equals(
      [IO.Path]::GetFullPath($expectedTarget), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The installed shortcut has the wrong target.'
  }
  $expectedArguments = '"' + (Join-Path $success.Destination 'dashboard.vbs') + '"'
  if ($shortcut.Arguments -ne $expectedArguments) { throw 'The installed shortcut has the wrong arguments.' }
  if (-not ([IO.Path]::GetFullPath($shortcut.WorkingDirectory)).Equals(
      [IO.Path]::GetFullPath($success.Destination), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The installed shortcut has the wrong working directory.'
  }
  $expectedIconHash = (Get-FileHash -LiteralPath (Join-Path $srcDir 'icon.ico') -Algorithm SHA256).Hash.Substring(0, 8).ToLower()
  $expectedIcon = Join-Path $success.Destination ("icon-$expectedIconHash.ico")
  if ($shortcut.IconLocation -ne "$expectedIcon,0") { throw 'The installed shortcut has the wrong icon.' }
  if (Test-Path -LiteralPath $oldManagedIcon) { throw 'The icon referenced by the previous shortcut was not retired.' }
  if (-not (Test-Path -LiteralPath $unrelatedIcon)) { throw 'Installer deleted an unowned icon-like file.' }
  Assert-NoTransactionResidue $success

  # A pre-migration generator in another Windows Session owns a different Local
  # mutex. This probe deliberately owns no mutex, so only the SID/process drain
  # can keep npm unchanged until the already-started script exits.
  $crossSession = New-Scenario 'cross-session-drain'
  Set-ScenarioEnvironment $crossSession
  Set-FakePackage $crossSession 'codeburn' '0.9.19'
  Set-FakePackage $crossSession 'ccusage' '20.0.14'
  [void](Seed-OldRuntime $crossSession)
  $oldGeneratorPath = Join-Path $crossSession.Destination 'Generate-ClaudeReport.ps1'
  $oldGeneratorProbe = @'
$ErrorActionPreference = 'Stop'
[IO.File]::WriteAllText($env:AI_USAGE_INSTALL_TEST_OLD_RUN_READY, [string]$PID, [Text.Encoding]::ASCII)
$deadline = [DateTime]::UtcNow.AddSeconds(30)
while (-not (Test-Path -LiteralPath $env:AI_USAGE_INSTALL_TEST_OLD_RUN_RELEASE)) {
  if ([DateTime]::UtcNow -ge $deadline) { exit 47 }
  Start-Sleep -Milliseconds 20
}
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$global = [Threading.Mutex]::new($false, "Global\AIUsage-CodeBurn-$sid")
$local = [Threading.Mutex]::new($false, 'Local\AIUsage-CodeBurn')
$globalHeld = $false
$localHeld = $false
try {
  try { $globalHeld = $global.WaitOne([TimeSpan]::FromSeconds(10)) } catch [Threading.AbandonedMutexException] { $globalHeld = $true }
  if (-not $globalHeld) { exit 48 }
  try { $localHeld = $local.WaitOne([TimeSpan]::FromSeconds(10)) } catch [Threading.AbandonedMutexException] { $localHeld = $true }
  if (-not $localHeld) { exit 49 }
} finally {
  if ($localHeld) { try { $local.ReleaseMutex() } catch {} }
  if ($globalHeld) { try { $global.ReleaseMutex() } catch {} }
  $local.Dispose()
  $global.Dispose()
}
'@
  Write-Ascii $oldGeneratorPath $oldGeneratorProbe
  $env:AI_USAGE_INSTALL_TEST_OLD_RUN_READY = Join-Path $crossSession.Root 'old-run.ready'
  $env:AI_USAGE_INSTALL_TEST_OLD_RUN_RELEASE = Join-Path $crossSession.Root 'old-run.release'
  $oldRunStart = New-Object Diagnostics.ProcessStartInfo
  $oldRunStart.FileName = 'powershell.exe'
  $oldRunStart.Arguments = '-NoProfile -ExecutionPolicy Bypass -File ".\Generate-ClaudeReport.ps1"'
  $oldRunStart.WorkingDirectory = $crossSession.Destination
  $oldRunStart.UseShellExecute = $false
  $oldRunStart.CreateNoWindow = $true
  $oldRun = New-Object Diagnostics.Process
  $oldRun.StartInfo = $oldRunStart
  if (-not $oldRun.Start()) { throw 'Could not start the cross-session migration probe.' }
  $activeProcesses.Add($oldRun)
  $oldRunDeadline = [DateTime]::UtcNow.AddSeconds(30)
  while (-not (Test-Path -LiteralPath $env:AI_USAGE_INSTALL_TEST_OLD_RUN_READY) -and [DateTime]::UtcNow -lt $oldRunDeadline) {
    Start-Sleep -Milliseconds 20
  }
  if (-not (Test-Path -LiteralPath $env:AI_USAGE_INSTALL_TEST_OLD_RUN_READY)) { throw 'The cross-session migration probe did not start.' }

  $crossInvocation = Start-Installer $crossSession
  $crossPending = Join-Path $crossSession.Destination '.install-pending'
  $crossDeadline = [DateTime]::UtcNow.AddSeconds(30)
  while (-not (Test-Path -LiteralPath $crossPending) -and [DateTime]::UtcNow -lt $crossDeadline) {
    if ($crossInvocation.Process.HasExited) { break }
    Start-Sleep -Milliseconds 25
  }
  if (-not (Test-Path -LiteralPath $crossPending)) { throw 'Cross-session migration did not publish its pending marker.' }
  Start-Sleep -Milliseconds 500
  $crossInvocation.Process.Refresh()
  if ($crossInvocation.Process.HasExited) { throw 'Installer did not drain a same-SID legacy process outside the Local mutex.' }
  if ((Get-FakePackageVersion $crossSession 'ccusage') -ne '20.0.14') {
    throw 'Installer changed npm before the cross-session legacy process exited.'
  }
  Write-Ascii $env:AI_USAGE_INSTALL_TEST_OLD_RUN_RELEASE 'release'
  if (-not $oldRun.WaitForExit(10000)) { throw 'The cross-session migration probe did not exit.' }
  $crossResult = Wait-Installer $crossInvocation
  Remove-Item Env:AI_USAGE_INSTALL_TEST_OLD_RUN_READY -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_OLD_RUN_RELEASE -ErrorAction SilentlyContinue
  if ($crossResult.ExitCode -ne 0) { throw "Cross-session migration failed: $($crossResult.Output)" }
  Assert-PublishedRuntime $crossSession
  if ((Get-FakePackageVersion $crossSession 'ccusage') -ne '20.0.20') {
    throw 'Cross-session migration did not install the pinned ccusage version after draining.'
  }
  Assert-NoTransactionResidue $crossSession

  # Start the replacement before killing the current installer. It must wake on
  # the abandoned mutex, then wait for the old npm Job to become stably empty
  # before issuing even a read-only npm root probe.
  $abandonedWaiter = New-Scenario 'abandoned-install-waiter'
  Set-ScenarioEnvironment $abandonedWaiter
  Set-FakePackage $abandonedWaiter 'codeburn' '0.9.19'
  Set-FakePackage $abandonedWaiter 'ccusage' '20.0.14'
  [void](Seed-OldRuntime $abandonedWaiter)
  $abandonedOverlap = Join-Path $abandonedWaiter.Root 'npm-overlap.txt'
  $env:AI_USAGE_INSTALL_TEST_OVERLAP_MUTEX = 'Global\AIUsage-Test-Npm-' + [guid]::NewGuid().ToString('N')
  $env:AI_USAGE_INSTALL_TEST_OVERLAP_MARKER = $abandonedOverlap
  $env:AI_USAGE_INSTALL_TEST_GATE_SPEC = 'ccusage@20.0.20'
  $env:AI_USAGE_INSTALL_TEST_GATE_READY = $abandonedWaiter.GateReady
  $env:AI_USAGE_INSTALL_TEST_GATE_RELEASE = $abandonedWaiter.GateRelease
  $abandonedOwner = Start-Installer $abandonedWaiter
  $abandonedDeadline = [DateTime]::UtcNow.AddSeconds(30)
  while (-not (Test-Path -LiteralPath $abandonedWaiter.GateReady) -and [DateTime]::UtcNow -lt $abandonedDeadline) {
    if ($abandonedOwner.Process.HasExited) { break }
    Start-Sleep -Milliseconds 25
  }
  if (-not (Test-Path -LiteralPath $abandonedWaiter.GateReady)) {
    $abandonedOwner.Process.Refresh()
    if ($abandonedOwner.Process.HasExited) {
      $earlyAbandonedOwner = Wait-Installer $abandonedOwner 1000
      throw "Abandoned-install waiter owner exited before the npm gate: $($earlyAbandonedOwner.Output)"
    }
    throw 'Abandoned-install waiter owner remained blocked before the npm gate for 30 seconds.'
  }
  $abandonedChildPid = [int]([IO.File]::ReadAllText($abandonedWaiter.GateReady).Trim())
  Remove-Item Env:AI_USAGE_INSTALL_TEST_GATE_SPEC -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_GATE_READY -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_GATE_RELEASE -ErrorAction SilentlyContinue
  $abandonedReplacement = Start-Installer $abandonedWaiter
  Start-Sleep -Milliseconds 600
  $abandonedReplacement.Process.Refresh()
  if ($abandonedReplacement.Process.HasExited) {
    throw 'Replacement installer did not wait for the live install mutex owner.'
  }
  Stop-Process -Id $abandonedOwner.Process.Id -Force
  $abandonedOwnerResult = Wait-Installer $abandonedOwner 10000
  if ($abandonedOwnerResult.ExitCode -eq 0) { throw 'Force-terminated install mutex owner reported success.' }
  $abandonedReplacementResult = Wait-Installer $abandonedReplacement
  if ($abandonedReplacementResult.ExitCode -ne 0) {
    throw "Replacement installer failed after abandoned mutex recovery: $($abandonedReplacementResult.Output)"
  }
  if (Test-Path -LiteralPath $abandonedOverlap) {
    throw 'Replacement npm work overlapped an old npm descendant after mutex abandonment.'
  }
  if (Get-Process -Id $abandonedChildPid -ErrorAction SilentlyContinue) {
    throw 'Abandoned installer recovery finished while the old npm descendant was still alive.'
  }
  Assert-PublishedRuntime $abandonedWaiter
  Assert-NoTransactionResidue $abandonedWaiter
  Remove-Item Env:AI_USAGE_INSTALL_TEST_OVERLAP_MUTEX -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_OVERLAP_MARKER -ErrorAction SilentlyContinue

  # Kill the complete installer after fake npm has published the new package but
  # before it returns. The Job Object must kill the child, and a rerun must repair
  # forward from the pending-aware generator without restoring stale closing state.
  $killed = New-Scenario 'strong-kill-recovery'
  Set-ScenarioEnvironment $killed
  Set-FakePackage $killed 'codeburn' '0.9.19'
  Set-FakePackage $killed 'ccusage' '20.0.14'
  [void](Seed-OldRuntime $killed)
  $env:AI_USAGE_INSTALL_TEST_GATE_SPEC = 'ccusage@20.0.20'
  $env:AI_USAGE_INSTALL_TEST_GATE_READY = $killed.GateReady
  $env:AI_USAGE_INSTALL_TEST_GATE_RELEASE = $killed.GateRelease
  $killedInvocation = Start-Installer $killed
  $killDeadline = [DateTime]::UtcNow.AddSeconds(30)
  while (-not (Test-Path -LiteralPath $killed.GateReady) -and [DateTime]::UtcNow -lt $killDeadline) {
    if ($killedInvocation.Process.HasExited) { break }
    Start-Sleep -Milliseconds 25
  }
  if (-not (Test-Path -LiteralPath $killed.GateReady)) { throw 'Strong-kill installer did not reach the npm gate.' }
  $npmChildPid = [int]([IO.File]::ReadAllText($killed.GateReady).Trim())
  if ((Get-FakePackageVersion $killed 'ccusage') -ne '20.0.20') {
    throw 'Strong-kill test did not observe the upgraded package before termination.'
  }
  Stop-Process -Id $killedInvocation.Process.Id -Force
  $killedResult = Wait-Installer $killedInvocation 10000
  if ($killedResult.ExitCode -eq 0) { throw 'Force-terminated installer unexpectedly reported success.' }
  $childDeadline = [DateTime]::UtcNow.AddSeconds(10)
  while ((Get-Process -Id $npmChildPid -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $childDeadline) {
    Start-Sleep -Milliseconds 25
  }
  if (Get-Process -Id $npmChildPid -ErrorAction SilentlyContinue) {
    throw 'Force-terminating the installer did not kill its npm child process.'
  }
  $killedPending = Join-Path $killed.Destination '.install-pending'
  if (-not (Test-Path -LiteralPath $killedPending)) { throw 'Strong-kill recovery marker was not retained.' }
  $pendingMatch = [regex]::Match([IO.File]::ReadAllText($killedPending), 'transaction=([0-9a-fA-F]{32})')
  if (-not $pendingMatch.Success) { throw 'Strong-kill recovery marker did not identify its transaction.' }
  if (-not @(Get-ChildItem -LiteralPath $killed.LocalAppData -Directory -Filter '.ClaudeUsage-install-*').Count) {
    throw 'Strong-kill test did not leave the interrupted transaction for recovery.'
  }
  $killedRunState = Join-Path (Join-Path $killed.Temp 'ClaudeUsage') 'report-run.state'
  if (-not (Test-Path -LiteralPath $killedRunState) -or [IO.File]::ReadAllText($killedRunState).Trim() -ne 'closing') {
    throw 'Strong-kill test did not leave the expected closing state.'
  }
  $interruptedId = $pendingMatch.Groups[1].Value
  $residueTmp = Join-Path $killed.Destination ('.template.html.install-' + $interruptedId + '.tmp')
  $residueBak = $residueTmp + '.bak'
  $shortcutResidue = Join-Path $killed.Desktop ('.AI Usage.lnk.install-' + $interruptedId + '.tmp')
  Write-Ascii $residueTmp 'interrupted temporary'
  Write-Ascii $residueBak 'interrupted backup'
  Write-Ascii $shortcutResidue 'interrupted shortcut'
  $ownerlessShell = Join-Path $killed.LocalAppData ('.ClaudeUsage-install-' + [guid]::NewGuid().ToString('N'))
  $invalidOwnerShell = Join-Path $killed.LocalAppData ('.ClaudeUsage-install-' + [guid]::NewGuid().ToString('N'))
  $nonemptyOwnerlessShell = Join-Path $killed.LocalAppData ('.ClaudeUsage-install-' + [guid]::NewGuid().ToString('N'))
  $emptyInterruptedShell = Join-Path $killed.LocalAppData ('.ClaudeUsage-install-' + [guid]::NewGuid().ToString('N'))
  $partialBootstrapShell = Join-Path $killed.LocalAppData ('.ClaudeUsage-install-init-' + [guid]::NewGuid().ToString('N'))
  foreach ($shell in @($ownerlessShell, $invalidOwnerShell, $nonemptyOwnerlessShell)) {
    New-Item -ItemType Directory -Force -Path (Join-Path $shell 'runtime'), (Join-Path $shell 'rollback') | Out-Null
  }
  Write-Ascii (Join-Path $invalidOwnerShell '.owner') 'partial owner record'
  Write-Ascii (Join-Path $nonemptyOwnerlessShell 'runtime\unknown.txt') 'preserve unknown residue'
  [void][IO.Directory]::CreateDirectory($emptyInterruptedShell)
  [void][IO.Directory]::CreateDirectory($partialBootstrapShell)
  Write-Ascii (Join-Path $partialBootstrapShell '.owner') 'partial owner record'
  $oldResidueTime = [DateTime]::UtcNow.AddHours(-2)
  [IO.Directory]::SetLastWriteTimeUtc($emptyInterruptedShell, $oldResidueTime)
  [IO.File]::SetLastWriteTimeUtc((Join-Path $partialBootstrapShell '.owner'), $oldResidueTime)
  [IO.Directory]::SetLastWriteTimeUtc($partialBootstrapShell, $oldResidueTime)

  Remove-Item Env:AI_USAGE_INSTALL_TEST_GATE_SPEC -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_GATE_READY -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_GATE_RELEASE -ErrorAction SilentlyContinue
  $recoveryResult = Wait-Installer (Start-Installer $killed)
  if ($recoveryResult.ExitCode -ne 0) { throw "Strong-kill recovery rerun failed: $($recoveryResult.Output)" }
  Assert-PublishedRuntime $killed
  if ((Get-FakePackageVersion $killed 'codeburn') -ne '0.9.19' -or
      (Get-FakePackageVersion $killed 'ccusage') -ne '20.0.20') {
    throw 'Strong-kill recovery did not converge on the pinned dependency versions.'
  }
  if (Test-Path -LiteralPath $killedPending) { throw 'Strong-kill recovery left its pending marker behind.' }
  if (-not (Test-Path -LiteralPath $ownerlessShell) -or -not (Test-Path -LiteralPath $invalidOwnerShell)) {
    throw 'Strong-kill recovery deleted a transaction without complete owner evidence.'
  }
  if (-not (Test-Path -LiteralPath $nonemptyOwnerlessShell)) {
    throw 'Strong-kill recovery removed an ownerless transaction containing unknown data.'
  }
  if ((Test-Path -LiteralPath $emptyInterruptedShell) -or (Test-Path -LiteralPath $partialBootstrapShell)) {
    throw 'Strong-kill recovery retained an aged incomplete transaction initialization shell.'
  }
  foreach ($unknownShell in @($ownerlessShell, $invalidOwnerShell, $nonemptyOwnerlessShell)) {
    [IO.Directory]::Delete($unknownShell, $true)
  }
  Assert-NoTransactionResidue $killed

  $concurrent = New-Scenario 'concurrent-installers'
  Set-ScenarioEnvironment $concurrent
  Set-FakePackage $concurrent 'codeburn' '0.9.19'
  Set-FakePackage $concurrent 'ccusage' '20.0.14'
  [void](Seed-OldRuntime $concurrent)
  $env:AI_USAGE_INSTALL_TEST_GATE_SPEC = 'ccusage@20.0.20'
  $env:AI_USAGE_INSTALL_TEST_GATE_READY = $concurrent.GateReady
  $env:AI_USAGE_INSTALL_TEST_GATE_RELEASE = $concurrent.GateRelease
  $installerA = Start-Installer $concurrent
  $concurrentDeadline = [DateTime]::UtcNow.AddSeconds(30)
  while (-not (Test-Path -LiteralPath $concurrent.GateReady) -and [DateTime]::UtcNow -lt $concurrentDeadline) {
    if ($installerA.Process.HasExited) { break }
    Start-Sleep -Milliseconds 25
  }
  if (-not (Test-Path -LiteralPath $concurrent.GateReady)) {
    throw 'First concurrent installer did not reach the npm gate.'
  }

  Remove-Item Env:AI_USAGE_INSTALL_TEST_GATE_SPEC -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_GATE_READY -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_GATE_RELEASE -ErrorAction SilentlyContinue
  $probeRoot = Join-Path $concurrent.Root 'relative-probe'
  $probePath = Join-Path $probeRoot 'Generate-ClaudeReport.ps1'
  $probeReady = Join-Path $probeRoot 'probe.ready'
  $probeRelease = Join-Path $probeRoot 'probe.release'
  $relativeProbe = @'
$ErrorActionPreference = 'Stop'
[IO.File]::WriteAllText($env:AI_USAGE_INSTALL_TEST_OLD_RUN_READY, [string]$PID, [Text.Encoding]::ASCII)
$deadline = [DateTime]::UtcNow.AddSeconds(30)
while (-not (Test-Path -LiteralPath $env:AI_USAGE_INSTALL_TEST_OLD_RUN_RELEASE)) {
  if ([DateTime]::UtcNow -ge $deadline) { exit 47 }
  Start-Sleep -Milliseconds 20
}
'@
  Write-Ascii $probePath $relativeProbe
  $env:AI_USAGE_INSTALL_TEST_OLD_RUN_READY = $probeReady
  $env:AI_USAGE_INSTALL_TEST_OLD_RUN_RELEASE = $probeRelease
  $probeStart = New-Object Diagnostics.ProcessStartInfo
  $probeStart.FileName = 'powershell.exe'
  $probeStart.Arguments = '-NoProfile -ExecutionPolicy Bypass -File ".\Generate-ClaudeReport.ps1"'
  $probeStart.WorkingDirectory = $probeRoot
  $probeStart.UseShellExecute = $false
  $probeStart.CreateNoWindow = $true
  $relativeProbeProcess = New-Object Diagnostics.Process
  $relativeProbeProcess.StartInfo = $probeStart
  if (-not $relativeProbeProcess.Start()) { throw 'Could not start the relative-path migration probe.' }
  $activeProcesses.Add($relativeProbeProcess)
  while (-not (Test-Path -LiteralPath $probeReady) -and [DateTime]::UtcNow -lt $concurrentDeadline) {
    Start-Sleep -Milliseconds 20
  }
  if (-not (Test-Path -LiteralPath $probeReady)) { throw 'Relative-path migration probe did not start.' }

  $installerB = Start-Installer $concurrent
  $installerBTransaction = $null
  $installerBOwnerText = $null
  $ownerDeadline = [DateTime]::UtcNow.AddSeconds(30)
  while (-not $installerBTransaction -and [DateTime]::UtcNow -lt $ownerDeadline) {
    $installerBTransaction = Find-TransactionRootForPid $concurrent $installerB.Process.Id
    Start-Sleep -Milliseconds 20
  }
  if (-not $installerBTransaction) { throw 'Second concurrent installer did not publish its owner-tagged transaction.' }
  $installerBOwnerText = [IO.File]::ReadAllText((Join-Path $installerBTransaction '.owner'))
  $installerBOwnerMatch = [regex]::Match(
    $installerBOwnerText,
    '^pid=(\d+)\r?\nstartedUtcTicks=(\d+)\r?\n?$'
  )
  if (-not $installerBOwnerMatch.Success -or
      [int]$installerBOwnerMatch.Groups[1].Value -ne $installerB.Process.Id -or
      $installerBOwnerMatch.Groups[2].Value -cne [string]$installerB.Process.StartTime.ToUniversalTime().Ticks) {
    throw 'Second concurrent installer published an invalid owner identity.'
  }

  Write-Ascii $concurrent.GateRelease 'release'
  $installerAResult = Wait-Installer $installerA
  if ($installerAResult.ExitCode -ne 0) { throw "First concurrent installer failed: $($installerAResult.Output)" }
  $secondPending = Join-Path $concurrent.Destination '.install-pending'
  $secondDeadline = [DateTime]::UtcNow.AddSeconds(30)
  while (-not (Test-Path -LiteralPath $secondPending) -and [DateTime]::UtcNow -lt $secondDeadline) {
    if ($installerB.Process.HasExited) { break }
    Start-Sleep -Milliseconds 20
  }
  Start-Sleep -Milliseconds 300
  $installerB.Process.Refresh()
  if ($installerB.Process.HasExited -or -not (Test-Path -LiteralPath $secondPending)) {
    $earlySecond = Wait-Installer $installerB
    throw "Second concurrent installer did not wait for the relative-path migration probe: $($earlySecond.Output)"
  }
  if (-not (Test-Path -LiteralPath $installerBTransaction) -or
      [IO.File]::ReadAllText((Join-Path $installerBTransaction '.owner')) -cne $installerBOwnerText) {
    throw 'Committed installer cleanup changed or deleted the live second installer transaction.'
  }

  Write-Ascii $probeRelease 'release'
  if (-not $relativeProbeProcess.WaitForExit(10000)) { throw 'Relative-path migration probe did not exit.' }
  $installerBResult = Wait-Installer $installerB
  Remove-Item Env:AI_USAGE_INSTALL_TEST_OLD_RUN_READY -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_OLD_RUN_RELEASE -ErrorAction SilentlyContinue
  if ($installerBResult.ExitCode -ne 0) { throw "Second concurrent installer failed: $($installerBResult.Output)" }
  Assert-PublishedRuntime $concurrent
  Assert-NoTransactionResidue $concurrent

  Invoke-RollbackScenario 'rollback' $false
  Invoke-RollbackScenario 'recovery-rollback' $true

  $unrelatedNpm = New-Scenario 'unrelated-npm-publish-rollback'
  Set-ScenarioEnvironment $unrelatedNpm
  Set-FakePackage $unrelatedNpm 'codeburn' '0.9.19'
  Set-FakePackage $unrelatedNpm 'ccusage' '20.0.20'
  $unrelatedNpmHashes = Seed-OldRuntime $unrelatedNpm
  $unrelatedNpmScript = Join-Path $unrelatedNpm.Root 'unrelated\npm-cli.ps1'
  $unrelatedNpmReady = Join-Path $unrelatedNpm.Root 'unrelated.ready'
  $unrelatedNpmRelease = Join-Path $unrelatedNpm.Root 'unrelated.release'
  Write-Ascii $unrelatedNpmScript @'
param([string]$ReadyPath, [string]$ReleasePath)
[IO.File]::WriteAllText($ReadyPath, 'ready', [Text.Encoding]::ASCII)
while (-not (Test-Path -LiteralPath $ReleasePath)) { Start-Sleep -Milliseconds 20 }
'@
  $unrelatedInfo = New-Object Diagnostics.ProcessStartInfo
  $unrelatedInfo.FileName = 'powershell.exe'
  $unrelatedInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $unrelatedNpmScript +
    '" -ReadyPath "' + $unrelatedNpmReady + '" -ReleasePath "' + $unrelatedNpmRelease + '"'
  $unrelatedInfo.UseShellExecute = $false
  $unrelatedInfo.CreateNoWindow = $true
  $unrelatedProcess = New-Object Diagnostics.Process
  $unrelatedProcess.StartInfo = $unrelatedInfo
  if (-not $unrelatedProcess.Start()) { throw 'Could not start the unrelated npm process probe.' }
  $activeProcesses.Add($unrelatedProcess)
  $unrelatedDeadline = [DateTime]::UtcNow.AddSeconds(10)
  while (-not (Test-Path -LiteralPath $unrelatedNpmReady) -and [DateTime]::UtcNow -lt $unrelatedDeadline) {
    Start-Sleep -Milliseconds 20
  }
  if (-not (Test-Path -LiteralPath $unrelatedNpmReady)) { throw 'The unrelated npm process probe did not become ready.' }

  $publishLock = [IO.File]::Open(
    (Join-Path $unrelatedNpm.Destination 'template.html'),
    [IO.FileMode]::Open,
    [IO.FileAccess]::Read,
    [IO.FileShare]::Read
  )
  try {
    $unrelatedResult = Wait-Installer (Start-Installer $unrelatedNpm) 15000
    if ($unrelatedResult.ExitCode -eq 0 -or $unrelatedResult.Output -notmatch 'was rolled back') {
      throw 'A publish failure beside an unrelated npm process did not complete rollback.'
    }
    $unrelatedProcess.Refresh()
    if ($unrelatedProcess.HasExited) {
      throw 'The installer treated an unrelated npm-like process as transaction-owned cleanup.'
    }
  } finally {
    $publishLock.Dispose()
    Write-Ascii $unrelatedNpmRelease 'release'
    [void]$unrelatedProcess.WaitForExit(10000)
  }
  Assert-OldRuntime $unrelatedNpm $unrelatedNpmHashes
  if (Test-Path -LiteralPath (Join-Path $unrelatedNpm.Destination '.install-pending')) {
    throw 'Unrelated npm rollback left a new pending marker behind.'
  }
  Assert-NoTransactionResidue $unrelatedNpm

  $shortcutRollback = New-Scenario 'shortcut-rollback'
  Set-ScenarioEnvironment $shortcutRollback
  Set-FakePackage $shortcutRollback 'codeburn' '0.9.19'
  Set-FakePackage $shortcutRollback 'ccusage' '20.0.14'
  $shortcutRollbackHashes = Seed-OldRuntime $shortcutRollback
  $rollbackIcon = Join-Path $shortcutRollback.Destination 'icon-0123abcd.ico'
  Write-Ascii $rollbackIcon 'rollback icon'
  $rolledBackNewIcon = Join-Path $shortcutRollback.Destination ("icon-$expectedIconHash.ico")
  Write-Ascii $rolledBackNewIcon 'preexisting target-hash sentinel'
  $rolledBackNewIconHash = (Get-FileHash -LiteralPath $rolledBackNewIcon -Algorithm SHA256).Hash
  $rollbackShortcutPath = Join-Path $shortcutRollback.Desktop 'AI Usage.lnk'
  $rollbackShortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($rollbackShortcutPath)
  $rollbackShortcut.TargetPath = Join-Path $env:SystemRoot 'System32\notepad.exe'
  $rollbackShortcut.Arguments = 'old arguments'
  $rollbackShortcut.WorkingDirectory = $shortcutRollback.Root
  $rollbackShortcut.IconLocation = "$rollbackIcon,0"
  $rollbackShortcut.Save()
  $rollbackShortcutHash = (Get-FileHash -LiteralPath $rollbackShortcutPath -Algorithm SHA256).Hash
  $env:AI_USAGE_INSTALL_TEST_VERSION_FAULT_PACKAGE = 'ccusage'
  $env:AI_USAGE_INSTALL_TEST_VERSION_FAULT_AT = '3'
  $shortcutRollbackResult = Wait-Installer (Start-Installer $shortcutRollback)
  Remove-Item Env:AI_USAGE_INSTALL_TEST_VERSION_FAULT_PACKAGE -ErrorAction SilentlyContinue
  Remove-Item Env:AI_USAGE_INSTALL_TEST_VERSION_FAULT_AT -ErrorAction SilentlyContinue
  if ($shortcutRollbackResult.ExitCode -eq 0 -or $shortcutRollbackResult.Output -notmatch 'was rolled back') {
    throw 'The post-shortcut verification fault did not trigger a completed rollback.'
  }
  Assert-OldRuntime $shortcutRollback $shortcutRollbackHashes
  if ((Get-FakePackageVersion $shortcutRollback 'ccusage') -ne '20.0.14') {
    throw 'Post-shortcut rollback did not restore the previous ccusage version.'
  }
  if ((Get-FileHash -LiteralPath $rollbackShortcutPath -Algorithm SHA256).Hash -ne $rollbackShortcutHash) {
    throw 'Post-shortcut rollback did not restore the original shortcut.'
  }
  if (-not (Test-Path -LiteralPath $rollbackIcon)) { throw 'Post-shortcut rollback removed the original icon.' }
  if (-not (Test-Path -LiteralPath $rolledBackNewIcon) -or
      (Get-FileHash -LiteralPath $rolledBackNewIcon -Algorithm SHA256).Hash -ne $rolledBackNewIconHash) {
    throw 'Post-shortcut rollback did not restore the preexisting target-hash icon.'
  }
  if (Test-Path -LiteralPath (Join-Path $shortcutRollback.Destination '.install-pending')) {
    throw 'Post-shortcut rollback left a new pending marker behind.'
  }
  Assert-NoTransactionResidue $shortcutRollback

  $corruptRepair = New-Scenario 'corrupt-manifest-repair'
  Set-ScenarioEnvironment $corruptRepair
  Set-FakePackage $corruptRepair 'codeburn' '0.9.19'
  Set-FakePackage $corruptRepair 'ccusage' '0.0.0'
  Write-Ascii (Join-Path (Join-Path $corruptRepair.NpmRoot 'ccusage') 'package.json') '{broken'
  [void](Seed-OldRuntime $corruptRepair)
  $corruptRepairResult = Wait-Installer (Start-Installer $corruptRepair)
  if ($corruptRepairResult.ExitCode -ne 0) {
    throw "Installer did not repair a corrupt npm manifest: $($corruptRepairResult.Output)"
  }
  if ((Get-FakePackageVersion $corruptRepair 'ccusage') -ne '20.0.20') {
    throw 'Corrupt npm manifest repair did not install the pinned ccusage version.'
  }
  Assert-PublishedRuntime $corruptRepair
  Assert-NoTransactionResidue $corruptRepair

  $percentPath = New-Scenario 'percent-command-path' $true
  Set-ScenarioEnvironment $percentPath
  Set-FakePackage $percentPath 'codeburn' '0.9.19'
  Set-FakePackage $percentPath 'ccusage' '20.0.14'
  [void](Seed-OldRuntime $percentPath)
  $expandedBin = Join-Path $percentPath.Root 'npm\expanded-path-must-not-be-used\bin'
  if (Test-Path -LiteralPath $expandedBin) { throw 'Percent-path test unexpectedly created the expanded token directory.' }
  $percentResult = Wait-Installer (Start-Installer $percentPath)
  if ($percentResult.ExitCode -ne 0) { throw "Literal percent command path failed: $($percentResult.Output)" }
  if ((Get-FakePackageVersion $percentPath 'codeburn') -ne '0.9.19' -or
      (Get-FakePackageVersion $percentPath 'ccusage') -ne '20.0.20') {
    throw 'Literal percent command path did not complete the pinned dependency transition.'
  }
  Assert-PublishedRuntime $percentPath
  Assert-NoTransactionResidue $percentPath

  $stderrFlood = New-Scenario 'stderr-capture'
  Set-ScenarioEnvironment $stderrFlood
  Set-FakePackage $stderrFlood 'codeburn' '0.9.19'
  Set-FakePackage $stderrFlood 'ccusage' '20.0.20'
  [void](Seed-OldRuntime $stderrFlood)
  $env:AI_USAGE_INSTALL_TEST_VERSION_STDERR_PACKAGE = 'codeburn'
  $stderrResult = Wait-Installer (Start-Installer $stderrFlood)
  Remove-Item Env:AI_USAGE_INSTALL_TEST_VERSION_STDERR_PACKAGE -ErrorAction SilentlyContinue
  if ($stderrResult.ExitCode -ne 0) { throw "Large stderr capture failed: $($stderrResult.Output)" }
  Assert-PublishedRuntime $stderrFlood
  Assert-NoTransactionResidue $stderrFlood

  Write-Output 'Installer.Integration.Tests.ps1: PASS'
} finally {
  foreach ($process in $activeProcesses) {
    if ($process -and -not $process.HasExited) {
      try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
  }
  foreach ($name in $environmentNames) {
    if ($null -eq $originalEnvironment[$name]) {
      Remove-Item ("Env:$name") -ErrorAction SilentlyContinue
    } else {
      Set-Item ("Env:$name") $originalEnvironment[$name]
    }
  }
  try {
    $resolved = [IO.Path]::GetFullPath($sandbox)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $env:AI_USAGE_KEEP_TEST_SANDBOX -and
        $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved).StartsWith('ai-usage-installer-test-', [StringComparison]::Ordinal)) {
      if (Test-Path -LiteralPath $resolved) { [IO.Directory]::Delete($resolved, $true) }
    }
  } catch {}
}
