
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'RamGuard.Core.ps1'))) { throw 'RamGuard.Core.ps1 is missing. Extract the complete ZIP.' }
. (Join-Path $PSScriptRoot 'RamGuard.Core.ps1')
$script:DataDirectory=Join-Path $env:LOCALAPPDATA 'RobloxRAMGuard'
$script:ProfilePath=Join-Path $script:DataDirectory 'profile.json'
$profileState=Initialize-GuardProfile $script:DataDirectory $PSScriptRoot
$script:Main=$profileState.Profile.Main
$script:Alts=@($profileState.Profile.Alts)
$script:Settings=$profileState.Profile.Settings
$script:CanSaveProfile=$profileState.CanSave
$script:Resolved=@{}; $script:AssignedLogs=@{}; $script:FreezeStart=@{}; $script:KnownPids=@()

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
  [DllImport("user32.dll")]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")]
  public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
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

function Is-Alt($row) { return Test-ManagedAlt $row $script:Main $script:Alts }
function Is-Main($row) { return Test-SameAccount $row $script:Main }

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
# The dedicated runspace owns these variables across separate pipeline scripts.
$script:WorkerInit = $script:WorkerInit.Replace('$script:', '$global:')
$script:Monitor = $null
$script:MonitorHandle = $null
$script:MonitorStop = $null
$script:MonitorStarted = [datetime]::MinValue
$script:NextMonitorAt = [datetime]::MinValue
$script:ForceIdentity = $true
$script:Rows = @()
$script:TrimAt = @{}
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

