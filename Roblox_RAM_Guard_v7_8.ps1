
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
}
"@

function Get-RobloxProcesses {
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
    $text = Read-LogLarge $key
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
    foreach ($nativeEntry in $nativeEntries) {
        try {
            $threadKey = [string][Convert]::ToInt32($nativeEntry.Groups['thread'].Value, 16)
            $seenUtc = [datetime]::Parse($nativeEntry.Groups['utc'].Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
            if (-not $threadTimes.ContainsKey($threadKey) -or $threadTimes[$threadKey] -lt $seenUtc) { $threadTimes[$threadKey]=$seenUtc }
            if ($seenUtc -gt $lastUtc) { $lastUtc=$seenUtc }
        } catch {}
    }
    $entry = [pscustomobject]@{Path=$key; StartUtc=$started; LastUtc=$lastUtc; ThreadTimes=$threadTimes; Identity=(Parse-IdentityFromText $text $key); Fingerprint=$fingerprint}
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
    try { return $proc.StartTime.ToUniversalTime() } catch {}
    # Some protected clients deny the .NET handle query but expose CIM metadata.
    try {
        $entry = Get-CimInstance Win32_Process -Filter ('ProcessId={0}' -f [int]$proc.Id) -ErrorAction Stop
        if ($entry.CreationDate) { return $entry.CreationDate.ToUniversalTime() }
    } catch {}
    return $null
}

function Assign-LogsToProcesses {
    Update-UsernameLookups
    if (((Get-Date) - $script:IdentityScanAt).TotalSeconds -lt 2) { return }
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
}

function Resolve-IdentityForProcess($proc) {
    Assign-LogsToProcesses
    $key = [string]$proc.Id
    if ($script:Resolved.ContainsKey($key)) {
        # Reuse the start time read during the scan if the direct handle query
        # is denied; the next scan rechecks it through CIM before using the ID.
        try {
            if ($script:Resolved[$key].StartTicks -ne $proc.StartTime.ToUniversalTime().Ticks) {
                return [pscustomobject]@{UserId=$null; Username='Unknown'; Log=$null; Reason='Waiting for new process scan'}
            }
        } catch {}
        return $script:Resolved[$key]
    }
    return [pscustomobject]@{UserId=$null; Username='Unknown'; Log=$null; Reason='Waiting for account scan'}
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

$form=New-Object System.Windows.Forms.Form
$form.Text="Roblox RAM Guard v7.8.2"
$form.Size=New-Object System.Drawing.Size(1030,710)
$form.StartPosition="CenterScreen"
$form.BackColor=[System.Drawing.Color]::FromArgb(24,24,28)
$form.ForeColor=[System.Drawing.Color]::White
$form.Font=New-Object System.Drawing.Font("Segoe UI",10)

$title=New-Object System.Windows.Forms.Label
$title.Text="Roblox RAM Guard v7.8.2"
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

function Refresh-List {
    $checked=@{}
    foreach($it in $list.Items){if($it.Checked){$checked[[string]$it.Tag]=$true}}

    $list.BeginUpdate()
    $list.Items.Clear()

    Assign-LogsToProcesses

    foreach($p in Get-RobloxProcesses){
        $id=Resolve-IdentityForProcess $p
        $role=""
        if(Is-Main $id){$role="MAIN";Set-MainPriority $p}
        elseif(Is-Alt $id){$role="ALT";Set-AltPriority $p}

        $ram=[math]::Round($p.WorkingSet64/1MB)
        $status="Normal"
        if(-not $p.Responding){$status="Frozen"}
        elseif($role -eq "ALT" -and $ram -ge [int]$script:Settings.TrimTriggerMB){$status="High RAM"}

        $item=New-Object System.Windows.Forms.ListViewItem($(if($id.Username){$id.Username}else{"Unknown"}))
        $item.SubItems.Add($role)|Out-Null
        $item.SubItems.Add([string]$p.Id)|Out-Null
        $item.SubItems.Add("$ram MB")|Out-Null
        $item.SubItems.Add($status)|Out-Null
        $item.SubItems.Add([string]$id.UserId)|Out-Null
        $item.SubItems.Add([string]$p.PriorityClass)|Out-Null
        $item.Tag=$p.Id

        if($role -eq "MAIN"){
            $item.Checked=$false;$item.BackColor=[System.Drawing.Color]::FromArgb(40,62,92)
        } elseif($status -eq "Frozen"){
            $item.BackColor=[System.Drawing.Color]::FromArgb(100,40,40)
            if($checked.ContainsKey([string]$p.Id)-or $role -eq "ALT"){$item.Checked=$true}
        } elseif($status -eq "High RAM"){
            $item.BackColor=[System.Drawing.Color]::FromArgb(90,75,30)
            if($checked.ContainsKey([string]$p.Id)-or $role -eq "ALT"){$item.Checked=$true}
        } else {
            $item.BackColor=[System.Drawing.Color]::FromArgb(34,60,42)
            if($checked.ContainsKey([string]$p.Id)-or $role -eq "ALT"){$item.Checked=$true}
        }
        $list.Items.Add($item)|Out-Null
    }
    $list.EndUpdate()
}

function Update-MetersAndGuard {
    $procs=@(Get-RobloxProcesses)
    $current=@($procs|ForEach-Object{$_.Id}|Sort-Object)

    if(($script:KnownPids -join ",") -ne ($current -join ",")){
        $script:KnownPids=$current
        Refresh-List
    }

    try{
        $os=Get-CimInstance Win32_OperatingSystem
        $total=[math]::Round($os.TotalVisibleMemorySize/1MB,1)
        $free=[math]::Round($os.FreePhysicalMemory/1MB,1)
        $used=[math]::Round($total-$free,1)
        $pct=if($total -gt 0){[math]::Round(($used/$total)*100)}else{0}
        $sysRam.Text="System RAM: $used / $total GB ($($pct)%)"
    }catch{}

    $robloxMB=0
    foreach($p in $procs){$robloxMB+=($p.WorkingSet64/1MB)}
    $totalRoblox.Text="Total Roblox RAM: $([math]::Round($robloxMB/1024,2)) GB"

    # Compare values, not cache-key existence: ID-only records can gain a name.
    $beforeIdentity = (@($list.Items | ForEach-Object { '{0}:{1}:{2}' -f $_.Tag,$_.Text,$_.SubItems[5].Text } | Sort-Object) -join '|')
    Assign-LogsToProcesses
    # Retry identity for unresolved clients.
    foreach($p in $procs){
        $pidKey=[string]$p.Id
        $id=Resolve-IdentityForProcess $p

        if(Is-Main $id){
            Set-MainPriority $p
            continue
        }

        if(Is-Alt $id){
            Set-AltPriority $p
            $ram=[math]::Round($p.WorkingSet64/1MB)
            if($ram -ge [int]$script:Settings.TrimTriggerMB){Trim-Process $p}

            if(-not $p.Responding){
                if(-not $script:FreezeStart.ContainsKey($pidKey)){$script:FreezeStart[$pidKey]=Get-Date}
                else{
                    $elapsed=((Get-Date)-$script:FreezeStart[$pidKey]).TotalSeconds
                    if($elapsed -ge [int]$script:Settings.FrozenSeconds){
                        Kill-Proc $p
                        $script:FreezeStart.Remove($pidKey)
                    }
                }
            } elseif($script:FreezeStart.ContainsKey($pidKey)){
                $script:FreezeStart.Remove($pidKey)
            }
        }
    }

    $afterIdentity = (@($procs | ForEach-Object {
        $identity = Resolve-IdentityForProcess $_
        '{0}:{1}:{2}' -f $_.Id,$identity.Username,$identity.UserId
    } | Sort-Object) -join '|')
    if($beforeIdentity -ne $afterIdentity){Refresh-List}

    # Cleanup closed processes and their assigned logs.
    $alive=@{}
    foreach($p in $procs){$alive[[string]$p.Id]=$true}

    foreach($k in @($script:Resolved.Keys)){
        if(-not $alive.ContainsKey($k)){$script:Resolved.Remove($k)}
    }

    foreach($log in @($script:AssignedLogs.Keys)){
        $assignedPid=[string]$script:AssignedLogs[$log]
        if(-not $alive.ContainsKey($assignedPid)){$script:AssignedLogs.Remove($log)}
    }

    foreach($it in $list.Items){
        $p=Get-Process -Id ([int]$it.Tag) -ErrorAction SilentlyContinue
        if($p){
            $ram=[math]::Round($p.WorkingSet64/1MB)
            $it.SubItems[3].Text="$ram MB"
            $role=$it.SubItems[1].Text
            $status="Normal"
            if(-not $p.Responding){$status="Frozen"}
            elseif($role -eq "ALT" -and $ram -ge [int]$script:Settings.TrimTriggerMB){$status="High RAM"}
            $it.SubItems[4].Text=$status
            $it.SubItems[6].Text=[string]$p.PriorityClass

            if($role -eq "MAIN"){$it.BackColor=[System.Drawing.Color]::FromArgb(40,62,92)}
            elseif($status -eq "Frozen"){$it.BackColor=[System.Drawing.Color]::FromArgb(100,40,40)}
            elseif($status -eq "High RAM"){$it.BackColor=[System.Drawing.Color]::FromArgb(90,75,30)}
            else{$it.BackColor=[System.Drawing.Color]::FromArgb(34,60,42)}
        }
    }
}

Add-Button "Refresh" 20 495 100 {$script:IdentityScanAt=[datetime]::MinValue; Refresh-List}|Out-Null
Add-Button "Trim Selected" 130 495 125 {
    foreach($it in $list.CheckedItems){
        if($it.SubItems[1].Text -ne "MAIN"){
            $p=Get-Process -Id ([int]$it.Tag)-ErrorAction SilentlyContinue
            if($p){Trim-Process $p}
        }
    }
}|Out-Null

Add-Button "Trim All Alts" 265 495 125 {
    foreach($p in Get-RobloxProcesses){
        $id=Resolve-IdentityForProcess $p
        if(Is-Alt $id -and -not(Is-Main $id)){Trim-Process $p}
    }
}|Out-Null

Add-Button "Kill Selected" 400 495 120 {
    if([System.Windows.Forms.MessageBox]::Show("Kill selected Roblox instances?","Confirm",'YesNo') -eq 'Yes'){
        foreach($it in @($list.CheckedItems)){
            if($it.SubItems[1].Text -ne "MAIN"){
                $p=Get-Process -Id ([int]$it.Tag)-ErrorAction SilentlyContinue
                if($p){Kill-Proc $p}
            }
        }
    }
}|Out-Null

Add-Button "Kill All Frozen" 530 495 125 {
    foreach($p in Get-RobloxProcesses){if(-not $p.Responding){Kill-Proc $p}}
}|Out-Null

Add-Button "Minimize All Alts" 665 495 145 {
    foreach($p in Get-RobloxProcesses){
        $id=Resolve-IdentityForProcess $p
        if(Is-Alt $id -and -not(Is-Main $id)){Minimize-Proc $p}
    }
}|Out-Null

Add-Button "Mark as Alt" 820 495 110 {
    foreach($it in $list.SelectedItems){
        $p=Get-Process -Id ([int]$it.Tag)-ErrorAction SilentlyContinue
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
        $p=Get-Process -Id ([int]$it.Tag)-ErrorAction SilentlyContinue
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
    $timer.Interval=[int]$script:Settings.PollSeconds*1000
    [System.Windows.Forms.MessageBox]::Show("Settings saved.","Roblox RAM Guard")|Out-Null
})

$info=New-Object System.Windows.Forms.Label
$info.Text="v7.8.2: live thread log matching. Double-click a row for detection details."
$info.Location=New-Object System.Drawing.Point(390,655)
$info.Size=New-Object System.Drawing.Size(600,25)
$info.ForeColor=[System.Drawing.Color]::Silver
$form.Controls.Add($info)

$timer=New-Object System.Windows.Forms.Timer
$timer.Interval=[int]$script:Settings.PollSeconds*1000
$timer.Add_Tick({Update-MetersAndGuard})
$timer.Start()

$script:KnownPids=@((Get-RobloxProcesses|ForEach-Object{$_.Id})|Sort-Object)
Refresh-List
Update-MetersAndGuard
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
    if ($script:NameWorker) {
        $script:NameWorker.Stop()
        $script:NameWorker.Dispose()
    }
}
