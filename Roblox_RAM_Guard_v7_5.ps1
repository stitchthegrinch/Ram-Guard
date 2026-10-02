
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:AltFile = Join-Path $PSScriptRoot "alts.json"
$script:MainFile = Join-Path $PSScriptRoot "main.json"
$script:Resolved = @{}
$script:AssignedLogs = @{}
$script:LastKnown = @{}
$script:TrimTargetMB = 600
$script:TrimTriggerMB = 700
$script:AutoKillFrozen = $true
$script:FrozenSeconds = 30
$script:PollSeconds = 5
$script:MainPriority = "AboveNormal"

function Load-JsonFile($path, $fallback) {
    if (Test-Path $path) {
        try { return (Get-Content $path -Raw | ConvertFrom-Json) } catch {}
    }
    return $fallback
}
function Save-JsonFile($path, $obj) {
    try { $obj | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $path } catch {}
}

$script:Alts = @(Load-JsonFile $script:AltFile @())
$script:Main = Load-JsonFile $script:MainFile $null

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
    Get-Process RobloxPlayerBeta -ErrorAction SilentlyContinue
}

function Get-RobloxLogs {
    $logDir = Join-Path $env:LOCALAPPDATA "Roblox\logs"
    if (-not (Test-Path $logDir)) { return @() }
    Get-ChildItem $logDir -Filter "*Player*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
}

function Parse-IdentityFromLog($path) {
    try {
        $txt = Get-Content $path -Raw -ErrorAction Stop
    } catch { return $null }

    $userId = $null
    $username = $null

    $patterns = @(
        '"userId"\s*:\s*(\d+)',
        'UserId["=: ]+(\d+)',
        'userid["=: ]+(\d+)',
        'userId=(\d+)'
    )
    foreach ($pat in $patterns) {
        $m = [regex]::Match($txt, $pat, 'IgnoreCase')
        if ($m.Success) { $userId = $m.Groups[1].Value; break }
    }

    $namePatterns = @(
        '"username"\s*:\s*"([^"]+)"',
        '"name"\s*:\s*"([^"]+)"',
        'username["=: ]+([A-Za-z0-9_]{3,20})'
    )
    foreach ($pat in $namePatterns) {
        $m = [regex]::Match($txt, $pat, 'IgnoreCase')
        if ($m.Success) { $username = $m.Groups[1].Value; break }
    }

    if ($userId -or $username) {
        return [pscustomobject]@{ UserId=$userId; Username=$username; Log=$path }
    }
    return $null
}

