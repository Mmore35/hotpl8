. (Join-Path $PSScriptRoot 'provider-contract.ps1')
. (Join-Path $PSScriptRoot 'selection.ps1')
# No native calls, state writes or provider-name policy branches. Context belongs
# to one binding scope; callers must not pass another process's dwell history.
function Get-Hotpl8ProviderDecision($Accounts,$Policy,$Context,[datetimeoffset]$Now) {
    $intent=if($Context.intent){[string]$Context.intent}else{'observe'}
    if($intent -notin @('observe','admit','rebind','refresh','control','warm','probe')){throw 'Unknown provider action intent.'}
    $rows=@(foreach($account in @($Accounts)){if($account){ConvertTo-Hotpl8ProviderAccount $account $Policy @($Context.scopes|Where-Object {$_}) $Now}})
    # Every duplicate is excluded; array order cannot decide which identity wins.
    foreach($r in $rows){
        if(@($rows|Where-Object id -CEQ $r.id).Count -gt 1){$r.reason='duplicate_observation';$r.valid=$false}
        elseif($r.identityKey -and @($rows|Where-Object identityKey -CEQ $r.identityKey).Count -gt 1){$r.reason='duplicate_subscription';$r.valid=$false}
    }
    $previous=if($Context.bindingKnown -eq $true){[string]$Context.previousId}else{$null}
    $capacity=@(foreach($r in $rows){[pscustomobject]@{slot=$r.id;reserve=$r.reserve;fresh=$r.valid;blocked=(-not $r.valid);bindingRemaining=$r.bindingRemaining;scaled=$r.scaled;gross=$r.gross}})
    $critical=if($Context.eligibilityOnly -eq $true){[pscustomobject]@{active=$false;selected=$previous;ranked=@();pollSeconds=300;selectedAt=$Context.criticalState.selectedAt;reason='eligibility only'}}else{Get-Hotpl8CriticalDecision $capacity $Policy $previous $Context.criticalState $Now}
    $eligible=@()
    foreach($r in $rows){
        $reason=$r.reason
        if(-not $reason){foreach($w in @($r.windows|Where-Object state -EQ 'observed')){
            if($w.remainingPercent -le 0 -or $w.remainingPercent -lt (Get-Hotpl8ProviderMargin $Policy $r $w ($critical.active -or $Context.emergency -eq $true))){$reason='below_margin';break}
        }}
        $r|Add-Member NoteProperty eligible (-not $reason)
        $r.reason=if($reason){$reason}else{'eligible'}
        $degraded=$null -ne $r.weeklyRemaining -and $r.weeklyRemaining -lt (Get-Hotpl8ProviderSetting $Policy 'margin7d' 20)
        $key=[double]$r.preference
        $order=Get-Hotpl8ProviderSetting $Policy 'order' 'prefer'
        if($order -eq 'soonest-reset'){$key=[double]::MaxValue;if($r.resetAt){$key=[double]([datetimeoffset]::Parse($r.resetAt)).ToUnixTimeSeconds()}}
        elseif($order -in @('weekly-expiry','balanced')){$key=Get-Hotpl8SelectionKey $order $r.shortRemaining $r.weeklyRemaining $r.weeklyResetAt $Now}
        if($degraded){$key=-[double]$r.weeklyRemaining}
        $r|Add-Member NoteProperty degraded $degraded
        $r|Add-Member NoteProperty rankKey $key
        if($r.eligible){$eligible+= $r}
    }
    $ordered=@($eligible|Sort-Object reserve,degraded,rankKey,preference,id)
    $proposed=if($ordered.Count){$ordered[0].id}else{$null}
    $prior=@($eligible|Where-Object id -CEQ $previous)
    if($critical.active -and $critical.ranked.Count){
        $ordered=@(foreach($id in $critical.ranked){$eligible|Where-Object id -CEQ $id})
        $proposed=if(@($ordered|Where-Object id -CEQ $critical.selected).Count){$critical.selected}else{$null}
    }elseif($prior.Count -eq 1 -and $proposed -and $proposed -cne $previous){
        $best=$ordered[0];$old=$prior[0]
        if($best.reserve -eq $old.reserve -and $best.degraded -eq $old.degraded){
            if($best.degraded){if($best.weeklyRemaining -le $old.weeklyRemaining){$proposed=$previous}}
            elseif($order -eq 'soonest-reset'){
                if($best.resetAt -and $old.resetAt -and ([datetimeoffset]::Parse($old.resetAt)-[datetimeoffset]::Parse($best.resetAt)).TotalMinutes -lt (Get-Hotpl8ProviderSetting $Policy 'resetLeadMin' 10)){$proposed=$previous}
            }elseif($null -ne $best.shortRemaining -and $best.shortRemaining -lt ((Get-Hotpl8ProviderSetting $Policy 'margin5h' 25)+(Get-Hotpl8ProviderSetting $Policy 'hysteresis' 10))){$proposed=$previous}
        }
    }
    $target=$proposed;$suppression=$null;$permitted=$true;$manual=$false
    if($intent -eq 'control'){$target=$previous}
    elseif($Context.safetyInvalid -eq $true){$suppression='safety_state_invalid'}
    elseif($intent -eq 'refresh'){
        $target=$previous
        $bound=@($rows|Where-Object id -CEQ $previous)
        if(-not $previous -or $Context.identityKnown -ne $true){$suppression='binding_unknown'}
        elseif($bound.Count -ne 1 -or $bound[0].reason -in @('disabled','binding_changed','duplicate_observation','duplicate_subscription')){$suppression='binding_changed'}
    }else{
        if($intent -in @('warm','probe')){
            # This is permission for an explicitly prepared operation, not a
            # warming/probe planner. The caller supplies operation-specific
            # evidence (cold window, phase, cooldown or recovery eligibility).
            $target=[string]$Context.actionSlot
            $operationAccount=@($rows|Where-Object id -CEQ $target)
            if(-not $target -or $operationAccount.Count -ne 1){$suppression='action_target_unknown'}
            elseif($operationAccount[0].reason -in @('disabled','binding_changed','duplicate_observation','duplicate_subscription')){$suppression='binding_changed'}
            elseif($intent -eq 'warm' -and -not $operationAccount[0].valid){$suppression='action_ineligible'}
            elseif($Context.actionEligible -ne $true){$suppression='action_ineligible'}
        }elseif($intent -eq 'admit' -and $Context.pin){
            $pinned=@($rows|Where-Object id -CEQ ([string]$Context.pin))
            if($pinned.Count -ne 1 -or $pinned[0].reason -in @('disabled','binding_changed','duplicate_observation','duplicate_subscription')){$suppression='binding_changed'}
            else{$target=[string]$Context.pin;$manual=$true}
        }elseif($Context.hold -eq $true -and $intent -notin @('warm','probe')){
            if(-not $previous){$suppression='binding_unknown';$target=$null}
            elseif($prior.Count -eq 1){$target=$previous;if($intent -eq 'rebind'){$suppression='selection_held'}}
            else{$target=$null;$suppression='held_account_unavailable'}
        }
        if($intent -in @('rebind','warm','probe')){
            if($Context.mode -ne 'automate'){$suppression='monitor_only'}
            elseif($Context.paused -eq $true){$suppression='automation_paused'}
            elseif($intent -eq 'rebind' -and $Context.switching -ne $true){$suppression='switching_disabled'}
            elseif($intent -in @('warm','probe') -and $Context.actionEnabled -ne $true){$suppression='action_disabled'}
            elseif($Context.actionBlock){$suppression=[string]$Context.actionBlock}
            if($intent -eq 'rebind' -and -not $previous -and -not $suppression){$suppression='binding_unknown'}
        }
        if(-not $target -and -not $suppression){$suppression='unavailable'}
        if($intent -eq 'observe'){$suppression=if($suppression){$suppression}else{'observe_only'}}
    }
    if($suppression){$permitted=$false}
    [pscustomobject]@{accounts=$rows;ranked=@($ordered|ForEach-Object id);allRanked=@($rows|Sort-Object reserve,degraded,rankKey,preference,id|ForEach-Object id);proposedSlot=$proposed;targetSlot=$target;actionPermitted=$permitted;suppressionReason=$suppression;manual=$manual;requiresNativeValidation=($permitted -and $intent -ne 'control');critical=$critical}
}
