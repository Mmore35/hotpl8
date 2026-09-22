# Cooperative capabilities, separate from the human-owned pause. Writers hold
# tick.lock, then briefly action-control.lock at publication (never native I/O).
. (Join-Path $PSScriptRoot 'provider-actions.ps1')
function Stop-Hotpl8LeaseError([string]$Code, [string]$Message) {
    $exception=New-Object InvalidOperationException($Message)
    $exception.Data['Hotpl8Code']=$Code
    throw $exception
}
function Test-Hotpl8LeaseId($Value) {
    return ($Value -is [string] -and $Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -and $Value -ne [guid]::Empty.ToString())
}
function Test-Hotpl8LeaseOwner($Value) {
    return ($Value -is [string] -and $Value.Length -ge 1 -and $Value.Length -le 80 -and $Value.Trim().Length -gt 0 -and $Value -notmatch '[\x00-\x1f\x7f]')
}
function ConvertFrom-Hotpl8LeaseTime($Value) {
    if ($Value -isnot [string] -or $Value -notmatch '(Z|\+00:00)$') { throw 'invalid timestamp' }
    return [datetimeoffset]::Parse($Value,[Globalization.CultureInfo]::InvariantCulture)
}
function Read-Hotpl8LeaseLedger([string]$Directory) {
    $path=Join-Path $Directory 'automation-leases.json'
    try {
        # File.Exists hides access errors. Get-Item distinguishes absent state from unreadable state.
        try { $file=Get-Item -LiteralPath $path -Force -ErrorAction Stop }
        catch [System.Management.Automation.ItemNotFoundException] { return [pscustomobject]@{schemaVersion=1;entries=@()} }
        if ($file.PSIsContainer -or $file.Length -gt 262144) { throw 'invalid ledger' }
        $ledger=Read-Hotpl8Json $path
        if ($ledger -isnot [pscustomobject] -or $ledger.schemaVersion -isnot [int] -or $ledger.schemaVersion -ne 1 -or $ledger.entries -isnot [array] -or $ledger.entries.Count -gt 256) { throw 'invalid ledger' }
        foreach ($property in $ledger.PSObject.Properties) { if ($property.Name -notin @('schemaVersion','entries')) { throw 'invalid ledger field' } }
        $ids=@{}
        foreach ($entry in $ledger.entries) {
            if ($entry -isnot [pscustomobject] -or -not (Test-Hotpl8LeaseId $entry.leaseId) -or $ids.ContainsKey($entry.leaseId)) { throw 'invalid lease' }
            $ids[$entry.leaseId]=$true
            $fields=@('leaseId','owner','minutes','acquiredAt','until','releasedAt','retainUntil')
            if (@($entry.PSObject.Properties).Count -ne $fields.Count) { throw 'invalid lease fields' }
            foreach ($property in $entry.PSObject.Properties) { if ($property.Name -notin $fields) { throw 'invalid lease field' } }
            $retain=ConvertFrom-Hotpl8LeaseTime $entry.retainUntil
            $released=$null
            if ($null -ne $entry.releasedAt) { $released=ConvertFrom-Hotpl8LeaseTime $entry.releasedAt }
            if ($null -eq $entry.acquiredAt) {
                if ($null -ne $entry.owner -or $null -ne $entry.minutes -or $null -ne $entry.until -or $null -eq $released -or $retain -lt $released.AddHours(24)) { throw 'invalid tombstone' }
            } else {
                if (-not (Test-Hotpl8LeaseOwner $entry.owner) -or $entry.minutes -isnot [int] -or $entry.minutes -lt 1 -or $entry.minutes -gt 1440) { throw 'invalid acquisition' }
                $acquired=ConvertFrom-Hotpl8LeaseTime $entry.acquiredAt
                $until=ConvertFrom-Hotpl8LeaseTime $entry.until
                if ($until -ne $acquired.AddMinutes($entry.minutes) -or $retain -lt $until.AddHours(24)) { throw 'invalid expiry' }
                if ($null -ne $released -and $retain -lt $released.AddHours(24)) { throw 'invalid release retention' }
            }
        }
        return $ledger
    } catch { Stop-Hotpl8LeaseError 'lease_state_invalid' 'Agent pause state is invalid or unreadable; automation remains paused.' }
}
function Get-Hotpl8LeasePause([string]$Directory, [datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
    try { $ledger=Read-Hotpl8LeaseLedger $Directory }
    catch { return [pscustomobject]@{until=$null;reason='invalid_leases';invalid=$true;leaseCount=$null} }
    $active=@($ledger.entries | Where-Object { $null -ne $_.until -and $null -eq $_.releasedAt -and (ConvertFrom-Hotpl8LeaseTime $_.until) -gt $Now })
    if (-not $active.Count) { return $null }
    $until=($active | ForEach-Object { ConvertFrom-Hotpl8LeaseTime $_.until } | Sort-Object -Descending | Select-Object -First 1).ToUniversalTime().ToString('o')
    return [pscustomobject]@{until=$until;reason='agent_leases';invalid=$false;leaseCount=$active.Count}
}
function Open-Hotpl8LeaseLock([string]$Directory) {
    try { return [IO.File]::Open((Join-Path $Directory 'tick.lock'),'OpenOrCreate','ReadWrite','None') }
    catch {
        $cause=$_.Exception
        while ($cause.InnerException) { $cause=$cause.InnerException }
        if ($cause -is [IO.IOException] -and ($cause.HResult -band 65535) -in @(32,33)) { Stop-Hotpl8LeaseError 'collector_busy' 'Collector state is busy; retry the request.' }
        Stop-Hotpl8LeaseError 'state_write_failed' 'Agent pause state could not be locked.'
    }
}
function Save-Hotpl8LeaseLedger([string]$Directory, $Entries) {
    try { Invoke-Hotpl8ControlWrite $Directory { Write-Hotpl8Text (Join-Path $Directory 'automation-leases.json') (@{schemaVersion=1;entries=@($Entries)} | ConvertTo-Json -Depth 8 -Compress) -NoBom } }
    catch { Stop-Hotpl8LeaseError 'state_write_failed' 'Agent pause state could not be saved.' }
}
function Invoke-Hotpl8LeaseAcquire($Directory, $LeaseId, $Owner, [int]$Minutes, [datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
    if ($Directory -isnot [string] -or [string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Hotpl8LeaseId $LeaseId) -or -not (Test-Hotpl8LeaseOwner $Owner) -or $Minutes -lt 1 -or $Minutes -gt 1440) { Stop-Hotpl8LeaseError 'invalid_arguments' 'Expected a UUID leaseId, owner of 1 to 80 printable characters, and minutes from 1 to 1440.' }
    $Now=$Now.ToUniversalTime();$LeaseId=$LeaseId.ToLowerInvariant();$lock=$null
    try {
        $lock=Open-Hotpl8LeaseLock $Directory
        $ledger=Read-Hotpl8LeaseLedger $Directory
        $entries=@($ledger.entries | Where-Object { (ConvertFrom-Hotpl8LeaseTime $_.retainUntil) -gt $Now })
        $existing=@($entries | Where-Object leaseId -EQ $LeaseId)
        if ($existing.Count) {
            $entry=$existing[0]
            if ($null -eq $entry.acquiredAt -or $entry.owner -cne $Owner -or $entry.minutes -ne $Minutes) { Stop-Hotpl8LeaseError 'lease_conflict' 'The leaseId was already used with different acquisition parameters or released before acquisition.' }
        } else {
            if ($entries.Count -ge 256) { Stop-Hotpl8LeaseError 'lease_capacity' 'The agent pause ledger is full; wait for retained entries to expire.' }
            $until=$Now.AddMinutes($Minutes)
            $entry=[pscustomobject]@{leaseId=$LeaseId;owner=$Owner;minutes=$Minutes;acquiredAt=$Now.ToString('o');until=$until.ToString('o');releasedAt=$null;retainUntil=$until.AddHours(24).ToString('o')}
            Save-Hotpl8LeaseLedger $Directory @($entries+$entry)
        }
        return [pscustomobject]@{leaseId=$LeaseId;until=$entry.until;active=($null -eq $entry.releasedAt -and (ConvertFrom-Hotpl8LeaseTime $entry.until) -gt $Now);released=($null -ne $entry.releasedAt)}
    } finally { if ($lock) { $lock.Dispose() } }
}
function Invoke-Hotpl8LeaseRelease($Directory, $LeaseId, [datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
    if ($Directory -isnot [string] -or [string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Hotpl8LeaseId $LeaseId)) { Stop-Hotpl8LeaseError 'invalid_arguments' 'Expected a UUID leaseId.' }
    $Now=$Now.ToUniversalTime();$LeaseId=$LeaseId.ToLowerInvariant();$lock=$null
    try {
        $lock=Open-Hotpl8LeaseLock $Directory
        $ledger=Read-Hotpl8LeaseLedger $Directory
        $entries=@($ledger.entries | Where-Object { (ConvertFrom-Hotpl8LeaseTime $_.retainUntil) -gt $Now })
        $existing=@($entries | Where-Object leaseId -EQ $LeaseId)
        if ($existing.Count) {
            $entry=$existing[0]
            if ($null -eq $entry.releasedAt) {
                $entry.releasedAt=$Now.ToString('o')
                if ((ConvertFrom-Hotpl8LeaseTime $entry.retainUntil) -lt $Now.AddHours(24)) { $entry.retainUntil=$Now.AddHours(24).ToString('o') }
                Save-Hotpl8LeaseLedger $Directory $entries
            }
        } else {
            if ($entries.Count -ge 256) { Stop-Hotpl8LeaseError 'lease_capacity' 'The agent pause ledger is full; wait for retained entries to expire.' }
            $entry=[pscustomobject]@{leaseId=$LeaseId;owner=$null;minutes=$null;acquiredAt=$null;until=$null;releasedAt=$Now.ToString('o');retainUntil=$Now.AddHours(24).ToString('o')}
            Save-Hotpl8LeaseLedger $Directory @($entries+$entry)
        }
        return [pscustomobject]@{leaseId=$LeaseId;until=$entry.until;active=$false;released=$true}
    } finally { if ($lock) { $lock.Dispose() } }
}
