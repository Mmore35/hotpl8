# Pure observation contract. Native adapters supply facts, never credentials.
. (Join-Path $PSScriptRoot 'common.ps1')
function Get-Hotpl8ProviderSetting($Policy,[string]$Name,$Default) {
    if($null -ne $Policy.$Name){return $Policy.$Name}
    return $Default
}
function ConvertTo-Hotpl8ProviderWindow($Window,[datetimeoffset]$Now,[double]$MaxAgeSeconds=900) {
    $reason=$null;$remaining=$null;$reset=$null;$rolled=$false
    $state=[string]$Window.state
    if($Window.name -isnot [string] -or [string]::IsNullOrWhiteSpace($Window.name) -or $Window.name.Length -gt 128 -or $Window.name -match '[\x00-\x1f\x7f]' -or $Window.scope -isnot [string] -or $Window.role -notin @('short','weekly','scoped') -or $Window.required -isnot [bool] -or $state -notin @('observed','not_applicable','unknown')){$reason='window_malformed'}
    elseif($state -eq 'not_applicable'){
        if($Window.required -eq $true){$reason='window_required'}
    }elseif($state -ne 'observed'){$reason='window_unknown'}
    elseif(-not (Test-Hotpl8Number $Window.usedPercent) -or $Window.usedPercent -lt 0 -or $Window.usedPercent -gt 100){$reason='window_malformed'}
    else{
        try{$age=($Now-[datetimeoffset]::Parse([string]$Window.observedAt)).TotalSeconds}catch{$age=$null}
        if($null -eq $age -or $age -lt -5 -or $age -gt $MaxAgeSeconds){$reason='window_stale'}
        if($Window.resetConfirmed -isnot [bool]){$reason='window_malformed'}
        if($Window.resetRequired -eq $true -and -not $Window.resetAt){$reason='reset_unconfirmed'}
        $resolved=Resolve-Hotpl8Window $Window.usedPercent $Window.resetAt $Window.observedAt $Now
        $remaining=100-[double]$resolved.used;$rolled=[bool]$resolved.rolledOver
        if($Window.resetAt){
            try{$at=[datetimeoffset]::Parse([string]$Window.resetAt)}catch{$at=$null;$reason='window_malformed'}
            if($at -and $at -le $Now -and -not $rolled){$reason='reset_unconfirmed'}
            if($at -and $at -gt $Now -and $Window.resetConfirmed -eq $true){$reset=$at.ToUniversalTime().ToString('o')}
        }
    }
    [pscustomobject]@{name=[string]$Window.name;scope=[string]$Window.scope;role=[string]$Window.role;state=$state;required=($Window.required -eq $true);remainingPercent=$remaining;resetAt=$reset;observedAt=$Window.observedAt;rolledOver=$rolled;reason=$reason}
}
function ConvertTo-Hotpl8ProviderAccount($Account,$Policy,$Scopes,[datetimeoffset]$Now) {
    $id=[string]$Account.id;$reason=$null
    $reserve=if($null -ne $Account.reserve){[bool]$Account.reserve}else{$id -in @($Policy.reserve|ForEach-Object {[string]$_})}
    $preference=if($null -ne $Account.preference){[int]$Account.preference}else{[array]::IndexOf(@($Policy.prefer|ForEach-Object {[string]$_}),$id)}
    if($preference -lt 0){$preference=[int]::MaxValue}
    if(-not $id){$reason='account_unknown'}
    elseif($Account.enabled -eq $false -or $id -in @($Policy.disabled|ForEach-Object {[string]$_})){$reason='disabled'}
    elseif($Account.identityValid -eq $false -or $Account.bindingValid -eq $false){$reason='binding_changed'}
    elseif($Account.status -ne 'ok'){$reason=if($Account.status){[string]$Account.status}else{'unknown'}}
    elseif($Account.blockedReason){$reason=[string]$Account.blockedReason}
    else{
        try{$age=($Now-[datetimeoffset]::Parse([string]$Account.observedAt)).TotalSeconds}catch{$age=$null}
        if($null -eq $age -or $age -lt -5 -or $age -gt (Get-Hotpl8ProviderSetting $Policy 'maxUsageAgeS' 900)){$reason='stale'}
    }
    $inputWindows=@($Account.windows|Where-Object {$null -ne $_})
    foreach($scope in @($Scopes)){
        if(-not @($inputWindows|Where-Object {$_.scope -ceq $scope -and $_.state -eq 'observed'}).Count -and -not $reason){$reason='model_quota_unknown'}
    }
    $normalized=@(foreach($w in $inputWindows){ConvertTo-Hotpl8ProviderWindow $w $Now (Get-Hotpl8ProviderSetting $Policy 'maxUsageAgeS' 900)})
    # Validate before scope filtering: malformed scope metadata cannot hide a
    # required constraint by making it appear to belong to an unrelated model.
    if(-not $reason -and @($normalized|Where-Object reason -EQ 'window_malformed').Count){$reason='window_malformed'}
    $windows=@($normalized|Where-Object {-not @($Scopes).Count -or -not $_.scope -or $_.scope -cin @($Scopes)})
    $seen=@{}
    foreach($w in $windows){
        $key=$w.scope+'/'+$w.name
        if($seen.ContainsKey($key) -and -not $reason){$reason='duplicate_window'}
        $seen[$key]=$true
        if($w.reason -and -not $reason){$reason=$w.reason}
    }
    $observed=@($windows|Where-Object state -EQ 'observed')
    if(-not $observed.Count -and -not $reason){$reason='window_unknown'}
    $short=@($observed|Where-Object role -EQ 'short')
    $week=@($observed|Where-Object role -EQ 'weekly')
    $shortLeft=if($short.Count){($short|Measure-Object remainingPercent -Minimum).Minimum}else{$null}
    $weekLeft=if($week.Count){($week|Measure-Object remainingPercent -Minimum).Minimum}else{$null}
    $binding=if($observed.Count){($observed|Measure-Object remainingPercent -Minimum).Minimum}else{$null}
    $resetWindows=if($short.Count){$short}else{$week}
    $reset=@($resetWindows|Where-Object resetAt|Sort-Object resetAt|Select-Object -First 1)
    $weeklyReset=@($week|Where-Object resetAt|Sort-Object resetAt|Select-Object -First 1)
    $scaled=$Account.capacity.scaled -eq $true -and (Test-Hotpl8Number $Account.capacity.gross) -and $Account.capacity.gross -ge 0
    [pscustomobject]@{id=$id;identityKey=[string]$Account.identityKey;reserve=$reserve;preference=$preference;reason=$reason;valid=(-not $reason);windows=$windows;shortRemaining=$shortLeft;weeklyRemaining=$weekLeft;bindingRemaining=$binding;resetAt=$(if($reset.Count){$reset[0].resetAt}else{$null});weeklyResetAt=$(if($weeklyReset.Count){$weeklyReset[0].resetAt}else{$null});scaled=$scaled;gross=$(if($scaled){$Account.capacity.gross}else{$null});observedAt=$Account.observedAt}
}
function Get-Hotpl8ProviderMargin($Policy,$Account,$Window,[bool]$Emergency=$false) {
    if($Emergency -and $Policy.critical.enabled -eq $true -and -not $Account.reserve){if($Policy.critical.drainToZero){return 0};return (Get-Hotpl8ProviderSetting $Policy.critical 'floorPercent' 1)}
    if($Window.role -eq 'short'){return (Get-Hotpl8ProviderSetting $Policy 'margin5h' 25)}
    if(-not $Account.reserve -and $null -ne $Policy.margin7dWork){return $Policy.margin7dWork}
    return (Get-Hotpl8ProviderSetting $Policy 'margin7d' 20)
}