function Resolve-IdentityForProcess($proc) {
    $pidKey = [string]$proc.Id

    # PERFORMANCE FIX: once a process is resolved, never rescan logs for it.
    if ($script:Resolved.ContainsKey($pidKey)) {
        return $script:Resolved[$pidKey]
    }

    $start = $proc.StartTime
    $logs = Get-RobloxLogs

    # Prefer unused logs nearest to process start.
    $candidates = $logs | Where-Object {
        -not $script:AssignedLogs.ContainsKey($_.FullName)
    } | Sort-Object {
        [math]::Abs(($_.LastWriteTime - $start).TotalSeconds)
    }

    foreach ($log in $candidates | Select-Object -First 8) {
        $id = Parse-IdentityFromLog $log.FullName
        if ($id) {
            $script:AssignedLogs[$log.FullName] = $pidKey
            $script:Resolved[$pidKey] = $id
            return $id
        }
    }

    return [pscustomobject]@{ UserId=$null; Username="Unknown"; Log=$null }
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

function Trim-Process($proc) {
    try { [NativeMethods]::EmptyWorkingSet($proc.Handle) | Out-Null } catch {}
}
function Kill-Proc($proc) {
    try { $proc.Kill() } catch {}
}
function Minimize-Proc($proc) {
    try {
        if ($proc.MainWindowHandle -ne 0) {
            [NativeMethods]::ShowWindowAsync($proc.MainWindowHandle, 6) | Out-Null
        }
    } catch {}
}
function Set-MainPriority($proc) {
    try { $proc.PriorityClass = $script:MainPriority } catch {}
}
function Set-AltPriority($proc) {
    try { $proc.PriorityClass = "BelowNormal" } catch {}
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Roblox RAM Guard v7.5"
$form.Size = New-Object System.Drawing.Size(980,650)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(24,24,28)
$form.ForeColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font("Segoe UI",10)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Roblox RAM Guard v7.5"
$title.Location = New-Object System.Drawing.Point(20,15)
$title.AutoSize = $true
$title.Font = New-Object System.Drawing.Font("Segoe UI Semibold",18)
$form.Controls.Add($title)

$credits = New-Object System.Windows.Forms.Label
$credits.Text = "Credits: Stitch - @jhfo on Discord"
$credits.Location = New-Object System.Drawing.Point(23,50)
$credits.AutoSize = $true
$credits.ForeColor = [System.Drawing.Color]::Silver
$form.Controls.Add($credits)

$sysRam = New-Object System.Windows.Forms.Label
$sysRam.Location = New-Object System.Drawing.Point(20,80)
$sysRam.Size = New-Object System.Drawing.Size(450,25)
$form.Controls.Add($sysRam)

$totalRoblox = New-Object System.Windows.Forms.Label
$totalRoblox.Location = New-Object System.Drawing.Point(500,80)
$totalRoblox.Size = New-Object System.Drawing.Size(420,25)
$form.Controls.Add($totalRoblox)

$list = New-Object System.Windows.Forms.ListView
$list.Location = New-Object System.Drawing.Point(20,115)
$list.Size = New-Object System.Drawing.Size(930,370)
$list.View = 'Details'
$list.FullRowSelect = $true
$list.CheckBoxes = $true
$list.HideSelection = $false
$list.BackColor = [System.Drawing.Color]::FromArgb(32,32,38)
$list.ForeColor = [System.Drawing.Color]::White
$list.Columns.Add("Account",180) | Out-Null
$list.Columns.Add("Role",70) | Out-Null
$list.Columns.Add("PID",75) | Out-Null
$list.Columns.Add("RAM",90) | Out-Null
$list.Columns.Add("Status",100) | Out-Null
$list.Columns.Add("UserId",150) | Out-Null
$list.Columns.Add("Priority",110) | Out-Null
$form.Controls.Add($list)

$buttons = @()
function Add-Button($text,$x,$y,$w,$handler) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x,$y)
    $b.Size = New-Object System.Drawing.Size($w,34)
    $b.FlatStyle = 'Flat'
    $b.BackColor = [System.Drawing.Color]::FromArgb(48,48,58)
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Add_Click($handler)
    $form.Controls.Add($b)
    return $b
}

function Refresh-List {
    $checkedPids = @{}
    foreach ($it in $list.Items) {
        if ($it.Checked) { $checkedPids[[string]$it.Tag] = $true }
    }

    $list.BeginUpdate()
    $list.Items.Clear()

    foreach ($p in Get-RobloxProcesses) {
        $id = Resolve-IdentityForProcess $p
        $role = ""
        if (Is-Main $id) { $role="MAIN"; Set-MainPriority $p }
        elseif (Is-Alt $id) { $role="ALT"; Set-AltPriority $p }

        $ram = [math]::Round($p.WorkingSet64/1MB)
        $status = "Normal"
        if (-not $p.Responding) { $status="Frozen" }
        elseif ($ram -ge $script:TrimTriggerMB -and $role -eq "ALT") { $status="High RAM" }

        $name = if ($id.Username) { $id.Username } else { "Unknown" }
        $item = New-Object System.Windows.Forms.ListViewItem($name)
        $item.SubItems.Add($role) | Out-Null
        $item.SubItems.Add([string]$p.Id) | Out-Null
        $item.SubItems.Add("$ram MB") | Out-Null
        $item.SubItems.Add($status) | Out-Null
        $item.SubItems.Add([string]$id.UserId) | Out-Null
        $item.SubItems.Add([string]$p.PriorityClass) | Out-Null
        $item.Tag = $p.Id

        if ($role -eq "MAIN") {
            $item.Checked = $false
            $item.BackColor = [System.Drawing.Color]::FromArgb(40,62,92)
        } elseif ($status -eq "Frozen") {
            $item.BackColor = [System.Drawing.Color]::FromArgb(100,40,40)
            if ($checkedPids.ContainsKey([string]$p.Id) -or $role -eq "ALT") { $item.Checked=$true }
        } elseif ($status -eq "High RAM") {
            $item.BackColor = [System.Drawing.Color]::FromArgb(90,75,30)
            if ($checkedPids.ContainsKey([string]$p.Id) -or $role -eq "ALT") { $item.Checked=$true }
        } else {
            $item.BackColor = [System.Drawing.Color]::FromArgb(34,60,42)
            if ($checkedPids.ContainsKey([string]$p.Id) -or $role -eq "ALT") { $item.Checked=$true }
        }

        $list.Items.Add($item) | Out-Null
    }

    $list.EndUpdate()
}

