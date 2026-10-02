Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class MemoryTools {
    [DllImport("psapi.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool EmptyWorkingSet(IntPtr hProcess);
}
"@

$script:monitoring = $false
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 5000
$script:userCache = @{}
$script:pidIdentity = @{}
$script:pidLog = @{}
$script:freezeSince = @{}
$script:logsPath = Join-Path $env:LOCALAPPDATA "Roblox\logs"
$script:altsPath = Join-Path $PSScriptRoot "alts.json"
$script:savedAltUserIds = @{}
$script:savedAltNames = @{}
$script:freezeKillSeconds = 30
$script:identityRetrySeconds = 5

function Load-Alts {
    $script:savedAltUserIds = @{}
    $script:savedAltNames = @{}
    if (-not (Test-Path $script:altsPath)) { return }
    try {
        $data = Get-Content $script:altsPath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($alt in @($data.alts)) {
            if ($null -ne $alt.userId -and [long]$alt.userId -gt 0) {
                $script:savedAltUserIds[[string]$alt.userId] = $true
            }
            if ($alt.username) {
                $script:savedAltNames[[string]$alt.username.ToLowerInvariant()] = $true
            }
        }
    } catch {}
}

function Save-Alts {
    $rows = @()
    $keys = @{}
    foreach ($uid in $script:savedAltUserIds.Keys) {
        $name = ""
        foreach ($entry in $script:pidIdentity.Values) {
            if ([string]$entry.UserId -eq [string]$uid -and $entry.Username -ne "Unknown") { $name = $entry.Username; break }
        }
        $rows += [PSCustomObject]@{ userId = [long]$uid; username = $name }
        $keys["uid:$uid"] = $true
    }
    foreach ($nameKey in $script:savedAltNames.Keys) {
        $already = $false
        foreach ($row in $rows) {
            if ($row.username -and $row.username.ToLowerInvariant() -eq $nameKey) { $already = $true; break }
        }
        if (-not $already) { $rows += [PSCustomObject]@{ userId = 0; username = $nameKey } }
    }
    try {
        [PSCustomObject]@{ alts = $rows } | ConvertTo-Json -Depth 4 | Set-Content -Path $script:altsPath -Encoding UTF8
    } catch {}
}

function Get-RobloxProcesses {
    @(Get-Process -Name "RobloxPlayerBeta" -ErrorAction SilentlyContinue | Sort-Object StartTime)
}


Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win32WindowTools {
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}
"@

function Trim-ProcessMemory($proc) {
    try {
        [void][MemoryTools]::EmptyWorkingSet($proc.Handle)
        return $true
    } catch { return $false }
}

function Get-LogTail([string]$path, [int]$maxBytes = 8000000) {
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            $len = $fs.Length
            $start = [Math]::Max(0, $len - $maxBytes)
            [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
            $sr = New-Object System.IO.StreamReader($fs)
            try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
        } finally { $fs.Dispose() }
    } catch { return "" }
}

function Resolve-Username([long]$userId) {
    if ($userId -le 0) { return $null }
    $key = $userId.ToString()
    if ($script:userCache.ContainsKey($key)) { return $script:userCache[$key] }
    try {
        $u = Invoke-RestMethod -Uri ("https://users.roblox.com/v1/users/{0}" -f $userId) -Method Get -TimeoutSec 4 -ErrorAction Stop
        if ($u -and $u.name) {
            $script:userCache[$key] = [string]$u.name
            return [string]$u.name
        }
    } catch {}
    return $null
}

function Find-UserIdInLog([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return 0 }
    $patterns = @(
        '(?i)"userId"\s*:\s*"?(\d{2,20})',
        '(?i)"authenticatedUserId"\s*:\s*"?(\d{2,20})',
        '(?i)"accountId"\s*:\s*"?(\d{2,20})',
        '(?i)\buserId\b\s*[=:]\s*"?(\d{2,20})',
        '(?i)\bauthenticatedUserId\b\s*[=:]\s*"?(\d{2,20})',
        '(?i)\buserid\b[^0-9]{0,32}(\d{2,20})',
        '(?i)\buser[_-]?id\b[^0-9]{0,32}(\d{2,20})',
        '(?i)\baccount[_-]?id\b[^0-9]{0,32}(\d{2,20})'
    )
    foreach ($pattern in $patterns) {
        $matches = [regex]::Matches($text, $pattern)
        if ($matches.Count -gt 0) {
            for ($i = $matches.Count - 1; $i -ge 0; $i--) {
                $v = 0L
                if ([long]::TryParse($matches[$i].Groups[1].Value, [ref]$v) -and $v -gt 0) { return $v }
            }
        }
    }
    return 0
}

function Find-UsernameInLog([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $patterns = @(
        '(?i)"username"\s*:\s*"([A-Za-z0-9_]{3,20})"',
        '(?i)"userName"\s*:\s*"([A-Za-z0-9_]{3,20})"',
        '(?i)"accountName"\s*:\s*"([A-Za-z0-9_]{3,20})"',
        '(?i)\busername\b\s*[=:]\s*"?([A-Za-z0-9_]{3,20})',
        '(?i)\baccountName\b\s*[=:]\s*"?([A-Za-z0-9_]{3,20})'
    )
    foreach ($pattern in $patterns) {
        $matches = [regex]::Matches($text, $pattern)
        if ($matches.Count -gt 0) { return $matches[$matches.Count - 1].Groups[1].Value }
    }
    return $null
}


function Get-IdentityFromLogPath([string]$logPath) {
    $identity = [PSCustomObject]@{ UserId = 0L; Username = "Unknown"; Log = ""; HasIdentity = $false }
    if (-not $logPath -or -not (Test-Path $logPath)) { return $identity }
    $identity.Log = [System.IO.Path]::GetFileName($logPath)
    $text = Get-LogTail $logPath
    $uid = Find-UserIdInLog $text
    $name = Find-UsernameInLog $text
    if ($uid -gt 0) {
        $identity.UserId = $uid
        $resolved = Resolve-Username $uid
        if ($resolved) { $name = $resolved }
    }
    if ($name) { $identity.Username = $name }
    $identity.HasIdentity = (($identity.UserId -gt 0) -or ($identity.Username -ne "Unknown"))
    return $identity
}

function Find-BetterIdentityLog($proc) {
    if (-not (Test-Path $script:logsPath)) { return $null }
    try { $start = $proc.StartTime } catch { return $null }

    $used = @{}
    foreach ($k in @($script:pidLog.Keys)) {
        if ([string]$k -eq $proc.Id.ToString()) { continue }
        $pp = [string]$script:pidLog[$k]
        if ($pp) { $used[$pp.ToLowerInvariant()] = $true }
    }

    $candidates = @(Get-ChildItem -Path $script:logsPath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'Player' -and $_.Extension -match '\.(log|txt)$' } |
        Where-Object {
            $deltaCreate = [Math]::Abs(($_.CreationTime - $start).TotalSeconds)
            $deltaWrite = [Math]::Abs(($_.LastWriteTime - $start).TotalSeconds)
            ($deltaCreate -le 300 -or $deltaWrite -le 300)
        } |
        Sort-Object CreationTime)

    $best = $null
    $bestScore = [double]::MaxValue
    foreach ($f in $candidates) {
        if ($used.ContainsKey($f.FullName.ToLowerInvariant())) { continue }
        $id = Get-IdentityFromLogPath $f.FullName
        if (-not $id.HasIdentity) { continue }
        $score = [Math]::Abs(($f.CreationTime - $start).TotalSeconds)
        # Prefer logs that started shortly after the process over older nearby logs.
        if ($f.CreationTime -ge $start.AddSeconds(-15)) { $score -= 15 }
        if ($score -lt $bestScore) {
            $bestScore = $score
            $best = [PSCustomObject]@{ Path = $f.FullName; Identity = $id; Score = $score }
        }
    }
    return $best
}

function Update-LogAssignments($clients) {
    if (-not (Test-Path $script:logsPath)) { return }

    # Remove mappings for Roblox processes that no longer exist.
    $livePids = @{}
    foreach ($p in @($clients)) { $livePids[$p.Id.ToString()] = $true }
    foreach ($pidKey in @($script:pidLog.Keys)) {
        if (-not $livePids.ContainsKey($pidKey)) { $script:pidLog.Remove($pidKey) }
    }
    foreach ($pidKey in @($script:pidIdentity.Keys)) {
        if (-not $livePids.ContainsKey($pidKey)) { $script:pidIdentity.Remove($pidKey) }
    }

    $files = @(Get-ChildItem -Path $script:logsPath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'Player' -and $_.Extension -match '\.(log|txt)$' } |
        Sort-Object CreationTime -Descending |
        Select-Object -First 80)
    if ($files.Count -eq 0) { return }

    # A log is allowed to belong to only ONE Roblox process.
    $used = @{}
    foreach ($pidKey in @($script:pidLog.Keys)) {
        $path = [string]$script:pidLog[$pidKey]
        if ($path -and (Test-Path $path)) { $used[$path.ToLowerInvariant()] = $true }
        else { $script:pidLog.Remove($pidKey) }
    }

    # Match oldest clients first so launches close together remain deterministic.
    $ordered = @($clients | Sort-Object StartTime)
    foreach ($proc in $ordered) {
        $pidKey = $proc.Id.ToString()
        if ($script:pidLog.ContainsKey($pidKey)) { continue }
        try { $start = $proc.StartTime } catch { continue }

        $best = $null
        $bestScore = [double]::MaxValue
        foreach ($f in $files) {
            $key = $f.FullName.ToLowerInvariant()
            if ($used.ContainsKey($key)) { continue }
            # Player log creation time is the most reliable relation to process launch.
            $score = [Math]::Abs(($f.CreationTime - $start).TotalSeconds)
            if ($score -lt $bestScore) { $bestScore = $score; $best = $f }
        }
        if ($best -and $bestScore -le 120) {
            $script:pidLog[$pidKey] = $best.FullName
            $used[$best.FullName.ToLowerInvariant()] = $true
        }
    }
}

