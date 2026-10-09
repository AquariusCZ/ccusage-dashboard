#Requires -Version 5.1
param(
  [string]$Destination,
  [string]$DesktopDirectory,
  [string]$NpmCommand,
  [switch]$NoPrompt
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host ''
Write-Host '  AI Usage - installer' -ForegroundColor Cyan
Write-Host '  ==================='
Write-Host ''

$srcDir = Join-Path $PSScriptRoot 'src'
$dest = if ([string]::IsNullOrWhiteSpace($Destination)) { Join-Path $env:LOCALAPPDATA 'ClaudeUsage' } else { [IO.Path]::GetFullPath($Destination) }
$transactionId = [guid]::NewGuid().ToString('N')
$transactionRoot = Join-Path $env:LOCALAPPDATA ('.ClaudeUsage-install-' + $transactionId)
$transactionBootstrapRoot = Join-Path $env:LOCALAPPDATA ('.ClaudeUsage-install-init-' + $transactionId)
$transactionOwnerPath = Join-Path $transactionRoot '.owner'
$stageRuntime = Join-Path $transactionRoot 'runtime'
$rollbackRuntime = Join-Path $transactionRoot 'rollback'
$pendingPath = Join-Path $dest '.install-pending'
$runStatePath = Join-Path (Join-Path $env:TEMP 'ClaudeUsage') 'report-run.state'
$installMutex = $null
$installMutexHeld = $false
$installMutexAbandoned = $false
$runMutex = $null
$runMutexHeld = $false
$runMutexAbandoned = $false
$legacyRunMutex = $null
$legacyRunMutexHeld = $false
$legacyRunMutexAbandoned = $false
$transactionCommitted = $false
$rollbackComplete = $false
$publishedFiles = @()
$originalFiles = @{}
$toolStates = @()
$shortcutPublished = $false
$iconPath = $null
$iconWasPresent = $false
$iconPublished = $false
$iconRollbackPath = Join-Path $rollbackRuntime 'managed-icon.ico'
$pendingWasPresent = $false
$pendingWritten = $false
$pendingContents = $null
$runStateWritten = $false
$npmRoot = $null
$previousManagedIconPath = $null
$installProcessDrainFailed = $false
$installProcessCleanupRequired = $false

function Set-InstallProcessCleanupRequiredFromError($ErrorRecord) {
  $exception = $ErrorRecord.Exception
  while ($exception) {
    if ($exception.GetType().FullName -eq 'AiUsage.InstallJobCleanupException') {
      $script:installProcessCleanupRequired = $true
      return
    }
    $exception = $exception.InnerException
  }
}

function Test-IsProcessElevated {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  try {
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } finally {
    $identity.Dispose()
  }
}

function Test-PathInsideRoot([string]$Path, [string]$Root) {
  try {
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd(
      [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
  } catch {
    return $false
  }
}

function Get-IsolatedInstallerTestRoot {
  if ([string]::IsNullOrWhiteSpace($Destination) -or
      [string]::IsNullOrWhiteSpace($DesktopDirectory) -or
      [string]::IsNullOrWhiteSpace($NpmCommand) -or
      [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -or
      [string]::IsNullOrWhiteSpace($env:TEMP)) { return $null }
  try {
    $localAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA)
    $scenarioRoot = [IO.Directory]::GetParent($localAppData)
    if (-not $scenarioRoot -or -not $scenarioRoot.Parent -or
        -not $scenarioRoot.Parent.Name.StartsWith('ai-usage-installer-test-[literal]-', [StringComparison]::Ordinal)) {
      return $null
    }
    foreach ($path in @($env:LOCALAPPDATA, $env:TEMP, $Destination, $DesktopDirectory, $NpmCommand)) {
      if (-not (Test-PathInsideRoot $path $scenarioRoot.FullName)) { return $null }
    }
    return $scenarioRoot.FullName
  } catch {
    return $null
  }
}

$processElevated = Test-IsProcessElevated
$isolatedInstallerTestRoot = Get-IsolatedInstallerTestRoot
if ($processElevated -and -not $isolatedInstallerTestRoot) {
  throw 'AI Usage is a per-user install. Run install.ps1 without administrator elevation.'
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
  Write-Host '  [!] Node.js 22.13.0 or newer was not found. Install a current LTS release from https://nodejs.org and run this installer again.' -ForegroundColor Yellow
  if (-not $NoPrompt) { Read-Host '  Press Enter to exit' }
  exit 1
}
$nodePath = $node.Source
if ($processElevated -and -not (Test-PathInsideRoot $nodePath $isolatedInstallerTestRoot)) {
  throw 'The isolated elevated test resolved Node.js outside its sandbox.'
}

$npmPath = $null
if (-not [string]::IsNullOrWhiteSpace($NpmCommand)) {
  $npmPath = (Resolve-Path -LiteralPath $NpmCommand).Path
} else {
  $npm = Get-Command 'npm.cmd' -ErrorAction SilentlyContinue
  if (-not $npm) { $npm = Get-Command 'npm' -ErrorAction SilentlyContinue }
  if ($npm) { $npmPath = $npm.Source }
}
if (-not $npmPath) { throw 'npm was not found on PATH.' }
if ($processElevated -and -not (Test-PathInsideRoot $npmPath $isolatedInstallerTestRoot)) {
  throw 'The isolated elevated test resolved npm outside its sandbox.'
}

function Get-ToolCommand([string]$Name) {
  $resolved = Get-Command "$Name.cmd" -ErrorAction SilentlyContinue
  if (-not $resolved) { $resolved = Get-Command $Name -ErrorAction SilentlyContinue }
  return $resolved
}

function Test-SafeCommandArguments([string[]]$Arguments) {
  foreach ($argument in $Arguments) {
    if ($argument -notmatch '^[0-9A-Za-z@._/+-]+$') { throw 'Refusing an unsafe command argument.' }
  }
}

function Invoke-WithCommandPathEnvironment([string]$CommandPath, [scriptblock]$Action) {
  $variableName = 'AI_USAGE_INSTALL_COMMAND_PATH'
  $previous = [Environment]::GetEnvironmentVariable($variableName, [EnvironmentVariableTarget]::Process)
  try {
    [Environment]::SetEnvironmentVariable(
      $variableName, [IO.Path]::GetFullPath($CommandPath), [EnvironmentVariableTarget]::Process
    )
    return & $Action
  } finally {
    [Environment]::SetEnvironmentVariable($variableName, $previous, [EnvironmentVariableTarget]::Process)
  }
}

function Invoke-CmdCapture([string]$CommandPath, [string[]]$Arguments) {
  if ($script:installProcessCleanupRequired) {
    throw 'Refusing to start a command while prior installation process cleanup is unverified.'
  }
  Test-SafeCommandArguments $Arguments
  Initialize-InstallJobType
  $captureVariable = 'AI_USAGE_INSTALL_CAPTURE_PATH'
  $previousCapture = [Environment]::GetEnvironmentVariable($captureVariable, [EnvironmentVariableTarget]::Process)
  $capturePath = Join-Path $transactionRoot ('.capture-' + [guid]::NewGuid().ToString('N') + '.stdout')
  try {
    [Environment]::SetEnvironmentVariable($captureVariable, $capturePath, [EnvironmentVariableTarget]::Process)
    return Invoke-WithCommandPathEnvironment $CommandPath {
    $commandInterpreter = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $commandBody = '"set "AI_USAGE_INSTALL_JOB=1" & "%AI_USAGE_INSTALL_COMMAND_PATH%"'
    if ($Arguments.Count) { $commandBody += ' ' + ($Arguments -join ' ') }
      $commandBody += ' 1> "%AI_USAGE_INSTALL_CAPTURE_PATH%" 2> NUL"'
      $commandLine = '"' + $commandInterpreter + '" /d /q /v:off /s /c ' + $commandBody
      $exitCode = [AiUsage.InstallJob]::RunWithOutputLimit(
        $commandInterpreter, $commandLine, $PSScriptRoot, 30000, $capturePath, 1048576
      )
      $stdout = if (Test-Path -LiteralPath $capturePath) { [IO.File]::ReadAllText($capturePath) } else { '' }
      return [pscustomobject]@{ ExitCode = $exitCode; Output = $stdout }
    }
  } catch {
    Set-InstallProcessCleanupRequiredFromError $_
    throw
  } finally {
    [Environment]::SetEnvironmentVariable($captureVariable, $previousCapture, [EnvironmentVariableTarget]::Process)
    try { if (Test-Path -LiteralPath $capturePath) { [IO.File]::Delete($capturePath) } } catch {}
  }
}

function Get-ToolVersion([string]$CommandPath) {
  try {
    $result = Invoke-CmdCapture $CommandPath @('--version')
  } catch {
    if ($script:installProcessCleanupRequired) { throw }
    return $null
  }
  if ($result.ExitCode -ne 0) { return $null }
  $raw = ([string]$result.Output).Trim()
  $match = [regex]::Match($raw, '\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?')
  if ($match.Success) { return $match.Value }
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  return $raw
}

function Get-ExactReleaseVersion([string]$CommandPath) {
  try {
    $result = Invoke-CmdCapture $CommandPath @('--version')
  } catch {
    if ($script:installProcessCleanupRequired) { throw }
    return $null
  }
  if ($result.ExitCode -ne 0) { return $null }
  $match = [regex]::Match(
    ([string]$result.Output).Trim(),
    '^v?(?<version>(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))$'
  )
  if (-not $match.Success) { return $null }
  try { return [version]$match.Groups['version'].Value } catch { return $null }
}

function Get-NpmGlobalRoot {
  $result = Invoke-CmdCapture $npmPath @('root', '-g')
  $root = ([string]$result.Output).Trim()
  if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($root)) {
    throw 'Could not resolve the active npm global package root.'
  }
  return [IO.Path]::GetFullPath($root)
}

function Get-NpmPackageVersion([string]$Root, [string]$Package) {
  $manifest = Join-Path (Join-Path $Root $Package) 'package.json'
  if (-not (Test-Path -LiteralPath $manifest)) { return $null }
  try {
    $parsed = [IO.File]::ReadAllText($manifest) | ConvertFrom-Json
    if ($parsed.name -eq $Package -and $parsed.version) { return [string]$parsed.version }
  } catch {}
  # An unreadable package is not a usable rollback baseline. Treat it as absent
  # so npm can repair it; a later transaction failure removes that broken state.
  return $null
}

function Get-RelativeRuntimePath([string]$Path) {
  return $Path.Substring($stageRuntime.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
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

function Set-FileAtomically([string]$Source, [string]$Destination) {
  Assert-NoReparsePath $Source
  Assert-NoReparsePath $Destination
  $parent = Split-Path $Destination -Parent
  if (-not (Test-Path -LiteralPath $parent)) {
    [void][IO.Directory]::CreateDirectory($parent)
  }
  Assert-NoReparsePath $parent
  $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Destination) + '.install-' + $transactionId + '.tmp')
  $replaceBackup = $temporary + '.bak'
  try {
    [IO.File]::Copy($Source, $temporary, $true)
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
      try {
        Assert-NoReparsePath $Destination
        if (Test-Path -LiteralPath $Destination) {
          if (Test-Path -LiteralPath $replaceBackup) { [IO.File]::Delete($replaceBackup) }
          [IO.File]::Replace($temporary, $Destination, $replaceBackup)
          try { if (Test-Path -LiteralPath $replaceBackup) { [IO.File]::Delete($replaceBackup) } } catch {}
        } else {
          [IO.File]::Move($temporary, $Destination)
        }
        return
      } catch {
        if ($attempt -ge 7) { throw }
        Start-Sleep -Milliseconds (40 * ($attempt + 1))
      }
    }
  } finally {
    try { if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) } } catch {}
    try { if (Test-Path -LiteralPath $replaceBackup) { [IO.File]::Delete($replaceBackup) } } catch {}
  }
}

