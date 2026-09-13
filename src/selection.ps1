# Optional policies keep reserve/degraded tiers outside this key.
function Get-Hotpl8SelectionKey([string]$Order, $FiveRemaining, $WeekRemaining, $WeekReset, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    try { $reset=[datetimeoffset]::Parse([string]$WeekReset); if($reset -le $Now){return [double]::MaxValue} } catch { return [double]::MaxValue }
    if($Order -eq 'weekly-expiry'){return [double]$reset.ToUnixTimeSeconds()}
    if($Order -eq 'balanced'){
        if(-not (Test-Hotpl8Number $WeekRemaining)){return [double]::MaxValue}
        # Sustainable weekly allowance per remaining five-hour interval, limited
        # by the current short window. Higher useful headroom sorts first.
        $intervals=[math]::Max(1,($reset-$Now).TotalHours/5)
        $sustainable=[double]$WeekRemaining/$intervals
        $short=if(Test-Hotpl8Number $FiveRemaining){[double]$FiveRemaining}else{100}
        return -[math]::Min($short,$sustainable)
    }
    return [double]::MaxValue
}