function Update-MetersAndGuard {
    $procs = @(Get-RobloxProcesses)

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $total = [math]::Round($os.TotalVisibleMemorySize/1MB,1)
        $free = [math]::Round($os.FreePhysicalMemory/1MB,1)
        $used = [math]::Round($total-$free,1)
        $pct = if ($total -gt 0) { [math]::Round(($used/$total)*100) } else { 0 }
        $sysRam.Text = "System RAM: $used / $total GB ($($pct)%)"
    } catch {}

    $robloxMB = 0
    foreach ($p in $procs) {
        $robloxMB += ($p.WorkingSet64/1MB)
    }
    $totalRoblox.Text = "Total Roblox RAM: $([math]::Round($robloxMB/1024,2)) GB"

    foreach ($p in $procs) {
        $pidKey=[string]$p.Id
        $id = Resolve-IdentityForProcess $p
        $isMain = Is-Main $id
        $isAlt = Is-Alt $id

        if ($isMain) {
            Set-MainPriority $p
            continue
        }

        if ($isAlt) {
            Set-AltPriority $p

            # PERFORMANCE FIX:
            # Target is 600 MB, but trim only when reaching 700 MB.
            # This avoids hammering the working set around 600-610 MB.
            $ramMB = [math]::Round($p.WorkingSet64/1MB)
            if ($ramMB -ge $script:TrimTriggerMB) {
                Trim-Process $p
            }

            if ($script:AutoKillFrozen -and -not $p.Responding) {
                if (-not $script:LastKnown.ContainsKey($pidKey)) {
                    $script:LastKnown[$pidKey] = Get-Date
                } else {
                    $elapsed=((Get-Date)-$script:LastKnown[$pidKey]).TotalSeconds
                    if ($elapsed -ge $script:FrozenSeconds) {
                        Kill-Proc $p
                        $script:LastKnown.Remove($pidKey)
                    }
                }
            } else {
                if ($script:LastKnown.ContainsKey($pidKey)) { $script:LastKnown.Remove($pidKey) }
            }
        }
    }

    # Clean caches only for processes that no longer exist.
    $alive=@{}
    foreach($p in $procs){$alive[[string]$p.Id]=$true}
    foreach($k in @($script:Resolved.Keys)){
        if(-not $alive.ContainsKey($k)){ $script:Resolved.Remove($k) }
    }
    foreach($log in @($script:AssignedLogs.Keys)){
        $pid=[string]$script:AssignedLogs[$log]
        if(-not $alive.ContainsKey($pid)){ $script:AssignedLogs.Remove($log) }
    }

    # Update RAM/status cells without rebuilding identities.
    foreach ($it in $list.Items) {
        $p = Get-Process -Id ([int]$it.Tag) -ErrorAction SilentlyContinue
        if ($p) {
            $ram=[math]::Round($p.WorkingSet64/1MB)
            $it.SubItems[3].Text="$ram MB"
            $role=$it.SubItems[1].Text
            $status="Normal"
            if(-not $p.Responding){$status="Frozen"}
            elseif($role -eq "ALT" -and $ram -ge $script:TrimTriggerMB){$status="High RAM"}
            $it.SubItems[4].Text=$status
            $it.SubItems[6].Text=[string]$p.PriorityClass

            if($role -eq "MAIN"){$it.BackColor=[System.Drawing.Color]::FromArgb(40,62,92)}
            elseif($status -eq "Frozen"){$it.BackColor=[System.Drawing.Color]::FromArgb(100,40,40)}
            elseif($status -eq "High RAM"){$it.BackColor=[System.Drawing.Color]::FromArgb(90,75,30)}
            else{$it.BackColor=[System.Drawing.Color]::FromArgb(34,60,42)}
        }
    }
}

