# Shared action controls. Collector callers hold tick.lock while updating state.
. (Join-Path $PSScriptRoot 'leases.ps1')
function Test-Hotpl8WorkTime($Schedule, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    if (-not $Schedule) { return $true }
    $zone = if ($Schedule.timeZone) { [TimeZoneInfo]::FindSystemTimeZoneById($Schedule.timeZone) } else { [TimeZoneInfo]::Local }
    $local = [TimeZoneInfo]::ConvertTime($Now, $zone)
    $start = [timespan]::ParseExact($Schedule.start, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
    $end = [timespan]::ParseExact($Schedule.end, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
    $day = [int]$local.DayOfWeek; $time = $local.TimeOfDay
    if ($start -eq $end) { return $false }
    if ($start -lt $end) { return ($day -in @($Schedule.days) -and $time -ge $start -and $time -lt $end) }
    # An overnight interval belongs to the day on which it starts.
    if ($time -ge $start) { return $day -in @($Schedule.days) }
    return ($time -lt $end -and (($day + 6) % 7) -in @($Schedule.days))
}
function Get-Hotpl8Pause([string]$Directory, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    $leases=Get-Hotpl8LeasePause $Directory $Now
    if ($leases.invalid) { return $leases }
    $path = Join-Path $Directory 'automation-pause.json'
    if (-not (Test-Path -LiteralPath $path)) { return $leases }
    $pause = Read-Hotpl8Json $path
    try {
        if (-not $pause.until) { throw 'invalid pause' }
        if ([datetimeoffset]::Parse($pause.until) -gt $Now) {
            if (-not $leases) { return $pause }
            $until=if ([datetimeoffset]::Parse($pause.until) -gt [datetimeoffset]::Parse($leases.until)) { $pause.until } else { $leases.until }
            return [pscustomobject]@{until=$until;reason='manual_and_agent_leases';invalid=$false;leaseCount=$leases.leaseCount}
        }
    } catch { return [pscustomobject]@{until=$null;reason='invalid_pause';invalid=$true} }
    return $leases
}
function Get-Hotpl8ActionBlock($Policy, [string]$Directory, [string]$Provider, [string]$Slot, [string]$Kind, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    if (Get-Hotpl8Pause $Directory $Now) { return 'automation_paused' }
    if ($Kind -eq 'switch') { return $null }
    if (-not (Test-Hotpl8WorkTime $Policy.automation.schedule $Now)) { return 'outside_work_hours' }
    if (($Provider + ':' + $Slot) -in @($Policy.automation.warmExcluded)) { return 'account_excluded' }
    $limit = if ($null -ne $Policy.automation.dailyAttemptLimit) { [int]$Policy.automation.dailyAttemptLimit } else { 12 }
    $ledger = Read-Hotpl8Json (Join-Path $Directory 'attempt-budget.json')
    if((Test-Path -LiteralPath (Join-Path $Directory 'attempt-budget.json')) -and -not $ledger){return 'attempt_state_invalid'}
    if($Kind -eq 'warm' -and (Test-Path -LiteralPath (Join-Path $Directory 'warm-outcomes.json')) -and -not (Read-Hotpl8Json (Join-Path $Directory 'warm-outcomes.json'))){return 'warm_state_invalid'}
    $key = $Now.UtcDateTime.ToString('yyyy-MM-dd') + '/' + $Provider + '/' + $Slot
    if ($ledger.$key -ge $limit) { return 'daily_attempt_limit' }
    return $null
}
function Add-Hotpl8Attempt([string]$Directory, [string]$Provider, [string]$Slot, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    $day = $Now.UtcDateTime.ToString('yyyy-MM-dd')
    $path = Join-Path $Directory 'attempt-budget.json'; $old = Read-Hotpl8Json $path; $next = @{}
    foreach ($p in $old.PSObject.Properties) { if ($p.Name.StartsWith($day + '/')) { $next[$p.Name] = [int]$p.Value } }
    $key = $day + '/' + $Provider + '/' + $Slot
    $next[$key] = [int]$next[$key] + 1
    Write-Hotpl8Text $path ($next | ConvertTo-Json)
}
function Assert-Hotpl8AutomationPolicy($Policy) {
    $a = $Policy.automation
    foreach($name in @('disabled','claudeModels')){
        if($null -ne $Policy.$name -and ($Policy.$name -isnot [array] -or @($Policy.$name|Select-Object -Unique).Count -ne @($Policy.$name).Count)){throw ('Invalid array: '+$name)}
        if($null -ne $Policy.$name -and @($Policy.$name|Where-Object {$null -eq $_}).Count){throw ('Null array entry: '+$name)}
    }
    if ($a) {
        if($a -isnot [pscustomobject]){throw 'automation must be an object.'}
        foreach ($field in $a.PSObject.Properties) { if ($field.Name -notin @('schedule','dailyAttemptLimit','warmExcluded')) { throw 'Invalid automation field.' } }
        if ($null -ne $a.dailyAttemptLimit -and (-not (Test-Hotpl8Number $a.dailyAttemptLimit) -or $a.dailyAttemptLimit -lt 1 -or $a.dailyAttemptLimit -gt 100 -or [math]::Floor($a.dailyAttemptLimit) -ne $a.dailyAttemptLimit)) { throw 'dailyAttemptLimit must be an integer from 1 to 100.' }
        if($null -ne $a.warmExcluded -and ($a.warmExcluded -isnot [array] -or @($a.warmExcluded|Select-Object -Unique).Count -ne @($a.warmExcluded).Count)){throw 'warmExcluded must be a unique array.'}
        if($null -ne $a.warmExcluded -and @($a.warmExcluded|Where-Object {$null -eq $_}).Count){throw 'Null warming exclusion.'}
        foreach ($id in @($a.warmExcluded|Where-Object {$null -ne $_})) {
            if($id -isnot [string] -or $id -cnotmatch '^([a-z][a-z0-9-]{0,39}):([a-zA-Z0-9_-]{1,40})$'){throw 'Invalid warming exclusion.'}
            $providerId=$Matches[1];$slotId=$Matches[2]
            $definition=Get-Hotpl8ProviderDefinition $providerId
            $driver=Get-Hotpl8ProviderDriver $definition.driver
            if($driver.slotKind -eq 'numeric' -and $slotId -notmatch '^[0-9]+$'){throw 'Invalid warming exclusion.'}
        }
        if ($a.schedule) {
            $s = $a.schedule
            if($s -isnot [pscustomobject]){throw 'schedule must be an object.'}
            foreach ($field in $s.PSObject.Properties) { if ($field.Name -notin @('start','end','days','timeZone')) { throw 'Invalid schedule field.' } }
            foreach ($t in @($s.start,$s.end)) { if ($t -isnot [string] -or $t -notmatch '^([01][0-9]|2[0-3]):[0-5][0-9]$') { throw 'Work hours must use HH:mm.' } }
            if ($s.days -isnot [array] -or @($s.days).Count -eq 0 -or @($s.days | Select-Object -Unique).Count -ne @($s.days).Count) { throw 'Work days must be a nonempty unique array.' }
            foreach ($d in @($s.days)) { if (-not (Test-Hotpl8Number $d) -or $d -lt 0 -or $d -gt 6 -or [math]::Floor($d) -ne $d) { throw 'Work days must be 0 (Sunday) through 6.' } }
            if ($s.timeZone) { $null = [TimeZoneInfo]::FindSystemTimeZoneById($s.timeZone) }
        }
    }
    foreach ($n in @($Policy.disabled)) { if ($null -ne $n -and $n -notin @($Policy.prefer)) { throw 'Disabled Claude slot must be enrolled.' } }
    foreach ($name in @($Policy.claudeModels|Where-Object {$null -ne $_})) { if ($name -isnot [string] -or $name -notmatch '^[a-zA-Z0-9_-]{1,80}$') { throw 'Invalid Claude scoped model name.' } }
    if ($null -ne $Policy.historyEnabled -and $Policy.historyEnabled -isnot [bool]) { throw 'historyEnabled must be Boolean.' }
    if ($null -ne $Policy.notificationsEnabled -and $Policy.notificationsEnabled -isnot [bool]) { throw 'notificationsEnabled must be Boolean.' }
}
