# What hotpl8 doctor says, in words, of the facts the compiled program gathers (rules.ps1).
function Format-Hotpl8Doctor($Report,$ParkCandidates=@()) {
    # Human guidance is separate from the stable, allowlisted JSON contract.
    'HotPl8 ' + $Report.version + ' | PowerShell ' + $Report.runtime
    if (-not $Report.policyPresent) {
        'SETUP NEEDED: run hotpl8 setup to connect your first account.'
        return
    }
    if (-not $Report.policyValid) {
        'POLICY INVALID: check policy.json against docs/configuration.md. Your file was not changed.'
        return
    }
    'Mode: ' + $Report.mode
    if (-not $Report.claudeConfigured -and -not $Report.codexConfigured -and -not @($Report.providers.PSObject.Properties|Where-Object {$_.Value.configured}).Count) {
        'NO ACCOUNTS: run hotpl8 setup, or ask your agent to add an account.'
        'HotPl8 reuses a native sign-in or opens provider login, then reads usage.'
        return
    }
    $dependenciesReady = $true
    if ($Report.codexConfigured) {
        if ($Report.codexFound) { 'Codex: enrolled; native CLI found.' }
        else {
            'CODEX MISSING: run hotpl8 setup -Provider codex to prepare the integration.'
            $dependenciesReady = $false
        }
    }
    if ($Report.claudeConfigured) {
        if ($Report.cswapFound) { 'Claude: configured; cswap found (experimental adapter).' }
        else {
            'CSWAP MISSING: run hotpl8 setup -Provider claude to prepare the integration.'
            $dependenciesReady = $false
        }
    }
    foreach($entry in $Report.providers.PSObject.Properties){
        if($entry.Name -in @('claude','codex') -or -not $entry.Value.configured){continue}
        $name=(Get-Hotpl8ProviderDefinition $entry.Name).name
        if($entry.Value.installed){$name+': enrolled; native driver found.'}
        else{$name+': enrolled; native driver unavailable. See docs/install.md.';$dependenciesReady=$false}
    }
    if ($Report.collectorBusy) {
        'COLLECTOR BUSY: wait for the current collection; do not delete its lock.'
    } elseif ($dependenciesReady) {
        if ($null -eq $Report.snapshotAgeSeconds) {
            'NO READING: run hotpl8 refresh, then hotpl8.'
        } elseif (-not $Report.snapshotFresh) {
            'STALE READING: run hotpl8 refresh before relying on the dashboard.'
        } else {
            'Recent snapshot found. Run hotpl8 to view per-account status.'
        }
    }
    foreach($candidate in @($ParkCandidates|Where-Object {$_})){
        'PARK CANDIDATE: '+$candidate.label+' ('+$candidate.providerName+'), '+(Format-Hotpl8ParkReason $candidate)+'.'
    }
    if(@($ParkCandidates|Where-Object {$_}).Count){'Sign in again to keep an account, or run hotpl8 park to set it aside until it returns.'}
    if($Report.continue){
        'Automatic continue: '+$(if($Report.continue.enabled){'on'}else{'off'})+' | Claude hook '+$(if($Report.continue.hookPresent){'present'}else{'absent'})+' | last sent '+$(if($Report.continue.lastAt){$Report.continue.lastAt}else{'never'})
    }
    'Doctor is offline: native login and quota availability are checked by hotpl8 refresh.'
}
