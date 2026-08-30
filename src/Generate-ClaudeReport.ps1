<#
  Build a local, disposable Claude + Codex usage snapshot.
  CodeBurn provides the normalized usage and API-equivalent price estimates.
#>
param(
  [ValidateSet('today', 'week', '30days', 'month', 'all', 'lifetime')]
  [string]$Period = '30days',
  [switch]$KeepFile,
  [switch]$NoLaunch,
  [int]$DeleteAfter = 18
)

$ErrorActionPreference = 'Stop'
$Period = $Period.ToLowerInvariant()
$AppDir = $PSScriptRoot
$Template = Join-Path $AppDir 'template.html'
$FontDir = Join-Path $AppDir 'fonts'
$ReportDataModule = Join-Path $AppDir 'ReportData.psm1'
$RequiredCodeBurnVersion = '0.9.19'
$RequiredCCUsageVersion = '20.0.20'
$MaxCollectorOutputBytes = [int64](16 * 1024 * 1024)
$MaxQuotaResponseBytes = [int64](1024 * 1024)
$CCUsageTimeoutMilliseconds = 120000
$RuntimeRoot = Join-Path $env:TEMP 'ClaudeUsage'
$InstallPendingPaths = @(
  (Join-Path $AppDir '.install-pending'),
  (Join-Path (Join-Path $env:LOCALAPPDATA 'ClaudeUsage') '.install-pending')
) | Select-Object -Unique
function Assert-NoPendingInstallation {
  if (@($InstallPendingPaths | Where-Object { Test-Path -LiteralPath $_ }).Count) {
    throw 'AI Usage installation is incomplete. Run install.ps1 again.'
  }
}
Assert-NoPendingInstallation
$RetainedRun = [bool]($NoLaunch -or $KeepFile)
$OutDir = if ($RetainedRun) {
  Join-Path $RuntimeRoot ("debug-{0}-{1}" -f [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff'), $PID)
} else {
  $RuntimeRoot
}
$QuotaCachePath = Join-Path $RuntimeRoot 'quota-cache.json'
$CodexQuotaCachePath = Join-Path $RuntimeRoot 'codex-quota-cache.json'
$ReadLeasePath = Join-Path $RuntimeRoot 'report-read.lease'
$RunStatePath = Join-Path $RuntimeRoot 'report-run.state'
$RunOwnerPath = Join-Path $RuntimeRoot 'report-run.owner.json'
$RetryRequestPath = Join-Path $RuntimeRoot 'report-retry.request'
$OutHtml = Join-Path $OutDir 'report.html'
$OutData = Join-Path $OutDir 'data.js'
$OutFailure = Join-Path $OutDir 'failure.js'
$FontNames = @(
  'ark-pixel-12px-monospaced-zh_cn.woff2',
  'fusion-pixel-12px-monospaced-zh_hans.woff2'
)
$OutFonts = @($FontNames | ForEach-Object { Join-Path $OutDir $_ })
$ManagedPeriodKeys = @('today', 'week', '30days', 'month', 'all', 'lifetime')
$ManagedScratchNames = @(
  '_claude-blocks.json', 'data.js.tmp', 'data.js.bak', 'failure.js.tmp', 'failure.js.bak'
)
foreach ($managedPeriod in $ManagedPeriodKeys) {
  foreach ($managedProvider in @('claude', 'codex')) {
    $ManagedScratchNames += "_${managedPeriod}-${managedProvider}-report.json"
    $ManagedScratchNames += "_${managedPeriod}-${managedProvider}-status.json"
  }
}
Import-Module $ReportDataModule -Force

function Resolve-CommandPath([string[]]$Names) {
  foreach ($name in $Names) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
  }
  return $null
}

function Get-NpmPackageVersion([string]$CommandPath, [string]$PackageName) {
  # npm's Windows shim and package.json are installed side by side. Reading the
  # manifest avoids starting a full Node process only to print one version.
  try {
    $packagePath = Join-Path (Split-Path $CommandPath -Parent) "node_modules\$PackageName\package.json"
    if (Test-Path -LiteralPath $packagePath) {
      $package = [IO.File]::ReadAllText($packagePath) | ConvertFrom-Json
      if ($package.name -eq $PackageName -and $package.version) {
        return [string]$package.version
      }
    }
  } catch {}
  return $null
}

function Read-JsonFile([string]$Path) {
  try {
    $file = [IO.FileInfo]::new($Path)
    if (-not $file.Exists -or $file.Length -gt $MaxCollectorOutputBytes) { return $null }
    $raw = [IO.File]::ReadAllText($Path).Trim()
    if ($raw.StartsWith('{') -or $raw.StartsWith('[')) {
      return $raw | ConvertFrom-Json
    }
  } catch {}
  return $null
}

function Read-LatestRateLimitFromFile([string]$Path) {
  try {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
      $size = [Math]::Min([int64]8388608, $stream.Length)
      $null = $stream.Seek(-$size, [IO.SeekOrigin]::End)
      $buffer = New-Object byte[] $size
      $read = $stream.Read($buffer, 0, $buffer.Length)
      $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
      $lines = $text -split "`r?`n"
      for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -notmatch '"rate_limits"') { continue }
        try {
          $entry = $lines[$i] | ConvertFrom-Json
          if ($entry.payload.rate_limits) { return $entry.payload.rate_limits }
        } catch {}
      }
    } finally {
      $stream.Dispose()
    }
  } catch {}
  return $null
}

<#
  Real Claude quota, from the same endpoint Claude Code itself uses.

  ccusage blocks only describe a rolling 5-hour *cost* window; they say nothing
  about how much of the plan is left, so a gauge built on them can only show
  elapsed time. The authoritative source is GET /api/oauth/usage.

  Red lines (mirrored from the AI Resume implementation, which learned them the
  hard way on 2026-08-08):
    1. the token is read-only - never refreshed, never written back;
    2. the token never reaches a log, an exception message, or the payload;
    3. under 60s of remaining life counts as expired - no request is made;
    4. any failure degrades to the ccusage window, and never throws;
    5. `limits[]` is authoritative for "am I actually blocked" - five_hour and
       seven_day alone miss it. Measured that day: weekly_all 93% read as fine
       while weekly_scoped was already 100% and requests were being refused.
#>
function Get-ClaudeOAuthUsage {
  # The endpoint rate-limits (observed 429 under repeated calls), and the app is
  # launched on demand, so a short cache keeps rapid relaunches from hammering it
  # and keeps the most important card populated when a call fails.
  $cachePath = $QuotaCachePath
  $FreshSeconds = 120      # reuse without calling at all
  $StaleSeconds = 3600     # reuse, clearly labelled, only if the live call fails
  $cached = $null
  try {
    if (Test-Path $cachePath) {
      $raw = [IO.File]::ReadAllText($cachePath) | ConvertFrom-Json
      if (-not ($raw -is [pscustomobject]) -or
          -not (Test-OutputRecordProperty $raw 'cachedAt') -or
          -not (Test-OutputRecordProperty $raw 'cachedAtUnix') -or
          -not (Test-OutputRecordProperty $raw 'payload') -or
          -not (Test-JsonDateValue (Get-OutputRecordValue $raw 'cachedAt')) -or
          -not (Test-JsonInt64Value (Get-OutputRecordValue $raw 'cachedAtUnix'))) {
        throw 'Malformed Claude quota cache envelope.'
      }
      $safeCachedPayload = Select-ClaudeQuotaFields (Get-OutputRecordValue $raw 'payload')
      if (-not $safeCachedPayload.ok) { throw 'Malformed Claude quota cache payload.' }
      $age = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$raw.cachedAtUnix)
      if ($age -ge 0 -and $age -lt $StaleSeconds) {
        $cached = [pscustomobject][ordered]@{
          cachedAt = [string]$raw.cachedAt
          cachedAtUnix = [int64]$raw.cachedAtUnix
          payload = $safeCachedPayload
        }
      }
      if ($cached -and $age -lt $FreshSeconds) {
        $hit = $cached.payload | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        Add-Member -InputObject $hit -NotePropertyName 'cachedAt' -NotePropertyValue $cached.cachedAt -Force
        $safeHit = Select-ClaudeQuotaFields $hit
        if ($safeHit.ok) { return $safeHit }
        $cached = $null
      }
    }
  } catch { $cached = $null }

  function Use-CachedQuota([string]$Reason) {
    if (-not $cached) { return [ordered]@{ ok = $false; reason = $Reason } }
    try {
      $hit = $cached.payload | ConvertTo-Json -Depth 20 | ConvertFrom-Json
      Add-Member -InputObject $hit -NotePropertyName 'cachedAt' -NotePropertyValue $cached.cachedAt -Force
      Add-Member -InputObject $hit -NotePropertyName 'stale' -NotePropertyValue $true -Force
      Add-Member -InputObject $hit -NotePropertyName 'staleReason' -NotePropertyValue $Reason -Force
      $safeHit = Select-ClaudeQuotaFields $hit
      if (-not $safeHit.ok) { return [ordered]@{ ok = $false; reason = $Reason } }
      return $safeHit
    } catch {
      return [ordered]@{ ok = $false; reason = $Reason }
    }
  }

  $credentials = Join-Path $env:USERPROFILE '.claude\.credentials.json'
  if (-not (Test-Path $credentials)) { return Use-CachedQuota 'no_credentials' }

  $token = $null
  try {
    $parsed = [IO.File]::ReadAllText($credentials) | ConvertFrom-Json
    $token = $parsed.claudeAiOauth.accessToken
    $expiresAt = $parsed.claudeAiOauth.expiresAt
  } catch {
    return Use-CachedQuota 'no_credentials'
  }
  if (-not $token) { return Use-CachedQuota 'no_credentials' }
  if ($expiresAt) {
    $expiresAtMilliseconds = [int64]0
    if (-not [int64]::TryParse([string]$expiresAt, [ref]$expiresAtMilliseconds)) {
      return Use-CachedQuota 'malformed_credentials'
    }
    if (($expiresAtMilliseconds - [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -lt 60000) {
      return Use-CachedQuota 'token_expired'
    }
  }

  $response = $null
  try {
    $response = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' `
      -Headers @{ Authorization = "Bearer $token" } -Method Get -TimeoutSec 20
  } catch {
    # Deliberately does not surface the exception text: a failed request can echo
    # the Authorization header back in its message.
    $status = $null
    try { $status = [int]$_.Exception.Response.StatusCode } catch {}
    $reason = if ($status -in @(401, 403)) { "token_rejected_$status" }
              elseif ($status -eq 429) { 'rate_limited' }
              elseif ($status) { "http_$status" }
              else { 'failed_local' }
    return Use-CachedQuota $reason
  } finally {
    $token = $null
  }
  if (-not $response) { return Use-CachedQuota 'malformed_response' }

  try {
    if ((-not ($response -is [pscustomobject]) -and -not ($response -is [Collections.IDictionary])) -or
        -not (Test-OutputRecordProperty $response 'five_hour') -or
        -not (Test-OutputRecordProperty $response 'seven_day') -or
        -not (Test-OutputRecordProperty $response 'limits')) {
      return Use-CachedQuota 'malformed_response'
    }

    function ConvertTo-Window($window) {
      if (-not $window) { return $null }
      return [ordered]@{
        utilization = Get-OutputRecordValue $window 'utilization'
        resetsAt    = Get-OutputRecordValue $window 'resets_at'
      }
    }

    $responseLimits = Get-OutputRecordValue $response 'limits'
    if (-not (Test-OutputRecordArray $responseLimits)) {
      return Use-CachedQuota 'malformed_response'
    }
    $limits = @()
    foreach ($limit in $responseLimits) {
      $model = $null
      try { $model = $limit.scope.model.display_name } catch {}
      $limits += [ordered]@{
        kind     = Get-OutputRecordValue $limit 'kind'
        group    = Get-OutputRecordValue $limit 'group'
        percent  = Get-OutputRecordValue $limit 'percent'
        severity = Get-OutputRecordValue $limit 'severity'
        resetsAt = Get-OutputRecordValue $limit 'resets_at'
        isActive = Get-OutputRecordValue $limit 'is_active'
        model    = $model
      }
    }

    $payload = [ordered]@{
      ok       = $true
      reason   = $null
      fiveHour = ConvertTo-Window (Get-OutputRecordValue $response 'five_hour')
      sevenDay = ConvertTo-Window (Get-OutputRecordValue $response 'seven_day')
      limits   = $limits
    }
    $payload = Select-ClaudeQuotaFields $payload
  } catch {
    return Use-CachedQuota 'malformed_response'
  }
  if (-not $payload.ok) { return Use-CachedQuota 'malformed_response' }

  # Quota state only - no credential material reaches this file.
  try {
    [IO.File]::WriteAllText($cachePath, ([ordered]@{
      cachedAt     = [DateTimeOffset]::Now.ToString('o')
      cachedAtUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
      payload      = $payload
    } | ConvertTo-Json -Depth 20 -Compress), (New-Object Text.UTF8Encoding($false)))
  } catch {}

  return $payload
}

function Get-LatestCodexRateLimit {
  $sessions = Join-Path $env:USERPROFILE '.codex\sessions'
  if (-not (Test-Path $sessions)) { return $null }
  $files = Get-ChildItem -LiteralPath $sessions -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 6
  foreach ($file in $files) {
    $limits = Read-LatestRateLimitFromFile $file.FullName
    if ($limits) { return $limits }
  }
  return $null
}

<#
  Reads the Codex provider CC Switch currently has selected.

  Upstream inventory, 2026-08-13: CC Switch keeps its providers in a SQLite file
  and offers no CLI, no export, and no local API to read it back. Windows ships
  `winsqlite3.dll`, so a read-only open needs no new dependency. The database is
  opened read-only and left alone; CC Switch holds no long transaction over the
  providers table, and a busy timeout covers its periodic writes elsewhere.
#>
function Read-CcSwitchCodexProvider {
  $dbPath = Join-Path $env:USERPROFILE '.cc-switch\cc-switch.db'
  if (-not (Test-Path $dbPath)) { return [pscustomobject]@{ ok = $false; reason = 'no_ccswitch' } }

  try {
    if (-not ('AiUsage.WinSqlite' -as [type])) {
      Add-Type -Namespace AiUsage -Name WinSqlite -MemberDefinition @'
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_open_v2", CallingConvention = CallingConvention.Cdecl)]
public static extern int Open(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_busy_timeout", CallingConvention = CallingConvention.Cdecl)]
public static extern int BusyTimeout(IntPtr db, int ms);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_prepare_v2", CallingConvention = CallingConvention.Cdecl)]
public static extern int Prepare(IntPtr db, byte[] sql, int nbyte, out IntPtr stmt, IntPtr tail);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_step", CallingConvention = CallingConvention.Cdecl)]
public static extern int Step(IntPtr stmt);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_bytes", CallingConvention = CallingConvention.Cdecl)]
public static extern int ColumnBytes(IntPtr stmt, int col);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_blob", CallingConvention = CallingConvention.Cdecl)]
public static extern IntPtr ColumnBlob(IntPtr stmt, int col);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_finalize", CallingConvention = CallingConvention.Cdecl)]
public static extern int Close(IntPtr stmt);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_close_v2", CallingConvention = CallingConvention.Cdecl)]
public static extern int Release(IntPtr db);
'@
    }
  } catch {
    return [pscustomobject]@{ ok = $false; reason = 'sqlite_unavailable' }
  }

  $utf8 = New-Object Text.UTF8Encoding($false)
  $db = [IntPtr]::Zero
  $statement = [IntPtr]::Zero
  try {
    if ([AiUsage.WinSqlite]::Open(($utf8.GetBytes($dbPath) + [byte]0), [ref]$db, 1, [IntPtr]::Zero) -ne 0) {
      return [pscustomobject]@{ ok = $false; reason = 'ccswitch_unreadable' }
    }
    [void][AiUsage.WinSqlite]::BusyTimeout($db, 3000)
    $sql = "select id, name, meta, settings_config from providers where app_type='codex' and is_current=1 limit 1"
    if ([AiUsage.WinSqlite]::Prepare($db, ($utf8.GetBytes($sql) + [byte]0), -1, [ref]$statement, [IntPtr]::Zero) -ne 0) {
      return [pscustomobject]@{ ok = $false; reason = 'ccswitch_unreadable' }
    }
    if ([AiUsage.WinSqlite]::Step($statement) -ne 100) {
      return [pscustomobject]@{ ok = $false; reason = 'no_current_provider' }
    }

    $columns = @()
    for ($index = 0; $index -lt 4; $index++) {
      $length = [AiUsage.WinSqlite]::ColumnBytes($statement, $index)
      if ($length -le 0) { $columns += ''; continue }
      $buffer = New-Object byte[] $length
      [Runtime.InteropServices.Marshal]::Copy([AiUsage.WinSqlite]::ColumnBlob($statement, $index), $buffer, 0, $length)
      $columns += [Text.Encoding]::UTF8.GetString($buffer)
    }
    if ([string]::IsNullOrWhiteSpace($columns[0])) {
      return [pscustomobject]@{ ok = $false; reason = 'ccswitch_unreadable' }
    }
    return [pscustomobject]@{
      ok             = $true
      reason         = $null
      id             = $columns[0]
      name           = $columns[1]
      meta           = $columns[2]
      settingsConfig = $columns[3]
    }
  } catch {
    return [pscustomobject]@{ ok = $false; reason = 'ccswitch_unreadable' }
  } finally {
    if ($statement -ne [IntPtr]::Zero) { [void][AiUsage.WinSqlite]::Close($statement) }
    if ($db -ne [IntPtr]::Zero) { [void][AiUsage.WinSqlite]::Release($db) }
  }
}

function Write-TextFileWithRetry([string]$Path, [string]$Value, [int]$Attempts = 8) {
  $encoding = New-Object Text.UTF8Encoding($false)
  for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
    try {
      [IO.File]::WriteAllText($Path, $Value, $encoding)
      return $true
    } catch {
      if ($attempt + 1 -lt $Attempts) { Start-Sleep -Milliseconds (20 * ($attempt + 1)) }
    }
  }
  return $false
}

function Remove-FileWithRetry([string]$Path, [int]$Attempts = 8) {
  for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
    try {
      if (-not (Test-Path -LiteralPath $Path)) { return $true }
      [IO.File]::Delete($Path)
      if (-not (Test-Path -LiteralPath $Path)) { return $true }
    } catch {}
    if ($attempt + 1 -lt $Attempts) { Start-Sleep -Milliseconds (20 * ($attempt + 1)) }
  }
  return $false
}