function Get-IdentityForProcess($proc, [bool]$force = $false) {
    $pidKey = $proc.Id.ToString()

    # Once a PID has a real identity, keep it sticky for that process lifetime.
    if ($script:pidIdentity.ContainsKey($pidKey)) {
        $cached = $script:pidIdentity[$pidKey]
        if (($cached.UserId -gt 0) -or ($cached.Username -and $cached.Username -ne "Unknown")) {
            return $cached
        }
    }

    $identity = [PSCustomObject]@{ UserId = 0L; Username = "Unknown"; Log = "" }
    $logPath = if ($script:pidLog.ContainsKey($pidKey)) { [string]$script:pidLog[$pidKey] } else { "" }
    if ($logPath -and (Test-Path $logPath)) {
        $parsed = Get-IdentityFromLogPath $logPath
        $identity.UserId = $parsed.UserId
        $identity.Username = $parsed.Username
        $identity.Log = $parsed.Log
    }

    # Fallback: if the first time-based match has no identity, inspect other UNUSED
    # Player logs near this process launch and take the closest one that actually
    # exposes an account identity. This prevents a live in-game client staying Unknown.
    if (($identity.UserId -le 0) -and ($identity.Username -eq "Unknown")) {
        $better = Find-BetterIdentityLog $proc
        if ($better) {
            $script:pidLog[$pidKey] = $better.Path
            $identity.UserId = $better.Identity.UserId
            $identity.Username = $better.Identity.Username
            $identity.Log = $better.Identity.Log
        }
    }

    $script:pidIdentity[$pidKey] = $identity
    return $identity
}

