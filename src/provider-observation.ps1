# Native/public shapes enter the same pure observation contract here. These
# decoders do not read state, fetch quota, select accounts or own credentials.
. (Join-Path $PSScriptRoot 'provider-decision.ps1')
function ConvertTo-Hotpl8ClaudeObservation($Slot,$Policy,[datetimeoffset]$Now) {
    $windows=@()
    foreach($shape in @(@('300','short','used5h','reset5h'),@('10080','weekly','used7d','reset7d'))){
        $used=$Slot.($shape[2]);$reset=$Slot.($shape[3])
        $windows+=[pscustomobject]@{name=$shape[0];scope='';role=$shape[1];state=$(if($null -ne $used){'observed'}else{'unknown'});required=$true;usedPercent=$used;resetAt=$reset;observedAt=$Slot.observedAt;resetConfirmed=[bool]$reset;resetRequired=($shape[1] -eq 'weekly' -or $used -ne 0)}
    }
    foreach($model in @($Policy.claudeModels|Where-Object {$_})){
        $scopes=@($Slot.scoped|Where-Object name -CEQ $model)
        $scope=if($scopes.Count -eq 1){$scopes[0]}else{$null}
        $windows+=[pscustomobject]@{name=[string]$model;scope=[string]$model;role='scoped';state=$(if($scope){'observed'}else{'unknown'});required=$true;usedPercent=$scope.pct;resetAt=$scope.resetsAt;observedAt=$Slot.observedAt;resetConfirmed=[bool]$scope.resetsAt;resetRequired=$true}
    }
    $status=if($Slot.status -and $Slot.status -ne 'ok'){[string]$Slot.status}elseif($Slot.fresh -eq $false){'stale'}else{'ok'}
    [pscustomobject]@{id=[string]$Slot.slot;status=$status;observedAt=$Slot.observedAt;identityKey=[string]$Slot.streamKey;windows=$windows;blockedReason=$Slot.modelReason}
}
function ConvertTo-Hotpl8ClaudeEntryObservation($Id,$Entry,$Policy,[datetimeoffset]$Now,[switch]$ForWarm) {
    if($Entry.observation){$observation=$Entry.observation}else{
    $stamp=$Entry.observedAt
    $nativeAge=$Entry.obj.usageAgeSeconds
    if(-not $stamp -and (Test-Hotpl8Number $nativeAge) -and $nativeAge -ge 0 -and $nativeAge -le 604800){
        try{$stamp=$Now.AddSeconds(-[double]$nativeAge).ToString('o')}catch{$stamp=$null}
    }
    # Legacy callers pass already-evaluated headroom/freshness rather than raw
    # quota. Preserve that interface; new raw observations always carry time.
    if(-not $stamp -and $null -eq $nativeAge -and $Entry.fresh){$stamp=$Now.ToString('o')}
    $slot=[pscustomobject]@{slot=$Id;status=$(if($Entry){if($Entry.obj.usageStatus){$Entry.obj.usageStatus}else{'ok'}}else{'not_observed'});fresh=[bool]$Entry.fresh;observedAt=$stamp;used5h=$(if(Test-Hotpl8Number $Entry.h5){100-[double]$Entry.h5}else{$null});used7d=$(if(Test-Hotpl8Number $Entry.h7){100-[double]$Entry.h7}else{$null});reset5h=$Entry.obj.usage.fiveHour.resetsAt;reset7d=$Entry.obj.usage.sevenDay.resetsAt;scoped=$Entry.obj.usage.scoped;modelReason=$(if($Entry.modelBlocked){if($Entry.modelReason){$Entry.modelReason}else{'model_quota_unknown'}}else{$null})}
    $observation=ConvertTo-Hotpl8ClaudeObservation $slot $Policy $Now
    }
    # Opening a native cold window needs fresh quota but cannot require the
    # reset anchor that opening it will create. This copy is action-specific;
    # admission retains the original, conservative reset requirement.
    if($ForWarm -and $Entry.cold -and $Entry.obj.usage.fiveHour -and [string]::IsNullOrWhiteSpace([string]$Entry.obj.usage.fiveHour.resetsAt)){
        $observation=$observation|Select-Object *
        $observation.windows=@(foreach($window in $observation.windows){
            $copy=$window|Select-Object *
            if($copy.role -eq 'short' -and -not $copy.scope -and -not $copy.resetAt){$copy.resetRequired=$false}
            $copy
        })
    }
    return $observation
}
function ConvertTo-Hotpl8CodexObservation($Slot,[string]$Meter) {
    $bucket=$Slot.buckets.$Meter;$windows=@();$malformed=$false
    foreach($entry in @($bucket.windows.PSObject.Properties|Where-Object {$null -ne $_})){
        $w=$entry.Value;$reset=$null
        # Published used/remaining values describe one observation. A stale or
        # corrupted mirror cannot authorize work by choosing its happier half.
        if(-not (Test-Hotpl8Number $w.usedPercent) -or -not (Test-Hotpl8Number $w.remainingPercent) -or $w.remainingPercent -lt 0 -or $w.remainingPercent -gt 100 -or [math]::Abs(([double]$w.usedPercent+[double]$w.remainingPercent)-100) -gt 0.000001){$malformed=$true}
        if($null -ne $w.resetsAt){try{$reset=[datetimeoffset]::FromUnixTimeSeconds([long]$w.resetsAt).ToString('o')}catch{$reset='invalid'}}
        # Legacy snapshots stamped the enclosing account only. Inherit that
        # original observation, never the current clock or a newer collector time.
        $hasStamp=if(-not $w){$false}elseif($w -is [Collections.IDictionary]){$w.Contains('observedAt')}else{$null -ne $w.PSObject.Properties['observedAt']}
        $stamp=if($hasStamp){$w.observedAt}else{$Slot.observedAt}
        $windows+=[pscustomobject]@{name=[string]$entry.Name;scope=$Meter;role=$(if($entry.Name -eq '300'){'short'}elseif($entry.Name -eq '10080'){'weekly'}else{'scoped'});state='observed';required=$true;usedPercent=$w.usedPercent;resetAt=$reset;observedAt=$stamp;resetConfirmed=($w.anchorState -eq 'observed-active')}
    }
    [pscustomobject]@{id=[string]$Slot.id;status=[string]$Slot.status;observedAt=$Slot.observedAt;identityKey=[string]$Slot.streamKey;windows=$windows;blockedReason=$(if(-not $bucket){'meter_unknown'}elseif($bucket.status -ne 'observed'){[string]$bucket.status}elseif($malformed){'window_malformed'}else{$null})}
}
function Add-Hotpl8ObservationCapacity($Observations,$CapacityAccounts) {
    foreach($observation in @($Observations)){
        $copy=$observation|Select-Object *
        $capacity=@($CapacityAccounts|Where-Object slot -CEQ $observation.id)
        if($capacity.Count -eq 1){$copy|Add-Member NoteProperty capacity @{scaled=$capacity[0].scaled;gross=$capacity[0].gross} -Force}
        $copy
    }
}
