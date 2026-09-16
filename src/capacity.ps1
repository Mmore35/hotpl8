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
function Get-Hotpl8AccountCapacity($Part,[string]$Slot,[string]$Provider,[string]$Meter='codex',$DetectedPlan=$null,[datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
    $c=$Part.capacity.$Slot
    $profileId=if($c.profile){[string]$c.profile}elseif($Provider -eq 'claude' -and $DetectedPlan.status -eq 'detected' -and (Test-Hotpl8DetectedPlan $DetectedPlan $Now)){[string]$DetectedPlan.profile}else{$null}
    $profile=if($profileId){(Get-Hotpl8CapacityCatalog).profiles.$profileId}else{$null}
    if($profile -and ($profile.provider -ne $Provider -or ($Provider -eq 'codex' -and $profile.meter -ne $Meter))){$profile=$null}
    $weekly=if($null -ne $c.weekly){$c.weekly}else{$profile.weekly}
    $short=if($null -ne $c.fiveHour){$c.fiveHour}else{$profile.fiveHour}
    return [pscustomobject]@{weekly=$weekly;fiveHour=$short;scoped=$c.scoped;profile=$profileId;confidence=$(if($c.weekly -or $c.fiveHour){'user estimate'}elseif($profile){$profile.confidence}else{'capacity setup needed'})}
}
function New-Hotpl8CapacityWindow([string]$Name,$Remaining,$Full,$Reset,[datetimeoffset]$Now,[bool]$Confirmed=$true) {
    $at=$null
    try{if($Reset){$at=[datetimeoffset]::Parse([string]$Reset)}}catch{}
    $valid=(Test-Hotpl8Number $Remaining) -and $Remaining -ge 0 -and $Remaining -le 100 -and ($null -eq $at -or $at -gt $Now)
    return [pscustomobject]@{name=$Name;remaining=$Remaining;full=$Full;valid=$valid;resetAt=$(if($Confirmed -and $at){$at.ToString('o')}else{$null})}
}
function Get-Hotpl8CapacityAccounts($Snapshot,$Part,[string]$Provider,[datetimeoffset]$Now,[string]$Meter='codex',[switch]$QuotaHeadroom) {
    $ids=if($Provider -eq 'claude'){@($Part.prefer)}else{@($Part.slots|ForEach-Object id)}
    $ids=@($ids|Where-Object {$null -ne $_ -and $_ -notin @($Part.disabled)}|Select-Object -Unique)
    $seen=@{}
    foreach($id in $ids){
        $slot=@(if($Provider -eq 'claude'){$Snapshot.slots|Where-Object slot -EQ $id}else{$Snapshot.providers.codex.slots|Where-Object id -EQ $id})
        $s=if($slot.Count -eq 1){$slot[0]}else{$null}
        if($s.streamKey -and $s.status -in @('ok','duplicate_subscription')){if($seen.ContainsKey($s.streamKey)){continue};$seen[$s.streamKey]=$true}
        $c=Get-Hotpl8AccountCapacity $Part ([string]$id) $Provider $Meter $s.plan $Now
        $fresh=$s -and $s.status -eq 'ok' -and (Test-Hotpl8FreshTimestamp $s.observedAt $Now)
        $windows=@();$blocked=$false;$reason='';$blockReason=$null
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
            if($blocked -and $b.blockReason){$blockReason=[string]$b.blockReason}
            foreach($entry in $b.windows.PSObject.Properties){
                $w=$entry.Value;$reset=$null
                try{if($w.resetsAt){$reset=[datetimeoffset]::FromUnixTimeSeconds([long]$w.resetsAt).ToString('o')}}catch{}
                $full=if($entry.Name -eq '10080'){$c.weekly}else{$c.fiveHour}
                # A single weekly-only subscription needs no cross-account conversion.
                if($ids.Count -eq 1 -and $entry.Name -eq '10080' -and @($b.windows.PSObject.Properties).Count -eq 1 -and $null -eq $full){$full=1;$c.weekly=1;$c.confidence='single-account normalization'}
                $windows+=New-Hotpl8CapacityWindow $entry.Name $w.remainingPercent $full $reset $Now ($w.anchorState -eq 'observed-active')
            }
        }
        $basis='calibrated'
        if($QuotaHeadroom){
            # Normalize against a FULL currently usable window, not a full week.
            # Weekly/session percentages have different denominators. Weekly
            # limits cap units only when calibrated; otherwise they remain hard
            # eligibility gates and are explicitly reported as unconverted.
            $profile=if($c.profile){(Get-Hotpl8CapacityCatalog).profiles.([string]$c.profile)}else{$null}
            $primary=@($windows|Where-Object name -EQ '300'|Select-Object -First 1)
            if(-not $primary.Count){$primary=@($windows|Where-Object name -EQ '10080'|Select-Object -First 1)}
            $calibrated=$primary.Count -eq 1 -and $null -ne $primary[0].full
            $primaryFull=if($calibrated){$primary[0].full}else{$null}
            $hasProfile=$profile -and $profile.provider -eq $Provider -and ($Provider -ne 'codex' -or $profile.meter -eq $Meter)
            $weight=if($hasProfile){$profile.sessionMultiplier}elseif($calibrated){$primaryFull}elseif($ids.Count -eq 1){1}else{$null}
            $basis=if($hasProfile -or -not $calibrated){'plan'}else{'calibrated'}
            foreach($window in $windows){
                if($window -eq $primary[0]){$window.full=$weight}
                elseif(-not $calibrated){$window.full=$null}
                elseif($null -ne $window.full){$window.full=$window.full/$primaryFull*$weight}
            }
            $c.weekly=$weight
            $c.confidence=if(@($windows|Where-Object {$null -eq $_.full}).Count){'weekly/model conversion unavailable'}else{'calibrated current-window estimate'}
        }
        $known=$fresh -and $windows.Count -gt 0 -and @($windows|Where-Object {-not $_.valid}).Count -eq 0
        $scaled=$known -and $null -ne $c.weekly -and ($QuotaHeadroom -or @($windows|Where-Object {$null -eq $_.full}).Count -eq 0)
        $gross=$null;$percent=$null
        if($known){$percent=($windows|Measure-Object remaining -Minimum).Minimum}
        if($scaled){$gross=($windows|Where-Object {$null -ne $_.full}|ForEach-Object {$_.full*$_.remaining/100}|Measure-Object -Minimum).Minimum}
        $knownZero=$known -and $blocked -and $reason -eq 'blocked' -and $percent -eq 0
        # Only a collector-recorded quota exhaustion whose empty windows all carry a
        # confirmed reset is expected to refill; any other block survives a reset.
        $refillExpected=$knownZero -and $blockReason -eq 'quota_exhausted' -and @($windows|Where-Object {$_.remaining -le 0 -and -not $_.resetAt}).Count -eq 0
        [pscustomobject]@{slot=[string]$id;profile=$c.profile;fresh=[bool]$known;scaled=[bool]$scaled;knownZero=[bool]$knownZero;refillExpected=[bool]$refillExpected;weekly=$c.weekly;weightBasis=$basis;unconvertedConstraints=@($windows|Where-Object {$null -eq $_.full}|ForEach-Object name);windows=$windows;gross=$gross;bindingRemaining=$percent;blocked=$blocked;reason=$reason;blockReason=$blockReason;reserve=($id -in @($Part.reserve));confidence=$c.confidence}
    }
}
function Get-Hotpl8CapacityAmount($Account,$Part,[datetimeoffset]$At,[bool]$Project,[bool]$Emergency=$false,[bool]$AssumeRefill=$false) {
    # A blocked account yields nothing now; a projection may look past a quota
    # block, and its empty windows still cap the amount until they have reset.
    if(-not $Account.scaled -or ($Account.blocked -and -not ($Project -and $AssumeRefill))){return $null}
    $units=[double]::MaxValue
    foreach($w in $Account.windows){
        $left=[double]$w.remaining
        if($Project -and $w.resetAt -and [datetimeoffset]::Parse($w.resetAt) -le $At){$left=100}
        $margin=if($w.name -eq '300'){[double]$Part.margin5h}elseif($Account.reserve){[double]$Part.margin7d}elseif($null -ne $Part.margin7dWork){[double]$Part.margin7dWork}else{[double]$Part.margin7d}
        if($Emergency -and -not $Account.reserve){$margin=if($Part.critical.drainToZero){0}else{Get-Hotpl8CriticalSetting $Part 'floorPercent' 1}}
        if($left -le 0 -or $left -lt $margin){return 0.0}
        if($null -ne $w.full){$units=[math]::Min($units,$w.full*$left/100)}
    }
    return [math]::Min([double]$Account.weekly,[double]$units)
}
function Get-Hotpl8ProviderCapacity($Snapshot,$Part,[string]$Provider,[datetimeoffset]$Now,[string]$Meter='codex',[switch]$QuotaHeadroom) {
    $accounts=@(Get-Hotpl8CapacityAccounts $Snapshot $Part $Provider $Now $Meter -QuotaHeadroom:$QuotaHeadroom)
    $denominatorKnown=$accounts.Count -gt 0 -and @($accounts|Where-Object {$null -eq $_.weekly}).Count -eq 0 -and @($accounts|ForEach-Object weightBasis|Select-Object -Unique).Count -le 1
    $total=if($denominatorKnown){($accounts|Measure-Object weekly -Sum).Sum}else{$null}
    $complete=$denominatorKnown -and @($accounts|Where-Object {-not $_.scaled -or ($_.blocked -and -not $_.knownZero)}).Count -eq 0
    # A measured zero is known now, but a generic native block may survive reset.
    # Only a recorded quota exhaustion with a confirmed reset is projected to refill.
    $projectionComplete=$complete -and @($accounts|Where-Object {$_.blocked -and -not $_.refillExpected}).Count -eq 0
    $hold=if($Provider -eq 'claude'){$Snapshot.hold}else{$Snapshot.providers.codex.hold}
    $selected=if($Provider -eq 'claude'){[string]$Snapshot.active}else{[string]$Snapshot.providers.codex.recommendedSlot}
    if($hold){try{if([datetimeoffset]::Parse($hold.until) -le $Now){$hold=$null}}catch{}}
    $pause=$Snapshot.automationPause
    if($pause){try{if([datetimeoffset]::Parse($pause.until) -le $Now){$pause=$null}}catch{}}
    $restricted=$hold -or $pause -or ($Provider -eq 'claude' -and ($Part.mode -eq 'monitor' -or $Part.switchEnabled -eq $false))
    $critical=Get-Hotpl8CriticalDecision $accounts $Part $selected $(if($Provider -eq 'claude'){$Snapshot.critical}else{$Snapshot.providers.codex.critical.$Meter}) $Now
    $resets=@($accounts|Where-Object {$_.fresh -and (-not $_.blocked -or $_.knownZero)}|ForEach-Object {$_.windows}|Where-Object {$_.resetAt -and [datetimeoffset]::Parse($_.resetAt) -gt $Now}|Sort-Object {[datetimeoffset]::Parse($_.resetAt)})
    $next=$null
    $solid=0.0;$future=0.0;$unknown=0.0
    foreach($a in $accounts){
        if($a.scaled -and $a.knownZero){continue}
        if(-not $a.scaled -or $a.blocked){if($a.weekly){$unknown+=$a.weekly};continue}
        if($restricted -and $a.slot -ne $selected){continue}
        $solid+=Get-Hotpl8CapacityAmount $a $Part $Now $false $critical.active
    }
    # Show the earliest useful refill in the next 24h, not a zero-gain reset
    # that masks a later recovery. Each candidate applies all prior resets.
    # Beyond 24h the first useful refill is reported as text only, up to 8 days.
    $later=$null;$laterFuture=0.0
    if($complete){
        foreach($reset in $resets){
            $at=[datetimeoffset]::Parse($reset.resetAt)
            if($at -gt $Now.AddDays(8)){break}
            $candidate=0.0
            foreach($a in $accounts){
                if(($a.blocked -and -not $a.refillExpected) -or ($restricted -and $a.slot -ne $selected)){continue}
                $candidate+=Get-Hotpl8CapacityAmount $a $Part $at $true $critical.active $a.refillExpected
            }
            if($candidate -le $solid+0.0000001){continue}
            if($at -le $Now.AddHours(24)){$next=$at;$future=$candidate}else{$later=$at;$laterFuture=$candidate}
            break
        }
    }
    $gain=if($next){[math]::Max(0.0,$future-$solid)}else{$null}
    $laterGain=if($later){[math]::Max(0.0,$laterFuture-$solid)}else{$null}
    [pscustomobject]@{metric=$(if($QuotaHeadroom){'plan-weighted-quota-headroom'}else{'weighted-weekly-capacity'});unit=$(if($QuotaHeadroom){'relative session headroom'}else{'relative weekly allowance'});totalUnits=$total;complete=[bool]$complete;accounts=$accounts;measured=@($accounts|Where-Object scaled).Count;usableNowPercent=$(if($complete){[math]::Min(100.0,100*$solid/$total)}else{$null});knownUsablePercent=$(if($total){[math]::Min(100.0,100*$solid/$total)}else{0});unknownPercent=$(if($total){100*$unknown/$total}else{100});nextResetAt=$(if($next){$next.ToString('o')}else{$null});projectionHorizonHours=24;projectionComplete=[bool]$projectionComplete;projectedGainPercent=$(if($complete -and $next){[math]::Min(100-100*$solid/$total,100*$gain/$total)}else{$null});laterRefillAt=$(if($later){$later.ToString('o')}else{$null});laterRefillGainPercent=$(if($complete -and $later){[math]::Min(100-100*$solid/$total,100*$laterGain/$total)}else{$null});projectionAssumption='First positive gain within 24h, else the first within 8 days as text; no further consumption; blocked accounts stay blocked unless the block is a quota exhaustion with a confirmed reset; other limits and policy still apply';critical=$critical;restricted=[bool]$restricted;confidence=$(if($QuotaHeadroom){'quota headroom estimate; not a token budget'}elseif($complete){'estimate'}else{'capacity setup or fresh reading needed'})}
}
