# Scheduled collection is quiet; interactive callers can request nonzero failure exits.
param([string]$StateDirectory,[string]$CswapExecutable,[string]$CodexExecutable,[scriptblock]$CodexReader,[switch]$ObserveOnly,[switch]$Strict)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'src/common.ps1')
. (Join-Path $PSScriptRoot 'src/config.ps1')
. (Join-Path $PSScriptRoot 'src/diagnostics.ps1')
$StateDirectory=Resolve-Hotpl8StateDirectory $StateDirectory $PSScriptRoot
$lock=$null; $failed=$false
try {
    $policyPath=Join-Path $StateDirectory 'policy.json'
    if(-not (Test-Path -LiteralPath $policyPath)){if($Strict){exit 1};exit 0}
    $policy=Read-Hotpl8Json $policyPath
    Assert-Hotpl8Policy $policy
    $lock=[IO.File]::Open((Join-Path $StateDirectory 'tick.lock'),'OpenOrCreate','ReadWrite','None')
    $previous=Read-Hotpl8Json (Join-Path $StateDirectory 'status.json')
    $claude=$null; $claudeError=$null; $codex=$null
    try {
        . (Join-Path $PSScriptRoot 'src/providers/claude.ps1')
        $claude=Invoke-ClaudeTick $policy $StateDirectory $CswapExecutable -ObserveOnly:$ObserveOnly
    } catch {
        $claudeError='collection_failed'; $failed=$true
        if($_.Exception.Message -in @('claude_missing','claude_no_accounts','claude_schema_unsupported','claude_read_failed','claude_switch_failed','process_timeout','process_output_limit')){$claudeError=$_.Exception.Message}
        Write-Hotpl8Event $StateDirectory ('claude_'+$claudeError)
    }
    if($policy.codex -and $policy.codex.slots){
        try {
            . (Join-Path $PSScriptRoot 'src/providers/codex.ps1')
            $codex=Invoke-CodexCollection $policy.codex $StateDirectory $CodexExecutable $previous.providers.codex $CodexReader
            if(@($codex.slots|Where-Object status -NE ok).Count){$failed=$true;Write-Hotpl8Event $StateDirectory 'codex_observation_unavailable'}
        } catch {
            $failed=$true
            $codex=[pscustomobject]@{status='collection_failed';observedAt=[datetimeoffset]::UtcNow.ToString('o');recommendedSlot=$null;slots=@()}
            Write-Hotpl8Event $StateDirectory 'codex_collection_failed'
        }
    }
    if(-not $claude -and -not $codex -and -not $claudeError){exit 0}
    if($claude){$payload=$claude.payload;$lines=@($claude.lines)}
    else{
        $reason=if($policy.prefer){'Claude unavailable: '+$claudeError}else{'Claude not configured'}
        $payload=[pscustomobject]@{generatedAt=[datetimeoffset]::UtcNow.ToString('o');active=0;verdict=$reason;hold=$null;slots=@()}
        $lines=@($reason)
    }
    $payload|Add-Member NoteProperty schemaVersion 2 -Force
    $payload|Add-Member NoteProperty generationId ([guid]::NewGuid().ToString('N')) -Force
    $payload|Add-Member NoteProperty mode $(if($ObserveOnly -or $policy.mode -eq 'monitor'){'monitor'}else{'automate'}) -Force
    if($claudeError){$payload|Add-Member NoteProperty claudeError $claudeError -Force}
    if($codex){
        $payload|Add-Member NoteProperty providers ([pscustomobject]@{codex=$codex}) -Force
        $lines+=@(Format-CodexStatus $codex $policy.codex)
    }
    $json=$payload|ConvertTo-Json -Depth 24
    Write-Hotpl8Text (Join-Path $StateDirectory 'status.json') ($json+[Environment]::NewLine)
    Write-Hotpl8Text (Join-Path $StateDirectory 'status.js') ('window.CSWAP = '+$json+';'+[Environment]::NewLine)
    Write-Hotpl8Text (Join-Path $StateDirectory 'status.txt') ((@($lines|ForEach-Object{ConvertTo-Hotpl8SafeText $_}) -join [Environment]::NewLine)+[Environment]::NewLine)
    if($claude.action){ConvertTo-Hotpl8SafeText $claude.action}
} catch {
    $failed=$true
    if($lock){Write-Hotpl8Event $StateDirectory 'collector_failed'}
} finally {if($lock){$lock.Dispose()}}
if($Strict -and $failed){exit 1}
exit 0