$script:GuardEnabled=$false
$script:Armed=@{}
$script:InstanceAccounts=@{}
function Get-CurrentProfile {
    return [pscustomobject]@{SchemaVersion=1;Main=$script:Main;Alts=@($script:Alts);Settings=$script:Settings}
}
function Commit-Profile($candidate,[switch]$Recover) {
    if(-not $script:CanSaveProfile -and -not $Recover){throw 'Import a valid backup before saving changes.'}
    $saved=Write-GuardProfile $script:ProfilePath $candidate
    $script:Main=$saved.Main; $script:Alts=@($saved.Alts); $script:Settings=$saved.Settings
    $script:CanSaveProfile=$true
}
function Show-ActionError($message) {
    [void][Windows.Forms.MessageBox]::Show([string]$message,'RAM Guard','OK','Warning')
}
function Get-SelectedRows {
    foreach($item in $list.SelectedItems){
        $row=$script:Resolved[[string]$item.Tag]
        if($row -and (Get-InstanceKey $row) -eq $item.Name){$row}
    }
}
function Update-InstanceStates {
    $live=@{}
    foreach($row in $script:Rows){
        $key=Get-InstanceKey $row; $accountKey=Get-AccountKey $row; $live[$key]=$true
        if(-not $script:InstanceAccounts.ContainsKey($key) -or $script:InstanceAccounts[$key] -ne $accountKey){
            $script:Armed[$key]=$false
            $script:InstanceAccounts[$key]=$accountKey
        }
    }
    foreach($cache in @($script:Armed,$script:InstanceAccounts,$script:TrimAt,$script:FreezeStart,$script:FrozenSamples,$script:LastGuardSample)){
        foreach($key in @($cache.Keys)){if(-not $live.ContainsKey($key)){$cache.Remove($key)}}
    }
}
function Set-GuardEnabled([bool]$enabled) {
    $script:GuardEnabled=$enabled
    $script:FreezeStart.Clear();$script:FrozenSamples.Clear();$script:LastGuardSample.Clear()
    if($enabled){Set-AltArmed $script:Rows $true}
    Update-GuardControl
    Render-Rows
}
function Set-AltArmed($rows,[bool]$enabled) {
    foreach($row in @($rows)){
        if(Test-ManagedAlt $row $script:Main $script:Alts){
            $key=Get-InstanceKey $row
            $script:Armed[$key]=$enabled
            $script:FreezeStart.Remove($key);$script:FrozenSamples.Remove($key);$script:LastGuardSample.Remove($key)
        }
    }
}
function Open-SelectedWindow {
    $rows=@(Get-SelectedRows)
    if($rows.Count -ne 1){$info.Text='Select one client to open its window.';return}
    $p=Get-ValidatedProcess $rows[0]
    if(-not $p){$info.Text='That client has closed or restarted. Refresh the list.';return}
    try{
        $p.Refresh();$window=$p.MainWindowHandle
        if($window -eq [IntPtr]::Zero){$info.Text='This client does not have a window ready yet.';return}
        [uint32]$ownerId=0
        [void][NativeMethods]::GetWindowThreadProcessId($window,[ref]$ownerId)
        if($ownerId -ne $p.Id){$info.Text='Window ownership changed. Refresh and try again.';return}
        if([NativeMethods]::IsIconic($window)){[void][NativeMethods]::ShowWindowAsync($window,9)}
        else{[void][NativeMethods]::ShowWindowAsync($window,5)}
        if([NativeMethods]::SetForegroundWindow($window)){$info.Text='Opened '+$rows[0].Username}
        else{$info.Text='Window restored. Windows kept the current app focused; select it on the taskbar.'}
    }catch{Show-ActionError $_.Exception.Message}
}
function Invoke-AltAction($rows,$action) {
    $count=0
    foreach($row in @($rows)){
        # This gate applies even to manual actions while automation is OFF.
        if(-not (Test-ManagedAlt $row $script:Main $script:Alts)){continue}
        $p=Get-ValidatedProcess $row
        if(-not $p){continue}
        try{
            switch($action){
                'Trim' {
                    if(-not [NativeMethods]::EmptyWorkingSet($p.Handle)){continue}
                    $script:TrimAt[(Get-InstanceKey $row)]=[datetime]::UtcNow
                }
                'Minimize' {[void][NativeMethods]::ShowWindowAsync($p.MainWindowHandle,6)}
                'Close' {$p.Kill()}
            }
            $count++
        }catch{}
    }
    $info.Text="$action completed for $count alt(s). Main accounts are protected."
}
function Confirm-CloseAlts($rows) {
    $targets=@($rows | Where-Object {Test-ManagedAlt $_ $script:Main $script:Alts})
    if(-not $targets.Count){$info.Text='No saved alts selected for closing.';return}
    if([Windows.Forms.MessageBox]::Show("Close $($targets.Count) selected alt window(s)?",'Close alts','YesNo','Warning') -eq 'Yes'){
        Invoke-AltAction $targets 'Close'
    }
}
function Set-SelectedRole($role) {
    $selected=@(Get-SelectedRows)
    if($role -ne 'ClearMain' -and -not $selected.Count){$info.Text='Select an account first.';return}
    if($role -eq 'Main' -and $selected.Count -ne 1){$info.Text='Select one account to make Main.';return}
    try{
        $profile=Get-CurrentProfile
        if($role -eq 'ClearMain'){
            if([Windows.Forms.MessageBox]::Show('Remove protection from the saved Main account?','Clear Main','YesNo','Question') -ne 'Yes'){return}
            $profile.Main=$null
        }
        foreach($row in $selected){
            if(-not (Get-ValidatedProcess $row)){continue}
            $account=ConvertTo-GuardAccount $row
            switch($role){
                'Main' {$profile.Main=$account;$profile.Alts=@($profile.Alts | Where-Object {-not(Test-SameAccount $_ $account)})}
                'Alt' {
                    # Main must be explicitly cleared first; a bulk role change cannot remove protection.
                    if(Test-SameAccount $account $profile.Main){continue}
                    if(-not(Test-ManagedAlt $account $profile.Main $profile.Alts)){$profile.Alts=@($profile.Alts)+@($account)}
                }
                'RemoveAlt' {$profile.Alts=@($profile.Alts | Where-Object {-not(Test-SameAccount $_ $account)})}
            }
            $script:Armed[(Get-InstanceKey $row)]=$false
        }
        Commit-Profile $profile
        $script:FreezeStart.Clear();$script:FrozenSamples.Clear();$script:LastGuardSample.Clear()
        Render-Rows
        $info.Text='Account roles saved. Newly assigned alts stay paused until enabled.'
    }catch{Show-ActionError $_.Exception.Message}
}
function Show-AccountDetails {
    $rows=@(Get-SelectedRows);if($rows.Count -ne 1){return};$r=$rows[0]
    $logName=if($r.Log){[IO.Path]::GetFileName($r.Log)}else{'None'}
    [void][Windows.Forms.MessageBox]::Show("Account: $($r.Username)`r`nUserId: $($r.UserId)`r`nPID: $($r.Id)`r`nDetection: $($r.Reason)`r`nMatch: $($r.Method)`r`nLive threads: $($r.LiveThreadCount)`r`nLogs scanned: $($r.ScannedLogCount)`r`nLog: $logName",'Account details')
}
function Export-ProfileBackup {
    $dialog=New-Object Windows.Forms.SaveFileDialog
    $dialog.Filter='RAM Guard backup (*.json)|*.json';$dialog.FileName='RAM_Guard_Backup_'+(Get-Date -Format 'yyyy-MM-dd_HH-mm')+'.json'
    try{
        if($dialog.ShowDialog() -eq 'OK'){
            [void](Write-GuardProfile $dialog.FileName (Get-CurrentProfile))
            $info.Text='Backup exported: account roles and settings.'
        }
    }catch{Show-ActionError $_.Exception.Message}finally{$dialog.Dispose()}
}
function Import-ProfileBackup([bool]$legacy) {
    Set-GuardEnabled $false
    $dialog=if($legacy){New-Object Windows.Forms.FolderBrowserDialog}else{New-Object Windows.Forms.OpenFileDialog}
    if($legacy){$dialog.Description='Choose the old RAM Guard folder containing alts.json, main.json and settings.json.'}
    else{$dialog.Filter='RAM Guard backup (*.json)|*.json'}
    try{
        if($dialog.ShowDialog() -ne 'OK'){return}
        $candidate=if($legacy){Read-LegacyProfile $dialog.SelectedPath}else{ConvertTo-GuardProfile (Read-GuardJson $dialog.FileName)}
        $mainName=if($candidate.Main){$candidate.Main.Username}else{'None'}
        if([Windows.Forms.MessageBox]::Show("Import $(@($candidate.Alts).Count) alt(s), Main: $mainName, and their settings? Your current profile will be backed up.",'Import profile','YesNo','Question') -ne 'Yes'){return}
        Commit-Profile $candidate -Recover
        $script:Armed.Clear();$script:InstanceAccounts.Clear();Update-InstanceStates
        Load-SettingsControls;Render-Rows
        $info.Text='Profile imported. Alt Guard is OFF so clients can load safely.'
        $saveNotice.Text='Your settings and account roles are saved outside the update folder.'
    }catch{Show-ActionError $_.Exception.Message}finally{$dialog.Dispose()}
}
function Load-SettingsControls {
    $numTrigger.Value=$script:Settings.TrimTriggerMB;$numPoll.Value=$script:Settings.PollSeconds
    $numFrozen.Value=$script:Settings.FrozenSeconds;$numCooldown.Value=$script:Settings.TrimCooldownSeconds
    $closeFrozen.Checked=$script:Settings.CloseFrozen
}

