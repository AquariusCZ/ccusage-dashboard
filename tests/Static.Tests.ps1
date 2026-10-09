$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

foreach ($relative in @(
  'src\Generate-ClaudeReport.ps1', 'src\ReportData.psm1', 'tests\New-DemoSnapshot.ps1',
  'tests\Generator.Integration.Tests.ps1', 'tests\InstallJob.Tests.ps1',
  'tests\Installer.Integration.Tests.ps1', 'tests\Uninstaller.Integration.Tests.ps1',
  'install.ps1', 'uninstall.ps1'
)) {
  $path = Join-Path $root $relative
  $tokens = $null
  $errors = $null
  [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  if ($errors.Count) { throw "$relative has PowerShell parse errors: $($errors[0].Message)" }
}

# Windows PowerShell reads a BOM-less script in the system ANSI code page, so a
# non-ASCII literal in a .ps1 becomes mojibake before it can reach a snapshot or
# match a file on disk. All visible copy lives in template.html, which is served as
# UTF-8 HTML; a name that must stay non-ASCII is built from its code points.
foreach ($relative in @(
  'src\Generate-ClaudeReport.ps1', 'src\ReportData.psm1', 'src\codex-rate-limits.mjs',
  'tests\New-DemoSnapshot.ps1', 'tests\ReportData.Tests.ps1', 'tests\Static.Tests.ps1', 'tests\Verify-Snapshot.ps1',
  'tests\Generator.Integration.Tests.ps1', 'tests\InstallJob.Tests.ps1', 'tests\Installer.Integration.Tests.ps1',
  'tests\Uninstaller.Integration.Tests.ps1',
  'install.ps1', 'uninstall.ps1'
)) {
  $bytes = [IO.File]::ReadAllBytes((Join-Path $root $relative))
  if (@($bytes | Where-Object { $_ -gt 127 }).Count) { throw "$relative contains non-ASCII bytes; build the value from code points instead" }
}

# The legacy Chinese shortcut both scripts clean up is exactly that case, and it is
# the one name a regression would silently strand on the desktop.
$legacyShortcutLiteral = "0x7528, 0x91CF, 0x4EEA, 0x8868, 0x76D8"
foreach ($relative in @('install.ps1', 'uninstall.ps1')) {
  $text = [IO.File]::ReadAllText((Join-Path $root $relative))
  if (-not $text.Contains($legacyShortcutLiteral)) { throw "$relative no longer removes the legacy Chinese desktop shortcut" }
}

$template = [IO.File]::ReadAllText((Join-Path $root 'src\template.html'))
$generator = [IO.File]::ReadAllText((Join-Path $root 'src\Generate-ClaudeReport.ps1'))
$installer = [IO.File]::ReadAllText((Join-Path $root 'install.ps1'))
$uninstaller = [IO.File]::ReadAllText((Join-Path $root 'uninstall.ps1'))
$installBatch = [IO.File]::ReadAllText((Join-Path $root 'install.bat'))
$uninstallBatch = [IO.File]::ReadAllText((Join-Path $root 'uninstall.bat'))
foreach ($batch in @($installBatch, $uninstallBatch)) {
  $clearErrorLevelIndex = $batch.IndexOf('set "ERRORLEVEL="')
  $invokeIndex = $batch.IndexOf('powershell -NoProfile')
  if (-not $batch.Contains('setlocal DisableDelayedExpansion') -or
      $clearErrorLevelIndex -lt 0 -or $invokeIndex -le $clearErrorLevelIndex -or
      $batch -notmatch 'set "AI_USAGE_EXIT_CODE=%errorlevel%"' -or
      $batch -notmatch 'if not "%AI_USAGE_EXIT_CODE%"=="0" pause' -or
      $batch -notmatch 'exit /b %AI_USAGE_EXIT_CODE%') {
    throw 'A double-click batch launcher can hide or replace a PowerShell failure exit code.'
  }
}

$batchSandbox = Join-Path ([IO.Path]::GetTempPath()) ('ai-usage-batch-test-' + [guid]::NewGuid().ToString('N'))
$previousErrorLevel = [Environment]::GetEnvironmentVariable('ERRORLEVEL', [EnvironmentVariableTarget]::Process)
$previousBatchExit = [Environment]::GetEnvironmentVariable('AI_USAGE_BATCH_TEST_EXIT', [EnvironmentVariableTarget]::Process)
try {
  New-Item -ItemType Directory -Path $batchSandbox | Out-Null
  foreach ($name in @('install', 'uninstall')) {
    $batchPath = Join-Path $batchSandbox ($name + '.bat')
    [IO.File]::Copy((Join-Path $root ($name + '.bat')), $batchPath)
    [IO.File]::WriteAllText(
      (Join-Path $batchSandbox ($name + '.ps1')),
      'exit [int]$env:AI_USAGE_BATCH_TEST_EXIT',
      [Text.Encoding]::ASCII
    )
    foreach ($case in @(
      [pscustomobject]@{ Parent = '0'; Script = '37'; Expected = 37 },
      [pscustomobject]@{ Parent = '37'; Script = '0'; Expected = 0 }
    )) {
      [Environment]::SetEnvironmentVariable('ERRORLEVEL', $case.Parent, [EnvironmentVariableTarget]::Process)
      [Environment]::SetEnvironmentVariable('AI_USAGE_BATCH_TEST_EXIT', $case.Script, [EnvironmentVariableTarget]::Process)
      & $env:ComSpec /d /q /c ('call "' + $batchPath + '" < NUL') | Out-Null
      if ($LASTEXITCODE -ne $case.Expected) {
        throw "$name.bat returned $LASTEXITCODE instead of $($case.Expected) with inherited ERRORLEVEL=$($case.Parent)."
      }
    }
  }
} finally {
  [Environment]::SetEnvironmentVariable('ERRORLEVEL', $previousErrorLevel, [EnvironmentVariableTarget]::Process)
  [Environment]::SetEnvironmentVariable('AI_USAGE_BATCH_TEST_EXIT', $previousBatchExit, [EnvironmentVariableTarget]::Process)
  try {
    $resolvedBatchSandbox = [IO.Path]::GetFullPath($batchSandbox)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($resolvedBatchSandbox.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedBatchSandbox).StartsWith('ai-usage-batch-test-', [StringComparison]::Ordinal)) {
      if (Test-Path -LiteralPath $resolvedBatchSandbox) { [IO.Directory]::Delete($resolvedBatchSandbox, $true) }
    }
  } catch {}
}
if (-not $installer.Contains("'ReportData.psm1'")) { throw 'The installer does not publish the reconciliation module.' }
if (-not $uninstaller.Contains('$managedRelativeFiles = @(Get-ChildItem -LiteralPath $repositorySourceRoot -File -Recurse') -or
    -not $uninstaller.Contains('Remove-ManagedPath (Join-Path $dest $relative)')) {
  throw 'The repository uninstaller does not derive managed mirrors from the canonical src inventory.'
}
if (-not $template.Contains('id="modelDonut"')) { throw 'The model composition chart is missing.' }
foreach ($marker in @('id="trendCap"', 'id="activityCap"', 'id="modelCap"', 'quota-src', 'quota-offline-note')) {
  if ($template.Contains($marker)) { throw "Implementation copy leaked into the dashboard: $marker" }
}
if (-not $template.Contains('function cost(p) { var o = overview(p); return n(o.cost != null ? o.cost : o.netCost); }')) {
  throw 'The UI is not using gross API reference cost as its primary total.'
}
if ($template.Contains('currency: "USD"')) { throw 'The UI still hard-codes USD formatting.' }
if (-not $template.Contains('function currencyInfo()')) { throw 'The UI is not reading the snapshot currency contract.' }
if (-not $template.Contains('if (runId === lastRunId && revision <= lastRevision) return;')) { throw 'The UI does not deduplicate progressive snapshots.' }
if (-not $template.Contains('data.complete === false')) { throw 'The UI does not continue polling an incomplete snapshot.' }
if (-not $template.Contains('window.__fail__ = function ()')) { throw 'The UI has no terminal startup-failure handler.' }
if (-not $template.Contains('failure.js?t=') -or
    -not $template.Contains('String(failure.runId || "") !== String(data.runId || "")') -or
    -not $template.Contains('failure.reason !== "initial_generation_failed"') -or
    -not $template.Contains('typeof failure.generatedAt !== "string"') -or
    -not $template.Contains('typeof failure.runId !== "string"') -or
    -not $generator.Contains("`$OutFailure = Join-Path `$OutDir 'failure.js'") -or
    -not $generator.Contains("'failure.js.tmp', 'failure.js.bak'") -or
    -not $generator.Contains('function Write-TerminalFailureSignal') -or
    -not $generator.Contains("Write-TerminalFailureSignal 'initial_generation_failed'") -or
    -not $generator.Contains("Write-TerminalFailureSignal 'partial_generation_failed'")) {
  throw 'The independent runId-bound failure sidecar protocol is incomplete.'
}
if (-not $generator.Contains('function Select-TypedOutputRecord') -or
    $generator.Contains('function Select-OutputRecord')) {
  throw 'The generator is not enforcing typed render-only DTO fields.'
}
if (-not $generator.Contains("`$RequiredCCUsageVersion = '20.0.20'")) { throw 'The generator does not pin the audited ccusage version.' }
if (-not $generator.Contains("Start-OptionalJsonCommand `$CCUsage @('blocks', '--json', '--offline')")) { throw 'ccusage blocks is not isolated from public pricing refreshes or launch failures.' }
$staleSnapshotDeleteIndex = $generator.IndexOf('foreach ($previousOutput in @($OutData, $OutFailure))')
$readLeaseIndex = $generator.IndexOf("if (-not (Touch-ReadLease)) { throw 'Could not establish the dashboard read lease.' }")
$primaryLaunchIndex = $generator.LastIndexOf('Start-Process (Get-ReportLaunchTarget $OutHtml $Period)')
if ($staleSnapshotDeleteIndex -lt 0 -or $readLeaseIndex -lt 0 -or $primaryLaunchIndex -lt 0 -or
    $staleSnapshotDeleteIndex -gt $readLeaseIndex -or $readLeaseIndex -gt $primaryLaunchIndex) {
  throw 'The generator may launch a page before stale data removal and read-lease publication succeed.'
}
if (-not $generator.Contains('while (-not $RunMutexHeld -and [DateTime]::UtcNow -lt $runMutexDeadline)') -or
    -not $generator.Contains('Test-ActiveReportReusable $Period') -or
    -not $generator.Contains('Start-Process (Get-ReportLaunchTarget $OutHtml $Period)')) {
  throw 'The generator does not jointly poll the report lock and a period-aware reusable page.'
}
if (-not $generator.Contains('ownerStartUtcTicks = $OwnerProcessStartUtcTicks') -or
    -not $generator.Contains('Test-RunOwnerIdentity $owner') -or
    -not $generator.Contains("Write-RunOwnerPhase 'failed'") -or
    -not $generator.Contains('Test-RunFailureSignaled ([string]$owner.runId)') -or
    -not $generator.Contains('[Threading.EventResetMode]::ManualReset')) {
  throw 'Page reuse is not bound to a live owner identity and a nonfailed phase.'
}
if (-not $generator.Contains('$GenerationFailed = $true') -or
    -not $generator.Contains('Test-FailedRunRetryRequested') -or
    -not $generator.Contains('$graceMilliseconds = [Math]::Min(2000, $normalGraceMilliseconds)') -or
    -not $generator.Contains('$deadline = [Math]::Min($deadline, $now + $graceMilliseconds)') -or
    -not $generator.Contains('Write-TextFileWithRetry $RetryRequestPath $ownerRunId')) {
  throw 'A runId-bound failed-page retry does not apply its bounded early close.'
}
$finalPublishIndex = $generator.IndexOf("`$GenerationStage = 'final_publish'")
$generationCatchIndex = $generator.IndexOf('  } catch {', $finalPublishIndex)
$terminalWriteIndex = $generator.IndexOf('Write-Snapshot $true', $finalPublishIndex)
if ($finalPublishIndex -lt 0 -or $generationCatchIndex -lt 0 -or
    $terminalWriteIndex -lt 0 -or $terminalWriteIndex -gt $generationCatchIndex) {
  throw 'The final snapshot publication is outside the generation failure state machine.'
}
if (-not $generator.Contains('QueryInformationJobObject(') -or
    -not $generator.Contains('return info.ActiveProcesses == 0;') -or
    -not $generator.Contains('emptyObservations >= 2') -or
    -not $generator.Contains('const uint DISPOSE_DRAIN_TIMEOUT_MILLISECONDS = 10000;') -or
    -not $generator.Contains('Wait(DISPOSE_DRAIN_TIMEOUT_MILLISECONDS) != WAIT_OBJECT_0') -or
    $generator.Contains('if (Wait(INFINITE) != WAIT_OBJECT_0 || !HasExited)') -or
    -not $generator.Contains('Wait-AbandonedCollectorProcesses $userSid')) {
  throw 'Forced collector termination does not use a bounded complete-Job drain and conservative fallback.'
}
$collectorGuardCalls = [regex]::Matches($generator, 'Assert-CollectorCleanupVerified').Count
$startGuardIndex = $generator.IndexOf('  Assert-CollectorCleanupVerified', $generator.IndexOf('function Start-JsonCommand'))
$startInitializeIndex = $generator.IndexOf('  Initialize-CollectorJobType', $generator.IndexOf('function Start-JsonCommand'))
if (-not $generator.Contains('function Assert-CollectorCleanupVerified') -or
    $collectorGuardCalls -lt 6 -or $startGuardIndex -lt 0 -or $startInitializeIndex -lt 0 -or
    $startGuardIndex -gt $startInitializeIndex -or
    -not $generator.Contains('} catch { Assert-CollectorCleanupVerified }')) {
  throw 'An uncertain collector cleanup can be swallowed or cross a later process-launch boundary.'
}
if (-not $generator.Contains('$MaxCollectorOutputBytes = [int64](16 * 1024 * 1024)') -or
    -not $generator.Contains('Wait-ChildProcess $run 120000 $Output $MaxCollectorOutputBytes { Receive-CollectorSlice }')) {
  throw 'Collector output is not bounded to the audited 16 MiB limit while the process is running.'
}
$codexHelper = [IO.File]::ReadAllText((Join-Path $root 'src\codex-rate-limits.mjs'))
if (-not $generator.Contains('$official.Job = Start-OptionalJsonCommand $node @($CodexHelperScript, $codex) $codexQuotaOutput') -or
    -not $generator.Contains('$CodexQuotaTimeoutMilliseconds = 30000') -or
    -not $generator.Contains('function Test-CodexQuotaOutputOversized') -or
    -not $generator.Contains('try { $rootExited = $job.RootHasExited } catch { $inspectionFailed = $true }') -or
    -not $generator.Contains("if (-not `$job.HasExited -and -not (Stop-ProcessTree `$job)) {")) {
  throw 'The official Codex quota helper is not a bounded, Job-contained optional collector.'
}
if ($codexHelper -match '(?i)auth\.json|access_token|refresh_token|OPENAI_API_KEY|Authorization' -or
    -not $codexHelper.Contains('account/rateLimits/read') -or -not $codexHelper.Contains('%AI_USAGE_CODEX_COMMAND%')) {
  throw 'The Codex quota helper must ask app-server for rate limits without touching Codex credentials.'
}
if (-not $generator.Contains("`$codexQuota = [ordered]@{ ok = `$false; reason = 'official_account' }") -or
    $generator -match 'oauth:tokenCache|Local State|safeStorage|ProtectedData') {
  throw 'Quota sources must follow the login in use and never open the desktop app''s encrypted token store.'
}
$publishCandidate = [regex]::Match($generator, '(?s)function Publish-PeriodCandidate\(\[string\]\$PeriodKey\) \{(.*?)\n\}')
if (-not $publishCandidate.Success -or $publishCandidate.Groups[1].Value -match 'Publish-QuotaUpdate|Receive-CollectorSlice' -or
    -not $generator.Contains('function Publish-QuotaUpdate') -or
    -not $generator.Contains('if ($GenerationFailed -or $script:QuotaStateVersion -eq $script:PublishedQuotaVersion) { return }')) {
  throw 'A quota-only publish can run while an uncommitted period candidate is in the report set.'
}
if (-not $generator.Contains('$request.Client.MaxResponseContentBufferSize = $MaxBytes') -or
    -not $generator.Contains('[Net.Http.HttpCompletionOption]::ResponseContentRead') -or
    ([regex]::Matches($generator, '\$Handler\.AllowAutoRedirect = \$false')).Count -lt 2) {
  throw 'The non-blocking Claude quota request is not bounded and redirect-free.'
}
$blocksDeadlineIndex = $generator.IndexOf('$blocksDeadlineUtc = [DateTime]::UtcNow.AddMilliseconds($CCUsageTimeoutMilliseconds)')
$blocksStartIndex = $generator.IndexOf("`$blocksJob = Start-OptionalJsonCommand `$CCUsage @('blocks', '--json', '--offline')")
if (-not $generator.Contains('$CCUsageTimeoutMilliseconds = 120000') -or
    $blocksDeadlineIndex -lt 0 -or $blocksStartIndex -lt 0 -or $blocksDeadlineIndex -gt $blocksStartIndex -or
    -not $generator.Contains('($script:blocksDeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds') -or
    $generator.Contains('Wait-ChildProcess $blocksJob 120000')) {
  throw 'ccusage does not retain one absolute 120-second budget from process start through final collection.'
}
$collectorDispose = [regex]::Match(
  $generator,
  '(?s)public void Dispose\(\)\s*\{(.*?)\n\s*\}\s*\n\s*~CollectorProcess\(\)'
)
if (-not $collectorDispose.Success -or
    $collectorDispose.Groups[1].Value -notmatch '(?s)finally\s*\{.*CloseHandle\(jobHandle\).*CloseHandle\(processHandle\)') {
  throw 'Collector disposal does not close both native handles from a guaranteed finally block.'
}
if (-not $generator.Contains('$MaxQuotaResponseBytes = [int64](1024 * 1024)') -or
    -not $generator.Contains('[Net.Http.HttpCompletionOption]::ResponseHeadersRead') -or
    -not $generator.Contains('$Handler.AllowAutoRedirect = $false') -or
    -not $generator.Contains('$stream.ReadAsync($buffer, 0, $readSize, $cancellation.Token)')) {
  throw 'Relay quota HTTP does not enforce its redirect, timeout, and streamed byte boundaries.'
}
if (-not $generator.Contains('function Get-NpmPackageVersion') -or $generator.Contains("'--version'")) {
  throw 'A damaged npm manifest can still trigger an uncontained version command.'
}
if (-not $installer.Contains("Package = 'ccusage'; Label = 'ccusage'; Version = '20.0.20'")) { throw 'The installer ccusage pin differs from the generator.' }
if (-not $installer.Contains('function Test-IsProcessElevated') -or
    -not $installer.Contains('Run install.ps1 without administrator elevation.') -or
    -not $uninstaller.Contains('Run uninstall.ps1 without administrator elevation.')) {
  throw 'Per-user install and uninstall do not reject an elevated production token.'
}
if (-not $installer.Contains('function Get-ExistingPathEntry') -or
    -not $uninstaller.Contains('function Get-ExistingPathEntry') -or
    -not $uninstaller.Contains('if (-not (Get-ExistingPathEntry $Path)) { return }')) {
  throw 'Managed path checks can miss a dangling reparse-point directory entry.'
}
if ($installer.Contains('IsNullOrWhiteSpace($commandLine) -and [int]$process.SessionId -eq 0') -or
    $uninstaller.Contains('IsNullOrWhiteSpace($commandLine) -and [int]$process.SessionId -eq 0')) {
  throw 'A Session 0 usage process with an unreadable command line can still bypass the SID check.'
}
if (-not $installer.Contains("'codeburn.exe', 'ccusage.exe'") -or
    -not $uninstaller.Contains("'codeburn.exe', 'ccusage.exe'")) {
  throw 'Install/uninstall migration scans do not both recognize native ccusage collectors.'
}
if (-not $uninstaller.Contains('$runMutexAbandoned = $true') -or
    -not $uninstaller.Contains('$legacyRunMutexAbandoned = $true') -or
    -not $uninstaller.Contains('if ($runMutexAbandoned -or $legacyRunMutexAbandoned)')) {
  throw 'Uninstall does not drain collector descendants after an abandoned report mutex.'
}
if (-not $generator.Contains("Join-Path `$AppDir '.install-pending'")) { throw 'The generator does not guard an interrupted installation.' }
if (-not $installer.Contains('Global\AIUsage-CodeBurn-')) { throw 'The installer does not share the generator mutex.' }
if (-not $generator.Contains("'Local\AIUsage-CodeBurn'") -or -not $installer.Contains("'Local\AIUsage-CodeBurn'")) {
  throw 'The migration release does not coordinate with the legacy report mutex.'
}
if (-not $installer.Contains("Set-FileAtomically `$markerSource `$pendingPath")) { throw 'The installer does not publish its pending marker atomically.' }
$generatorPublishIndex = $installer.IndexOf("Set-FileAtomically (Join-Path `$stageRuntime `$generatorRelative)")
$pendingPublishIndex = $installer.IndexOf("Set-FileAtomically `$markerSource `$pendingPath")
$drainIndex = $installer.IndexOf('Wait-MigrationUsageProcesses $userSid')
$installLockIndex = $installer.IndexOf('$installMutex = [Threading.Mutex]::new')
$nodeProbeIndex = $installer.IndexOf('$nodeVersion = Get-ExactReleaseVersion $nodePath')
$runLockIndex = $installer.IndexOf('$runMutex = [Threading.Mutex]::new')
$legacyLockIndex = $installer.IndexOf("`$legacyRunMutex = [Threading.Mutex]::new(`$false, 'Local\AIUsage-CodeBurn')")
$npmMutationIndex = $installer.IndexOf("Invoke-Npm @('install', '-g', `$package)")
if ($generatorPublishIndex -lt 0 -or $pendingPublishIndex -lt 0 -or $drainIndex -lt 0 -or
    $installLockIndex -lt 0 -or $nodeProbeIndex -lt 0 -or $runLockIndex -lt 0 -or $legacyLockIndex -lt 0 -or $npmMutationIndex -lt 0 -or
    $installLockIndex -gt $pendingPublishIndex -or
    $installLockIndex -gt $nodeProbeIndex -or $nodeProbeIndex -gt $npmMutationIndex -or
    $pendingPublishIndex -gt $generatorPublishIndex -or $generatorPublishIndex -gt $drainIndex -or $drainIndex -gt $npmMutationIndex) {
  throw 'The installer migration order is not marker, pending-aware generator, cross-session drain, then npm.'
}
if ($drainIndex -gt $runLockIndex -or $runLockIndex -gt $legacyLockIndex -or $legacyLockIndex -gt $npmMutationIndex) {
  throw 'The installer must drain before acquiring report locks in Global then Local order.'
}
if (-not $installer.Contains('Get-CimInstance -ClassName Win32_Process') -or
    -not $installer.Contains('Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid')) {
  throw 'The installer does not drain legacy report processes across Windows Sessions by SID.'
}
if (-not $installer.Contains('PROC_THREAD_ATTRIBUTE_JOB_LIST') -or
    -not $installer.Contains('EXTENDED_STARTUPINFO_PRESENT') -or
    -not $installer.Contains('IsProcessInJob(process.hProcess, job, out inJob)')) {
  throw 'The installer does not create and verify npm inside its Job Object atomically.'
}
if (-not $generator.Contains('COLLECTOR_JOB_CSHARP_BEGIN') -or
    -not $generator.Contains('PROC_THREAD_ATTRIBUTE_JOB_LIST') -or
    -not $generator.Contains('JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE') -or
    -not $generator.Contains('IsProcessInJob(process.hProcess, job, out inJob)') -or
    -not $generator.Contains('TerminateAndWait')) {
  throw 'The generator does not create and contain collectors in kill-on-close Job Objects.'
}
if (-not $installer.Contains('RunWithOutputLimit') -or -not $installer.Contains('2> NUL')) {
  throw 'Installer command capture is not bounded and Job-contained.'
}
if (-not $installer.Contains('WaitForJobEmpty(job, 10000)') -or
    -not $installer.Contains('Wait-AbandonedInstallProcesses $UserSid')) {
  throw 'Installer failure cleanup can release transaction locks before its process tree drains.'
}
if (-not $installer.Contains('TerminateProcess(process.hProcess, 1)') -or
    -not $installer.Contains('WaitForSingleObject(process.hProcess, 10000)') -or
    -not $installer.Contains('processCreated && !membershipVerified') -or
    -not $generator.Contains('public sealed class CollectorJobCleanupException') -or
    -not $generator.Contains('Set-CollectorCleanupRequiredFromError $_') -or
    $collectorGuardCalls -lt 6) {
  throw 'A failed atomic process start can proceed without verified root and Job cleanup.'
}
if (-not $installer.Contains('public sealed class InstallJobCleanupException') -or
    -not $installer.Contains('Set-InstallProcessCleanupRequiredFromError $_') -or
    -not $installer.Contains('function Confirm-InstallProcessCleanup') -or
    ([regex]::Matches($installer, 'if \(\$script:installProcessCleanupRequired\) \{ throw \}').Count -lt 2) -or
    -not $installer.Contains('if ($script:installProcessCleanupRequired) { break }') -or
    $installer.Contains('try { Wait-AbandonedInstallProcesses $userSid }')) {
  throw 'Installer rollback cannot distinguish its own uncertain Job cleanup from an unrelated failure.'
}
if (-not $installer.Contains('$commandInterpreter, $commandLine, $PSScriptRoot, 30000, $capturePath, 1048576')) {
  throw 'Installer probe output no longer has its 1 MiB limit.'
}
if (-not $installer.Contains('Get-ExactReleaseVersion $nodePath') -or
    -not $installer.Contains("'^v?(?<version>(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))$'")) {
  throw 'The installer does not require an exact stable Node.js release version.'
}
foreach ($obsoleteJobStep in @('CREATE_SUSPENDED', 'AssignProcessToJobObject', 'ResumeThread')) {
  if ($installer.Contains($obsoleteJobStep)) { throw "The installer still uses the racy Job step $obsoleteJobStep." }
}
if ($installer.Contains("Get-ChildItem `$dest -Filter 'icon-*.ico'")) { throw 'The installer still deletes icons by a broad filename pattern.' }
if ($uninstaller -match 'Get-ChildItem\s+\$dest\s+-Filter\s+[''"]icon-\*\.ico') {
  throw 'The uninstaller still deletes icons by a broad filename pattern.'
}
if ($uninstaller.Contains('[string]$Destination') -or $uninstaller.Contains('[string]$DesktopDirectory')) {
  throw 'The production uninstaller exposes an arbitrary destructive destination.'
}
if (-not $uninstaller.Contains("'.uninstall-' + `$uninstallTransactionId + '.bak'") -or
    $uninstaller.Contains('.uninstall-backup')) {
  throw 'The uninstall gate backup is not uniquely owned by its transaction.'
}

