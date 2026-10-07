# Pure estimates anchored to provider observations, never wall-clock rollover.
function Format-Hotpl8Forecast($Forecast) {
    if (-not $Forecast) { return 'Pace: not enough fresh history' }
    $hours=[math]::Round($Forecast.secondsToLimit/3600,1)
    return ('Weekly pace: '+$Forecast.pace+'; ~'+$hours+'h to limit at cycle-average usage; '+$(if($Forecast.lastsToReset){'likely lasts to reset'}else{'may run out before reset'}))
}
