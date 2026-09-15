# A successful process is an attempt, never proof of a provider window.
function New-Hotpl8WarmOutcome([string]$Provider, [string]$Slot, [string]$Identity, [string]$Meter, [bool]$Succeeded, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    return [pscustomobject]@{schemaVersion=1;id=[guid]::NewGuid().ToString('N');provider=$Provider;slot=$Slot;identity=$Identity;meter=$Meter;sentAt=$Now.ToString('o');expiresAt=$Now.AddHours(5).ToString('o');outcome=$(if($Succeeded){'sent'}else{'failed'});observedAt=$null;resetAt=$null}
}
function Update-Hotpl8WarmOutcome($Outcome, [string]$Identity, $ObservedAt, $ResetAt, [bool]$Fresh, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    if (-not $Outcome) { return $null }
    $result = $Outcome | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    if ($result.identity -ne $Identity) { $result.outcome='account_changed'; return $result }
    if ($result.outcome -in @('failed','account_changed','expired')) { return $result }
    try {
        $sent=[datetimeoffset]::Parse($result.sentAt); $expires=[datetimeoffset]::Parse($result.expiresAt)
        if ($Now -ge $expires) { $result.outcome='expired'; return $result }
        if ($Fresh -and $ObservedAt -and $ResetAt) {
            $observed=[datetimeoffset]::Parse([string]$ObservedAt); $reset=[datetimeoffset]::Parse([string]$ResetAt)
            # Bound the window and reject stale/pre-request or future observations.
            if ($observed -gt $sent -and $observed -le $Now.AddSeconds(5) -and ($Now-$observed).TotalSeconds -le 900 -and $reset -gt $Now -and $reset -le $sent.AddHours(5).AddMinutes(5)) {
                $result.outcome='observed-active'; $result.observedAt=$observed.ToString('o'); $result.resetAt=$reset.ToString('o'); $result.expiresAt=$reset.ToString('o')
                return $result
            }
        }
        if ($result.outcome -in @('sent','requested') -and ($Now-$sent).TotalMinutes -ge 15) { $result.outcome='unconfirmed' }
    } catch { $result.outcome='unconfirmed' }
    return $result
}
function Read-Hotpl8WarmOutcomes([string]$Directory) {
    $value = Read-Hotpl8Json (Join-Path $Directory 'warm-outcomes.json')
    if (-not $value) { return [pscustomobject]@{} }
    return $value
}
function Save-Hotpl8WarmOutcomes([string]$Directory, $Outcomes) {
    Write-Hotpl8Text (Join-Path $Directory 'warm-outcomes.json') ($Outcomes | ConvertTo-Json -Depth 10)
}
function Test-Hotpl8WarmPending($Outcome, [string]$Identity, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    if (-not $Outcome -or $Outcome.identity -ne $Identity -or $Outcome.outcome -in @('failed','expired','account_changed')) { return $false }
    try { return [datetimeoffset]::Parse($Outcome.expiresAt) -gt $Now } catch { return $true }
}
