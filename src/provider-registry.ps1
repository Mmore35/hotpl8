# Packaged provider definitions are data, never executable modules or commands.
# This file is deliberately independent of config/collection so readers can use
# the same registry without loading a provider or creating a dependency cycle.
function Copy-Hotpl8ProviderValue($Value) {
    # A wrapper plus the unary comma preserves empty and singleton arrays in
    # Windows PowerShell 5.1 without adding extended array properties.
    $wrapper=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject ([pscustomobject]@{item=$Value}) -Depth 32)
    return ,$wrapper.item
}

function Get-Hotpl8ProviderDriver([string]$Id) {
    # These IDs are the reviewed native contracts, not paths from configuration.
    # Adding another native protocol requires an implementation and qualification.
    switch -CaseSensitive ($Id) {
        'claude-cswap' {
            return [pscustomobject]@{
                id=$Id;provider='claude';slotKind='numeric';healthyPollSeconds=60
                meters=@('claude');windows=@(
                    [pscustomobject]@{id='300';minutes=300;required=$true},
                    [pscustomobject]@{id='10080';minutes=10080;required=$true})
                capabilities=[pscustomobject]@{observation=$true;enrollment=$true;selection=$true;nativeLaunch=$false;warming=$true;recoveryProbe=$true;t3Rollover=$false}
                # native names the adapter family; t3 is the host's exact
                # providerInstances.<instance>.driver value, not a display ID.
                integrations=[pscustomobject]@{native='claude';t3='claudeAgent'}
            }
        }
        'codex-app-server' {
            return [pscustomobject]@{
                id=$Id;provider='codex';slotKind='native-home';healthyPollSeconds=300
                meters=@('codex','codex_bengalfox');windows=@(
                    [pscustomobject]@{id='300';minutes=300;required=$false},
                    [pscustomobject]@{id='10080';minutes=10080;required=$false})
                capabilities=[pscustomobject]@{observation=$true;enrollment=$true;selection=$true;nativeLaunch=$true;warming=$false;recoveryProbe=$false;t3Rollover=$true}
                integrations=[pscustomobject]@{native='codex';t3='codex'}
            }
        }
        default { throw 'Unknown provider driver. Only shipped native contracts may be registered.' }
    }
}

function Assert-Hotpl8ProviderObject($Value,[string[]]$Allowed,[string[]]$Required=@()) {
    if($Value -isnot [pscustomobject]){throw 'Invalid provider definition: expected an object.'}
    foreach($p in $Value.PSObject.Properties){if($p.Name -cnotin $Allowed){throw 'Invalid provider definition: unknown field.'}}
    foreach($name in $Required){if(-not $Value.PSObject.Properties[$name]){throw 'Invalid provider definition: missing field.'}}
}

function Test-Hotpl8ProviderNumber($Value) {
    return ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) -and -not [double]::IsNaN([double]$Value) -and -not [double]::IsInfinity([double]$Value)
}

