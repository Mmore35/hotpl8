# Optional plan discovery cannot change authentication, quota or eligibility.
function Read-Hotpl8ClaudePlans($Accounts,[string]$Directory,[string]$Cswap,[datetimeoffset]$Now=[datetimeoffset]::UtcNow,[scriptblock]$Reader=$null) {
    $path=Join-Path $Directory 'claude-plans.json'
    $cache=Read-Hotpl8Json $path
    $result=[pscustomobject]@{};$pending=@();$bindings=@{}
    foreach($account in @($Accounts)){
        $id=[string]$account.number
        if($id -notmatch '^[1-9][0-9]{0,3}$' -or $account.disabled -eq $true -or $account.enabled -eq $false){continue}
        # Both adapter surfaces must supply the same organization identity.
        # Do not weaken this to email-only for older/custom inventory schemas.
        $binding=Get-Hotpl8Hash ([string]$account.email+'|'+[string]$account.organizationUuid)
        $bindings[$id]=$binding;$prior=$cache.accounts.$id;$reuse=$false
        try{$reuse=$cache.schemaVersion -eq 1 -and $prior.identityKey -eq $binding -and [datetimeoffset]::Parse($prior.nextAttemptAt) -gt $Now -and [datetimeoffset]::Parse($prior.nextAttemptAt) -le $Now.AddDays(1)}catch{}
        if($reuse){$result|Add-Member NoteProperty $id $prior}else{$pending+=@($id)}
    }
    if(-not $pending.Count){return $result}
    $data=$null
    try{
        if($Reader){$data=& $Reader $pending}else{
            # Resolve Python beside cswap first (including venv/pipx installs).
            # Custom batch adapters keep working, with plan detection unavailable.
            $python=$null
            if([IO.Path]::GetFileName($Cswap) -eq 'cswap.exe'){
                foreach($candidate in @((Join-Path (Split-Path $Cswap -Parent) 'python.exe'),(Join-Path (Split-Path (Split-Path $Cswap -Parent) -Parent) 'python.exe'))){
                    if(Test-Path -LiteralPath $candidate){$python=$candidate;break}
                }
            }elseif([IO.Path]::GetFileName($Cswap) -eq 'cswap'){
                $line=Get-Content -LiteralPath $Cswap -TotalCount 1
                if($line -match '^#!(/[^\r\n]+/python[0-9.]*)\s*$' -and (Test-Path -LiteralPath $Matches[1])){$python=$Matches[1]}
            }
            if($python){
                $read=Invoke-Hotpl8Process $python (@((Join-Path $PSScriptRoot 'claude_plan.py'))+@($pending)) 45000
                if($read.exitCode -eq 0){$data=$read.output|ConvertFrom-Json}
            }
        }
    }catch{} # Authentication and provider output must not leak into diagnostics.
    foreach($id in $pending){
        $matches=@($data.accounts|Where-Object {[string]$_.slot -eq $id})
        $row=if($data.schemaVersion -eq 1 -and $matches.Count -eq 1){$matches[0]}else{$null}
        $status='unavailable';$profile=$null;$label=$null;$multiplier=$null;$retry=900
        if($row -and $row.identityKey -eq $bindings[$id]){
            if($row.status -in @('detected','partial','unsupported','identity_mismatch','no_credentials','rate_limited','authentication_required','unavailable')){$status=$row.status}
            $names=@{'claude-pro'='Pro';'claude-max-5x'='Max 5x';'claude-max-20x'='Max 20x'}
            if($status -eq 'detected' -and $names.ContainsKey([string]$row.profile)){
                $profile=[string]$row.profile;$label=$names[$profile]
                $multiplier=@{'claude-pro'=1;'claude-max-5x'=5;'claude-max-20x'=20}[$profile]
            }elseif($status -eq 'detected'){$status='unsupported'}
            if($status -eq 'partial' -and $row.label -in @('Pro','Max (tier unknown)','Team','Enterprise')){$label=[string]$row.label}
            if($status -eq 'rate_limited' -and (Test-Hotpl8Number $row.retryAfterSeconds)){$retry=[math]::Max(900,[math]::Min(86400,$row.retryAfterSeconds))}
        }
        $result|Add-Member NoteProperty $id ([pscustomobject]@{status=$status;identityKey=$bindings[$id];profile=$profile;label=$label;sessionMultiplier=$multiplier;source='anthropic-oauth-profile';observedAt=$Now.ToString('o');nextAttemptAt=$Now.AddSeconds($retry).ToString('o')})
    }
    # The caller holds the collector lock. Persist no credential or raw profile.
    try{Write-Hotpl8Text $path ([pscustomobject]@{schemaVersion=1;accounts=$result}|ConvertTo-Json -Depth 6)}catch{}
    return $result
}
function Test-Hotpl8DetectedPlan($Plan,[datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
    # Plan refresh is scheduled at 15 minutes. Leave a bounded scheduling grace
    # so a normal collector wake does not briefly erase the capacity weights.
    # This does not extend quota freshness or accept a failed/changed identity.
    if(-not $Plan -or $Plan.status -notin @('detected','partial')){return $false}
    try{
        $age=($Now-[datetimeoffset]::Parse($Plan.observedAt)).TotalSeconds
        return $age -ge -5 -and $age -le 1200
    }catch{return $false}
}