function Test-IsSavedAlt($identity) {
    if ($identity.UserId -gt 0 -and $script:savedAltUserIds.ContainsKey($identity.UserId.ToString())) { return $true }
    if ($identity.Username -and $identity.Username -ne "Unknown" -and $script:savedAltNames.ContainsKey($identity.Username.ToLowerInvariant())) { return $true }
    return $false
}

Load-Alts

# ---------------- UI ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Stitch RAM Guard"
$form.Size = New-Object System.Drawing.Size(1080, 720)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(1080, 720)
$form.BackColor = [System.Drawing.Color]::FromArgb(15, 17, 22)
$form.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 242)

$title = New-Object System.Windows.Forms.Label
$title.Text = "STITCH RAM GUARD"
$title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 20, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(18, 14)
$title.AutoSize = $true
$title.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "Roblox multi-instance memory control • account-aware trimming • crash protection"
$subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$subtitle.Location = New-Object System.Drawing.Point(21, 52)
$subtitle.AutoSize = $true
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(170, 178, 190)
$form.Controls.Add($subtitle)

$lblSystemRam = New-Object System.Windows.Forms.Label
$lblSystemRam.Text = "System RAM: --"
$lblSystemRam.Location = New-Object System.Drawing.Point(22, 82)
$lblSystemRam.AutoSize = $true
$lblSystemRam.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblSystemRam)

$ramBar = New-Object System.Windows.Forms.ProgressBar
$ramBar.Location = New-Object System.Drawing.Point(22, 104)
$ramBar.Size = New-Object System.Drawing.Size(355, 16)
$ramBar.Minimum = 0
$ramBar.Maximum = 100
$form.Controls.Add($ramBar)