function Invoke-BoundedJsonRequest {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [Parameter(Mandatory = $true)][ValidateSet('GET', 'HEAD')][string]$Method,
    [Collections.IDictionary]$Headers,
    [ValidateRange(1, 60)][int]$TimeoutSeconds,
    [ValidateRange(1, [int64]::MaxValue)][int64]$MaxBytes = $MaxQuotaResponseBytes,
    [object]$Handler = $null
  )

  Add-Type -AssemblyName System.Net.Http
  $ownsHandler = $null -eq $Handler
  $client = $null
  $message = $null
  $response = $null
  $stream = $null
  $memory = $null
  $cancellation = $null
  try {
    if ($ownsHandler) {
      $Handler = New-Object Net.Http.HttpClientHandler
      $Handler.AllowAutoRedirect = $false
      $Handler.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
    }
    $client = [Net.Http.HttpClient]::new($Handler, $false)
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $httpMethod = if ($Method -eq 'HEAD') { [Net.Http.HttpMethod]::Head } else { [Net.Http.HttpMethod]::Get }
    $message = [Net.Http.HttpRequestMessage]::new($httpMethod, [Uri]$Uri)
    foreach ($name in @($Headers.Keys)) {
      $added = if ([string]$name -ieq 'Content-Type') {
        if ($null -eq $message.Content) {
          $message.Content = [Net.Http.ByteArrayContent]::new([byte[]]@())
        }
        $message.Content.Headers.TryAddWithoutValidation([string]$name, [string]$Headers[$name])
      } else {
        $message.Headers.TryAddWithoutValidation([string]$name, [string]$Headers[$name])
      }
      if (-not $added) {
        return [pscustomobject][ordered]@{ ok = $false; reason = 'failed_local'; status = $null; value = $null }
      }
    }
    $cancellation = [Threading.CancellationTokenSource]::new()
    $cancellation.CancelAfter([TimeSpan]::FromSeconds($TimeoutSeconds))
    $response = $client.SendAsync(
      $message,
      [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
      $cancellation.Token
    ).GetAwaiter().GetResult()
    $status = [int]$response.StatusCode
    if (-not $response.IsSuccessStatusCode) {
      return [pscustomobject][ordered]@{ ok = $false; reason = 'http_error'; status = $status; value = $null }
    }
    $declaredLength = $response.Content.Headers.ContentLength
    if ($null -ne $declaredLength -and [int64]$declaredLength -gt $MaxBytes) {
      return [pscustomobject][ordered]@{ ok = $false; reason = 'response_too_large'; status = $status; value = $null }
    }

    $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $memory = [IO.MemoryStream]::new()
    $buffer = New-Object byte[] 8192
    while ($true) {
      $remaining = $MaxBytes - $memory.Length
      $readSize = [int][Math]::Min([int64]$buffer.Length, $remaining + 1)
      $read = $stream.ReadAsync($buffer, 0, $readSize, $cancellation.Token).GetAwaiter().GetResult()
      if ($read -le 0) { break }
      if (($memory.Length + $read) -gt $MaxBytes) {
        return [pscustomobject][ordered]@{ ok = $false; reason = 'response_too_large'; status = $status; value = $null }
      }
      $memory.Write($buffer, 0, $read)
    }
    try {
      $value = [Text.Encoding]::UTF8.GetString($memory.ToArray()) | ConvertFrom-Json
    } catch {
      return [pscustomobject][ordered]@{ ok = $false; reason = 'malformed_response'; status = $status; value = $null }
    }
    if ($null -eq $value) {
      return [pscustomobject][ordered]@{ ok = $false; reason = 'malformed_response'; status = $status; value = $null }
    }
    return [pscustomobject][ordered]@{ ok = $true; reason = $null; status = $status; value = $value }
  } catch {
    $reason = if ($cancellation -and $cancellation.IsCancellationRequested) { 'request_timed_out' } else { 'failed_local' }
    return [pscustomobject][ordered]@{ ok = $false; reason = $reason; status = $null; value = $null }
  } finally {
    if ($memory) { try { $memory.Dispose() } catch {} }
    if ($stream) { try { $stream.Dispose() } catch {} }
    if ($response) { try { $response.Dispose() } catch {} }
    if ($message) { try { $message.Dispose() } catch {} }
    if ($cancellation) { try { $cancellation.Dispose() } catch {} }
    if ($client) { try { $client.Dispose() } catch {} }
    if ($ownsHandler -and $Handler) { try { $Handler.Dispose() } catch {} }
  }
}

<#
  Real Codex quota for a relay-backed provider, replayed from CC Switch's own
  usage-script declaration. See ReportData.psm1 for why this exists and for the
  rules the replay follows.
