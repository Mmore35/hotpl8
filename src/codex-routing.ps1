# The T3 adapter's private broker. Never expose its token-bearing result via status/MCP.
function Get-Hotpl8CodexRoute($Request,[string]$StateDirectory,[string]$Executable,[scriptblock]$Reader) {
    $policy=Read-Hotpl8Json (Join-Path $StateDirectory 'policy.json')
    Assert-Hotpl8Policy $policy
    Assert-CodexPolicy $policy.codex
    foreach($key in @('OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','CODEX_SQLITE_HOME','OPENAI_BASE_URL')){
        if([Environment]::GetEnvironmentVariable($key)){throw 'routing_environment_conflict'}
    }
    $state=Read-Hotpl8Json (Join-Path $StateDirectory 'codex-state.json')
    $snapshot=Read-Hotpl8Json (Join-Path $StateDirectory 'status.json')
    $status=$snapshot.providers.codex
    $now=[datetimeoffset]::UtcNow
    $refresh=$Request.operation -eq 'refresh'
    if($Request.operation -notin @('select','refresh','exec')){throw 'routing_invalid_request'}
    $meter=if($Request.model){[string]$policy.codex.modelMeters.([string]$Request.model)}else{[string]$policy.codex.defaultMeter}
    if(-not $meter){throw 'routing_model_unknown'}
    $rows=@($status.slots)
    $identities=@{}
    foreach($slot in @($policy.codex.slots)){
        $prior=$state.slots.([string]$slot.id)
        if($prior.identityKey){
            if($identities.ContainsKey([string]$prior.identityKey)){throw 'routing_duplicate_identity'}
            $identities[[string]$prior.identityKey]=$true
        }
    }
    # Duplicate, removed and rebound observations cannot authorize a launch.
    $rows=@(foreach($slot in @($policy.codex.slots)){
        $matches=@($rows|Where-Object id -EQ $slot.id)
        $prior=$state.slots.([string]$slot.id)
        if($matches.Count -eq 1 -and $prior.identityKey -and $prior.binding -eq (Get-Hotpl8Hash ([IO.Path]::GetFullPath([string]$slot.home))) -and $slot.id -notin @($Request.exclude)){$matches[0]}
    })
    if(-not $refresh){
        try{$age=($now-[datetimeoffset]::Parse($status.observedAt)).TotalSeconds}catch{throw 'routing_stale'}
        if($age -lt -5 -or $age -gt 900){throw 'routing_stale'}
    }
    $hold=Get-Hold $StateDirectory
    $previous=if($Request.previousSlot){[string]$Request.previousSlot}else{[string]$status.recommendations.$meter}
    if($hold){$previous=[string]$status.recommendations.$meter}
    for($attempt=0;$attempt -lt @($policy.codex.slots).Count;$attempt++){
        $selected=if($refresh){[string]$Request.previousSlot}else{Select-CodexSlot $rows $policy.codex $meter $previous $hold $now $status.critical.$meter}
        if(-not $selected){throw 'routing_unavailable'}
        $slot=@($policy.codex.slots|Where-Object id -EQ $selected)
        if($slot.Count -ne 1 -or $selected -in @($policy.codex.disabled)){throw 'routing_binding_changed'}
        $slot=$slot[0]
        $prior=$state.slots.$selected
        if(-not $prior.identityKey -or $prior.binding -ne (Get-Hotpl8Hash ([IO.Path]::GetFullPath([string]$slot.home)))){throw 'routing_binding_changed'}
        $read=if($Reader){& $Reader $slot $refresh}else{Read-CodexQuota $slot.home $Executable 6500 $Request.cwd -IncludeAccessToken -RefreshToken:$refresh}
        $valid=$read.status -eq 'ok' -and $read.identityKey -eq $prior.identityKey -and $read.standardTransport -and (-not $read.modelProvider -or $read.modelProvider -eq 'openai')
        if($refresh){
            if(-not $valid -or $read.auth.chatgptAccountId -cne $Request.accountId){throw 'routing_refresh_failed'}
        }else{
            $current=[pscustomobject]@{id=$selected;status='ok';observedAt=$now.ToString('o');buckets=(ConvertTo-CodexBuckets $read.quota $null $now)}
            $accounts=@(Get-Hotpl8CapacityAccounts ([pscustomobject]@{providers=@{codex=$status}}) $policy.codex 'codex' $now $meter)
            $critical=Get-Hotpl8CriticalDecision $accounts $policy.codex $selected $status.critical.$meter $now
            $valid=$valid -and (Get-CodexEligibility $current $policy.codex $meter $now $critical.active) -eq 'eligible'
        }
        if($valid){
            $model=if($Request.model){[string]$Request.model}else{[string]$read.model}
            if(-not $model -or [string]$policy.codex.modelMeters.$model -ne $meter){throw 'routing_model_unknown'}
            if(-not $read.auth.accessToken -or -not $read.auth.chatgptAccountId){throw 'routing_auth_unavailable'}
            return [pscustomobject]@{slot=$selected;home=[string]$slot.home;model=$model;meter=$meter;auth=$(if($Request.operation -ne 'exec'){$read.auth}else{$null})}
        }
        $rows=@($rows|Where-Object id -NE $selected)
        if($refresh){throw 'routing_refresh_failed'}
    }
    throw 'routing_unavailable'
}
