. (Join-Path $PSScriptRoot 'overview.ps1')
. (Join-Path $PSScriptRoot 'replay.ps1')
. (Join-Path $PSScriptRoot 'diagnostics.ps1')
function Get-Hotpl8HistoryStores($Policy,[string]$Directory) {
    # Canonical adapters share the original store. Aliases have isolated stores;
    # enumerate configured registrations only, never arbitrary residual folders.
    $stores=@{}
    foreach($r in @(Get-Hotpl8ConfiguredProviders $Policy)){
        $state=Get-Hotpl8ProviderStateDirectory $Directory $r.id
        if(-not $stores.ContainsKey($state)){$stores[$state]=[pscustomobject]@{directory=$state;providers=@();samples=0}}
        $stores[$state].providers+=@($r.id)
    }
    foreach($key in @($stores.Keys|Sort-Object)){
        $history=Read-Hotpl8Json (Join-Path $key 'usage-history.json')
        $stores[$key].samples=@($history.samples|Where-Object {$_}).Count
        $stores[$key]
    }
}
function Get-Hotpl8Health($Collector, [datetimeoffset]$Now = [datetimeoffset]::UtcNow, [string]$Provider) {
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
        if($Provider -and $Collector.providers.$Provider){
            $p=$Collector.providers.$Provider
            if($p.failureCode -eq 'state_io_failed'){return 'local state write failed; retrying'}
            if($p.status -eq 'ok'){
                $age=($Now-[datetimeoffset]::Parse($p.lastSuccessAt)).TotalSeconds
                if($age -gt 900 -or $age -lt -5){return 'provider readings stale'}
                return 'recent collection completed'
            }
            return 'provider checks incomplete'
        }
        if(@($Collector.providers.PSObject.Properties|Where-Object {$_.Value.failureCode -eq 'state_io_failed'}).Count){return 'local state write failed; retrying'}
        if ($Collector.status -ne 'ok') { return 'provider checks incomplete' }
        return 'recent collection completed'
    } catch { return 'collector state invalid' }
}

function Read-Hotpl8Snapshot([string]$Directory,$PolicyOverride=$null,[switch]$SkipDisplay,[datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
    $s=Read-Hotpl8Json (Join-Path $Directory 'status.json')
    $c=Read-Hotpl8Json (Join-Path $Directory 'collector.json')
    $pause=Get-Hotpl8Pause $Directory $Now
    # First collection can stall before there is a snapshot. Show that evidence too.
    if(-not $s -and ($c -or $pause)){$s=[pscustomobject]@{schemaVersion=2;generatedAt=$null;slots=@()}}
    if($s){
        if($c){
            # A failed trailing collector.json write can leave its earlier
            # "started" marker behind a successfully published snapshot.
            # Prefer the completed evidence embedded in that newer snapshot.
            $useCollector=$true
            try{
                if($s.collector.completedAt){
                    $completed=[datetimeoffset]::Parse($s.collector.completedAt)
                    $useCollector=[datetimeoffset]::Parse($c.startedAt) -gt $completed -or ($c.completedAt -and [datetimeoffset]::Parse($c.completedAt) -ge $completed)
                }
            }catch{}
            if($useCollector){$s|Add-Member NoteProperty collector $c -Force}
        }
        $s|Add-Member NoteProperty automationPause $pause -Force
    }
    if($s -and $PolicyOverride){$s|Add-Member NoteProperty displayPolicy 'explicit reader policy' -Force}
    # A native launch reads provider observations only: it takes the snapshot as stored
    # and skips the reader-side display summaries, which nothing on that path reads.
    if($s -and -not $SkipDisplay){
        $readerPolicy=if($PolicyOverride){$PolicyOverride}else{Read-Hotpl8Json (Join-Path $Directory 'policy.json')}
        $s|Add-Member NoteProperty providerOverview (Get-Hotpl8ProviderOverview $s $readerPolicy $Now) -Force
        # Advice only: a detector failure must never cost a reader its snapshot.
        $candidates=@();try{$candidates=@(Get-Hotpl8ParkCandidates $s $readerPolicy $Now)}catch{}
        $s|Add-Member NoteProperty parkCandidates $candidates -Force
    }
    return $s
}
