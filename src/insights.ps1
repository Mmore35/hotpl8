. (Join-Path $PSScriptRoot 'overview.ps1')
. (Join-Path $PSScriptRoot 'forecast.ps1')
. (Join-Path $PSScriptRoot 'replay.ps1')
function Add-Hotpl8ActionEvent([string]$Directory, [string]$Provider, [string]$Slot, [string]$Kind, [string]$Reason, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    $path=Join-Path $Directory 'activity.json'
    $old=Read-Hotpl8Json $path
    $event=[pscustomobject]@{id=[guid]::NewGuid().ToString('N');at=$Now.ToString('o');provider=$Provider;slot=$Slot;kind=$Kind;reason=$Reason}
    $events=@(@($old.events | Where-Object {$_}) + @($event) | Select-Object -Last 100)
    Write-Hotpl8Text $path (@{schemaVersion=1;events=$events}|ConvertTo-Json -Depth 6)
}
function Get-Hotpl8Health($Collector, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    if (-not $Collector) { return 'manual / no collector evidence' }
    try {
        $started=[datetimeoffset]::Parse($Collector.startedAt)
        if($started -gt $Now.AddSeconds(5)){return 'collector state invalid'}
        if (-not $Collector.completedAt -or [datetimeoffset]::Parse($Collector.completedAt) -lt $started) {
            if (($Now-$started).TotalSeconds -gt 240) { return 'collector stalled' }
            return 'collecting'
        }
        $completed=[datetimeoffset]::Parse($Collector.completedAt)
        if (($Now-$completed).TotalSeconds -gt 900) { return 'collector overdue' }
        if ($Collector.status -ne 'ok') { return 'provider checks incomplete' }
        return 'recent collection completed'
    } catch { return 'collector state invalid' }
}