#>
function Get-CodexProviderFingerprint($Provider) {
  if (-not $Provider -or -not $Provider.ok) { return $null }
  $hash = $null
  $material = $null
  try {
    $material = @(
      [string]$Provider.id,
      [string]$Provider.name,
      [string]$Provider.meta,
      [string]$Provider.settingsConfig
    ) -join ([char]0)
    $hash = [Security.Cryptography.SHA256]::Create()
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($material)
    return -join @($hash.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
  } catch {
    return $null
  } finally {
    $material = $null
    if ($hash) { $hash.Dispose() }
  }
}

function Get-CodexProviderQuota {
  # Same shape as the Claude quota cache: relaunches are frequent, the endpoint
  # is somebody else's, and a stale-but-labelled card beats an empty one.
  $cachePath = $CodexQuotaCachePath
  $FreshSeconds = 120
  $StaleSeconds = 3600
  $provider = Read-CcSwitchCodexProvider
  $providerFingerprint = Get-CodexProviderFingerprint $provider
  $cached = $null
  try {
    if (Test-Path $cachePath) {
      $raw = [IO.File]::ReadAllText($cachePath) | ConvertFrom-Json
      if (-not ($raw -is [pscustomobject]) -or
          -not (Test-OutputRecordProperty $raw 'cachedAt') -or
          -not (Test-OutputRecordProperty $raw 'cachedAtUnix') -or
          -not (Test-OutputRecordProperty $raw 'providerId') -or
          -not (Test-OutputRecordProperty $raw 'providerFingerprint') -or
          -not (Test-OutputRecordProperty $raw 'payload') -or
          -not (Test-JsonDateValue (Get-OutputRecordValue $raw 'cachedAt')) -or
          -not (Test-JsonInt64Value (Get-OutputRecordValue $raw 'cachedAtUnix')) -or
          -not (Test-JsonNonEmptyStringValue (Get-OutputRecordValue $raw 'providerId')) -or
          ([string](Get-OutputRecordValue $raw 'providerId')).Length -gt 1024 -or
          -not (Test-JsonStringValue (Get-OutputRecordValue $raw 'providerFingerprint')) -or
          [string](Get-OutputRecordValue $raw 'providerFingerprint') -notmatch '\A[0-9a-f]{64}\z') {
        throw 'Malformed Codex quota cache envelope.'
      }
      $safeCachedPayload = Select-CodexQuotaFields (Get-OutputRecordValue $raw 'payload')
      if (-not $safeCachedPayload.ok) { throw 'Malformed Codex quota cache payload.' }
      $age = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$raw.cachedAtUnix)
      if ($age -ge 0 -and $age -lt $StaleSeconds) {
        $cached = [pscustomobject][ordered]@{
          cachedAt = [string]$raw.cachedAt
          cachedAtUnix = [int64]$raw.cachedAtUnix
          providerId = [string]$raw.providerId
          providerFingerprint = [string]$raw.providerFingerprint
          payload = $safeCachedPayload
        }
      }
      if ($provider.ok -and (-not $cached.payload -or -not $providerFingerprint -or
          [string]$cached.providerId -cne [string]$provider.id -or
          [string]$cached.providerFingerprint -cne [string]$providerFingerprint)) {
        $cached = $null
      }
      if ($cached -and $age -lt $FreshSeconds -and $provider.ok) {
        $hit = $cached.payload | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        Add-Member -InputObject $hit -NotePropertyName 'cachedAt' -NotePropertyValue $cached.cachedAt -Force
        $safeHit = Select-CodexQuotaFields $hit
        if ($safeHit.ok) {
          $provider.settingsConfig = $null
          return $safeHit
        }
        $cached = $null
      }
    }
  } catch { $cached = $null }

  function Use-CachedCodexQuota([string]$Reason) {
    if (-not $cached) { return [ordered]@{ ok = $false; reason = $Reason } }
    try {
      $hit = $cached.payload | ConvertTo-Json -Depth 20 | ConvertFrom-Json
      Add-Member -InputObject $hit -NotePropertyName 'cachedAt' -NotePropertyValue $cached.cachedAt -Force
      Add-Member -InputObject $hit -NotePropertyName 'stale' -NotePropertyValue $true -Force
      Add-Member -InputObject $hit -NotePropertyName 'staleReason' -NotePropertyValue $Reason -Force
      $safeHit = Select-CodexQuotaFields $hit
      if (-not $safeHit.ok) { return [ordered]@{ ok = $false; reason = $Reason } }
      return $safeHit
    } catch {
      return [ordered]@{ ok = $false; reason = $Reason }
    }
  }

  if (-not $provider.ok) { return Use-CachedCodexQuota $provider.reason }

  $request = $null
  try {
    $request = Get-CodexUsageRequest -MetaJson $provider.meta -SettingsConfigJson $provider.settingsConfig
  } catch {
    return Use-CachedCodexQuota 'usage_script_unreadable'
  } finally {
    $provider.settingsConfig = $null
  }
  if (-not $request.ok) { return Use-CachedCodexQuota $request.reason }

  $response = $null
  try {
    $httpResult = Invoke-BoundedJsonRequest -Uri $request.url -Headers $request.headers `
      -Method $request.method -TimeoutSeconds $request.timeoutSeconds -MaxBytes $MaxQuotaResponseBytes
    if (-not $httpResult.ok) {
      $status = $httpResult.status
      $reason = if ($status -in @(401, 403)) { "key_rejected_$status" }
                elseif ($status -eq 429) { 'rate_limited' }
                elseif ($status) { "http_$status" }
                else { $httpResult.reason }
      return Use-CachedCodexQuota $reason
    }
    $response = $httpResult.value
  } finally {
    $request = $null
  }
  if (-not $response) { return Use-CachedCodexQuota 'malformed_response' }

  try {
    $payload = Select-CodexQuotaFields (ConvertTo-CodexQuota -Response $response -ProviderName $provider.name)
  } catch {
    return Use-CachedCodexQuota 'malformed_response'
  }
  if (-not $payload.ok) { return Use-CachedCodexQuota $payload.reason }

  # Quota state only - no endpoint and no credential material reaches this file.
  if ($providerFingerprint) {
    try {
      [IO.File]::WriteAllText($cachePath, ([ordered]@{
        cachedAt           = [DateTimeOffset]::Now.ToString('o')
        cachedAtUnix       = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        providerId         = $provider.id
        providerFingerprint = $providerFingerprint
        payload            = $payload
      } | ConvertTo-Json -Depth 20 -Compress), (New-Object Text.UTF8Encoding($false)))
    } catch {}
  }

  return $payload
}

function Initialize-CollectorJobType {
  if ('AiUsage.CollectorJob' -as [type]) { return }
  # COLLECTOR_JOB_CSHARP_BEGIN
  Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace AiUsage {
  public sealed class CollectorJobCleanupException : InvalidOperationException {
    public CollectorJobCleanupException(string message, Exception innerException)
      : base(message, innerException) { }
  }

  public sealed class CollectorProcess : IDisposable {
    const uint WAIT_OBJECT_0 = 0;
    const uint WAIT_TIMEOUT = 258;
    const uint INFINITE = 0xFFFFFFFF;
    const uint DISPOSE_DRAIN_TIMEOUT_MILLISECONDS = 10000;

    IntPtr jobHandle;
    IntPtr processHandle;
    readonly int processId;
    bool disposed;

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION {
      public long TotalUserTime, TotalKernelTime;
      public long ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
      public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool QueryInformationJobObject(
      IntPtr job, int infoClass, out JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info,
      uint length, IntPtr returnLength);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    internal CollectorProcess(IntPtr job, IntPtr process, uint id) {
      jobHandle = job;
      processHandle = process;
      processId = checked((int)id);
    }

    void EnsureOpen() {
      if (disposed || processHandle == IntPtr.Zero) {
        throw new ObjectDisposedException("CollectorProcess");
      }
    }

    bool IsJobEmpty() {
      JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info;
      uint size = (uint)Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
      if (!QueryInformationJobObject(jobHandle, 1, out info, size, IntPtr.Zero)) {
        throw new Win32Exception(Marshal.GetLastWin32Error(), "QueryInformationJobObject failed");
      }
      return info.ActiveProcesses == 0;
    }

    uint Wait(uint milliseconds) {
      EnsureOpen();
      if (jobHandle == IntPtr.Zero) {
        uint processResult = WaitForSingleObject(processHandle, milliseconds);
        if (processResult != WAIT_OBJECT_0 && processResult != WAIT_TIMEOUT) {
          throw new Win32Exception(Marshal.GetLastWin32Error(), "Waiting for the usage collector failed");
        }
        return processResult;
      }

      var stopwatch = Stopwatch.StartNew();
      int emptyObservations = 0;
      while (true) {
        if (IsJobEmpty()) {
          emptyObservations++;
          if (milliseconds == 0 || emptyObservations >= 2) return WAIT_OBJECT_0;
        } else {
          emptyObservations = 0;
        }
        if (milliseconds == 0) return WAIT_TIMEOUT;
        int sleepMilliseconds = 25;
        if (milliseconds != INFINITE) {
          long remaining = (long)milliseconds - stopwatch.ElapsedMilliseconds;
          if (remaining <= 0) return WAIT_TIMEOUT;
          sleepMilliseconds = (int)Math.Min(sleepMilliseconds, remaining);
        }
        Thread.Sleep(Math.Max(1, sleepMilliseconds));
      }
    }

    public int Id { get { return processId; } }

    public bool HasExited { get { return Wait(0) == WAIT_OBJECT_0; } }

    public bool WaitForExit(int timeoutMilliseconds) {
      if (timeoutMilliseconds < -1) throw new ArgumentOutOfRangeException("timeoutMilliseconds");
      uint timeout = timeoutMilliseconds == -1 ? INFINITE : (uint)timeoutMilliseconds;
      return Wait(timeout) == WAIT_OBJECT_0;
    }

    public void WaitForExit() {
      if (Wait(INFINITE) != WAIT_OBJECT_0) {
        throw new InvalidOperationException("The usage collector wait did not complete.");
      }
    }

    public void Refresh() { }

    public int ExitCode {
      get {
        EnsureOpen();
        uint exitCode;
        if (!GetExitCodeProcess(processHandle, out exitCode)) {
          throw new Win32Exception(Marshal.GetLastWin32Error(), "GetExitCodeProcess failed");
        }
        return unchecked((int)exitCode);
      }
    }

  public bool TerminateAndWait(int timeoutMilliseconds) {
    EnsureOpen();
    if (timeoutMilliseconds < -1) throw new ArgumentOutOfRangeException("timeoutMilliseconds");
    bool alreadyExited = HasExited;
    if (jobHandle != IntPtr.Zero && !alreadyExited && !TerminateJobObject(jobHandle, 1)) {
      throw new Win32Exception(Marshal.GetLastWin32Error(), "TerminateJobObject failed");
    }
    uint timeout = timeoutMilliseconds == -1 ? INFINITE : checked((uint)timeoutMilliseconds);
    uint result = Wait(timeout);
    return result == WAIT_OBJECT_0 && HasExited;
  }

    public void Dispose() {
      if (disposed) return;
      Exception cleanupFailure = null;
      try {
        if (jobHandle != IntPtr.Zero) {
          try {
            if (!IsJobEmpty()) {
              if (!TerminateJobObject(jobHandle, 1)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "TerminateJobObject failed during disposal");
              }
              if (Wait(DISPOSE_DRAIN_TIMEOUT_MILLISECONDS) != WAIT_OBJECT_0 || !HasExited) {
                throw new InvalidOperationException("The usage collector Job did not become empty within the disposal deadline.");
              }
            }
          } catch (Exception error) {
            cleanupFailure = error;
          }
        }
      } finally {
        if (jobHandle != IntPtr.Zero) {
          if (!CloseHandle(jobHandle) && cleanupFailure == null) {
            cleanupFailure = new Win32Exception(Marshal.GetLastWin32Error(), "Closing the usage collector Job failed");
          }
          jobHandle = IntPtr.Zero;
        }
        if (processHandle != IntPtr.Zero) {
          if (!CloseHandle(processHandle) && cleanupFailure == null) {
            cleanupFailure = new Win32Exception(Marshal.GetLastWin32Error(), "Closing the usage collector process failed");
          }
          processHandle = IntPtr.Zero;
        }
        disposed = true;
        GC.SuppressFinalize(this);
      }
      if (cleanupFailure != null) {
        throw new InvalidOperationException("The usage collector cleanup could not be verified.", cleanupFailure);
      }
    }

    ~CollectorProcess() {
      if (jobHandle != IntPtr.Zero) CloseHandle(jobHandle);
      if (processHandle != IntPtr.Zero) CloseHandle(processHandle);
    }
  }

  public static class CollectorJob {
    const uint CREATE_NO_WINDOW = 0x08000000;
    const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
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
        int remaining = timeoutMilliseconds - checked((int)Math.Min(int.MaxValue, stopwatch.ElapsedMilliseconds));
        if (remaining <= 0) return false;
        Thread.Sleep(Math.Min(25, remaining));
      }
    }

    static IntPtr BuildEnvironmentBlock(string[] names, string[] values) {
      if (names == null || values == null || names.Length != values.Length) {
        throw new ArgumentException("Environment override arrays must have the same length.");
      }
      var environment = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
      foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables()) {
        string key = entry.Key as string;
        string value = entry.Value as string;
        if (key != null && value != null) environment[key] = value;
      }
      for (int index = 0; index < names.Length; index++) {
        if (String.IsNullOrEmpty(names[index]) || names[index].IndexOf('=') >= 0 || values[index] == null) {
          throw new ArgumentException("Invalid environment override.");
        }
        environment[names[index]] = values[index];
      }

      var block = new StringBuilder();
      foreach (KeyValuePair<string, string> pair in environment) {
        block.Append(pair.Key).Append('=').Append(pair.Value).Append('\0');
      }
      if (environment.Count == 0) block.Append('\0');
      block.Append('\0');
      byte[] bytes = Encoding.Unicode.GetBytes(block.ToString());
      IntPtr pointer = Marshal.AllocHGlobal(bytes.Length);
      Marshal.Copy(bytes, 0, pointer, bytes.Length);
      return pointer;
    }

    public static CollectorProcess Start(
        string applicationName, string commandLine, string workingDirectory,
        string[] environmentNames, string[] environmentValues) {
      IntPtr job = IntPtr.Zero;
      IntPtr infoPointer = IntPtr.Zero;
      IntPtr attributeList = IntPtr.Zero;
      IntPtr jobListValue = IntPtr.Zero;
      IntPtr environment = IntPtr.Zero;
      bool attributeListInitialized = false;
      PROCESS_INFORMATION process = new PROCESS_INFORMATION();
      bool ownershipTransferred = false;
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

        environment = BuildEnvironmentBlock(environmentNames, environmentValues);
        var startup = new STARTUPINFOEX();
        startup.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        startup.lpAttributeList = attributeList;
        var mutableCommand = new StringBuilder(commandLine);
        uint flags = CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT;
        if (!CreateProcess(applicationName, mutableCommand, IntPtr.Zero, IntPtr.Zero, false,
            flags, environment, workingDirectory, ref startup, out process)) {
          Win32("CreateProcess");
        }
        processCreated = true;
        bool inJob;
        if (!IsProcessInJob(process.hProcess, job, out inJob)) Win32("IsProcessInJob");
        if (!inJob) throw new InvalidOperationException("The usage collector was not created in its Job Object.");
        membershipVerified = true;

        if (process.hThread != IntPtr.Zero) {
          if (!CloseHandle(process.hThread)) Win32("CloseHandle(thread)");
          process.hThread = IntPtr.Zero;
        }

        var result = new CollectorProcess(job, process.hProcess, process.dwProcessId);
        ownershipTransferred = true;
        job = IntPtr.Zero;
        process.hProcess = IntPtr.Zero;
        return result;
      } catch (Exception error) {
        operationFailure = error;
        throw;
      } finally {
        Exception cleanupFailure = null;
        if (!ownershipTransferred && processCreated && process.hProcess != IntPtr.Zero) {
          try {
            uint rootState = WaitForSingleObject(process.hProcess, 0);
            if (rootState == WAIT_TIMEOUT) {
              if (!TerminateProcess(process.hProcess, 1)) Win32("TerminateProcess");
            } else if (rootState != WAIT_OBJECT_0) {
              Win32("WaitForSingleObject");
            }
          } catch (Exception error) { cleanupFailure = CombineFailure(cleanupFailure, error); }
        }
        if (!ownershipTransferred && processCreated && job != IntPtr.Zero) {
          try {
            if (!TerminateJobObject(job, 1)) Win32("TerminateJobObject");
          } catch (Exception error) { cleanupFailure = CombineFailure(cleanupFailure, error); }
        }
        if (!ownershipTransferred && processCreated && process.hProcess != IntPtr.Zero) {
          try {
            if (WaitForSingleObject(process.hProcess, 10000) != WAIT_OBJECT_0) {
              throw new InvalidOperationException("The failed usage collector root process did not exit.");
            }
          } catch (Exception error) { cleanupFailure = CombineFailure(cleanupFailure, error); }
        }
        if (!ownershipTransferred && processCreated && job != IntPtr.Zero) {
          try {
            if (!WaitForJobEmpty(job, 10000)) {
              throw new InvalidOperationException("The failed usage collector Job did not become empty.");
            }
          } catch (Exception error) { cleanupFailure = CombineFailure(cleanupFailure, error); }
        }
        if (processCreated && !membershipVerified) {
          cleanupFailure = CombineFailure(
            cleanupFailure,
            new InvalidOperationException("The failed usage collector Job membership could not be verified.")
          );
        }
        if (process.hThread != IntPtr.Zero) {
          if (!CloseHandle(process.hThread)) {
            cleanupFailure = CombineFailure(
              cleanupFailure,
              new Win32Exception(Marshal.GetLastWin32Error(), "Closing the usage collector thread failed")
            );
          }
          process.hThread = IntPtr.Zero;
        }
        if (process.hProcess != IntPtr.Zero) {
          if (!CloseHandle(process.hProcess)) {
            cleanupFailure = CombineFailure(
              cleanupFailure,
              new Win32Exception(Marshal.GetLastWin32Error(), "Closing the usage collector process failed")
            );
          }
          process.hProcess = IntPtr.Zero;
        }
        if (attributeListInitialized) DeleteProcThreadAttributeList(attributeList);
        if (attributeList != IntPtr.Zero) Marshal.FreeHGlobal(attributeList);
        if (jobListValue != IntPtr.Zero) Marshal.FreeHGlobal(jobListValue);
        if (environment != IntPtr.Zero) Marshal.FreeHGlobal(environment);
        if (infoPointer != IntPtr.Zero) Marshal.FreeHGlobal(infoPointer);
        if (job != IntPtr.Zero) {
          if (!CloseHandle(job)) {
            cleanupFailure = CombineFailure(
              cleanupFailure,
              new Win32Exception(Marshal.GetLastWin32Error(), "Closing the usage collector Job failed")
            );
          }
          job = IntPtr.Zero;
        }
        if (cleanupFailure != null) {
          Exception detail = operationFailure == null
            ? cleanupFailure
            : new AggregateException(operationFailure, cleanupFailure);
          throw new CollectorJobCleanupException(
            "The usage collector startup cleanup could not be verified.", detail
          );
        }
      }
    }
  }
}
'@
  # COLLECTOR_JOB_CSHARP_END
}

function Get-DescendantProcessIds([int]$RootProcessId) {
  try {
    $rows = @(Get-CimInstance Win32_Process -ErrorAction Stop |
      Select-Object @{ Name = 'Id'; Expression = { [int]$_.ProcessId } },
                    @{ Name = 'ParentId'; Expression = { [int]$_.ParentProcessId } })
    $pending = New-Object Collections.Generic.Queue[int]
    $pending.Enqueue($RootProcessId)
    $found = New-Object Collections.Generic.List[int]
    while ($pending.Count) {
      $parent = $pending.Dequeue()
      foreach ($row in @($rows | Where-Object { $_.ParentId -eq $parent })) {
        if ($found.Contains($row.Id)) { continue }
        $found.Add($row.Id)
        $pending.Enqueue($row.Id)
      }
    }
    return @($found)
  } catch {
    return @()
  }
}

function Stop-ProcessTree($Process) {
  if (-not $Process) { return $true }
  if ($Process.PSObject.Methods.Name -contains 'TerminateAndWait') {
    try { return $Process.TerminateAndWait(10000) } catch { return $false }
  }
  $ids = @([int]$Process.Id) + @(Get-DescendantProcessIds ([int]$Process.Id))
  $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
  try { & $taskkill /PID $Process.Id /T /F 2>$null | Out-Null } catch {}

  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  do {
    $alive = @($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if (-not $alive.Count) { return $true }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  return $false
}

function Close-CollectorProcess($Process) {
  if (-not $Process) { return }
  $cleanupVerified = $true
  try {
    if (-not $Process.HasExited -and -not (Stop-ProcessTree $Process)) { $cleanupVerified = $false }
  } catch {
    $cleanupVerified = $false
  }
  try { $Process.Dispose() } catch { $cleanupVerified = $false }
  if (-not $cleanupVerified) { $script:CollectorCleanupUncertain = $true }
}

function Set-CollectorCleanupRequiredFromError($ErrorRecord) {
  $exception = $ErrorRecord.Exception
  while ($exception) {
    if ($exception.GetType().FullName -eq 'AiUsage.CollectorJobCleanupException') {
      $script:CollectorCleanupUncertain = $true
      return
    }
    $exception = $exception.InnerException
  }
}

function Assert-CollectorCleanupVerified {
  if ($script:CollectorCleanupUncertain) {
    throw 'Collector cleanup remains unverified; refusing to start another collector.'
  }
}

function Test-UsageCollectorProcess([string]$Name, [string]$CommandLine) {
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
    $hasCommandLine = -not [string]::IsNullOrWhiteSpace($commandLine)
    if ($name -notin @('cmd.exe', 'node.exe', 'powershell.exe', 'pwsh.exe', 'codeburn.exe', 'ccusage.exe') -or
        ($hasCommandLine -and -not (Test-UsageCollectorProcess $name $commandLine))) { continue }
    $ownerState = 'Unknown'
    try {
      $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -OperationTimeoutSec 2 -ErrorAction Stop
      if ([int]$owner.ReturnValue -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$owner.Sid)) {
        $ownerState = if ([string]$owner.Sid -eq $UserSid) { 'Same' } else { 'Other' }
      }
    } catch {}
    if ($ownerState -eq 'Other') { continue }
    if (-not $hasCommandLine -and $ownerState -ne 'Same' -and
        $name -notin @('codeburn.exe', 'ccusage.exe')) { continue }
    if ($ownerState -eq 'Unknown' -and
        -not (Get-Process -Id ([int]$process.ProcessId) -ErrorAction SilentlyContinue)) { continue }
    $matches += [pscustomobject]@{
      ProcessId = [int]$process.ProcessId
      Name = $name
      OwnerState = $ownerState
    }
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
  throw "A collector from an abandoned report did not exit within two minutes: $summary."
}

function Wait-ChildProcess(
  $Process,
  [int]$TimeoutMilliseconds,
  [string]$OutputPath = '',
  [int64]$MaxOutputBytes = 0,
  [scriptblock]$Heartbeat = $null
) {
  $deadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Max(0, $TimeoutMilliseconds))
  do {
    $remaining = [int][Math]::Max(0, [Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalMilliseconds))
    $slice = if ($TimeoutMilliseconds -le 0) { 0 } else { [Math]::Min(100, $remaining) }
    $exited = $false
    try { $exited = $Process.WaitForExit($slice) } catch {}
    if ($Heartbeat) {
      try { & $Heartbeat } catch {}
      Assert-CollectorCleanupVerified
    }

    if ($MaxOutputBytes -gt 0 -and -not [string]::IsNullOrWhiteSpace($OutputPath)) {
      try {
        $outputFile = [IO.FileInfo]::new($OutputPath)
        if ($outputFile.Exists -and $outputFile.Length -gt $MaxOutputBytes) {
          if (-not (Stop-ProcessTree $Process)) {
            throw 'An oversized child process could not be terminated safely.'
          }
          throw "Collector output exceeded the $MaxOutputBytes byte limit."
        }
      } catch {
        if ($_.Exception.Message -match 'Collector output exceeded|oversized child process') { throw }
      }
    }

    if ($exited) {
      try {
        $Process.WaitForExit()
        $Process.Refresh()
        $rawExitCode = $Process.ExitCode
        if ($null -eq $rawExitCode) { return $null }
        return [int]$rawExitCode
      } catch { return $null }
    }
    if ($TimeoutMilliseconds -le 0) { break }
  } while ([DateTime]::UtcNow -lt $deadline)

  if (-not (Stop-ProcessTree $Process)) {
    throw 'A timed-out child process could not be terminated safely.'
  }
  return $null
}

function Start-JsonCommand([string]$CommandPath, [string[]]$Arguments, [string]$OutputPath) {
  Assert-CollectorCleanupVerified
  foreach ($value in @($CommandPath, $Arguments, $OutputPath)) {
    if ($value -match '[\r\n"]') { throw 'Refusing an unsafe command path or argument.' }
  }

  # PowerShell 5.1 can return a .cmd Process object whose ExitCode is null after
  # output redirection. Own cmd.exe through ProcessStartInfo so success and
  # failure remain distinguishable before any JSON is trusted. Values travel in
  # the child environment so cmd.exe does not expand percent pairs in a valid path.
  Initialize-CollectorJobType
  $commandInterpreter = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $environmentNames = New-Object Collections.Generic.List[string]
  $environmentValues = New-Object Collections.Generic.List[string]
  $environmentNames.Add('AI_USAGE_COLLECTOR_COMMAND')
  $environmentValues.Add($CommandPath)
  $environmentNames.Add('AI_USAGE_COLLECTOR_OUTPUT')
  $environmentValues.Add($OutputPath)
  $commandLine = '"set "AI_USAGE_COLLECTOR_JOB=1" & "%AI_USAGE_COLLECTOR_COMMAND%"'
  for ($index = 0; $index -lt $Arguments.Count; $index++) {
    $variableName = 'AI_USAGE_COLLECTOR_ARG_' + $index
    $environmentNames.Add($variableName)
    $environmentValues.Add($Arguments[$index])
    $commandLine += ' "%' + $variableName + '%"'
  }
  $commandLine += ' > "%AI_USAGE_COLLECTOR_OUTPUT%""'
  $fullCommandLine = '"' + $commandInterpreter + '" /d /v:off /s /c ' + $commandLine
  try {
    return [AiUsage.CollectorJob]::Start(
      $commandInterpreter,
      $fullCommandLine,
      $PSScriptRoot,
      $environmentNames.ToArray(),
      $environmentValues.ToArray()
    )
  } catch {
    Set-CollectorCleanupRequiredFromError $_
    throw
  }
}

function Start-OptionalJsonCommand([string]$CommandPath, [string[]]$Arguments, [string]$OutputPath) {
  try {
    return Start-JsonCommand $CommandPath $Arguments $OutputPath
  } catch {
    # Optional collectors enrich an already-valid report. A process creation
    # failure must not bypass the required CodeBurn failure/snapshot path.
    [void](Remove-FileWithRetry $OutputPath)
    Assert-CollectorCleanupVerified
    return $null
  }
}

function Invoke-CodeBurnJson([string[]]$Arguments, [string]$Output, [string]$Label) {
  if (-not (Remove-FileWithRetry $Output)) {
    throw "Could not remove stale collector output for $Label."
  }
  $run = $null
  $succeeded = $false
  try {
    $run = Start-JsonCommand $CodeBurn $Arguments $Output
    $exitCode = Wait-ChildProcess $run 120000 $Output $MaxCollectorOutputBytes { Receive-BlocksIfReady }
    if ($null -eq $exitCode) { throw "CodeBurn timed out while building $Label." }
    if ($exitCode -ne 0) { throw ("CodeBurn failed for {0} with exit code {1}." -f $Label, $exitCode) }
    $succeeded = $true
  } finally {
    if ($run) {
      Close-CollectorProcess $run
    }
    if (-not $succeeded) {
      [void](Remove-FileWithRetry $Output)
    }
    Assert-CollectorCleanupVerified
  }
}

$RunMutex = $null
$RunMutexHeld = $false
$RunMutexAbandoned = $false
$LegacyRunMutex = $null
$LegacyRunMutexHeld = $false
$LegacyRunMutexAbandoned = $false
$FailureEvent = $null
$RunCompleted = $false
$PreserveFinal = $RetainedRun
$blocksOutput = Join-Path $OutDir '_claude-blocks.json'
$temporaryData = "$OutData.tmp"
$backupData = "$OutData.bak"
$temporaryFailure = "$OutFailure.tmp"
$backupFailure = "$OutFailure.bak"
$blocksJob = $null
$blocksDeadlineUtc = $null
$script:CollectorCleanupUncertain = $false
$scratch = @{}
$RunId = [guid]::NewGuid().ToString('N')
$OwnerProcess = Get-Process -Id $PID -ErrorAction Stop
$OwnerProcessStartUtcTicks = [string]$OwnerProcess.StartTime.ToUniversalTime().Ticks
$Revision = 0
$reports = [ordered]@{}
$claudeBlocks = $null
$codexLimits = $null
$claudeQuota = [ordered]@{ ok = $false; reason = 'loading' }
$codexQuota = [ordered]@{ ok = $false; reason = 'loading' }
$GenerationError = $null
$GenerationStage = 'startup'
$GenerationFailed = $false
$HasPublishedSnapshot = $false
$ReadGraceObserved = $false
$CanDeleteFinal = $true
$PageLaunched = $false
$CleanupFailures = New-Object Collections.Generic.List[string]
$PeriodKeys = @($Period)
foreach ($candidate in @('week', '30days', 'all')) {
  if ($PeriodKeys -notcontains $candidate) { $PeriodKeys += $candidate }
}

$KeepFields = @(
  'currency', 'overview', 'daily', 'models', 'projects', 'topSessions'
)

function Test-OutputRecordProperty($Record, [string]$Name) {
  if ($null -eq $Record) { return $false }
  if ($Record -is [Collections.IDictionary]) { return $Record.Contains($Name) }
  foreach ($property in $Record.PSObject.Properties) {
    if ($property.Name -eq $Name) { return $true }
  }
  return $false
}

function Get-OutputRecordValue($Record, [string]$Name) {
  if (-not (Test-OutputRecordProperty $Record $Name)) { return $null }
  if ($Record -is [Collections.IDictionary]) {
    $value = $Record[$Name]
  } else {
    $value = $Record.$Name
  }
  # Function output normally enumerates arrays; preserve [] so a valid empty
  # collector array cannot become indistinguishable from JSON null.
  Write-Output -NoEnumerate $value
}

function Select-TypedOutputRecord {
  [CmdletBinding()]
  param(
    $Record,
    [string[]]$RequiredNumbers = @(),
    [string[]]$OptionalNumbers = @(),
    [string[]]$RequiredNullableNumbers = @(),
    [string[]]$OptionalNullableNumbers = @(),
    [string[]]$OptionalNullableFiniteNumbers = @(),
    [string[]]$RequiredInt64s = @(),
    [string[]]$OptionalInt64s = @(),
    [string[]]$RequiredStrings = @(),
    [string[]]$OptionalStrings = @(),
    [string[]]$RequiredNullableStrings = @(),
    [string[]]$OptionalNullableStrings = @(),
    [string[]]$RequiredNonEmptyStrings = @(),
    [string[]]$OptionalNonEmptyStrings = @(),
    [string[]]$RequiredBooleans = @(),
    [string[]]$OptionalBooleans = @(),
    [string[]]$OptionalNullableBooleans = @(),
    [string[]]$RequiredDates = @(),
    [string[]]$OptionalDates = @(),
    [string[]]$RequiredNullableDates = @(),
    [string[]]$OptionalNullableDates = @(),
    [string[]]$RequiredCalendarDates = @(),
    [string[]]$RequiredNullableCalendarDates = @(),
    [string[]]$RequiredPercents = @(),
    [string[]]$OptionalPercents = @(),
    [string[]]$RequiredNullablePercents = @(),
    [string[]]$OptionalNullablePercents = @()
  )

  if (-not ($Record -is [Collections.IDictionary]) -and -not ($Record -is [pscustomobject])) {
    return $null
  }
  $safe = [ordered]@{}

  function Copy-Fields([string[]]$Names, [bool]$Required, [bool]$AllowNull, [scriptblock]$Validator) {
    foreach ($name in $Names) {
      if (-not (Test-OutputRecordProperty $Record $name)) {
        if ($Required) { return $false }
        continue
      }
      $value = Get-OutputRecordValue $Record $name
      if ($null -eq $value) {
        if (-not $AllowNull) { return $false }
        [void]$safe.Add($name, $null)
        continue
      }
      if (-not (& $Validator $value)) { return $false }
      [void]$safe.Add($name, $value)
    }
    return $true
  }

  $number = { param($value) Test-JsonNumberValue $value }
  $finiteNumber = { param($value) Test-JsonFiniteNumberValue $value }
  $int64 = { param($value) Test-JsonInt64Value $value }
  $string = { param($value) Test-JsonStringValue $value }
  $nonEmptyString = { param($value) Test-JsonNonEmptyStringValue $value }
  $boolean = { param($value) Test-JsonBooleanValue $value }
  $date = { param($value) Test-JsonDateValue $value }
  $calendarDate = { param($value) Test-IsoCalendarDate $value }
  $percent = { param($value) Test-JsonPercentValue $value }

  if (-not (Copy-Fields $RequiredNumbers $true $false $number) -or
      -not (Copy-Fields $OptionalNumbers $false $false $number) -or
      -not (Copy-Fields $RequiredNullableNumbers $true $true $number) -or
      -not (Copy-Fields $OptionalNullableNumbers $false $true $number) -or
      -not (Copy-Fields $OptionalNullableFiniteNumbers $false $true $finiteNumber) -or
      -not (Copy-Fields $RequiredInt64s $true $false $int64) -or
      -not (Copy-Fields $OptionalInt64s $false $false $int64) -or
      -not (Copy-Fields $RequiredStrings $true $false $string) -or
      -not (Copy-Fields $OptionalStrings $false $false $string) -or
      -not (Copy-Fields $RequiredNullableStrings $true $true $string) -or
      -not (Copy-Fields $OptionalNullableStrings $false $true $string) -or
      -not (Copy-Fields $RequiredNonEmptyStrings $true $false $nonEmptyString) -or
      -not (Copy-Fields $OptionalNonEmptyStrings $false $false $nonEmptyString) -or
      -not (Copy-Fields $RequiredBooleans $true $false $boolean) -or
      -not (Copy-Fields $OptionalBooleans $false $false $boolean) -or
      -not (Copy-Fields $OptionalNullableBooleans $false $true $boolean) -or
      -not (Copy-Fields $RequiredDates $true $false $date) -or
      -not (Copy-Fields $OptionalDates $false $false $date) -or
      -not (Copy-Fields $RequiredNullableDates $true $true $date) -or
      -not (Copy-Fields $OptionalNullableDates $false $true $date) -or
      -not (Copy-Fields $RequiredCalendarDates $true $false $calendarDate) -or
      -not (Copy-Fields $RequiredNullableCalendarDates $true $true $calendarDate) -or
      -not (Copy-Fields $RequiredPercents $true $false $percent) -or
      -not (Copy-Fields $OptionalPercents $false $false $percent) -or
      -not (Copy-Fields $RequiredNullablePercents $true $true $percent) -or
      -not (Copy-Fields $OptionalNullablePercents $false $true $percent)) {
    return $null
  }
  return [pscustomobject]$safe
}

function Select-ReportFields($Report) {
  if (-not ($Report -is [pscustomobject]) -or
      -not ($Report.currency -is [string]) -or
      $Report.currency -notmatch '\A[A-Za-z]{3}\z' -or
      -not (Test-JsonRecordArray $Report.daily) -or
      -not (Test-JsonRecordArray $Report.models) -or
      -not (Test-JsonRecordArray $Report.projects) -or
      -not (Test-JsonRecordArray $Report.topSessions)) { return $null }

  $overview = Select-TypedOutputRecord -Record $Report.overview `
    -RequiredNumbers @('cost', 'netCost', 'savings', 'estimatedCost') `
    -RequiredInt64s @('calls', 'sessions') `
    -RequiredPercents @('cacheHitPercent')
  if ($null -eq $overview) { return $null }
  $tokens = Select-TypedOutputRecord -Record $Report.overview.tokens `
    -RequiredInt64s @('input', 'output', 'cacheRead', 'cacheWrite')
  if ($null -eq $tokens) { return $null }
  Add-Member -InputObject $overview -NotePropertyName 'tokens' -NotePropertyValue $tokens -Force

  $daily = New-Object Collections.Generic.List[object]
  foreach ($row in $Report.daily) {
    $safeRow = Select-TypedOutputRecord -Record $row `
      -RequiredNumbers @('cost', 'savings') `
      -RequiredInt64s @('calls', 'turns', 'editTurns', 'oneShotTurns') `
      -RequiredCalendarDates @('date') `
      -RequiredNullablePercents @('oneShotRate')
    if ($null -eq $safeRow) { return $null }
    $daily.Add($safeRow)
  }

  $models = New-Object Collections.Generic.List[object]
  foreach ($row in $Report.models) {
    $safeRow = Select-TypedOutputRecord -Record $row `
      -RequiredNumbers @('cost', 'savings', 'estimatedCost') `
      -RequiredInt64s @('calls', 'inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens') `
      -RequiredNonEmptyStrings @('name') `
      -OptionalNonEmptyStrings @('kind', 'costSource') `
      -OptionalBooleans @('tokensPartial')
    if ($null -eq $safeRow) { return $null }
    $models.Add($safeRow)
  }

  $projects = New-Object Collections.Generic.List[object]
  foreach ($row in $Report.projects) {
    $safeRow = Select-TypedOutputRecord -Record $row `
      -RequiredNumbers @('cost', 'savings') `
      -RequiredNullableNumbers @('avgCostPerSession') `
      -RequiredInt64s @('calls', 'sessions') `
      -RequiredNonEmptyStrings @('name', 'path')
    if ($null -eq $safeRow) { return $null }
    $projects.Add($safeRow)
  }

  $topSessions = New-Object Collections.Generic.List[object]
  foreach ($row in $Report.topSessions) {
    $safeRow = Select-TypedOutputRecord -Record $row `
      -RequiredNumbers @('cost', 'savings') `
      -RequiredInt64s @('calls') `
      -RequiredNonEmptyStrings @('sessionId', 'project') `
      -RequiredNullableCalendarDates @('date')
    if ($null -eq $safeRow) { return $null }
    $topSessions.Add($safeRow)
  }

  return [pscustomobject][ordered]@{
    currency = $Report.currency
    overview = $overview
    daily = $daily.ToArray()
    models = $models.ToArray()
    projects = $projects.ToArray()
    topSessions = $topSessions.ToArray()
  }
}

