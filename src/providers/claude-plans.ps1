# Optional plan discovery cannot change authentication, quota or eligibility.
function Test-Hotpl8DetectedPlan($Plan,[datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
    # Plan refresh is scheduled at 15 minutes. Leave a bounded scheduling grace
    # so a normal collector wake does not briefly erase the capacity weights.
    # This does not extend quota freshness or accept a failed/changed identity.
    if(-not $Plan -or $Plan.status -notin @('detected','partial')){return $false}
    try{
        $age=($Now-[datetimeoffset]::Parse($Plan.observedAt)).TotalSeconds
        return $age -ge -5 -and $age -le 1200
    }catch{return $false}
}
