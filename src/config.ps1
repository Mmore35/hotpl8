# Configuration is validated before provider actions. Legacy policy remains explicit.
function Resolve-Hotpl8StateDirectory([string]$Explicit, [string]$CodeDirectory) {
    if ($Explicit) { return [IO.Path]::GetFullPath($Explicit) }
    if ($env:HOTPL8_STATE_DIRECTORY) { return [IO.Path]::GetFullPath($env:HOTPL8_STATE_DIRECTORY) }
    $installed = Read-Hotpl8Json (Join-Path $CodeDirectory 'install-state.json')
    if ($installed.stateDirectory) { return [IO.Path]::GetFullPath([string]$installed.stateDirectory) }
    # A source checkout is portable, including existing installations.
    return $CodeDirectory
}
function Assert-Hotpl8Policy($Policy) {
    if (-not $Policy -or $Policy -is [array] -or $Policy -isnot [pscustomobject]) { throw 'Invalid policy: expected an object.' }
    if ($null -ne $Policy.schemaVersion -and (-not (Test-Hotpl8Number $Policy.schemaVersion) -or $Policy.schemaVersion -ne 1)) { throw 'Invalid policy: unsupported schemaVersion.' }
    if($Policy.schemaVersion -eq 1){
        $allowed=@('schemaVersion','mode','prefer','reserve','labels','weights','switchEnabled','warm','probeEnabled','order','pattern','margin5h','margin7d','margin7dWork','hysteresis','warmMin7d','warmMin7dWork','maxUsageAgeS','staleQuarantineS','warmFloorMin','warmPhaseWindowMin','warmGroup','resetLeadMin','codex')
        foreach($field in $Policy.PSObject.Properties){if($field.Name -notin $allowed){throw 'Invalid policy: unknown version-1 field.'}}
    }
    if ($Policy.mode -and $Policy.mode -notin @('monitor','automate')) { throw 'Invalid policy: mode must be monitor or automate.' }
    foreach ($key in @('warm','switchEnabled','probeEnabled')) {
        if ($null -ne $Policy.$key -and $Policy.$key -isnot [bool]) { throw ('Invalid policy field: '+$key) }
    }
    if ($Policy.schemaVersion -eq 1 -and (-not $Policy.mode)) { throw 'Invalid policy: schemaVersion 1 requires mode.' }
    foreach ($key in @('margin5h','margin7d','margin7dWork','hysteresis','warmMin7d','warmMin7dWork')) {
        if ($null -ne $Policy.$key -and (-not (Test-Hotpl8Number $Policy.$key) -or $Policy.$key -lt 0 -or $Policy.$key -gt 100)) { throw ('Invalid policy field: '+$key) }
    }
    foreach ($key in @('maxUsageAgeS','staleQuarantineS','warmFloorMin','warmPhaseWindowMin','warmGroup','resetLeadMin')) {
        if ($null -ne $Policy.$key -and (-not (Test-Hotpl8Number $Policy.$key) -or $Policy.$key -lt 0 -or $Policy.$key -gt 604800)) { throw ('Invalid policy field: '+$key) }
    }
    foreach($key in @('maxUsageAgeS','staleQuarantineS','warmFloorMin','warmPhaseWindowMin','warmGroup')){
        if($null -ne $Policy.$key -and $Policy.$key -le 0){throw ('Invalid policy field: '+$key)}
    }
    if ($Policy.order -and $Policy.order -notin @('prefer','soonest-reset')) { throw 'Invalid policy field: order' }
    if ($Policy.pattern -and $Policy.pattern -notin @('maintain','even','clustered','synced')) { throw 'Invalid policy field: pattern' }
    $seen = @{}
    foreach ($n in @($Policy.prefer)) {
        if ($null -eq $n) { continue }
        if (-not (Test-Hotpl8Number $n) -or $n -le 0 -or $n -gt 10000 -or [Math]::Floor($n) -ne $n -or $seen.ContainsKey([string]$n)) { throw 'Invalid policy field: prefer' }
        $seen[[string]$n] = $true
    }
    foreach ($n in @($Policy.reserve)) {
        if ($null -ne $n -and -not $seen.ContainsKey([string]$n)) { throw 'Invalid policy field: reserve' }
    }
    foreach ($p in @($Policy.labels.PSObject.Properties)) {
        if ($p -and ([string]$p.Value -match '[\x00-\x1f\x7f]' -or ([string]$p.Value).Length -gt 80)) { throw 'Invalid policy field: labels' }
    }
    foreach ($p in @($Policy.weights.PSObject.Properties)) {
        if ($p -and (-not (Test-Hotpl8Number $p.Value) -or $p.Value -le 0 -or $p.Value -gt 10000)) { throw 'Invalid policy field: weights' }
    }
}
function Get-Hotpl8Actions($Policy, [bool]$ObserveOnly) {
    # Legacy configs predate mode. Preserve their existing behavior; new examples are monitor-only.
    $enabled = -not $ObserveOnly -and $Policy.mode -ne 'monitor'
    $legacy = $null -eq $Policy.schemaVersion
    return @{
        switching = $enabled -and (($legacy -and $null -eq $Policy.switchEnabled) -or $Policy.switchEnabled -eq $true)
        warming = $enabled -and $Policy.warm -eq $true
        probing = $enabled -and (($legacy -and $null -eq $Policy.probeEnabled) -or $Policy.probeEnabled -eq $true)
    }
}