function Get-FunctionText([string]$Path, [string]$Name) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  if ($errors.Count) { throw "Could not parse $Path while comparing $Name." }
  $definition = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
  }, $true)
  if (-not $definition) { throw "$Path does not define $Name." }
  return $definition.Extent.Text
}

foreach ($functionName in @(
  'Get-MigrationUsageProcessDisposition', 'Get-MigrationUsageProcesses', 'Wait-MigrationUsageProcesses',
  'Test-AbandonedInstallProcess', 'Get-AbandonedInstallProcesses', 'Wait-AbandonedInstallProcesses'
)) {
  $installFunction = Get-FunctionText (Join-Path $root 'install.ps1') $functionName
  $uninstallFunction = Get-FunctionText (Join-Path $root 'uninstall.ps1') $functionName
  if ($installFunction -cne $uninstallFunction) {
    throw "Installer and uninstaller disagree on $functionName."
  }
}

$authModeReader = Get-FunctionText (Join-Path $root 'src\ReportData.psm1') 'Get-CodexAuthModeFromDocument'
if ($authModeReader -match '(?i)tokens|refresh_token|access_token|id_token|OPENAI_API_KEY') {
  throw 'The Codex login-mode reader must consult auth_mode only, never a credential slot.'
}
$reportDataModule = [IO.File]::ReadAllText((Join-Path $root 'src\ReportData.psm1'))
foreach ($source in @($generator, $reportDataModule, $codexHelper)) {
  if ($source -match '(?i)Claude\\config\.json|oauth:tokenCache|safeStorage') {
    throw 'Runtime code references the Claude desktop app''s encrypted login store.'
  }
}

