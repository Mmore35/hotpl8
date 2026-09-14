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
function Get-Hotpl8ProviderOverview($Snapshot,$Policy,[datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
    $result=[ordered]@{}
    foreach($provider in @('claude','codex')){
        $part=if($provider -eq 'claude'){$Policy}else{$Policy.codex}
        $configured=if($provider -eq 'claude'){@($Policy.prefer|Where-Object {$null -ne $_})}else{@($part.slots|Where-Object {$_}|ForEach-Object {$_.id})}
        $ids=@($configured|Where-Object {$_ -notin @($part.disabled)}|Select-Object -Unique)
        $observations=if($provider -eq 'claude'){@($Snapshot.slots)}else{@($Snapshot.providers.codex.slots)}
        $meter=if($provider -eq 'claude'){'overall weekly'}elseif($part.defaultMeter){[string]$part.defaultMeter}else{'codex'}
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
            $remaining=$null;$reason='no_observation';$eligible=$false
            if($s){$reason=if(-not $fresh){if($s.status -ne 'ok'){[string]$s.status}else{'stale'}}else{'weekly_unmeasured'}}
            if($provider -eq 'claude'){
                $fresh=$fresh -and $s.fresh
                $weekly=$fresh -and (Test-Hotpl8OverviewPercent $s.used7d) -and (Test-Hotpl8FutureReset $s.reset7d $Now)
                if($weekly){$remaining=100-[double]$s.used7d}
                $short=$fresh -and (Test-Hotpl8OverviewPercent $s.used5h) -and ((Test-Hotpl8FutureReset $s.reset5h $Now) -or ($s.cold -and $s.used5h -eq 0 -and -not $s.reset5h))
                $modelBlock=Get-ClaudeModelBlock $s.scoped $Policy ([int]$id) $Now
                $e=@{h5=$(if($short){100-[double]$s.used5h}else{$null});h7=$remaining;fresh=[bool]($short -and $weekly);modelBlocked=[bool]$modelBlock;obj=@{usage=@{fiveHour=@{resetsAt=$s.reset5h};sevenDay=@{resetsAt=$s.reset7d}}}}
                $claudeAccounts[[int]$id]=$e
                $eligible=(Test-Ok $e ([double]$Policy.margin5h) (Get-Margin7dFor $Policy $id)) -and $e.h5 -gt 0 -and $remaining -gt 0
                if($fresh){$reason=if($modelBlock){$modelBlock}elseif($eligible){'eligible'}elseif(-not $weekly -or -not $short){'window_unmeasured'}else{'below_margin'}}
            }else{
                $b=$s.buckets.$meter;$w=$b.windows.'10080'
                if($fresh -and ($b.status -eq 'observed' -or ($b.status -eq 'blocked' -and $w.usedPercent -eq 100)) -and (Test-Hotpl8OverviewPercent $w.usedPercent) -and (Test-Hotpl8FutureReset $w.resetsAt $Now -Unix)){$remaining=100-[double]$w.usedPercent}
                if($s){$reason=Get-CodexEligibility $s $part $meter $Now;$eligible=$reason -eq 'eligible';$codexAccounts+=@($s)}
            }
            $members+=@([pscustomobject]@{slot=[string]$id;remainingPercent=$remaining;eligible=[bool]$eligible;reason=$reason;reserve=($id -in @($part.reserve))})
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
            $automation='existing sessions keep their account'
        }
        $health=Get-Hotpl8Health $Snapshot.collector $Now
        if($total -and @($members|Where-Object reason -EQ 'stale').Count -eq $total){$availability='Readings stale - refresh'}
        $signIn=@($members|Where-Object {$_.reason -in @('authentication_required','relogin_required','no_credentials')}).Count
        if($signIn){$availability+='; sign-in needed'}
        if($health -notin @('manual / no collector evidence','recent collection completed','collecting')){$availability+='; '+$health}
        $capacity=Get-Hotpl8ProviderCapacity $Snapshot $part $provider $Now $meter
        if($capacity.critical.active){foreach($member in $members){if($member.slot -in $capacity.critical.ranked){$member.eligible=$true;$member.reason='critical_allowance'}}}
        if($capacity.critical.active -and $selected){$availability=if($provider -eq 'codex'){'Ready for next launch / critical'}else{'Ready / critical'}}
        $result[$provider]=[pscustomobject]@{schemaVersion=2;capacity=$capacity;computedAt=$Now.ToString('o');metric='normalized-weekly-headroom';scope=$meter;accounts=$total;measured=$measured;disabled=($configured.Count-$ids.Count);duplicates=$duplicates;knownRemainingPercent=$known;unknownPercent=$unknown;remainingPercent=$(if($total -and $measured -eq $total){$known}else{$null});includesReserve=(@($members|Where-Object reserve).Count -gt 0);availability=$availability;automation=$automation;collectionHealth=$health;selected=$selected;members=$members}
    }
    return [pscustomobject]$result
}
function Get-Hotpl8CapacityDisplay($ProviderOverview) {
    $p=$ProviderOverview;$c=$p.capacity
    # Missing conversion data must not hide valid native quota readings, or turn
    # their equal-account average into a claim about immediately usable compute.
    $weekly=-not $c.complete -and ($null -eq $c.totalUnits -or $c.measured -eq 0) -and $p.measured -gt 0
    $ready=@($p.members|Where-Object eligible).Count
    $state=if($weekly){
        $(if($null -ne $p.remainingPercent){'{0:0.#}% weekly' -f $p.remainingPercent}else{[string]$p.measured+'/'+$p.accounts+' weekly readings'})+' / '+$ready+'/'+$p.accounts+' ready; capacity setup needed'
    }elseif($c.complete){'{0:0.#}% now' -f $c.usableNowPercent}else{'Usable capacity unmeasured; check setup/readings'}
    [pscustomobject]@{
        title=$(if($weekly){'Weekly headroom (unweighted)'}else{'Available capacity (estimate)'})
        value=$(if($weekly){$p.knownRemainingPercent}else{$c.knownUsablePercent})
        unknown=$(if($weekly){$p.unknownPercent}else{$c.unknownPercent})
        gain=$(if(-not $weekly){$c.projectedGainPercent}else{$null})
        state=$state
        weekly=[bool]$weekly
    }
}
function Format-Hotpl8Overview($Overview) {
    foreach($provider in @('claude','codex')){
        $p=$Overview.$provider
        $amount=if($null -ne $p.remainingPercent){'{0:0}% estimate' -f $p.remainingPercent}else{'partial / unknown'}
        $provider.ToUpper()+': weekly headroom '+$amount+'; '+$p.measured+'/'+$p.accounts+' measured; '+$p.availability+'; '+$p.automation
        if($p.capacity){
            $c=$p.capacity
            $display=Get-Hotpl8CapacityDisplay $p
            '  Capacity: '+$display.state+'; '+$c.critical.reason
            '  Membership: '+$p.accounts+' enabled; '+$p.disabled+' disabled; '+$p.duplicates+' duplicate entries excluded.'
            if($null -ne $c.projectedGainPercent){'  Next reset: +{0:0.#}% at {1}; assumes no further consumption.' -f $c.projectedGainPercent,$c.nextResetAt}
        }
        if($p.includesReserve){'  Includes reserve allowance.'}
    }
    'Weekly headroom is an equal-account average, not a token budget; tiers may differ. Short/model limits determine readiness.'
}