function Test-StagedRuntime {
  Assert-NoReparseTree $stageRuntime
  $required = @(
    'Generate-ClaudeReport.ps1', 'ReportData.psm1', 'template.html', 'codex-rate-limits.mjs',
    'dashboard.bat', 'dashboard.vbs', 'icon.ico',
    'fonts\ark-pixel-12px-monospaced-zh_cn.woff2',
    'fonts\fusion-pixel-12px-monospaced-zh_hans.woff2'
  )
  foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $stageRuntime $relative))) {
      throw "Staged runtime is missing $relative."
    }
  }

  $sourceFiles = @(Get-ChildItem -LiteralPath $srcDir -File -Recurse | Sort-Object FullName)
  $stagedFiles = @(Get-ChildItem -LiteralPath $stageRuntime -File -Recurse | Sort-Object FullName)
  if ($sourceFiles.Count -ne $stagedFiles.Count) { throw 'Staged runtime file count differs from src.' }
  foreach ($sourceFile in $sourceFiles) {
    $relative = $sourceFile.FullName.Substring($srcDir.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
    $stagedPath = Join-Path $stageRuntime $relative
    if (-not (Test-Path -LiteralPath $stagedPath)) { throw "Staged runtime is missing $relative." }
    if ((Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $stagedPath -Algorithm SHA256).Hash) {
      throw "Staged runtime hash differs for $relative."
    }
  }

  foreach ($script in @(Get-ChildItem -LiteralPath $stageRuntime -File -Recurse | Where-Object { $_.Extension -in @('.ps1', '.psm1') })) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Staged script has parse errors: $($script.Name)." }
    $bytes = [IO.File]::ReadAllBytes($script.FullName)
    if (@($bytes | Where-Object { $_ -gt 127 }).Count) { throw "Staged PowerShell file is not ASCII: $($script.Name)." }
  }
}

