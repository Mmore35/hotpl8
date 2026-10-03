# Parking takes an unfunded or unreadable account out of policy and keeps what is
# needed to bring it back. policy.json describes only active accounts, so every
# reader treats a parked account as absent without knowing that parking exists.
function Read-Hotpl8Parked([string]$Directory,[switch]$Strict) {
    $path=Join-Path $Directory 'parked.json'
    $file=Read-Hotpl8Json $path
    if(-not $file -or $file.schemaVersion -ne 1){
        # Never replace a record file this build cannot read.
        if($Strict -and (Test-Path -LiteralPath $path)){throw 'parked.json is unreadable; it was not changed.'}
        return @()
    }
    return @($file.accounts|Where-Object {$_ -and $_.provider -is [string] -and $_.slot -is [string]})
}
function Write-Hotpl8Parked([string]$Directory,$Records) {
    $lock=$null
    try{
        $lock=[IO.File]::Open((Join-Path $Directory 'tick.lock'),'OpenOrCreate','ReadWrite','None')
        Invoke-Hotpl8ControlWrite $Directory { Write-Hotpl8Text (Join-Path $Directory 'parked.json') (([pscustomobject]@{schemaVersion=1;accounts=@($Records)})|ConvertTo-Json -Depth 12) }
    }finally{if($lock){$lock.Dispose()}}
}
function Invoke-Hotpl8ParkRetry([scriptblock]$Action,[int]$TimeoutMs=30000) {
    # A collection holds tick.lock for several seconds. Wait for it rather than
    # fail the owner's command; each guarded write below is safe to repeat.
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while($true){
        try{return (& $Action)}
        catch{
            $cause=$_.Exception;while($cause.InnerException){$cause=$cause.InnerException}
            if($cause -isnot [IO.IOException] -or $cause -is [IO.FileNotFoundException] -or $cause -is [IO.DirectoryNotFoundException] -or $clock.ElapsedMilliseconds -ge $TimeoutMs){throw}
            Start-Sleep -Milliseconds 250
        }
    }
}
function Get-Hotpl8ParkPolicyPart($Policy,[string]$Provider) {
    $driver=Get-Hotpl8ProviderDriver (Get-Hotpl8ConfiguredProvider $Policy $Provider).driver
    $part=if($Policy.schemaVersion -eq 3){$Policy.providers.$Provider}elseif($driver.provider -eq 'claude'){$Policy}else{$Policy.codex}
    return [pscustomobject]@{driver=$driver;part=$part}
}
function Test-Hotpl8AccountEnrolled([string]$Directory,[string]$Provider,[string]$Slot) {
    try{return (@(Get-Hotpl8ProviderAccounts (Read-Hotpl8Json (Join-Path $Directory 'policy.json'))|Where-Object {$_.provider -ceq $Provider -and $_.slot -ceq $Slot}).Count -gt 0)}catch{return $false}
}
function Get-Hotpl8ParkClaudeRow([string]$Slot) {
    $exe=Resolve-CswapExecutable '';if(-not $exe){return $null}
    $read=Invoke-Hotpl8Process $exe @('list','--json') 20000
    if($read.exitCode -ne 0){return $null}
    $data=$read.output|ConvertFrom-Json
    if($data.schemaVersion -ne 1){return $null}
    $rows=@($data.accounts|Where-Object {[string]$_.number -eq $Slot})
    if($rows.Count -eq 1){return $rows[0]}
    return [pscustomobject]@{missing=$true}
}
function Get-Hotpl8ParkIdentity([string]$Directory,[string]$Provider,[string]$Slot,[string]$AccountHome,[string]$Executable,[switch]$Cached) {
    # Best effort: an unknown identity falls back to matching the slot alone.
    try{
        $driver=Get-Hotpl8ProviderDriver (Get-Hotpl8ProviderDefinition $Provider).driver
        if($driver.slotKind -eq 'numeric'){
            $row=Get-Hotpl8ParkClaudeRow $Slot
            # The binding plan discovery already uses: account plus organization.
            if($row -and -not $row.missing -and $row.email){return (Get-Hotpl8Hash ([string]$row.email+'|'+[string]$row.organizationUuid))}
            return $null
        }
        if(-not $AccountHome){return $null}
        if($Cached){
            $row=(Read-Hotpl8Json (Join-Path (Get-Hotpl8ProviderStateDirectory $Directory $Provider) 'codex-state.json')).slots.$Slot
            if($row.identityKey -and $row.binding -eq (Get-Hotpl8Hash ([IO.Path]::GetFullPath($AccountHome)))){return [string]$row.identityKey}
            return $null
        }
        $read=Read-CodexQuota ([IO.Path]::GetFullPath($AccountHome)) $Executable 5000
        if($read.status -eq 'ok' -and $read.identityKey){return [string]$read.identityKey}
    }catch{}
    return $null
}
function Move-Hotpl8ParkItem($Items,$Item,[int]$Index,[scriptblock]$Key={[string]$args[0]}) {
    $list=New-Object Collections.ArrayList;$wanted=& $Key $Item
    foreach($entry in @($Items)){if((& $Key $entry) -cne $wanted){[void]$list.Add($entry)}}
    $list.Insert([Math]::Max(0,[Math]::Min($Index,$list.Count)),$Item)
    return ,@($list.ToArray())
}
function New-Hotpl8ParkRecord($Policy,[string]$Directory,[string]$Provider,[string]$Slot,[string]$Reason,$LastReadingAt) {
    $target=Get-Hotpl8ParkPolicyPart $Policy $Provider;$part=$target.part
    $record=[ordered]@{provider=$Provider;slot=$Slot;label='';home=$null;position=-1;slotPosition=-1;reason=$Reason;lastReadingAt=$LastReadingAt;parkedAt=[datetimeoffset]::UtcNow.ToString('o')}
    if($target.driver.slotKind -eq 'numeric'){
        if($Slot -notmatch '^[1-9][0-9]{0,3}$' -or [int]$Slot -notin @($part.prefer)){throw 'Unknown native account slot.'}
        $id=[int]$Slot
        $record.label=[string]$part.labels.$Slot
    }else{
        $found=@($part.slots|Where-Object id -CEQ $Slot)
        if($found.Count -ne 1){throw 'Unknown native account slot.'}
        $id=$Slot
        $record.label=[string]$found[0].label;$record.home=[string]$found[0].home
        $record.slotPosition=[array]::IndexOf(@($part.slots|ForEach-Object {[string]$_.id}),$Slot)
    }
    $record.position=[array]::IndexOf(@($part.prefer|ForEach-Object {[string]$_}),$Slot)
    $record.reserve=($id -in @($part.reserve));$record.disabled=($id -in @($part.disabled))
    $record.weight=$part.weights.$Slot;$record.capacity=$part.capacity.$Slot
    $record.warmExcluded=(($Provider+':'+$Slot) -cin @($Policy.automation.warmExcluded))
    $record.identity=Get-Hotpl8ParkIdentity $Directory $Provider $Slot $record.home '' -Cached
    return [pscustomobject]$record
}
function Invoke-Hotpl8Park([string]$Directory,[string]$Provider,[string]$Slot,[string]$Reason='manual',$LastReadingAt=$null,$Snapshot=$null) {
    $path=Join-Path $Directory 'policy.json'
    Invoke-Hotpl8ParkRetry {
        $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        # Read after hashing so a concurrent edit is rejected when committing.
        $policy=Read-Hotpl8Json $path;Assert-Hotpl8Policy $policy
        $target=Get-Hotpl8ParkPolicyPart $policy $Provider
        if($target.driver.slotKind -eq 'numeric' -and $Snapshot -and (Test-Hotpl8FreshTimestamp $Snapshot.generatedAt)){
            $payload=if($Provider -ceq 'claude' -and -not $Snapshot.providers.claude){$Snapshot}else{$Snapshot.providers.$Provider}
            if(@($payload.slots|Where-Object {$_ -and [string]$_.slot -eq $Slot -and $_.active}).Count){throw 'That is the Claude login in use right now. Switch Claude to another account, then park this one.'}
        }
        $record=New-Hotpl8ParkRecord $policy $Directory $Provider $Slot $Reason $LastReadingAt
        $next=Set-Hotpl8Account $policy $Provider $Slot 'remove' ''
        if($next.automation.warmExcluded){$next.automation.warmExcluded=@($next.automation.warmExcluded|Where-Object {$_ -cne ($Provider+':'+$Slot)})}
        # An enrolled account always wins over a leftover record for the same slot.
        $enrolled=@(Get-Hotpl8ProviderAccounts $next|ForEach-Object {$_.provider+':'+$_.slot})
        $records=@(Read-Hotpl8Parked $Directory -Strict|Where-Object {($_.provider+':'+$_.slot) -cnotin $enrolled -and ($_.provider+':'+$_.slot) -cne ($Provider+':'+$Slot)})+@($record)
        # Record first: a crash before the policy save leaves a record that the
        # still-enrolled account overrides, never an account that was forgotten.
        Write-Hotpl8Parked $Directory $records
        Save-Hotpl8Policy $Directory $next $hash
        [pscustomobject]@{record=$record;remaining=@(Get-Hotpl8ProviderAccounts $next|Where-Object {$_.provider -ceq $Provider -and -not $_.disabled})}
    }
}
function Restore-Hotpl8ParkedSettings([string]$Directory,[string]$Provider,[string]$Slot,$Record,[switch]$KeepLabel) {
    $path=Join-Path $Directory 'policy.json'
    Invoke-Hotpl8ParkRetry {
        $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $policy=Read-Hotpl8Json $path;Assert-Hotpl8Policy $policy
        $next=if($policy.schemaVersion -ne 3 -and ($Record.disabled -or $null -ne $Record.capacity -or $Record.warmExcluded)){ConvertTo-Hotpl8PolicyV2 $policy}else{Copy-Hotpl8ProviderValue $policy}
        $target=Get-Hotpl8ParkPolicyPart $next $Provider;$part=$target.part
        if($target.driver.slotKind -eq 'numeric'){
            $id=[int]$Slot
            if($id -notin @($part.prefer)){return $false}
            if($Record.label -and -not $KeepLabel){
                if(-not $part.labels){$part|Add-Member NoteProperty labels ([pscustomobject]@{}) -Force}
                $part.labels|Add-Member NoteProperty $Slot ([string]$Record.label) -Force
            }
        }else{
            $id=$Slot;$found=@($part.slots|Where-Object id -CEQ $Slot)
            if($found.Count -ne 1){return $false}
            if($Record.label -and -not $KeepLabel){$found[0]|Add-Member NoteProperty label ([string]$Record.label) -Force}
            if($Record.slotPosition -ge 0){$part.slots=Move-Hotpl8ParkItem $part.slots $found[0] ([int]$Record.slotPosition) {[string]$args[0].id}}
        }
        if($Record.position -ge 0 -and $id -in @($part.prefer)){$part.prefer=Move-Hotpl8ParkItem $part.prefer $id ([int]$Record.position)}
        foreach($flag in @('reserve','disabled')){
            if($Record.$flag -and $id -notin @($part.$flag)){$part|Add-Member NoteProperty $flag @(@($part.$flag|Where-Object {$null -ne $_})+@($id)) -Force}
        }
        foreach($map in @('weights','capacity')){
            $value=if($map -eq 'weights'){$Record.weight}else{$Record.capacity}
            if($null -eq $value){continue}
            if(-not $part.$map){$part|Add-Member NoteProperty $map ([pscustomobject]@{}) -Force}
            $part.$map|Add-Member NoteProperty $Slot $value -Force
        }
        $exclusion=$Provider+':'+$Slot
        if($Record.warmExcluded -and $exclusion -cnotin @($next.automation.warmExcluded)){
            if(-not $next.automation){$next|Add-Member NoteProperty automation ([pscustomobject]@{}) -Force}
            $next.automation|Add-Member NoteProperty warmExcluded @(@($next.automation.warmExcluded|Where-Object {$null -ne $_})+@($exclusion)) -Force
        }
        Save-Hotpl8Policy $Directory $next $hash
        return $true
    }
}
function Restore-Hotpl8ParkedAccount([string]$Directory,[string]$Provider,[string]$Slot,[string]$AccountHome,[string]$Executable,[switch]$KeepLabel) {
    # Called once an account has just been enrolled. A returning subscription gets
    # its saved settings back, whichever route enrolled it.
    $records=@(Read-Hotpl8Parked $Directory)
    $mine=@($records|Where-Object {$_.provider -ceq $Provider})
    if(-not $mine.Count){return}
    $current=Get-Hotpl8ParkIdentity $Directory $Provider $Slot $AccountHome $Executable
    $record=$null;$stale=$null
    $bySlot=@($mine|Where-Object {$_.slot -ceq $Slot})
    if($bySlot.Count){
        # The same slot name can come to hold a different subscription.
        if($bySlot[0].identity -and $current -and $bySlot[0].identity -cne $current){$stale=$bySlot[0]}else{$record=$bySlot[0]}
    }
    # A new sign-in can give a returning subscription a new slot name.
    if(-not $record -and $current){$record=@($mine|Where-Object {$_.identity -and $_.identity -ceq $current})|Select-Object -First 1}
    if(-not $record -and -not $stale){return}
    $restored=if($record){Restore-Hotpl8ParkedSettings $Directory $Provider $Slot $record -KeepLabel:$KeepLabel}else{$false}
    $drop=@(@($record,$stale)|Where-Object {$_}|ForEach-Object {$_.provider+':'+$_.slot})
    Invoke-Hotpl8ParkRetry {Write-Hotpl8Parked $Directory @(Read-Hotpl8Parked $Directory -Strict|Where-Object {($_.provider+':'+$_.slot) -cnotin $drop})}
    if($restored){'Its saved settings were restored from parking.'}
    if($stale){'A different account now uses this slot; the old parking record was discarded.'}
}
function Invoke-Hotpl8Unpark([string]$Directory,[string]$Provider,[string]$Slot,[string]$Executable,[switch]$Force) {
    $found=@(Read-Hotpl8Parked $Directory -Strict|Where-Object {$_.provider -ceq $Provider -and $_.slot -ceq $Slot})
    if($found.Count -ne 1){throw 'No parked account matches. Run hotpl8 unpark to list parked accounts.'}
    $record=$found[0]
    if(Test-Hotpl8AccountEnrolled $Directory $Provider $Slot){
        Invoke-Hotpl8ParkRetry {Write-Hotpl8Parked $Directory @(Read-Hotpl8Parked $Directory -Strict|Where-Object {($_.provider+':'+$_.slot) -cne ($Provider+':'+$Slot)})}
        return [pscustomobject]@{record=$record;enrolled=$true;needsSignIn=$false;messages=@('That account is already enrolled; its parking record was cleared.')}
    }
    $driver=Get-Hotpl8ProviderDriver (Get-Hotpl8ProviderDefinition $Provider).driver
    if($driver.slotKind -eq 'numeric'){
        # Enrollment accepts any inventory row, so check before returning an
        # account that still cannot be read.
        $row=Get-Hotpl8ParkClaudeRow $Slot
        if($row.missing){throw ('That account is no longer signed in on this machine. Connect it again with hotpl8 add -Provider '+$Provider+'; its saved settings return with it.')}
        if(-not $Force -and $row.usageStatus -in @('relogin_required','no_credentials')){return [pscustomobject]@{record=$record;enrolled=$false;needsSignIn=$true;messages=@()}}
    }
    try{$messages=@(Add-Hotpl8RegisteredAccount $Directory $Provider $Slot ([string]$record.home) ([string]$record.label) $Executable)}
    catch{
        if($_.Exception.Message -ne 'Native subscription identity or transport is not ready for enrollment.'){throw}
        throw ('That account cannot be read yet, so it stays parked. Sign in again with hotpl8 add -Provider '+$Provider+'; its saved settings return with it.')
    }
    return [pscustomobject]@{record=$record;enrolled=(Test-Hotpl8AccountEnrolled $Directory $Provider $Slot);needsSignIn=$false;messages=@($messages|Where-Object {$_ -is [string]})}
}
function Get-Hotpl8ParkName($Record) {
    if($Record.label){return [string]$Record.label}
    return ([string]$Record.provider+' '+[string]$Record.slot)
}
function Resolve-Hotpl8ParkProvider($Accounts,[string]$Slot) {
    $owners=@($Accounts|Where-Object {$_.slot -ceq $Slot}|ForEach-Object {[string]$_.provider}|Select-Object -Unique)
    if($owners.Count -eq 1){return $owners[0]}
    if($owners.Count -gt 1){throw 'More than one provider has that slot. Add -Provider.'}
    throw 'Unknown native account slot.'
}
function Read-Hotpl8ParkAnswer([string]$Question,[bool]$Default) {
    [Console]::Out.Write($Question+' ')
    $answer=[Console]::In.ReadLine()
    if($null -eq $answer -or -not $answer.Trim()){return $Default}
    return ($answer.Trim() -match '^(y|yes)$')
}
function Format-Hotpl8ParkCandidates($Candidates) {
    $width=(@($Candidates|ForEach-Object {([string]$_.label).Length})|Measure-Object -Maximum).Maximum
    foreach($candidate in @($Candidates)){
        $detail=Format-Hotpl8ParkReason $candidate
        if($candidate.reason -eq 'dormant'){try{$detail+=' (last: '+[datetimeoffset]::Parse([string]$candidate.lastReadingAt).ToLocalTime().ToString('MMM d',[Globalization.CultureInfo]::InvariantCulture)+')'}catch{}}
        '  '+([string]$candidate.label).PadRight($width)+'    '+$detail
    }
    # An unreadable account is not proof of a cancellation, except here.
    if(@($Candidates|Where-Object {$_.reason -eq 'dormant' -and $_.family -eq 'claude'}).Count){'  Claude refuses sign-in without a Pro or Max plan, so an account you cannot sign back into is canceled.'}
}
function Format-Hotpl8Parked($Results) {
    foreach($result in @($Results)){
        $rest=@($result.remaining|ForEach-Object {if($_.label){[string]$_.label}else{[string]$_.slot}})
        'Parked '+(Get-Hotpl8ParkName $result.record)+'. '+$(if($rest.Count){'Still enrolled: '+($rest -join ', ')+'.'}else{'No other '+$result.record.provider+' account is enrolled.'})
        'Undo: hotpl8 unpark -Provider '+$result.record.provider+' -Slot '+$result.record.slot
    }
}