$lblRobloxRam = New-Object System.Windows.Forms.Label
$lblRobloxRam.Text = "Total Roblox RAM: --"
$lblRobloxRam.Location = New-Object System.Drawing.Point(395, 82)
$lblRobloxRam.AutoSize = $true
$lblRobloxRam.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblRobloxRam)

$lblTarget = New-Object System.Windows.Forms.Label
$lblTarget.Text = "Trim above:"
$lblTarget.Location = New-Object System.Drawing.Point(620, 82)
$lblTarget.AutoSize = $true
$form.Controls.Add($lblTarget)

$numTarget = New-Object System.Windows.Forms.NumericUpDown
$numTarget.Location = New-Object System.Drawing.Point(695, 78)
$numTarget.Width = 82
$numTarget.Minimum = 400
$numTarget.Maximum = 8000
$numTarget.Increment = 100
$numTarget.Value = 1200
$form.Controls.Add($numTarget)

$lblMB = New-Object System.Windows.Forms.Label
$lblMB.Text = "MB"
$lblMB.Location = New-Object System.Drawing.Point(782, 82)
$lblMB.AutoSize = $true
$form.Controls.Add($lblMB)

$chkAutoKill = New-Object System.Windows.Forms.CheckBox
$chkAutoKill.Text = "Auto-kill guarded client if frozen 30s"
$chkAutoKill.Location = New-Object System.Drawing.Point(22, 133)
$chkAutoKill.AutoSize = $true
$chkAutoKill.Checked = $true
$chkAutoKill.ForeColor = $form.ForeColor
$form.Controls.Add($chkAutoKill)

$chkPriority = New-Object System.Windows.Forms.CheckBox
$chkPriority.Text = "Below Normal priority"
$chkPriority.Location = New-Object System.Drawing.Point(292, 133)
$chkPriority.AutoSize = $true
$chkPriority.Checked = $true
$chkPriority.ForeColor = $form.ForeColor
$form.Controls.Add($chkPriority)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "Start Guard"
$btnStart.Location = New-Object System.Drawing.Point(22, 165)
$btnStart.Size = New-Object System.Drawing.Size(105, 34)
$form.Controls.Add($btnStart)

$btnTrimSelected = New-Object System.Windows.Forms.Button
$btnTrimSelected.Text = "Trim Selected"
$btnTrimSelected.Location = New-Object System.Drawing.Point(135, 165)
$btnTrimSelected.Size = New-Object System.Drawing.Size(115, 34)
$form.Controls.Add($btnTrimSelected)

$btnTrimAllAlts = New-Object System.Windows.Forms.Button
$btnTrimAllAlts.Text = "Trim All Alts"
$btnTrimAllAlts.Location = New-Object System.Drawing.Point(258, 165)
$btnTrimAllAlts.Size = New-Object System.Drawing.Size(112, 34)
$form.Controls.Add($btnTrimAllAlts)

$btnKillSelected = New-Object System.Windows.Forms.Button
$btnKillSelected.Text = "Kill Selected"
$btnKillSelected.Location = New-Object System.Drawing.Point(378, 165)
$btnKillSelected.Size = New-Object System.Drawing.Size(108, 34)
$form.Controls.Add($btnKillSelected)

$btnKillFrozen = New-Object System.Windows.Forms.Button
$btnKillFrozen.Text = "Kill All Frozen"
$btnKillFrozen.Location = New-Object System.Drawing.Point(494, 165)
$btnKillFrozen.Size = New-Object System.Drawing.Size(116, 34)
$form.Controls.Add($btnKillFrozen)

$btnMinimizeAlts = New-Object System.Windows.Forms.Button
$btnMinimizeAlts.Text = "Minimize All Alts"
$btnMinimizeAlts.Location = New-Object System.Drawing.Point(618, 165)
$btnMinimizeAlts.Size = New-Object System.Drawing.Size(132, 34)
$form.Controls.Add($btnMinimizeAlts)

$btnMarkAlt = New-Object System.Windows.Forms.Button
$btnMarkAlt.Text = "Mark as Alt"
$btnMarkAlt.Location = New-Object System.Drawing.Point(22, 205)
$btnMarkAlt.Size = New-Object System.Drawing.Size(100, 32)
$form.Controls.Add($btnMarkAlt)

$btnRemoveAlt = New-Object System.Windows.Forms.Button
$btnRemoveAlt.Text = "Remove Alt"
$btnRemoveAlt.Location = New-Object System.Drawing.Point(130, 205)
$btnRemoveAlt.Size = New-Object System.Drawing.Size(100, 32)
$form.Controls.Add($btnRemoveAlt)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refresh"
$btnRefresh.Location = New-Object System.Drawing.Point(238, 205)
$btnRefresh.Size = New-Object System.Drawing.Size(84, 32)
$form.Controls.Add($btnRefresh)

