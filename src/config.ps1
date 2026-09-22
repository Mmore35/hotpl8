# Configuration is validated before provider actions. Legacy policy remains explicit.
. (Join-Path $PSScriptRoot 'automation.ps1')
. (Join-Path $PSScriptRoot 'capacity.ps1')
. (Join-Path $PSScriptRoot 'critical.ps1')
. (Join-Path $PSScriptRoot 'provider-registry.ps1')
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
    if($Policy.schemaVersion -eq 3 -and (Test-Hotpl8Number $Policy.schemaVersion)){
        $allowed=@('schemaVersion','mode','providers','switchEnabled','warm','probeEnabled','automation','historyEnabled','notificationsEnabled','display')
        foreach($field in $Policy.PSObject.Properties){if($field.Name -cnotin $allowed){throw 'Invalid version 3 policy field.'}}
        if($Policy.mode -cnotin @('monitor','automate')){throw 'Invalid policy: version 3 requires mode.'}
        $control=Copy-Hotpl8ProviderValue $Policy;$control.PSObject.Properties.Remove('providers');$control.schemaVersion=2
        Assert-Hotpl8Policy $control
        $nativeHomes=@{};$globalOwners=0
        foreach($r in @(Get-Hotpl8ConfiguredProviders $Policy)){
            $driver=Get-Hotpl8ProviderDriver $r.driver
            $view=Get-Hotpl8ProviderView $null $Policy $r.id
            if($driver.provider -eq 'claude'){
                foreach($key in @('schemaVersion','mode','switchEnabled','warm','probeEnabled','automation','historyEnabled','notificationsEnabled','display','providers','codex')){if($r.policy.PSObject.Properties[$key]){throw 'Provider policy contains a global or foreign setting.'}}
                Assert-Hotpl8Policy $view.policy
                if(@($r.policy.prefer|Where-Object {$null -ne $_}).Count){$globalOwners++}
            }else{
                # Load only the shipped reviewed validator, never a path from data.
                if(-not (Get-Command Assert-CodexPolicy -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'providers/codex.ps1')}
                Assert-CodexPolicy $r.policy
                foreach($slot in @($r.policy.slots)){
                    $homeKey=[IO.Path]::GetFullPath([string]$slot.home).TrimEnd('\','/').ToLowerInvariant()
                    if($nativeHomes.ContainsKey($homeKey)){throw 'Native account home is enrolled under more than one provider.'}
                    $nativeHomes[$homeKey]=$true
                }
            }
            if(-not $r.definition.capabilities.warming -and $r.policy.warm){throw 'Provider does not support warming.'}
        }
        if($globalOwners -gt 1){throw 'The native global activation driver supports only one configured provider owner.'}
        return
    }
    if ($null -ne $Policy.schemaVersion -and (-not (Test-Hotpl8Number $Policy.schemaVersion) -or $Policy.schemaVersion -notin @(1,2))) { throw 'Invalid policy: unsupported schemaVersion.' }
    $v2Fields=@('automation','disabled','claudeModels','historyEnabled','notificationsEnabled','capacity','critical','display')
    if($Policy.schemaVersion -ne 2 -and @($Policy.PSObject.Properties|Where-Object {$_.Name -in $v2Fields}).Count){throw 'New operational settings require schemaVersion 2.'}
    if($Policy.schemaVersion -in @(1,2)){
        $allowed=@('schemaVersion','mode','prefer','reserve','labels','weights','switchEnabled','warm','probeEnabled','order','pattern','margin5h','margin7d','margin7dWork','hysteresis','warmMin7d','warmMin7dWork','maxUsageAgeS','staleQuarantineS','warmFloorMin','warmPhaseWindowMin','warmGroup','resetLeadMin','codex')
        if($Policy.schemaVersion -eq 2){$allowed+=@('automation','disabled','claudeModels','historyEnabled','notificationsEnabled','capacity','critical','display');Assert-Hotpl8AutomationPolicy $Policy}
        foreach($field in $Policy.PSObject.Properties){if($field.Name -notin $allowed){throw 'Invalid policy: unknown versioned field.'}}
    }
    if($Policy.schemaVersion -ne 2 -and ($Policy.codex.capacity -or $Policy.codex.critical)){throw 'Capacity and critical settings require schemaVersion 2.'}
    if ($Policy.mode -and $Policy.mode -notin @('monitor','automate')) { throw 'Invalid policy: mode must be monitor or automate.' }
    foreach ($key in @('warm','switchEnabled','probeEnabled')) {
        if ($null -ne $Policy.$key -and $Policy.$key -isnot [bool]) { throw ('Invalid policy field: '+$key) }
    }
    if ($Policy.schemaVersion -in @(1,2) -and (-not $Policy.mode)) { throw 'Invalid policy: versioned policy requires mode.' }
    foreach ($key in @('margin5h','margin7d','margin7dWork','hysteresis','warmMin7d','warmMin7dWork')) {
        if ($null -ne $Policy.$key -and (-not (Test-Hotpl8Number $Policy.$key) -or $Policy.$key -lt 0 -or $Policy.$key -gt 100)) { throw ('Invalid policy field: '+$key) }
    }
    foreach ($key in @('maxUsageAgeS','staleQuarantineS','warmFloorMin','warmPhaseWindowMin','warmGroup','resetLeadMin')) {
        if ($null -ne $Policy.$key -and (-not (Test-Hotpl8Number $Policy.$key) -or $Policy.$key -lt 0 -or $Policy.$key -gt 604800)) { throw ('Invalid policy field: '+$key) }
    }
    foreach($key in @('maxUsageAgeS','staleQuarantineS','warmFloorMin','warmPhaseWindowMin','warmGroup')){
        if($null -ne $Policy.$key -and $Policy.$key -le 0){throw ('Invalid policy field: '+$key)}
    }
    if ($Policy.order -and $Policy.order -notin @('prefer','soonest-reset','weekly-expiry','balanced')) { throw 'Invalid policy field: order' }
    if($Policy.schemaVersion -ne 2 -and ($Policy.order -in @('weekly-expiry','balanced') -or $Policy.codex.order -in @('weekly-expiry','balanced') -or ($null -ne $Policy.codex -and $Policy.codex.PSObject.Properties['disabled']))){throw 'New selection options require policy version 2.'}
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
    Assert-Hotpl8CapacityPolicy $Policy
    Assert-Hotpl8CriticalPolicy $Policy
    if($Policy.display){foreach($f in $Policy.display.PSObject.Properties){if($f.Name -notin @('reducedMotion','noColor') -or $f.Value -isnot [bool]){throw 'Invalid display setting.'}}}
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