Add-Button "Refresh" 20 505 110 { Refresh-List } | Out-Null
Add-Button "Trim Selected" 140 505 130 {
    foreach($it in $list.CheckedItems){
        if($it.SubItems[1].Text -ne "MAIN"){
            $p=Get-Process -Id ([int]$it.Tag) -ErrorAction SilentlyContinue
            if($p){Trim-Process $p}
        }
    }
} | Out-Null
Add-Button "Trim All Alts" 280 505 130 {
    foreach($p in Get-RobloxProcesses){
        $id=Resolve-IdentityForProcess $p
        if(Is-Alt $id -and -not (Is-Main $id)){Trim-Process $p}
    }
} | Out-Null
Add-Button "Kill Selected" 420 505 120 {
    if([System.Windows.Forms.MessageBox]::Show("Kill selected Roblox instances?","Confirm",'YesNo') -eq 'Yes'){
        foreach($it in @($list.CheckedItems)){
            if($it.SubItems[1].Text -ne "MAIN"){
                $p=Get-Process -Id ([int]$it.Tag) -ErrorAction SilentlyContinue
                if($p){Kill-Proc $p}
            }
        }
        Start-Sleep -Milliseconds 250
        Refresh-List
    }
} | Out-Null
Add-Button "Kill All Frozen" 550 505 130 {
    foreach($p in Get-RobloxProcesses){if(-not $p.Responding){Kill-Proc $p}}
    Start-Sleep -Milliseconds 250
    Refresh-List
} | Out-Null
Add-Button "Minimize All Alts" 690 505 145 {
    foreach($p in Get-RobloxProcesses){
        $id=Resolve-IdentityForProcess $p
        if(Is-Alt $id -and -not (Is-Main $id)){Minimize-Proc $p}
    }
} | Out-Null

Add-Button "Mark as Alt" 20 550 120 {
    foreach($it in $list.SelectedItems){
        $p=Get-Process -Id ([int]$it.Tag) -ErrorAction SilentlyContinue
        if($p){
            $id=Resolve-IdentityForProcess $p
            if($id.Username -ne "Unknown"){
                if(Is-Main $id){$script:Main=$null; Save-JsonFile $script:MainFile $null}
                if(-not (Is-Alt $id)){
                    $script:Alts += [pscustomobject]@{UserId=$id.UserId;Username=$id.Username}
                    Save-JsonFile $script:AltFile $script:Alts
                }
            }
        }
    }
    Refresh-List
} | Out-Null

Add-Button "Remove Alt" 150 550 120 {
    foreach($it in $list.SelectedItems){
        $uid=$it.SubItems[5].Text
        $uname=$it.Text
        $script:Alts=@($script:Alts | Where-Object {
            -not (
                ($uid -and $_.UserId -and ([string]$_.UserId -eq [string]$uid)) -or
                ($uname -ne "Unknown" -and $_.Username -and ($_.Username -ieq $uname))
            )
        })
    }
    Save-JsonFile $script:AltFile $script:Alts
    Refresh-List
} | Out-Null

Add-Button "Mark as Main" 280 550 130 {
    if($list.SelectedItems.Count -gt 0){
        $it=$list.SelectedItems[0]
        $p=Get-Process -Id ([int]$it.Tag) -ErrorAction SilentlyContinue
        if($p){
            $id=Resolve-IdentityForProcess $p
            if($id.Username -ne "Unknown"){
                $script:Main=[pscustomobject]@{UserId=$id.UserId;Username=$id.Username}
                Save-JsonFile $script:MainFile $script:Main
                $script:Alts=@($script:Alts | Where-Object {
                    -not (
                        ($id.UserId -and $_.UserId -and ([string]$_.UserId -eq [string]$id.UserId)) -or
                        ($id.Username -and $_.Username -and ($_.Username -ieq $id.Username))
                    )
                })
                Save-JsonFile $script:AltFile $script:Alts
                Set-MainPriority $p
            }
        }
    }
    Refresh-List
} | Out-Null

Add-Button "Clear Main" 420 550 110 {
    $script:Main=$null
    Save-JsonFile $script:MainFile $null
    Refresh-List
} | Out-Null

$info = New-Object System.Windows.Forms.Label
$info.Text = "Auto-guard: ALT target 600 MB - trims at 700 MB - checks every 5s - resolved usernames stop log scanning"
$info.Location = New-Object System.Drawing.Point(20,595)
$info.Size = New-Object System.Drawing.Size(920,25)
$info.ForeColor = [System.Drawing.Color]::Silver
$form.Controls.Add($info)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $script:PollSeconds * 1000
$timer.Add_Tick({ Update-MetersAndGuard })
$timer.Start()

Refresh-List
Update-MetersAndGuard
[void]$form.ShowDialog()