function Assert-Hotpl8ProviderDefinition($Definition) {
    $fields=@('schemaVersion','id','name','driver','defaultMeter','meters','windows','policyDefaults','modelMeters','capabilities','integrations','display')
    Assert-Hotpl8ProviderObject $Definition $fields $fields
    if(-not (Test-Hotpl8ProviderNumber $Definition.schemaVersion) -or $Definition.schemaVersion -ne 1){throw 'Invalid provider definition version.'}
    if($Definition.id -isnot [string] -or $Definition.id -cnotmatch '^[a-z][a-z0-9-]{0,39}$'){throw 'Invalid provider ID.'}
    if($Definition.name -isnot [string] -or -not $Definition.name.Trim() -or $Definition.name.Length -gt 80 -or $Definition.name -match '[\x00-\x1f\x7f]'){throw 'Invalid provider display name.'}
    if($Definition.driver -isnot [string]){throw 'Invalid provider driver.'}
    $driver=Get-Hotpl8ProviderDriver $Definition.driver
    if(($Definition.id -ceq 'claude' -and $driver.provider -cne 'claude') -or ($Definition.id -ceq 'codex' -and $driver.provider -cne 'codex')){throw 'Legacy provider IDs must retain their native driver.'}
    if($Definition.meters -isnot [array] -or -not $Definition.meters.Count -or $Definition.meters.Count -gt 8){throw 'Invalid provider meters.'}
    $seen=@{}
    foreach($meter in $Definition.meters){
        if($meter -isnot [string] -or $meter -cnotin $driver.meters -or $seen.ContainsKey($meter)){throw 'Unsupported or duplicate provider meter.'}
        $seen[$meter]=$true
    }
    if($Definition.defaultMeter -isnot [string] -or $Definition.defaultMeter -cnotin $Definition.meters){throw 'Invalid provider default meter.'}
    # A definition may narrow supported meters but cannot weaken window evidence.
    if($Definition.windows -isnot [array] -or $Definition.windows.Count -ne $driver.windows.Count){throw 'Invalid provider windows.'}
    $seen=@{}
    foreach($window in $Definition.windows){
        Assert-Hotpl8ProviderObject $window @('id','minutes','required') @('id','minutes','required')
        $native=@($driver.windows|Where-Object id -CEQ $window.id)
        if($window.id -isnot [string] -or $native.Count -ne 1 -or $seen.ContainsKey($window.id) -or -not (Test-Hotpl8ProviderNumber $window.minutes) -or $window.minutes -ne $native[0].minutes -or $window.required -isnot [bool] -or $window.required -ne $native[0].required){throw 'Provider windows do not match the native contract.'}
        $seen[$window.id]=$true
    }
    Assert-Hotpl8ProviderObject $Definition.policyDefaults @('order','margin5h','margin7d','margin7dWork','hysteresis','resetLeadMin')
    foreach($p in $Definition.policyDefaults.PSObject.Properties){
        if($p.Name -eq 'order'){
            if($p.Value -isnot [string] -or $p.Value -cnotin @('prefer','soonest-reset','weekly-expiry','balanced')){throw 'Invalid provider default ordering.'}
        }else{
            $max=if($p.Name -eq 'resetLeadMin'){604800}else{100}
            if(-not (Test-Hotpl8ProviderNumber $p.Value) -or $p.Value -lt 0 -or $p.Value -gt $max){throw 'Invalid provider default threshold.'}
        }
    }
    if($Definition.modelMeters -isnot [pscustomobject] -or @($Definition.modelMeters.PSObject.Properties).Count -gt 256){throw 'Invalid provider model mappings.'}
    foreach($p in $Definition.modelMeters.PSObject.Properties){
        if($p.Name -cnotmatch '^[a-zA-Z0-9_.-]{1,100}$' -or $p.Value -isnot [string] -or $p.Value -cnotin $Definition.meters){throw 'Invalid provider model mapping.'}
    }
    $capabilities=@($driver.capabilities.PSObject.Properties|ForEach-Object Name)
    Assert-Hotpl8ProviderObject $Definition.capabilities $capabilities $capabilities
    foreach($p in $Definition.capabilities.PSObject.Properties){
        if($p.Value -isnot [bool] -or ($p.Value -and -not $driver.capabilities.($p.Name))){throw 'Provider capability is not implemented by its driver.'}
    }
    Assert-Hotpl8ProviderObject $Definition.integrations @('native','t3')
    foreach($p in $Definition.integrations.PSObject.Properties){
        if($p.Value -isnot [string] -or $p.Value -cne $driver.integrations.($p.Name)){throw 'Provider integration does not match the native driver.'}
    }
    if($Definition.capabilities.t3Rollover -and -not $Definition.integrations.t3){throw 'T3 rollover requires a supported T3 integration.'}
    Assert-Hotpl8ProviderObject $Definition.display @('order') @('order')
    if(-not (Test-Hotpl8ProviderNumber $Definition.display.order) -or $Definition.display.order -lt 0 -or $Definition.display.order -gt 10000 -or [math]::Floor($Definition.display.order) -ne $Definition.display.order){throw 'Invalid provider display ordering.'}
}

function Get-Hotpl8ProviderCatalog([string]$Directory=(Join-Path (Split-Path $PSScriptRoot -Parent) 'data/providers')) {
    if(-not (Test-Path -LiteralPath $Directory -PathType Container)){throw 'Packaged provider catalog is missing.'}
    $files=@(Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File)
    if(-not $files.Count -or $files.Count -gt 32){throw 'Invalid provider catalog size.'}
    $definitions=@();$seen=@{}
    foreach($file in $files){
        if($file.Length -gt 131072){throw 'Provider definition exceeds size limit.'}
        try{$definition=[IO.File]::ReadAllText($file.FullName)|ConvertFrom-Json -ErrorAction Stop}catch{throw 'Invalid provider definition JSON.'}
        Assert-Hotpl8ProviderDefinition $definition
        if($file.BaseName -cne $definition.id -or $seen.ContainsKey($definition.id)){throw 'Duplicate provider ID or mismatched definition filename.'}
        $seen[$definition.id]=$true;$definitions+=@($definition)
    }
    return @($definitions|Sort-Object @{Expression={$_.display.order}},id)
}

function Get-Hotpl8ProviderDefinition([string]$Id,$Catalog=$null) {
    if($null -eq $Catalog){$Catalog=@(Get-Hotpl8ProviderCatalog)}
    $matches=@($Catalog|Where-Object id -CEQ $Id)
    if($matches.Count -ne 1){throw 'Provider is not registered.'}
    Assert-Hotpl8ProviderDefinition $matches[0]
    return (Copy-Hotpl8ProviderValue $matches[0])
}

function Get-Hotpl8ProviderControls($Policy) {
    $controls=[ordered]@{}
    foreach($name in @('schemaVersion','mode','switchEnabled','warm','probeEnabled','automation')){
        if($Policy.PSObject.Properties[$name]){$controls[$name]=Copy-Hotpl8ProviderValue $Policy.$name}
    }
    return [pscustomobject]$controls
}

