
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:AltFile = Join-Path $PSScriptRoot "alts.json"
$script:MainFile = Join-Path $PSScriptRoot "main.json"
$script:SettingsFile = Join-Path $PSScriptRoot "settings.json"

$script:Resolved = @{}
$script:PidToLog = @{}
$script:LogToPid = @{}
$script:FreezeStart = @{}
$script:KnownPids = @()
$script:UserNameCache = @{}

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

function Get-RobloxLogs {
    $logDir = Join-Path $env:LOCALAPPDATA "Roblox\logs"
    if (-not (Test-Path $logDir)) { return @() }
    @(Get-ChildItem $logDir -Filter "*Player*.log" -File -ErrorAction SilentlyContinue |
      Sort-Object CreationTime, LastWriteTime -Descending)
}

function Read-LogTail($path, $maxBytes = 2097152) {
    try {
        $fi = Get-Item $path -ErrorAction Stop
        $len = $fi.Length
        if ($len -le $maxBytes) {
            return [System.IO.File]::ReadAllText($path)
        }

        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $fs.Seek(-$maxBytes, [System.IO.SeekOrigin]::End) | Out-Null
            $buf = New-Object byte[] $maxBytes
            $read = $fs.Read($buf, 0, $buf.Length)
            return [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally {
            $fs.Dispose()
        }
    } catch { return "" }
}

function Resolve-UsernameFromUserId($userId) {
    if (-not $userId) { return $null }
    $key=[string]$userId
    if ($script:UserNameCache.ContainsKey($key)) {
        return $script:UserNameCache[$key]
    }
    try {
        $resp = Invoke-RestMethod -Uri ("https://users.roblox.com/v1/users/" + $key) -Method Get -TimeoutSec 3
        if ($resp -and $resp.name) {
            $script:UserNameCache[$key] = [string]$resp.name
            return [string]$resp.name
        }
    } catch {}
    return $null
}

function Parse-IdentityFromText($txt) {
    if (-not $txt) { return $null }

    $userId=$null
    $username=$null

    $idPatterns=@(
        '"userId"\s*:\s*(\d+)',
        '"userid"\s*:\s*(\d+)',
        '\bUserId\b[^0-9]{0,12}(\d+)',
        '\buserid\b[^0-9]{0,12}(\d+)',
        'userId=(\d+)',
        'userid=(\d+)',
        'UserID=(\d+)',
        '"UserId"\s*:\s*"?(?<id>\d+)"?'
    )
    foreach($pat in $idPatterns){
        $m=[regex]::Match($txt,$pat,'IgnoreCase')
        if($m.Success){
            if($m.Groups["id"].Success){$userId=$m.Groups["id"].Value}else{$userId=$m.Groups[1].Value}
            break
        }
    }

    $namePatterns=@(
        '"username"\s*:\s*"([^"]+)"',
        '\busername\b[^A-Za-z0-9_]{0,8}([A-Za-z0-9_]{3,20})',
        '"name"\s*:\s*"([A-Za-z0-9_]{3,20})"'
    )
    foreach($pat in $namePatterns){
        $m=[regex]::Match($txt,$pat,'IgnoreCase')
        if($m.Success){$username=$m.Groups[1].Value;break}
    }

    if($userId -or $username){
        return [pscustomobject]@{UserId=$userId;Username=$username}
    }
    return $null
}

function Get-BestLogForProcess($proc) {
    $pidKey=[string]$proc.Id

    if ($script:PidToLog.ContainsKey($pidKey)) {
        $existing=$script:PidToLog[$pidKey]
        if (Test-Path $existing) { return $existing }
        $script:PidToLog.Remove($pidKey)
    }

    $logs=Get-RobloxLogs
    if(-not $logs){return $null}

    $start=$proc.StartTime

    # Only consider unclaimed logs. Prefer log creation time nearest process start.
    $candidates=@($logs | Where-Object {
        -not $script:LogToPid.ContainsKey($_.FullName)
    } | Sort-Object {
        [math]::Abs(($_.CreationTime - $start).TotalSeconds)
    })

    # Favor logs created within a reasonable launch window.
    foreach($log in $candidates){
        $delta=[math]::Abs(($log.CreationTime-$start).TotalSeconds)
        if($delta -le 120){
            $script:PidToLog[$pidKey]=$log.FullName
            $script:LogToPid[$log.FullName]=$pidKey
            return $log.FullName
        }
    }

    # Fallback: nearest unused log.
    if($candidates.Count -gt 0){
        $pick=$candidates[0].FullName
        $script:PidToLog[$pidKey]=$pick
        $script:LogToPid[$pick]=$pidKey
        return $pick
    }
    return $null
}

function Resolve-IdentityForProcess($proc) {
    $pidKey=[string]$proc.Id

    if($script:Resolved.ContainsKey($pidKey)){
        return $script:Resolved[$pidKey]
    }

    $logPath=Get-BestLogForProcess $proc
    if(-not $logPath){
        return [pscustomobject]@{UserId=$null;Username="Unknown";Log=$null}
    }

    # Keep retrying THE SAME assigned log as Roblox writes more data to it.
    $txt=Read-LogTail $logPath
    $parsed=Parse-IdentityFromText $txt

    if($parsed){
        $uid=$parsed.UserId
        $uname=$parsed.Username

        # Prefer resolving the real username from the UserId.
        if($uid){
            $apiName=Resolve-UsernameFromUserId $uid
            if($apiName){$uname=$apiName}
        }

        if($uid -or ($uname -and $uname -ne "Unknown")){
            $obj=[pscustomobject]@{
                UserId=$uid
                Username=$(if($uname){$uname}else{"Unknown"})
                Log=$logPath
            }
            $script:Resolved[$pidKey]=$obj
            return $obj
        }
    }

    return [pscustomobject]@{UserId=$null;Username="Unknown";Log=$logPath}
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
$form.Text="Roblox RAM Guard v7.7"
$form.Size=New-Object System.Drawing.Size(1030,710)
$form.StartPosition="CenterScreen"
$form.BackColor=[System.Drawing.Color]::FromArgb(24,24,28)
$form.ForeColor=[System.Drawing.Color]::White
$form.Font=New-Object System.Drawing.Font("Segoe UI",10)

$title=New-Object System.Windows.Forms.Label
$title.Text="Roblox RAM Guard v7.7"
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

    $needsUiIdentityRefresh=$false

    foreach($p in $procs){
        $pidKey=[string]$p.Id
        $wasResolved=$script:Resolved.ContainsKey($pidKey)
        $id=Resolve-IdentityForProcess $p
        if((-not $wasResolved) -and $script:Resolved.ContainsKey($pidKey)){
            $needsUiIdentityRefresh=$true
        }

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

    if($needsUiIdentityRefresh){Refresh-List}

    $alive=@{}
    foreach($p in $procs){$alive[[string]$p.Id]=$true}
    foreach($k in @($script:Resolved.Keys)){if(-not $alive.ContainsKey($k)){$script:Resolved.Remove($k)}}
    foreach($k in @($script:PidToLog.Keys)){
        if(-not $alive.ContainsKey($k)){
            $lp=$script:PidToLog[$k]
            $script:PidToLog.Remove($k)
            if($script:LogToPid.ContainsKey($lp)){$script:LogToPid.Remove($lp)}
        }
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

Add-Button "Refresh" 20 495 100 {Refresh-List}|Out-Null
Add-Button "Trim Selected" 130 495 125 {
    foreach($it in $list.CheckedItems){
        if($it.SubItems[1].Text -ne "MAIN"){
            $p=Get-Process -Id ([int]$it.Tag)-ErrorAction SilentlyContinue
            if($p){Trim-Process $p}
        }
    }
}|Out-Null
Add-Button "Trim All Alts" 265 495 125 {
    foreach($p in Get-RobloxProcesses){$id=Resolve-IdentityForProcess $p;if(Is-Alt $id -and -not(Is-Main $id)){Trim-Process $p}}
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
Add-Button "Kill All Frozen" 530 495 125 {foreach($p in Get-RobloxProcesses){if(-not $p.Responding){Kill-Proc $p}}}|Out-Null
Add-Button "Minimize All Alts" 665 495 145 {
    foreach($p in Get-RobloxProcesses){$id=Resolve-IdentityForProcess $p;if(Is-Alt $id -and -not(Is-Main $id)){Minimize-Proc $p}}
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
        $uid=$it.SubItems[5].Text;$uname=$it.Text
        $script:Alts=@($script:Alts|Where-Object{-not(
            ($uid -and $_.UserId -and ([string]$_.UserId -eq [string]$uid)) -or
            ($uname -ne "Unknown" -and $_.Username -and ($_.Username -ieq $uname))
        )})
    }
    Save-JsonFile $script:AltFile $script:Alts;Refresh-List
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
Add-Button "Clear Main" 265 650 100 {$script:Main=$null;Save-JsonFile $script:MainFile $null;Refresh-List}|Out-Null

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
$info.Text="v7.7 identity detection: each PID keeps its own log and retries it until a UserId is found."
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
[void]$form.ShowDialog()
