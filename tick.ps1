# Scheduled collection is quiet; interactive callers can request nonzero failure exits.
param([string]$StateDirectory,[string]$CswapExecutable,[string]$CodexExecutable,[scriptblock]$CodexReader,[switch]$ObserveOnly,[switch]$Strict,[switch]$Scheduled)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'src/common.ps1')
. (Join-Path $PSScriptRoot 'src/config.ps1')
. (Join-Path $PSScriptRoot 'src/diagnostics.ps1')
. (Join-Path $PSScriptRoot 'src/collection.ps1')
. (Join-Path $PSScriptRoot 'src/insights.ps1')
$StateDirectory=Resolve-Hotpl8StateDirectory $StateDirectory $PSScriptRoot
$lock=$null; $failed=$false
try {
    $policyPath=Join-Path $StateDirectory 'policy.json'
    if(-not (Test-Path -LiteralPath $policyPath)){if($Strict){exit 1};exit 0}
    $policy=Read-Hotpl8Json $policyPath
    Assert-Hotpl8Policy $policy
    if(-not $policy.prefer -and -not $policy.codex.slots){exit 0}
    $lock=[IO.File]::Open((Join-Path $StateDirectory 'tick.lock'),'OpenOrCreate','ReadWrite','None')
    $previous=Read-Hotpl8Json (Join-Path $StateDirectory 'status.json')
    $collector=Get-Hotpl8CollectionState $StateDirectory
    $collector|Add-Member NoteProperty startedAt ([datetimeoffset]::UtcNow.ToString('o')) -Force
    $collector|Add-Member NoteProperty scheduled ([bool]$Scheduled) -Force
    Write-Hotpl8Text (Join-Path $StateDirectory 'collector.json') ($collector|ConvertTo-Json -Depth 8)
    $claude=$null; $claudeError=$null; $codex=$null
    try {
        . (Join-Path $PSScriptRoot 'src/providers/claude.ps1')
        if(Test-Hotpl8CollectionDue $collector 'claude' ([bool]$Scheduled)){
            $claude=Invoke-ClaudeTick $policy $StateDirectory $CswapExecutable -ObserveOnly:$ObserveOnly
            if($policy.prefer){
                $healthy=@($claude.payload.slots|Where-Object {$_.fresh -or $_.status -eq 'disabled'}).Count -eq @($claude.payload.slots).Count
                # cswap owns API cadence/backoff. Observe its cache every scheduler
                # wake: a second five-minute cache can age a healthy ten-minute
                # native poll (plus jitter) past our fifteen-minute freshness bound.
                Set-Hotpl8CollectionResult $collector 'claude' (@($claude.payload.slots|Where-Object {$_.fresh -or $_.status -eq 'disabled'}).Count -gt 0) -HealthySeconds 60
                if(-not $healthy){$failed=$true}
            }
        }elseif($policy.prefer){
            if($collector.providers.claude.failures){$claudeError='backoff';$failed=$true}
            elseif($previous){$claude=@{payload=($previous|ConvertTo-Json -Depth 24|ConvertFrom-Json);lines=@('Claude: cached until next scheduled collection')}}
        }
    } catch {
        $claudeError='collection_failed'; $failed=$true
        $failureCode=Get-Hotpl8FailureCode $_
        if($failureCode -eq 'state_io_failed'){$claudeError='local_state_unavailable'}
        if($_.Exception.Message -in @('claude_missing','claude_no_accounts','claude_schema_unsupported','claude_read_failed','claude_switch_failed','process_timeout','process_output_limit')){$claudeError=$_.Exception.Message}
        Write-Hotpl8Event $StateDirectory ('claude_'+$claudeError) $_
        Set-Hotpl8CollectionResult $collector 'claude' $false -FailureCode $failureCode
    }
    if($policy.codex -and $policy.codex.slots){
        try {
            . (Join-Path $PSScriptRoot 'src/providers/codex.ps1')
            if(Test-Hotpl8CollectionDue $collector 'codex' ([bool]$Scheduled)){
                $codex=Invoke-CodexCollection $policy.codex $StateDirectory $CodexExecutable $previous.providers.codex $CodexReader
                Set-Hotpl8CollectionResult $collector 'codex' (@($codex.slots|Where-Object {$_.status -in @('ok','disabled')}).Count -gt 0) -HealthySeconds $(if($codex.critical.($policy.codex.defaultMeter).active){[int]$codex.critical.($policy.codex.defaultMeter).pollSeconds}else{300})
            }else{
                $codex=$previous.providers.codex
                if($codex -and $collector.providers.codex.failures){$codex=Get-Hotpl8CodexFailure $codex 'backoff' $null}
            }
            if(@($codex.slots|Where-Object {$_.status -notin @('ok','disabled')}).Count){$failed=$true;Write-Hotpl8Event $StateDirectory 'codex_observation_unavailable'}
        } catch {
            $failed=$true
            $codex=Get-Hotpl8CodexFailure $previous.providers.codex 'collection_failed' (Get-Hotpl8FailureCode $_)
            Write-Hotpl8Event $StateDirectory 'codex_collection_failed' $_
            Set-Hotpl8CollectionResult $collector 'codex' $false -FailureCode (Get-Hotpl8FailureCode $_)
        }
    }
    if($claude){$payload=$claude.payload;$lines=@($claude.lines)}
    else{
        $reason=if($policy.prefer){'Claude unavailable: '+$claudeError}else{'Claude not configured'}
        $payload=[pscustomobject]@{generatedAt=[datetimeoffset]::UtcNow.ToString('o');active=0;verdict=$reason;hold=$null;slots=@()}
        if($claudeError -and $previous.slots){$payload.slots=@($previous.slots);foreach($s in $payload.slots){$s.fresh=$false;$s.active=$false;$s.status=$claudeError}}
        $lines=@($reason)
    }
    $payload|Add-Member NoteProperty schemaVersion 2 -Force
    $payload.generatedAt=[datetimeoffset]::UtcNow.ToString('o')
    $payload|Add-Member NoteProperty generationId ([guid]::NewGuid().ToString('N')) -Force
    $payload|Add-Member NoteProperty mode $(if($ObserveOnly -or $policy.mode -eq 'monitor'){'monitor'}else{'automate'}) -Force
    $payload.PSObject.Properties.Remove('claudeError')
    if($claudeError){$payload|Add-Member NoteProperty claudeError $claudeError -Force}
    if($codex){
        $payload|Add-Member NoteProperty providers ([pscustomobject]@{codex=$codex}) -Force
        $lines+=@(Format-CodexStatus $codex $policy.codex)
    }else{$payload.PSObject.Properties.Remove('providers')}
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
    if($claude.action){ConvertTo-Hotpl8SafeText $claude.action}
} catch {
    $failed=$true
    if($lock){Write-Hotpl8Event $StateDirectory 'collector_failed' $_}
} finally {if($lock){$lock.Dispose()}}
if($Strict -and $failed){exit 1}
exit 0
