# Pure estimates anchored to provider observations, never wall-clock rollover.
function Get-Hotpl8Forecast($Used, $ResetAt, $ObservedAt, [int]$Minutes = 10080, [datetimeoffset]$Now = [datetimeoffset]::UtcNow, $Samples = @()) {
    if (-not (Test-Hotpl8Number $Used) -or $Used -le 0 -or $Used -gt 100) { return $null }
    try { $at=[datetimeoffset]::Parse([string]$ObservedAt); $reset=[datetimeoffset]::Parse([string]$ResetAt) } catch { return $null }
    $age=($Now-$at).TotalSeconds; $elapsed=$Minutes*60-($reset-$at).TotalSeconds
    if ($age -lt -5 -or $age -gt 900 -or $reset -le $Now -or $elapsed -lt $(if($Minutes -eq 10080){86400}else{900}) -or $elapsed -gt $Minutes*60) { return $null }
    $expected=100*$elapsed/($Minutes*60); $rate=[double]$Used/$elapsed
    $estimate=if($rate -gt 0){(100-[double]$Used)/$rate}else{$null}
    $recent=$null
    $valid=@($Samples | Where-Object {
        try{$sampleAt=[datetimeoffset]::Parse($_.observedAt);$_.resetAt -eq $ResetAt -and (Test-Hotpl8Number $_.used) -and $_.used -ge 0 -and $_.used -le $Used -and $sampleAt -le $at -and $sampleAt -ge $at.AddHours(-6)}catch{$false}
    } | Sort-Object observedAt)
    if ($valid.Count -ge 3) {
        $first=$valid[0]; $span=($at-[datetimeoffset]::Parse($first.observedAt)).TotalSeconds
        $delta=[double]$Used-[double]$first.used
        if ($span -ge 1800 -and $span -le 21600 -and $delta -gt 0) { $recent=(100-[double]$Used)/($delta/$span) }
    }
    return [pscustomobject]@{observedAt=$at.ToString('o');expectedUsed=[math]::Round($expected,1);used=[double]$Used;pace=$(if($Used-$expected -ge 10){'ahead'}elseif($expected-$Used -ge 10){'behind'}else{'on track'});secondsToLimit=[math]::Round($estimate);lastsToReset=($estimate -ge ($reset-$at).TotalSeconds);recentSecondsToLimit=$recent;basis='cycle-average';confidence='estimate'}
}
function Format-Hotpl8Forecast($Forecast) {
    if (-not $Forecast) { return 'Pace: not enough fresh history' }
    $hours=[math]::Round($Forecast.secondsToLimit/3600,1)
    return ('Weekly pace: '+$Forecast.pace+'; ~'+$hours+'h to limit at cycle-average usage; '+$(if($Forecast.lastsToReset){'likely lasts to reset'}else{'may run out before reset'}))
}
function Update-Hotpl8History([string]$Directory, $Rows, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    $path=Join-Path $Directory 'usage-history.json'; $old=Read-Hotpl8Json $path
    $kept=@($old.samples | Where-Object { try { $time=[datetimeoffset]::Parse($_.observedAt);$time -gt $Now.AddDays(-14) -and $time -le $Now.AddSeconds(5) -and (Test-Hotpl8Number $_.used) -and $_.used -ge 0 -and $_.used -le 100 } catch { $false } })
    foreach ($row in @($Rows)) {
        $last=@($kept | Where-Object key -EQ $row.key | Sort-Object observedAt | Select-Object -Last 1)
        if (-not $last.Count -or $last[0].resetAt -ne $row.resetAt -or ([datetimeoffset]::Parse($row.observedAt)-[datetimeoffset]::Parse($last[0].observedAt)).TotalMinutes -ge 30) { $kept+=@($row) }
    }
    $kept=@($kept | Sort-Object observedAt | Select-Object -Last 4096)
    Write-Hotpl8Text $path (@{schemaVersion=1;samples=$kept}|ConvertTo-Json -Depth 8)
    return ,$kept
}