function Update-GuardControl {
    if($script:GuardEnabled){$guardToggle.Text='ALT GUARD: ON';$guardToggle.BackColor=[Drawing.Color]::FromArgb(37,119,92)}
    else{$guardToggle.Text='ALT GUARD: OFF';$guardToggle.BackColor=[Drawing.Color]::FromArgb(136,95,35)}
    $guardToggle.ForeColor=[Drawing.Color]::White
}
function Render-Rows {
    $visible=@{}
    $filter=if($search){$search.Text.Trim()}else{''}
    $list.BeginUpdate()
    try{
        foreach($row in $script:Rows){
            if($filter -and (('{0} {1} {2}' -f $row.Username,$row.UserId,$row.Id).IndexOf($filter,[StringComparison]::OrdinalIgnoreCase) -lt 0)){continue}
            $key=Get-InstanceKey $row;$visible[$key]=$true
            $role='-';$guard='Unmanaged'
            if(Is-Main $row){$role='MAIN';$guard='Protected'}
            elseif(Is-Alt $row){
                $role='ALT'
                $guard=if(-not $script:GuardEnabled){'Global OFF'}elseif($script:Armed[$key]){'ON'}else{'Paused'}
            }
            $status=if($row.Hung -eq $true){'Frozen'}elseif($row.Hung -eq $null){'Loading'}elseif($row.RamMB -ge $script:Settings.TrimTriggerMB){'High RAM'}else{'Normal'}
            $item=$list.Items[$key]
            if(-not $item){
                $item=New-Object Windows.Forms.ListViewItem([string]$row.Username)
                $item.Name=$key;$item.Tag=$row.Id
                for($column=0;$column -lt 6;$column++){[void]$item.SubItems.Add('')}
                [void]$list.Items.Add($item)
            }
            $item.Text=[string]$row.Username
            $item.SubItems[1].Text=$role;$item.SubItems[2].Text=$guard
            $item.SubItems[3].Text="$($row.RamMB) MB";$item.SubItems[4].Text=$status
            $item.SubItems[5].Text=[string]$row.Id;$item.SubItems[6].Text=[string]$row.UserId
            $item.BackColor=if($role -eq 'MAIN'){[Drawing.Color]::FromArgb(30,51,77)}elseif($status -eq 'Frozen'){[Drawing.Color]::FromArgb(76,34,44)}elseif($guard -eq 'ON'){[Drawing.Color]::FromArgb(25,53,48)}else{[Drawing.Color]::FromArgb(25,30,41)}
        }
        foreach($item in @($list.Items)){if(-not $visible.ContainsKey($item.Name)){$list.Items.Remove($item)}}
        $mainMetric.Text=if($script:Main){[string]$script:Main.Username}else{'Not assigned'}
    }finally{$list.EndUpdate()}
}
function Refresh-List {$script:ForceIdentity=$true;$script:NextMonitorAt=[datetime]::MinValue;Render-Rows}
function Apply-GuardSnapshot {
    if(-not $script:GuardEnabled){
        $script:FreezeStart.Clear();$script:FrozenSamples.Clear();$script:LastGuardSample.Clear()
        return
    }
    $now=[datetime]::UtcNow;$alive=@{}
    foreach($row in $script:Rows){
        $key=Get-InstanceKey $row;$alive[$key]=$true
        if(-not(Test-GuardEligible $row $script:Main $script:Alts $script:GuardEnabled $script:Armed)){
            $script:FreezeStart.Remove($key);$script:FrozenSamples.Remove($key);$script:LastGuardSample.Remove($key)
            continue
        }
        if(($now-[datetime]$row.SampledUtc).TotalSeconds -gt [math]::Max(10,2*$script:Settings.PollSeconds)){continue}
        $p=Get-ValidatedProcess $row;if(-not $p){continue}
        if($row.Hung -eq $false -and $row.RamMB -ge $script:Settings.TrimTriggerMB -and
            (-not $script:TrimAt.ContainsKey($key) -or ($now-$script:TrimAt[$key]).TotalSeconds -ge $script:Settings.TrimCooldownSeconds)){
            # No priority changes are applied, including to Main.
            try{if([NativeMethods]::EmptyWorkingSet($p.Handle)){$script:TrimAt[$key]=$now}}catch{}
        }
        if(-not $script:Settings.CloseFrozen){$script:FreezeStart.Remove($key);$script:FrozenSamples.Remove($key);continue}
        $gap=0;if($script:LastGuardSample.ContainsKey($key)){$gap=($now-$script:LastGuardSample[$key]).TotalSeconds}
        $script:LastGuardSample[$key]=$now
        if($gap -gt [math]::Max(10,3*$script:Settings.PollSeconds)){$script:FreezeStart.Remove($key);$script:FrozenSamples.Remove($key)}
        $age=($now-[datetime]$row.ProcessStartUtc).TotalSeconds
        if($row.Hung -eq $true -and $age -ge 60){
            if(-not $script:FreezeStart.ContainsKey($key)){$script:FreezeStart[$key]=$now;$script:FrozenSamples[$key]=1}
            else{
                $script:FrozenSamples[$key]++
                if($script:FrozenSamples[$key] -ge 3 -and ($now-$script:FreezeStart[$key]).TotalSeconds -ge $script:Settings.FrozenSeconds){
                    try{$p.Kill()}catch{}
                    $script:FreezeStart.Remove($key);$script:FrozenSamples.Remove($key)
                }
            }
        }else{$script:FreezeStart.Remove($key);$script:FrozenSamples.Remove($key)}
    }
    foreach($cache in @($script:FreezeStart,$script:FrozenSamples,$script:LastGuardSample,$script:TrimAt)){
        foreach($key in @($cache.Keys)){if(-not $alive.ContainsKey($key)){$cache.Remove($key)}}
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
                        Update-InstanceStates
                        if ($snapshot.MemoryOK) {
                            $total=[math]::Round($snapshot.TotalMemory/1GB,1)
                            $used=[math]::Round(($snapshot.TotalMemory-$snapshot.FreeMemory)/1GB,1)
                            $pct=[math]::Round(100*($snapshot.TotalMemory-$snapshot.FreeMemory)/$snapshot.TotalMemory)
                            $sysRam.Text="$used / $total GB ($pct%)"
                        }
                        $sum=0; foreach($row in $script:Rows){$sum+=$row.RamMB}
                        $totalRoblox.Text="$([math]::Round($sum/1024,2)) GB"
                        Render-Rows
                        Apply-GuardSnapshot
                        $info.Text="$($script:Rows.Count) clients | Scan $([math]::Round($snapshot.DurationMs/1000,1))s | New clients start paused | Stitch / @jhfo"
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
            $scanScript='param($force)' + "`n"
            if (-not $script:Monitor) {
                $script:Monitor=[PowerShell]::Create()
                $scanScript += $script:WorkerInit + "`n"
            } else { $script:Monitor.Commands.Clear(); $script:Monitor.Streams.Error.Clear() }
            # Keep one pipeline statement: retained batches can rerun initialization.
            $scanScript += 'Get-MonitorSnapshot $force'
            [void]$script:Monitor.AddScript($scanScript, $false).AddArgument($script:ForceIdentity)
            $script:ForceIdentity=$false
            $script:MonitorStarted=$now
            $script:MonitorHandle=$script:Monitor.BeginInvoke()
        }
    } catch { $script:MonitorError=$_.Exception.Message; $info.Text='Monitor could not start. Double-click this status for details.' }
    finally { $script:UiTickBusy=$false }
}