$btnAll = New-Object System.Windows.Forms.Button
$btnAll.Text = "Select All"
$btnAll.Location = New-Object System.Drawing.Point(330, 205)
$btnAll.Size = New-Object System.Drawing.Size(84, 32)
$form.Controls.Add($btnAll)

$btnNone = New-Object System.Windows.Forms.Button
$btnNone.Text = "Clear"
$btnNone.Location = New-Object System.Drawing.Point(422, 205)
$btnNone.Size = New-Object System.Drawing.Size(70, 32)
$form.Controls.Add($btnNone)

$status = New-Object System.Windows.Forms.Label
$status.Text = "Stopped"
$status.Location = New-Object System.Drawing.Point(775, 174)
$status.AutoSize = $true
$status.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$status.ForeColor = [System.Drawing.Color]::FromArgb(110, 220, 150)
$form.Controls.Add($status)

$list = New-Object System.Windows.Forms.ListView
$list.Location = New-Object System.Drawing.Point(22, 252)
$list.Size = New-Object System.Drawing.Size(1020, 342)
$list.Anchor = 'Top,Bottom,Left,Right'
$list.View = 'Details'
$list.FullRowSelect = $true
$list.GridLines = $false
$list.CheckBoxes = $true
$list.MultiSelect = $true
$list.BackColor = [System.Drawing.Color]::FromArgb(23, 26, 33)
$list.ForeColor = [System.Drawing.Color]::FromArgb(236, 239, 244)
$list.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
[void]$list.Columns.Add("Alt", 48)
[void]$list.Columns.Add("Username", 205)
[void]$list.Columns.Add("PID", 72)
[void]$list.Columns.Add("RAM (MB)", 88)
[void]$list.Columns.Add("Status", 110)
[void]$list.Columns.Add("UserId", 115)
[void]$list.Columns.Add("Last action", 300)
$form.Controls.Add($list)

$note = New-Object System.Windows.Forms.Label
$note.Text = "Saved alts are remembered automatically. Unknown clients retry identity detection as their Roblox session log updates."
$note.Location = New-Object System.Drawing.Point(22, 610)
$note.Size = New-Object System.Drawing.Size(760, 42)
$note.Anchor = 'Bottom,Left,Right'
$note.ForeColor = [System.Drawing.Color]::FromArgb(155, 164, 178)
$form.Controls.Add($note)

$credit = New-Object System.Windows.Forms.Label
$credit.Text = "Credits: Stitch  •  @jhfo on Discord"
$credit.Location = New-Object System.Drawing.Point(790, 622)
$credit.Size = New-Object System.Drawing.Size(250, 28)
$credit.Anchor = 'Bottom,Right'
$credit.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$credit.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$credit.ForeColor = [System.Drawing.Color]::FromArgb(130, 150, 255)
$form.Controls.Add($credit)


foreach ($btn in @($btnStart,$btnTrimSelected,$btnTrimAllAlts,$btnKillSelected,$btnKillFrozen,$btnMinimizeAlts,$btnMarkAlt,$btnRemoveAlt,$btnRefresh,$btnAll,$btnNone)) {
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 0
    $btn.BackColor = [System.Drawing.Color]::FromArgb(38, 43, 54)
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
}
$btnStart.BackColor = [System.Drawing.Color]::FromArgb(72, 95, 220)
$btnKillSelected.BackColor = [System.Drawing.Color]::FromArgb(178, 61, 72)
$btnKillFrozen.BackColor = [System.Drawing.Color]::FromArgb(150, 48, 58)
$btnTrimAllAlts.BackColor = [System.Drawing.Color]::FromArgb(65, 105, 225)
$btnMinimizeAlts.BackColor = [System.Drawing.Color]::FromArgb(95, 79, 168)
$btnMarkAlt.BackColor = [System.Drawing.Color]::FromArgb(52, 134, 95)

function Get-CheckedPidSet {
    $set = @{}
    foreach ($it in $list.Items) {
        if ($it.Checked -and $it.Tag) { $set[[string]$it.Tag] = $true }
    }
    return $set
}

function Get-SelectedItems {
    @($list.SelectedItems)
}