function Test-PublishedRuntime {
  foreach ($stagedFile in @(Get-ChildItem -LiteralPath $stageRuntime -File -Recurse)) {
    $relative = Get-RelativeRuntimePath $stagedFile.FullName
    $target = Join-Path $dest $relative
    if (-not (Test-Path -LiteralPath $target)) { throw "Published runtime is missing $relative."
    }
    if ((Get-FileHash -LiteralPath $stagedFile.FullName -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) {
      throw "Published runtime hash differs for $relative."
    }
  }
}

function Initialize-InstallJobType {
  if ('AiUsage.InstallJob' -as [type]) { return }
  # INSTALL_JOB_CSHARP_BEGIN
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace AiUsage {
  public sealed class InstallJobCleanupException : InvalidOperationException {
    public InstallJobCleanupException(string message, Exception innerException)
      : base(message, innerException) { }
  }

  public static class InstallJob {
    const uint CREATE_NO_WINDOW = 0x08000000;
    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    const uint WAIT_OBJECT_0 = 0;
    const uint WAIT_TIMEOUT = 258;
    static readonly UIntPtr PROC_THREAD_ATTRIBUTE_JOB_LIST = new UIntPtr(0x0002000D);

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS {
      public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
      public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
      public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
      public uint LimitFlags;
      public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
      public uint ActiveProcessLimit;
      public UIntPtr Affinity;
      public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
      public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
      public IO_COUNTERS IoInfo;
      public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION {
      public long TotalUserTime, TotalKernelTime;
      public long ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
      public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFO {
      public int cb;
      public IntPtr lpReserved, lpDesktop, lpTitle;
      public uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars;
      public uint dwFillAttribute, dwFlags;
      public short wShowWindow, cbReserved2;
      public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX {
      public STARTUPINFO StartupInfo;
      public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION {
      public IntPtr hProcess, hThread;
      public uint dwProcessId, dwThreadId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool QueryInformationJobObject(
      IntPtr job, int infoClass, out JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info,
      uint length, IntPtr returnLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(
      IntPtr attributeList, uint attributeCount, uint flags, ref UIntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(
      IntPtr attributeList, uint flags, UIntPtr attribute, IntPtr value,
      UIntPtr valueSize, IntPtr previousValue, IntPtr returnSize);
    [DllImport("kernel32.dll")]
    static extern void DeleteProcThreadAttributeList(IntPtr attributeList);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(
      string applicationName, StringBuilder commandLine, IntPtr processAttributes,
      IntPtr threadAttributes, bool inheritHandles, uint creationFlags, IntPtr environment,
      string currentDirectory, ref STARTUPINFOEX startupInfo, out PROCESS_INFORMATION processInformation);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(IntPtr process, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);

    static void Win32(string operation) {
      throw new Win32Exception(Marshal.GetLastWin32Error(), operation + " failed");
    }

    static Exception CombineFailure(Exception current, Exception next) {
      return current == null ? next : new AggregateException(current, next);
    }

    static bool IsJobEmpty(IntPtr job) {
      JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info;
      uint size = (uint)Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
      if (!QueryInformationJobObject(job, 1, out info, size, IntPtr.Zero)) {
        Win32("QueryInformationJobObject");
      }
      return info.ActiveProcesses == 0;
    }

    static bool WaitForJobEmpty(IntPtr job, int timeoutMilliseconds) {
      var stopwatch = Stopwatch.StartNew();
      int emptyObservations = 0;
      while (true) {
        if (IsJobEmpty(job)) {
          emptyObservations++;
          if (emptyObservations >= 2) return true;
        } else {
          emptyObservations = 0;
        }
        if (timeoutMilliseconds < 0) {
          Thread.Sleep(25);
        } else {
          int remaining = timeoutMilliseconds - checked((int)Math.Min(int.MaxValue, stopwatch.ElapsedMilliseconds));
          if (remaining <= 0) return false;
          Thread.Sleep(Math.Min(25, remaining));
        }
      }
    }

    static int RunInternal(
        string commandInterpreter, string commandLine, string workingDirectory,
        int timeoutMilliseconds, string outputPath, long maxOutputBytes) {
      IntPtr job = IntPtr.Zero;
      IntPtr infoPointer = IntPtr.Zero;
      IntPtr attributeList = IntPtr.Zero;
      IntPtr jobListValue = IntPtr.Zero;
      bool attributeListInitialized = false;
      PROCESS_INFORMATION process = new PROCESS_INFORMATION();
      bool completed = false;
      bool processCreated = false;
      bool membershipVerified = false;
      Exception operationFailure = null;
      try {
        job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) Win32("CreateJobObject");
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        int infoSize = Marshal.SizeOf(info);
        infoPointer = Marshal.AllocHGlobal(infoSize);
        Marshal.StructureToPtr(info, infoPointer, false);
        if (!SetInformationJobObject(job, 9, infoPointer, (uint)infoSize)) Win32("SetInformationJobObject");

        UIntPtr attributeListSize = UIntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeListSize);
        if (attributeListSize == UIntPtr.Zero) Win32("InitializeProcThreadAttributeList(size)");
        attributeList = Marshal.AllocHGlobal(checked((int)attributeListSize.ToUInt64()));
        if (!InitializeProcThreadAttributeList(attributeList, 1, 0, ref attributeListSize)) {
          Win32("InitializeProcThreadAttributeList");
        }
        attributeListInitialized = true;
        jobListValue = Marshal.AllocHGlobal(IntPtr.Size);
        Marshal.WriteIntPtr(jobListValue, job);
        if (!UpdateProcThreadAttribute(
            attributeList, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST, jobListValue,
            new UIntPtr((uint)IntPtr.Size), IntPtr.Zero, IntPtr.Zero)) {
          Win32("UpdateProcThreadAttribute(JOB_LIST)");
        }

        var startup = new STARTUPINFOEX();
        startup.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        startup.lpAttributeList = attributeList;
        var mutableCommand = new StringBuilder(commandLine);
        if (!CreateProcess(commandInterpreter, mutableCommand, IntPtr.Zero, IntPtr.Zero, false,
            CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT, IntPtr.Zero, workingDirectory, ref startup, out process)) {
          Win32("CreateProcess");
        }
        processCreated = true;
        bool inJob;
        if (!IsProcessInJob(process.hProcess, job, out inJob)) Win32("IsProcessInJob");
        if (!inJob) throw new InvalidOperationException("The npm process was not created in its Job Object.");
        membershipVerified = true;

        uint wait = WAIT_TIMEOUT;
        var stopwatch = Stopwatch.StartNew();
        while (true) {
          if (IsJobEmpty(job)) {
            wait = WAIT_OBJECT_0;
            break;
          }
          int remaining = timeoutMilliseconds - checked((int)Math.Min(int.MaxValue, stopwatch.ElapsedMilliseconds));
          if (remaining <= 0) break;
          if (!String.IsNullOrEmpty(outputPath) && File.Exists(outputPath) &&
              new FileInfo(outputPath).Length > maxOutputBytes) {
            if (!TerminateJobObject(job, 111)) Win32("TerminateJobObject");
            if (!WaitForJobEmpty(job, 10000)) {
              throw new InvalidOperationException("The oversized command Job did not become empty.");
            }
            throw new InvalidOperationException("The command output exceeded its limit.");
          }
          Thread.Sleep(Math.Min(25, remaining));
        }
        if (wait == WAIT_TIMEOUT) {
          if (!TerminateJobObject(job, 1460)) Win32("TerminateJobObject");
          if (!WaitForJobEmpty(job, 10000)) {
            throw new TimeoutException("The timed-out npm Job did not become empty.");
          }
          throw new TimeoutException("The npm process timed out.");
        }
        if (!String.IsNullOrEmpty(outputPath) && File.Exists(outputPath) &&
            new FileInfo(outputPath).Length > maxOutputBytes) {
          throw new InvalidOperationException("The command output exceeded its limit.");
        }
        uint exitCode;
        if (!GetExitCodeProcess(process.hProcess, out exitCode)) Win32("GetExitCodeProcess");
        completed = true;
        return unchecked((int)exitCode);
      } catch (Exception error) {
        operationFailure = error;
        throw;
      } finally {
        Exception cleanupFailure = null;
        if (!completed && processCreated && process.hProcess != IntPtr.Zero) {
          try {
            uint rootState = WaitForSingleObject(process.hProcess, 0);
            if (rootState == WAIT_TIMEOUT) {
              if (!TerminateProcess(process.hProcess, 1)) Win32("TerminateProcess");
            } else if (rootState != WAIT_OBJECT_0) {
              Win32("WaitForSingleObject");
            }
          } catch (Exception error) { cleanupFailure = CombineFailure(cleanupFailure, error); }
        }
        if (!completed && processCreated && job != IntPtr.Zero) {
          try {
            if (!TerminateJobObject(job, 1)) Win32("TerminateJobObject");
          } catch (Exception error) { cleanupFailure = CombineFailure(cleanupFailure, error); }
        }
        if (!completed && processCreated && process.hProcess != IntPtr.Zero) {
          try {
            if (WaitForSingleObject(process.hProcess, 10000) != WAIT_OBJECT_0) {
              throw new InvalidOperationException("The failed npm root process did not exit.");
            }
          } catch (Exception error) { cleanupFailure = CombineFailure(cleanupFailure, error); }
        }
        if (!completed && processCreated && job != IntPtr.Zero) {
          try {
            if (!WaitForJobEmpty(job, 10000)) {
              throw new InvalidOperationException("The failed npm Job did not become empty.");
            }
          } catch (Exception error) { cleanupFailure = CombineFailure(cleanupFailure, error); }
        }
        if (processCreated && !membershipVerified) {
          cleanupFailure = CombineFailure(
            cleanupFailure,
            new InvalidOperationException("The failed npm process Job membership could not be verified.")
          );
        }
        if (process.hThread != IntPtr.Zero) {
          if (!CloseHandle(process.hThread)) {
            cleanupFailure = CombineFailure(
              cleanupFailure,
              new Win32Exception(Marshal.GetLastWin32Error(), "Closing the npm thread handle failed")
            );
          }
          process.hThread = IntPtr.Zero;
        }
        if (process.hProcess != IntPtr.Zero) {
          if (!CloseHandle(process.hProcess)) {
            cleanupFailure = CombineFailure(
              cleanupFailure,
              new Win32Exception(Marshal.GetLastWin32Error(), "Closing the npm process handle failed")
            );
          }
          process.hProcess = IntPtr.Zero;
        }
        if (attributeListInitialized) DeleteProcThreadAttributeList(attributeList);
        if (attributeList != IntPtr.Zero) Marshal.FreeHGlobal(attributeList);
        if (jobListValue != IntPtr.Zero) Marshal.FreeHGlobal(jobListValue);
        if (infoPointer != IntPtr.Zero) Marshal.FreeHGlobal(infoPointer);
        if (job != IntPtr.Zero) {
          if (!CloseHandle(job)) {
            cleanupFailure = CombineFailure(
              cleanupFailure,
              new Win32Exception(Marshal.GetLastWin32Error(), "Closing the npm Job handle failed")
            );
          }
          job = IntPtr.Zero;
        }
        if (cleanupFailure != null) {
          Exception detail = operationFailure == null
            ? cleanupFailure
            : new AggregateException(operationFailure, cleanupFailure);
          throw new InstallJobCleanupException(
            "The npm process tree cleanup could not be verified.", detail
          );
        }
      }
    }

    public static int Run(string commandInterpreter, string commandLine, string workingDirectory, int timeoutMilliseconds) {
      return RunInternal(commandInterpreter, commandLine, workingDirectory, timeoutMilliseconds, null, 0);
    }

    public static int RunWithOutputLimit(
        string commandInterpreter, string commandLine, string workingDirectory,
        int timeoutMilliseconds, string outputPath, long maxOutputBytes) {
      if (String.IsNullOrEmpty(outputPath)) throw new ArgumentException("An output path is required.");
      if (maxOutputBytes <= 0) throw new ArgumentOutOfRangeException("maxOutputBytes");
      return RunInternal(
        commandInterpreter, commandLine, workingDirectory, timeoutMilliseconds, outputPath, maxOutputBytes
      );
    }
  }
}
'@
  # INSTALL_JOB_CSHARP_END
}

function Invoke-Npm([string[]]$Arguments, [string]$FailureMessage) {
  if ($script:installProcessCleanupRequired) {
    throw 'Refusing to start npm while prior installation process cleanup is unverified.'
  }
  Test-SafeCommandArguments $Arguments
  Initialize-InstallJobType
  $commandInterpreter = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $commandBody = '"set "AI_USAGE_INSTALL_JOB=1" & "%AI_USAGE_INSTALL_COMMAND_PATH%" ' +
    ($Arguments -join ' ') + '"'
  $commandLine = '"' + $commandInterpreter + '" /d /q /v:off /s /c ' + $commandBody
  try {
    $exitCode = Invoke-WithCommandPathEnvironment $npmPath {
      [AiUsage.InstallJob]::Run($commandInterpreter, $commandLine, $PSScriptRoot, 600000)
    }
  } catch {
    Set-InstallProcessCleanupRequiredFromError $_
    throw
  }
  if ($exitCode -ne 0) { throw $FailureMessage }
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

function Confirm-InstallProcessCleanup([string]$UserSid) {
  if (-not $script:installProcessCleanupRequired) { return }
  try {
    Wait-AbandonedInstallProcesses $UserSid
    $script:installProcessCleanupRequired = $false
  } catch {
    $script:installProcessDrainFailed = $true
    throw
  }
}

function Test-AbandonedCollectorProcess([string]$Name, [string]$CommandLine) {
  if ($Name -notin @('cmd.exe', 'node.exe', 'powershell.exe', 'pwsh.exe', 'codeburn.exe', 'ccusage.exe')) {
    return $false
  }
  if ($Name -in @('codeburn.exe', 'ccusage.exe')) { return $true }
  if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
  if ($Name -eq 'cmd.exe' -and
      ($CommandLine -match '(?i)AI_USAGE_COLLECTOR_JOB' -or
       $CommandLine -match '(?i)(?:^|[\\/"\s])(?:codeburn|ccusage)\.cmd(?:["\s]|$)')) {
    return $true
  }
  return $CommandLine -match '(?i)[\\/]node_modules[\\/](?:codeburn|ccusage)[\\/]'
}

function Get-AbandonedCollectorProcesses([string]$UserSid) {
  $matches = @()
  foreach ($process in @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)) {
    if ([int]$process.ProcessId -eq $PID) { continue }
    $name = [string]$process.Name
    $commandLine = [string]$process.CommandLine
    if (-not (Test-AbandonedCollectorProcess $name $commandLine)) { continue }
    $ownerState = 'Unknown'
    try {
      $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -OperationTimeoutSec 2 -ErrorAction Stop
      if ([int]$owner.ReturnValue -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$owner.Sid)) {
        $ownerState = if ([string]$owner.Sid -eq $UserSid) { 'Same' } else { 'Other' }
      }
    } catch {}
    if ($ownerState -eq 'Other') { continue }
    if ($ownerState -eq 'Unknown' -and
        -not (Get-Process -Id ([int]$process.ProcessId) -ErrorAction SilentlyContinue)) { continue }
    $matches += [pscustomobject]@{ ProcessId = [int]$process.ProcessId; Name = $name; OwnerState = $ownerState }
  }
  return $matches
}

function Wait-AbandonedCollectorProcesses([string]$UserSid) {
  $deadline = [DateTime]::UtcNow.AddMinutes(2)
  $emptyScans = 0
  $active = @()
  while ([DateTime]::UtcNow -lt $deadline) {
    $active = @(Get-AbandonedCollectorProcesses $UserSid)
    if (-not $active.Count) {
      $emptyScans += 1
      if ($emptyScans -ge 2) { return }
    } else {
      $emptyScans = 0
    }
    Start-Sleep -Milliseconds 200
  }
  $summary = @($active | ForEach-Object { '{0}:{1} ({2})' -f $_.Name, $_.ProcessId, $_.OwnerState }) -join ', '
  throw "A collector from an abandoned report did not finish within two minutes: $summary."
}

function Remove-TransactionRoot {
  $resolvedParent = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  $expectedNames = @(
    ('.ClaudeUsage-install-' + $transactionId)
    ('.ClaudeUsage-install-init-' + $transactionId)
  )
  foreach ($candidate in @($transactionRoot, $transactionBootstrapRoot)) {
    $resolvedRoot = [IO.Path]::GetFullPath($candidate)
    if (-not $resolvedRoot.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase) -or
        $expectedNames -cnotcontains [IO.Path]::GetFileName($resolvedRoot)) {
      throw 'Refusing to clean an unexpected installer transaction path.'
    }
    if (Test-Path -LiteralPath $resolvedRoot) {
      Assert-NoReparseTree $resolvedRoot
      [IO.Directory]::Delete($resolvedRoot, $true)
    }
  }
}

function Remove-AbandonedInstallerResidue {
  $localRoot = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd([IO.Path]::DirectorySeparatorChar)
  $incompleteCutoff = [DateTime]::UtcNow.AddHours(-1)
  foreach ($directory in @(Get-ChildItem -LiteralPath $localRoot -Directory -Filter '.ClaudeUsage-install-*' -ErrorAction SilentlyContinue)) {
    if ($directory.Name -notmatch '^\.ClaudeUsage-install-(?:init-)?[0-9a-fA-F]{32}$' -or
        -not [IO.Path]::GetFullPath($directory.Parent.FullName).TrimEnd([IO.Path]::DirectorySeparatorChar).Equals(
          $localRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
    $ownerPath = Join-Path $directory.FullName '.owner'
    $ownerMatch = $null
    try {
      if (Test-Path -LiteralPath $ownerPath -PathType Leaf) {
        $ownerText = [IO.File]::ReadAllText($ownerPath)
        $ownerMatch = [regex]::Match($ownerText, '^pid=(\d+)\r?\nstartedUtcTicks=(\d+)\r?\n?$')
      }
    } catch { continue }
    if (-not $ownerMatch -or -not $ownerMatch.Success) {
      try {
        $entries = @(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction Stop)
        $isIncompleteShell = -not $entries.Count -or
          ($entries.Count -eq 1 -and $entries[0].Name -ceq '.owner' -and -not $entries[0].PSIsContainer)
        $latestWrite = $directory.LastWriteTimeUtc
        foreach ($entry in $entries) {
          if ($entry.LastWriteTimeUtc -gt $latestWrite) { $latestWrite = $entry.LastWriteTimeUtc }
        }
        if ($isIncompleteShell -and $latestWrite -le $incompleteCutoff) {
          Assert-NoReparseTree $directory.FullName
          [IO.Directory]::Delete($directory.FullName, $true)
        }
      } catch {}
      continue
    }
    try {
      $ownerProcess = Get-Process -Id ([int]$ownerMatch.Groups[1].Value) -ErrorAction SilentlyContinue
      if ($ownerProcess -and [string]($ownerProcess.StartTime.ToUniversalTime().Ticks) -eq $ownerMatch.Groups[2].Value) { continue }
    } catch { continue }
    try {
      Assert-NoReparseTree $directory.FullName
      [IO.Directory]::Delete($directory.FullName, $true)
    } catch {}
  }

  $cleanupDirectories = @($dest, $desktop)
  foreach ($sourceDirectory in @(Get-ChildItem -LiteralPath $srcDir -Directory -Recurse -ErrorAction SilentlyContinue)) {
    $relative = $sourceDirectory.FullName.Substring($srcDir.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
    $cleanupDirectories += Join-Path $dest $relative
  }
  foreach ($directory in @($cleanupDirectories | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $directory)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue)) {
      if ($file.Name -match '^\..+\.install-[0-9a-fA-F]{32}\.tmp(?:\.bak)?$') {
        try { [IO.File]::Delete($file.FullName) } catch {}
      }
    }
  }
}

try {
  Assert-NoReparseTree $srcDir
  Assert-NoReparsePath $env:LOCALAPPDATA
  Assert-NoReparsePath $dest
  $ownerStartedUtcTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
  [void][IO.Directory]::CreateDirectory($transactionBootstrapRoot)
  [IO.File]::WriteAllText(
    (Join-Path $transactionBootstrapRoot '.owner'),
    "pid=$PID`r`nstartedUtcTicks=$ownerStartedUtcTicks`r`n",
    [Text.Encoding]::ASCII
  )
  [IO.Directory]::Move($transactionBootstrapRoot, $transactionRoot)
  if (-not (Test-Path -LiteralPath $transactionOwnerPath -PathType Leaf)) {
    throw 'Installer transaction ownership publication failed.'
  }
  [void][IO.Directory]::CreateDirectory($stageRuntime)
  [void][IO.Directory]::CreateDirectory($rollbackRuntime)
  Assert-NoReparsePath $transactionRoot
  foreach ($sourceChild in @(Get-ChildItem -LiteralPath $srcDir -Force)) {
    Copy-Item -LiteralPath $sourceChild.FullName -Destination $stageRuntime -Recurse -Force
  }
  Test-StagedRuntime
  Write-Host '  [ok] runtime staged and verified' -ForegroundColor Green

$tools = @(
  [ordered]@{ Command = 'codeburn'; Package = 'codeburn'; Label = 'CodeBurn'; Version = '0.9.19' },
  [ordered]@{ Command = 'ccusage'; Package = 'ccusage'; Label = 'ccusage'; Version = '20.0.20' }
)

$desktop = if ([string]::IsNullOrWhiteSpace($DesktopDirectory)) { [Environment]::GetFolderPath('Desktop') } else { [IO.Path]::GetFullPath($DesktopDirectory) }
[void][IO.Directory]::CreateDirectory($desktop)
Assert-NoReparsePath $desktop
$shortcutPath = Join-Path $desktop 'AI Usage.lnk'
$shortcutBackup = Join-Path $transactionRoot 'AI Usage.lnk'
} catch {
  try { Remove-TransactionRoot } catch {}
  throw
}

try {
  $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $installMutex = [Threading.Mutex]::new($false, "Global\AIUsage-Install-$userSid")
  try {
    $installMutexHeld = $installMutex.WaitOne([TimeSpan]::FromMinutes(5))
  } catch [Threading.AbandonedMutexException] {
    $installMutexHeld = $true
    $installMutexAbandoned = $true
  }
  if (-not $installMutexHeld) { throw 'Another AI Usage installer did not finish within five minutes.' }
  if ($installMutexAbandoned) {
    $installProcessCleanupRequired = $true
    Confirm-InstallProcessCleanup $userSid
  }

  $nodeVersion = Get-ExactReleaseVersion $nodePath
  if (-not $nodeVersion -or $nodeVersion -lt [version]'22.13.0') {
    throw 'CodeBurn 0.9.19 requires Node.js 22.13.0 or newer.'
  }
  Write-Host "  [ok] Node.js $nodeVersion" -ForegroundColor Green

  [void][IO.Directory]::CreateDirectory($dest)
  Assert-NoReparsePath $dest
  $runStateRoot = Split-Path $runStatePath -Parent
  Assert-NoReparsePath $runStateRoot
  [void][IO.Directory]::CreateDirectory($runStateRoot)
  Assert-NoReparsePath $runStateRoot
  $managedFiles = @(Get-ChildItem -LiteralPath $stageRuntime -File -Recurse)
  foreach ($stagedFile in $managedFiles) {
    $relative = Get-RelativeRuntimePath $stagedFile.FullName
    $target = Join-Path $dest $relative
    Assert-NoReparsePath $target
    $exists = Test-Path -LiteralPath $target
    $originalFiles[$relative] = $exists
    if ($exists) {
      $backup = Join-Path $rollbackRuntime $relative
      $backupParent = Split-Path $backup -Parent
      [void][IO.Directory]::CreateDirectory($backupParent)
      [IO.File]::Copy($target, $backup, $true)
      if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne
          (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash) {
        throw "Runtime backup hash differs for $relative."
      }
    }
  }

  if (Test-Path -LiteralPath $shortcutPath) {
    [IO.File]::Copy($shortcutPath, $shortcutBackup, $true)
    try {
      $existingShortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
      $iconLocation = [string]$existingShortcut.IconLocation
      $separator = $iconLocation.LastIndexOf(',')
      if ($separator -ge 0 -and $iconLocation.Substring($separator + 1).Trim() -match '^-?\d+$') {
        $iconLocation = $iconLocation.Substring(0, $separator)
      }
      $iconCandidate = [IO.Path]::GetFullPath($iconLocation.Trim().Trim([char]34))
      if ([IO.Path]::GetDirectoryName($iconCandidate).Equals(
          [IO.Path]::GetFullPath($dest).TrimEnd([IO.Path]::DirectorySeparatorChar),
          [StringComparison]::OrdinalIgnoreCase) -and
          [IO.Path]::GetFileName($iconCandidate) -match '^icon-[0-9a-fA-F]{8}\.ico$') {
        $previousManagedIconPath = $iconCandidate
      }
    } catch {}
  }

  $pendingWasPresent = Test-Path -LiteralPath $pendingPath
  $markerSource = Join-Path $transactionRoot '.install-pending'
  $pendingContents = "transaction=$transactionId`r`nstage=pending`r`n"
  [IO.File]::WriteAllText($markerSource, $pendingContents, [Text.Encoding]::ASCII)

  # Establish the fail-closed marker before publishing code that understands it.
  # If the process is killed between these writes, dependencies are still unchanged.
  Set-FileAtomically $markerSource $pendingPath
  $pendingWritten = $true

  # Publish the pending-aware generator before changing global dependencies. If the
  # process is killed later, normal launches stop at the marker until install reruns.
  $generatorRelative = 'Generate-ClaudeReport.ps1'
  Set-FileAtomically (Join-Path $stageRuntime $generatorRelative) (Join-Path $dest $generatorRelative)
  $publishedFiles += $generatorRelative

  # Drain before taking either report mutex. An already-started generator may be
  # waiting for Global or Local; holding that lock while waiting for its process
  # would create a five-minute lock cycle. The marker and pending-aware installed
  # generator prevent any new supported launch from entering during the drain.
  Wait-MigrationUsageProcesses $userSid

  $runMutex = [Threading.Mutex]::new($false, "Global\AIUsage-CodeBurn-$userSid")
  try {
    $runMutexHeld = $runMutex.WaitOne([TimeSpan]::FromMinutes(5))
  } catch [Threading.AbandonedMutexException] {
    $runMutexHeld = $true
    $runMutexAbandoned = $true
  }
  if (-not $runMutexHeld) { throw 'A running AI Usage report did not finish within five minutes.' }

  # Public releases before the SID-scoped mutex used a session-local mutex. Take
  # it only after the process drain, and in the same Global -> Local order as the
  # current generator.
  $legacyRunMutex = [Threading.Mutex]::new($false, 'Local\AIUsage-CodeBurn')
  try {
    $legacyRunMutexHeld = $legacyRunMutex.WaitOne([TimeSpan]::FromMinutes(5))
  } catch [Threading.AbandonedMutexException] {
    $legacyRunMutexHeld = $true
    $legacyRunMutexAbandoned = $true
  }
  if (-not $legacyRunMutexHeld) { throw 'A legacy AI Usage report did not finish within five minutes.' }
  if ($runMutexAbandoned -or $legacyRunMutexAbandoned) {
    Wait-AbandonedCollectorProcesses $userSid
  }

  [IO.File]::WriteAllText($runStatePath, 'closing', [Text.Encoding]::ASCII)
  $runStateWritten = $true

  # Capture rollback baselines only after every report process is quiescent. A
  # previous interrupted transaction may already have changed one package.
  $npmRoot = Get-NpmGlobalRoot
  foreach ($tool in $tools) {
    $resolved = Get-ToolCommand $tool.Command
    $pathVersion = if ($resolved) { Get-ToolVersion $resolved.Source } else { $null }
    $packageVersion = Get-NpmPackageVersion $npmRoot $tool.Package
    $toolStates += [pscustomobject]@{
      Tool = $tool
      PackageWasInstalled = $null -ne $packageVersion
      PreviousVersion = $packageVersion
      PreviousPath = if ($resolved -and $pathVersion) { $resolved.Source } else { $null }
      PreviousPathVersion = if ($resolved -and $pathVersion) { $pathVersion } else { $null }
      NeedsInstall = ($packageVersion -ne $tool.Version) -or (-not $resolved) -or ($pathVersion -ne $tool.Version)
      MutationStarted = $false
    }
  }

  foreach ($state in $toolStates) {
    $tool = $state.Tool
    if (-not $state.NeedsInstall) {
      Write-Host "  [ok] $($tool.Label) $($tool.Version) present" -ForegroundColor Green
      continue
    }
    $state.MutationStarted = $true
    $package = "$($tool.Package)@$($tool.Version)"
    Write-Host "  [..] installing $package globally"
    Invoke-Npm @('install', '-g', $package) "Failed to install $package."
    $verified = Get-ToolCommand $tool.Command
    if (-not $verified) { throw "$($tool.Label) was installed but is not available on PATH." }
    $verifiedVersion = Get-ToolVersion $verified.Source
    $verifiedPackageVersion = Get-NpmPackageVersion $npmRoot $tool.Package
    if ($verifiedPackageVersion -ne $tool.Version -or $verifiedVersion -ne $tool.Version) {
      throw ("{0} {1} was requested, but PATH resolves {2}." -f $tool.Label, $tool.Version, $verifiedVersion)
    }
    Write-Host "  [ok] $($tool.Label) $verifiedVersion installed" -ForegroundColor Green
  }

  foreach ($stagedFile in $managedFiles) {
    $relative = Get-RelativeRuntimePath $stagedFile.FullName
    if ($relative -eq $generatorRelative) { continue }
    Set-FileAtomically $stagedFile.FullName (Join-Path $dest $relative)
    $publishedFiles += $relative
  }
  Test-PublishedRuntime

  foreach ($name in @('Generate-ClaudeReport.ps1', 'ReportData.psm1', 'template.html', 'codex-rate-limits.mjs', 'dashboard.bat', 'dashboard.vbs', 'icon.ico')) {
    Unblock-File -LiteralPath (Join-Path $dest $name) -ErrorAction SilentlyContinue
  }
  Write-Host "  [ok] installed to $dest" -ForegroundColor Green

  $iconHash = (Get-FileHash -LiteralPath (Join-Path $dest 'icon.ico') -Algorithm SHA256).Hash.Substring(0, 8).ToLower()
  $iconPath = Join-Path $dest "icon-$iconHash.ico"
  $iconWasPresent = Test-Path -LiteralPath $iconPath
  if ($iconWasPresent) {
    [IO.File]::Copy($iconPath, $iconRollbackPath, $true)
    if ((Get-FileHash -LiteralPath $iconPath -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $iconRollbackPath -Algorithm SHA256).Hash) {
      throw 'Managed icon backup hash differs from its source.'
    }
  }
  Set-FileAtomically (Join-Path $dest 'icon.ico') $iconPath
  $iconPublished = $true

  $temporaryShortcut = Join-Path $transactionRoot 'AI Usage.new.lnk'
  $wsh = New-Object -ComObject WScript.Shell
  $shortcut = $wsh.CreateShortcut($temporaryShortcut)
  $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
  $shortcut.Arguments = '"' + (Join-Path $dest 'dashboard.vbs') + '"'
  $shortcut.WorkingDirectory = $dest
  $shortcut.IconLocation = "$iconPath,0"
  $shortcut.WindowStyle = 1
  $shortcut.Description = 'Local Claude and Codex AI usage dashboard'
  $shortcut.Save()
  if (-not (Test-Path -LiteralPath $temporaryShortcut)) { throw 'Desktop shortcut staging failed.' }
  Set-FileAtomically $temporaryShortcut $shortcutPath
  $shortcutPublished = $true

  foreach ($state in $toolStates) {
    $verified = Get-ToolCommand $state.Tool.Command
    $verifiedPackageVersion = Get-NpmPackageVersion $npmRoot $state.Tool.Package
    if ($verifiedPackageVersion -ne $state.Tool.Version -or -not $verified -or
        (Get-ToolVersion $verified.Source) -ne $state.Tool.Version) {
      throw "$($state.Tool.Label) changed during installation verification."
    }
  }
  Test-PublishedRuntime
  Confirm-InstallProcessCleanup $userSid

  if (-not (Test-Path -LiteralPath $pendingPath) -or [IO.File]::ReadAllText($pendingPath) -ne $pendingContents) {
    throw 'The installation marker changed while the transaction lock was held.'
  }
  [IO.File]::Delete($pendingPath)
  $transactionCommitted = $true
  if ($previousManagedIconPath -and $iconPath -and
      -not $previousManagedIconPath.Equals($iconPath, [StringComparison]::OrdinalIgnoreCase) -and
      (Test-Path -LiteralPath $previousManagedIconPath)) {
    try { [IO.File]::Delete($previousManagedIconPath) } catch {}
  }
} catch {
  $installError = $_.Exception.Message
  $rollbackErrors = @()
  try { Confirm-InstallProcessCleanup $userSid } catch {}

  if ($installProcessDrainFailed) {
    throw 'Installation process cleanup could not be verified; transaction locks will be abandoned.'
  }

  for ($index = $toolStates.Count - 1; $index -ge 0; $index--) {
    $state = $toolStates[$index]
    if (-not $state.MutationStarted) { continue }
    try {
      if ($state.PackageWasInstalled -and $state.PreviousVersion) {
        Invoke-Npm @('install', '-g', "$($state.Tool.Package)@$($state.PreviousVersion)") "Failed to restore $($state.Tool.Label)."
        if ((Get-NpmPackageVersion $npmRoot $state.Tool.Package) -ne $state.PreviousVersion) {
          throw "$($state.Tool.Label) rollback verification failed."
        }
      } else {
        Invoke-Npm @('uninstall', '-g', $state.Tool.Package) "Failed to remove $($state.Tool.Label) during rollback."
        if ($null -ne (Get-NpmPackageVersion $npmRoot $state.Tool.Package)) {
          throw "$($state.Tool.Label) uninstall rollback verification failed."
        }
      }
      $restored = Get-ToolCommand $state.Tool.Command
      if ($state.PreviousPath) {
        if (-not $restored -or -not ([IO.Path]::GetFullPath($restored.Source)).Equals(
            [IO.Path]::GetFullPath($state.PreviousPath), [StringComparison]::OrdinalIgnoreCase) -or
            (Get-ToolVersion $restored.Source) -ne $state.PreviousPathVersion) {
          throw "$($state.Tool.Label) PATH rollback verification failed."
        }
      } elseif ($restored) {
        throw "$($state.Tool.Label) unexpectedly remained on PATH after rollback."
      }
    } catch {
      $rollbackErrors += $_.Exception.Message
      if ($script:installProcessCleanupRequired) { break }
    }
  }

  try { Confirm-InstallProcessCleanup $userSid } catch {}
  if ($installProcessDrainFailed) {
    throw 'Installation process cleanup could not be verified; transaction locks will be abandoned.'
  }

  if (-not $rollbackErrors.Count) {
    for ($index = $publishedFiles.Count - 1; $index -ge 0; $index--) {
      $relative = $publishedFiles[$index]
      if ($relative -eq 'Generate-ClaudeReport.ps1') { continue }
      try {
        $target = Join-Path $dest $relative
        if ($originalFiles[$relative]) {
          Set-FileAtomically (Join-Path $rollbackRuntime $relative) $target
        } elseif (Test-Path -LiteralPath $target) {
          [IO.File]::Delete($target)
        }
      } catch {
        $rollbackErrors += $_.Exception.Message
      }
    }
  }

  if (-not $rollbackErrors.Count -and -not $pendingWasPresent -and
      $publishedFiles -contains 'Generate-ClaudeReport.ps1') {
    try {
      $generatorTarget = Join-Path $dest 'Generate-ClaudeReport.ps1'
      if ($originalFiles['Generate-ClaudeReport.ps1']) {
        Set-FileAtomically (Join-Path $rollbackRuntime 'Generate-ClaudeReport.ps1') $generatorTarget
      } elseif (Test-Path -LiteralPath $generatorTarget) {
        [IO.File]::Delete($generatorTarget)
      }
    } catch {
      $rollbackErrors += $_.Exception.Message
    }
  }

  if (-not $rollbackErrors.Count -and $shortcutPublished) {
    try {
      if (Test-Path -LiteralPath $shortcutBackup) {
        Set-FileAtomically $shortcutBackup $shortcutPath
      } elseif (Test-Path -LiteralPath $shortcutPath) {
        [IO.File]::Delete($shortcutPath)
      }
    } catch {
      $rollbackErrors += $_.Exception.Message
    }
  }
  if (-not $rollbackErrors.Count -and $iconPublished -and $iconPath) {
    try {
      if ($iconWasPresent) {
        Set-FileAtomically $iconRollbackPath $iconPath
      } elseif (Test-Path -LiteralPath $iconPath) {
        [IO.File]::Delete($iconPath)
      }
    } catch { $rollbackErrors += $_.Exception.Message }
  }

  if (-not $rollbackErrors.Count -and $pendingWritten -and -not $pendingWasPresent) {
    try {
      if ((Test-Path -LiteralPath $pendingPath) -and [IO.File]::ReadAllText($pendingPath) -eq $pendingContents) {
        [IO.File]::Delete($pendingPath)
      } elseif (Test-Path -LiteralPath $pendingPath) {
        throw 'The installation marker is no longer owned by this transaction.'
      }
    } catch { $rollbackErrors += $_.Exception.Message }
  }
  if (-not $rollbackErrors.Count) { $rollbackComplete = $true }

  if ($rollbackErrors.Count) {
    throw ("Installation failed: {0} Rollback was incomplete: {1}. Rerun install.ps1 before launching AI Usage." -f
      $installError, ($rollbackErrors -join ' | '))
  }
  if ($pendingWasPresent) {
    throw ("Installation recovery failed; the pending marker was retained. Rerun install.ps1: {0}" -f $installError)
  }
  throw ("Installation failed and was rolled back: {0}" -f $installError)
} finally {
  try {
    if ($runStateWritten -and (Test-Path -LiteralPath $runStatePath)) {
      $stateText = [IO.File]::ReadAllText($runStatePath).Trim()
      if ($stateText -eq 'closing') { [IO.File]::Delete($runStatePath) }
    }
  } catch {}

  if ($installProcessCleanupRequired -and -not $installProcessDrainFailed) {
    try { Confirm-InstallProcessCleanup $userSid } catch {}
  }
  if ($installProcessDrainFailed) {
    throw 'Installation process cleanup could not be verified; transaction locks will be abandoned.'
  }

  if ($transactionCommitted -or $rollbackComplete) {
    try { Remove-TransactionRoot } catch {}
  }
  if ($transactionCommitted) {
    try { Remove-AbandonedInstallerResidue } catch {}
  }

  if ($legacyRunMutexHeld) { try { $legacyRunMutex.ReleaseMutex() } catch {} }
  if ($runMutexHeld) { try { $runMutex.ReleaseMutex() } catch {} }
  if ($installMutexHeld) { try { $installMutex.ReleaseMutex() } catch {} }
  if ($legacyRunMutex) { try { $legacyRunMutex.Dispose() } catch {} }
  if ($runMutex) { try { $runMutex.Dispose() } catch {} }
  if ($installMutex) { try { $installMutex.Dispose() } catch {} }
}

# The oldest shortcut name is Chinese. Windows PowerShell reads a BOM-less script
# in the system ANSI code page, so the literal would arrive as mojibake and never
# match the file on disk; the code points survive that reading intact.
$legacyChineseShortcut = 'Claude' + (-join [char[]](0x7528, 0x91CF, 0x4EEA, 0x8868, 0x76D8)) + '.lnk'
foreach ($oldName in @($legacyChineseShortcut, 'Claude Usage Dashboard.lnk', 'AI Usage Ledger.lnk')) {
  $oldShortcut = Join-Path $desktop $oldName
  if (Test-Path -LiteralPath $oldShortcut) { Remove-Item -LiteralPath $oldShortcut -Force -ErrorAction SilentlyContinue }
}

if (-not $NoPrompt) {
  try {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\ie4uinit.exe') -ArgumentList '-show' -WindowStyle Hidden -Wait
  } catch {}
}
Write-Host '  [ok] Desktop shortcut created' -ForegroundColor Green

Write-Host ''
Write-Host "  Done. Double-click 'AI Usage' on the Desktop." -ForegroundColor Cyan
Write-Host ''
if (-not $NoPrompt) { Read-Host '  Press Enter to finish' }