[Windows.Forms.Application]::EnableVisualStyles()
$bg=[Drawing.Color]::FromArgb(17,20,28)
$panelColor=[Drawing.Color]::FromArgb(25,30,41)
$muted=[Drawing.Color]::FromArgb(158,170,190)
$accent=[Drawing.Color]::FromArgb(104,90,225)
$form=New-Object Windows.Forms.Form
$form.Text='RAM Guard v8.0'
$form.ClientSize=New-Object Drawing.Size(1120,780)
$form.MinimumSize=New-Object Drawing.Size(1000,740)
$form.StartPosition='CenterScreen';$form.BackColor=$bg;$form.ForeColor=[Drawing.Color]::White
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$form.AutoScaleMode='Dpi'
function New-Label($text,$size=10,$color=$null){
    $label=New-Object Windows.Forms.Label
    $label.Text=$text;$label.Dock='Fill';$label.TextAlign='MiddleLeft';$label.AutoEllipsis=$true
    $label.Font=New-Object Drawing.Font('Segoe UI',[single]$size)
    $label.ForeColor=if($color){$color}else{[Drawing.Color]::White}
    return $label
}
function New-Flow {
    $flow=New-Object Windows.Forms.FlowLayoutPanel
    $flow.Dock='Fill';$flow.AutoSize=$true;$flow.WrapContents=$true
    $flow.Margin=New-Object Windows.Forms.Padding(0)
    return $flow
}
function New-Button($parent,$text,$handler,$width=135,[switch]$Primary){
    $button=New-Object Windows.Forms.Button
    $button.Text=$text;$button.Size=New-Object Drawing.Size($width,38)
    $button.Margin=New-Object Windows.Forms.Padding(0,0,8,8)
    $button.FlatStyle='Flat';$button.FlatAppearance.BorderSize=0
    $button.BackColor=if($Primary){$accent}else{[Drawing.Color]::FromArgb(43,51,68)}
    $button.ForeColor=[Drawing.Color]::White;$button.Cursor='Hand'
    $button.Add_Click($handler)
    [void]$parent.Controls.Add($button)
    return $button
}
function New-SectionTag($flow,$text){
    $label=New-Label $text 9 $muted
    $label.Dock='None';$label.Size=New-Object Drawing.Size(85,38)
    $label.Margin=New-Object Windows.Forms.Padding(0,0,4,8)
    [void]$flow.Controls.Add($label)
}
$root=New-Object Windows.Forms.TableLayoutPanel
$root.Dock='Fill';$root.Padding=New-Object Windows.Forms.Padding(20,14,20,10)
$root.ColumnCount=1;$root.RowCount=4
[void]$root.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
foreach($height in @(72,84)){[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height)))}
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',34)))
$form.Controls.Add($root)
$header=New-Object Windows.Forms.TableLayoutPanel
$header.Dock='Fill';$header.ColumnCount=2;$header.RowCount=1
[void]$header.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',70)))
[void]$header.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',30)))
$brand=New-Object Windows.Forms.TableLayoutPanel
$brand.Dock='Fill';$brand.RowCount=2;$brand.ColumnCount=1
[void]$brand.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',60)))
[void]$brand.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',40)))
$brand.Controls.Add((New-Label 'RAM GUARD  /  8.0' 21),0,0)
$brand.Controls.Add((New-Label 'Load your clients. Choose when the alts are ready.' 10 $muted),0,1)
$header.Controls.Add($brand,0,0)
$guardToggle=New-Object Windows.Forms.Button
$guardToggle.Dock='Fill';$guardToggle.Margin=New-Object Windows.Forms.Padding(20,8,0,12)
$guardToggle.FlatStyle='Flat';$guardToggle.FlatAppearance.BorderSize=0;$guardToggle.Cursor='Hand'
$guardToggle.Font=New-Object Drawing.Font('Segoe UI',12,[Drawing.FontStyle]::Bold)
$guardToggle.Add_Click({Set-GuardEnabled (-not $script:GuardEnabled)})
$header.Controls.Add($guardToggle,1,0)
$root.Controls.Add($header,0,0)
$metrics=New-Object Windows.Forms.TableLayoutPanel
$metrics.Dock='Fill';$metrics.ColumnCount=3;$metrics.RowCount=1
foreach($width in @(34,33,33)){[void]$metrics.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',$width)))}
function New-Metric($caption,$index){
    $card=New-Object Windows.Forms.TableLayoutPanel
    $card.Dock='Fill';$card.BackColor=$panelColor;$card.Padding=New-Object Windows.Forms.Padding(14,7,14,7)
    $card.Margin=New-Object Windows.Forms.Padding(0,0,8,10);$card.RowCount=2;$card.ColumnCount=1
    [void]$card.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',23)))
    [void]$card.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
    $card.Controls.Add((New-Label $caption 9 $muted),0,0)
    $value=New-Label 'Waiting for scan...' 13
    $card.Controls.Add($value,0,1);$metrics.Controls.Add($card,$index,0)
    return $value
}
$sysRam=New-Metric 'SYSTEM MEMORY' 0
$totalRoblox=New-Metric 'ROBLOX MEMORY' 1
$mainMetric=New-Metric 'MAIN ACCOUNT / PROTECTED' 2
$root.Controls.Add($metrics,0,1)
$tabs=New-Object Windows.Forms.TabControl
$tabs.Dock='Fill';$tabs.SizeMode='Fixed';$tabs.ItemSize=New-Object Drawing.Size(165,34)
$clientsPage=New-Object Windows.Forms.TabPage('Clients')
$settingsPage=New-Object Windows.Forms.TabPage('Settings & Saves')
foreach($page in @($clientsPage,$settingsPage)){$page.BackColor=$panelColor;$page.ForeColor=[Drawing.Color]::White;$page.Padding=New-Object Windows.Forms.Padding(12);[void]$tabs.TabPages.Add($page)}
$root.Controls.Add($tabs,0,2)
$clientLayout=New-Object Windows.Forms.TableLayoutPanel
$clientLayout.Dock='Fill';$clientLayout.RowCount=5;$clientLayout.ColumnCount=1
[void]$clientLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
[void]$clientLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',48)))
[void]$clientLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$clientLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',32)))
[void]$clientLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
[void]$clientLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
$clientsPage.Controls.Add($clientLayout)
$searchBar=New-Flow
New-SectionTag $searchBar 'FIND CLIENT'
$search=New-Object Windows.Forms.TextBox
$search.Width=260;$search.BackColor=[Drawing.Color]::FromArgb(36,43,57);$search.ForeColor=[Drawing.Color]::White
$search.Margin=New-Object Windows.Forms.Padding(0,6,12,6)
$search.Add_TextChanged({Render-Rows})
$searchBar.Controls.Add($search)
[void](New-Button $searchBar 'Refresh' {Refresh-List} 100)
[void](New-Button $searchBar 'Account details' {Show-AccountDetails} 140)
$clientLayout.Controls.Add($searchBar,0,0)
$list=New-Object Windows.Forms.ListView
$list.Dock='Fill';$list.View='Details';$list.FullRowSelect=$true;$list.HideSelection=$false;$list.MultiSelect=$true
$list.BackColor=[Drawing.Color]::FromArgb(20,25,35);$list.ForeColor=[Drawing.Color]::White
$list.BorderStyle='None';$list.CheckBoxes=$false
foreach($column in @(@('Account',205),@('Role',75),@('Guard',100),@('RAM',95),@('State',105),@('PID',75),@('UserId',145))){[void]$list.Columns.Add($column[0],[int]$column[1])}
$list.Add_DoubleClick({Open-SelectedWindow})
$clientLayout.Controls.Add($list,0,1)
$clientHelp=New-Label 'New windows start paused. Double-click to open a window. Use Ctrl / Shift to select several.' 9 $muted
$clientLayout.Controls.Add($clientHelp,0,2)
$selectionBar=New-Flow
New-SectionTag $selectionBar 'SELECTED'
[void](New-Button $selectionBar 'Open Selected' {Open-SelectedWindow} 142 -Primary)
[void](New-Button $selectionBar 'Trim' {Invoke-AltAction @(Get-SelectedRows) 'Trim'} 90)
[void](New-Button $selectionBar 'Pause' {Set-AltArmed @(Get-SelectedRows) $false;Render-Rows} 90)
[void](New-Button $selectionBar 'Enable' {Set-AltArmed @(Get-SelectedRows) $true;Render-Rows;if(-not $script:GuardEnabled){$info.Text='Selected alts enabled. The global Alt Guard switch is still OFF.'}} 90)
$roleMenu=New-Object Windows.Forms.ContextMenuStrip
foreach($entry in @(@('Mark as Alt','Alt'),@('Mark as Main','Main'),@('Remove Alt role','RemoveAlt'),@('Clear saved Main','ClearMain'))){
    $menuItem=New-Object Windows.Forms.ToolStripMenuItem($entry[0]);$menuItem.Tag=$entry[1]
    $menuItem.Add_Click({param($sender,$eventArgs) Set-SelectedRole ([string]$sender.Tag)})
    [void]$roleMenu.Items.Add($menuItem)
}
$roleButton=New-Button $selectionBar 'Account role...' {param($sender,$eventArgs) $roleMenu.Show($sender,0,$sender.Height)} 145
$clientLayout.Controls.Add($selectionBar,0,3)
$allBar=New-Flow
New-SectionTag $allBar 'ALL ALTS'
[void](New-Button $allBar 'Trim All Alts' {Invoke-AltAction $script:Rows 'Trim'} 142)
[void](New-Button $allBar 'Minimize' {Invoke-AltAction $script:Rows 'Minimize'} 110)
[void](New-Button $allBar 'Pause all' {Set-AltArmed $script:Rows $false;Render-Rows} 110)
[void](New-Button $allBar 'Enable all' {Set-AltArmed $script:Rows $true;Render-Rows;if(-not $script:GuardEnabled){$info.Text='Alts enabled. Turn Alt Guard ON when you want automation.'}} 110)
$closeMenu=New-Object Windows.Forms.ContextMenuStrip
$closeSelected=New-Object Windows.Forms.ToolStripMenuItem('Close selected alts...')
$closeSelected.Add_Click({Confirm-CloseAlts @(Get-SelectedRows)})
[void]$closeMenu.Items.Add($closeSelected)
$closeHung=New-Object Windows.Forms.ToolStripMenuItem('Close frozen alts...')
$closeHung.Add_Click({Confirm-CloseAlts @($script:Rows | Where-Object {$_.Hung -eq $true -and ([datetime]::UtcNow-[datetime]$_.SampledUtc).TotalSeconds -le 10})})
[void]$closeMenu.Items.Add($closeHung)
[void](New-Button $allBar 'Close...' {param($sender,$eventArgs) $closeMenu.Show($sender,0,$sender.Height)} 100)
$clientLayout.Controls.Add($allBar,0,4)
# Separate configuration and transfer controls from everyday account actions.
$settingsPage.AutoScroll=$true
$settingsLayout=New-Object Windows.Forms.TableLayoutPanel
$settingsLayout.Dock='Top';$settingsLayout.AutoSize=$true;$settingsLayout.ColumnCount=2;$settingsLayout.RowCount=1
[void]$settingsLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',50)))
[void]$settingsLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',50)))
$settingsPage.Controls.Add($settingsLayout)
$settingsBox=New-Object Windows.Forms.TableLayoutPanel
$settingsBox.Dock='Top';$settingsBox.AutoSize=$true;$settingsBox.ColumnCount=2;$settingsBox.Padding=New-Object Windows.Forms.Padding(12)
[void]$settingsBox.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',65)))
[void]$settingsBox.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',35)))
$settingsLayout.Controls.Add($settingsBox,0,0)
$settingsBox.Controls.Add((New-Label 'AUTOMATION' 14),0,0);$settingsBox.SetColumnSpan($settingsBox.Controls[0],2)
[void]$settingsBox.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',46)))
function New-Setting($caption,$row,$minimum,$maximum){
    [void]$settingsBox.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',48)))
    $settingsBox.Controls.Add((New-Label $caption 10 $muted),0,$row)
    $input=New-Object Windows.Forms.NumericUpDown
    $input.Minimum=$minimum;$input.Maximum=$maximum;$input.Dock='Fill';$input.Margin=New-Object Windows.Forms.Padding(5,10,5,10)
    $input.BackColor=[Drawing.Color]::FromArgb(36,43,57);$input.ForeColor=[Drawing.Color]::White
    $settingsBox.Controls.Add($input,1,$row)
    return $input
}
$numTrigger=New-Setting 'Trim above (MB)' 1 100 65536
$numPoll=New-Setting 'Check interval (seconds)' 2 1 60
$numCooldown=New-Setting 'Trim cooldown (seconds)' 3 10 600
$numFrozen=New-Setting 'Frozen duration (seconds)' 4 5 600
$closeFrozen=New-Object Windows.Forms.CheckBox
$closeFrozen.Text='Automatically close frozen alts';$closeFrozen.Dock='Fill';$closeFrozen.ForeColor=[Drawing.Color]::White
[void]$settingsBox.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',44)))
$settingsBox.Controls.Add($closeFrozen,0,5);$settingsBox.SetColumnSpan($closeFrozen,2)
$settingsHint=New-Label 'OFF pauses automatic trims and frozen closures. Manual Trim All Alts still works.' 9 $muted
[void]$settingsBox.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',64)))
$settingsBox.Controls.Add($settingsHint,0,6);$settingsBox.SetColumnSpan($settingsHint,2)
$saveFlow=New-Flow
$saveSettings=New-Button $saveFlow 'Save settings' {
    try{
        $candidate=Get-CurrentProfile
        $candidate.Settings=[pscustomobject]@{TrimTriggerMB=[int]$numTrigger.Value;PollSeconds=[int]$numPoll.Value;FrozenSeconds=[int]$numFrozen.Value;TrimCooldownSeconds=[int]$numCooldown.Value;CloseFrozen=$closeFrozen.Checked}
        Commit-Profile $candidate
        $script:FreezeStart.Clear();$script:FrozenSamples.Clear();$script:LastGuardSample.Clear()
        $info.Text='Settings saved for this and future updates.'
    }catch{Show-ActionError $_.Exception.Message}
} 155 -Primary
[void]$settingsBox.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
$settingsBox.Controls.Add($saveFlow,0,7);$settingsBox.SetColumnSpan($saveFlow,2)
$savesBox=New-Object Windows.Forms.TableLayoutPanel
$savesBox.Dock='Top';$savesBox.AutoSize=$true;$savesBox.ColumnCount=1;$savesBox.Padding=New-Object Windows.Forms.Padding(20,12,12,12)
$settingsLayout.Controls.Add($savesBox,1,0)
$savesBox.Controls.Add((New-Label 'SAVES & UPDATES' 14),0,0)
[void]$savesBox.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',46)))
$saveNotice=New-Label 'Your settings and account roles are saved outside the update folder. New versions use them automatically.' 10 $muted
$savesBox.Controls.Add($saveNotice,0,1)
[void]$savesBox.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',80)))
$savePath=New-Object Windows.Forms.TextBox
$savePath.Text=$script:DataDirectory;$savePath.ReadOnly=$true;$savePath.Multiline=$true;$savePath.Height=54;$savePath.Dock='Fill'
$savePath.BackColor=[Drawing.Color]::FromArgb(36,43,57);$savePath.ForeColor=[Drawing.Color]::White
$savesBox.Controls.Add($savePath,0,2)
[void]$savesBox.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',64)))
$transferFlow=New-Flow
[void](New-Button $transferFlow 'Export backup' {Export-ProfileBackup} 150)
[void](New-Button $transferFlow 'Import backup' {Import-ProfileBackup $false} 150)
[void](New-Button $transferFlow 'Import old folder' {Import-ProfileBackup $true} 150)
[void](New-Button $transferFlow 'Open save folder' {try{[void][IO.Directory]::CreateDirectory($script:DataDirectory);Start-Process explorer.exe -ArgumentList ('"'+$script:DataDirectory+'"')}catch{Show-ActionError $_.Exception.Message}} 150)
$savesBox.Controls.Add($transferFlow,0,3)
[void]$savesBox.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
$savesBox.Controls.Add((New-Label 'Old version in another folder? Use Import old folder once. Moving PCs? Export a backup, then import it on the new PC.' 9 $muted),0,4)
[void]$savesBox.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',80)))
$info=New-Label 'Starting background monitor. Alt Guard is OFF.' 9 $muted
$root.Controls.Add($info,0,3)
$info.Add_DoubleClick({[void][Windows.Forms.MessageBox]::Show("Last monitor error: $($script:MonitorError)`r`nCredits: Stitch / @jhfo",'Monitor details')})
Load-SettingsControls
Update-GuardControl

$timer=New-Object Windows.Forms.Timer
$timer.Interval=250
$timer.Add_Tick({Update-MetersAndGuard})
$form.Add_Shown({
    $timer.Start()
    if($profileState.Notice){$saveNotice.Text=$profileState.Notice;$info.Text=$profileState.Notice}
})
try{[void]$form.ShowDialog()}finally{
    $timer.Stop()
    if($script:Monitor){
        if($script:MonitorHandle -and -not $script:MonitorHandle.IsCompleted){
            if(-not $script:MonitorStop){[void]$script:Monitor.BeginStop($null,$null)}
        }else{$script:Monitor.Dispose()}
    }
    $timer.Dispose();$roleMenu.Dispose();$closeMenu.Dispose();$form.Dispose()
}