function Add-Hotpl8Insights($Snapshot, $Policy, [string]$Directory, $Previous, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    $history=if($Policy.historyEnabled -eq $true){Read-Hotpl8Json (Join-Path $Directory 'usage-history.json')}else{$null}; $newSamples=@()
    foreach ($slot in @($Snapshot.slots)) {
        if(-not $slot){continue}
        $slot|Add-Member NoteProperty forecast $null -Force
        if (-not $slot.fresh -or -not $slot.observedAt) { continue }
        $key='claude/'+$slot.streamKey+'/10080'
        $f=Get-Hotpl8Forecast $slot.used7d $slot.reset7d $slot.observedAt 10080 $Now @($history.samples|Where-Object key -EQ $key)
        $slot|Add-Member NoteProperty forecast $f -Force
        if($f){$newSamples+=@(@{key=$key;observedAt=$slot.observedAt;resetAt=$slot.reset7d;used=$slot.used7d})}
    }
    foreach ($slot in @($Snapshot.providers.codex.slots)) {
        if (-not $slot) { continue }
        foreach ($entry in $slot.buckets.PSObject.Properties) {
            $entry.Value|Add-Member NoteProperty forecast $null -Force
            if($slot.status -ne 'ok'){continue}
            $window=$entry.Value.windows.'10080'
            if (-not $window -or $entry.Value.status -ne 'observed' -or $window.anchorState -ne 'observed-active') { continue }
            $key='codex/'+$slot.streamKey+'/'+$entry.Name+'/10080'
            $reset=[datetimeoffset]::FromUnixTimeSeconds($window.resetsAt).ToString('o')
            $f=Get-Hotpl8Forecast $window.usedPercent $reset $slot.observedAt 10080 $Now @($history.samples|Where-Object key -EQ $key)
            $entry.Value|Add-Member NoteProperty forecast $f -Force
            if($f){$newSamples+=@(@{key=$key;observedAt=$slot.observedAt;resetAt=$reset;used=$window.usedPercent})}
        }
    }
    if($Policy.historyEnabled -eq $true){$null=Update-Hotpl8History $Directory $newSamples $Now}
    $pause=Get-Hotpl8Pause $Directory $Now
    $Snapshot|Add-Member NoteProperty automationPause $pause -Force
    if($Snapshot.active -and $Previous.active -and $Snapshot.active -ne $Previous.active){Add-Hotpl8ActionEvent $Directory 'claude' ([string]$Snapshot.active) 'active_changed' 'observed_account_change' $Now}
    $next=$Snapshot.providers.codex.recommendedSlot
    if($next -and $next -ne $Previous.providers.codex.recommendedSlot){Add-Hotpl8ActionEvent $Directory 'codex' $next 'recommendation' 'next_launch_only' $Now}
    $activity=Read-Hotpl8Json (Join-Path $Directory 'activity.json')
    $Snapshot|Add-Member NoteProperty recentActions @($activity.events|Select-Object -Last 5) -Force
    $Snapshot|Add-Member NoteProperty providerOverview (Get-Hotpl8ProviderOverview $Snapshot $Policy $Now) -Force
    $shadow=Invoke-Hotpl8Replay @($Snapshot) $Policy
    $Snapshot|Add-Member NoteProperty shadow @($shadow.decisions) -Force
}
function Read-Hotpl8Snapshot([string]$Directory,$PolicyOverride=$null) {
    $s=Read-Hotpl8Json (Join-Path $Directory 'status.json')
    $c=Read-Hotpl8Json (Join-Path $Directory 'collector.json')
    $pause=Get-Hotpl8Pause $Directory
    # First collection can stall before there is a snapshot. Show that evidence too.
    if(-not $s -and ($c -or $pause)){$s=[pscustomobject]@{schemaVersion=2;generatedAt=$null;slots=@()}}
    if($s){
        if($c){$s|Add-Member NoteProperty collector $c -Force}
        $s|Add-Member NoteProperty automationPause $pause -Force
    }
    if($s -and $PolicyOverride){$s|Add-Member NoteProperty displayPolicy 'explicit reader policy' -Force}
    if($s){$s|Add-Member NoteProperty providerOverview (Get-Hotpl8ProviderOverview $s $(if($PolicyOverride){$PolicyOverride}else{Read-Hotpl8Json (Join-Path $Directory 'policy.json')})) -Force}
    return $s
}
function Format-Hotpl8Explanation($Snapshot, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    if(-not $Snapshot -or -not $Snapshot.generatedAt){'No observation. Run hotpl8 refresh.';return}
    try{$age=($Now-[datetimeoffset]::Parse($Snapshot.generatedAt)).TotalSeconds}catch{$age=99999}
    if($age -gt 900 -or $age -lt -5){'STALE: these are the decisions at the last observation, not a current recommendation.'}
    if($Snapshot.providerOverview){Format-Hotpl8Overview $Snapshot.providerOverview}
    'Observed: '+$Snapshot.generatedAt
    if($Snapshot.automationPause){'Automation paused: '+$Snapshot.automationPause.reason}
    if($Snapshot.critical.active){'Claude critical: '+$Snapshot.critical.reason+' / '+$Snapshot.critical.basis+' / checks '+$Snapshot.critical.pollSeconds+'s'}
    if($Snapshot.decision){
        'Claude: '+$Snapshot.decision.reason+'; policy '+$Snapshot.decision.policy
        foreach($r in @($Snapshot.decision.accounts)){'  slot '+$r.slot+': '+$r.reason+'; rank '+$r.rank}
    }
    foreach($c in $Snapshot.providers.codex.critical.PSObject.Properties){if($c.Value.active){'Codex '+$c.Name+' critical: '+$c.Value.reason+' / '+$c.Value.basis+' / checks '+$c.Value.pollSeconds+'s'}}
    foreach($d in @($Snapshot.providers.codex.decisions)){
        'Codex '+$d.meter+': next launch '+$(if($d.selected){$d.selected}else{'none'})+'; policy '+$d.policy
        foreach($r in @($d.accounts)){'  '+$r.slot+': '+$r.reason+'; reserve='+$r.reserve}
    }
    'Codex selection affects the next launch. Existing sessions retain their account.'
}
