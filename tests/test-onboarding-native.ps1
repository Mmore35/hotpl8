# Real child processes with synthetic native auth; no browser, network, or production state.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($module in @('common','config','diagnostics','management','onboarding','onboarding-native')){. (Join-Path $root ('src/'+$module+'.ps1'))}
. (Join-Path $root 'src/providers/codex.ps1')
$lab=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-native-fixture-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($lab)
$script:node=(Get-Command node -ErrorAction Stop).Source
$script:nativeFactory=${function:New-Hotpl8OnboardingProcess}
function Resolve-CodexExecutable {return $script:node}
function New-Hotpl8OnboardingProcess($Executable,$Arguments,$AccountHome,$Provider){
    $fixture=if($Provider -eq 'claude'){'onboarding-claude-fixture.mjs'}else{'onboarding-native-fixture.mjs'}
    & $script:nativeFactory $script:node @((Join-Path $PSScriptRoot $fixture)) $AccountHome $Provider
}
function New-CodexProcessInfo($Executable,$AccountHome,$Arguments,$WorkingDirectory){New-Hotpl8OnboardingProcess $Executable $Arguments $AccountHome codex}
function Assert($Value,$Message='assertion failed'){if(-not $Value){throw $Message}}
$script:passed=0;$script:failed=0
function Check($Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message+' at '+$_.ScriptStackTrace}}
function Fixture($Name,$Options=@{},[switch]$Authenticated){
    $h=Join-Path $lab $Name;[void][IO.Directory]::CreateDirectory($h)
    Write-Hotpl8Text (Join-Path $h 'fixture.json') ($Options|ConvertTo-Json) -NoBom
    if($Authenticated){Write-Hotpl8Text (Join-Path $h 'auth.json') '{"tokens":{"account_id":"workspace-fixture"}}' -NoBom}
    return $h
}
function Operation($Directory,$NativeHome){
    Initialize-Hotpl8Onboarding $Directory
    $op=[pscustomobject]@{schemaVersion=1;id=[guid]::NewGuid().ToString('N');provider='codex';selected=[pscustomobject]@{id='fixture';provider='codex';home=$NativeHome;slot='';label='';enrolled=$false};deviceCode=$false;newAccount=$false;phase='preparing';message='';updatedAt='';handoff=$null;result=$null}
    Save-Hotpl8Onboarding $Directory $op;return $op
}
try{
    Check 'private state directory can be secured again by every later request' {
        # Each onboarding request re-secures its state folder. Windows PowerShell's
        # Set-Acl failed that second pass without SeSecurityPrivilege (non-elevated users).
        $p=Join-Path $lab 'private'
        foreach($pass in 1..2){$null=New-Hotpl8PrivateDirectory $p}
        if($env:OS -eq 'Windows_NT'){
            $acl=Get-Acl -LiteralPath $p
            $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
            $expected=@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')|Sort-Object
            Assert ($acl.AreAccessRulesProtected -and $rules.Count -eq 3) 'inherited or extra access remains'
            Assert ((@($rules|ForEach-Object {$_.IdentityReference.Value})|Sort-Object) -join ',' -eq ($expected -join ',')) 'unexpected principal'
            Assert (-not @($rules|Where-Object {$_.AccessControlType -ne 'Allow' -or $_.FileSystemRights -ne 'FullControl'}).Count)
        }else{
            Assert ((Get-Item -LiteralPath $p).UnixFileMode -eq [IO.UnixFileMode]'UserRead,UserWrite,UserExecute')
        }
    }
    Check 'identity verification succeeds while quota is unavailable and never requests quota' {
        $h=Fixture identity @{quotaFailure=$true} -Authenticated
        $r=Read-CodexQuota $h '' 5000 -IdentityOnly
        Assert ($r.status -eq 'ok' -and $r.identityVerified)
        Assert (-not ((Get-Content (Join-Path $h 'calls.jsonl') -Raw) -match 'rateLimits'))
        $r=Read-CodexQuota $h '' 5000
        Assert ($r.status -eq 'rate_limited')
    }
    Check 'API keys and incomplete identities cannot create subscription capacity' {
        $h=Fixture apikey @{apiKey=$true} -Authenticated
        Assert ((Read-CodexQuota $h '' 5000 -IdentityOnly).status -eq 'subscription_login_required')
        $h=Fixture incomplete @{nullEmail=$true} -Authenticated
        Assert (-not (Read-CodexQuota $h '' 5000 -IdentityOnly).identityVerified)
    }
    Check 'native browser login completion persists in its dedicated home and re-entry skips login' {
        $h=Fixture browser;$d=Join-Path $lab browser-state;$op=Operation $d $h
        $selected=Connect-Hotpl8NativeAccount $d $op
        Assert ($selected.home -eq $h -and (Test-Path (Join-Path $h 'auth.json')))
        $null=Connect-Hotpl8NativeAccount $d $op
        $calls=@(Get-Content (Join-Path $h 'calls.jsonl')|Where-Object {$_ -eq '"account/login/start"'})
        Assert ($calls.Count -eq 1) 're-entry repeated native sign-in'
    }
    Check 'device-code login exposes the native handoff and completion' {
        $h=Fixture device;$d=Join-Path $lab device-state;$op=Operation $d $h;$op.deviceCode=$true
        $null=Connect-Hotpl8NativeAccount $d $op
        Assert ($op.handoff.code -eq 'TEST-ONLY' -and (Test-Path (Join-Path $h 'auth.json')))
    }
    Check 'cancel stops native login without persisting credentials' {
        $h=Fixture cancel;$d=Join-Path $lab cancel-state;$op=Operation $d $h
        Write-Hotpl8Text (Join-Path $h 'fixture.json') (@{cancelPath=((Get-Hotpl8OnboardingPath $d $op.id)+'.cancel')}|ConvertTo-Json) -NoBom
        $null=Connect-Hotpl8NativeAccount $d $op
        Assert (-not (Test-Path (Join-Path $h 'auth.json')))
        Assert ((Get-Content (Join-Path $h 'calls.jsonl') -Raw) -match 'account/login/cancel')
    }
    Check 'duplicate subscription in another home is enrolled once and without quota' {
        $h=Fixture first @{} -Authenticated;$d=Join-Path $lab duplicate-state;$op=Operation $d $h
        Register-Hotpl8OnboardingCodex $d $op
        $h2=Fixture second @{} -Authenticated;$second=Operation $d $h2
        Register-Hotpl8OnboardingCodex $d $second
        $p=Read-Hotpl8Json (Join-Path $d 'policy.json')
        Assert (@($p.codex.slots).Count -eq 1 -and $second.selected.enrolled -and $op.selected.slot -eq $second.selected.slot)
        $second.newAccount=$true
        Complete-Hotpl8OnboardingAccount $d $second
        Assert ($second.phase -eq 'already_connected' -and $second.result.alreadyPresent) 'duplicate must not be announced as a new account'
    }
    Check 'signing in again to an enrolled Claude account that needed sign-in reconnects it' {
        # The observe-only refresh is a separate process; supply its fresh snapshot instead.
        function Invoke-Hotpl8Process {[pscustomobject]@{exitCode=0;output=''}}
        foreach($case in @(@{status='relogin_required';phase='ready';reconnected=$true},@{status='ok';phase='already_connected';reconnected=$false})){
            $d=Join-Path $lab ('reconnect-'+$case.status);$op=Operation $d (Join-Path $lab 'unused')
            $policy=Read-Hotpl8Json (Join-Path $d 'policy.json');$policy.prefer=@('1')
            Write-Hotpl8Text (Join-Path $d 'policy.json') ($policy|ConvertTo-Json -Depth 20)
            Write-Hotpl8Text (Join-Path $d 'status.json') (@{slots=@(@{slot='1';status='ok';observedAt=[datetimeoffset]::UtcNow.ToString('o')})}|ConvertTo-Json -Depth 8)
            $op.provider='claude';$op.newAccount=$true
            $op|Add-Member NoteProperty candidates @([pscustomobject]@{id='claude-1';provider='claude';label='Claude account 1';home='';slot='1';enrolled=$true;status=$case.status}) -Force
            $op.selected=[pscustomobject]@{id='claude-1';provider='claude';label='Claude account 1';home='';slot='1';enrolled=$false;status='ok'}
            Complete-Hotpl8OnboardingAccount $d $op
            Assert ($op.phase -eq $case.phase -and $op.result.reconnected -eq $case.reconnected -and $op.result.alreadyPresent -ne $case.reconnected) ($case.status+' finished as '+$op.phase)
        }
    }
    Check 'uncertain peer identity preserves candidate without adding capacity' {
        $h=Fixture peer @{} -Authenticated;$d=Join-Path $lab pending-state;$op=Operation $d $h
        Register-Hotpl8OnboardingCodex $d $op
        Remove-Item (Join-Path $h 'auth.json')
        $h2=Fixture pending @{} -Authenticated;$candidate=Operation $d $h2
        $rejected=$false;try{Register-Hotpl8OnboardingCodex $d $candidate}catch{$rejected=$true}
        Assert $rejected
        Assert ((Test-Path (Join-Path $h2 'auth.json')) -and @( (Read-Hotpl8Json (Join-Path $d 'policy.json')).codex.slots).Count -eq 1)
    }
    function ClaudeLogin([string]$Name,$Options=@{}){
        function Get-Hotpl8ClaudeExecutable {return $script:node}
        function Add-Hotpl8NativeClaudeAccount($Directory,$Operation){
            if(Test-Path (Join-Path $Operation.selected.home 'fixture-auth-completed')){return $Operation.selected}
            return $null
        }
        $h=Fixture $Name;$d=Join-Path $lab ($Name+'-state');$op=Operation $d $h;$op.provider='claude';$op.selected.provider='claude'
        Write-Hotpl8Text (Join-Path $h 'fixture.json') ((@{operationPath=(Get-Hotpl8OnboardingPath $d $op.id)}+$Options)|ConvertTo-Json) -NoBom
        try{$selected=Connect-Hotpl8NativeAccount $d $op}catch{
            $detail=Read-Hotpl8Json (Join-Path $h 'fixture-failure.json')
            if($detail){Write-Host ('Synthetic Claude fixture: '+($detail|ConvertTo-Json -Compress -Depth 5))}
            throw
        }
        return [pscustomobject]@{selected=$selected;operation=$op;home=$h;codePath=((Get-Hotpl8OnboardingPath $d $op.id)+'.code')}
    }
    Check 'complete Claude fallback URL is available across pipe chunks before native login exits' {
        $r=ClaudeLogin claude
        Assert ($r.selected -and $r.operation.handoff.url -eq 'https://claude.com/cai/oauth/authorize?fixture=1' -and $r.operation.handoff.kind -eq 'paste_code')
    }
    Check 'a pasted Claude code reaches the waiting native login through its open input once' {
        $r=ClaudeLogin claude-paste @{paste='accept'}
        Assert ($r.selected -and $r.operation.handoff.codeReceived) 'code was not relayed'
        Assert ((Get-Content (Join-Path $r.home 'fixture-code-1') -Raw) -ceq 'fixture-code-1#state')
        Assert (-not (Test-Path $r.codePath)) 'relayed code was left on disk'
        Assert (-not ((Get-Content ($r.codePath -replace '\.code$','') -Raw) -match 'fixture-code')) 'code persisted in operation state'
    }
    Check 'a rejected Claude code starts a fresh native login with a new link and says why' {
        $r=ClaudeLogin claude-reject @{paste='reject-once'}
        Assert ($r.selected -and (Get-Content (Join-Path $r.home 'fixture-starts') -Raw).Trim() -eq '2') 'login was not restarted'
        Assert ($r.operation.handoff.url -eq 'https://claude.com/cai/oauth/authorize?fixture=2')
        Assert ((Get-Content (Join-Path $r.home 'fixture-message-2') -Raw) -like 'Claude did not accept that code.*earlier sign-in page*') 'restart reason not shown'
    }
    Check 'an incomplete Claude code reopens the same login for another paste' {
        $r=ClaudeLogin claude-incomplete @{paste='incomplete-once'}
        Assert ($r.selected -and (Get-Content (Join-Path $r.home 'fixture-starts') -Raw).Trim() -eq '1') 'login was restarted'
        Assert ((Get-Content (Join-Path $r.home 'fixture-code-1') -Raw) -ceq "fixture-code-1`nfixture-code-1#state") 'second code was not relayed'
        Assert ((Get-Content (Join-Path $r.home 'fixture-reopened-message') -Raw) -like 'That code was incomplete.*') 'incomplete code not reported'
    }
    Check 'detached worker survives the short-lived JSON caller' {
        $d=Join-Path $lab detached
        $shell=(Get-Process -Id $PID).Path
        $psi=New-Object Diagnostics.ProcessStartInfo
        $psi.FileName=$shell;$psi.UseShellExecute=$false
        $argv=@('-NoProfile','-File',(Join-Path $root 'hotpl8.ps1'),'setup','-Provider','claude','-AsJson','-StateDirectory',$d)
        $psi.Arguments=(@($argv|ForEach-Object{ConvertTo-NativeArgument $_}) -join ' ')
        $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
        # Dependency discovery stops before any native account access or installation.
        $psi.EnvironmentVariables['PATH']=''
        foreach($key in @('HOME','USERPROFILE')){$psi.EnvironmentVariables[$key]=$lab}
        $psi.EnvironmentVariables.Remove('HOTPL8_NATIVE_BIN')
        # Cold Windows PowerShell/compiler startup can exceed 15 seconds on CI.
        # The separate held-worker check below proves response-pipe independence.
        $elapsed=[Diagnostics.Stopwatch]::StartNew()
        $r=Invoke-Hotpl8ProcessInfo $psi 90000
        Write-Host ('JSON onboarding caller elapsed: '+[math]::Round($elapsed.Elapsed.TotalSeconds,1)+'s')
        Assert ($r.exitCode -eq 0) 'JSON caller did not exit promptly'
        $response=$r.output|ConvertFrom-Json
        $path=Get-Hotpl8OnboardingPath $d $response.operationId
        $clock=[Diagnostics.Stopwatch]::StartNew();$released=$false
        do{
            Start-Sleep -Milliseconds 200
            $saved=Read-Hotpl8Json $path
            if($saved.phase -eq 'needs_install_authorization'){
                $probe=$null
                try{$probe=[IO.File]::Open(($path+'.worker'),'Open','ReadWrite','None');$released=$true}catch{}finally{if($probe){$probe.Dispose()}}
            }
        }while(-not $released -and $clock.Elapsed.TotalSeconds -lt 30)
        Assert ($released -and $saved.phase -eq 'needs_install_authorization') 'worker did not finish after its parent exited'
    }
    if($env:OS -eq 'Windows_NT'){
        Check 'detached Windows worker releases caller pipes and supports native UTF-8 JSON transport' {
            $h=Fixture detached-native @{} -Authenticated
            $child=Join-Path $lab 'detached-native.ps1';$result=Join-Path $lab 'detached-native.json'
            $release=Join-Path $lab 'release-worker';$ended=Join-Path $lab 'worker-ended'
            Write-Hotpl8Text $child @'
param($Root,$Node,$Fixture,$AccountHome,$Result,$Release,$Ended)
$ErrorActionPreference='Stop'
. (Join-Path $Root 'src/common.ps1')
. (Join-Path $Root 'src/providers/codex.ps1')
function Resolve-CodexExecutable {return $Node}
function New-CodexProcessInfo($Executable,$AccountHome,$Arguments,$WorkingDirectory){
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$Node;$psi.Arguments=ConvertTo-NativeArgument $Fixture
    $psi.UseShellExecute=$false;$psi.WorkingDirectory=$AccountHome
    $psi.EnvironmentVariables['CODEX_HOME']=$AccountHome
    return $psi
}
$read=Read-CodexQuota $AccountHome '' 12000 -IdentityOnly
Write-Hotpl8Text $Result (@{status=$read.status;verified=[bool]$read.identityVerified}|ConvertTo-Json) -NoBom
# Stay alive until the test has consumed the caller's response and releases us.
$clock=[Diagnostics.Stopwatch]::StartNew()
while(-not (Test-Path $Release) -and $clock.Elapsed.TotalSeconds -lt 150){Start-Sleep -Milliseconds 100}
Write-Hotpl8Text $Ended 'done' -NoBom
'@ -NoBom
            $argv=@('-NoProfile','-File',$child,'-Root',$root,'-Node',$script:node,'-Fixture',(Join-Path $PSScriptRoot 'onboarding-native-fixture.mjs'),'-AccountHome',$h,'-Result',$result,'-Release',$release,'-Ended',$ended)
            $workerArguments=(@($argv|ForEach-Object{ConvertTo-NativeArgument $_})) -join ' '
            $parent=Join-Path $lab 'worker-caller.ps1'
            $argumentsPath=Join-Path $lab 'worker-arguments.json'
            Write-Hotpl8Text $argumentsPath (@{arguments=$workerArguments}|ConvertTo-Json) -NoBom
            Write-Hotpl8Text $parent @'
param($Root,$ArgumentsPath)
$ErrorActionPreference='Stop'
. (Join-Path $Root 'src/common.ps1')
. (Join-Path $Root 'src/onboarding-process.ps1')
Start-Hotpl8WindowsWorker (Get-Process -Id $PID).Path (Read-Hotpl8Json $ArgumentsPath).arguments
[Console]::Write('{"started":true}')
'@ -NoBom
            $psi=New-Object Diagnostics.ProcessStartInfo
            $psi.FileName=(Get-Process -Id $PID).Path;$psi.UseShellExecute=$false
            $psi.Arguments=(@(@('-NoProfile','-File',$parent,'-Root',$root,'-ArgumentsPath',$argumentsPath)|ForEach-Object{ConvertTo-NativeArgument $_})) -join ' '
            $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
            try{
                $response=Invoke-Hotpl8ProcessInfo $psi 90000
                Assert ($response.exitCode -eq 0 -and ($response.output|ConvertFrom-Json).started) 'caller response unavailable while worker lives'
                $clock=[Diagnostics.Stopwatch]::StartNew()
                while(-not (Test-Path $result) -and $clock.Elapsed.TotalSeconds -lt 30){Start-Sleep -Milliseconds 200}
                Assert (Test-Path $result) 'detached native worker did not return a result'
                Assert (-not (Test-Path $ended)) 'worker ended before caller independence was established'
                $read=Read-Hotpl8Json $result
                Assert ($read.status -eq 'ok' -and $read.verified) ('detached native transport: '+$read.status)
            }finally{
                Write-Hotpl8Text $release 'release' -NoBom
                $clock=[Diagnostics.Stopwatch]::StartNew()
                while(-not (Test-Path $ended) -and $clock.Elapsed.TotalSeconds -lt 10){Start-Sleep -Milliseconds 100}
            }
        }
    }
    Check 'bounded process capture rejects excessive output and timeout' {
        $shell=(Get-Process -Id $PID).Path
        foreach($case in @(@{command="[Console]::Write(('x'*1100000))";budget=10000},@{command='Start-Sleep -Seconds 30';budget=500})){
            $psi=& $script:nativeFactory $shell @('-NoProfile','-Command',$case.command) '' claude
            $rejected=$false;try{$null=Invoke-Hotpl8ProcessInfo $psi $case.budget}catch{$rejected=$true}
            Assert $rejected
        }
    }
}finally{Remove-Item -LiteralPath $lab -Recurse -Force}
'Native onboarding: '+$script:passed+' passed, '+$script:failed+' failed.'
if($script:failed){exit 1}