function Get-Hotpl8ConfiguredProviders($Policy,$Catalog=$null,[switch]$IncludeUnconfigured) {
    if($Policy -isnot [pscustomobject]){throw 'Provider configuration requires a policy object.'}
    if($Policy.PSObject.Properties['schemaVersion'] -and (-not (Test-Hotpl8ProviderNumber $Policy.schemaVersion) -or $Policy.schemaVersion -notin @(1,2,3))){throw 'Unsupported provider policy version.'}
    if($null -eq $Catalog){$Catalog=@(Get-Hotpl8ProviderCatalog)}
    $seen=@{}
    foreach($definition in @($Catalog)){
        Assert-Hotpl8ProviderDefinition $definition
        if($seen.ContainsKey($definition.id)){throw 'Duplicate provider ID.'}
        $seen[$definition.id]=$true
    }
    $configured=@{}
    if($Policy.schemaVersion -eq 3){
        if($Policy.providers -isnot [pscustomobject]){throw 'Policy version 3 requires a providers map.'}
        # Reject even empty legacy fields: there must be one unambiguous owner.
        $legacy=@('prefer','reserve','labels','weights','disabled','claudeModels','capacity','critical','codex','order','pattern','margin5h','margin7d','margin7dWork','hysteresis','warmMin7d','warmMin7dWork','maxUsageAgeS','staleQuarantineS','warmFloorMin','warmPhaseWindowMin','warmGroup','resetLeadMin')
        if(@($Policy.PSObject.Properties|Where-Object {$_.Name -in $legacy}).Count){throw 'Policy version 3 cannot mix legacy and registered provider settings.'}
        if(@($Policy.providers.PSObject.Properties).Count -gt 32){throw 'Too many configured providers.'}
        foreach($entry in $Policy.providers.PSObject.Properties){
            $definition=Get-Hotpl8ProviderDefinition $entry.Name $Catalog
            if($entry.Value -isnot [pscustomobject]){throw 'Provider policy must be an object.'}
            $part=Copy-Hotpl8ProviderValue $definition.policyDefaults
            foreach($p in $entry.Value.PSObject.Properties){$part|Add-Member NoteProperty $p.Name (Copy-Hotpl8ProviderValue $p.Value) -Force}
            $driver=Get-Hotpl8ProviderDriver $definition.driver
            if($driver.provider -eq 'codex'){
                if(-not $part.PSObject.Properties['defaultMeter']){$part|Add-Member NoteProperty defaultMeter $definition.defaultMeter}
                $models=Copy-Hotpl8ProviderValue $definition.modelMeters
                if($part.PSObject.Properties['modelMeters'] -and $part.modelMeters -isnot [pscustomobject]){throw 'Provider model mappings must be an object.'}
                foreach($m in $part.modelMeters.PSObject.Properties){$models|Add-Member NoteProperty $m.Name (Copy-Hotpl8ProviderValue $m.Value) -Force}
                $part|Add-Member NoteProperty modelMeters $models -Force
                if($part.defaultMeter -isnot [string] -or $part.defaultMeter -cnotin $definition.meters){throw 'Configured meter is not supported by the provider definition.'}
                foreach($m in $part.modelMeters.PSObject.Properties){if($m.Value -isnot [string] -or $m.Value -cnotin $definition.meters){throw 'Configured model meter is not supported by the provider definition.'}}
            }
            $configured[$entry.Name]=$part
        }
    }else{
        if($Policy.PSObject.Properties['providers']){throw 'Registered provider configuration requires policy version 3.'}
        if($Policy.PSObject.Properties['prefer']){$configured['claude']=Copy-Hotpl8ProviderValue $Policy}
        if($Policy.PSObject.Properties['codex']){
            if($Policy.codex -isnot [pscustomobject]){throw 'Codex policy must be an object.'}
            $configured['codex']=Copy-Hotpl8ProviderValue $Policy.codex
        }
        foreach($id in @($configured.Keys)){if(-not $seen.ContainsKey($id)){throw 'Configured legacy provider is missing from the catalog.'}}
    }
    foreach($definition in @($Catalog|Sort-Object @{Expression={$_.display.order}},id)){
        if(-not $configured.ContainsKey($definition.id) -and -not $IncludeUnconfigured){continue}
        Assert-Hotpl8ProviderDefinition $definition
        $part=if($configured.ContainsKey($definition.id)){$configured[$definition.id]}else{$null}
        [pscustomobject]@{
            id=$definition.id;name=$definition.name;driver=$definition.driver
            definition=(Copy-Hotpl8ProviderValue $definition);policy=$part
            controls=(Get-Hotpl8ProviderControls $Policy)
            configured=$configured.ContainsKey($definition.id);isLegacy=($Policy.schemaVersion -ne 3)
        }
    }
}