function New-MalformedQuotaState {
  return [pscustomobject][ordered]@{ ok = $false; reason = 'malformed_response' }
}

function Test-OutputReasonCode($Value) {
  return $null -eq $Value -or ($Value -is [string] -and $Value -match '\A[a-z0-9_]+\z')
}

function Select-ClaudeQuotaFields($Quota) {
  $safe = Select-TypedOutputRecord -Record $Quota `
    -RequiredBooleans @('ok') `
    -OptionalNullableStrings @('reason') `
    -OptionalDates @('cachedAt') `
    -OptionalBooleans @('stale') `
    -OptionalStrings @('staleReason')
  if ($null -eq $safe -or
      -not (Test-OutputReasonCode (Get-OutputRecordValue $safe 'reason')) -or
      -not (Test-OutputReasonCode (Get-OutputRecordValue $safe 'staleReason'))) {
    return New-MalformedQuotaState
  }

  foreach ($windowName in @('fiveHour', 'sevenDay')) {
    if (-not (Test-OutputRecordProperty $Quota $windowName)) { continue }
    $window = Get-OutputRecordValue $Quota $windowName
    if ($null -eq $window) {
      Add-Member -InputObject $safe -NotePropertyName $windowName -NotePropertyValue $null -Force
      continue
    }
    $safeWindow = Select-TypedOutputRecord -Record $window `
      -RequiredPercents @('utilization') `
      -RequiredNullableDates @('resetsAt')
    if ($null -eq $safeWindow) { return New-MalformedQuotaState }
    Add-Member -InputObject $safe -NotePropertyName $windowName -NotePropertyValue $safeWindow -Force
  }

  if (Test-OutputRecordProperty $Quota 'limits') {
    $limits = Get-OutputRecordValue $Quota 'limits'
    if (-not (Test-OutputRecordArray $limits)) { return New-MalformedQuotaState }
    $safeLimits = New-Object Collections.Generic.List[object]
    foreach ($limit in $limits) {
      $safeLimit = Select-TypedOutputRecord -Record $limit `
        -RequiredNonEmptyStrings @('kind') `
        -OptionalNullableStrings @('group', 'severity', 'model') `
        -RequiredNullablePercents @('percent') `
        -OptionalNullableDates @('resetsAt') `
        -OptionalNullableBooleans @('isActive')
      if ($null -eq $safeLimit) { return New-MalformedQuotaState }
      if ($safeLimit.kind.Length -gt 64 -or $safeLimit.kind -notmatch '\A[a-z0-9_]+\z') {
        return New-MalformedQuotaState
      }
      foreach ($textField in @('group', 'severity', 'model')) {
        $textValue = Get-OutputRecordValue $safeLimit $textField
        if ($null -ne $textValue -and $textValue.Length -gt 1024) { return New-MalformedQuotaState }
      }
      $safeLimits.Add($safeLimit)
    }
    Add-Member -InputObject $safe -NotePropertyName 'limits' -NotePropertyValue $safeLimits.ToArray() -Force
  }
  if ($safe.ok) {
    foreach ($requiredField in @('reason', 'fiveHour', 'sevenDay', 'limits')) {
      if (-not (Test-OutputRecordProperty $safe $requiredField)) { return New-MalformedQuotaState }
    }
    if ($null -ne $safe.reason) { return New-MalformedQuotaState }
  } elseif (-not (Test-OutputRecordProperty $safe 'reason') -or $null -eq $safe.reason) {
    return New-MalformedQuotaState
  }
  return $safe
}