function Update-RamMeters {
    try {
        $ci = New-Object Microsoft.VisualBasic.Devices.ComputerInfo
        $total = [double]$ci.TotalPhysicalMemory
        $avail = [double]$ci.AvailablePhysicalMemory
        $used = [Math]::Max(0, $total - $avail)
        $pct = if ($total -gt 0) { [Math]::Round(($used / $total) * 100) } else { 0 }
        $ramBar.Value = [Math]::Max(0, [Math]::Min(100, [int]$pct))
        $lblSystemRam.Text = "System RAM: $([math]::Round($used / 1GB, 1)) / $([math]::Round($total / 1GB, 1)) GB ($pct%)"
    } catch {
        $lblSystemRam.Text = "System RAM: unavailable"
    }

    $robloxTotal = 0L
    foreach ($p in @(Get-RobloxProcesses)) {
        try { $p.Refresh(); $robloxTotal += [long]$p.WorkingSet64 } catch {}
    }
    $lblRobloxRam.Text = "Total Roblox RAM: $([math]::Round($robloxTotal / 1GB, 2)) GB"
}

function Start-GuardInternal {
    if (-not $script:monitoring) {
        $script:monitoring = $true
        $btnStart.Text = "Stop Guard"
        $script:timer.Start()
    }
}

function Refresh-Clients([bool]$forceIdentity = $false) {
    $checkedBefore = Get-CheckedPidSet
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        $clients = @(Get-RobloxProcesses)
        Update-LogAssignments $clients
        $foundSavedAlt = $false

        foreach ($p in $clients) {
            try { $p.Refresh() } catch { continue }
            $pidKey = $p.Id.ToString()
            try { $mb = [math]::Round($p.WorkingSet64 / 1MB) } catch { $mb = 0 }
            $id = Get-IdentityForProcess $p $forceIdentity
            $isAlt = Test-IsSavedAlt $id
            if ($isAlt) { $foundSavedAlt = $true }
            $isChecked = $checkedBefore.ContainsKey($pidKey) -or $isAlt

            $item = New-Object System.Windows.Forms.ListViewItem($(if ($isAlt) { "ALT" } else { "" }))
            [void]$item.SubItems.Add($id.Username)
            [void]$item.SubItems.Add($pidKey)
            [void]$item.SubItems.Add($mb.ToString())
            [void]$item.SubItems.Add("Running")
            [void]$item.SubItems.Add($(if ($id.UserId -gt 0) { $id.UserId.ToString() } else { "?" }))
            [void]$item.SubItems.Add($(if ($isAlt) { "Saved alt" } else { "OK" }))
            $item.Tag = $pidKey
            $item.Checked = $isChecked
            [void]$list.Items.Add($item)
        }
    } finally {
        $list.EndUpdate()
    }

    Update-RamMeters
    $checkedCount = @($list.Items | Where-Object { $_.Checked }).Count
    $state = if ($script:monitoring) { "Guard ON" } else { "Stopped" }
    $status.Text = "$state | $checkedCount guarded"

    if ($foundSavedAlt) { Start-GuardInternal }
}

function Trim-CheckedClients {
    $checked = Get-CheckedPidSet
    if ($checked.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Check at least one Roblox instance first.", "Roblox RAM Guard") | Out-Null
        return
    }
    foreach ($p in @(Get-RobloxProcesses)) {
        if ($checked.ContainsKey($p.Id.ToString())) {
            if ($chkPriority.Checked) { try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {} }
            [void](Trim-ProcessMemory $p)
        }
    }
    Update-ClientStats $false
}

function Kill-CheckedClients {
    $checked = Get-CheckedPidSet
    if ($checked.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Check at least one Roblox instance first.", "Roblox RAM Guard") | Out-Null
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Close the selected Roblox client(s)?`n`nIn-game progress may be lost.",
        "Kill Selected",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    foreach ($p in @(Get-RobloxProcesses)) {
        if ($checked.ContainsKey($p.Id.ToString())) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {} }
    }
    Start-Sleep -Milliseconds 120
    Refresh-Clients $false
}

function Get-AltPidSet {
    $set = @{}
    foreach ($it in @($list.Items)) {
        if ($it.SubItems[0].Text -eq "ALT" -and $it.Tag) { $set[[string]$it.Tag] = $true }
    }
    return $set
}

function Trim-AllAlts {
    $alts = Get-AltPidSet
    if ($alts.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No saved alts are currently running.", "Roblox RAM Guard") | Out-Null
        return
    }
    foreach ($p in @(Get-RobloxProcesses)) {
        if ($alts.ContainsKey($p.Id.ToString())) {
            if ($chkPriority.Checked) { try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {} }
            [void](Trim-ProcessMemory $p)
        }
    }
    Update-ClientStats $false
}

