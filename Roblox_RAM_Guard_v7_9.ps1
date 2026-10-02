
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:AltFile = Join-Path $PSScriptRoot "alts.json"
$script:MainFile = Join-Path $PSScriptRoot "main.json"
$script:SettingsFile = Join-Path $PSScriptRoot "settings.json"

$script:Resolved = @{}
$script:AssignedLogs = @{}
$script:FreezeStart = @{}
$script:KnownPids = @()

function Load-JsonFile($path, $fallback) {
    if (Test-Path $path) {
        try { return (Get-Content $path -Raw | ConvertFrom-Json) } catch {}
    }
    return $fallback
}
function Save-JsonFile($path, $obj) {
    try { $obj | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $path } catch {}
}

$script:Alts = @(Load-JsonFile $script:AltFile @())
$script:Main = Load-JsonFile $script:MainFile $null
$script:Settings = Load-JsonFile $script:SettingsFile ([pscustomobject]@{
    TrimTargetMB = 600
    TrimTriggerMB = 700
    PollSeconds = 3
    FrozenSeconds = 30
})

if (-not $script:Settings.TrimTargetMB) { $script:Settings.TrimTargetMB = 600 }
if (-not $script:Settings.TrimTriggerMB) { $script:Settings.TrimTriggerMB = 700 }
if (-not $script:Settings.PollSeconds) { $script:Settings.PollSeconds = 3 }
if (-not $script:Settings.FrozenSeconds) { $script:Settings.FrozenSeconds = 30 }

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class NativeMethods {
  [DllImport("psapi.dll")]
  public static extern bool EmptyWorkingSet(IntPtr hProcess);
  [DllImport("user32.dll")]
  public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool IsHungAppWindow(IntPtr hWnd);
  [StructLayout(LayoutKind.Sequential)]
  public struct MemoryStatus {
    public uint Length, Load;
    public ulong TotalPhysical, AvailablePhysical, TotalPageFile, AvailablePageFile;
    public ulong TotalVirtual, AvailableVirtual, AvailableExtendedVirtual;
  }
  [DllImport("kernel32.dll", SetLastError=true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
}
"@

function Get-RobloxProcesses {
    if ($null -ne $script:CycleProcesses) { return @($script:CycleProcesses) }
    @(Get-Process RobloxPlayerBeta -ErrorAction SilentlyContinue)
}

# Identity records are scoped to PID + process start, not PID alone.
$script:IdentityScanAt = [datetime]::MinValue
$script:LogMetadata = @{}
$script:NameCache = @{}
$script:NameRetryAt = @{}
$script:NameWorker = $null
$script:NameWorkerHandle = $null
$script:NameWorkerIds = @()

function Get-RobloxLogs {
    $logDir = Join-Path $env:LOCALAPPDATA 'Roblox\logs'
    if (-not (Test-Path -LiteralPath $logDir)) { return @() }
    @(Get-ChildItem -LiteralPath $logDir -Filter '*Player*.log' -File -ErrorAction SilentlyContinue)
}

function Read-LogLarge($path, $maxBytes = 8388608) {
    # Startup contains identity; reading only the tail discarded it after 8 MB.
    $fs = $null
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        $length = $fs.Length
        $headBytes = [int][math]::Min($length, $maxBytes)
        if ($length -gt $maxBytes) { $headBytes = [int]($maxBytes / 2) }
        $buf = New-Object byte[] $headBytes
        $offset = 0
        while ($offset -lt $buf.Length) {
            $count = $fs.Read($buf, $offset, $buf.Length - $offset)
            if ($count -eq 0) { break }
            $offset += $count
        }
        $text = [Text.Encoding]::UTF8.GetString($buf, 0, $offset)
        if ($length -gt $maxBytes) {
            $tailBytes = [int]($maxBytes / 2)
            [void]$fs.Seek(-$tailBytes, [IO.SeekOrigin]::End)
            $buf = New-Object byte[] $tailBytes
            $offset = 0
            while ($offset -lt $buf.Length) {
                $count = $fs.Read($buf, $offset, $buf.Length - $offset)
                if ($count -eq 0) { break }
                $offset += $count
            }
            $text += "`n" + [Text.Encoding]::UTF8.GetString($buf, 0, $offset)
        }
        return $text
    } catch { return '' }
    finally { if ($fs) { $fs.Dispose() } }
}

function Parse-IdentityFromText($text, $path) {
    if (-not $text) { return $null }
    # Handle escaped JSON and URL-encoded launch/telemetry fields.
    $text = $text.Replace('\"', '"')
    $text = $text -replace '(?i)%22', '"' -replace '(?i)%3a', ':' -replace '(?i)%3d', '='
    $userId = $null
    $username = $null
    # Prefer the authenticated/local user over IDs of other players printed by a game.
    $idPatterns = @(
        '\bauthenticatedUserId\b["\s:=]+(?<id>[1-9][0-9]{0,17})\b',
        '\[FLog::GameJoinLoadTime\][^\r\n]*?\buserid\s*:\s*(?<id>[1-9][0-9]{0,17})\b',
        '\[FLog::(?:ClientRunInfo|GameJoinUtil|SingleSurfaceApp|Player|UgcGameController)\][^\r\n]*?\b(?:userId|accountId)\b["\s:=]+(?<id>[1-9][0-9]{0,17})\b',
        '(?m)^\s*\{\s*"(?:userId|accountId)"\s*:\s*"?(?<id>[1-9][0-9]{0,17})\b',
        '(?m)^\s*(?:userId|accountId)\s*[:=]\s*"?(?<id>[1-9][0-9]{0,17})\b'
    )
    foreach ($pattern in $idPatterns) {
        $matchesFound = [regex]::Matches($text, $pattern, 'IgnoreCase')
        $values = @($matchesFound | ForEach-Object { $_.Groups['id'].Value } | Select-Object -Unique)
        # Conflicting local identities require another scan, not a guessed account.
        if ($values.Count -gt 1) { return $null }
        if ($values.Count -eq 1) { $userId = $values[0]; break }
    }
    # Read a username only from a local-account field/record, not arbitrary game output.
    $namePatterns = @(
        '(?m)^\s*(?:username|accountName)\s*[:=]\s*"?(?<name>[A-Za-z0-9_]{3,20})\b',
        '\[FLog::(?:ClientRunInfo|GameJoinUtil|SingleSurfaceApp|Player|UgcGameController)\][^\r\n]*?\b(?:username|accountName)\b["\s:=]+(?<name>[A-Za-z0-9_]{3,20})\b',
        '(?m)^\s*\{[^\r\n]*?"(?:username|accountName)"\s*:\s*"(?<name>[A-Za-z0-9_]{3,20})"'
    )
    foreach ($pattern in $namePatterns) {
        $m = [regex]::Match($text, $pattern, 'IgnoreCase')
        if ($m.Success -and $m.Groups['name'].Value -notin @('Unknown','null','true','false')) {
            $username = $m.Groups['name'].Value; break
        }
    }
    if (-not $userId -and -not $username) { return $null }
    # With an ID, resolve the canonical username from Roblox rather than pairing
    # a separately printed name with an unrelated ID.
    if ($userId) { $username = 'Unknown' }
    return [pscustomobject]@{UserId=$userId; Username=$(if($username){$username}else{'Unknown'}); Log=$path}
}

function Parse-IdentityFromLog($path) {
    return Parse-IdentityFromText (Read-LogLarge $path) $path
}

function Get-LogMetadata($file) {
    $key = $file.FullName
    $fingerprint = '{0}:{1}:{2}' -f $file.CreationTimeUtc.Ticks, $file.LastWriteTimeUtc.Ticks, $file.Length
    if ($script:LogMetadata.ContainsKey($key) -and $script:LogMetadata[$key].Fingerprint -eq $fingerprint) {
        return $script:LogMetadata[$key]
    }
    # Most identity and thread fields are in startup/recent sections. Large
    # fallback reads are needed only while identity remains unresolved.
    $text = Read-LogLarge $key 262144
    $identity = Parse-IdentityFromText $text $key
    # A known ID may sit between the bounded head/tail samples. Keep it when
    # neither sample contains account fields; conflicting fields stay unresolved.
    if (-not $identity -and $script:LogMetadata.ContainsKey($key) -and $script:LogMetadata[$key].Identity -and
        $text -notmatch '(?i)authenticatedUserId|GameJoinLoadTime[^\r\n]*userid|\b(?:userId|accountId|username|accountName)\b') {
        $identity=$script:LogMetadata[$key].Identity
    }
    if (-not $identity) {
        $text = Read-LogLarge $key
        $identity = Parse-IdentityFromText $text $key
    }
    $started = $file.CreationTimeUtc
    $hasStartupClock = $false
    # The logger clock is a timing hint; it is not Windows process creation time.
    $m = [regex]::Match($text, '(?m)^(?<utc>\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z),(?<elapsed>\d+(?:\.\d+)?),')
    if ($m.Success) {
        try {
            $stamp = [datetime]::Parse($m.Groups['utc'].Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
            $elapsed = [double]::Parse($m.Groups['elapsed'].Value, [Globalization.CultureInfo]::InvariantCulture)
            $started = $stamp.AddSeconds(-$elapsed)
            $hasStartupClock = $true
        } catch {}
    }
    $threadTimes = @{}
    $lastUtc = [datetime]::MinValue
    $nativeEntries = [regex]::Matches($text, '(?m)^(?<utc>\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z),\d+(?:\.\d+)?,(?<thread>[0-9a-fA-F]+),')
    # Walk backwards and parse a timestamp only once per distinct native thread.
    for ($entryIndex=$nativeEntries.Count-1; $entryIndex -ge 0; $entryIndex--) {
        $nativeEntry = $nativeEntries[$entryIndex]
        try {
            $threadKey = [string][Convert]::ToInt32($nativeEntry.Groups['thread'].Value, 16)
            if ($threadTimes.ContainsKey($threadKey)) { continue }
            $seenUtc = [datetime]::Parse($nativeEntry.Groups['utc'].Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
            if (-not $threadTimes.ContainsKey($threadKey) -or $threadTimes[$threadKey] -lt $seenUtc) { $threadTimes[$threadKey]=$seenUtc }
            if ($seenUtc -gt $lastUtc) { $lastUtc=$seenUtc }
        } catch {}
    }
    $entry = [pscustomobject]@{Path=$key; StartUtc=$started; LastUtc=$lastUtc; ThreadTimes=$threadTimes; Identity=$identity; Fingerprint=$fingerprint}
    # A sharing error must not be cached as a permanently empty log.
    if ($text) { $script:LogMetadata[$key] = $entry }
    return $entry
}

function Update-UsernameLookups {
    # Network I/O runs off the UI thread, with a timeout and a retry backoff.
    if ($script:NameWorker -and $script:NameWorkerHandle.IsCompleted) {
        try {
            $profiles = @($script:NameWorker.EndInvoke($script:NameWorkerHandle))
            foreach ($profile in $profiles) {
                $key = [string]$profile.id
                if ($key -in $script:NameWorkerIds -and $profile.name -match '^[A-Za-z0-9_]{3,20}$') {
                    $script:NameCache[$key] = [string]$profile.name
                }
            }
        } catch {} finally {
            $script:NameWorker.Dispose()
            $script:NameWorker = $null
            $script:NameWorkerHandle = $null
        }
    }
    foreach ($identity in @($script:Resolved.Values)) {
        $key = [string]$identity.UserId
        if ($key -and $script:NameCache.ContainsKey($key)) { $identity.Username = $script:NameCache[$key] }
    }
    if ($script:NameWorker) { return }
    $now = Get-Date
    $pending = @($script:Resolved.Values | Where-Object {
        $_.UserId -and $_.Username -eq 'Unknown' -and
        (-not $script:NameRetryAt.ContainsKey([string]$_.UserId) -or $script:NameRetryAt[[string]$_.UserId] -le $now)
    } | ForEach-Object { [string]$_.UserId } | Select-Object -Unique -First 100)
    if (-not $pending.Count) { return }
    foreach ($key in $pending) { $script:NameRetryAt[$key] = $now.AddSeconds(60) }
    $script:NameWorkerIds = $pending
    $body = @{userIds=@($pending | ForEach-Object { [long]$_ }); excludeBannedUsers=$false} | ConvertTo-Json -Compress
    try {
        $script:NameWorker = [PowerShell]::Create()
        [void]$script:NameWorker.AddScript({
            param($requestBody)
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                $response = Invoke-RestMethod -Uri 'https://users.roblox.com/v1/users' -Method Post -ContentType 'application/json' -Body $requestBody -TimeoutSec 8 -ErrorAction Stop
                $response.data | Select-Object id,name
            } catch {}
        }).AddArgument($body)
        $script:NameWorkerHandle = $script:NameWorker.BeginInvoke()
    } catch {
        if ($script:NameWorker) { $script:NameWorker.Dispose() }
        $script:NameWorker = $null
    }
}

function Get-ProcessStartUtc($proc) {
    $key=[string]$proc.Id
    if ($script:CycleStartCache.ContainsKey($key)) { return $script:CycleStartCache[$key] }
    $start=$null
    try { $start=$proc.StartTime.ToUniversalTime() } catch {}
    if (-not $start) {
        # One bounded CIM fallback per cycle instead of one query per client.
        if ($null -eq $script:CimStartMap) {
            $script:CimStartMap=@{}
            try {
                foreach ($entry in @(Get-CimInstance Win32_Process -Filter "Name='RobloxPlayerBeta.exe'" -OperationTimeoutSec 3 -ErrorAction Stop)) {
                    if ($entry.CreationDate) { $script:CimStartMap[[string]$entry.ProcessId]=$entry.CreationDate.ToUniversalTime() }
                }
            } catch {}
        }
        $start=$script:CimStartMap[$key]
    }
    $script:CycleStartCache[$key]=$start
    return $start
}

function Assign-LogsToProcesses {
    Update-UsernameLookups
    if (((Get-Date) - $script:IdentityScanAt).TotalSeconds -lt 10) { return }
    $script:IdentityScanAt = Get-Date
    $procs = @(Get-RobloxProcesses)
    $live = @{}
    $snapshots = @{}
    foreach ($p in $procs) {
        $key = [string]$p.Id
        $start = Get-ProcessStartUtc $p
        $threads = @{}
        try {
            $p.Refresh()
            foreach ($thread in $p.Threads) { $threads[[string]$thread.Id] = $true }
        } catch {}
        $snapshots[$key] = [pscustomobject]@{StartUtc=$start; Threads=$threads}
        if ($start) { $live[$key] = $start.Ticks }
    }
    foreach ($key in @($script:Resolved.Keys)) {
        if (-not $live.ContainsKey($key) -or $script:Resolved[$key].StartTicks -ne $live[$key]) {
            $script:Resolved.Remove($key)
            $script:FreezeStart.Remove($key)
        }
    }
    $script:AssignedLogs.Clear()
    $records = @()
    foreach ($file in Get-RobloxLogs) {
        # Compare to process creation only to reject logs from ended sessions.
        $recent = $false
        foreach ($snapshot in $snapshots.Values) {
            if ($snapshot.StartUtc -and $file.LastWriteTimeUtc -ge $snapshot.StartUtc.AddSeconds(-2)) {
                $recent = $true; break
            }
        }
        if ($recent) { $records += Get-LogMetadata $file }
    }
    foreach ($key in @($script:LogMetadata.Keys)) {
        if ($key -notin @($records | ForEach-Object {$_.Path})) { $script:LogMetadata.Remove($key) }
    }
    # Match log native-thread IDs to the owning live Windows process. Require
    # two distinct IDs recorded after that process began to reduce ID-reuse risk.
    $owners = @{}
    foreach ($record in $records) {
        $bestKey = $null
        $bestScore = 1
        $tied = $false
        foreach ($key in $snapshots.Keys) {
            $snapshot = $snapshots[$key]
            if (-not $snapshot.StartUtc) { continue }
            $score = 0
            foreach ($threadKey in $record.ThreadTimes.Keys) {
                if ($snapshot.Threads.ContainsKey($threadKey) -and $record.ThreadTimes[$threadKey] -ge $snapshot.StartUtc.AddSeconds(-2)) {
                    $score++
                }
            }
            if ($score -gt $bestScore) { $bestKey=$key; $bestScore=$score; $tied=$false }
            elseif ($score -eq $bestScore -and $score -ge 2) { $tied=$true }
        }
        if ($bestKey -and -not $tied) { $owners[$record.Path] = $bestKey }
    }
    foreach ($p in $procs) {
        $key = [string]$p.Id
        $snapshot = $snapshots[$key]
        $previous = $script:Resolved[$key]
        $picked = $null
        $candidates = @($records | Where-Object { $owners.ContainsKey($_.Path) -and $owners[$_.Path] -eq $key } |
            Sort-Object LastUtc -Descending)
        if ($candidates.Count) { $picked = $candidates[0] }
        $method = 'Live thread ownership'
        # Timestamp fallback is used only if Windows cannot enumerate threads.
        # Never override contradictory thread ownership with a clock guess.
        if (-not $picked -and $snapshot.StartUtc -and $snapshot.Threads.Count -eq 0) {
            $timeCandidates = @($records | Where-Object {
                $delta = ($_.StartUtc - $snapshot.StartUtc).TotalSeconds
                -not $owners.ContainsKey($_.Path) -and $delta -ge -2 -and $delta -le 120
            })
            if ($timeCandidates.Count -eq 1) {
                $candidate = $timeCandidates[0]
                $possibleOwners = @($snapshots.Values | Where-Object {
                    $_.StartUtc -and ($candidate.StartUtc - $_.StartUtc).TotalSeconds -ge -2 -and
                    ($candidate.StartUtc - $_.StartUtc).TotalSeconds -le 120
                })
                if ($possibleOwners.Count -eq 1) { $picked=$candidate; $method='Unique startup timing (threads unavailable)' }
            }
        }
        $identity = $null
        if ($picked) {
            $script:AssignedLogs[$picked.Path] = $key
            $identity = $picked.Identity
        }
        $reason = 'No log with matching live threads'
        if (-not $snapshot.StartUtc) { $reason = 'Windows process start time unavailable' }
        elseif ($snapshot.Threads.Count -eq 0 -and -not $picked) { $reason = 'Windows thread enumeration unavailable; no unique timing match' }
        elseif ($picked -and -not $identity) { $reason = 'Matched log; waiting for local account fields' }
        elseif ($identity -and $identity.UserId) { $reason = 'Matched log; waiting for username lookup' }
        elseif ($identity) { $reason = 'Username found in matched log' }
        $record = [pscustomobject]@{
            UserId=$(if($identity){$identity.UserId}else{$null})
            Username=$(if($identity){$identity.Username}else{'Unknown'})
            Log=$(if($picked){$picked.Path}else{$null})
            StartTicks=$(if($snapshot.StartUtc){$snapshot.StartUtc.Ticks}else{0})
            Reason=$reason
            Method=$(if($picked){$method}else{'None'})
            ProcessStartUtc=$snapshot.StartUtc
            LiveThreadCount=$snapshot.Threads.Count
            ScannedLogCount=$records.Count
        }
        if ($previous -and $previous.Log -eq $record.Log -and $previous.UserId -eq $record.UserId -and $previous.Username -ne 'Unknown') {
            $record.Username = $previous.Username
        }
        if ($previous -and ($previous.UserId -ne $record.UserId -or $previous.Log -ne $record.Log)) {
            $script:FreezeStart.Remove($key)
        }
        $script:Resolved[$key] = $record
    }
    Update-UsernameLookups
    $script:IdentityScanAt=Get-Date
}

function Is-Alt($id) {
    if (-not $id) { return $false }
    foreach ($a in @($script:Alts)) {
        if ($id.UserId -and $a.UserId -and ([string]$id.UserId -eq [string]$a.UserId)) { return $true }
        if ($id.Username -and $id.Username -ne "Unknown" -and $a.Username -and ($id.Username -ieq $a.Username)) { return $true }
    }
    return $false
}

function Is-Main($id) {
    if (-not $script:Main -or -not $id) { return $false }
    if ($id.UserId -and $script:Main.UserId -and ([string]$id.UserId -eq [string]$script:Main.UserId)) { return $true }
    if ($id.Username -and $id.Username -ne "Unknown" -and $script:Main.Username -and ($id.Username -ieq $script:Main.Username)) { return $true }
    return $false
}

function Trim-Process($proc) { try { [NativeMethods]::EmptyWorkingSet($proc.Handle) | Out-Null } catch {} }
function Kill-Proc($proc) { try { $proc.Kill() } catch {} }
function Minimize-Proc($proc) {
    try { if($proc.MainWindowHandle -ne 0){[NativeMethods]::ShowWindowAsync($proc.MainWindowHandle,6)|Out-Null} } catch {}
}
function Set-MainPriority($proc) { try { $proc.PriorityClass="AboveNormal" } catch {} }
function Set-AltPriority($proc) { try { $proc.PriorityClass="BelowNormal" } catch {} }

function Get-MonitorSnapshot($forceIdentity) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $script:CycleProcesses = @(Get-Process RobloxPlayerBeta -ErrorAction SilentlyContinue)
    $script:CycleStartCache = @{}
    $script:CimStartMap = $null
    try {
        $signature = (@($script:CycleProcesses | ForEach-Object {$_.Id} | Sort-Object) -join ',')
        if ($forceIdentity -or $signature -ne $script:LastProcessSignature) { $script:IdentityScanAt = [datetime]::MinValue }
        $script:LastProcessSignature = $signature
        Assign-LogsToProcesses
        $rows = New-Object 'System.Collections.Generic.List[object]'
        foreach ($p in $script:CycleProcesses) {
            try {
                $p.Refresh()
                $start = Get-ProcessStartUtc $p
                if ($p.HasExited) { continue }
                $key = [string]$p.Id
                $id = $script:Resolved[$key]
                if (-not $id -or -not $start -or $id.StartTicks -ne $start.Ticks) {
                    $id = [pscustomobject]@{UserId=$null;Username='Unknown';Log=$null;Reason='Waiting for account scan';Method='None';LiveThreadCount=0;ScannedLogCount=0}
                    $script:IdentityScanAt = [datetime]::MinValue
                }
                $hung = $null
                try {
                    $window = $p.MainWindowHandle
                    if ($window -ne [IntPtr]::Zero) { $hung = [NativeMethods]::IsHungAppWindow($window) }
                } catch {}
                $priority = ''
                try { $priority = [string]$p.PriorityClass } catch {}
                $rows.Add([pscustomobject]@{
                    Id=$p.Id; StartTicks=$(if($start){$start.Ticks}else{0}); SampledUtc=[datetime]::UtcNow
                    RamMB=[math]::Round($p.WorkingSet64/1MB); Hung=$hung; Priority=$priority
                    UserId=$id.UserId; Username=$id.Username; Log=$id.Log; Reason=$id.Reason
                    Method=$id.Method; ProcessStartUtc=$start; LiveThreadCount=$id.LiveThreadCount; ScannedLogCount=$id.ScannedLogCount
                })
            } catch { continue }
        }
        $memory = New-Object NativeMethods+MemoryStatus
        $memory.Length = [Runtime.InteropServices.Marshal]::SizeOf($memory)
        $memoryOK = [NativeMethods]::GlobalMemoryStatusEx([ref]$memory)
        # Serialize once so the UI receives an independent snapshot, not live worker state.
        [pscustomobject]@{
            Rows=@($rows.ToArray()); DurationMs=$watch.ElapsedMilliseconds; MemoryOK=$memoryOK
            TotalMemory=$memory.TotalPhysical; FreeMemory=$memory.AvailablePhysical
        } | ConvertTo-Json -Depth 6 -Compress
    } finally {
        $script:CycleProcesses = $null
        $script:CycleStartCache = @{}
    }
}

# One persistent runspace owns all log caches and account lookup state.
# Only this function's source is captured; controls never enter the worker.
$workerFunctions = @('Get-RobloxProcesses','Get-RobloxLogs','Read-LogLarge','Parse-IdentityFromText',
    'Parse-IdentityFromLog','Get-LogMetadata','Update-UsernameLookups','Get-ProcessStartUtc',
    'Assign-LogsToProcesses','Get-MonitorSnapshot')
$script:WorkerInit = @'
$script:Resolved=@{}; $script:AssignedLogs=@{}; $script:FreezeStart=@{}
$script:IdentityScanAt=[datetime]::MinValue; $script:LogMetadata=@{}
$script:NameCache=@{}; $script:NameRetryAt=@{}; $script:NameWorker=$null
$script:NameWorkerHandle=$null; $script:NameWorkerIds=@(); $script:LastProcessSignature=''
$script:CycleProcesses=$null; $script:CycleStartCache=@{}; $script:CimStartMap=$null
'@
foreach ($functionName in $workerFunctions) {
    $definition = (Get-Item ('Function:\' + $functionName)).Definition
    $script:WorkerInit += "`nfunction $functionName {`n$definition`n}`n"
}
$script:Monitor = $null
$script:MonitorHandle = $null
$script:MonitorStop = $null
$script:MonitorStarted = [datetime]::MinValue
$script:NextMonitorAt = [datetime]::MinValue
$script:ForceIdentity = $true
$script:Rows = @()
$script:TrimAt = @{}
$script:PriorityApplied = @{}
$script:FrozenSamples = @{}
$script:LastGuardSample = @{}
$script:UiTickBusy = $false
$script:MonitorError = ''

function Get-ValidatedProcess($row) {
    if (-not $row -or -not $row.StartTicks) { return $null }
    try {
        $p = Get-Process -Id ([int]$row.Id) -ErrorAction Stop
        if ($p.ProcessName -ne 'RobloxPlayerBeta' -or $p.StartTime.ToUniversalTime().Ticks -ne [long]$row.StartTicks) { return $null }
        return $p
    } catch { return $null }
}

function Resolve-IdentityForProcess($proc) {
    # UI handlers read only the last snapshot. They must never start a log scan.
    $key = [string]$proc.Id
    if ($script:Resolved.ContainsKey($key)) {
        $row = $script:Resolved[$key]
        if (Get-ValidatedProcess $row) { return $row }
    }
    return [pscustomobject]@{UserId=$null;Username='Unknown';Log=$null;Reason='Waiting for account scan'}
}

$form=New-Object System.Windows.Forms.Form
$form.Text="Roblox RAM Guard v7.9"
$form.Size=New-Object System.Drawing.Size(1030,710)
$form.StartPosition="CenterScreen"
$form.BackColor=[System.Drawing.Color]::FromArgb(24,24,28)
$form.ForeColor=[System.Drawing.Color]::White
$form.Font=New-Object System.Drawing.Font("Segoe UI",10)

$title=New-Object System.Windows.Forms.Label
$title.Text="Roblox RAM Guard v7.9"
$title.Location=New-Object System.Drawing.Point(20,15)
$title.AutoSize=$true
$title.Font=New-Object System.Drawing.Font("Segoe UI Semibold",18)
$form.Controls.Add($title)

$credits=New-Object System.Windows.Forms.Label
$credits.Text="Credits: Stitch - @jhfo on Discord"
$credits.Location=New-Object System.Drawing.Point(23,50)
$credits.AutoSize=$true
$credits.ForeColor=[System.Drawing.Color]::Silver
$form.Controls.Add($credits)

$sysRam=New-Object System.Windows.Forms.Label
$sysRam.Location=New-Object System.Drawing.Point(20,80)
$sysRam.Size=New-Object System.Drawing.Size(450,25)
$form.Controls.Add($sysRam)

$totalRoblox=New-Object System.Windows.Forms.Label
$totalRoblox.Location=New-Object System.Drawing.Point(520,80)
$totalRoblox.Size=New-Object System.Drawing.Size(450,25)
$form.Controls.Add($totalRoblox)

$list=New-Object System.Windows.Forms.ListView
$list.Location=New-Object System.Drawing.Point(20,115)
$list.Size=New-Object System.Drawing.Size(975,365)
$list.View='Details'
$list.FullRowSelect=$true
$list.CheckBoxes=$true
$list.HideSelection=$false
$list.BackColor=[System.Drawing.Color]::FromArgb(32,32,38)
$list.ForeColor=[System.Drawing.Color]::White
$list.Columns.Add("Account",190)|Out-Null
$list.Columns.Add("Role",70)|Out-Null
$list.Columns.Add("PID",75)|Out-Null
$list.Columns.Add("RAM",95)|Out-Null
$list.Columns.Add("Status",110)|Out-Null
$list.Columns.Add("UserId",160)|Out-Null
$list.Columns.Add("Priority",120)|Out-Null
$form.Controls.Add($list)

function Add-Button($text,$x,$y,$w,$handler){
    $b=New-Object System.Windows.Forms.Button
    $b.Text=$text
    $b.Location=New-Object System.Drawing.Point($x,$y)
    $b.Size=New-Object System.Drawing.Size($w,34)
    $b.FlatStyle='Flat'
    $b.BackColor=[System.Drawing.Color]::FromArgb(48,48,58)
    $b.ForeColor=[System.Drawing.Color]::White
    $b.Add_Click($handler)
    $form.Controls.Add($b)
    return $b
}

$settingsBox=New-Object System.Windows.Forms.GroupBox
$settingsBox.Text="Settings"
$settingsBox.Location=New-Object System.Drawing.Point(20,545)
$settingsBox.Size=New-Object System.Drawing.Size(975,95)
$settingsBox.ForeColor=[System.Drawing.Color]::White
$form.Controls.Add($settingsBox)

function Add-Label($parent,$text,$x,$y,$w){
    $l=New-Object System.Windows.Forms.Label
    $l.Text=$text;$l.Location=New-Object System.Drawing.Point($x,$y);$l.Size=New-Object System.Drawing.Size($w,22)
    $parent.Controls.Add($l);return $l
}
function Add-Num($parent,$value,$x,$y,$min,$max,$w=85){
    $n=New-Object System.Windows.Forms.NumericUpDown
    $n.Location=New-Object System.Drawing.Point($x,$y);$n.Size=New-Object System.Drawing.Size($w,25)
    $n.Minimum=$min;$n.Maximum=$max;$n.Value=$value
    $parent.Controls.Add($n);return $n
}

Add-Label $settingsBox "Target MB" 15 28 75|Out-Null
$numTarget=Add-Num $settingsBox ([int]$script:Settings.TrimTargetMB) 90 26 100 8192
Add-Label $settingsBox "Trim at MB" 200 28 80|Out-Null
$numTrigger=Add-Num $settingsBox ([int]$script:Settings.TrimTriggerMB) 285 26 100 8192
Add-Label $settingsBox "Check every (s)" 400 28 100|Out-Null
$numPoll=Add-Num $settingsBox ([int]$script:Settings.PollSeconds) 505 26 1 60
Add-Label $settingsBox "Kill frozen after (s)" 620 28 125|Out-Null
$numFrozen=Add-Num $settingsBox ([int]$script:Settings.FrozenSeconds) 750 26 5 300

$saveSettings=New-Object System.Windows.Forms.Button
$saveSettings.Text="Save Settings"
$saveSettings.Location=New-Object System.Drawing.Point(850,24)
$saveSettings.Size=New-Object System.Drawing.Size(110,32)
$saveSettings.FlatStyle='Flat'
$saveSettings.BackColor=[System.Drawing.Color]::FromArgb(48,48,58)
$saveSettings.ForeColor=[System.Drawing.Color]::White
$settingsBox.Controls.Add($saveSettings)

function Render-Rows {
    $alive = @{}
    $list.BeginUpdate()
    try {
        foreach ($row in $script:Rows) {
            $key = [string]$row.Id
            $alive[$key] = $true
            $role = ''
            if (Is-Main $row) { $role='MAIN' }
            elseif (Is-Alt $row) { $role='ALT' }
            $status = 'Normal'
            if ($row.Hung -eq $true) { $status='Frozen' }
            elseif ($role -eq 'ALT' -and $row.RamMB -ge [int]$script:Settings.TrimTriggerMB) { $status='High RAM' }
            $item = $list.Items[$key]
            if (-not $item) {
                $item = New-Object System.Windows.Forms.ListViewItem([string]$row.Username)
                $item.Name = $key
                $item.Tag = $row.Id
                for ($column=0; $column -lt 6; $column++) { [void]$item.SubItems.Add('') }
                if ($role -eq 'ALT') { $item.Checked=$true }
                [void]$list.Items.Add($item)
            }
            $item.Text = [string]$row.Username
            $item.SubItems[1].Text=$role
            $item.SubItems[2].Text=$key
            $item.SubItems[3].Text="$($row.RamMB) MB"
            $item.SubItems[4].Text=$status
            $item.SubItems[5].Text=[string]$row.UserId
            $item.SubItems[6].Text=[string]$row.Priority
            if ($role -eq 'MAIN') { $item.Checked=$false; $item.BackColor=[Drawing.Color]::FromArgb(40,62,92) }
            elseif ($status -eq 'Frozen') { $item.BackColor=[Drawing.Color]::FromArgb(100,40,40) }
            elseif ($status -eq 'High RAM') { $item.BackColor=[Drawing.Color]::FromArgb(90,75,30) }
            else { $item.BackColor=[Drawing.Color]::FromArgb(34,60,42) }
        }
        foreach ($item in @($list.Items)) {
            if (-not $alive.ContainsKey([string]$item.Tag)) { $list.Items.Remove($item) }
        }
    } finally { $list.EndUpdate() }
}

function Refresh-List {
    $script:ForceIdentity=$true
    $script:NextMonitorAt=[datetime]::MinValue
    Render-Rows
}

function Apply-GuardSnapshot {
    $now = [datetime]::UtcNow
    $alive = @{}
    foreach ($row in $script:Rows) {
        $key = '{0}:{1}' -f $row.Id,$row.StartTicks
        $alive[$key]=$true
        # Stale observations cannot trigger a trim or a frozen-client kill.
        if (($now - [datetime]$row.SampledUtc).TotalSeconds -gt [math]::Max(10,2*[int]$script:Settings.PollSeconds)) { continue }
        $p = Get-ValidatedProcess $row
        if (-not $p) { continue }
        $role = ''
        if (Is-Main $row) { $role='MAIN' }
        elseif (Is-Alt $row) { $role='ALT' }
        if ($role -and $script:PriorityApplied[$key] -ne $role) {
            try {
                $p.PriorityClass = $(if($role -eq 'MAIN'){'AboveNormal'}else{'BelowNormal'})
                $script:PriorityApplied[$key]=$role
            } catch {}
        }
        if ($role -ne 'ALT') {
            $script:FreezeStart.Remove($key); $script:FrozenSamples.Remove($key)
            $script:LastGuardSample.Remove($key)
            continue
        }
        if ($row.Hung -eq $false -and $row.RamMB -ge [int]$script:Settings.TrimTriggerMB -and
            (-not $script:TrimAt.ContainsKey($key) -or ($now-$script:TrimAt[$key]).TotalSeconds -ge 30)) {
            Trim-Process $p
            $script:TrimAt[$key]=$now
        }
        $gap = 0
        if ($script:LastGuardSample.ContainsKey($key)) { $gap=($now-$script:LastGuardSample[$key]).TotalSeconds }
        $script:LastGuardSample[$key]=$now
        # A slow/missed scan is not evidence that a client stayed frozen.
        if ($gap -gt [math]::Max(10,3*[int]$script:Settings.PollSeconds)) {
            $script:FreezeStart.Remove($key); $script:FrozenSamples.Remove($key)
        }
        $age = ($now-[datetime]$row.ProcessStartUtc).TotalSeconds
        if ($row.Hung -eq $true -and $age -ge 60) {
            if (-not $script:FreezeStart.ContainsKey($key)) {
                $script:FreezeStart[$key]=$now; $script:FrozenSamples[$key]=1
            } else {
                $script:FrozenSamples[$key]++
                if ($script:FrozenSamples[$key] -ge 3 -and ($now-$script:FreezeStart[$key]).TotalSeconds -ge [int]$script:Settings.FrozenSeconds) {
                    Kill-Proc $p
                    $script:FreezeStart.Remove($key); $script:FrozenSamples.Remove($key)
                }
            }
        } else { $script:FreezeStart.Remove($key); $script:FrozenSamples.Remove($key) }
    }
    foreach ($cache in @($script:FreezeStart,$script:FrozenSamples,$script:LastGuardSample,$script:TrimAt,$script:PriorityApplied)) {
        foreach ($key in @($cache.Keys)) { if (-not $alive.ContainsKey($key)) { $cache.Remove($key) } }
    }
}

function Update-MetersAndGuard {
    if ($script:UiTickBusy) { return }
    $script:UiTickBusy=$true
    try {
        $now=Get-Date
        if ($script:MonitorHandle) {
            if ($script:MonitorHandle.IsCompleted -and (-not $script:MonitorStop -or $script:MonitorStop.IsCompleted)) {
                try {
                    if ($script:MonitorStop) { $script:Monitor.EndStop($script:MonitorStop) }
                    $output=@($script:Monitor.EndInvoke($script:MonitorHandle))
                    if ($output.Count) {
                        $snapshot=[string]$output[-1] | ConvertFrom-Json -ErrorAction Stop
                        $newResolved=@{}
                        $script:Rows=@($snapshot.Rows)
                        foreach ($row in $script:Rows) { $newResolved[[string]$row.Id]=$row }
                        $script:Resolved=$newResolved
                        if ($snapshot.MemoryOK) {
                            $total=[math]::Round($snapshot.TotalMemory/1GB,1)
                            $used=[math]::Round(($snapshot.TotalMemory-$snapshot.FreeMemory)/1GB,1)
                            $pct=[math]::Round(100*($snapshot.TotalMemory-$snapshot.FreeMemory)/$snapshot.TotalMemory)
                            $sysRam.Text="System RAM: $used / $total GB ($pct%)"
                        }
                        $sum=0; foreach($row in $script:Rows){$sum+=$row.RamMB}
                        $totalRoblox.Text="Total Roblox RAM: $([math]::Round($sum/1024,2)) GB"
                        Render-Rows
                        Apply-GuardSnapshot
                        $info.Text="v7.9: $($script:Rows.Count) clients | Scan: $([math]::Round($snapshot.DurationMs/1000,1))s | Trim cooldown: 30s"
                    } else { $info.Text='No scan result. Retrying in the background.' }
                } catch { $script:MonitorError=$_.Exception.Message; $info.Text='Scan interrupted. Retrying in the background.' }
                $script:MonitorHandle=$null
                $script:MonitorStop=$null
                $script:NextMonitorAt=$now.AddSeconds([int]$script:Settings.PollSeconds)
            } elseif (-not $script:MonitorStop -and ($now-$script:MonitorStarted).TotalSeconds -gt 60) {
                # Cancellation is asynchronous. Never stack new scans behind a stuck one.
                $script:MonitorStop=$script:Monitor.BeginStop($null,$null)
                $info.Text='Slow scan: cancellation requested. Controls remain available.'
            } else { return }
        }
        if (-not $script:MonitorHandle -and ($script:ForceIdentity -or $now -ge $script:NextMonitorAt)) {
            if (-not $script:Monitor) {
                $script:Monitor=[PowerShell]::Create()
                [void]$script:Monitor.AddScript($script:WorkerInit, $false).AddStatement()
            } else { $script:Monitor.Commands.Clear(); $script:Monitor.Streams.Error.Clear() }
            [void]$script:Monitor.AddScript('param($force) Get-MonitorSnapshot $force', $false).AddArgument($script:ForceIdentity)
            $script:ForceIdentity=$false
            $script:MonitorStarted=$now
            $script:MonitorHandle=$script:Monitor.BeginInvoke()
        }
    } catch { $script:MonitorError=$_.Exception.Message; $info.Text='Monitor could not start. Double-click this status for details.' }
    finally { $script:UiTickBusy=$false }
}

Add-Button "Refresh" 20 495 100 {Refresh-List}|Out-Null
Add-Button "Trim Selected" 130 495 125 {
    foreach($it in $list.CheckedItems){
        if($it.SubItems[1].Text -ne "MAIN"){
            $p=Get-ValidatedProcess $script:Resolved[[string]$it.Tag]
            if($p){Trim-Process $p}
        }
    }
}|Out-Null

Add-Button "Trim All Alts" 265 495 125 {
    foreach($p in Get-RobloxProcesses){
        $id=Resolve-IdentityForProcess $p
        if((Is-Alt $id) -and -not(Is-Main $id)){Trim-Process $p}
    }
}|Out-Null

Add-Button "Kill Selected" 400 495 120 {
    if([System.Windows.Forms.MessageBox]::Show("Kill selected Roblox instances?","Confirm",'YesNo') -eq 'Yes'){
        foreach($it in @($list.CheckedItems)){
            if($it.SubItems[1].Text -ne "MAIN"){
                $p=Get-ValidatedProcess $script:Resolved[[string]$it.Tag]
                if($p){Kill-Proc $p}
            }
        }
    }
}|Out-Null

Add-Button "Kill All Frozen" 530 495 125 {
    foreach($row in $script:Rows){
        if($row.Hung -eq $true -and -not(Is-Main $row) -and
            ([datetime]::UtcNow-[datetime]$row.SampledUtc).TotalSeconds -le 10){
            $p=Get-ValidatedProcess $row
            if($p){Kill-Proc $p}
        }
    }
}|Out-Null

Add-Button "Minimize All Alts" 665 495 145 {
    foreach($p in Get-RobloxProcesses){
        $id=Resolve-IdentityForProcess $p
        if((Is-Alt $id) -and -not(Is-Main $id)){Minimize-Proc $p}
    }
}|Out-Null

Add-Button "Mark as Alt" 820 495 110 {
    foreach($it in $list.SelectedItems){
        $p=Get-ValidatedProcess $script:Resolved[[string]$it.Tag]
        if($p){
            $id=Resolve-IdentityForProcess $p
            if($id.Username -ne "Unknown"){
                if(Is-Main $id){$script:Main=$null;Save-JsonFile $script:MainFile $null}
                if(-not(Is-Alt $id)){
                    $script:Alts += [pscustomobject]@{UserId=$id.UserId;Username=$id.Username}
                    Save-JsonFile $script:AltFile $script:Alts
                }
            }
        }
    }
    Refresh-List
}|Out-Null

Add-Button "Remove Alt" 20 650 105 {
    foreach($it in $list.SelectedItems){
        $uid=$it.SubItems[5].Text
        $uname=$it.Text
        $script:Alts=@($script:Alts|Where-Object{-not(
            ($uid -and $_.UserId -and ([string]$_.UserId -eq [string]$uid)) -or
            ($uname -ne "Unknown" -and $_.Username -and ($_.Username -ieq $uname))
        )})
    }
    Save-JsonFile $script:AltFile $script:Alts
    Refresh-List
}|Out-Null

Add-Button "Mark as Main" 135 650 120 {
    if($list.SelectedItems.Count -gt 0){
        $it=$list.SelectedItems[0]
        $p=Get-ValidatedProcess $script:Resolved[[string]$it.Tag]
        if($p){
            $id=Resolve-IdentityForProcess $p
            if($id.Username -ne "Unknown"){
                $script:Main=[pscustomobject]@{UserId=$id.UserId;Username=$id.Username}
                Save-JsonFile $script:MainFile $script:Main
                $script:Alts=@($script:Alts|Where-Object{-not(
                    ($id.UserId -and $_.UserId -and ([string]$_.UserId -eq [string]$id.UserId)) -or
                    ($id.Username -and $_.Username -and ($_.Username -ieq $id.Username))
                )})
                Save-JsonFile $script:AltFile $script:Alts
            }
        }
    }
    Refresh-List
}|Out-Null

Add-Button "Clear Main" 265 650 100 {
    $script:Main=$null
    Save-JsonFile $script:MainFile $null
    Refresh-List
}|Out-Null

$saveSettings.Add_Click({
    $target=[int]$numTarget.Value
    $trigger=[int]$numTrigger.Value
    if($trigger -le $target){
        [System.Windows.Forms.MessageBox]::Show("Trim trigger must be higher than the target.","Settings")|Out-Null
        return
    }
    $script:Settings.TrimTargetMB=$target
    $script:Settings.TrimTriggerMB=$trigger
    $script:Settings.PollSeconds=[int]$numPoll.Value
    $script:Settings.FrozenSeconds=[int]$numFrozen.Value
    Save-JsonFile $script:SettingsFile $script:Settings
    $script:NextMonitorAt=[datetime]::MinValue
    [System.Windows.Forms.MessageBox]::Show("Settings saved.","Roblox RAM Guard")|Out-Null
})

$info=New-Object System.Windows.Forms.Label
$info.Text="v7.9: Starting background monitor..."
$info.Location=New-Object System.Drawing.Point(390,655)
$info.Size=New-Object System.Drawing.Size(600,25)
$info.ForeColor=[System.Drawing.Color]::Silver
$form.Controls.Add($info)
$info.Add_DoubleClick({
    $state=if($script:MonitorHandle){'Scanning'}else{'Waiting for next scan'}
    $elapsed=if($script:MonitorHandle){[math]::Round(((Get-Date)-$script:MonitorStarted).TotalSeconds,1)}else{0}
    [void][System.Windows.Forms.MessageBox]::Show("State: $state`r`nCurrent scan: $elapsed seconds`r`nLast monitor error: $($script:MonitorError)", 'Monitor details')
})

$timer=New-Object System.Windows.Forms.Timer
$timer.Interval=250
$timer.Add_Tick({Update-MetersAndGuard})
# Paint the window before any Roblox enumeration, WMI query or log scan.
$form.Add_Shown({$timer.Start()})

$list.Add_DoubleClick({
    if ($list.SelectedItems.Count -eq 0) { return }
    $key = [string]$list.SelectedItems[0].Tag
    $identity = $script:Resolved[$key]
    if (-not $identity) { return }
    $reason = $identity.Reason
    if ($identity.Username -ne 'Unknown') { $reason = 'Username resolved' }
    $logName = if($identity.Log){[IO.Path]::GetFileName($identity.Log)}else{'None'}
    $details = "PID: $key`r`nAccount: $($identity.Username)`r`nUserId: $($identity.UserId)`r`nDetection: $reason`r`nMatch: $($identity.Method)`r`nProcess start UTC: $($identity.ProcessStartUtc)`r`nLive threads: $($identity.LiveThreadCount)`r`nScanned logs: $($identity.ScannedLogCount)`r`nLog: $logName`r`n`r`nJoin a game to write account telemetry. Failed username lookups retry every 60 seconds. If still Unknown, send this details box."
    [void][System.Windows.Forms.MessageBox]::Show($details, 'Account detection details')
})
try { [void]$form.ShowDialog() }
finally {
    $timer.Stop()
    if ($script:Monitor) {
        if ($script:MonitorHandle -and -not $script:MonitorHandle.IsCompleted) {
            if (-not $script:MonitorStop) { [void]$script:Monitor.BeginStop($null,$null) }
        } else { $script:Monitor.Dispose() }
    }
    $timer.Dispose()
    $form.Dispose()
}
