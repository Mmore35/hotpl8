# Private broker: its token-bearing result belongs only in the bridge pipe.
. (Join-Path $PSScriptRoot 'provider-actions.ps1')
. (Join-Path $PSScriptRoot 'provider-observation.ps1')
. (Join-Path $PSScriptRoot 'provider-registry.ps1')
function Get-Hotpl8CodexRoutingDecision($Rows,$Part,$Policy,$Meters,$Request,[string]$Directory,[datetimeoffset]$Now) {
    $accounts=@(foreach($row in @($Rows)){
        $account=$null;$windows=@()
        foreach($meter in $Meters){
            $decoded=ConvertTo-Hotpl8CodexObservation $row $meter
            if(-not $account){$account=$decoded}
            $windows+=@($decoded.windows)
            if($decoded.blockedReason){$account|Add-Member NoteProperty blockedReason $decoded.blockedReason -Force}
        }
        if($account){$account|Add-Member NoteProperty windows $windows -Force;$account}
    })
    if(@($Meters).Count -eq 1){
        $capacity=@(Get-Hotpl8CapacityAccounts ([pscustomobject]@{providers=@{codex=@{slots=$Rows}}}) $Part 'codex' $Now $Meters[0])
        $accounts=@(Add-Hotpl8ObservationCapacity $accounts $capacity)
    }
    # Critical dwell belongs to this native process, never the collector.
    $intent=if($Request.operation -eq 'refresh'){'refresh'}elseif($Request.intent){[string]$Request.intent}else{'admit'}
    $context=[pscustomobject]@{intent=$intent;previousId=[string]$Request.previousSlot;bindingKnown=[bool]$Request.previousSlot;identityKnown=[bool]$Request.accountId;scopes=@($Meters);criticalState=$Request.criticalState}
    $context=Get-Hotpl8ProviderActionContext $Policy $Directory $context $Now
    Get-Hotpl8ProviderDecision $accounts $Part $context $Now
}
function Get-Hotpl8CodexRoute($Request,[string]$StateDirectory,[string]$Executable,[scriptblock]$Reader) {
    $validationClock=[Diagnostics.Stopwatch]::StartNew()
    $refresh=$Request.operation -eq 'refresh';$background=$Request.intent -eq 'rebind'
    # An admission may wait out one slow reader and then make its own slow read,
    # 12 s each on a saturated machine. Refresh answers native Codex, which does
    # not wait that long.
    $validationBudget=if($refresh){6500}else{30000}
    if($Request.operation -notin @('select','refresh','exec') -or ($Request.intent -and $Request.intent -notin @('admit','rebind')) -or ($Request.operation -ne 'select' -and $Request.intent -eq 'rebind')){throw 'routing_invalid_request'}
    foreach($key in @('OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','CODEX_SQLITE_HOME','OPENAI_BASE_URL')){if([Environment]::GetEnvironmentVariable($key)){throw 'routing_environment_conflict'}}
    try{$admission=Get-Hotpl8ControlSnapshot $StateDirectory}catch{if($_.Exception.Message -eq 'action_state_changed'){throw 'routing_state_changed'};throw}
    $policy=$admission.policy;Assert-Hotpl8Policy $policy
    $registration=Get-Hotpl8ConfiguredProvider $policy 'codex'
    $part=$registration.policy;Assert-CodexPolicy $part
    $state=Read-Hotpl8Json (Join-Path $StateDirectory 'codex-state.json')
    $status=(Read-Hotpl8Json (Join-Path $StateDirectory 'status.json')).providers.codex
    $now=[datetimeoffset]::UtcNow
    $meter=if($part.defaultMeter){[string]$part.defaultMeter}else{'codex'}; $meters=@($meter)
    $identities=@{}
    foreach($slot in @($part.slots)){
        $prior=$state.slots.([string]$slot.id)
        if($prior.identityKey){if($identities.ContainsKey([string]$prior.identityKey)){throw 'routing_duplicate_identity'};$identities[[string]$prior.identityKey]=$true}
    }
    $rows=@(foreach($slot in @($part.slots)){
        $matches=@($status.slots|Where-Object id -EQ $slot.id);$prior=$state.slots.([string]$slot.id)
        if($prior.identityKey -and $prior.binding -eq (Get-Hotpl8Hash ([IO.Path]::GetFullPath([string]$slot.home))) -and $slot.id -notin @($Request.exclude)){
            if($matches.Count -eq 1){
                $row=$matches[0]
                # A failed lock acquisition or one slow collector read says
                # nothing about the account's quota or login. Reconsider its
                # retained observation privately; all freshness/policy gates
                # and fresh native validation below still apply, so a stale or
                # never-read account stays out. Never publish this as health.
                if($row.status -in @('home_busy','timeout')){$row=$row|Select-Object *;$row.status='ok'}
                $row
            }
            elseif($refresh -and $matches.Count -eq 0){[pscustomobject]@{id=$slot.id;status='unknown';observedAt=$null;buckets=$null}}
        }
    })
    if(-not $refresh){
        try{$age=($now-[datetimeoffset]::Parse($status.observedAt)).TotalSeconds}catch{throw 'routing_stale'}
        if($age -lt -5 -or $age -gt (Get-Hotpl8ProviderSetting $part 'maxUsageAgeS' 900)){throw 'routing_stale'}
    }
    # Keep successful reads private to this admission. A candidate that loses
    # rank after fresh quota arrives can still serve if a better peer fails.
    # Each home is validated once, plus one final pass to select a cached fallback.
    # A home whose lock stayed busy has not been validated: it is set aside while
    # its peers are tried, and tried again until the deadline.
    $validated=@{};$busy=@();$locked=@{};$settled=0
    while($settled -le @($part.slots).Count){
        if($validationClock.ElapsedMilliseconds -ge $validationBudget){if($locked.Count){throw 'routing_account_busy'};throw 'routing_validation_timeout'}
        $decision=Get-Hotpl8CodexRoutingDecision $rows $part $policy $meters $Request $StateDirectory ([datetimeoffset]::UtcNow)
        if(-not $decision.actionPermitted){
            # Only a lock stands between this admission and the homes set aside.
            # Decide again with them: a control that suppresses the action still
            # does, and is reported then.
            if($busy.Count){$rows=@($rows)+@($busy);$busy=@();continue}
            if($decision.suppressionReason -in @('monitor_only','automation_paused','switching_disabled','selection_held','binding_unknown')){throw ('routing_'+$decision.suppressionReason)}
            throw 'routing_unavailable'
        }
        $selected=[string]$decision.targetSlot;$slot=@($part.slots|Where-Object id -EQ $selected)
        if($slot.Count -ne 1 -or $selected -in @($part.disabled)){throw 'routing_binding_changed'}
        $slot=$slot[0];$prior=$state.slots.$selected
        if(-not $prior.identityKey -or $prior.binding -ne (Get-Hotpl8Hash ([IO.Path]::GetFullPath([string]$slot.home)))){throw 'routing_binding_changed'}
        $cached=$validated.ContainsKey($selected)
        if($cached){$read=$validated[$selected]}
        else{
          $accountClock=[Diagnostics.Stopwatch]::StartNew();$read=$null
          # Another reader holds this lock for 2-4 s, and up to 12 s on a saturated
          # machine. Wait 6.5 s for it here before a peer is tried. Refresh keeps
          # its shorter wait so native I/O still fits the 6.5 s deadline. A
          # background validation does not wait at all: it would hold the lock
          # next, in front of an admission, and the next wakeup repeats it.
          $lockWaitBudget=if($refresh){2500}elseif($background){0}else{6500}
          do{
            $remaining=$validationBudget-[int]$validationClock.ElapsedMilliseconds
            if($remaining -le 0){if($locked.Count -or $read.status -eq 'home_busy'){throw 'routing_account_busy'};throw 'routing_validation_timeout'}
            # The collector's bound: a tighter one fails every account at once when
            # starting the native program alone takes longer.
            $readBudget=[Math]::Min((Get-CodexReadBudgetMs),$remaining)
            $read=if($Reader){& $Reader $slot $refresh $readBudget}else{Read-CodexQuota $slot.home $Executable $readBudget $Request.cwd -IncludeAccessToken -RefreshToken:$refresh}
            if($read.status -ne 'home_busy'){break}
            if($accountClock.ElapsedMilliseconds -ge $lockWaitBudget){break}
            Start-Sleep -Milliseconds 75
          }while($true)
        }
        if($read.status -eq 'home_busy'){
            if($refresh -or $background){throw 'routing_account_busy'}
            $locked[$selected]=$true
            $busy+=@($rows|Where-Object id -EQ $selected);$rows=@($rows|Where-Object id -NE $selected);continue
        }
        $locked.Remove($selected);$settled++
        $valid=$read.status -eq 'ok' -and $read.identityKey -eq $prior.identityKey -and $read.standardTransport -and (-not $read.modelProvider -or $read.modelProvider -eq 'openai')
        if($refresh){if(-not $valid -or $read.auth.chatgptAccountId -cne $Request.accountId){throw 'routing_refresh_failed'}}
        elseif($valid){
            $readNow=[datetimeoffset]::UtcNow
            if(-not $cached){
                $validated[$selected]=$read
                $oldRow=@($rows|Where-Object id -CEQ $selected)[0]
                $current=[pscustomobject]@{id=$selected;status='ok';observedAt=$readNow.ToString('o');buckets=(ConvertTo-CodexBuckets $read.quota $oldRow.buckets $readNow)}
                $rows=@($rows|Where-Object id -NE $selected)+@($current)
            }
            $decision=Get-Hotpl8CodexRoutingDecision $rows $part $policy $meters $Request $StateDirectory $readNow
            if($decision.actionPermitted -and $decision.targetSlot -cne $selected){continue}
            $valid=$decision.actionPermitted -and $decision.targetSlot -ceq $selected
        }
        if($valid){
            if(-not $read.auth.accessToken -or -not $read.auth.chatgptAccountId){throw 'routing_auth_unavailable'}
            # Native I/O is outside this short admission boundary. Changes after
            # this authorization govern subsequent actions; never repeat a turn.
            try{
                $authorized=Invoke-Hotpl8ActionAuthorization $StateDirectory $admission.generation {
                    $latest=Read-Hotpl8Json (Join-Path $StateDirectory 'codex-state.json')
                    if($latest.slots.$selected.identityKey -cne $prior.identityKey -or $latest.slots.$selected.binding -cne $prior.binding){throw 'routing_binding_changed'}
                    Get-Hotpl8CodexRoutingDecision $rows $part $policy $meters $Request $StateDirectory ([datetimeoffset]::UtcNow)
                }
            }catch{if($_.Exception.Message -eq 'action_state_changed'){throw 'routing_state_changed'};throw}
            if(-not $authorized.actionPermitted -or $authorized.targetSlot -cne $selected){throw 'routing_state_changed'}
            $critical=$authorized.critical;$critical.selected=$selected
            if($selected -cne $Request.previousSlot -or -not $Request.criticalState.selectedAt){$critical.selectedAt=[datetimeoffset]::UtcNow.ToString('o')}else{$critical.selectedAt=$Request.criticalState.selectedAt}
            return [pscustomobject]@{slot=$selected;home=[string]$slot.home;meter=$meter;criticalState=$critical;authorizationGeneration=$admission.generation;auth=$(if($Request.operation -ne 'exec'){$read.auth}else{$null})}
        }
        $rows=@($rows|Where-Object id -NE $selected)
        if($refresh){throw 'routing_refresh_failed'}
    }
    if($locked.Count){throw 'routing_account_busy'}
    throw 'routing_unavailable'
}