function Kill-AllFrozen {
    $frozen = @()
    foreach ($it in @($list.Items)) {
        if ($it.SubItems[4].Text -like "FROZEN*") { $frozen += $it }
    }
    if ($frozen.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No frozen Roblox clients detected.", "Roblox RAM Guard") | Out-Null
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Kill all $($frozen.Count) frozen Roblox client(s)?",
        "Kill All Frozen",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    foreach ($it in $frozen) {
        try { Stop-Process -Id ([int]$it.Tag) -Force -ErrorAction Stop } catch {}
    }
    Start-Sleep -Milliseconds 120
    Refresh-Clients $false
}

function Minimize-AllAlts {
    $alts = Get-AltPidSet
    if ($alts.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No saved alts are currently running.", "Roblox RAM Guard") | Out-Null
        return
    }
    $count = 0
    foreach ($p in @(Get-RobloxProcesses)) {
        if ($alts.ContainsKey($p.Id.ToString())) {
            try {
                $p.Refresh()
                if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
                    [void][Win32WindowTools]::ShowWindowAsync($p.MainWindowHandle, 6)
                    $count++
                }
            } catch {}
        }
    }
    $status.Text = "Minimized $count alt window(s)"
}

function Apply-StatusColor($it, [int]$mb, [int]$target, [bool]$responding) {
    if (-not $responding) {
        $it.BackColor = [System.Drawing.Color]::FromArgb(72, 28, 32)
        $it.ForeColor = [System.Drawing.Color]::FromArgb(255, 170, 170)
        return
    }
    if ($mb -gt $target) {
        $it.BackColor = [System.Drawing.Color]::FromArgb(67, 55, 25)
        $it.ForeColor = [System.Drawing.Color]::FromArgb(255, 223, 145)
        return
    }
    $it.BackColor = $list.BackColor
    $it.ForeColor = [System.Drawing.Color]::FromArgb(160, 235, 180)
}

function Mark-SelectedAsAlt {
    $selected = Get-SelectedItems
    if ($selected.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Click one or more rows first, then press Mark as Alt.", "Roblox RAM Guard") | Out-Null
        return
    }
    foreach ($it in $selected) {
        $uidText = $it.SubItems[5].Text
        $name = $it.SubItems[1].Text
        $uid = 0L
        if ([long]::TryParse($uidText, [ref]$uid) -and $uid -gt 0) { $script:savedAltUserIds[$uid.ToString()] = $true }
        if ($name -and $name -ne "Unknown") { $script:savedAltNames[$name.ToLowerInvariant()] = $true }
        $it.Checked = $true
    }
    Save-Alts
    Refresh-Clients $false
    Start-GuardInternal
    Update-ClientStats $true
}

function Remove-SelectedAlt {
    $selected = Get-SelectedItems
    if ($selected.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Click one or more rows first, then press Remove Alt.", "Roblox RAM Guard") | Out-Null
        return
    }
    foreach ($it in $selected) {
        $uidText = $it.SubItems[5].Text
        $name = $it.SubItems[1].Text
        $uid = 0L
        if ([long]::TryParse($uidText, [ref]$uid) -and $uid -gt 0) { $script:savedAltUserIds.Remove($uid.ToString()) }
        if ($name -and $name -ne "Unknown") { $script:savedAltNames.Remove($name.ToLowerInvariant()) }
    }
    Save-Alts
    Refresh-Clients $false
}

