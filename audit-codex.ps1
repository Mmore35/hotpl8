# Read-only observation coverage audit. Never polls, launches, or refreshes auth.
# Coverage is evidence about recorded quota reads, not proof of token refresh,
# warming benefit, or every acceptance criterion in the integration plan.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Slot,
    [string]$HistoryPath,
    [datetimeoffset]$Since=[datetimeoffset]::MinValue,
    [datetimeoffset]$Now=[datetimeoffset]::UtcNow,
    [ValidateRange(0.01,8760)][double]$RequiredHours=72,
    [ValidateRange(0.01,60)][double]$MaxGapMinutes=10
)
$ErrorActionPreference='Stop'
if(-not $HistoryPath){$HistoryPath=Join-Path $PSScriptRoot 'codex-observations.jsonl'}
$report=[ordered]@{
    slot=$Slot; since=$(if($Since -ne [datetimeoffset]::MinValue){$Since.ToString('o')}else{$null})
    checkedAt=$Now.ToString('o'); requiredHours=$RequiredHours; maxGapMinutes=$MaxGapMinutes
    coverageStatus='no_observations'; observations=0; successful=0; failed=0
    invalidRows=0; gaps=0; maximumGapMinutes=0.0
    firstObservationAt=$null; latestObservationAt=$null; latestObservationAgeMinutes=$null
    currentContinuousHours=0.0; longestContinuousHours=0.0
    scope='Recorded quota-read coverage only; does not prove native token refresh or warming.'
}
$previous=$null; $start=$null; $last=$null; $longest=0.0
if(Test-Path -LiteralPath $HistoryPath -PathType Leaf){
    foreach($line in [IO.File]::ReadLines($HistoryPath)){
        if([string]::IsNullOrWhiteSpace($line)){continue}
        try{
            $row=$line|ConvertFrom-Json -ErrorAction Stop
            $time=[datetimeoffset]::Parse([string]$row.observedAt)
            if($time -lt $Since){continue}
            # Clock reversals, duplicate timestamps, and impossible future rows
            # interrupt evidence rather than being sorted into fictitious coverage.
            if($time -gt $Now.AddSeconds(5) -or ($previous -and $time -le $previous)){throw 'invalid_clock'}
            $matches=@($row.slots|Where-Object id -EQ $Slot)
            if($matches.Count -ne 1){throw 'missing_or_duplicate_slot'}
        } catch {$report.invalidRows++; $start=$null; continue}
        $report.observations++
        if(-not $report.firstObservationAt){$report.firstObservationAt=$time.ToString('o')}
        $report.latestObservationAt=$time.ToString('o'); $last=$time
        $gap=if($previous){($time-$previous).TotalMinutes}else{0.0}
        $report.maximumGapMinutes=[Math]::Max($report.maximumGapMinutes,$gap)
        if($gap -gt $MaxGapMinutes){$report.gaps++; $start=$null}
        $previous=$time
        $healthy=$false
        try{
            $age=($time-[datetimeoffset]::Parse([string]$matches[0].observedAt)).TotalSeconds
            $healthy=($matches[0].status -eq 'ok' -and $age -ge -5 -and $age -le 900)
        }catch{}
        if($healthy){
            $report.successful++
            if(-not $start){$start=$time}
            $longest=[Math]::Max($longest,($time-$start).TotalHours)
        } else {$report.failed++; $start=$null}
    }
}
if($last){
    $report.latestObservationAgeMinutes=($Now-$last).TotalMinutes
    $report.currentContinuousHours=if($start){($last-$start).TotalHours}else{0.0}
    $report.longestContinuousHours=$longest
    $report.coverageStatus='incomplete'
    if($report.latestObservationAgeMinutes -gt $MaxGapMinutes){$report.coverageStatus='stale'}
    elseif($report.currentContinuousHours -ge $RequiredHours){$report.coverageStatus='sufficient'}
}
[pscustomobject]$report|ConvertTo-Json -Depth 4