$uninstallLockIndex = $uninstaller.IndexOf('$installMutex = [Threading.Mutex]::new')
$uninstallMarkerIndex = $uninstaller.IndexOf("(Get-UninstallMarker 'pending')")
$uninstallGateIndex = $uninstaller.IndexOf('Publish-UninstallGate $generatorPath')
$uninstallDrainIndex = $uninstaller.IndexOf('Wait-MigrationUsageProcesses $userSid')
$uninstallRunLockIndex = $uninstaller.IndexOf('$runMutex = [Threading.Mutex]::new')
$uninstallLegacyLockIndex = $uninstaller.IndexOf("`$legacyRunMutex = [Threading.Mutex]::new(`$false, 'Local\AIUsage-CodeBurn')")
$uninstallGateRecheckIndex = $uninstaller.IndexOf('The uninstall launch gate changed while waiting for active reports.')
$uninstallDeleteIndex = $uninstaller.IndexOf("Remove-ManagedPath (Join-Path `$env:TEMP 'ClaudeUsage')")
if (@($uninstallLockIndex, $uninstallMarkerIndex, $uninstallGateIndex, $uninstallDrainIndex,
    $uninstallRunLockIndex, $uninstallLegacyLockIndex, $uninstallGateRecheckIndex,
    $uninstallDeleteIndex) | Where-Object { $_ -lt 0 }) {
  throw 'The uninstaller transaction protocol is incomplete.'
}
if ($uninstallLockIndex -gt $uninstallMarkerIndex -or $uninstallMarkerIndex -gt $uninstallGateIndex -or
    $uninstallGateIndex -gt $uninstallDrainIndex -or $uninstallDrainIndex -gt $uninstallRunLockIndex -or
    $uninstallRunLockIndex -gt $uninstallLegacyLockIndex -or
    $uninstallLegacyLockIndex -gt $uninstallGateRecheckIndex -or
    $uninstallGateRecheckIndex -gt $uninstallDeleteIndex) {
  throw 'The uninstaller order is not install lock, marker, gate, drain, Global, Local, recheck, delete.'
}
$managedDeleteIndex = $uninstaller.IndexOf("Remove-ManagedPath (Join-Path `$dest `$relative)", $uninstallDeleteIndex)
$ownedIconDeleteIndex = $uninstaller.IndexOf('Remove-ManagedPath $ownedIcon', $managedDeleteIndex)
$sourceIconDeleteIndex = $uninstaller.IndexOf('Remove-ManagedPath $sourceIcon', $ownedIconDeleteIndex)
$shortcutDeleteIndex = $uninstaller.IndexOf('  Remove-AiUsageShortcuts', $sourceIconDeleteIndex)
$pendingDeleteIndex = $uninstaller.IndexOf('Remove-ManagedPath $pendingPath', $shortcutDeleteIndex)
if ($managedDeleteIndex -lt 0 -or $ownedIconDeleteIndex -lt 0 -or $sourceIconDeleteIndex -lt 0 -or
    $shortcutDeleteIndex -lt 0 -or
    $pendingDeleteIndex -lt 0 -or $managedDeleteIndex -gt $ownedIconDeleteIndex -or
    $ownedIconDeleteIndex -gt $sourceIconDeleteIndex -or $sourceIconDeleteIndex -gt $shortcutDeleteIndex -or
    $shortcutDeleteIndex -gt $pendingDeleteIndex) {
  throw 'Repository uninstall must retain source-icon and shortcut ownership proof until hashed icon deletion succeeds.'
}

$match = [regex]::Match($template, '(?s)<script>\s*(addEventListener\("error".*)</script>\s*</body>')
if (-not $match.Success) { throw 'Could not extract the dashboard script for syntax checking.' }
$tempJs = Join-Path ([IO.Path]::GetTempPath()) ("ai-usage-static-{0}.js" -f [guid]::NewGuid().ToString('N'))
try {
  [IO.File]::WriteAllText($tempJs, $match.Groups[1].Value, (New-Object Text.UTF8Encoding($false)))
  & node --check $tempJs
  if ($LASTEXITCODE -ne 0) { throw 'Dashboard JavaScript syntax check failed.' }
  & node --check (Join-Path $root 'src\codex-rate-limits.mjs')
  if ($LASTEXITCODE -ne 0) { throw 'Codex quota helper syntax check failed.' }
} finally {
  try { if (Test-Path $tempJs) { [IO.File]::Delete($tempJs) } } catch {}
}

Write-Output 'Static.Tests.ps1: PASS'
