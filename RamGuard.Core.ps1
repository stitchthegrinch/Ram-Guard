# Shared profile and guard rules. No UI, process mutations, or startup side effects.
function New-DefaultProfile {
    return [pscustomobject]@{
        SchemaVersion=1; Main=$null; Alts=@()
        Settings=[pscustomobject]@{TrimTriggerMB=700;PollSeconds=3;FrozenSeconds=30;TrimCooldownSeconds=30;CloseFrozen=$true}
    }
}
function ConvertTo-GuardAccount($account) {
    if ($null -eq $account) { return $null }
    $uid=[string]$account.UserId
    $name=[string]$account.Username
    if ($uid -and $uid -notmatch '^[1-9][0-9]{0,17}$') { throw 'An account has an invalid UserId.' }
    if ($name -and $name -ne 'Unknown' -and $name -notmatch '^[A-Za-z0-9_]{3,20}$') { throw 'An account has an invalid username.' }
    if (-not $uid -and (-not $name -or $name -eq 'Unknown')) { throw 'An account needs a UserId or username.' }
    return [pscustomobject]@{UserId=$(if($uid){$uid}else{$null});Username=$(if($name){$name}else{'Unknown'})}
}
function Test-SameAccount($left,$right) {
    if (-not $left -or -not $right) { return $false }
    if ($left.UserId -and $right.UserId) { return [string]$left.UserId -eq [string]$right.UserId }
    return $left.Username -and $left.Username -ne 'Unknown' -and $left.Username -ieq $right.Username
}
function Get-AccountKey($account) {
    if ($account.UserId) { return 'id:'+[string]$account.UserId }
    if ($account.Username -and $account.Username -ne 'Unknown') { return 'name:'+([string]$account.Username).ToLowerInvariant() }
    return ''
}
function Get-InstanceKey($row) { return '{0}:{1}' -f $row.Id,$row.StartTicks }
function Test-ManagedAlt($row,$main,$alts) {
    if (Test-SameAccount $row $main) { return $false }
    foreach($alt in @($alts)){if(Test-SameAccount $row $alt){return $true}}
    return $false
}
function Test-GuardEligible($row,$main,$alts,$enabled,$armed) {
    if (-not $enabled -or -not $row.StartTicks) { return $false }
    if (-not (Test-ManagedAlt $row $main $alts)) { return $false }
    $key=Get-InstanceKey $row
    return $armed.ContainsKey($key) -and $armed[$key] -eq $true
}
function ConvertTo-GuardProfile($data) {
    if (-not $data -or $data.SchemaVersion -ne 1 -or -not $data.Settings -or
        $null -eq $data.PSObject.Properties['Alts'] -or $null -eq $data.PSObject.Properties['Main']) { throw 'This is not a supported RAM Guard profile (schema 1).' }
    $result=New-DefaultProfile
    $result.Main=ConvertTo-GuardAccount $data.Main
    $accounts=New-Object 'System.Collections.Generic.List[object]'
    if (@($data.Alts).Count -gt 1000) { throw 'This profile contains too many accounts.' }
    foreach($raw in @($data.Alts)){
        if ($null -eq $raw) { continue }
        $account=ConvertTo-GuardAccount $raw
        if(Test-SameAccount $account $result.Main){continue}
        $duplicate=$false
        foreach($existing in $accounts){if(Test-SameAccount $existing $account){$duplicate=$true;break}}
        if(-not $duplicate){$accounts.Add($account)}
    }
    $result.Alts=@($accounts.ToArray())
    $limits=@{TrimTriggerMB=@(100,65536);PollSeconds=@(1,60);FrozenSeconds=@(5,600);TrimCooldownSeconds=@(10,600)}
    foreach($key in $limits.Keys){
        if($null -eq $data.Settings.PSObject.Properties[$key]){continue}
        $value=[string]$data.Settings.$key
        if($value -notmatch '^\d+$'){throw "Invalid setting: $key"}
        $number=[long]$value
        if($number -lt $limits[$key][0] -or $number -gt $limits[$key][1]){throw "Setting out of range: $key"}
        $result.Settings.$key=[int]$number
    }
    if($null -ne $data.Settings.PSObject.Properties['CloseFrozen']){
        if($data.Settings.CloseFrozen -isnot [bool]){throw 'CloseFrozen must be true or false.'}
        $result.Settings.CloseFrozen=$data.Settings.CloseFrozen
    }
    return $result
}
function Read-GuardJson($path) {
    $file=Get-Item -LiteralPath $path -ErrorAction Stop
    if($file.Length -gt 5MB){throw 'The save file is too large.'}
    return ([IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json -ErrorAction Stop)
}
function Read-LegacyProfile($folder) {
    $profile=New-DefaultProfile
    $found=$false
    foreach($pair in @(@('main.json','Main'),@('alts.json','Alts'),@('settings.json','Settings'))){
        $path=Join-Path $folder $pair[0]
        if(Test-Path -LiteralPath $path){
            $found=$true
            $value=Read-GuardJson $path
            if($pair[1] -eq 'Alts'){$profile.Alts=@($value)}
            elseif($pair[1] -eq 'Main'){$profile.Main=$value}
            else{if(-not $value){throw 'The legacy settings file is empty.'};$profile.Settings=$value}
        }
    }
    if(-not $found){throw 'No alts.json, main.json, or settings.json found in that folder.'}
    return ConvertTo-GuardProfile $profile
}
function Write-GuardProfile($path,$profile) {
    $normalized=ConvertTo-GuardProfile $profile
    $folder=Split-Path -Parent $path
    [void][IO.Directory]::CreateDirectory($folder)
    $temp=Join-Path $folder ('.profile-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{
        $json=ConvertTo-Json -InputObject $normalized -Depth 8
        [IO.File]::WriteAllText($temp,$json,(New-Object Text.UTF8Encoding($false)))
        if([IO.File]::Exists($path)){[IO.File]::Replace($temp,$path,($path+'.bak'),$true)}
        else{[IO.File]::Move($temp,$path)}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
    return $normalized
}
function Initialize-GuardProfile($dataDirectory,$legacyDirectory) {
    $path=Join-Path $dataDirectory 'profile.json'
    if(Test-Path -LiteralPath $path){
        try{return [pscustomobject]@{Profile=(ConvertTo-GuardProfile (Read-GuardJson $path));CanSave=$true;Notice=''}}catch{
            try{return [pscustomobject]@{Profile=(ConvertTo-GuardProfile (Read-GuardJson ($path+'.bak')));CanSave=$true;Notice='Recovered your previous profile backup.'}}catch{
                return [pscustomobject]@{Profile=(New-DefaultProfile);CanSave=$false;Notice='Saved profile is unreadable. Import a valid backup before saving changes.'}
            }
        }
    }
    $legacyPresent=$false
    foreach($name in @('alts.json','main.json','settings.json')){if(Test-Path -LiteralPath (Join-Path $legacyDirectory $name)){$legacyPresent=$true}}
    try{
        $profile=if($legacyPresent){Read-LegacyProfile $legacyDirectory}else{New-DefaultProfile}
        $saved=Write-GuardProfile $path $profile
        return [pscustomobject]@{Profile=$saved;CanSave=$true;Notice=$(if($legacyPresent){'Imported your old settings and account roles automatically.'}else{''})}
    }catch{return [pscustomobject]@{Profile=(New-DefaultProfile);CanSave=$false;Notice=('Could not initialize saves: '+$_.Exception.Message)}}
}
