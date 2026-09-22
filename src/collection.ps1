# Per-provider due times persist across scheduler, manual refresh and process restarts.
. (Join-Path $PSScriptRoot 'provider-registry.ps1')
function Get-Hotpl8CollectionState([string]$Directory) {
    $state=Read-Hotpl8Json (Join-Path $Directory 'collector.json')
    if(-not $state){$state=[pscustomobject]@{schemaVersion=1;providers=[pscustomobject]@{}}}
    # Older/partial collector markers may contain timing alone. Rebuild this
    # derived map rather than failing every provider's next result assignment.
    if($state.providers -isnot [pscustomobject]){$state|Add-Member NoteProperty providers ([pscustomobject]@{}) -Force}
    return $state
}
function Test-Hotpl8CollectionDue($State, [string]$Provider, [bool]$Scheduled, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    $p=$State.providers.$Provider
    if(-not $p.nextAttemptAt){return $true}
    try{
        # cswap already owns each account's polling/cache deadlines. Observe it
        # on every healthy scheduler wake; adding a second cache can expire its
        # otherwise valid readings. Neither path may cancel failure backoff.
        if(-not $p.failures -and (-not $Scheduled -or (Get-Hotpl8ProviderDriver (Get-Hotpl8ProviderDefinition $Provider).driver).healthyPollSeconds -eq 60)){return $true}
        return [datetimeoffset]::Parse($p.nextAttemptAt) -le $Now
    }catch{return $true}
}
function Set-Hotpl8CollectionResult($State, [string]$Provider, [bool]$Success, [datetimeoffset]$Now = [datetimeoffset]::UtcNow, [int]$HealthySeconds=300, [string]$FailureCode) {
    $old=$State.providers.$Provider
    $localFailure=$FailureCode -eq 'state_io_failed'
    $priorFailures=if($old.failureCode -eq 'state_io_failed' -and -not $localFailure){0}else{[int]$old.failures}
    $failures=if($Success){0}else{[math]::Min(10,1+$priorFailures)}
    # A local write failure is not a rejected provider request. Recover at the
    # next scheduler wake, while native/provider failures retain their backoff.
    $delay=if($Success){[math]::Max(60,[math]::Min(300,$HealthySeconds))}elseif($localFailure){60}else{[math]::Min(1800,300*[math]::Pow(2,[math]::Max(0,$failures-1)))}
    $p=[pscustomobject]@{lastAttemptAt=$Now.ToString('o');lastSuccessAt=$(if($Success){$Now.ToString('o')}else{$old.lastSuccessAt});failures=$failures;nextAttemptAt=$Now.AddSeconds($delay).ToString('o');status=$(if($Success){'ok'}else{'unavailable'})}
    if(-not $Success -and $FailureCode){$p|Add-Member NoteProperty failureCode $FailureCode}
    $State.providers|Add-Member NoteProperty $Provider $p -Force
}

# A skipped retry is not a new failure. Sparse/legacy records are normalized here.
function Get-Hotpl8CodexFailure($Previous,[string]$Status,$FailureCode) {
    $slots=@()
    foreach($slot in @($Previous.slots)){
        if(-not $slot){continue}
        $copy=$slot|ConvertTo-Json -Depth 24|ConvertFrom-Json
        if($copy.status -ne 'disabled'){$copy|Add-Member NoteProperty status $Status -Force}
        $slots+=@($copy)
    }
    return [pscustomobject]@{status=$Status;observedAt=$Previous.observedAt;recommendedSlot=$null;recommendations=[pscustomobject]@{};decisions=@();slots=$slots;failureCode=$(if($FailureCode){$FailureCode}else{$Previous.failureCode});failureStage='codex_collection'}
}
function Get-Hotpl8FailureCode($ErrorRecord) {
    # Exception messages may include paths or native output. Export only known categories.
    $exception=$ErrorRecord.Exception
    while($exception){
        if($exception -is [UnauthorizedAccessException]){return 'access_denied'}
        if($exception -is [IO.IOException]){return 'state_io_failed'}
        $exception=$exception.InnerException
    }
    switch -Regex ([string]$ErrorRecord.FullyQualifiedErrorId) {
        'PropertyAssignment|PropertyNotFound' {return 'invalid_cached_shape'}
        'ParameterBinding' {return 'invalid_parameter'}
        'UnauthorizedAccess|PermissionDenied' {return 'access_denied'}
        'IOException' {return 'state_io_failed'}
        default {return 'unexpected_collection_error'}
    }
}