function Select-CodexQuotaFields($Quota) {
  $safe = Select-TypedOutputRecord -Record $Quota `
    -RequiredBooleans @('ok') `
    -OptionalNullableStrings @('reason', 'provider', 'planName', 'mode', 'unit') `
    -OptionalBooleans @('isValid', 'stale') `
    -OptionalNullableFiniteNumbers @('remaining') `
    -OptionalNullableDates @('expiresAt') `
    -OptionalDates @('cachedAt') `
    -OptionalStrings @('staleReason')
  if ($null -eq $safe -or
      -not (Test-OutputReasonCode (Get-OutputRecordValue $safe 'reason')) -or
      -not (Test-OutputReasonCode (Get-OutputRecordValue $safe 'staleReason'))) {
    return New-MalformedQuotaState
  }
  foreach ($textLimit in @(
    @{ name = 'provider'; max = 1024 }, @{ name = 'planName'; max = 1024 },
    @{ name = 'mode'; max = 128 }, @{ name = 'unit'; max = 16 }
  )) {
    $textValue = Get-OutputRecordValue $safe $textLimit.name
    if ($null -ne $textValue -and $textValue.Length -gt $textLimit.max) {
      return New-MalformedQuotaState
    }
  }

  if (Test-OutputRecordProperty $Quota 'windows') {
    $windows = Get-OutputRecordValue $Quota 'windows'
    if (-not (Test-OutputRecordArray $windows)) { return New-MalformedQuotaState }
    $safeWindows = New-Object Collections.Generic.List[object]
    foreach ($window in $windows) {
      $safeWindow = Select-TypedOutputRecord -Record $window `
        -RequiredNumbers @('limit', 'used') `
        -RequiredNullablePercents @('percent') `
        -RequiredNonEmptyStrings @('kind') `
        -RequiredNullableDates @('startsAt', 'resetsAt')
      if ($null -eq $safeWindow) { return New-MalformedQuotaState }
      if ($safeWindow.kind -notin @('weekly', 'daily', 'monthly')) {
        return New-MalformedQuotaState
      }
      $safeWindows.Add($safeWindow)
    }
    Add-Member -InputObject $safe -NotePropertyName 'windows' -NotePropertyValue $safeWindows.ToArray() -Force
  }
  if ($safe.ok) {
    foreach ($requiredField in @(
      'reason', 'provider', 'planName', 'mode', 'isValid', 'unit',
      'remaining', 'expiresAt', 'windows'
    )) {
      if (-not (Test-OutputRecordProperty $safe $requiredField)) { return New-MalformedQuotaState }
    }
    if ($null -ne $safe.reason) { return New-MalformedQuotaState }
  } elseif (-not (Test-OutputRecordProperty $safe 'reason') -or $null -eq $safe.reason) {
    return New-MalformedQuotaState
  }
  return $safe
}

function Select-CodexRateLimits($Limits) {
  if ($null -eq $Limits -or
      (-not ($Limits -is [Collections.IDictionary]) -and -not ($Limits -is [pscustomobject]))) {
    return $null
  }
  $safe = [ordered]@{}
  foreach ($windowName in @('primary', 'secondary')) {
    if (-not (Test-OutputRecordProperty $Limits $windowName)) { continue }
    $window = Get-OutputRecordValue $Limits $windowName
    if ($null -eq $window) { continue }
    $safeWindow = Select-TypedOutputRecord -Record $window `
      -RequiredPercents @('used_percent')
    if ($null -eq $safeWindow) { return $null }
    if (Test-OutputRecordProperty $window 'resets_at') {
      $resetsAt = Get-OutputRecordValue $window 'resets_at'
      if ($null -eq $resetsAt) {
        Add-Member -InputObject $safeWindow -NotePropertyName 'resets_at' -NotePropertyValue $null -Force
      } elseif (Test-JsonInt64Value $resetsAt) {
        try {
          $resetIso = [DateTimeOffset]::FromUnixTimeSeconds([int64]$resetsAt).ToString('o')
          Add-Member -InputObject $safeWindow -NotePropertyName 'resets_at' -NotePropertyValue $resetIso -Force
        } catch {
          return $null
        }
      } else {
        return $null
      }
    }
    $safe[$windowName] = $safeWindow
  }
  if (-not $safe.Count) { return $null }
  return [pscustomobject]$safe
}

