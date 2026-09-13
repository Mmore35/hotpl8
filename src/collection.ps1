# Per-provider due times persist across scheduler, manual refresh and process restarts.
function Get-Hotpl8CollectionState([string]$Directory) {
    $state=Read-Hotpl8Json (Join-Path $Directory 'collector.json')
    if(-not $state){$state=[pscustomobject]@{schemaVersion=1;providers=[pscustomobject]@{}}}
    return $state
}
function Test-Hotpl8CollectionDue($State, [string]$Provider, [bool]$Scheduled, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    $p=$State.providers.$Provider
    if(-not $p.nextAttemptAt){return $true}
    try{
        # Manual reads can refresh healthy data, but cannot cancel failure backoff.
        if(-not $Scheduled -and -not $p.failures){return $true}
        return [datetimeoffset]::Parse($p.nextAttemptAt) -le $Now
    }catch{return $true}
}
function Set-Hotpl8CollectionResult($State, [string]$Provider, [bool]$Success, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    $old=$State.providers.$Provider
    $failures=if($Success){0}else{[math]::Min(10,1+[int]$old.failures)}
    $delay=if($Success){300}else{[math]::Min(1800,300*[math]::Pow(2,[math]::Max(0,$failures-1)))}
    $p=[pscustomobject]@{lastAttemptAt=$Now.ToString('o');lastSuccessAt=$(if($Success){$Now.ToString('o')}else{$old.lastSuccessAt});failures=$failures;nextAttemptAt=$Now.AddSeconds($delay).ToString('o');status=$(if($Success){'ok'}else{'unavailable'})}
    $State.providers|Add-Member NoteProperty $Provider $p -Force
}
