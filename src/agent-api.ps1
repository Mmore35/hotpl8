# Versioned, cache-only agent operations. The CLI and MCP share this dispatcher.
function Stop-Hotpl8AgentRequest([string]$Code) {
    $failure=New-Object InvalidOperationException $Code
    $failure.Data['Hotpl8Code']=$Code
    throw $failure
}
function Get-Hotpl8AgentError([string]$Code) {
    $messages=@{
        invalid_json='Supply one valid JSON object.'
        invalid_request='Supply apiVersion 1, a supported operation and an arguments object.'
        unsupported_version='Only agent API version 1 is supported.'
        unknown_operation='Use an operation listed in the agent API documentation.'
        invalid_arguments='Arguments do not match this operation.'
        request_too_large='Requests must not exceed 64 KiB of UTF-8 JSON.'
        permission_denied='Pause writes are disabled for this connection.'
        policy_invalid='No valid policy is available. Use the local setup or doctor command.'
        snapshot_missing='No completed snapshot is available. Use the local refresh command.'
        snapshot_invalid='The cached observation is invalid or unsupported.'
        model_unknown='The requested model has no verified quota-meter mapping.'
        lease_state_invalid='Lease state is invalid. Automation remains paused; inspect it locally.'
        lease_conflict='This lease ID was used with different arguments or was already released.'
        lease_capacity='The lease ledger is full. Retry after retained records expire.'
        collector_busy='Another state writer is busy. Retry this same request later.'
        state_write_failed='The state change could not be saved. Retry this same request later.'
        internal_error='The request could not be completed. Inspect local diagnostics.'
    }
    if(-not $messages.ContainsKey($Code)){$Code='internal_error'}
    return [pscustomobject]@{code=$Code;message=$messages[$Code];retryable=($Code -in @('collector_busy','state_write_failed','lease_capacity'))}
}
function New-Hotpl8AgentEnvelope([string]$Operation,$Data,[string]$ErrorCode) {
    [pscustomobject]@{apiVersion=1;ok=(-not $ErrorCode);operation=$Operation;data=$Data;error=$(if($ErrorCode){Get-Hotpl8AgentError $ErrorCode}else{$null});computedAt=[datetimeoffset]::UtcNow.ToString('o')}
}
function Assert-Hotpl8AgentArguments($Value,[string[]]$Allowed,[string[]]$Required=@()) {
    if($Value -isnot [pscustomobject]){Stop-Hotpl8AgentRequest 'invalid_arguments'}
    foreach($property in $Value.PSObject.Properties){if($property.Name -cnotin $Allowed){Stop-Hotpl8AgentRequest 'invalid_arguments'}}
    foreach($name in $Required){if(-not $Value.PSObject.Properties[$name]){Stop-Hotpl8AgentRequest 'invalid_arguments'}}
}
function ConvertTo-Hotpl8AgentTime($Value) {
    try{if($Value -is [string] -and $Value){return [datetimeoffset]::Parse($Value).ToUniversalTime().ToString('o')}}catch{}
    return $null
}
function Get-Hotpl8AgentAge($Value,[datetimeoffset]$Now) {
    $at=ConvertTo-Hotpl8AgentTime $Value
    if($at){return [math]::Round(($Now-[datetimeoffset]::Parse($at)).TotalSeconds,3)}
    return $null
}
function ConvertTo-Hotpl8AgentReason([string]$Value) {
    # Never return arbitrary provider error strings from a local snapshot.
    $known=@('eligible','eligible_critical','disabled','stale','unknown','no_observation','duplicate_observation','duplicate_subscription','unsupported','authentication_required','relogin_required','no_credentials','rate_limited','meter_unknown','constraint_unknown','constraint_blocked','below_margin','reset_unconfirmed','model_quota_unknown','model_reset_unconfirmed','model_below_margin','window_unmeasured','malformed','blocked','unavailable','error','model_unknown','binding_changed')
    if($Value -cin $known){return $Value}
    return 'unknown'
}
function Get-Hotpl8AgentPause($Directory,[datetimeoffset]$Now) {
    $pause=Get-Hotpl8Pause $Directory $Now
    return [pscustomobject]@{active=[bool]$pause;until=(ConvertTo-Hotpl8AgentTime $pause.until);invalid=($pause.invalid -eq $true)}
}
function Get-Hotpl8AgentPolicy([string]$Directory) {
    $policy=Read-Hotpl8Json (Join-Path $Directory 'policy.json')
    try{
        Assert-Hotpl8Policy $policy
        if($policy.codex){Assert-CodexPolicy $policy.codex}
        if(@($policy.prefer).Count -gt 256 -or @($policy.codex.slots).Count -gt 256){throw 'too many accounts'}
    }catch{Stop-Hotpl8AgentRequest 'policy_invalid'}
    return $policy
}
function Get-Hotpl8AgentSnapshot([string]$Directory) {
    $path=Join-Path $Directory 'status.json'
    if(-not (Test-Path -LiteralPath $path)){Stop-Hotpl8AgentRequest 'snapshot_missing'}
    $snapshot=Read-Hotpl8Json $path
    if($snapshot -isnot [pscustomobject] -or -not (ConvertTo-Hotpl8AgentTime $snapshot.generatedAt) -or ($null -ne $snapshot.schemaVersion -and $snapshot.schemaVersion -notin @(1,2)) -or @($snapshot.slots).Count -gt 256 -or @($snapshot.providers.codex.slots).Count -gt 256){Stop-Hotpl8AgentRequest 'snapshot_invalid'}
    return $snapshot
}
function Test-Hotpl8AgentCodexObservation($Slot,[string]$Meter) {
    $bucket=$Slot.buckets.$Meter
    if(-not $bucket -or $bucket.status -ne 'observed'){return $true} # eligibility owns unavailable bucket codes
    if($bucket.windows -isnot [pscustomobject]){return $false}
    $windows=@($bucket.windows.PSObject.Properties)
    if(-not $windows.Count -or $windows.Count -gt 8){return $false}
    foreach($window in $windows){
        if($window.Name -notmatch '^[1-9][0-9]{0,5}$' -or $window.Value -isnot [pscustomobject]){return $false}
        $w=$window.Value
        if(-not (Test-Hotpl8Number $w.remainingPercent) -or $w.remainingPercent -lt 0 -or $w.remainingPercent -gt 100){return $false}
        if($null -ne $w.resetsAt -and (-not (Test-Hotpl8Number $w.resetsAt) -or $w.resetsAt -lt 0 -or $w.resetsAt -gt 253402300799 -or [math]::Floor($w.resetsAt) -ne $w.resetsAt)){return $false}
    }
    return $true
}
function Get-Hotpl8AgentReadiness($Policy,$Snapshot,[string]$Directory,[string]$Provider,[string]$Model,[datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
    $pause=Get-Hotpl8AgentPause $Directory $Now
    $part=if($Provider -eq 'claude'){$Policy}else{$Policy.codex}
    $meter=if($Provider -eq 'claude'){'claude'}elseif($Model){[string]$part.modelMeters.$Model}elseif($part.defaultMeter){[string]$part.defaultMeter}else{'codex'}
    if($Model -and ($Provider -ne 'codex' -or -not $meter)){Stop-Hotpl8AgentRequest 'model_unknown'}
    $configured=@(if($Provider -eq 'claude'){$Policy.prefer|ForEach-Object {[string]$_}}else{$part.slots|Where-Object {$_}|ForEach-Object {[string]$_.id}})
    $observations=@(if($Provider -eq 'claude'){$Snapshot.slots}else{$Snapshot.providers.codex.slots})
    $accounts=@();$usable=@();$acc=@{};$identities=@{}
    $active=if($Provider -eq 'claude' -and [string]$Snapshot.active -in $configured){[string]$Snapshot.active}else{$null}
    foreach($id in $configured){
        $matches=@($observations|Where-Object {if($Provider -eq 'claude'){[string]$_.slot -ceq $id}else{[string]$_.id -ceq $id}})
        $slot=if($matches.Count -eq 1){$matches[0]}else{$null}
        $age=Get-Hotpl8AgentAge $slot.observedAt $Now
        $observedAt=ConvertTo-Hotpl8AgentTime $slot.observedAt
        $reason='no_observation';$eligible=$false;$windows=@()
        $maxAge=if($Provider -eq 'claude' -and $null -ne $Policy.maxUsageAgeS){[double]$Policy.maxUsageAgeS}else{900}
        if($id -in @($part.disabled|ForEach-Object {[string]$_})){$reason='disabled'}
        elseif($matches.Count -gt 1){$reason='duplicate_observation'}
        elseif($slot){
            if($slot.status -ne 'ok'){$reason=ConvertTo-Hotpl8AgentReason $slot.status}
            elseif($null -eq $age -or $age -lt -5 -or $age -gt $maxAge){$reason='stale'}
            elseif($slot.streamKey -and $identities.ContainsKey([string]$slot.streamKey)){$reason='duplicate_subscription'}
            else{
                if($slot.streamKey){$identities[[string]$slot.streamKey]=$true}
                if($Provider -eq 'claude'){
                    $week=(Test-Hotpl8OverviewPercent $slot.used7d) -and (Test-Hotpl8FutureReset $slot.reset7d $Now)
                    $short=(Test-Hotpl8OverviewPercent $slot.used5h) -and ((Test-Hotpl8FutureReset $slot.reset5h $Now) -or ($slot.cold -eq $true -and $slot.used5h -eq 0 -and -not $slot.reset5h))
                    $modelBlock=Get-ClaudeModelBlock $slot.scoped $Policy ([int]$id) $Now
                    $entry=@{h5=$(if($short){100-[double]$slot.used5h}else{$null});h7=$(if($week){100-[double]$slot.used7d}else{$null});fresh=($slot.fresh -eq $true -and $short -and $week);modelBlocked=[bool]$modelBlock;obj=@{usage=@{fiveHour=@{resetsAt=$slot.reset5h};sevenDay=@{resetsAt=$slot.reset7d};scoped=$slot.scoped}}}
                    # A zero floor is not permission to use an exhausted account, including in critical mode.
                    if($entry.h5 -eq 0 -or $entry.h7 -eq 0){$entry.fresh=$false}
                    $acc[[int]$id]=$entry
                    $eligible=Test-Ok $entry ([double]$Policy.margin5h) (Get-Margin7dFor $Policy ([int]$id))
                    $reason=if($modelBlock){$modelBlock}elseif(-not $slot.fresh){'stale'}elseif(-not $short -or -not $week){'window_unmeasured'}elseif($eligible){'eligible'}else{'below_margin'}
                    foreach($w in @(@('300',$slot.used5h,$slot.reset5h),@('10080',$slot.used7d,$slot.reset7d))){
                        $windows+=@([pscustomobject]@{durationMinutes=[int]$w[0];remainingPercent=$(if(Test-Hotpl8OverviewPercent $w[1]){100-[double]$w[1]}else{$null});resetsAt=(ConvertTo-Hotpl8AgentTime $w[2])})
                    }
                }else{
                    if(-not (Test-Hotpl8AgentCodexObservation $slot $meter)){$reason='malformed'}
                    else{
                        $usable+=@($slot)
                        $reason=Get-CodexEligibility $slot $part $meter $Now
                        $eligible=$reason -eq 'eligible'
                        foreach($w in @($slot.buckets.$meter.windows.PSObject.Properties|Select-Object -First 8)){
                            if($w.Name -match '^[1-9][0-9]{0,5}$'){
                                $reset=$null;try{if($null -ne $w.Value.resetsAt){$reset=[datetimeoffset]::FromUnixTimeSeconds([long]$w.Value.resetsAt).ToString('o')}}catch{}
                                $windows+=@([pscustomobject]@{durationMinutes=[int]$w.Name;remainingPercent=$(if(Test-Hotpl8OverviewPercent $w.Value.remainingPercent){$w.Value.remainingPercent}else{$null});resetsAt=$reset})
                            }
                        }
                    }
                }
            }
        }
        $accounts+=@([pscustomobject]@{slot=$id;eligible=[bool]$eligible;reason=(ConvertTo-Hotpl8AgentReason $reason);observedAt=$observedAt;ageSeconds=$age;reserve=($id -in @($part.reserve|ForEach-Object {[string]$_}));windows=$windows})
    }
    $selected=$null;$proposed=$null;$held=$false;$critical=$false;$switching=$false
    if($Provider -eq 'claude'){
        $selection=Get-ClaudeSelection $Policy @($configured|ForEach-Object {[int]$_}) $acc ([int]$active) $Now $Snapshot.critical
        $critical=$selection.critical.active -eq $true
        if($critical){foreach($a in $accounts){if($a.slot -in @($selection.critical.ranked) -and $acc[[int]$a.slot].fresh -and -not $acc[[int]$a.slot].modelBlocked){$a.eligible=$true;$a.reason='eligible_critical'}}}
        $proposed=if($null -ne $selection.target){[string]$selection.target}elseif($selection.activeOk){$active}else{$null}
        # Read the current hold file; a published snapshot can predate a hold change.
        $holdPath=Join-Path $Directory 'hold.json';$hold=Read-Hotpl8Json $holdPath
        $held=(Test-Path -LiteralPath $holdPath) -and (-not (ConvertTo-Hotpl8AgentTime $hold.until) -or (Test-Hotpl8FutureReset $hold.until $Now))
        $switching=(Get-Hotpl8Actions $Policy $false).switching -and -not $pause.active -and -not $held
        $selected=if($switching){$proposed}elseif($selection.activeOk){$active}else{$null}
    }else{
        $hold=$Snapshot.providers.codex.hold
        $held=[bool]$hold -and (-not (ConvertTo-Hotpl8AgentTime $hold.until) -or (Test-Hotpl8FutureReset $hold.until $Now))
        if(-not $held){$hold=$null}
        $prior=[string]$Snapshot.providers.codex.recommendations.$meter
        if(-not $prior){$prior=[string]$Snapshot.providers.codex.recommendedSlot}
        $criticalAccounts=@(Get-Hotpl8CapacityAccounts ([pscustomobject]@{providers=@{codex=@{slots=$usable}}}) $part 'codex' $Now $meter)
        $criticalDecision=Get-Hotpl8CriticalDecision $criticalAccounts $part $prior $Snapshot.providers.codex.critical.$meter $Now
        $critical=$criticalDecision.active -eq $true
        if($critical){foreach($a in $accounts){$s=@($usable|Where-Object id -CEQ $a.slot);if($s.Count -eq 1 -and (Get-CodexEligibility $s[0] $part $meter $Now $true) -eq 'eligible'){$a.eligible=$true;$a.reason='eligible_critical'}}}
        $selected=Select-CodexSlot $usable $part $meter $prior $hold $Now $Snapshot.providers.codex.critical.$meter
        $proposed=$selected
    }
    # Pure selectors are authoritative; never publish a candidate that failed validation above.
    if($selected -and -not @($accounts|Where-Object {$_.slot -ceq [string]$selected -and $_.eligible}).Count){$selected=$null}
    if($proposed -and -not @($accounts|Where-Object {$_.slot -ceq [string]$proposed -and $_.eligible}).Count){$proposed=$null}
    $next=@($accounts.windows|Where-Object {Test-Hotpl8FutureReset $_.resetsAt $Now}|Sort-Object resetsAt|Select-Object -First 1)
    return [pscustomobject]@{provider=$Provider;meter=$meter;eligible=[bool]$selected;selectedSlot=$(if($selected){[string]$selected}else{$null});activeSlot=$active;proposedSlot=$proposed;requiresSelection=($Provider -eq 'claude' -and $proposed -and $proposed -ne $active);switchingPermitted=[bool]$switching;automationPaused=$pause.active;pause=$pause;selectionHeld=[bool]$held;mode=$(if($Policy.mode){$Policy.mode}else{'legacy'});critical=[bool]$critical;requiresNativeValidation=$true;scope=$(if($Provider -eq 'codex'){'next-launch'}else{'active-or-proposed-account'});nextObservedResetAt=$(if($next.Count){$next[0].resetsAt}else{$null});accounts=$accounts}
}
function Invoke-Hotpl8AgentRequest($Request,[string]$Directory,[bool]$AllowPause=$true) {
    $operation=$null
    try{
        if($Request -isnot [pscustomobject]){Stop-Hotpl8AgentRequest 'invalid_request'}
        if(@($Request.PSObject.Properties|Where-Object {$_.Name -cnotin @('apiVersion','operation','arguments')}).Count -or -not $Request.PSObject.Properties['apiVersion']){Stop-Hotpl8AgentRequest 'invalid_request'}
        if(-not (Test-Hotpl8Number $Request.apiVersion) -or $Request.apiVersion -ne 1){Stop-Hotpl8AgentRequest 'unsupported_version'}
        $operations=@('status','explain','capabilities','doctor','accounts','readiness','pause.acquire','pause.release')
        if($Request.operation -isnot [string] -or $Request.operation -cnotin $operations){Stop-Hotpl8AgentRequest 'unknown_operation'}
        $operation=[string]$Request.operation;$a=$Request.arguments
        if($operation -eq 'readiness'){
            Assert-Hotpl8AgentArguments $a @('provider','model') @('provider')
            if($a.provider -isnot [string] -or $a.provider -cnotin @('claude','codex') -or ($a.PSObject.Properties['model'] -and ($a.model -isnot [string] -or $a.model -notmatch '^[a-zA-Z0-9_.-]{1,100}$'))){Stop-Hotpl8AgentRequest 'invalid_arguments'}
        }elseif($operation -in @('pause.acquire','pause.release')){
            if(-not $AllowPause){Stop-Hotpl8AgentRequest 'permission_denied'}
            $keys=if($operation -eq 'pause.acquire'){@('leaseId','owner','minutes')}else{@('leaseId')}
            Assert-Hotpl8AgentArguments $a $keys $keys
            if($a.leaseId -isnot [string] -or $a.leaseId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -or [guid]$a.leaseId -eq [guid]::Empty){Stop-Hotpl8AgentRequest 'invalid_arguments'}
            if($operation -eq 'pause.acquire' -and ($a.owner -isnot [string] -or $a.owner.Length -lt 1 -or $a.owner.Length -gt 80 -or $a.owner -match '[\x00-\x1f\x7f]' -or -not (Test-Hotpl8Number $a.minutes) -or $a.minutes -lt 1 -or $a.minutes -gt 1440 -or [math]::Floor($a.minutes) -ne $a.minutes)){Stop-Hotpl8AgentRequest 'invalid_arguments'}
        }else{Assert-Hotpl8AgentArguments $a @()}
        $data=$null;$now=[datetimeoffset]::UtcNow
        if($operation -in @('doctor','capabilities')){
            $doctor=Get-Hotpl8Doctor $Directory
            # The original doctor is already redacted; select fields so future additions do not escape.
            $data=[pscustomobject]@{policyPresent=[bool]$doctor.policyPresent;policyValid=[bool]$doctor.policyValid;collectorBusy=[bool]$doctor.collectorBusy;snapshotFresh=[bool]$doctor.snapshotFresh;snapshotAgeSeconds=$doctor.snapshotAgeSeconds;claudeConfigured=[bool]$doctor.claudeConfigured;codexConfigured=[bool]$doctor.codexConfigured;claudeInstalled=[bool]$doctor.cswapFound;codexInstalled=[bool]$doctor.codexFound}
            if($operation -eq 'capabilities'){$data|Add-Member NoteProperty operations @($operations|Where-Object {$AllowPause -or $_ -notlike 'pause.*'});$data|Add-Member NoteProperty pauseWrites $AllowPause;$data|Add-Member NoteProperty observationMode 'cached';$data|Add-Member NoteProperty readinessScope 'eligibility-only'}
        }else{
            $policy=Get-Hotpl8AgentPolicy $Directory
            if($operation -eq 'pause.acquire'){$data=Invoke-Hotpl8LeaseAcquire $Directory $a.leaseId $a.owner ([int]$a.minutes) $now}
            elseif($operation -eq 'pause.release'){$data=Invoke-Hotpl8LeaseRelease $Directory $a.leaseId $now}
            elseif($operation -eq 'accounts'){
                $rows=@(foreach($id in @($policy.prefer)){[pscustomobject]@{provider='claude';slot=[string]$id;disabled=($id -in @($policy.disabled));reserve=($id -in @($policy.reserve))}};foreach($s in @($policy.codex.slots|Where-Object {$_})){[pscustomobject]@{provider='codex';slot=[string]$s.id;disabled=($s.id -in @($policy.codex.disabled));reserve=($s.id -in @($policy.codex.reserve))}})
                $data=[pscustomobject]@{accounts=$rows}
            }else{
                $snapshot=Get-Hotpl8AgentSnapshot $Directory
                if($operation -eq 'readiness'){$data=Get-Hotpl8AgentReadiness $policy $snapshot $Directory $a.provider $a.model $now}
                else{
                    $collector=Read-Hotpl8Json (Join-Path $Directory 'collector.json')
                    if(-not $collector -or ((ConvertTo-Hotpl8AgentTime $snapshot.collector.completedAt) -and (ConvertTo-Hotpl8AgentTime $snapshot.collector.completedAt) -gt (ConvertTo-Hotpl8AgentTime $collector.startedAt))){$collector=$snapshot.collector}
                    $data=[pscustomobject]@{generatedAt=(ConvertTo-Hotpl8AgentTime $snapshot.generatedAt);ageSeconds=(Get-Hotpl8AgentAge $snapshot.generatedAt $now);collector=[pscustomobject]@{status=$(if($collector.status -in @('ok','incomplete','collecting','started','failed')){$collector.status}else{'unknown'});startedAt=(ConvertTo-Hotpl8AgentTime $collector.startedAt);completedAt=(ConvertTo-Hotpl8AgentTime $collector.completedAt)};providers=[pscustomobject]@{claude=(Get-Hotpl8AgentReadiness $policy $snapshot $Directory 'claude' '' $now);codex=(Get-Hotpl8AgentReadiness $policy $snapshot $Directory 'codex' '' $now)}}
                }
            }
        }
        return New-Hotpl8AgentEnvelope $operation $data ''
    }catch{
        $code=[string]$_.Exception.Data['Hotpl8Code']
        if(-not $code){$code='internal_error'}
        return New-Hotpl8AgentEnvelope $operation $null $code
    }
}
function Invoke-Hotpl8AgentJson([string]$Json,[string]$Directory) {
    if([Text.Encoding]::UTF8.GetByteCount($Json) -gt 65536){return New-Hotpl8AgentEnvelope '' $null 'request_too_large'}
    try{$request=ConvertFrom-Json -InputObject $Json -ErrorAction Stop}catch{return New-Hotpl8AgentEnvelope '' $null 'invalid_json'}
    return Invoke-Hotpl8AgentRequest $request $Directory
}
