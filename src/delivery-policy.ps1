# Delivery ownership is forward-only state. A candidate records it during drain,
# before even an older runner selects the candidate. Callers hold tick.lock;
# never acquire update.lock here (delivery takes update.lock before tick.lock).
. (Join-Path $PSScriptRoot 'lifecycle.ps1')

function Get-Hotpl8VerifiedDeliveryOwner([string]$InstallDirectory,[string]$StateDirectory) {
    $root=Assert-Hotpl8Path $InstallDirectory
    $state=Assert-Hotpl8Path $StateDirectory
    $owned=Read-Hotpl8Json (Join-Path $root 'installation.json')
    $registration=Read-Hotpl8Json (Join-Path $root 'delivery.json')
    if(-not $owned -or $owned.product -cne 'hotpl8' -or $owned.id -cnotmatch '^[a-f0-9]{12}$' -or -not $owned.stateDirectory -or
       -not $registration -or $registration.product -cne 'hotpl8' -or $registration.protocol -ne 1 -or -not $registration.stateDirectory){
        throw 'Delivery ownership is invalid. Policy and installation were preserved.'
    }
    if((Assert-Hotpl8Path $owned.stateDirectory) -ine $state -or (Assert-Hotpl8Path $registration.stateDirectory) -ine $state){
        throw 'Delivery state ownership does not match. Policy and installation were preserved.'
    }
    $tick=Join-Path $state 'tick.lock'
    $protected=$false
    foreach($writer in @($registration.writerLocks)){
        if($writer -and (Assert-Hotpl8Path $writer) -ieq $tick){$protected=$true}
    }
    if(-not $protected){throw 'Delivery does not protect the policy writer lock. Policy and installation were preserved.'}
    return [pscustomobject]@{schemaVersion=1;product='hotpl8';installationId=$owned.id;installDirectory=$root;stateDirectory=$state}
}

function Read-Hotpl8DeliveryOwner([string]$StateDirectory) {
    $state=Assert-Hotpl8Path $StateDirectory
    $path=Join-Path $state 'delivery-owner.json'
    if(Test-Path -LiteralPath $path){
        $marker=Read-Hotpl8Json $path
        if(-not $marker -or $marker.schemaVersion -ne 1 -or $marker.product -cne 'hotpl8' -or
           -not $marker.installDirectory -or -not $marker.stateDirectory -or -not $marker.installationId){
            throw 'Delivery ownership marker is invalid. Policy was preserved.'
        }
        if((Assert-Hotpl8Path $marker.stateDirectory) -ine $state){throw 'Delivery ownership marker names another state directory. Policy was preserved.'}
        $owner=Get-Hotpl8VerifiedDeliveryOwner $marker.installDirectory $state
        if($owner.installationId -cne $marker.installationId){throw 'Delivery ownership marker names another installation. Policy was preserved.'}
        return $owner
    }
    # Compatibility discovery for a pre-marker installation. A custom legacy
    # source caller must use its installed launcher until the updater adopts it;
    # an undisclosed custom owner cannot be inferred from an arbitrary state path.
    $roots=@()
    if($env:HOTPL8_INSTALL_DIRECTORY){$roots+=@($env:HOTPL8_INSTALL_DIRECTORY)}
    if($env:LOCALAPPDATA){$roots+=@(Join-Path $env:LOCALAPPDATA 'HotPl8')}
    foreach($candidate in @($roots|Select-Object -Unique)){
        $root=Assert-Hotpl8Path $candidate
        $owned=Read-Hotpl8Json (Join-Path $root 'installation.json')
        if(-not (Test-Path -LiteralPath (Join-Path $root 'delivery.json'))){
            if($owned -and $owned.managedBy -eq 'local-delivery' -and $owned.stateDirectory -and (Assert-Hotpl8Path $owned.stateDirectory) -ieq $state){
                throw 'Delivery registration is missing. Policy was preserved.'
            }
            continue
        }
        $registration=Read-Hotpl8Json (Join-Path $root 'delivery.json')
        # An unrelated default installation does not own this source state.
        $matches=($owned -and $owned.stateDirectory -and (Assert-Hotpl8Path $owned.stateDirectory) -ieq $state) -or
                 ($registration -and $registration.stateDirectory -and (Assert-Hotpl8Path $registration.stateDirectory) -ieq $state)
        if($matches){return (Get-Hotpl8VerifiedDeliveryOwner $root $state)}
        if(-not $owned -or -not $registration){
            throw 'Delivery ownership is unreadable. Policy was preserved.'
        }
    }
    return $null
}

function Set-Hotpl8DeliveryOwner([string]$InstallDirectory,[string]$StateDirectory) {
    $owner=Get-Hotpl8VerifiedDeliveryOwner $InstallDirectory $StateDirectory
    $path=Join-Path $owner.stateDirectory 'delivery-owner.json'
    if(Test-Path -LiteralPath $path){
        $existing=Read-Hotpl8DeliveryOwner $owner.stateDirectory
        if($existing.installDirectory -ine $owner.installDirectory -or $existing.installationId -cne $owner.installationId){
            throw 'State already belongs to another delivery installation.'
        }
        return
    }
    Write-Hotpl8Text $path ($owner|ConvertTo-Json -Depth 4) -NoBom
}

function Assert-Hotpl8PolicyDeliveryCompatibility([string]$StateDirectory,$Policy) {
    $existing=Read-Hotpl8Json (Join-Path $StateDirectory 'policy.json')
    $before=if($existing.schemaVersion){[int]$existing.schemaVersion}else{1}
    $after=if($Policy.schemaVersion){[int]$Policy.schemaVersion}else{1}
    if($after -le $before){return}
    $owner=Read-Hotpl8DeliveryOwner $StateDirectory
    if(-not $owner){return}
    $root=$owner.installDirectory
    # Existence, not successful parsing, is the gate: a corrupt transaction also
    # represents an unresolved activation. This closes the old-bootstrap gap.
    if(Test-Path -LiteralPath (Join-Path $root 'transaction.json')){
        throw 'Delivery activation is unfinished. Recover or finish the update before migrating policy. Policy was preserved.'
    }
    $pointer=Read-Hotpl8Json (Join-Path $root 'current.json')
    if(-not $pointer -or $pointer.protocol -ne 1 -or $pointer.sha -cnotmatch '^[a-f0-9]{40}$' -or $pointer.release -cne ('releases/'+$pointer.sha)){
        throw 'Delivery current release is invalid. Policy was preserved.'
    }
    $release=Assert-Hotpl8Path (Join-Path $root $pointer.release)
    try{
        & {
            # Only this committed reader decides compatibility. Local function
            # scope prevents its validators replacing the caller's newer ones.
            . (Join-Path $release 'src/common.ps1')
            . (Join-Path $release 'src/config.ps1')
            . (Join-Path $release 'src/providers/codex.ps1')
            Assert-Hotpl8Policy $Policy
            if($Policy.codex){Assert-CodexPolicy $Policy.codex}
        }
    }catch{throw 'The committed delivery release cannot read the proposed policy. Finish a compatible update before migrating. Policy was preserved.'}
}
