# Scheduled collection is quiet; interactive callers can request nonzero failure exits.
param([string]$StateDirectory,[string]$CswapExecutable,[string]$CodexExecutable,[scriptblock]$CodexReader,[switch]$ObserveOnly,[switch]$Strict,[switch]$Scheduled)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'src/common.ps1')
. (Join-Path $PSScriptRoot 'src/config.ps1')
. (Join-Path $PSScriptRoot 'src/diagnostics.ps1')
. (Join-Path $PSScriptRoot 'src/collection.ps1')
. (Join-Path $PSScriptRoot 'src/insights.ps1')
. (Join-Path $PSScriptRoot 'src/provider-runtime.ps1')
$StateDirectory=Resolve-Hotpl8StateDirectory $StateDirectory $PSScriptRoot
$lock=$null; $failed=$false
try {
    $policyPath=Join-Path $StateDirectory 'policy.json'
    if(-not (Test-Path -LiteralPath $policyPath)){if($Strict){exit 1};exit 0}
    $lock=[IO.File]::Open((Join-Path $StateDirectory 'tick.lock'),'OpenOrCreate','ReadWrite','None')
    $control=Get-Hotpl8ControlSnapshot $StateDirectory
    $policy=$control.policy
    Assert-Hotpl8Policy $policy
    $registrations=@(Get-Hotpl8ConfiguredProviders $policy)
    if(-not @(Get-Hotpl8ProviderAccounts $policy).Count){exit 0}
    $previous=Read-Hotpl8Json (Join-Path $StateDirectory 'status.json')
    $collector=Get-Hotpl8CollectionState $StateDirectory
    $collector|Add-Member NoteProperty startedAt ([datetimeoffset]::UtcNow.ToString('o')) -Force
    $collector|Add-Member NoteProperty scheduled ([bool]$Scheduled) -Force
    Write-Hotpl8Text (Join-Path $StateDirectory 'collector.json') ($collector|ConvertTo-Json -Depth 8)
    $payload=[pscustomobject]@{active=0;verdict='Claude not configured';hold=$null;slots=@()}
    $providerPayloads=[ordered]@{};$providerLines=@{};$lines=@();$actions=@()
    foreach($registration in $registrations){
        $id=[string]$registration.id;$driver=Get-Hotpl8ProviderDriver $registration.driver
        if(-not @(Get-Hotpl8ProviderAccounts $policy|Where-Object provider -CEQ $id).Count){continue}
        $old=if($id -ceq 'claude'){$previous}else{$previous.providers.$id}
        $result=$null;$observed=$null
        try{
            if(Test-Hotpl8CollectionDue $collector $id ([bool]$Scheduled)){
                $result=Invoke-Hotpl8RegisteredCollection $registration $policy $StateDirectory $old $CswapExecutable $CodexExecutable $CodexReader -ObserveOnly:$ObserveOnly -ControlGeneration $control.generation
                $observed=$result.payload
                Set-Hotpl8CollectionResult $collector $id $result.success -HealthySeconds $result.healthySeconds
                if($result.incomplete){$failed=$true;Write-Hotpl8Event $StateDirectory ($id+'_observation_unavailable')}
                $providerLines[$id]=@($result.lines);if($result.action){$actions+=@($result.action)}
            }else{
                $observed=$old
                if($collector.providers.$id.failures){$observed=Get-Hotpl8RegisteredFailure $registration $old 'backoff' $null;$failed=$true}
                $providerLines[$id]=@($registration.name+': cached until next scheduled collection')
            }
        }catch{
            $failed=$true;$failureCode=Get-Hotpl8FailureCode $_;$reason='collection_failed'
            if($failureCode -eq 'state_io_failed' -and $driver.provider -eq 'claude'){$reason='local_state_unavailable'}
            if($_.Exception.Message -in @('claude_missing','claude_no_accounts','claude_schema_unsupported','claude_read_failed','claude_switch_failed','process_timeout','process_output_limit')){$reason=$_.Exception.Message}
            $observed=Get-Hotpl8RegisteredFailure $registration $old $reason $failureCode
            Write-Hotpl8Event $StateDirectory ($id+'_'+$reason) $_
            Set-Hotpl8CollectionResult $collector $id $false -FailureCode $failureCode
        }
        if($id -ceq 'claude'){$payload=$observed}
        else{$providerPayloads[$id]=$observed}
    }
    foreach($conflict in @(Assert-Hotpl8CollectedOwnership $registrations $providerPayloads $StateDirectory)){
        $failed=$true;Set-Hotpl8CollectionResult $collector $conflict $false
    }
    # Mirror text reflects final ownership checks, not a superseded proposal.
    $lines=@()
    foreach($r in $registrations){
        if($r.driver -ceq 'codex-app-server' -and $providerPayloads.Contains($r.id)){$lines+=@(Format-CodexStatus $providerPayloads.($r.id) $r.policy|ForEach-Object {$_ -replace '^Codex',$r.name})}
        elseif($providerLines.ContainsKey($r.id)){$lines+=@($providerLines[$r.id])}
    }
    $payload|Add-Member NoteProperty schemaVersion 2 -Force
    $payload|Add-Member NoteProperty generatedAt ([datetimeoffset]::UtcNow.ToString('o')) -Force
    $payload|Add-Member NoteProperty generationId ([guid]::NewGuid().ToString('N')) -Force
    $payload|Add-Member NoteProperty mode $(if($ObserveOnly -or $policy.mode -eq 'monitor'){'monitor'}else{'automate'}) -Force
    if($providerPayloads.Count){$payload|Add-Member NoteProperty providers ([pscustomobject]$providerPayloads) -Force}
    else{$payload.PSObject.Properties.Remove('providers')}
    $build=Read-Hotpl8Json (Join-Path $PSScriptRoot 'build-info.json')
    if($build.sha){$collector|Add-Member NoteProperty runningSha $build.sha -Force}
    $collector|Add-Member NoteProperty completedAt ([datetimeoffset]::UtcNow.ToString('o')) -Force
    $collector|Add-Member NoteProperty status $(if($failed){'incomplete'}else{'ok'}) -Force
    $collector|Add-Member NoteProperty incompleteRuns $(if($failed){1+[int]$collector.incompleteRuns}else{0}) -Force
    $payload|Add-Member NoteProperty collector $collector -Force
    Add-Hotpl8Insights $payload $policy $StateDirectory $previous
    $json=$payload|ConvertTo-Json -Depth 24
    Write-Hotpl8Text (Join-Path $StateDirectory 'status.json') ($json+[Environment]::NewLine)
    # status.json is the authoritative snapshot. Legacy text/browser mirrors
    # must not turn successful observation into a failed collection.
    $mirrors=@{
        'status.js'=('window.CSWAP = '+$json+';'+[Environment]::NewLine)
        'status.txt'=((@($lines|ForEach-Object{ConvertTo-Hotpl8SafeText $_}) -join [Environment]::NewLine)+[Environment]::NewLine)
    }
    foreach($name in $mirrors.Keys){
        try{Write-Hotpl8Text (Join-Path $StateDirectory $name) $mirrors[$name]}
        catch{Write-Hotpl8Event $StateDirectory 'compatibility_output_failed' $_}
    }
    Write-Hotpl8Text (Join-Path $StateDirectory 'collector.json') ($collector|ConvertTo-Json -Depth 8)
    foreach($action in $actions){ConvertTo-Hotpl8SafeText $action}
} catch {
    $failed=$true
    if($lock){Write-Hotpl8Event $StateDirectory 'collector_failed' $_}
} finally {if($lock){$lock.Dispose()}}
if($Strict -and $failed){exit 1}
exit 0