function Select-StatusCurrent($Status) {
  if ($Status -and $Status.PSObject.Properties.Name -contains 'current') { return $Status.current }
  return $null
}

function Select-StatusCurrency($Status) {
  if ($Status -and $Status.PSObject.Properties.Name -contains 'currency') { return $Status.currency }
  return $null
}

function Test-JsonRecordProperty($Record, [string]$Name) {
  if (-not ($Record -is [pscustomobject])) { return $false }
  foreach ($property in $Record.PSObject.Properties) {
    if ($property.Name -eq $Name) { return $true }
  }
  return $false
}

function Test-JsonNumberValue($Value, [bool]$AllowZero = $true) {
  if ($null -eq $Value) { return $false }
  $numericType = switch ([Type]::GetTypeCode($Value.GetType())) {
    ([TypeCode]::Byte) { $true }
    ([TypeCode]::SByte) { $true }
    ([TypeCode]::UInt16) { $true }
    ([TypeCode]::UInt32) { $true }
    ([TypeCode]::UInt64) { $true }
    ([TypeCode]::Int16) { $true }
    ([TypeCode]::Int32) { $true }
    ([TypeCode]::Int64) { $true }
    ([TypeCode]::Decimal) { $true }
    ([TypeCode]::Double) { $true }
    ([TypeCode]::Single) { $true }
    default { $false }
  }
  if (-not $numericType) { return $false }
  $number = [double]$Value
  if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $false }
  return $(if ($AllowZero) { $number -ge 0 } else { $number -gt 0 })
}

function Test-JsonFiniteNumberValue($Value) {
  if ($null -eq $Value) { return $false }
  $numericType = [Type]::GetTypeCode($Value.GetType()) -in @(
    [TypeCode]::Byte, [TypeCode]::SByte, [TypeCode]::UInt16, [TypeCode]::UInt32,
    [TypeCode]::UInt64, [TypeCode]::Int16, [TypeCode]::Int32, [TypeCode]::Int64,
    [TypeCode]::Decimal, [TypeCode]::Double, [TypeCode]::Single
  )
  if (-not $numericType) { return $false }
  $number = [double]$Value
  return -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)
}

function Test-JsonInt64Value($Value) {
  if (-not (Test-JsonNumberValue $Value)) { return $false }
  try {
    $number = [decimal]$Value
    return $number -le [decimal][int64]::MaxValue -and [decimal]::Truncate($number) -eq $number
  } catch {
    return $false
  }
}

function Test-JsonStringValue($Value) {
  return $Value -is [string] -and $Value.Length -le 32767 -and $Value -notmatch '[\x00-\x1f\x7f]'
}

function Test-JsonNonEmptyStringValue($Value) {
  return (Test-JsonStringValue $Value) -and -not [string]::IsNullOrWhiteSpace($Value)
}

function Test-JsonBooleanValue($Value) {
  return $Value -is [bool]
}

function Test-JsonPercentValue($Value) {
  return (Test-JsonNumberValue $Value) -and [double]$Value -le 100.0
}

function Test-FiniteJsonNumber($Record, [string]$Name, [bool]$AllowZero = $true) {
  if (-not (Test-JsonRecordProperty $Record $Name)) { return $false }
  return Test-JsonNumberValue $Record.$Name $AllowZero
}

function Test-RequiredJsonNumbers($Record, [string[]]$Names) {
  foreach ($name in $Names) {
    if (-not (Test-FiniteJsonNumber $Record $name)) { return $false }
  }
  return $true
}

function Test-JsonArrayValue($Value) {
  return $Value -is [Collections.IList] -and -not ($Value -is [string])
}

function Test-JsonRecordArray($Value) {
  if (-not (Test-JsonArrayValue $Value)) { return $false }
  foreach ($item in $Value) {
    if (-not ($item -is [pscustomobject])) { return $false }
  }
  return $true
}

function Test-OutputRecordArray($Value) {
  if (-not (Test-JsonArrayValue $Value)) { return $false }
  foreach ($item in $Value) {
    if (-not ($item -is [pscustomobject]) -and -not ($item -is [Collections.IDictionary])) {
      return $false
    }
  }
  return $true
}

function Test-IsoCalendarDate($Value) {
  if (-not ($Value -is [string])) { return $false }
  $parsed = [DateTime]::MinValue
  return [DateTime]::TryParseExact(
    $Value,
    'yyyy-MM-dd',
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::None,
    [ref]$parsed
  )
}

function Test-JsonDateValue($Value) {
  if (-not (Test-JsonStringValue $Value) -or
      $Value -notmatch '\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})\z') {
    return $false
  }
  $parsed = [DateTimeOffset]::MinValue
  return [DateTimeOffset]::TryParse(
    $Value,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind,
    [ref]$parsed
  )
}

function Select-UsableBlocks($Blocks) {
  $rows = if (Test-JsonRecordArray $Blocks) {
    @($Blocks)
  } elseif ((Test-JsonRecordProperty $Blocks 'blocks') -and (Test-JsonRecordArray $Blocks.blocks)) {
    @($Blocks.blocks)
  } else {
    return $null
  }

  $safeRows = New-Object Collections.Generic.List[object]
  foreach ($row in $rows) {
    $safe = Select-TypedOutputRecord -Record $row `
      -RequiredNumbers @('costUSD') `
      -RequiredBooleans @('isActive', 'isGap') `
      -RequiredDates @('startTime', 'endTime') `
      -OptionalNullableDates @('actualEndTime')
    if ($null -eq $safe) { return $null }

    $start = [DateTimeOffset]::Parse($safe.startTime, [Globalization.CultureInfo]::InvariantCulture)
    $end = [DateTimeOffset]::Parse($safe.endTime, [Globalization.CultureInfo]::InvariantCulture)
    if ($end -lt $start) { return $null }
    if ((Test-OutputRecordProperty $safe 'actualEndTime') -and $null -ne $safe.actualEndTime) {
      $actualEnd = [DateTimeOffset]::Parse($safe.actualEndTime, [Globalization.CultureInfo]::InvariantCulture)
      if ($actualEnd -lt $start -or $actualEnd -gt $end) { return $null }
    }

    if (Test-JsonRecordProperty $row 'burnRate') {
      if ($null -ne $row.burnRate) {
        $burnRate = Select-TypedOutputRecord -Record $row.burnRate -RequiredNumbers @('costPerHour')
        if ($null -eq $burnRate) { return $null }
        Add-Member -InputObject $safe -NotePropertyName 'burnRate' -NotePropertyValue $burnRate -Force
      }
    }
    if (Test-JsonRecordProperty $row 'projection') {
      if ($null -ne $row.projection) {
        $projection = Select-TypedOutputRecord -Record $row.projection -RequiredNumbers @('totalCost')
        if ($null -eq $projection) { return $null }
        Add-Member -InputObject $safe -NotePropertyName 'projection' -NotePropertyValue $projection -Force
      }
    }
    $safeRows.Add($safe)
  }
  return [pscustomobject][ordered]@{ blocks = $safeRows.ToArray() }
}

function Test-UsableBlocks($Blocks) {
  return $null -ne (Select-UsableBlocks $Blocks)
}

