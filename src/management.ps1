. (Join-Path $PSScriptRoot 'rules.ps1')
. (Join-Path $PSScriptRoot 'provider-actions.ps1')
. (Join-Path $PSScriptRoot 'delivery-policy.ps1')
. (Join-Path $PSScriptRoot 'parking.ps1')
function ConvertTo-Hotpl8PolicyV2($Policy) {
    $next=$Policy|ConvertTo-Json -Depth 24|ConvertFrom-Json
    if($Policy.schemaVersion -eq 3){return $next}
    # Freeze legacy defaults before assigning a version, so migration cannot enable actions.
    $actions=Get-Hotpl8Actions $next $false
    if(-not $next.mode){$next|Add-Member NoteProperty mode 'automate' -Force}
    if($null -eq $next.switchEnabled){$next|Add-Member NoteProperty switchEnabled ([bool]$actions.switching) -Force}
    if($null -eq $next.probeEnabled){$next|Add-Member NoteProperty probeEnabled ([bool]$actions.probing) -Force}
    $next|Add-Member NoteProperty schemaVersion 2 -Force
    return $next
}
function Save-Hotpl8Policy([string]$Directory, $Policy, [string]$ExpectedHash) {
    Assert-Hotpl8Policy $Policy
    if($Policy.codex){Assert-CodexPolicy $Policy.codex}
    $path=Join-Path $Directory 'policy.json';$lock=$null
    try{
        $lock=[IO.File]::Open((Join-Path $Directory 'tick.lock'),'OpenOrCreate','ReadWrite','None')
        Invoke-Hotpl8ControlWrite $Directory {
            if($ExpectedHash -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $ExpectedHash){throw 'Policy changed; reload before saving.'}
            Assert-Hotpl8PolicyDeliveryCompatibility $Directory $Policy
            if(Test-Path -LiteralPath $path){Write-Hotpl8Text (Join-Path $Directory 'policy.previous.json') ([IO.File]::ReadAllText($path))}
            Write-Hotpl8Text $path ($Policy|ConvertTo-Json -Depth 24)
        }
    }finally{if($lock){$lock.Dispose()}}
}
function ConvertTo-Hotpl8PolicyV3($Policy) {
    Assert-Hotpl8Policy $Policy
    if($Policy.schemaVersion -eq 3){return (Copy-Hotpl8ProviderValue $Policy)}
    $actions=Get-Hotpl8Actions $Policy $false
    $next=[pscustomobject]@{schemaVersion=3;mode=$(if($Policy.mode){$Policy.mode}else{'automate'});switchEnabled=[bool]$actions.switching;warm=[bool]$actions.warming;probeEnabled=[bool]$actions.probing;providers=[pscustomobject]@{}}
    foreach($key in @('automation','historyEnabled','notificationsEnabled','display')){if($Policy.PSObject.Properties[$key]){$next|Add-Member NoteProperty $key (Copy-Hotpl8ProviderValue $Policy.$key)}}
    foreach($r in @(Get-Hotpl8ConfiguredProviders $Policy)){
        $part=Copy-Hotpl8ProviderValue $r.policy;$driver=Get-Hotpl8ProviderDriver $r.driver
        foreach($key in @('schemaVersion','mode','switchEnabled','warm','probeEnabled','automation','historyEnabled','notificationsEnabled','display','codex')){$part.PSObject.Properties.Remove($key)}
        # Freeze the old reader's missing-value semantics before defaults apply.
        $defaults=if($driver.provider -eq 'claude'){@{order='prefer';margin5h=0;margin7d=20;hysteresis=0;resetLeadMin=10}}else{@{order='prefer';margin5h=25;margin7d=20;hysteresis=10;resetLeadMin=10}}
        foreach($key in $defaults.Keys){if($null -eq $part.$key){$part|Add-Member NoteProperty $key $defaults[$key] -Force}}
        $next.providers|Add-Member NoteProperty $r.id $part
    }
    Assert-Hotpl8Policy $next
    return $next
}

