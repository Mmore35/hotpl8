# Offline contracts for parking: detection, park/unpark round trips and the CLI.
# Fictional accounts only; native readers are replaced, so no account is contacted.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($file in @('common','config','diagnostics','insights','management','native')){. (Join-Path $root ('src/'+$file+'.ps1'))}
. (Join-Path $root 'src/providers/claude.ps1')
. (Join-Path $root 'src/providers/codex.ps1')
. (Join-Path $PSScriptRoot 'fixtures/frame.ps1')
$script:passed=0;$script:failed=0
function Assert($Value,[string]$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check([string]$Name,[scriptblock]$Body){
    # Freshness checks use the real clock; a slow, loaded run must not age the fixtures.
    $script:now=[datetimeoffset]::UtcNow
    try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message+' at '+$_.InvocationInfo.ScriptLineNumber}}
function Clone($Value){$Value|ConvertTo-Json -Depth 24|ConvertFrom-Json}
function Reject([scriptblock]$Body,[string]$Pattern='.'){$rejected=$false;try{& $Body|Out-Null}catch{$rejected=$_.Exception.Message -match $Pattern};Assert $rejected ('expected rejection matching '+$Pattern)}
function New-StateDirectory {$d=Join-Path $script:dir ([guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($d);return $d}
function Write-Policy([string]$Directory,$Policy){Write-Hotpl8Text (Join-Path $Directory 'policy.json') ($Policy|ConvertTo-Json -Depth 24)}
function Read-Policy([string]$Directory){Read-Hotpl8Json (Join-Path $Directory 'policy.json')}
# Fictional native inventory. Never resolve or run an installed account manager.
$script:inventory=@()
function Resolve-CswapExecutable([string]$CswapExecutable){return 'fixture-cswap'}
function Invoke-Hotpl8Process($Executable,$Arguments,$TimeoutMs){
    Assert ($Executable -eq 'fixture-cswap' -and $Arguments[0] -eq 'list') 'only the fixture inventory may be read'
    return [pscustomobject]@{exitCode=0;output=([pscustomobject]@{schemaVersion=1;accounts=@($script:inventory)}|ConvertTo-Json -Depth 8)}
}
$script:codexReads=@{}
function Read-CodexQuota([string]$AccountHome,[string]$Executable,[int]$TimeoutMs,[string]$WorkingDirectory,[switch]$IncludeAccessToken,[switch]$RefreshToken,[switch]$IdentityOnly){
    $read=$script:codexReads[[IO.Path]::GetFullPath($AccountHome)]
    if(-not $read){return [pscustomobject]@{status='home_missing'}}
    return $read
}
function New-ClaudeRow([int]$Number,[string]$Status,$LastGoodAge=$null){
    $row=[ordered]@{number=$Number;email=('fixture'+$Number+'@example.test');organizationUuid=('org-'+$Number);usageStatus=$Status;usage=$null}
    if($Status -eq 'ok'){$row.usage=@{fiveHour=@{pct=10;resetsAt='2099-01-01T00:00:00Z'};sevenDay=@{pct=20;resetsAt='2099-01-05T00:00:00Z'}};$row.usageAgeSeconds=5}
    if($null -ne $LastGoodAge){$row.lastGoodAgeSeconds=$LastGoodAge}
    return [pscustomobject]$row
}
$script:dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-parking-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($script:dir)
$now=[datetimeoffset]::UtcNow
$claudePolicy=@{schemaVersion=2;mode='monitor';prefer=@(2,1,3);reserve=@(2);pattern='even';weights=@{'2'=2;'1'=1};labels=@{'1'='Everyday';'2'='Old plan';'3'='Spare'};capacity=@{'2'=@{weekly=1;evidence='user-supplied relative capacity estimate'}};automation=@{warmExcluded=@('claude:2')}}
try{
    Check 'Codex plan names pass through when well formed and stay unknown otherwise' {
        Assert ((ConvertTo-Hotpl8CodexPlanType 'prolite') -ceq 'prolite')
        Assert ((ConvertTo-Hotpl8CodexPlanType 'free') -ceq 'free')
        foreach($bad in @($null,'','Pro Plus',('x'*30),'<script>',7)){Assert ((ConvertTo-Hotpl8CodexPlanType $bad) -eq 'unknown') ('accepted '+$bad)}
    }
    Check 'detector names week-long sign-in failures and ended plans, and nothing else' {
        $policy=Clone @{schemaVersion=2;mode='monitor';prefer=@(1,2,3,4,5);disabled=@(5);labels=@{'2'='Old plan'};codex=@{slots=@(@{id='a';home='/fixture/a';label='Ended'},@{id='b';home='/fixture/b';label='Paid'},@{id='c';home='/fixture/c';label='Signed out'},@{id='d';home='/fixture/d';label='Recent'});prefer=@('a','b','c','d')}}
        $old=$now.AddDays(-36).ToString('o');$recent=$now.AddDays(-2).ToString('o')
        $snapshot=Clone @{generatedAt=$now.ToString('o');slots=@(
            @{slot=1;status='relogin_required';active=$true;lastGoodAt=$old},
            @{slot=2;status='relogin_required';lastGoodAt=$old},
            @{slot=3;status='relogin_required';lastGoodAt=$recent},
            @{slot=4;status='no_credentials'},
            @{slot=5;status='relogin_required';lastGoodAt=$old});providers=@{codex=@{slots=@(
            @{id='a';status='ok';planType='free';observedAt=$now.ToString('o')},
            @{id='b';status='ok';planType='prolite';observedAt=$now.ToString('o')},
            @{id='c';status='authentication_required';observedAt=$now.AddDays(-10).ToString('o')},
            @{id='d';status='authentication_required';observedAt=$recent})}}}
        $found=@(Get-Hotpl8ParkCandidates $snapshot $policy $now)
        $keys=@($found|ForEach-Object {$_.provider+':'+$_.slot+':'+$_.reason})
        Assert (($keys -join ',') -ceq 'claude:2:dormant,codex:a:canceled,codex:c:dormant') ('found '+($keys -join ','))
        Assert ($found[0].label -ceq 'Old plan' -and $found[0].days -eq 36)
        Assert ((Format-Hotpl8ParkReason $found[0]) -ceq 'no reading for 36 days')
        Assert ((Format-Hotpl8ParkReason $found[1]) -ceq 'plan ended (now free)')
        $snapshot.generatedAt=$now.AddHours(-2).ToString('o')
        Assert (@(Get-Hotpl8ParkCandidates $snapshot $policy $now).Count -eq 0) 'stale snapshots advise nothing'
    }
    Check 'parking removes every trace from policy' {
        $d=New-StateDirectory;Write-Policy $d (Clone $claudePolicy)
        $script:inventory=@((New-ClaudeRow 1 'ok'),(New-ClaudeRow 2 'relogin_required' 3110400),(New-ClaudeRow 3 'ok'))
        $result=Invoke-Hotpl8Park $d claude '2' 'dormant' $now.AddDays(-36).ToString('o')
        $p=Read-Policy $d
        Assert ((@($p.prefer) -join ',') -eq '1,3' -and 2 -notin @($p.reserve) -and -not $p.labels.'2' -and -not $p.weights.'2' -and -not $p.capacity.'2')
        Assert ('claude:2' -cnotin @($p.automation.warmExcluded)) 'warm exclusion removed with the account'
        Assert-Hotpl8Policy $p
        $record=@(Read-Hotpl8Parked $d)
        Assert ($record.Count -eq 1 -and $record[0].label -ceq 'Old plan' -and $record[0].position -eq 0 -and $record[0].reserve -and $record[0].weight -eq 2 -and $record[0].warmExcluded -and $record[0].identity)
        Assert (@($result.remaining|ForEach-Object label) -join ',' -ceq 'Everyday,Spare')
        Assert (@(Get-Hotpl8ProviderAccounts $p).Count -eq 2)
    }
    Check 'unpark restores label, order, reserve, weight, capacity and warm exclusion' {
        $d=New-StateDirectory;Write-Policy $d (Clone $claudePolicy)
        $script:inventory=@((New-ClaudeRow 1 'ok'),(New-ClaudeRow 2 'relogin_required' 3110400),(New-ClaudeRow 3 'ok'))
        $null=Invoke-Hotpl8Park $d claude '2' 'dormant'
        $held=Invoke-Hotpl8Unpark $d claude '2' ''
        Assert ($held.needsSignIn -and -not $held.enrolled -and @(Read-Hotpl8Parked $d).Count -eq 1) 'an unreadable account is not returned without consent'
        $script:inventory=@((New-ClaudeRow 1 'ok'),(New-ClaudeRow 2 'ok'),(New-ClaudeRow 3 'ok'))
        $back=Invoke-Hotpl8Unpark $d claude '2' ''
        $p=Read-Policy $d
        Assert ($back.enrolled -and (@($p.prefer) -join ',') -eq '2,1,3' -and 2 -in @($p.reserve) -and $p.labels.'2' -ceq 'Old plan' -and $p.weights.'2' -eq 2 -and $p.capacity.'2'.weekly -eq 1)
        Assert ('claude:2' -cin @($p.automation.warmExcluded) -and @(Read-Hotpl8Parked $d).Count -eq 0)
        Assert-Hotpl8Policy $p
    }
    Check 'forced unpark returns an account that still needs sign-in' {
        $d=New-StateDirectory;Write-Policy $d (Clone $claudePolicy)
        $script:inventory=@((New-ClaudeRow 1 'ok'),(New-ClaudeRow 2 'relogin_required' 3110400),(New-ClaudeRow 3 'ok'))
        $null=Invoke-Hotpl8Park $d claude '2' 'dormant'
        $back=Invoke-Hotpl8Unpark $d claude '2' '' -Force
        Assert ($back.enrolled -and 2 -in @((Read-Policy $d).prefer))
    }
    Check 'the Claude login in use cannot be parked, and unknown slots are refused' {
        $d=New-StateDirectory;Write-Policy $d (Clone $claudePolicy)
        $snapshot=Clone @{generatedAt=$now.ToString('o');slots=@(@{slot=1;status='ok';active=$true})}
        Reject {Invoke-Hotpl8Park $d claude '1' 'manual' $null $snapshot} 'login in use'
        Reject {Invoke-Hotpl8Park $d claude '9' 'manual'} 'Unknown'
        Assert ((@((Read-Policy $d).prefer) -join ',') -eq '2,1,3' -and @(Read-Hotpl8Parked $d).Count -eq 0)
    }
    Check 'an enrolled account outranks a leftover record, and an unreadable record file blocks changes' {
        $d=New-StateDirectory;Write-Policy $d (Clone $claudePolicy)
        Write-Hotpl8Text (Join-Path $d 'parked.json') (@{schemaVersion=1;accounts=@(@{provider='claude';slot='1';label='leftover'})}|ConvertTo-Json -Depth 6)
        $null=Invoke-Hotpl8Park $d claude '3' 'manual'
        Assert ((@(Read-Hotpl8Parked $d)|ForEach-Object slot) -join ',' -eq '3') 'leftover for an enrolled slot pruned'
        $d=New-StateDirectory;Write-Policy $d (Clone $claudePolicy)
        Write-Hotpl8Text (Join-Path $d 'parked.json') '{"schemaVersion":9}'
        Reject {Invoke-Hotpl8Park $d claude '3' 'manual'} 'unreadable'
        Assert ((@((Read-Policy $d).prefer) -join ',') -eq '2,1,3') 'policy unchanged'
    }
    Check 'Codex homes return to their place, and a reused slot name discards the old record' {
        $d=New-StateDirectory;$homes=@{}
        foreach($name in @('one','two','three')){$homes[$name]=Join-Path $d $name;[void][IO.Directory]::CreateDirectory($homes[$name])}
        # Version 3 enrolls through the shared native reader that this suite replaces.
        Write-Policy $d (Clone @{schemaVersion=3;mode='monitor';providers=@{codex=@{slots=@(@{id='one';home=$homes.one;label='One'},@{id='two';home=$homes.two;label='Two'},@{id='three';home=$homes.three;label='Three'});prefer=@('one','two','three')}}})
        Write-Hotpl8Text (Join-Path $d 'codex-state.json') (@{schemaVersion=1;slots=@{two=@{binding=(Get-Hotpl8Hash ([IO.Path]::GetFullPath($homes.two)));identityKey='identity-two'}}}|ConvertTo-Json -Depth 6)
        $null=Invoke-Hotpl8Park $d codex 'two' 'canceled'
        $p=Read-Policy $d
        Assert ((@($p.providers.codex.slots|ForEach-Object id) -join ',') -eq 'one,three' -and (@(Read-Hotpl8Parked $d)[0].identity) -ceq 'identity-two')
        foreach($name in @('one','two','three')){$script:codexReads[[IO.Path]::GetFullPath($homes[$name])]=[pscustomobject]@{status='ok';identityKey=('identity-'+$name);standardTransport=$true;planType='plus'}}
        $back=Invoke-Hotpl8Unpark $d codex 'two' ''
        $p=Read-Policy $d
        Assert ($back.enrolled -and (@($p.providers.codex.slots|ForEach-Object id) -join ',') -eq 'one,two,three' -and (@($p.providers.codex.prefer) -join ',') -eq 'one,two,three' -and (@($p.providers.codex.slots)[1].label) -ceq 'Two')
        $null=Invoke-Hotpl8Park $d codex 'two' 'canceled'
        $script:codexReads[[IO.Path]::GetFullPath($homes.two)]=[pscustomobject]@{status='ok';identityKey='identity-someone-else';standardTransport=$true;planType='plus'}
        $messages=@(Add-Hotpl8RegisteredAccount $d codex 'two' $homes.two 'New' '')
        Assert (($messages -join ' ') -match 'different account' -and @(Read-Hotpl8Parked $d).Count -eq 0 -and (@((Read-Policy $d).providers.codex.slots)[-1].label) -ceq 'New')
    }
    Check 'a returning subscription under a new slot name gets its settings back' {
        $d=New-StateDirectory;$homes=@{old=(Join-Path $d 'old');new=(Join-Path $d 'new')}
        foreach($h in $homes.Values){[void][IO.Directory]::CreateDirectory($h)}
        Write-Policy $d (Clone @{schemaVersion=3;mode='monitor';providers=@{codex=@{slots=@(@{id='keep';home=(Join-Path $d 'keep');label='Keep'},@{id='old';home=$homes.old;label='Returning'});prefer=@('old','keep');reserve=@('old')}}})
        Write-Hotpl8Text (Join-Path $d 'codex-state.json') (@{schemaVersion=1;slots=@{old=@{binding=(Get-Hotpl8Hash ([IO.Path]::GetFullPath($homes.old)));identityKey='identity-returning'}}}|ConvertTo-Json -Depth 6)
        $null=Invoke-Hotpl8Park $d codex 'old' 'canceled'
        $script:codexReads[[IO.Path]::GetFullPath((Join-Path $d 'keep'))]=[pscustomobject]@{status='ok';identityKey='identity-keep';standardTransport=$true}
        $script:codexReads[[IO.Path]::GetFullPath($homes.new)]=[pscustomobject]@{status='ok';identityKey='identity-returning';standardTransport=$true}
        $null=@(Add-Hotpl8RegisteredAccount $d codex 'fresh' $homes.new '' '')
        $p=Read-Policy $d
        Assert ('fresh' -in @($p.providers.codex.reserve) -and (@($p.providers.codex.prefer) -join ',') -eq 'fresh,keep' -and @(Read-Hotpl8Parked $d).Count -eq 0)
    }
    Check 'dashboard names a week-long absence and a parked account that reads again' {
        $policy=Clone @{schemaVersion=2;mode='monitor';prefer=@(1,2);labels=@{'2'='Old plan'}}
        # The dashboard reads the absence from the account's last good reading, as it is stored.
        $status=Clone @{generatedAt=$now.ToString('o');slots=@(@{slot=1;status='ok';fresh=$true;observedAt=$now.ToString('o');used5h=1;used7d=1},@{slot=2;status='relogin_required';lastGoodAt=$now.AddDays(-36.5).ToString('o')});parkedReadable=@(@{slot='4';label='Parked one'})}
        $text=@(Get-Hotpl8TestFrame $status $policy $now) -join "`n"
        Assert ($text.Contains('Old plan: no reading for 36 days  ·  sign in, or hotpl8 park') -and -not $text.Contains('hotpl8 doctor')) $text
        Assert ($text.Contains('Parked one is readable again  ·  hotpl8 unpark'))
        $status.slots[1].lastGoodAt=$now.AddHours(-1).ToString('o')
        $text=@(Get-Hotpl8TestFrame $status $policy $now) -join "`n"
        Assert (-not $text.Contains('no reading for')) $text
        Assert (-not $text.Contains('account unavailable') -and $text.Contains('SIGN-IN NEEDED')) 'a recent failure stays on its account row'
    }
    Check 'doctor names candidates for people and only counts them in the redacted report' {
        $report=[pscustomobject]@{version='0';runtime='7';policyPresent=$true;policyValid=$true;mode='monitor';claudeConfigured=$true;codexConfigured=$false;cswapFound=$true;codexFound=$false;snapshotAgeSeconds=10;snapshotFresh=$true;collectorBusy=$false;providers=[pscustomobject]@{};parkCandidates=1}
        $text=(Format-Hotpl8Doctor $report @([pscustomobject]@{label='Old plan';providerName='Claude';reason='dormant';days=36})) -join "`n"
        Assert ($text.Contains('PARK CANDIDATE: Old plan (Claude), no reading for 36 days.') -and $text.Contains('hotpl8 park'))
        $d=New-StateDirectory;Write-Policy $d (Clone @{schemaVersion=2;mode='monitor';prefer=@(1,2);labels=@{'2'='Private label'}})
        Write-Hotpl8Text (Join-Path $d 'status.json') (@{generatedAt=$now.ToString('o');slots=@(@{slot=2;status='relogin_required';lastGoodAt=$now.AddDays(-30).ToString('o')})}|ConvertTo-Json -Depth 6)
        $json=Get-Hotpl8Doctor $d|ConvertTo-Json -Depth 6
        Assert ((ConvertFrom-Json $json).parkCandidates -eq 1 -and -not $json.Contains('Private label'))
    }
    Check 'CLI asks before parking, changes nothing without an answer, and lists parked accounts' {
        $d=New-StateDirectory
        $homes=@{gone=(Join-Path $d 'gone');paid=(Join-Path $d 'paid')};foreach($h in $homes.Values){[void][IO.Directory]::CreateDirectory($h)}
        Write-Policy $d (Clone @{schemaVersion=2;mode='monitor';codex=@{slots=@(@{id='gone';home=$homes.gone;label='Ended plan'},@{id='paid';home=$homes.paid;label='Paid'});prefer=@('gone','paid')}})
        Write-Hotpl8Text (Join-Path $d 'status.json') (@{schemaVersion=2;generatedAt=[datetimeoffset]::UtcNow.ToString('o');slots=@();providers=@{codex=@{slots=@(@{id='gone';status='ok';planType='free';observedAt=[datetimeoffset]::UtcNow.ToString('o')},@{id='paid';status='ok';planType='plus';observedAt=[datetimeoffset]::UtcNow.ToString('o')})}}}|ConvertTo-Json -Depth 8)
        $shell=(Get-Process -Id $PID).Path;$launcher=Join-Path $root 'hotpl8.ps1'
        $listed=@(''|& $shell -NoProfile -ExecutionPolicy Bypass -File $launcher park -StateDirectory $d 2>&1)
        $text=$listed -join "`n"
        Assert ($text.Contains('Ended plan') -and $text.Contains('plan ended (now free)') -and $text.Contains('No changes made') -and -not $text.Contains('Paid')) $text
        Assert ((@((Read-Policy $d).codex.slots)).Count -eq 2) 'redirected input never parks'
        $json=(& $shell -NoProfile -ExecutionPolicy Bypass -File $launcher park -AsJson -StateDirectory $d 2>&1) -join "`n"
        Assert (@((ConvertFrom-Json $json).candidates).Count -eq 1)
        $done=(''|& $shell -NoProfile -ExecutionPolicy Bypass -File $launcher park -Yes -StateDirectory $d 2>&1) -join "`n"
        Assert ($done.Contains('Parked Ended plan.') -and $done.Contains('Still enrolled: Paid.') -and $done.Contains('Undo: hotpl8 unpark -Provider codex -Slot gone')) $done
        $accounts=(& $shell -NoProfile -ExecutionPolicy Bypass -File $launcher accounts -AsJson -StateDirectory $d 2>&1) -join "`n"
        Assert (@((ConvertFrom-Json $accounts)|Where-Object parked).slot -ceq 'gone') $accounts
        $unpark=(''|& $shell -NoProfile -ExecutionPolicy Bypass -File $launcher unpark -StateDirectory $d 2>&1) -join "`n"
        Assert ($unpark.Contains('1. Ended plan') -and $unpark.Contains('its plan ended') -and $unpark.Contains('No changes made')) $unpark
        $nothing=(''|& $shell -NoProfile -ExecutionPolicy Bypass -File $launcher park -StateDirectory $d 2>&1) -join "`n"
        Assert ($nothing.Contains('Nothing to park')) $nothing
    }
}finally{
    $full=[IO.Path]::GetFullPath($script:dir);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if((Split-Path $full -Parent) -eq $temp -and (Split-Path $full -Leaf) -match '^hotpl8-parking-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
'passed='+$script:passed+' failed='+$script:failed
if($script:failed){exit 1}
