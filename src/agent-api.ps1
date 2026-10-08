# Versioned, cache-only agent operations. The CLI and MCP share this dispatcher.
. (Join-Path $PSScriptRoot 'rules.ps1')
. (Join-Path $PSScriptRoot 'leases.ps1')
function Stop-Hotpl8AgentRequest([string]$Code) {
    $failure=New-Object InvalidOperationException $Code
    $failure.Data['Hotpl8Code']=$Code
    throw $failure
}
function Get-Hotpl8AgentError([string]$Code) {
    $messages=@{
        invalid_json='Supply one valid JSON object.'
        invalid_request='Supply apiVersion 1, a supported operation and an arguments object.'
        unsupported_version='Only agent API version 1 is supported.'
        unknown_operation='Use an operation listed in the agent API documentation.'
        invalid_arguments='Arguments do not match this operation.'
        request_too_large='Requests must not exceed 64 KiB of UTF-8 JSON.'
        permission_denied='This operation is disabled for this connection.'
        policy_invalid='No valid policy is available. Use the local setup or doctor command.'
        snapshot_missing='No completed snapshot is available. Use the local refresh command.'
        snapshot_invalid='The cached observation is invalid or unsupported.'
        model_unknown='This provider does not support a model override in readiness.'
        lease_state_invalid='Lease state is invalid. Automation remains paused; inspect it locally.'
        lease_conflict='This lease ID was used with different arguments or was already released.'
        lease_capacity='The lease ledger is full. Retry after retained records expire.'
        collector_busy='Another state writer is busy. Retry this same request later.'
        state_write_failed='The state change could not be saved. Retry this same request later.'
        operation_not_found='This setup operation was not found in this installation.'
        operation_conflict='This setup operation belongs to another request or step.'
        internal_error='The request could not be completed. Inspect local diagnostics.'
    }
    if(-not $messages.ContainsKey($Code)){$Code='internal_error'}
    return [pscustomobject]@{code=$Code;message=$messages[$Code];retryable=($Code -in @('collector_busy','state_write_failed','lease_capacity'))}
}
function New-Hotpl8AgentEnvelope([string]$Operation,$Data,[string]$ErrorCode) {
    [pscustomobject]@{apiVersion=1;ok=(-not $ErrorCode);operation=$Operation;data=$Data;error=$(if($ErrorCode){Get-Hotpl8AgentError $ErrorCode}else{$null});computedAt=[datetimeoffset]::UtcNow.ToString('o')}
}
function Assert-Hotpl8AgentArguments($Value,[string[]]$Allowed,[string[]]$Required=@()) {
    if($Value -isnot [pscustomobject]){Stop-Hotpl8AgentRequest 'invalid_arguments'}
    foreach($property in $Value.PSObject.Properties){if($property.Name -cnotin $Allowed){Stop-Hotpl8AgentRequest 'invalid_arguments'}}
    foreach($name in $Required){if(-not $Value.PSObject.Properties[$name]){Stop-Hotpl8AgentRequest 'invalid_arguments'}}
}
function Invoke-Hotpl8AgentRequest($Request,[string]$Directory,[bool]$AllowPause=$true,[bool]$AllowOnboarding=$true) {
    $operation=$null
    try{
        if($Request -isnot [pscustomobject]){Stop-Hotpl8AgentRequest 'invalid_request'}
        if(@($Request.PSObject.Properties|Where-Object {$_.Name -cnotin @('apiVersion','operation','arguments')}).Count -or -not $Request.PSObject.Properties['apiVersion']){Stop-Hotpl8AgentRequest 'invalid_request'}
        if(-not (Test-Hotpl8Number $Request.apiVersion) -or $Request.apiVersion -ne 1){Stop-Hotpl8AgentRequest 'unsupported_version'}
        $operations=@('status','explain','capabilities','doctor','accounts','readiness','pause.acquire','pause.release','onboarding')
        if($Request.operation -isnot [string] -or $Request.operation -cnotin $operations){Stop-Hotpl8AgentRequest 'unknown_operation'}
        $operation=[string]$Request.operation;$a=$Request.arguments
        if($operation -eq 'onboarding'){
            if(-not $AllowOnboarding){Stop-Hotpl8AgentRequest 'permission_denied'}
            Assert-Hotpl8AgentArguments $a @('action','operationId','provider','candidateId','newAccount','allowInstall','deviceCode','code') @('action')
            if($a.action -isnot [string] -or $a.action -cnotin @('begin','status','choose_provider','choose_account','sign_in','install','retry','cancel','submit_code')){Stop-Hotpl8AgentRequest 'invalid_arguments'}
            if(($a.action -ne 'begin' -and -not $a.operationId) -or ($a.PSObject.Properties['operationId'] -and ($a.operationId -isnot [string] -or $a.operationId -cnotmatch '^[0-9a-f]{32}$'))){Stop-Hotpl8AgentRequest 'invalid_arguments'}
            if($a.PSObject.Properties['provider'] -and ($a.provider -isnot [string] -or $a.provider -cnotin @('claude','codex'))){Stop-Hotpl8AgentRequest 'invalid_arguments'}
            if($a.PSObject.Properties['candidateId'] -and ($a.candidateId -isnot [string] -or $a.candidateId -cnotmatch '^[a-z0-9-]{1,40}$')){Stop-Hotpl8AgentRequest 'invalid_arguments'}
            if(($a.action -eq 'submit_code') -ne [bool]$a.PSObject.Properties['code'] -or ($a.PSObject.Properties['code'] -and ($a.code -isnot [string] -or $a.code.Length -gt 4096))){Stop-Hotpl8AgentRequest 'invalid_arguments'}
            foreach($key in @('newAccount','allowInstall','deviceCode')){if($a.PSObject.Properties[$key] -and $a.$key -isnot [bool]){Stop-Hotpl8AgentRequest 'invalid_arguments'}}
            . (Join-Path $PSScriptRoot 'onboarding.ps1')
            $result=Invoke-Hotpl8Onboarding $Directory $a.action $a.operationId $a.provider $a.candidateId -NewAccount:([bool]$a.newAccount) -AllowInstall:([bool]$a.allowInstall) -DeviceCode:([bool]$a.deviceCode) -Code ([string]$a.code)
            return New-Hotpl8AgentEnvelope $operation $result ''
        }elseif($operation -eq 'readiness'){
            Assert-Hotpl8AgentArguments $a @('provider','model') @('provider')
            if($a.provider -isnot [string] -or $a.provider -cnotin @(Get-Hotpl8ProviderCatalog|ForEach-Object id) -or ($a.PSObject.Properties['model'] -and $a.model -isnot [string])){Stop-Hotpl8AgentRequest 'invalid_arguments'}
        }elseif($operation -in @('pause.acquire','pause.release')){
            if(-not $AllowPause){Stop-Hotpl8AgentRequest 'permission_denied'}
            $keys=if($operation -eq 'pause.acquire'){@('leaseId','owner','minutes')}else{@('leaseId')}
            Assert-Hotpl8AgentArguments $a $keys $keys
            if($a.leaseId -isnot [string] -or $a.leaseId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -or [guid]$a.leaseId -eq [guid]::Empty){Stop-Hotpl8AgentRequest 'invalid_arguments'}
            if($operation -eq 'pause.acquire' -and ($a.owner -isnot [string] -or $a.owner.Length -lt 1 -or $a.owner.Length -gt 80 -or $a.owner -match '[\x00-\x1f\x7f]' -or -not (Test-Hotpl8Number $a.minutes) -or $a.minutes -lt 1 -or $a.minutes -gt 1440 -or [math]::Floor($a.minutes) -ne $a.minutes)){Stop-Hotpl8AgentRequest 'invalid_arguments'}
        }else{Assert-Hotpl8AgentArguments $a @()}
        $data=$null;$now=[datetimeoffset]::UtcNow
        if($operation -in @('doctor','capabilities')){
            $doctor=Get-Hotpl8Doctor $Directory
            # The original doctor is already redacted; select fields so future additions do not escape.
            $data=[pscustomobject]@{policyPresent=[bool]$doctor.policyPresent;policyValid=[bool]$doctor.policyValid;collectorBusy=[bool]$doctor.collectorBusy;snapshotFresh=[bool]$doctor.snapshotFresh;snapshotAgeSeconds=$doctor.snapshotAgeSeconds;claudeConfigured=[bool]$doctor.claudeConfigured;codexConfigured=[bool]$doctor.codexConfigured;claudeInstalled=[bool]$doctor.cswapFound;codexInstalled=[bool]$doctor.codexFound}
            $providers=[ordered]@{}
            foreach($entry in $doctor.providers.PSObject.Properties){$providers[$entry.Name]=[pscustomobject]@{configured=[bool]$entry.Value.configured;installed=[bool]$entry.Value.installed;driver=[string]$entry.Value.driver}}
            $data|Add-Member NoteProperty providers ([pscustomobject]$providers)
            if($operation -eq 'capabilities'){$data|Add-Member NoteProperty operations @($operations|Where-Object {($AllowPause -or $_ -notlike 'pause.*') -and ($AllowOnboarding -or $_ -ne 'onboarding')});$data|Add-Member NoteProperty pauseWrites $AllowPause;$data|Add-Member NoteProperty onboardingWrites $AllowOnboarding;$data|Add-Member NoteProperty observationMode 'cached';$data|Add-Member NoteProperty readinessScope 'eligibility-only'}
        }else{
            # The program holds the policy, the snapshot and what they come to. A lease is written here.
            $answer=Invoke-Hotpl8Rule 'agent' @{operation=$operation;directory=$Directory;provider=[string]$a.provider;model=[string]$a.model;now=$now.ToString('o')}
            if($answer.PSObject.Properties['code']){Stop-Hotpl8AgentRequest ([string]$answer.code)}
            if($operation -eq 'pause.acquire'){$data=Invoke-Hotpl8LeaseAcquire $Directory $a.leaseId $a.owner ([int]$a.minutes) $now}
            elseif($operation -eq 'pause.release'){$data=Invoke-Hotpl8LeaseRelease $Directory $a.leaseId $now}
            else{$data=$answer.data}
        }
        return New-Hotpl8AgentEnvelope $operation $data ''
    }catch{
        $code=[string]$_.Exception.Data['Hotpl8Code']
        if(-not $code -and $operation -eq 'onboarding'){
            $message=$_.Exception.Message
            if($message -in @('Onboarding operation missing or unsupported.','Onboarding operation not found.')){$code='operation_not_found'}
            elseif($message -in @('Operation ID already used for a different request.','Action is not available at this setup step.','Operation provider cannot change.')){$code='operation_conflict'}
            elseif($message -eq 'Dependency installation needs explicit authorization.'){$code='permission_denied'}
            elseif($message -in @('Choose an account from this operation.','Provider is required.','That is not the whole code. Copy all of it, including the # in the middle.')){$code='invalid_arguments'}
            else{
                $cause=$_.Exception;while($cause.InnerException){$cause=$cause.InnerException}
                if($cause -is [IO.IOException]){$code='collector_busy'}
            }
        }
        if(-not $code){$code='internal_error'}
        return New-Hotpl8AgentEnvelope $operation $null $code
    }
}
function Invoke-Hotpl8AgentJson([string]$Json,[string]$Directory) {
    if([Text.Encoding]::UTF8.GetByteCount($Json) -gt 65536){return New-Hotpl8AgentEnvelope '' $null 'request_too_large'}
    # Windows .NET stdin writers may emit a UTF-8 preamble when the console uses UTF-8.
    # Treat it as an encoding marker, preserving strict validation of the JSON itself.
    $Json=$Json.TrimStart([char]0xfeff)
    try{$request=ConvertFrom-Json -InputObject $Json -ErrorAction Stop}catch{return New-Hotpl8AgentEnvelope '' $null 'invalid_json'}
    if($Json.TrimStart() -notmatch '^\{'){return New-Hotpl8AgentEnvelope '' $null 'invalid_request'}
    return Invoke-Hotpl8AgentRequest $request $Directory
}
