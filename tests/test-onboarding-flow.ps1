# Offline first-account and recovery contracts; every native operation is replaced by a fixture.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($module in @('common','config','diagnostics','management','onboarding','onboarding-native','onboarding-install','agent-api','mcp')){. (Join-Path $root ('src/'+$module+'.ps1'))}
. (Join-Path $root 'src/providers/claude.ps1')
. (Join-Path $root 'src/providers/codex.ps1')
$lab=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-onboarding-flow-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($lab)
$script:passed=0;$script:failed=0;$script:workers=0;$script:installs=0;$script:logins=0;$script:completed=0
function Assert($Value,$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check($Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message+' at '+$_.ScriptStackTrace}}
function Reject([scriptblock]$Body){$rejected=$false;try{& $Body|Out-Null}catch{$rejected=$true};Assert $rejected 'expected rejection'}
function Start-Hotpl8OnboardingWorker {$script:workers++}
function Get-Hotpl8OnboardingDependencies($Provider){if($script:missing){'fixture-tool'}}
function Get-Hotpl8OnboardingCandidates($Directory,$Provider){@($script:candidates|Where-Object provider -EQ $Provider)}
function Install-Hotpl8OnboardingDependencies {$script:installs++;$script:missing=$false}
function Add-Hotpl8NativeClaudeAccount {return $null}
function Connect-Hotpl8NativeAccount($Directory,$Operation){$script:logins++;return [pscustomobject]@{id='signed-in';provider=$Operation.provider;home=(Join-Path $Directory 'native');slot='new';label='Fixture';status='ok';enrolled=$false}}
function Complete-Hotpl8OnboardingAccount($Directory,$Operation){
    $script:completed++
    if($script:transient){throw 'synthetic temporary failure'}
    $Operation.result=[pscustomobject]@{enrolled=$true;slot='new';observed=$true;status='observed'}
    Set-Hotpl8OnboardingPhase $Directory $Operation ready 'Account connected.'
}
function BeginFixture([string]$Name,[string]$Provider='codex',[switch]$NewAccount){
    $script:directory=Join-Path $lab $Name
    $script:candidates=@();$script:missing=$false;$script:transient=$false
    return Invoke-Hotpl8Onboarding $script:directory begin '' $Provider -NewAccount:$NewAccount
}
function RunFixture($Result){Invoke-Hotpl8OnboardingWorker $script:directory $Result.operationId;Invoke-Hotpl8Onboarding $script:directory status $Result.operationId}
function Candidate([string]$Id,[bool]$Enrolled=$false,[string]$Provider='codex'){
    [pscustomobject]@{id=$Id;provider=$Provider;home=(Join-Path $lab $Id);slot=$Id;label=('Fixture '+$Id);enrolled=$Enrolled;status='ok'}
}
try{
    Check 'zero-state creates monitor policy and asks only for provider' {
        $r=BeginFixture empty ''; $r=RunFixture $r
        Assert ($r.phase -eq 'needs_provider' -and $r.humanRequired)
        $p=Read-Hotpl8Json (Join-Path $script:directory 'policy.json')
        Assert ($p.mode -eq 'monitor' -and -not $p.warm -and -not $p.switchEnabled)
    }
    Check 'one existing account completes without any provider login' {
        $r=BeginFixture existing;$script:candidates=@(Candidate only)
        $before=$script:logins;$r=RunFixture $r
        Assert ($r.phase -eq 'ready' -and $r.account.observed -and $script:logins -eq $before)
    }
    Check 'usable single native account resolves unspecified provider' {
        $r=BeginFixture infer '';$script:candidates=@(Candidate only $false claude);$r=RunFixture $r
        Assert ($r.phase -eq 'ready' -and $r.provider -eq 'claude')
    }
    Check 'multiple native accounts require an account choice, never all-account import' {
        $r=BeginFixture multiple;$script:candidates=@((Candidate first),(Candidate second));$before=$script:completed;$r=RunFixture $r
        Assert ($r.phase -eq 'needs_account_choice' -and $r.candidates.Count -eq 2 -and $script:completed -eq $before)
        Assert (-not $r.candidates[0].PSObject.Properties['home']) 'agent result leaked native path'
        Reject {Invoke-Hotpl8Onboarding $script:directory choose_account $r.operationId '' unknown}
        $r=Invoke-Hotpl8Onboarding $script:directory choose_account $r.operationId '' second;$r=RunFixture $r
        Assert ($r.phase -eq 'ready')
    }
    Check 'missing dependencies require a single explicit install authorization' {
        $r=BeginFixture dependency;$script:missing=$true;$before=$script:installs;$r=RunFixture $r
        Assert ($r.phase -eq 'needs_install_authorization' -and $script:installs -eq $before)
        Reject {Invoke-Hotpl8Onboarding $script:directory install $r.operationId}
        $r=Invoke-Hotpl8Onboarding $script:directory install $r.operationId -AllowInstall;$r=RunFixture $r
        Assert ($script:installs -eq ($before+1) -and $r.phase -eq 'needs_sign_in')
    }
    Check 'no local login asks for native sign-in then completes automatically' {
        $r=BeginFixture login;$r=RunFixture $r;Assert ($r.phase -eq 'needs_sign_in')
        $before=$script:logins;$r=Invoke-Hotpl8Onboarding $script:directory sign_in $r.operationId;$r=RunFixture $r
        Assert ($r.phase -eq 'ready' -and $script:logins -eq ($before+1))
    }
    Check 'temporary failure after login retries verification without another login' {
        $r=BeginFixture retry;$r=RunFixture $r
        $r=Invoke-Hotpl8Onboarding $script:directory sign_in $r.operationId;$script:transient=$true;$r=RunFixture $r
        Assert ($r.phase -eq 'pending')
        $script:transient=$false;$before=$script:logins
        $r=Invoke-Hotpl8Onboarding $script:directory retry $r.operationId;$r=RunFixture $r
        Assert ($r.phase -eq 'ready' -and $script:logins -eq $before)
    }
    Check 'begin with the same operation ID is idempotent' {
        $r=BeginFixture repeat;$before=$script:workers
        $again=Invoke-Hotpl8Onboarding $script:directory begin $r.operationId codex
        Assert ($again.operationId -eq $r.operationId -and $script:workers -eq $before)
        Reject {Invoke-Hotpl8Onboarding $script:directory begin $r.operationId claude}
    }
    Check 'returning human resumes unfinished setup without operation bookkeeping' {
        $r=BeginFixture resume;$r=RunFixture $r
        $again=Invoke-Hotpl8Onboarding $script:directory begin '' codex
        Assert ($again.operationId -eq $r.operationId)
    }
    Check 'first setup resumes the same operation after native sign-in starts' {
        $r=BeginFixture resumelogin;$r=RunFixture $r
        $r=Invoke-Hotpl8Onboarding $script:directory sign_in $r.operationId
        $saved=Read-Hotpl8Onboarding $script:directory $r.operationId
        Assert (-not $saved.newAccount) 'sign-in must preserve first-setup intent'
        $again=Invoke-Hotpl8Onboarding $script:directory begin '' codex
        Assert ($again.operationId -eq $r.operationId) 'setup lost its native login operation'
        $saved.phase='pending';Save-Hotpl8Onboarding $script:directory $saved
        $again=Invoke-Hotpl8Onboarding $script:directory begin '' codex
        Assert ($again.operationId -eq $r.operationId) 'setup lost interrupted sign-in progress'
    }
    Check 'canceled operation cannot restart or become ready from a late worker result' {
        $r=BeginFixture cancel;$saved=Read-Hotpl8Onboarding $script:directory $r.operationId
        $r=Invoke-Hotpl8Onboarding $script:directory cancel $r.operationId
        Assert ($r.phase -eq 'canceled')
        Set-Hotpl8OnboardingPhase $script:directory $saved ready 'late result'
        $r=Invoke-Hotpl8Onboarding $script:directory retry $r.operationId
        Assert ($r.phase -eq 'canceled' -and -not $r.handoff)
    }
    Check 'new-account intent reuses an unenrolled account and skips an already enrolled one' {
        $r=BeginFixture add codex -NewAccount;$script:candidates=@((Candidate old $true),(Candidate fresh));$r=RunFixture $r
        Assert ($r.phase -eq 'ready')
        $r=BeginFixture addlogin codex -NewAccount;$script:candidates=@(Candidate old $true);$r=RunFixture $r
        Assert ($r.phase -eq 'needs_sign_in')
    }
    Check 'a duplicate account offers another login in a new native profile' {
        $r=BeginFixture duplicateflow
        $op=Read-Hotpl8Onboarding $script:directory $r.operationId
        $op.phase='already_connected';$op.selected=Candidate old $true;$op.action='enroll'
        Save-Hotpl8Onboarding $script:directory $op
        $r=Invoke-Hotpl8Onboarding $script:directory sign_in $r.operationId
        $saved=Read-Hotpl8Onboarding $script:directory $r.operationId
        Assert ($saved.action -eq 'login' -and -not $saved.selected -and $saved.attempt -eq 1)
    }
    Check 'an interrupted login retries its native sign-in before enrollment' {
        $r=BeginFixture interrupted
        $op=Read-Hotpl8Onboarding $script:directory $r.operationId
        $op.phase='pending';$op.selected=Candidate interrupted;$op.action='login'
        Save-Hotpl8Onboarding $script:directory $op
        $r=Invoke-Hotpl8Onboarding $script:directory retry $r.operationId
        Assert ((Read-Hotpl8Onboarding $script:directory $r.operationId).action -eq 'login')
    }
    Check 'invalid requests create no installation state' {
        $absent=Join-Path $lab invalid
        Reject {Invoke-Hotpl8Onboarding $absent begin '../outside' codex}
        Reject {Invoke-Hotpl8Onboarding $absent boom '' codex}
        Assert (-not (Test-Path $absent))
    }
    Check 'read-only onboarding status creates no missing operation' {
        $absent=Join-Path $lab absent
        Reject {Invoke-Hotpl8Onboarding $absent status ('a'*32)}
        Assert (-not (Test-Path $absent))
    }
    Check 'MCP onboarding is opt-in and keeps existing read-only clients unchanged' {
        Assert (@(Get-Hotpl8McpTools $false).Count -eq 2)
        Assert (@(Get-Hotpl8McpTools $false $true|Where-Object name -EQ hotpl8_onboard).Count -eq 1)
        $request=[pscustomobject]@{apiVersion=1;operation='onboarding';arguments=[pscustomobject]@{action='begin'}}
        $response=Invoke-Hotpl8AgentRequest $request $lab $false $false
        Assert (-not $response.ok -and $response.error.code -eq 'permission_denied')
    }
    Check 'agent rejects arbitrary paths commands and mistyped write authorization' {
        foreach($argsValue in @(@{action='begin';path='/arbitrary'},@{action='begin';allowInstall='true'},@{action='sign_in'},@{action='begin';provider='shell'})){
            $request=[pscustomobject]@{apiVersion=1;operation='onboarding';arguments=([pscustomobject]$argsValue)}
            $response=Invoke-Hotpl8AgentRequest $request $lab
            Assert (-not $response.ok -and $response.error.code -eq 'invalid_arguments')
        }
    }
    Check 'agent capabilities work before installation and advertise allowed onboarding' {
        $request=[pscustomobject]@{apiVersion=1;operation='capabilities';arguments=[pscustomobject]@{}}
        $response=Invoke-Hotpl8AgentRequest $request (Join-Path $lab neverinstalled)
        Assert ($response.ok -and 'onboarding' -in $response.data.operations -and -not $response.data.policyPresent)
        $response=Invoke-Hotpl8AgentRequest $request (Join-Path $lab neverinstalled) $false $false
        Assert ('onboarding' -notin $response.data.operations)
    }
}finally{Remove-Item -LiteralPath $lab -Recurse -Force}
'Onboarding flow: '+$script:passed+' passed, '+$script:failed+' failed.'
if($script:failed){exit 1}
