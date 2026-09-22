# Cached, normalized weekly inventory. This is not a token or work-hour budget.
. (Join-Path $PSScriptRoot 'config.ps1')
. (Join-Path $PSScriptRoot 'providers/claude.ps1')
. (Join-Path $PSScriptRoot 'providers/codex.ps1')
function Test-Hotpl8FutureReset($Reset,[datetimeoffset]$Now,[switch]$Unix) {
    try {
        if($null -eq $Reset -or [string]$Reset -eq ''){return $false}
        $at=if($Unix){[datetimeoffset]::FromUnixTimeSeconds([long]$Reset)}else{[datetimeoffset]::Parse([string]$Reset)}
        return $at -gt $Now
    }catch{return $false}
}
function Test-Hotpl8OverviewPercent($Value) {
    return ((Test-Hotpl8Number $Value) -and $Value -ge 0 -and $Value -le 100)
}
function Get-Hotpl8NativeOverview($Snapshot,$Policy,[datetimeoffset]$Now=[datetimeoffset]::UtcNow,[string]$Family) {
    $result=[ordered]@{}
    foreach($provider in @($Family)){
        $part=if($provider -eq 'claude'){$Policy}else{$Policy.codex}
        $configured=if($provider -eq 'claude'){@($Policy.prefer|Where-Object {$null -ne $_})}else{@($part.slots|Where-Object {$_}|ForEach-Object {$_.id})}
        $ids=@($configured|Where-Object {$_ -notin @($part.disabled)}|Select-Object -Unique)
        $observations=if($provider -eq 'claude'){@($Snapshot.slots)}else{@($Snapshot.providers.codex.slots)}
        # The unified Codex graph is always the main allowance, never Spark.
        $meter=if($provider -eq 'claude'){'overall weekly'}else{'codex'}
        $members=@();$identities=@{};$claudeAccounts=@{};$codexAccounts=@();$duplicates=0
        foreach($id in $ids){
            $matches=@($observations|Where-Object {if($provider -eq 'claude'){$_.slot -eq $id}else{$_.id -eq $id}})
            $s=if($matches.Count -eq 1){$matches[0]}else{$null}
            # Only deduplicate when the snapshot actually supplies identity evidence.
            # Failed legacy reads can share an empty-identity hash; never collapse those.
            $identity=if($s.streamKey -and $s.status -in @('ok','duplicate_subscription')){[string]$s.streamKey}else{$null}
            if($identity -and $identities.ContainsKey($identity)){$duplicates++;continue}
            if($identity){$identities[$identity]=$true}
            $fresh=($s -and $s.status -eq 'ok' -and (Test-Hotpl8FreshTimestamp $s.observedAt $Now))
            $remaining=$null;$reason='no_observation';$eligible=$false;$weeklyReset=$null
            if($s){$reason=if(-not $fresh){if($s.status -ne 'ok'){[string]$s.status}else{'stale'}}else{'weekly_unmeasured'}}
            if($provider -eq 'claude'){
                $fresh=$fresh -and $s.fresh
                # An elapsed reset we were told about before it happened is a
                # refill, not a broken reading. A cold window reaches the same
                # state by the other route and keeps its own exemption.
                $w7=Resolve-Hotpl8Window $s.used7d $s.reset7d $s.observedAt $Now
                $w5=Resolve-Hotpl8Window $s.used5h $s.reset5h $s.observedAt $Now
                $weekly=$fresh -and (Test-Hotpl8OverviewPercent $w7.used) -and ($w7.rolledOver -or (Test-Hotpl8FutureReset $w7.resetAt $Now))
                if($weekly){$remaining=100-[double]$w7.used;$weeklyReset=$(if($w7.resetAt){[datetimeoffset]::Parse($w7.resetAt).ToString('o')}else{$null})}
                $short=$fresh -and (Test-Hotpl8OverviewPercent $w5.used) -and ($w5.rolledOver -or (Test-Hotpl8FutureReset $w5.resetAt $Now) -or ($s.cold -and $s.used5h -eq 0 -and -not $s.reset5h))
                $modelBlock=Get-ClaudeModelBlock $s.scoped $Policy ([int]$id) $Now $s.observedAt
                $e=@{h5=$(if($short){100-[double]$w5.used}else{$null});h7=$remaining;fresh=[bool]($short -and $weekly);modelBlocked=[bool]$modelBlock;obj=@{usage=@{fiveHour=@{resetsAt=$w5.resetAt};sevenDay=@{resetsAt=$w7.resetAt}}}}
                $e.observation=ConvertTo-Hotpl8ClaudeObservation $s $Policy $Now
                $claudeAccounts[[int]$id]=$e
                $eligible=(Test-Ok $e ([double]$Policy.margin5h) (Get-Margin7dFor $Policy $id)) -and $e.h5 -gt 0 -and $remaining -gt 0
                if($fresh){$reason=if($modelBlock){$modelBlock}elseif($eligible){'eligible'}elseif(-not $weekly -or -not $short){'window_unmeasured'}else{'below_margin'}}elseif($s -and $s.status -eq 'ok'){$reason='stale'}
            }else{
                $b=$s.buckets.$meter;$w=$b.windows.'10080'
                $rolledWeekly=Resolve-Hotpl8Window $w.usedPercent $w.resetsAt $w.observedAt $Now -Unix
                if($fresh -and ($b.status -eq 'observed' -or ($b.status -eq 'blocked' -and $w.usedPercent -eq 100)) -and (Test-Hotpl8OverviewPercent $rolledWeekly.used) -and ($rolledWeekly.rolledOver -or (Test-Hotpl8FutureReset $rolledWeekly.resetAt $Now -Unix))){
                    $remaining=100-[double]$rolledWeekly.used
                    if($w.anchorState -eq 'observed-active' -and $null -ne $rolledWeekly.resetAt){$weeklyReset=[datetimeoffset]::FromUnixTimeSeconds([long]$rolledWeekly.resetAt).ToString('o')}
                }
                if($s){$reason=Get-CodexEligibility $s $part $meter $Now;$eligible=$reason -eq 'eligible';$codexAccounts+=@($s)}
            }
            $members+=@([pscustomobject]@{slot=[string]$id;remainingPercent=$remaining;weeklyResetAt=$weeklyReset;eligible=[bool]$eligible;reason=$reason;reserve=($id -in @($part.reserve))})
        }
        $measured=@($members|Where-Object {$null -ne $_.remainingPercent}).Count
        $sum=0.0;foreach($m in $members){if($null -ne $m.remainingPercent){$sum+=$m.remainingPercent}}
        $total=$members.Count;$known=if($total){$sum/$total}else{0.0};$unknown=if($total){100.0*($total-$measured)/$total}else{100.0}
        $ready=@($members|Where-Object eligible).Count -gt 0
        $availability=if(-not $total){'No accounts enabled'}elseif($ready){if($provider -eq 'codex'){'Ready for next launch'}else{'Ready'}}else{'Unavailable now - see details'}
        $automation='';$selected=$null
        if($provider -eq 'claude'){
            $actions=Get-Hotpl8Actions $Policy $false
            $paused=$Snapshot.automationPause -and ($Snapshot.automationPause.invalid -or (Test-Hotpl8FutureReset $Snapshot.automationPause.until $Now))
            $held=$Snapshot.hold -and (Test-Hotpl8FutureReset $Snapshot.hold.until $Now)
            $automation=if($paused){'automation paused'}elseif($held){'rotation held'}elseif($actions.switching){'automatic selection on'}else{'manual selection'}
            if($Policy.mode -eq 'monitor' -and -not $paused){$automation='monitor only'}
            if($total){
                $selection=Get-ClaudeSelection $Policy @($members|ForEach-Object {[int]$_.slot}) $claudeAccounts ([int]$Snapshot.active) $Now $Snapshot.critical
                $selected=if($held -or $paused -or -not $actions.switching){if($selection.activeOk){$Snapshot.active}else{$null}}elseif($null -ne $selection.target){$selection.target}elseif($selection.activeOk){$Snapshot.active}else{$null}
                if($ready -and -not $selected){$availability='Account available - manual selection needed'}
            }
        }else{
            $hold=$Snapshot.providers.codex.hold
            if($hold -and -not (Test-Hotpl8FutureReset $hold.until $Now)){$hold=$null}
            if($total){$selected=Select-CodexSlot $codexAccounts $part $meter $Snapshot.providers.codex.recommendedSlot $hold $Now $Snapshot.providers.codex.critical.$meter}
            if($ready -and -not $selected){$availability='Account available - selection held'}
            $automation='native launches; managed sessions need adoption evidence'
        }
        $health=Get-Hotpl8Health $Snapshot.collector $Now $provider
        if($total -and @($members|Where-Object reason -EQ 'stale').Count -eq $total){$availability='Readings stale - refresh'}
        $signIn=@($members|Where-Object {$_.reason -in @('authentication_required','relogin_required','no_credentials')}).Count
        if($signIn){$availability+='; sign-in needed'}
        if($health -notin @('manual / no collector evidence','recent collection completed','collecting')){$availability+='; '+$health}
        $capacity=Get-Hotpl8ProviderCapacity $Snapshot $part $provider $Now $meter
        $immediate=Get-Hotpl8ProviderCapacity $Snapshot $part $provider $Now $meter -QuotaHeadroom
        if($capacity.critical.active){foreach($member in $members){if($member.slot -in $capacity.critical.ranked){$member.eligible=$true;$member.reason='critical_allowance'}}}
        if($capacity.critical.active -and $selected){$availability=if($provider -eq 'codex'){'Ready for next launch / critical'}else{'Ready / critical'}}
        $result[$provider]=[pscustomobject]@{schemaVersion=2;capacity=$capacity;immediate=$immediate;computedAt=$Now.ToString('o');metric='normalized-weekly-headroom';scope=$meter;accounts=$total;measured=$measured;disabled=($configured.Count-$ids.Count);duplicates=$duplicates;knownRemainingPercent=$known;unknownPercent=$unknown;remainingPercent=$(if($total -and $measured -eq $total){$known}else{$null});includesReserve=(@($members|Where-Object reserve).Count -gt 0);availability=$availability;automation=$automation;collectionHealth=$health;selected=$selected;members=$members}
    }
    return [pscustomobject]$result
}
function Get-Hotpl8ProviderOverview($Snapshot,$Policy,[datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
    if(-not $Policy){$Policy=[pscustomobject]@{}}
    $result=[ordered]@{}
    foreach($r in @(Get-Hotpl8ConfiguredProviders $Policy -IncludeUnconfigured)){
        $view=Get-Hotpl8ProviderView $Snapshot $Policy $r.id
        $native=Get-Hotpl8NativeOverview $view.snapshot $view.policy $Now $view.provider
        $value=$native.($view.provider)
        $value|Add-Member NoteProperty name $r.name -Force
        $value|Add-Member NoteProperty driver $r.driver -Force
        $result[$r.id]=$value
    }
    return [pscustomobject]$result
}
function Get-Hotpl8CodexAccountState($Slot,$Part,$Provider,[datetimeoffset]$Now) {
    if(-not $Slot){return 'NO OBSERVATION'}
    if($Slot.id -in @($Part.disabled) -or $Slot.status -eq 'disabled'){return 'DISABLED'}
    if($Slot.status -ne 'ok'){return ([string]$Slot.status).Replace('_',' ').ToUpperInvariant()}
    if(-not (Test-Hotpl8FreshTimestamp $Slot.observedAt $Now)){return 'STALE'}
    $bucket=$Slot.buckets.codex
    if(@($bucket.windows.PSObject.Properties|Where-Object {(Test-Hotpl8Number $_.Value.remainingPercent) -and $_.Value.remainingPercent -eq 0}).Count){return 'EXHAUSTED'}
    $eligibility=Get-CodexEligibility $Slot $Part 'codex' $Now ([bool]$Provider.critical.codex.active)
    if($eligibility -eq 'eligible'){
        $next=if($Provider.recommendations.codex){$Provider.recommendations.codex}elseif($Provider.defaultMeter -eq 'codex'){$Provider.recommendedSlot}else{$null}
        if($Slot.id -eq $next){return 'NEXT LAUNCH'}
        return 'AVAILABLE'
    }
    switch($eligibility){
        'below_margin'{return 'LOW BALANCE'}
        'blocked'{return 'BLOCKED'}
        default{return 'LIMIT UNCONFIRMED'}
    }
}
function Get-Hotpl8CapacityDisplay($ProviderOverview) {
    $p=$ProviderOverview;$c=if($p.immediate){$p.immediate}else{$p.capacity}
    $state=if($c.complete){'{0:0.#}% available now' -f $c.usableNowPercent}elseif($null -eq $c.totalUnits){'Plan allowance unknown; total unavailable'}else{'Partial: '+$c.measured+'/'+$p.accounts+' measured; total unavailable'}
    if($c.metric -eq 'plan-weighted-quota-headroom' -and $c.complete){$state+=' (estimate)'}
    $weeklyUncertain=@($c.accounts|Where-Object {($_.unconvertedConstraints -contains '10080') -and @($_.windows|Where-Object {$_.name -eq '10080' -and $_.remaining -gt 0 -and $_.remaining -le 20}).Count}).Count
    if($weeklyUncertain -and $c.complete){$state=$state.Replace('(estimate)','(weekly cap uncertain)')}
    if($null -ne $p.remainingPercent){$state+=' / '+('{0:0.#}% weekly left' -f $p.remainingPercent)}
    if($p.accounts -eq 0){$state='No accounts enabled'}
    $stale=@($p.members|Where-Object reason -EQ 'stale').Count
    if($stale){$state+=' / '+$stale+' expired; awaiting update'}
    [pscustomobject]@{
        title='Available now'
        value=$c.knownUsablePercent
        unknown=$c.unknownPercent
        gain=$c.projectedGainPercent
        nextResetAt=$c.nextResetAt
        capacity=$c
        state=$state
        weekly=$false
    }
}
function Format-Hotpl8Overview($Overview) {
    foreach($provider in @($Overview.PSObject.Properties|ForEach-Object Name)){
        $p=$Overview.$provider
        $display=Get-Hotpl8CapacityDisplay $p
        $(if($p.name){$p.name.ToUpper()}else{$provider.ToUpper()})+': '+$display.state+'; '+$p.availability+'; '+$p.automation
        if($p.capacity){
            $c=$p.capacity
            $display=Get-Hotpl8CapacityDisplay $p
            '  Capacity: '+$display.state+'; '+$c.critical.reason
            '  Membership: '+$p.accounts+' enabled; '+$p.disabled+' disabled; '+$p.duplicates+' duplicate entries excluded.'
            if($null -ne $display.gain){'  Next reset: +{0:0.#}% {1} at {2}; assumes no further consumption.' -f $display.gain,$(if($display.weekly){'weekly'}else{'available'}),$display.nextResetAt}
        }
        if($p.includesReserve){'  Includes reserve allowance.'}
        if($p.driver -eq 'claude-cswap' -and $p.capacity){
            $profiles=@($p.capacity.accounts|Where-Object profile|ForEach-Object {$_.slot+'='+$_.profile})
            if($profiles.Count){'  Profiles: '+($profiles -join ', ')}
        }
    }
    'Weekly headroom is an equal-account average, not a token budget; tiers may differ. Short/model limits determine readiness.'
}