function Select-UsableStatus($Status) {
  if (-not (Test-JsonRecordProperty $Status 'current') -or
      -not (Test-JsonRecordProperty $Status 'currency')) { return $null }
  $current = $Status.current
  $currency = $Status.currency
  $safeCurrent = Select-TypedOutputRecord -Record $current -RequiredNumbers @('cost')
  $safeCurrency = Select-TypedOutputRecord -Record $currency `
    -RequiredNumbers @('rate') `
    -RequiredNonEmptyStrings @('code') `
    -OptionalNonEmptyStrings @('symbol')
  if ($null -eq $safeCurrent -or $null -eq $safeCurrency -or
      $safeCurrency.code -notmatch '\A[A-Za-z]{3}\z' -or
      [double]$safeCurrency.rate -le 0) { return $null }
  if (-not (Test-JsonRecordArray $current.topModels)) { return $null }
  $models = @($current.topModels | Where-Object { $null -ne $_ })
  if (-not $models.Count) { return $null }
  $safeModels = New-Object Collections.Generic.List[object]
  foreach ($model in $models) {
    $safeModel = Select-TypedOutputRecord -Record $model `
      -RequiredNumbers @('cost') `
      -OptionalNumbers @('savingsUSD', 'estimatedCostUSD') `
      -RequiredInt64s @('calls') `
      -RequiredNonEmptyStrings @('name')
    if ($null -eq $safeModel) { return $null }
    $safeModels.Add($safeModel)
  }
  Add-Member -InputObject $safeCurrent -NotePropertyName 'topModels' -NotePropertyValue $safeModels.ToArray() -Force
  return [pscustomobject][ordered]@{
    current = $safeCurrent
    currency = $safeCurrency
  }
}

function Build-PeriodReports([string]$PeriodKey) {
  $rawReports = [ordered]@{
    claude = Read-JsonFile $scratch["$PeriodKey/claude/report"]
    codex = Read-JsonFile $scratch["$PeriodKey/codex/report"]
  }
  foreach ($provider in @('claude', 'codex')) {
    $report = $rawReports[$provider]
    if (-not $report) { throw "CodeBurn returned unreadable JSON for $PeriodKey/$provider report." }
    foreach ($field in $KeepFields) {
      if ($report.PSObject.Properties.Name -notcontains $field) {
        throw "CodeBurn omitted $field from $PeriodKey/$provider report."
      }
    }
    foreach ($arrayField in @('daily', 'models', 'projects', 'topSessions')) {
      if (-not (Test-JsonRecordArray $report.$arrayField)) {
        throw "CodeBurn returned invalid $arrayField data for $PeriodKey/$provider report."
      }
    }
    foreach ($row in $report.daily) {
      if (-not (Test-JsonRecordProperty $row 'date') -or
          -not (Test-IsoCalendarDate $row.date) -or
          -not (Test-FiniteJsonNumber $row 'cost')) {
        throw "CodeBurn returned invalid daily row data for $PeriodKey/$provider report."
      }
    }
    if (-not (Test-JsonRecordProperty $report 'overview') -or
        -not (Test-RequiredJsonNumbers $report.overview @('cost', 'calls', 'sessions', 'cacheHitPercent')) -or
        -not (Test-JsonRecordProperty $report.overview 'tokens') -or
        -not (Test-RequiredJsonNumbers $report.overview.tokens @('input', 'output', 'cacheRead', 'cacheWrite'))) {
      throw "CodeBurn returned invalid overview data for $PeriodKey/$provider report."
    }
    foreach ($model in $report.models) {
      if (-not (Test-JsonRecordProperty $model 'name') -or
          -not ($model.name -is [string]) -or
          [string]::IsNullOrWhiteSpace($model.name) -or
          -not (Test-RequiredJsonNumbers $model @(
            'cost', 'calls', 'inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens'
          ))) {
        throw "CodeBurn returned invalid model row data for $PeriodKey/$provider report."
      }
    }
    foreach ($project in $report.projects) {
      if (-not (Test-RequiredJsonNumbers $project @('cost', 'calls', 'sessions'))) {
        throw "CodeBurn returned invalid project row data for $PeriodKey/$provider report."
      }
    }
    foreach ($session in $report.topSessions) {
      if (-not (Test-RequiredJsonNumbers $session @('cost', 'calls'))) {
        throw "CodeBurn returned invalid session row data for $PeriodKey/$provider report."
      }
    }
    if (-not ($report.currency -is [string]) -or
        $report.currency -notmatch '\A[A-Za-z]{3}\z') {
      throw "CodeBurn returned invalid currency data for $PeriodKey/$provider report."
    }
  }
  $claudeReport = Select-ReportFields $rawReports.claude
  $codexReport = Select-ReportFields $rawReports.codex
  if ($null -eq $claudeReport -or $null -eq $codexReport) {
    throw "CodeBurn returned an invalid render field for $PeriodKey."
  }
  $claudeStatus = Select-UsableStatus (Read-JsonFile $scratch["$PeriodKey/claude/status"])
  $codexStatus = Select-UsableStatus (Read-JsonFile $scratch["$PeriodKey/codex/status"])
  return [ordered]@{
    claude = Merge-CodeBurnDurableModels -Report $claudeReport -StatusCurrent (Select-StatusCurrent $claudeStatus) -StatusCurrency (Select-StatusCurrency $claudeStatus)
    codex  = Merge-CodeBurnDurableModels -Report $codexReport -StatusCurrent (Select-StatusCurrent $codexStatus) -StatusCurrency (Select-StatusCurrency $codexStatus)
  }
}

function Receive-BlocksIfReady([bool]$WaitForCompletion = $false) {
  if (-not $script:blocksJob) { return }
  $job = $script:blocksJob
  $exited = $false
  $inspectionFailed = $false
  try { $exited = $job.HasExited } catch { $inspectionFailed = $true }
  $timedOut = $script:blocksDeadlineUtc -and [DateTime]::UtcNow -ge $script:blocksDeadlineUtc
  $oversized = $false
  try {
    $outputFile = [IO.FileInfo]::new($blocksOutput)
    $oversized = $outputFile.Exists -and $outputFile.Length -gt $MaxCollectorOutputBytes
  } catch {}
  if (-not $WaitForCompletion -and -not $exited -and -not $inspectionFailed -and
      -not $timedOut -and -not $oversized) {
    return
  }

  try {
    if ($WaitForCompletion) {
      $remaining = if ($script:blocksDeadlineUtc) {
        [int][Math]::Max(0, [Math]::Ceiling(($script:blocksDeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds))
      } else { 0 }
      $exitCode = Wait-ChildProcess $job $remaining $blocksOutput $MaxCollectorOutputBytes
    } elseif ($exited) {
      $exitCode = Wait-ChildProcess $job 0 $blocksOutput $MaxCollectorOutputBytes
    } else {
      if (-not (Stop-ProcessTree $job)) {
        throw 'The optional ccusage process could not be terminated safely.'
      }
      if ($oversized) { throw 'The optional ccusage output exceeded its limit.' }
      $exitCode = $null
    }
    if ($null -ne $exitCode -and $exitCode -eq 0) {
      $parsedBlocks = Read-JsonFile $blocksOutput
      $safeBlocks = Select-UsableBlocks $parsedBlocks
      if ($safeBlocks) { $script:claudeBlocks = $safeBlocks }
    }
  } catch {
    [void](Remove-FileWithRetry $blocksOutput)
  } finally {
    Close-CollectorProcess $job
    $script:blocksJob = $null
    $script:blocksDeadlineUtc = $null
  }
  Assert-CollectorCleanupVerified
}

function Write-AtomicScript(
  [string]$Destination,
  [string]$Temporary,
  [string]$Backup,
  [string]$ScriptText
) {
  $encoding = New-Object Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($Temporary, $ScriptText, $encoding)
  for ($attempt = 0; $attempt -lt 8; $attempt++) {
    try {
      if (Test-Path -LiteralPath $Destination) {
        if (Test-Path -LiteralPath $Backup) { [IO.File]::Delete($Backup) }
        [IO.File]::Replace($Temporary, $Destination, $Backup)
        try { if (Test-Path -LiteralPath $Backup) { [IO.File]::Delete($Backup) } } catch {}
      } else {
        [IO.File]::Move($Temporary, $Destination)
      }
      return
    } catch {
      if ($attempt -eq 7) { throw }
      Start-Sleep -Milliseconds ([Math]::Min(500, 25 * [Math]::Pow(2, $attempt)))
    }
  }
}

function Write-DataScript([string]$ScriptText) {
  Write-AtomicScript $OutData $temporaryData $backupData $ScriptText
}

function Write-FailureScript([string]$ScriptText) {
  Write-AtomicScript $OutFailure $temporaryFailure $backupFailure $ScriptText
}

function Write-TerminalFailureSignal([string]$Reason) {
  $failure = [ordered]@{
    reason = $Reason
    stage = $GenerationStage
    runId = $RunId
    generatedAt = [DateTimeOffset]::Now.ToString('o')
  }
  $json = $failure | ConvertTo-Json -Depth 10 -Compress
  Write-FailureScript "window.__GENERATION_FAILURE__ = $json; if (window.__fail__) window.__fail__();"
}

function Write-Snapshot([bool]$Complete) {
  $availablePeriods = @($PeriodKeys | Where-Object { $reports.Contains($_) })
  $reportCurrencies = @($availablePeriods | ForEach-Object {
    @($reports[$_].claude.currency, $reports[$_].codex.currency)
  })
  $statusCurrencies = @($availablePeriods | ForEach-Object {
    foreach ($provider in @('claude', 'codex')) {
      Select-StatusCurrency (Select-UsableStatus (Read-JsonFile $scratch["$_/$provider/status"]))
    }
  })
  $displayCurrency = Resolve-DisplayCurrency -ReportCurrencies $reportCurrencies -StatusCurrencies $statusCurrencies
  $script:Revision += 1

  $payload = [ordered]@{
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    runId = $RunId
    revision = $script:Revision
    complete = $Complete
    generationError = $GenerationError
    period = $Period
    currency = $displayCurrency
    pricingNote = 'API reference price estimate; subscription plans and custom providers may bill differently.'
    source = [ordered]@{
      name = 'CodeBurn'
      version = $CodeBurnVersion
    }
    periods = $availablePeriods
    reports = $reports
    limits = [ordered]@{
      claudeQuota = Select-ClaudeQuotaFields $claudeQuota
      claudeBlocks = Select-UsableBlocks $claudeBlocks
      codexQuota = Select-CodexQuotaFields $codexQuota
      codex = Select-CodexRateLimits $codexLimits
    }
    appDir = $AppDir
  }

  $json = $payload | ConvertTo-Json -Depth 100 -Compress
  Write-DataScript "window.__DATA__ = $json; if (window.__render__) window.__render__();"
}

function Publish-PeriodCandidate([string]$PeriodKey) {
  $hadPrevious = $reports.Contains($PeriodKey)
  $previous = if ($hadPrevious) { $reports[$PeriodKey] } else { $null }
  $candidate = Build-PeriodReports $PeriodKey
  $reports[$PeriodKey] = $candidate
  try {
    Receive-BlocksIfReady
    Write-Snapshot $false
  } catch {
    if ($hadPrevious) {
      $reports[$PeriodKey] = $previous
    } else {
      [void]$reports.Remove($PeriodKey)
    }
    throw
  }
}

function Set-RunState([string]$State) {
  if ($RetainedRun) { return $false }
  return Write-TextFileWithRetry $RunStatePath $State
}

function Get-RunState {
  if ($RetainedRun) { return $null }
  try { return [IO.File]::ReadAllText($RunStatePath).Trim() } catch { return $null }
}

function Write-RunOwnerPhase([string]$Phase) {
  if ($RetainedRun) { return $false }
  $record = [ordered]@{
    version = 1
    phase = $Phase
    runId = $RunId
    ownerPid = $PID
    ownerStartUtcTicks = $OwnerProcessStartUtcTicks
    primaryPeriod = $Period
    periods = @($PeriodKeys)
  }
  $json = $record | ConvertTo-Json -Depth 5 -Compress
  return Write-TextFileWithRetry $RunOwnerPath $json
}

function Get-RunOwnerRecord {
  if ($RetainedRun -or -not (Test-Path -LiteralPath $RunOwnerPath)) { return $null }
  try {
    $file = [IO.FileInfo]::new($RunOwnerPath)
    if (-not $file.Exists -or $file.Length -le 0 -or $file.Length -gt 4096) { return $null }
    $record = [IO.File]::ReadAllText($RunOwnerPath) | ConvertFrom-Json
    if (-not ($record -is [pscustomobject])) { return $null }
    return $record
  } catch {
    return $null
  }
}

function Test-RunOwnerIdentity($Record) {
  if (-not $Record) { return $false }
  $ownerPid = 0
  $ownerStartTicks = [int64]0
  if (-not [int]::TryParse([string]$Record.ownerPid, [ref]$ownerPid) -or $ownerPid -le 0 -or
      -not [int64]::TryParse([string]$Record.ownerStartUtcTicks, [ref]$ownerStartTicks) -or
      $ownerStartTicks -le 0) {
    return $false
  }
  try {
    $process = Get-Process -Id $ownerPid -ErrorAction Stop
    return $process.StartTime.ToUniversalTime().Ticks -eq $ownerStartTicks
  } catch {
    return $false
  }
}

function Get-RunFailureEventName([string]$IdentityRunId) {
  if ($IdentityRunId -cnotmatch '\A[0-9a-f]{32}\z' -or
      [string]::IsNullOrWhiteSpace([string]$UserSid)) {
    return $null
  }
  return "Global\AIUsage-ReportFailed-$UserSid-$IdentityRunId"
}

function Test-RunFailureSignaled([string]$IdentityRunId) {
  $eventName = Get-RunFailureEventName $IdentityRunId
  if (-not $eventName) { return $true }
  $failureSignal = $null
  try {
    $failureSignal = [Threading.EventWaitHandle]::OpenExisting($eventName)
    return $failureSignal.WaitOne([TimeSpan]::Zero)
  } catch {
    # A live normal owner creates this event before publishing `starting` and
    # retains it beyond the report mutex. Missing or inaccessible is therefore
    # an invalid active record, never proof that the run is healthy.
    return $true
  } finally {
    if ($failureSignal) { try { $failureSignal.Dispose() } catch {} }
  }
}

function Signal-RunFailure {
  if ($RetainedRun) { return }
  try { [void]$FailureEvent.Set() } catch {}
  [void](Write-RunOwnerPhase 'failed')
  [void](Set-RunState 'failed')
}

function Test-ActiveReportReusable([string]$PeriodKey) {
  if ($RetainedRun -or (Get-RunState) -cne 'active' -or -not (Test-Path -LiteralPath $OutHtml)) {
    return $false
  }
  $owner = Get-RunOwnerRecord
  if (-not $owner -or [string]$owner.phase -cne 'active' -or
      -not (Test-RunOwnerIdentity $owner)) {
    return $false
  }
  if (Test-RunFailureSignaled ([string]$owner.runId)) { return $false }
  $plannedPeriods = @($owner.periods)
  if (-not $plannedPeriods.Count -or @($plannedPeriods | Where-Object { -not ($_ -is [string]) }).Count) {
    return $false
  }
  return $plannedPeriods -ccontains $PeriodKey
}

function Test-FailedRunRetryRequested {
  if ($RetainedRun -or -not $GenerationFailed -or
      -not (Test-Path -LiteralPath $RetryRequestPath)) {
    return $false
  }
  try {
    $request = [IO.File]::ReadAllText($RetryRequestPath).Trim()
    return $request -cmatch '\A[0-9a-f]{32}\z' -and $request -ceq $RunId
  } catch {
    return $false
  }
}

function Request-FailedRunRetry {
  if ($RetainedRun -or (Get-RunState) -cne 'failed') { return $false }
  $owner = Get-RunOwnerRecord
  if (-not $owner -or [string]$owner.phase -cne 'failed' -or
      -not (Test-RunOwnerIdentity $owner)) {
    return $false
  }
  $ownerRunId = [string]$owner.runId
  if ($ownerRunId -cnotmatch '\A[0-9a-f]{32}\z') { return $false }
  try {
    if ((Test-Path -LiteralPath $RetryRequestPath) -and
        [IO.File]::ReadAllText($RetryRequestPath).Trim() -ceq $ownerRunId) {
      return $true
    }
  } catch {}
  if (-not (Write-TextFileWithRetry $RetryRequestPath $ownerRunId)) { return $false }
  $confirmedOwner = Get-RunOwnerRecord
  return (Get-RunState) -cne 'active' -and $confirmedOwner -and
    [string]$confirmedOwner.phase -cne 'active' -and
    [string]$confirmedOwner.runId -ceq $ownerRunId -and
    (Test-RunOwnerIdentity $confirmedOwner)
}

function Get-ReportLaunchTarget([string]$ReportPath, [string]$PeriodKey) {
  $reportUri = [Uri]::new([IO.Path]::GetFullPath($ReportPath))
  return $reportUri.AbsoluteUri + '?period=' + [Uri]::EscapeDataString($PeriodKey)
}

function Touch-ReadLease {
  if ($RetainedRun) { return $false }
  return Write-TextFileWithRetry $ReadLeasePath ([string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
}

function Get-ReadLeaseMilliseconds {
  if ($RetainedRun -or -not (Test-Path $ReadLeasePath)) { return [int64]0 }
  try {
    $value = [int64]0
    if ([int64]::TryParse([IO.File]::ReadAllText($ReadLeasePath).Trim(), [ref]$value)) { return $value }
  } catch {}
  return [int64]0
}

function Wait-NormalReadGrace {
  if ($RetainedRun) { return $false }
  $normalGraceMilliseconds = [Math]::Max(0, $DeleteAfter) * 1000
  $graceMilliseconds = $normalGraceMilliseconds
  $retryGraceApplied = $false
  $deadline = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + $graceMilliseconds
  $seenLease = Get-ReadLeaseMilliseconds
  while ($true) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if (-not $retryGraceApplied -and (Test-FailedRunRetryRequested)) {
      $retryGraceApplied = $true
      $graceMilliseconds = [Math]::Min(2000, $normalGraceMilliseconds)
      $deadline = [Math]::Min($deadline, $now + $graceMilliseconds)
    }
    $latestLease = Get-ReadLeaseMilliseconds
    if ($latestLease -gt $seenLease) { $seenLease = $latestLease }
    if (($latestLease + $graceMilliseconds) -gt $deadline) {
      $deadline = $latestLease + $graceMilliseconds
    }
    $remaining = $deadline - $now
    if ($remaining -gt 0) {
      Start-Sleep -Milliseconds ([Math]::Min(250, [Math]::Max(25, $remaining)))
      continue
    }

    $closingStateWritten = Set-RunState 'closing'
    [void](Write-RunOwnerPhase 'closing')
    if (-not $closingStateWritten) {
      # A concurrent launcher may already have renewed the lease and started this page.
      # Preserve the complete snapshot; the next mutex owner clears cleanup_failed residue.
      return $false
    }
    Start-Sleep -Milliseconds 150
    $afterClosing = Get-ReadLeaseMilliseconds
    if ($afterClosing -gt $seenLease) {
      $seenLease = $afterClosing
      $deadline = $afterClosing + $graceMilliseconds
      $renewedPhase = if ($GenerationFailed) { 'failed' } else { 'active' }
      [void](Write-RunOwnerPhase $renewedPhase)
      [void](Set-RunState $renewedPhase)
      continue
    }
    return $true
  }
}

try {
  # Upstream inventory, 2026-08-08: CodeBurn exposes no Windows-safe locking
  # primitive. A SID-scoped global .NET mutex covers the same user's Windows
  # terminal sessions. Keep the legacy Local mutex during migration so a report
  # already running from a pre-upgrade script cannot overlap this process.
  $UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $RunMutex = [Threading.Mutex]::new($false, "Global\AIUsage-CodeBurn-$UserSid")
  try {
    $RunMutexHeld = $RunMutex.WaitOne([TimeSpan]::Zero)
  } catch [Threading.AbandonedMutexException] {
    $RunMutexHeld = $true
    $RunMutexAbandoned = $true
  }
  $runMutexDeadline = [DateTime]::UtcNow.AddMinutes(5)
  while (-not $RunMutexHeld -and [DateTime]::UtcNow -lt $runMutexDeadline) {
    if (-not $RetainedRun -and (Test-ActiveReportReusable $Period)) {
      Assert-NoPendingInstallation
      if ((Touch-ReadLease) -and (Test-ActiveReportReusable $Period)) {
        Assert-NoPendingInstallation
        Start-Process (Get-ReportLaunchTarget $OutHtml $Period) | Out-Null
        return
      }
    }
    if (-not $RetainedRun) { [void](Request-FailedRunRetry) }
    $remainingMilliseconds = [int][Math]::Max(1, [Math]::Ceiling(($runMutexDeadline - [DateTime]::UtcNow).TotalMilliseconds))
    try {
      $RunMutexHeld = $RunMutex.WaitOne([TimeSpan]::FromMilliseconds([Math]::Min(100, $remainingMilliseconds)))
    } catch [Threading.AbandonedMutexException] {
      $RunMutexHeld = $true
      $RunMutexAbandoned = $true
    }
  }
  if (-not $RunMutexHeld) {
    throw 'Another AI Usage report is still running.'
  }
  # The marker may have appeared while this process waited for the report mutex.
  # Recheck before reading tools or session data, especially after an abandoned lock.
  Assert-NoPendingInstallation
  if (-not $RetainedRun) {
    if (-not (Test-Path -LiteralPath $RuntimeRoot)) {
      New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
    }
    foreach ($marker in @($ReadLeasePath, $RunStatePath, $RunOwnerPath, $RetryRequestPath)) {
      if (-not (Remove-FileWithRetry $marker)) {
        throw 'Could not remove stale dashboard coordination state.'
      }
    }
    $failureEventCreated = $false
    $FailureEvent = [Threading.EventWaitHandle]::new(
      $false,
      [Threading.EventResetMode]::ManualReset,
      (Get-RunFailureEventName $RunId),
      [ref]$failureEventCreated
    )
    if (-not $failureEventCreated) { throw 'Could not create a unique dashboard failure signal.' }
    if (-not (Set-RunState 'starting')) { throw 'Could not publish the starting dashboard state.' }
    if (-not (Write-RunOwnerPhase 'starting')) { throw 'Could not publish the dashboard owner record.' }
  }

  $LegacyRunMutex = [Threading.Mutex]::new($false, 'Local\AIUsage-CodeBurn')
  try {
    $LegacyRunMutexHeld = $LegacyRunMutex.WaitOne([TimeSpan]::FromMinutes(5))
  } catch [Threading.AbandonedMutexException] {
    $LegacyRunMutexHeld = $true
    $LegacyRunMutexAbandoned = $true
  }
  if (-not $LegacyRunMutexHeld) {
    throw 'A legacy AI Usage report is still running.'
  }
  if ($RunMutexAbandoned -or $LegacyRunMutexAbandoned) {
    # A mutex becomes abandoned when its owner thread dies; Job close and child
    # termination can finish a moment later. Older releases did not use Jobs at
    # all. Require two stable empty scans before any collector or session read.
    Wait-AbandonedCollectorProcesses $UserSid
  }

  $CodeBurn = Resolve-CommandPath @('codeburn.cmd', 'codeburn')
  if (-not $CodeBurn) {
    throw 'CodeBurn is not installed. Run: npm install -g codeburn'
  }
  $CodeBurnVersion = Get-NpmPackageVersion $CodeBurn 'codeburn'
  if ($CodeBurnVersion -ne $RequiredCodeBurnVersion) {
    throw ("Unsupported CodeBurn version {0}; run install.ps1 to install {1}." -f $CodeBurnVersion, $RequiredCodeBurnVersion)
  }
  $CCUsage = Resolve-CommandPath @('ccusage.cmd', 'ccusage')
  if ($CCUsage) {
    $CCUsageVersion = Get-NpmPackageVersion $CCUsage 'ccusage'
    if ($CCUsageVersion -ne $RequiredCCUsageVersion) {
      throw ("Unsupported ccusage version {0}; run install.ps1 to install {1}." -f $CCUsageVersion, $RequiredCCUsageVersion)
    }
  }

  if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  }

  # CodeBurn aggregates models/projects/sessions per period, so a period the browser
  # can switch to must be produced here - it cannot be re-derived from another period.
  foreach ($periodKey in $PeriodKeys) {
    foreach ($provider in @('claude', 'codex')) {
      $scratch["$periodKey/$provider/status"] = Join-Path $OutDir ("_{0}-{1}-status.json" -f $periodKey, $provider)
      $scratch["$periodKey/$provider/report"] = Join-Path $OutDir ("_{0}-{1}-report.json" -f $periodKey, $provider)
    }
  }

  # A previous run may have selected a different valid period, or may have left
  # raw files inside an explicit debug snapshot. Remove only names this generator
  # owns, and never traverse a reparse-point directory.
  $scratchDirectories = @($OutDir)
  if (Test-Path -LiteralPath $RuntimeRoot) {
    $scratchDirectories += @(Get-ChildItem -LiteralPath $RuntimeRoot -Directory -Filter 'debug-*' -ErrorAction SilentlyContinue | Where-Object {
      $_.Name -match '\Adebug-\d{8}-\d{6}-\d{3}-\d+\z' -and
      ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
    } | ForEach-Object { $_.FullName })
  }
  $staleScratch = @($scratchDirectories | Select-Object -Unique | ForEach-Object {
    $directory = $_
    $ManagedScratchNames | ForEach-Object { Join-Path $directory $_ }
  })
  foreach ($path in $staleScratch) {
    if (-not (Remove-FileWithRetry $path)) {
      [void]$CleanupFailures.Add([IO.Path]::GetFileName($path))
      throw 'Could not remove stale collector scratch before launch.'
    }
  }

  [IO.File]::Copy($Template, $OutHtml, $true)
  foreach ($fontName in $FontNames) {
    [IO.File]::Copy((Join-Path $FontDir $fontName), (Join-Path $OutDir $fontName), $true)
  }
  foreach ($previousOutput in @($OutData, $OutFailure)) {
    if (-not (Remove-FileWithRetry $previousOutput)) {
      throw 'Could not remove the previous dashboard output before launch.'
    }
  }

  if (-not $NoLaunch) {
    if (-not $RetainedRun) {
      if (-not (Touch-ReadLease)) { throw 'Could not establish the dashboard read lease.' }
    }
    Start-Process (Get-ReportLaunchTarget $OutHtml $Period) | Out-Null
    $PageLaunched = $true
    if (-not $RetainedRun) {
      if (-not (Write-RunOwnerPhase 'active')) { throw 'Could not publish the active dashboard owner.' }
      if (-not (Set-RunState 'active')) { throw 'Could not publish the active dashboard state.' }
    }
  }

  # ccusage is a separate tool over the same read-only session files, so it may
  # overlap with CodeBurn.
  if ($CCUsage) {
    $blocksDeadlineUtc = [DateTime]::UtcNow.AddMilliseconds($CCUsageTimeoutMilliseconds)
    $blocksJob = Start-OptionalJsonCommand $CCUsage @('blocks', '--json', '--offline') $blocksOutput
    if (-not $blocksJob) { $blocksDeadlineUtc = $null }
  }

  # CodeBurn is NOT concurrency-safe: overlapping invocations leak each other's
  # rows, so a `--provider codex` run can come back holding the union of both
  # providers' models and projects while its overview stays correctly scoped.
  # Verified 2026-08-08 - parallel gave codex/30days 10 models summing $7,585.72,
  # sequential gave the correct 3 models summing $1,263.73. Keep these serial.
  #
  try {
    # Publish reports first. They already conserve the headline cost through the
    # unattributed fallback, which makes the default period useful after two calls.
    # Status is a quality pass that restores durable historical model attribution.
    foreach ($periodKey in $PeriodKeys) {
      $GenerationStage = if ($periodKey -eq $PeriodKeys[0]) { 'default_usage' } else { 'remaining_usage' }
      foreach ($provider in @('claude', 'codex')) {
        Invoke-CodeBurnJson `
          @('report', '--period', $periodKey, '--provider', $provider, '--format', 'json') `
          $scratch["$periodKey/$provider/report"] "$periodKey/$provider report"
      }
      Publish-PeriodCandidate $periodKey
      $HasPublishedSnapshot = $true

      foreach ($provider in @('claude', 'codex')) {
        try {
          Invoke-CodeBurnJson `
            @('status', '--format', 'menubar-json', '--scope', 'local', '--provider', $provider,
              '--period', $periodKey, '--no-optimize', '--no-timeline') `
            $scratch["$periodKey/$provider/status"] "$periodKey/$provider durable models"
        } catch { Assert-CollectorCleanupVerified }
      }
      Publish-PeriodCandidate $periodKey
    }

    $GenerationStage = 'local_limits'
    Receive-BlocksIfReady $true

    # Quota reads happen after every local report is available. Slow or failed
    # provider networks can update their cards, but can no longer block the page.
    $codexLimits = Select-CodexRateLimits (Get-LatestCodexRateLimit)
    Write-Snapshot $false
    $GenerationStage = 'claude_quota'
    $claudeQuota = Get-ClaudeOAuthUsage
    Write-Snapshot $false
    $GenerationStage = 'codex_quota'
    $codexQuota = Get-CodexProviderQuota
    $GenerationStage = 'final_publish'
    Write-Snapshot $true
  } catch {
    $GenerationFailed = $true
    Signal-RunFailure
    if (-not $HasPublishedSnapshot) {
      $initialFailure = $_
      if ($PageLaunched) {
        try {
          Write-TerminalFailureSignal 'initial_generation_failed'
          $HasPublishedSnapshot = $true
          $RunCompleted = $true
        } catch {}
      }
      throw $initialFailure
    }
    $GenerationError = [ordered]@{ reason = 'partial_generation_failed'; stage = $GenerationStage }
    if ($claudeQuota.reason -eq 'loading') { $claudeQuota = [ordered]@{ ok = $false; reason = 'not_collected' } }
    if ($codexQuota.reason -eq 'loading') { $codexQuota = [ordered]@{ ok = $false; reason = 'not_collected' } }
    try {
      Write-Snapshot $true
    } catch {
      $terminalWriteFailure = $_
      Write-TerminalFailureSignal 'partial_generation_failed'
      throw $terminalWriteFailure
    }
  }

  $HasPublishedSnapshot = $true
  $RunCompleted = $true

  if ($NoLaunch) {
    # NoLaunch is a debugging mode and deliberately retains the final snapshot.
    Write-Output $OutHtml
  }
} catch {
  $outerFailure = $_
  if (-not $GenerationFailed -and $RunMutexHeld) {
    $GenerationFailed = $true
    Signal-RunFailure
    if ($PageLaunched -and -not $HasPublishedSnapshot) {
      try {
        Write-TerminalFailureSignal 'initial_generation_failed'
        $HasPublishedSnapshot = $true
        $RunCompleted = $true
      } catch {}
    }
  }
  throw $outerFailure
} finally {
  if ($RunMutexHeld) {
    if ($blocksJob) {
      Close-CollectorProcess $blocksJob
    }
    $collectorDrainFailed = $false
    if ($script:CollectorCleanupUncertain) {
      try { Wait-AbandonedCollectorProcesses $userSid }
      catch { $collectorDrainFailed = $true }
    }

    # Raw reports are never a debugging artifact: they include fields intentionally
    # excluded from data.js and must disappear on both success and failure.
    foreach ($path in @($scratch.Values) + @(
      $blocksOutput, $temporaryData, $backupData, $temporaryFailure, $backupFailure
    )) {
      if ($path -and -not (Remove-FileWithRetry $path)) {
        [void]$CleanupFailures.Add([IO.Path]::GetFileName($path))
      }
    }

    if (-not $RetainedRun -and -not $ReadGraceObserved) {
      if ($PageLaunched) {
        $CanDeleteFinal = if ($HasPublishedSnapshot) {
          Wait-NormalReadGrace
        } else {
          [void](Set-RunState 'closing')
          [void](Write-RunOwnerPhase 'closing')
          $true
        }
      }
      $ReadGraceObserved = $true
    }

    if ((-not $RunCompleted -or -not $PreserveFinal) -and ($RetainedRun -or $CanDeleteFinal)) {
      foreach ($path in @($OutData, $OutFailure, $OutHtml) + $OutFonts) {
        if (-not (Remove-FileWithRetry $path)) {
          [void]$CleanupFailures.Add([IO.Path]::GetFileName($path))
        }
      }
    }
    if (-not $RetainedRun) {
      if ($CanDeleteFinal -and -not $CleanupFailures.Count) {
        foreach ($marker in @($RunStatePath, $ReadLeasePath, $RunOwnerPath, $RetryRequestPath)) {
          if (-not (Remove-FileWithRetry $marker)) {
            [void]$CleanupFailures.Add([IO.Path]::GetFileName($marker))
          }
        }
      }
      if (-not $CanDeleteFinal -or $CleanupFailures.Count) {
        [void](Write-RunOwnerPhase 'cleanup_failed')
        [void](Set-RunState 'cleanup_failed')
      }
    }
    if ($RetainedRun -and -not $RunCompleted) {
      try {
        if ((Test-Path $OutDir) -and -not (Get-ChildItem -LiteralPath $OutDir -Force -ErrorAction SilentlyContinue)) {
          [IO.Directory]::Delete($OutDir, $false)
        }
      } catch {}
    }

    if ($collectorDrainFailed) {
      throw 'Collector cleanup could not be verified; the report mutex will be abandoned.'
    }
    if ($LegacyRunMutexHeld) { try { $LegacyRunMutex.ReleaseMutex() } catch {} }
    try { $RunMutex.ReleaseMutex() } catch {}
    if ($CleanupFailures.Count) {
      Write-Warning ('Dashboard cleanup needs a retry for: ' + (@($CleanupFailures | Select-Object -Unique) -join ', '))
    }
  }
  if ($LegacyRunMutex) {
    try { $LegacyRunMutex.Dispose() } catch {}
  }
  if ($RunMutex) {
    try { $RunMutex.Dispose() } catch {}
  }
  if ($FailureEvent) {
    try { $FailureEvent.Dispose() } catch {}
  }
}
