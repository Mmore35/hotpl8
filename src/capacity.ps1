# Capacity is expressed in relative weekly units within one provider/meter only.
# Unknown conversions are not inferred from monthly prices or selection weights.
function Get-Hotpl8CapacityCatalog {
    if(-not $script:Hotpl8CapacityCatalog){$script:Hotpl8CapacityCatalog=Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'data/capacity-profiles.json') -Raw|ConvertFrom-Json}
    return $script:Hotpl8CapacityCatalog
}
function Assert-Hotpl8CapacityPolicy($Part) {
    foreach($entry in $Part.capacity.PSObject.Properties){
        if($entry.Name -notmatch '^[a-zA-Z0-9_-]{1,40}$' -or $entry.Value -isnot [pscustomobject]){throw 'Invalid capacity account.'}
        $c=$entry.Value
        foreach($field in $c.PSObject.Properties){if($field.Name -notin @('profile','weekly','fiveHour','scoped','evidence')){throw 'Invalid capacity field.'}}
        if($c.profile -and -not (Get-Hotpl8CapacityCatalog).profiles.([string]$c.profile)){throw 'Unknown capacity profile.'}
        foreach($key in @('weekly','fiveHour')){if($null -ne $c.$key -and (-not (Test-Hotpl8Number $c.$key) -or $c.$key -le 0 -or $c.$key -gt 1000000)){throw 'Capacity must be a positive finite number.'}}
        foreach($scope in $c.scoped.PSObject.Properties){if($scope.Name -notmatch '^[a-zA-Z0-9_-]{1,80}$' -or -not (Test-Hotpl8Number $scope.Value) -or $scope.Value -le 0 -or $scope.Value -gt 1000000){throw 'Invalid scoped capacity.'}}
        if($c.evidence -and ([string]$c.evidence).Length -gt 240){throw 'Capacity evidence is too long.'}
    }
}
function Get-Hotpl8AccountCapacity($Part,[string]$Slot,[string]$Provider,[string]$Meter='codex') {
    $c=$Part.capacity.$Slot;$profile=if($c.profile){(Get-Hotpl8CapacityCatalog).profiles.([string]$c.profile)}else{$null}
    if($profile -and ($profile.provider -ne $Provider -or ($Provider -eq 'codex' -and $profile.meter -ne $Meter))){$profile=$null}
    $weekly=if($null -ne $c.weekly){$c.weekly}else{$profile.weekly}
    $short=if($null -ne $c.fiveHour){$c.fiveHour}else{$profile.fiveHour}
    return [pscustomobject]@{weekly=$weekly;fiveHour=$short;scoped=$c.scoped;profile=$c.profile;confidence=$(if($c.weekly -or $c.fiveHour){'user estimate'}elseif($profile){$profile.confidence}else{'capacity setup needed'})}
}
function New-Hotpl8CapacityWindow([string]$Name,$Remaining,$Full,$Reset,[datetimeoffset]$Now,[bool]$Confirmed=$true) {
    $at=$null
    try{if($Reset){$at=[datetimeoffset]::Parse([string]$Reset)}}catch{}
    $valid=(Test-Hotpl8Number $Remaining) -and $Remaining -ge 0 -and $Remaining -le 100 -and ($null -eq $at -or $at -gt $Now)
    return [pscustomobject]@{name=$Name;remaining=$Remaining;full=$Full;valid=$valid;resetAt=$(if($Confirmed -and $at){$at.ToString('o')}else{$null})}
}
function Get-Hotpl8CapacityAccounts($Snapshot,$Part,[string]$Provider,[datetimeoffset]$Now,[string]$Meter='codex') {
    $ids=if($Provider -eq 'claude'){@($Part.prefer)}else{@($Part.slots|ForEach-Object id)}
    $seen=@{}
    foreach($id in @($ids|Where-Object {$null -ne $_ -and $_ -notin @($Part.disabled)}|Select-Object -Unique)){
        $slot=@(if($Provider -eq 'claude'){$Snapshot.slots|Where-Object slot -EQ $id}else{$Snapshot.providers.codex.slots|Where-Object id -EQ $id})
        $s=if($slot.Count -eq 1){$slot[0]}else{$null}
        if($s.streamKey -and $s.status -in @('ok','duplicate_subscription')){if($seen.ContainsKey($s.streamKey)){continue};$seen[$s.streamKey]=$true}
        $c=Get-Hotpl8AccountCapacity $Part ([string]$id) $Provider $Meter
        $fresh=$s -and $s.status -eq 'ok' -and (Test-Hotpl8FreshTimestamp $s.observedAt $Now)
        $windows=@();$blocked=$false;$reason=''
        if($Provider -eq 'claude'){
            $fresh=$fresh -and $s.fresh
            $windows+=New-Hotpl8CapacityWindow '10080' $(if(Test-Hotpl8Number $s.used7d){100-$s.used7d}else{$null}) $c.weekly $s.reset7d $Now
            $windows+=New-Hotpl8CapacityWindow '300' $(if(Test-Hotpl8Number $s.used5h){100-$s.used5h}else{$null}) $c.fiveHour $s.reset5h $Now
            foreach($model in @($Part.claudeModels)){
                if(-not $model){continue}
                $scope=@($s.scoped|Where-Object name -EQ $model)
                $w=if($scope.Count -eq 1){$scope[0]}else{$null}
                $windows+=New-Hotpl8CapacityWindow $model $(if(Test-Hotpl8Number $w.pct){100-$w.pct}else{$null}) $c.scoped.$model $w.resetsAt $Now
            }
        }else{
            $b=$s.buckets.$Meter
            $blocked=$b.status -ne 'observed';$reason=if($b){$b.status}else{'meter_unknown'}
            foreach($entry in $b.windows.PSObject.Properties){
                $w=$entry.Value;$reset=$null
                try{if($w.resetsAt){$reset=[datetimeoffset]::FromUnixTimeSeconds([long]$w.resetsAt).ToString('o')}}catch{}
                $full=if($entry.Name -eq '10080'){$c.weekly}else{$c.fiveHour}
                # A single weekly-only subscription needs no cross-account conversion.
                if($ids.Count -eq 1 -and $entry.Name -eq '10080' -and @($b.windows.PSObject.Properties).Count -eq 1 -and $null -eq $full){$full=1;$c.weekly=1;$c.confidence='single-account normalization'}
                $windows+=New-Hotpl8CapacityWindow $entry.Name $w.remainingPercent $full $reset $Now ($w.anchorState -eq 'observed-active')
            }
        }
        $known=$fresh -and $windows.Count -gt 0 -and @($windows|Where-Object {-not $_.valid}).Count -eq 0
        $scaled=$known -and $null -ne $c.weekly -and @($windows|Where-Object {$null -eq $_.full}).Count -eq 0
        $gross=$null;$percent=$null
        if($known){$percent=($windows|Measure-Object remaining -Minimum).Minimum}
        if($scaled){$gross=($windows|ForEach-Object {$_.full*$_.remaining/100}|Measure-Object -Minimum).Minimum}
        $knownZero=$known -and $blocked -and $reason -eq 'blocked' -and $percent -eq 0
        [pscustomobject]@{slot=[string]$id;fresh=[bool]$known;scaled=[bool]$scaled;knownZero=[bool]$knownZero;weekly=$c.weekly;windows=$windows;gross=$gross;bindingRemaining=$percent;blocked=$blocked;reason=$reason;reserve=($id -in @($Part.reserve));confidence=$c.confidence}
    }
}
function Get-Hotpl8CapacityAmount($Account,$Part,[datetimeoffset]$At,[bool]$Project,[bool]$Emergency=$false) {
    if(-not $Account.scaled -or $Account.blocked){return $null}
    $units=[double]::MaxValue
    foreach($w in $Account.windows){
        $left=[double]$w.remaining
        if($Project -and $w.resetAt -and [datetimeoffset]::Parse($w.resetAt) -le $At){$left=100}
        $margin=if($w.name -eq '300'){[double]$Part.margin5h}elseif($Account.reserve){[double]$Part.margin7d}elseif($null -ne $Part.margin7dWork){[double]$Part.margin7dWork}else{[double]$Part.margin7d}
        if($Emergency -and -not $Account.reserve){$margin=if($Part.critical.drainToZero){0}else{Get-Hotpl8CriticalSetting $Part 'floorPercent' 1}}
        if($left -le 0 -or $left -lt $margin){return 0.0}
        $units=[math]::Min($units,$w.full*$left/100)
    }
    return $units
}
function Get-Hotpl8ProviderCapacity($Snapshot,$Part,[string]$Provider,[datetimeoffset]$Now,[string]$Meter='codex') {
    $accounts=@(Get-Hotpl8CapacityAccounts $Snapshot $Part $Provider $Now $Meter)
    $denominatorKnown=$accounts.Count -gt 0 -and @($accounts|Where-Object {$null -eq $_.weekly}).Count -eq 0
    $total=if($denominatorKnown){($accounts|Measure-Object weekly -Sum).Sum}else{$null}
    $complete=$denominatorKnown -and @($accounts|Where-Object {-not $_.scaled -or ($_.blocked -and -not $_.knownZero)}).Count -eq 0
    # A measured zero is known now, but a generic native block may survive reset.
    $projectionComplete=$complete -and @($accounts|Where-Object blocked).Count -eq 0
    $hold=if($Provider -eq 'claude'){$Snapshot.hold}else{$Snapshot.providers.codex.hold}
    $selected=if($Provider -eq 'claude'){[string]$Snapshot.active}else{[string]$Snapshot.providers.codex.recommendedSlot}
    if($hold){try{if([datetimeoffset]::Parse($hold.until) -le $Now){$hold=$null}}catch{}}
    $pause=$Snapshot.automationPause
    if($pause){try{if([datetimeoffset]::Parse($pause.until) -le $Now){$pause=$null}}catch{}}
    $restricted=$hold -or $pause -or ($Provider -eq 'claude' -and ($Part.mode -eq 'monitor' -or $Part.switchEnabled -eq $false))
    $critical=Get-Hotpl8CriticalDecision $accounts $Part $selected $(if($Provider -eq 'claude'){$Snapshot.critical}else{$Snapshot.providers.codex.critical.$Meter}) $Now
    $resets=@($accounts|Where-Object {$_.fresh -and (-not $_.blocked -or $_.knownZero)}|ForEach-Object {$_.windows}|Where-Object {$_.resetAt -and [datetimeoffset]::Parse($_.resetAt) -gt $Now}|Sort-Object {[datetimeoffset]::Parse($_.resetAt)})
    $next=if($resets.Count){[datetimeoffset]::Parse($resets[0].resetAt)}else{$null}
    $solid=0.0;$future=0.0;$unknown=0.0
    foreach($a in $accounts){
        if($a.scaled -and $a.knownZero){continue}
        if(-not $a.scaled -or $a.blocked){if($a.weekly){$unknown+=$a.weekly};continue}
        if($restricted -and $a.slot -ne $selected){continue}
        $solid+=Get-Hotpl8CapacityAmount $a $Part $Now $false $critical.active
        if($next){$future+=Get-Hotpl8CapacityAmount $a $Part $next $true $critical.active}
    }
    $gain=if($next){[math]::Max(0.0,$future-$solid)}else{$null}
    [pscustomobject]@{metric='weighted-weekly-capacity';unit='relative weekly allowance';totalUnits=$total;complete=[bool]$complete;accounts=$accounts;measured=@($accounts|Where-Object scaled).Count;usableNowPercent=$(if($complete){[math]::Min(100.0,100*$solid/$total)}else{$null});knownUsablePercent=$(if($total){[math]::Min(100.0,100*$solid/$total)}else{0});unknownPercent=$(if($total){100*$unknown/$total}else{100});nextResetAt=$(if($next){$next.ToString('o')}else{$null});projectionComplete=[bool]$projectionComplete;projectedGainPercent=$(if($projectionComplete -and $next){[math]::Min(100-100*$solid/$total,100*$gain/$total)}else{$null});projectionAssumption='No further consumption; other limits and policy still apply';critical=$critical;restricted=[bool]$restricted;confidence=$(if($complete){'estimate'}else{'capacity setup or fresh reading needed'})}
}