function Add-Hotpl8RegisteredAccount([string]$Directory,[string]$Provider,[string]$Slot,[string]$AccountHome,[string]$Label,[string]$Executable,[switch]$MigratePolicy,[switch]$KeepLabel) {
    # Setup, enroll and unpark share this entry, so an account that returns by
    # any of them gets its parked settings back instead of starting over.
    $known=Test-Hotpl8AccountEnrolled $Directory $Provider $Slot
    Add-Hotpl8RegisteredAccountCore $Directory $Provider $Slot $AccountHome $Label $Executable -MigratePolicy:$MigratePolicy
    if(-not $known -and (Test-Hotpl8AccountEnrolled $Directory $Provider $Slot)){
        # The enrollment above is complete; a failed restore must not undo or hide it.
        try{Restore-Hotpl8ParkedAccount $Directory $Provider $Slot $AccountHome $Executable -KeepLabel:$KeepLabel}
        catch{'The account is enrolled. Its parked settings could not be restored and remain saved.'}
    }
}
function Add-Hotpl8RegisteredAccountCore([string]$Directory,[string]$Provider,[string]$Slot,[string]$AccountHome,[string]$Label,[string]$Executable,[switch]$MigratePolicy) {
    $definition=Get-Hotpl8ProviderDefinition $Provider;$driver=Get-Hotpl8ProviderDriver $definition.driver
    if(-not $definition.capabilities.enrollment){throw 'Provider enrollment is unavailable.'}
    $path=Join-Path $Directory 'policy.json';$hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $policy=Read-Hotpl8Json $path;Assert-Hotpl8Policy $policy
    if($policy.schemaVersion -ne 3 -and $Provider -cne $driver.provider){
        if(-not $MigratePolicy){
            [pscustomobject]@{operation='policy-migration-preview';currentVersion=$policy.schemaVersion;targetVersion=3;provider=$Provider;changes=@('Move existing provider policy into providers map; preserve account homes and action settings.','Add explicitly enrolled account only after native identity validation.');next='Rerun enrollment with -MigratePolicy to accept this schema migration.'}
            return
        }
        $policy=ConvertTo-Hotpl8PolicyV3 $policy
    }
    if($policy.schemaVersion -ne 3){
        if($driver.slotKind -eq 'numeric'){Add-Hotpl8ClaudeAccount $Directory $Slot $Label;return}
        & (Join-Path (Split-Path $PSScriptRoot -Parent) 'setup-codex.ps1') -Slot $Slot -AccountHome $AccountHome -Label $Label -StateDirectory $Directory -CodexExecutable $Executable
        return
    }
    if(-not $policy.providers.PSObject.Properties[$Provider]){
        $part=Copy-Hotpl8ProviderValue $definition.policyDefaults
        $part|Add-Member NoteProperty prefer @();$part|Add-Member NoteProperty reserve @()
        if($driver.slotKind -eq 'numeric'){$part|Add-Member NoteProperty labels ([pscustomobject]@{})}
        else{$part|Add-Member NoteProperty slots @();$part|Add-Member NoteProperty defaultMeter $definition.defaultMeter}
        $policy.providers|Add-Member NoteProperty $Provider $part
    }
    $part=$policy.providers.$Provider
    if($driver.slotKind -eq 'numeric'){
        if($Slot -notmatch '^[1-9][0-9]{0,3}$' -or $AccountHome){throw 'This driver enrolls an existing native numeric account, without an account home.'}
        if([int]$Slot -in @($part.prefer)){'Account already enrolled; policy unchanged.';return}
        $exe=Resolve-CswapExecutable $Executable;if(-not $exe){throw 'Native account manager is not installed.'}
        $read=Invoke-Hotpl8Process $exe @('list','--json') (Get-CswapReadTimeoutMs)
        if($read.exitCode -ne 0){throw 'Native account inventory is unavailable.'}
        $data=$read.output|ConvertFrom-Json
        if($data.schemaVersion -ne 1 -or @($data.accounts|Where-Object number -EQ ([int]$Slot)).Count -ne 1){throw 'Account not found in native inventory.'}
        $part.prefer=@($part.prefer)+@([int]$Slot)
        if($Label){if(-not $part.labels){$part|Add-Member NoteProperty labels ([pscustomobject]@{})};$part.labels|Add-Member NoteProperty $Slot $Label -Force}
    }else{
        if($Slot -notmatch '^[a-zA-Z0-9_-]{1,40}$' -or -not [IO.Path]::IsPathRooted($AccountHome)){throw 'Enrollment requires a slot ID and an absolute native home.'}
        $homePath=[IO.Path]::GetFullPath($AccountHome)
        $existing=@($part.slots|Where-Object id -CEQ $Slot)
        if($existing.Count){
            if($existing.Count -ne 1 -or [IO.Path]::GetFullPath([string]$existing[0].home) -ne $homePath){throw 'Slot already refers to a different native home.'}
            'Account already enrolled; policy unchanged.';return
        }
        $read=Read-CodexQuota $homePath $Executable 5000
        if($read.status -ne 'ok' -or -not $read.standardTransport -or ($read.modelProvider -and $read.modelProvider -ne 'openai')){throw 'Native subscription identity or transport is not ready for enrollment.'}
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $peerSlots=@(Get-Hotpl8ConfiguredProviders $policy|Where-Object driver -CEQ $definition.driver|ForEach-Object {$_.policy.slots}|Where-Object {$_})
        foreach($other in $peerSlots){
            if($clock.ElapsedMilliseconds -ge 20000){throw 'Native enrollment verification budget exceeded.'}
            $peer=Read-CodexQuota $other.home $Executable ([math]::Min(5000,20000-$clock.ElapsedMilliseconds))
            if($peer.status -ne 'ok'){throw 'Cannot verify an existing native account.'}
            if($peer.identityKey -eq $read.identityKey){throw 'Subscription is already enrolled.'}
        }
        $part.slots=@($part.slots)+@([pscustomobject]@{id=$Slot;home=$homePath;label=$(if($Label){$Label}else{$Slot})})
        $part.prefer=@($part.prefer)+@($Slot)
    }
    Save-Hotpl8Policy $Directory $policy $hash
    'Account enrolled. Native credentials and configured action settings were preserved.'
}
function Set-Hotpl8Account($Policy, [string]$Provider, [string]$Slot, [string]$Operation, [string]$Label) {
    $next=if($Policy.schemaVersion -ne 3 -and $Operation -in @('disable','enable','capacity')){ConvertTo-Hotpl8PolicyV2 $Policy}else{Copy-Hotpl8ProviderValue $Policy}
    $record=Get-Hotpl8ConfiguredProvider $next $Provider
    $driver=Get-Hotpl8ProviderDriver $record.driver
    $part=if($next.schemaVersion -eq 3){$next.providers.$Provider}elseif($driver.provider -eq 'claude'){$next}else{$next.codex}
    if($driver.slotKind -eq 'numeric'){
        if($Slot -notmatch '^[1-9][0-9]{0,3}$' -or [int]$Slot -notin @($part.prefer)){throw 'Unknown native account slot.'}
        $id=[int]$Slot
        if($Operation -eq 'rename'){
            if(-not $part.labels){$part|Add-Member NoteProperty labels ([pscustomobject]@{}) -Force}
            $part.labels|Add-Member NoteProperty $Slot $Label -Force
        }
    }else{
        $id=$Slot;$matches=@($part.slots|Where-Object id -CEQ $Slot)
        if($matches.Count -ne 1){throw 'Unknown native account slot.'}
        if($Operation -eq 'rename'){$matches[0]|Add-Member NoteProperty label $Label -Force}
    }
    switch($Operation){
        'disable'{$part|Add-Member NoteProperty disabled @(@($part.disabled|Where-Object {$_})+@($id)|Select-Object -Unique) -Force}
        'enable'{$part|Add-Member NoteProperty disabled @($part.disabled|Where-Object {$_ -ne $id}) -Force}
        'reserve'{$part|Add-Member NoteProperty reserve @(@($part.reserve|Where-Object {$_})+@($id)|Select-Object -Unique) -Force}
        'work'{$part|Add-Member NoteProperty reserve @($part.reserve|Where-Object {$_ -ne $id}) -Force}
        'remove'{
            foreach($key in @('prefer','reserve','disabled')){if($part.PSObject.Properties[$key]){$part.$key=@($part.$key|Where-Object {$_ -ne $id})}}
            if($driver.slotKind -ne 'numeric'){$part.slots=@($part.slots|Where-Object id -CNE $Slot)}
            foreach($key in @('labels','weights','capacity')){if($part.$key){$part.$key.PSObject.Properties.Remove($Slot)}}
        }
    }
    return $next
}
function Set-Hotpl8Pause([string]$Directory, [int]$Minutes, [string]$Reason) {
    $lock=$null
    try{
        $lock=[IO.File]::Open((Join-Path $Directory 'tick.lock'),'OpenOrCreate','ReadWrite','None')
        $pause=@{schemaVersion=1;until=[datetimeoffset]::UtcNow.AddMinutes($Minutes).ToString('o');reason=$Reason}
        Invoke-Hotpl8ControlWrite $Directory { Write-Hotpl8Text (Join-Path $Directory 'automation-pause.json') ($pause|ConvertTo-Json) }
    }finally{if($lock){$lock.Dispose()}}
}
function Add-Hotpl8ClaudeAccount([string]$Directory,[string]$Slot,[string]$Label) {
    if($Slot -notmatch '^[1-9][0-9]{0,3}$'){throw 'Claude slot must be an existing cswap account number.'}
    $path=Join-Path $Directory 'policy.json';$hash=(Get-FileHash $path -Algorithm SHA256).Hash
    $p=ConvertTo-Hotpl8PolicyV2 (Read-Hotpl8Json $path)
    $exe=Resolve-CswapExecutable '';if(-not $exe){throw 'Install claude-swap and enroll with cswap first.'}
    $read=Invoke-Hotpl8Process $exe @('list','--json') (Get-CswapReadTimeoutMs)
    if($read.exitCode -ne 0){throw 'Could not read cswap inventory.'}
    $data=$read.output|ConvertFrom-Json
    if($data.schemaVersion -ne 1 -or @($data.accounts|Where-Object number -EQ ([int]$Slot)).Count -ne 1){throw 'Slot not found in supported cswap inventory.'}
    $p|Add-Member NoteProperty prefer @(@($p.prefer)+@([int]$Slot)|Select-Object -Unique) -Force
    if(-not $p.labels){$p|Add-Member NoteProperty labels ([pscustomobject]@{}) -Force}
    if($Label){$p.labels|Add-Member NoteProperty $Slot $Label -Force}
    Save-Hotpl8Policy $Directory $p $hash
    'Claude account enrolled. Native credentials remain managed by cswap.'
}

function Set-Hotpl8CapacityProfile($Policy,[string]$Provider,[string]$Slot,[string]$Profile,$Weekly,$FiveHour) {
    $next=Set-Hotpl8Account $Policy $Provider $Slot 'capacity' ''
    $driver=Get-Hotpl8ProviderDriver -Provider $Provider
    $part=if($next.schemaVersion -eq 3){$next.providers.$Provider}elseif($driver.provider -eq 'claude'){$next}else{$next.codex}
    if(-not $part.capacity){$part|Add-Member NoteProperty capacity ([pscustomobject]@{}) -Force}
    $c=[ordered]@{}
    if($Profile){
        $known=(Get-Hotpl8CapacityCatalog).profiles.$Profile
        if(-not $known -or $known.provider -ne $driver.provider){throw 'Choose a matching provider capacity profile.'}
        $c.profile=$Profile
    }
    if($null -ne $Weekly){$c.weekly=$Weekly}
    if($null -ne $FiveHour){$c.fiveHour=$FiveHour}
    $c.evidence='user-supplied relative capacity estimate'
    $part.capacity|Add-Member NoteProperty $Slot ([pscustomobject]$c) -Force
    return $next
}
