# Reviewed driver dispatch. Definitions select IDs, never executable code.
. (Join-Path $PSScriptRoot 'provider-registry.ps1')
function Invoke-Hotpl8RegisteredCollection($Registration,$Policy,[string]$Directory,$Previous,[string]$CswapExecutable,[string]$CodexExecutable,[scriptblock]$CodexReader,[switch]$ObserveOnly,[string]$ControlGeneration) {
    $id=[string]$Registration.id;$driver=Get-Hotpl8ProviderDriver $Registration.driver
    if(-not $Registration.definition.capabilities.observation){throw 'Provider observation is unavailable.'}
    $state=Get-Hotpl8ProviderStateDirectory $Directory $id
    [void][IO.Directory]::CreateDirectory($state)
    $view=Get-Hotpl8ProviderView $null $Policy $id
    foreach($capability in @{selection='switchEnabled';warming='warm';recoveryProbe='probeEnabled'}.GetEnumerator()){
        if(-not $Registration.definition.capabilities.($capability.Key)){$view.policy|Add-Member NoteProperty $capability.Value $false -Force}
    }
    if($state -ne $Directory -and (Get-Hotpl8Pause $Directory)){
        # Global pause belongs to the installation, not the adapter's quota cache.
        foreach($flag in @('switchEnabled','warm','probeEnabled')){$view.policy|Add-Member NoteProperty $flag $false -Force}
    }
    switch -CaseSensitive ($driver.id) {
        'claude-cswap' {
            . (Join-Path $PSScriptRoot 'providers/claude.ps1')
            $result=Invoke-ClaudeTick $view.policy $state $CswapExecutable -ObserveOnly:$ObserveOnly -ControlDirectory $Directory -ControlGeneration $ControlGeneration -ProviderId $id
            $healthy=@($result.payload.slots|Where-Object {$_.fresh -or $_.status -eq 'disabled'}).Count
            [pscustomobject]@{payload=$result.payload;lines=@($result.lines);action=$result.action;success=($healthy -gt 0);incomplete=($healthy -ne @($result.payload.slots).Count);healthySeconds=$driver.healthyPollSeconds}
        }
        'codex-app-server' {
            . (Join-Path $PSScriptRoot 'providers/codex.ps1')
            $payload=Invoke-CodexCollection $Registration.policy $state $CodexExecutable $Previous $CodexReader -ControlDirectory $Directory
            $healthy=@($payload.slots|Where-Object {$_.status -in @('ok','disabled')}).Count
            $cadence=if($payload.critical.($Registration.policy.defaultMeter).active){[int]$payload.critical.($Registration.policy.defaultMeter).pollSeconds}else{$driver.healthyPollSeconds}
            [pscustomobject]@{payload=$payload;lines=@(Format-CodexStatus $payload $Registration.policy);action=$null;success=($healthy -gt 0);incomplete=($healthy -ne @($payload.slots).Count);healthySeconds=$cadence}
        }
        default {throw 'Unsupported collection driver.'}
    }
}

function Assert-Hotpl8CollectedOwnership($Registrations,$ProviderPayloads,[string]$Directory,[datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
    $identities=@{};$conflicts=@{}
    foreach($r in @($Registrations|Where-Object driver -CEQ 'codex-app-server')){
        $state=Read-Hotpl8Json (Join-Path (Get-Hotpl8ProviderStateDirectory $Directory $r.id) 'codex-state.json')
        foreach($slot in @($ProviderPayloads.($r.id).slots|Where-Object status -EQ ok)){
            $identity=[string]$state.slots.($slot.id).identityKey
            if(-not $identity){continue}
            if($identities.ContainsKey($identity)){
                $other=$identities[$identity]
                if($other.provider -cne $r.id){$slot.status='duplicate_subscription';$other.slot.status='duplicate_subscription';$conflicts[$r.id]=$r;$conflicts[$other.provider]=$other.registration}
            }else{$identities[$identity]=@{provider=$r.id;slot=$slot;registration=$r}}
        }
    }
    foreach($id in $conflicts.Keys){
        $r=$conflicts[$id];$payload=$ProviderPayloads.$id
        foreach($meter in @($r.definition.meters)){
            $prior=$payload.recommendations.$meter
            $selected=Select-CodexSlot $payload.slots $r.policy $meter $prior $payload.hold $Now $payload.critical.$meter
            $payload.recommendations|Add-Member NoteProperty $meter $selected -Force
            foreach($decision in @($payload.decisions|Where-Object meter -CEQ $meter)){
                $decision.selected=$selected
                foreach($account in @($decision.accounts)){
                    $slot=@($payload.slots|Where-Object id -CEQ $account.slot|Select-Object -First 1)
                    if($slot.Count -and $slot[0].status -eq 'duplicate_subscription'){$account.reason='duplicate_subscription'}
                }
            }
        }
        $defaultMeter=if($r.policy.defaultMeter){$r.policy.defaultMeter}else{$r.definition.defaultMeter}
        $payload.recommendedSlot=$payload.recommendations.$defaultMeter
    }
    return @($conflicts.Keys)
}

function Get-Hotpl8RegisteredFailure($Registration,$Previous,[string]$Reason,[string]$FailureCode) {
    $driver=Get-Hotpl8ProviderDriver $Registration.driver
    if($driver.provider -eq 'codex'){return (Get-Hotpl8CodexFailure $Previous $Reason $FailureCode)}
    $payload=if($Previous){Copy-Hotpl8ProviderValue $Previous}else{[pscustomobject]@{slots=@()}}
    foreach($s in @($payload.slots|Where-Object {$_})){
        foreach($entry in @{fresh=$false;active=$false;status=$Reason}.GetEnumerator()){$s|Add-Member NoteProperty $entry.Key $entry.Value -Force}
    }
    foreach($entry in @{active=0;verdict=($Registration.name+' unavailable: '+$Reason);hold=$null}.GetEnumerator()){$payload|Add-Member NoteProperty $entry.Key $entry.Value -Force}
    $payload|Add-Member NoteProperty claudeError $Reason -Force
    return $payload
}
