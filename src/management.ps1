function ConvertTo-Hotpl8PolicyV2($Policy) {
    $next=$Policy|ConvertTo-Json -Depth 24|ConvertFrom-Json
    # Freeze legacy defaults before assigning a version, so migration cannot enable actions.
    $actions=Get-Hotpl8Actions $next $false
    if(-not $next.mode){$next|Add-Member NoteProperty mode 'automate' -Force}
    if($null -eq $next.switchEnabled){$next|Add-Member NoteProperty switchEnabled ([bool]$actions.switching) -Force}
    if($null -eq $next.probeEnabled){$next|Add-Member NoteProperty probeEnabled ([bool]$actions.probing) -Force}
    $next|Add-Member NoteProperty schemaVersion 2 -Force
    return $next
}
function Save-Hotpl8Policy([string]$Directory, $Policy, [string]$ExpectedHash) {
    Assert-Hotpl8Policy $Policy
    if($Policy.codex){Assert-CodexPolicy $Policy.codex}
    $path=Join-Path $Directory 'policy.json';$lock=$null
    try{
        $lock=[IO.File]::Open((Join-Path $Directory 'tick.lock'),'OpenOrCreate','ReadWrite','None')
        if($ExpectedHash -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $ExpectedHash){throw 'Policy changed; reload before saving.'}
        if(Test-Path -LiteralPath $path){Write-Hotpl8Text (Join-Path $Directory 'policy.previous.json') ([IO.File]::ReadAllText($path))}
        Write-Hotpl8Text $path ($Policy|ConvertTo-Json -Depth 24)
    }finally{if($lock){$lock.Dispose()}}
}
function Set-Hotpl8Account($Policy, [string]$Provider, [string]$Slot, [string]$Operation, [string]$Label) {
    $next=ConvertTo-Hotpl8PolicyV2 $Policy
    if($Provider -eq 'claude'){
        if($Slot -notmatch '^[1-9][0-9]{0,3}$' -or [int]$Slot -notin @($next.prefer)){throw 'Unknown Claude slot.'}
        $part=$next;$id=[int]$Slot
        if($Operation -eq 'rename'){
            if(-not $next.labels){$next|Add-Member NoteProperty labels ([pscustomobject]@{}) -Force}
            $next.labels|Add-Member NoteProperty $Slot $Label -Force
        }
    }else{
        $part=$next.codex;$id=$Slot
        $matches=@($part.slots|Where-Object id -EQ $Slot)
        if($matches.Count -ne 1){throw 'Unknown Codex slot.'}
        if($Operation -eq 'rename'){$matches[0]|Add-Member NoteProperty label $Label -Force}
    }
    switch($Operation){
        'disable'{$part|Add-Member NoteProperty disabled @(@($part.disabled|Where-Object {$_})+@($id)|Select-Object -Unique) -Force}
        'enable'{$part|Add-Member NoteProperty disabled @($part.disabled|Where-Object {$_ -ne $id}) -Force}
        'reserve'{$part|Add-Member NoteProperty reserve @(@($part.reserve|Where-Object {$_})+@($id)|Select-Object -Unique) -Force}
        'work'{$part|Add-Member NoteProperty reserve @($part.reserve|Where-Object {$_ -ne $id}) -Force}
    }
    return $next
}
function Set-Hotpl8Pause([string]$Directory, [int]$Minutes, [string]$Reason) {
    $lock=$null
    try{
        $lock=[IO.File]::Open((Join-Path $Directory 'tick.lock'),'OpenOrCreate','ReadWrite','None')
        $pause=@{schemaVersion=1;until=[datetimeoffset]::UtcNow.AddMinutes($Minutes).ToString('o');reason=$Reason}
        Write-Hotpl8Text (Join-Path $Directory 'automation-pause.json') ($pause|ConvertTo-Json)
    }finally{if($lock){$lock.Dispose()}}
}
function Get-Hotpl8Capabilities([string]$Directory) {
    $d=Get-Hotpl8Doctor $Directory
    $status=Read-Hotpl8Snapshot $Directory
    return [pscustomobject]@{schemaVersion=1;platform=$(if($env:OS -eq 'Windows_NT'){'windows-preview'}else{'source-only-unqualified'});runtime=$d.runtime;policyValid=$d.policyValid;collector=Get-Hotpl8Health (Read-Hotpl8Json (Join-Path $Directory 'collector.json'));providers=@{
        claude=@{installed=$d.cswapFound;configured=$d.claudeConfigured;freshAccounts=@($status.slots|Where-Object {$_.fresh -and (Test-Hotpl8FreshTimestamp $_.observedAt)}).Count;observe='supported adapter';selection='experimental';warming='experimental';authentication='native; verify with refresh'}
        codex=@{installed=$d.codexFound;configured=$d.codexConfigured;freshAccounts=@($status.providers.codex.slots|Where-Object {$_.status -eq 'ok' -and (Test-Hotpl8FreshTimestamp $_.observedAt)}).Count;observe='native app-server';selection='next-launch';warming='unqualified: no confirmed window benefit';authentication='native; verify with refresh'}
    };tray=($env:OS -eq 'Windows_NT');macHandoff='docs/plans/macos-handoff.md'}
}
function Invoke-Hotpl8Setup([string]$Directory, [string]$CodeDirectory, [switch]$Interactive) {
    [void][IO.Directory]::CreateDirectory($Directory)
    $path=Join-Path $Directory 'policy.json'
    if(-not (Test-Path -LiteralPath $path)){[IO.File]::Copy((Join-Path $CodeDirectory 'policy.example.json'),$path,$false)}
    if(-not $Interactive){
        'Monitoring policy ready. Use hotpl8 setup -Interactive for guided enrollment.'
        'Codex: hotpl8 enroll -Slot main -AccountHome PATH'
        'Claude: sign in and enroll using cswap, then hotpl8 enroll -Provider claude -Slot NUMBER'
        'Next: hotpl8 refresh; hotpl8 explain; hotpl8'
        return
    }
    if([Console]::IsInputRedirected){throw 'Interactive setup needs a terminal. Use hotpl8 enroll for scripting.'}
    $provider=Read-Host 'Provider (codex / claude; blank cancels)'
    if(-not $provider){return}
    if($provider -notin @('claude','codex')){throw 'Choose claude or codex.'}
    $slot=Read-Host 'Account slot (existing cswap number for Claude; label such as main for Codex)'
    if(-not $slot){return}
    $label=Read-Host 'Display label (optional)'
    if($provider -eq 'codex'){
        $accountPath=Read-Host 'Full path to the independently signed-in native Codex home'
        if(-not $accountPath){return}
        & (Join-Path $CodeDirectory 'setup-codex.ps1') -Slot $slot -AccountHome $accountPath -Label $label -StateDirectory $Directory
    }else{Add-Hotpl8ClaudeAccount $Directory $slot $label}
    'Account enrolled. Run hotpl8 refresh, then hotpl8. Automation is configured separately.'
}
function Add-Hotpl8ClaudeAccount([string]$Directory,[string]$Slot,[string]$Label) {
    if($Slot -notmatch '^[1-9][0-9]{0,3}$'){throw 'Claude slot must be an existing cswap account number.'}
    $path=Join-Path $Directory 'policy.json';$hash=(Get-FileHash $path -Algorithm SHA256).Hash
    $p=ConvertTo-Hotpl8PolicyV2 (Read-Hotpl8Json $path)
    $exe=Resolve-CswapExecutable '';if(-not $exe){throw 'Install claude-swap and enroll with cswap first.'}
    $read=Invoke-Hotpl8Process $exe @('list','--json') 20000
    if($read.exitCode -ne 0){throw 'Could not read cswap inventory.'}
    $data=$read.output|ConvertFrom-Json
    if($data.schemaVersion -ne 1 -or @($data.accounts|Where-Object number -EQ ([int]$Slot)).Count -ne 1){throw 'Slot not found in supported cswap inventory.'}
    $p|Add-Member NoteProperty prefer @(@($p.prefer)+@([int]$Slot)|Select-Object -Unique) -Force
    if(-not $p.labels){$p|Add-Member NoteProperty labels ([pscustomobject]@{}) -Force}
    if($Label){$p.labels|Add-Member NoteProperty $Slot $Label -Force}
    Save-Hotpl8Policy $Directory $p $hash
    'Claude account enrolled for monitoring. Native credentials remain managed by cswap.'
}