function Update-ClientStats([bool]$autoTrim = $false) {
    $target = [int]$numTarget.Value
    $livePids = @{}
    foreach ($p in @(Get-RobloxProcesses)) { $livePids[$p.Id.ToString()] = $p }

    # Rebuild only when a Roblox process was opened or closed.
    $listedPids = @{}
    foreach ($it in @($list.Items)) { $listedPids[[string]$it.Tag] = $true }
    $processSetChanged = ($livePids.Count -ne $listedPids.Count)
    if (-not $processSetChanged) {
        foreach ($k in $livePids.Keys) { if (-not $listedPids.ContainsKey($k)) { $processSetChanged = $true; break } }
    }
    if ($processSetChanged) {
        Refresh-Clients $false
        return
    }

    foreach ($it in @($list.Items)) {
        $pidKey = [string]$it.Tag
        if (-not $livePids.ContainsKey($pidKey)) { continue }
        $p = $livePids[$pidKey]
        try { $p.Refresh() } catch { continue }
        try { $mb = [math]::Round($p.WorkingSet64 / 1MB) } catch { $mb = 0 }
        $it.SubItems[3].Text = $mb.ToString()

        # Retry unresolved account identities in-place without rebuilding the whole list.
        if ($it.SubItems[1].Text -eq "Unknown") {
            $newId = Get-IdentityForProcess $p $true
            if ($newId.Username -ne "Unknown" -or $newId.UserId -gt 0) {
                $it.SubItems[1].Text = $newId.Username
                $it.SubItems[5].Text = $(if ($newId.UserId -gt 0) { $newId.UserId.ToString() } else { "?" })
                if (Test-IsSavedAlt $newId) {
                    $it.SubItems[0].Text = "ALT"
                    $it.Checked = $true
                    $it.SubItems[6].Text = "Alt recognized"
                    Start-GuardInternal
                } else {
                    $it.SubItems[6].Text = "Account recognized"
                }
            } else {
                $it.SubItems[6].Text = "Retrying account ID..."
            }
        }

        $responding = $true
        try {
            if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $responding = [bool]$p.Responding }
        } catch { $responding = $true }

        if (-not $responding) {
            if (-not $script:freezeSince.ContainsKey($pidKey)) { $script:freezeSince[$pidKey] = [DateTime]::Now }
            $seconds = [int]([DateTime]::Now - $script:freezeSince[$pidKey]).TotalSeconds
            $it.SubItems[4].Text = "FROZEN ${seconds}s"
            Apply-StatusColor $it $mb $target $false

            if ($chkAutoKill.Checked -and $it.Checked -and $seconds -ge $script:freezeKillSeconds) {
                try {
                    Stop-Process -Id $p.Id -Force -ErrorAction Stop
                    $it.SubItems[6].Text = "Auto-killed frozen client"
                } catch {
                    $it.SubItems[6].Text = "Auto-kill failed"
                }
                $script:freezeSince.Remove($pidKey)
                continue
            }
        } else {
            if ($script:freezeSince.ContainsKey($pidKey)) { $script:freezeSince.Remove($pidKey) }
            $it.SubItems[4].Text = "Running"
            Apply-StatusColor $it $mb $target $true
        }

        if ($autoTrim -and $it.Checked -and $responding) {
            if ($chkPriority.Checked) { try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {} }
            if ($mb -gt $target) {
                if (Trim-ProcessMemory $p) {
                    $it.SubItems[6].Text = "Auto trimmed"
                    try { $p.Refresh(); $it.SubItems[3].Text = ([math]::Round($p.WorkingSet64 / 1MB)).ToString() } catch {}
                } else {
                    $it.SubItems[6].Text = "Trim failed"
                }
            }
        }
    }

    Update-RamMeters
    $checkedCount = @($list.Items | Where-Object { $_.Checked }).Count
    $state = if ($script:monitoring) { "Guard ON" } else { "Stopped" }
    $status.Text = "$state | $checkedCount guarded"
}

$script:timer.Add_Tick({ if ($script:monitoring) { Update-ClientStats $true } else { Update-ClientStats $false } })

$btnStart.Add_Click({
    $script:monitoring = -not $script:monitoring
    if ($script:monitoring) {
        $btnStart.Text = "Stop Guard"
        $script:timer.Start()
        Update-ClientStats $true
    } else {
        $btnStart.Text = "Start Guard"
        # keep timer running for RAM meter/freeze status even when trimming is stopped
        if (-not $script:timer.Enabled) { $script:timer.Start() }
        Update-ClientStats $false
    }
})
$btnTrimSelected.Add_Click({ Trim-CheckedClients })
$btnTrimAllAlts.Add_Click({ Trim-AllAlts })
$btnKillSelected.Add_Click({ Kill-CheckedClients })
$btnKillFrozen.Add_Click({ Kill-AllFrozen })
$btnMinimizeAlts.Add_Click({ Minimize-AllAlts })
$btnMarkAlt.Add_Click({ Mark-SelectedAsAlt })
$btnRemoveAlt.Add_Click({ Remove-SelectedAlt })
$btnRefresh.Add_Click({
    $script:pidIdentity.Clear()
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try { Refresh-Clients $true } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
})
$btnAll.Add_Click({ foreach ($it in $list.Items) { $it.Checked = $true }; Update-ClientStats $false })
$btnNone.Add_Click({ foreach ($it in $list.Items) { $it.Checked = $false }; Update-ClientStats $false })

$form.Add_Shown({
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Refresh-Clients $true
        $script:timer.Start()
    } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
})
$form.Add_FormClosing({ $script:timer.Stop(); Save-Alts })
[void]$form.ShowDialog()
