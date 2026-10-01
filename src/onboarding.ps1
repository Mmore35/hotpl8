# Durable public onboarding. Native tools own credentials; the operation stores only references.
. (Join-Path $PSScriptRoot 'lifecycle.ps1')
. (Join-Path $PSScriptRoot 'onboarding-process.ps1')
function New-Hotpl8PrivateDirectory([string]$Path) {
    $full=Assert-Hotpl8Path $Path
    [void][IO.Directory]::CreateDirectory($full)
    if($env:OS -ne 'Windows_NT'){[IO.File]::SetUnixFileMode($full,[IO.UnixFileMode]'UserRead,UserWrite,UserExecute')}
    else{
        $acl=New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true,$false)
        $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.SetOwner($owner)
        foreach($sid in @($owner,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),(New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))){
            $rule=New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $full -AclObject $acl
    }
    return $full
}
function Get-Hotpl8OnboardingPath([string]$Directory,[string]$Id) {
    if($Id -cnotmatch '^[0-9a-f]{32}$'){throw 'Invalid onboarding operation ID.'}
    return Join-Path (Join-Path $Directory 'onboarding') ($Id+'.json')
}
function Read-Hotpl8Onboarding([string]$Directory,[string]$Id) {
    $op=Read-Hotpl8Json (Get-Hotpl8OnboardingPath $Directory $Id)
    if(-not $op -or $op.schemaVersion -ne 1 -or $op.id -cne $Id){throw 'Onboarding operation missing or unsupported.'}
    return $op
}
function Get-Hotpl8OnboardingProgress([string]$Directory,[string]$Id) {
    $op=Read-Hotpl8Onboarding $Directory $Id
    if($op.phase -in @('preparing','verifying','awaiting_sign_in') -and ([datetimeoffset]::UtcNow-[datetimeoffset]::Parse($op.updatedAt)).TotalSeconds -ge 15){
        $probe=$null
        try{
            $workerPath=(Get-Hotpl8OnboardingPath $Directory $Id)+'.worker'
            if(Test-Path -LiteralPath $workerPath){$probe=[IO.File]::Open($workerPath,'Open','ReadWrite','None')}
            $op.phase='pending';$op.handoff=$null;$op.message='Setup was interrupted. Resume to continue from saved progress.'
        }catch{}finally{if($probe){$probe.Dispose()}}
    }
    if($op.phase -eq 'pending' -and $op.result.enrolled){
        $snapshot=Read-Hotpl8Json (Join-Path $Directory 'status.json')
        $view=Get-Hotpl8ProviderView $snapshot (Read-Hotpl8Json (Join-Path $Directory 'policy.json')) $op.selected.provider
        $rows=if($op.provider -eq 'codex'){@($view.snapshot.providers.codex.slots|Where-Object id -EQ $op.selected.slot)}else{@($view.snapshot.slots|Where-Object slot -EQ $op.selected.slot)}
        if($rows.Count -eq 1 -and $rows[0].status -eq 'ok' -and (Test-Hotpl8FreshTimestamp $rows[0].observedAt)){
            $op.phase=$(if($op.result.alreadyPresent){'already_connected'}else{'ready'});$op.message='Account connected. Usage is available in HotPl8.';$op.result.observed=$true;$op.result.status='observed'
        }
    }
    return $op
}
function Complete-Hotpl8ObservedOnboarding([string]$Directory) {
    # The collector owns this write. Read-only status may derive readiness but
    # must not leave a completed addition resumable after its snapshot goes stale.
    $folder=Join-Path $Directory 'onboarding'
    if(-not (Test-Path -LiteralPath $folder -PathType Container)){return}
    $requestLock=$null
    try{
        $requestLock=[IO.File]::Open((Join-Path $folder 'request.lock'),'OpenOrCreate','ReadWrite','None')
        $accounts=@(Get-Hotpl8ProviderAccounts (Read-Hotpl8Json (Join-Path $Directory 'policy.json')))
        foreach($file in @(Get-ChildItem -LiteralPath $folder -Filter '*.json'|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 64)){
            $workerLock=$null
            try{
                $saved=Read-Hotpl8Json $file.FullName
                if($saved.schemaVersion -ne 1 -or $saved.id -cnotmatch '^[0-9a-f]{32}$' -or $file.BaseName -cne $saved.id -or $saved.phase -ne 'pending' -or -not $saved.result.enrolled){continue}
                if(-not @($accounts|Where-Object {$_.provider -ceq $saved.selected.provider -and [string]$_.slot -ceq [string]$saved.selected.slot}).Count){continue}
                $workerPath=$file.FullName+'.worker'
                if(Test-Path -LiteralPath $workerPath){$workerLock=[IO.File]::Open($workerPath,'Open','ReadWrite','None')}
                $observed=Get-Hotpl8OnboardingProgress $Directory $saved.id
                if($observed.phase -in @('ready','already_connected')){Save-Hotpl8Onboarding $Directory $observed}
            }catch{
                # Busy workers and malformed progress never interrupt collection.
            }finally{if($workerLock){$workerLock.Dispose()}}
        }
    }catch{
        # An active request wins; the next collection can reconcile completion.
    }finally{if($requestLock){$requestLock.Dispose()}}
}
function Save-Hotpl8Onboarding([string]$Directory,$Operation) {
    if(Test-Path -LiteralPath ((Get-Hotpl8OnboardingPath $Directory $Operation.id)+'.cancel')){
        $Operation.phase='canceled';$Operation.message='Setup canceled. Existing accounts were retained.';$Operation.handoff=$null
    }
    $Operation.updatedAt=[datetimeoffset]::UtcNow.ToString('o')
    Write-Hotpl8Text (Get-Hotpl8OnboardingPath $Directory $Operation.id) ($Operation|ConvertTo-Json -Depth 20) -NoBom
}
function Set-Hotpl8OnboardingPhase([string]$Directory,$Operation,[string]$Phase,[string]$Message) {
    $Operation.phase=$Phase;$Operation.message=$Message
    Save-Hotpl8Onboarding $Directory $Operation
}
function Get-Hotpl8OnboardingResult($Operation) {
    # Native paths/identities stay local. Only this explicit operation returns its login handoff.
    $actions=switch($Operation.phase){
        'needs_provider'{@('choose_provider','cancel')}
        'needs_account_choice'{@('choose_account','sign_in','cancel')}
        'needs_install_authorization'{@('install','cancel')}
        'needs_sign_in'{@('sign_in','cancel')}
        'awaiting_sign_in'{@('status','cancel')}
        'pending'{@('retry','cancel')}
        'failed'{@('retry','cancel')}
        'already_connected'{@('sign_in','cancel')}
        'ready'{@('status')}
        'canceled'{@('status')}
        default{@('status','cancel')}
    }
    [pscustomobject]@{operationId=$Operation.id;phase=$Operation.phase;provider=$Operation.provider;message=$Operation.message;humanRequired=($Operation.phase -in @('needs_provider','needs_account_choice','needs_install_authorization','needs_sign_in','awaiting_sign_in','already_connected'));nextActions=@($actions);retryAfterSeconds=$(if($Operation.phase -in @('preparing','verifying','awaiting_sign_in')){2}elseif($Operation.phase -eq 'pending'){60}else{$null});candidates=@($Operation.candidates|Select-Object id,provider,label,enrolled);dependencies=@($Operation.dependencies);handoff=$Operation.handoff;account=$Operation.result;worker=$Operation.worker;updatedAt=$Operation.updatedAt}
}
function Initialize-Hotpl8Onboarding([string]$Directory) {
    $null=New-Hotpl8PrivateDirectory $Directory
    $null=New-Hotpl8PrivateDirectory (Join-Path $Directory 'onboarding')
    $existingPolicy=Join-Path $Directory 'policy.json'
    if(Test-Path -LiteralPath $existingPolicy){Assert-Hotpl8Policy (Read-Hotpl8Json $existingPolicy);return}
    $lock=$null
    try{
        $lock=[IO.File]::Open((Join-Path $Directory 'tick.lock'),'OpenOrCreate','ReadWrite','None')
        $path=Join-Path $Directory 'policy.json'
        if(-not (Test-Path -LiteralPath $path)){
            $example=Join-Path (Split-Path $PSScriptRoot -Parent) 'policy.example.json'
            Write-Hotpl8Text $path ([IO.File]::ReadAllText($example))
        }
        Assert-Hotpl8Policy (Read-Hotpl8Json $path)
    }finally{if($lock){$lock.Dispose()}}
}
function Test-Hotpl8OnboardingTool([string]$Executable,[string]$Minimum) {
    if(-not $Executable -or [IO.Path]::GetExtension($Executable) -in @('.cmd','.bat','.ps1')){return $false}
    try{
        $r=Invoke-Hotpl8Process $Executable @('--version') 15000
        $match=[regex]::Match($r.output,'(?<![0-9])([0-9]+\.[0-9]+\.[0-9]+)(?![0-9])')
        return $r.exitCode -eq 0 -and $match.Success -and [version]$match.Groups[1].Value -ge [version]$Minimum
    }catch{return $false}
}
function Get-Hotpl8OnboardingDependencies([string]$Provider) {
    if($Provider -eq 'codex'){
        $exe=$null;try{$exe=Resolve-CodexExecutable ''}catch{}
        if(-not (Test-Hotpl8OnboardingTool $exe '0.155.1')){'codex'}
    }elseif($Provider -eq 'claude'){
        $exe=(Get-Command claude -ErrorAction SilentlyContinue).Source
        if(-not (Test-Hotpl8OnboardingTool $exe '2.1.281')){'claude'}
        if(-not (Test-Hotpl8OnboardingTool (Resolve-CswapExecutable '') '0.26.0')){'claude-swap'}
    }
}
function Get-Hotpl8OnboardingCandidates([string]$Directory,[string]$Provider) {
    $policy=Read-Hotpl8Json (Join-Path $Directory 'policy.json')
    if($Provider -eq 'codex'){
        $rows=@(Get-Hotpl8ProviderAccounts $policy|Where-Object provider -EQ 'codex')
        $part=(Get-Hotpl8ProviderView $null $policy codex).policy.codex
        $homes=@(@($part.slots|ForEach-Object home)+@($env:CODEX_HOME,(Join-Path (Get-Hotpl8UserHome) '.codex'))|Where-Object {$_ -and (Test-Path -LiteralPath $_ -PathType Container)}|Select-Object -Unique)
        foreach($path in $homes){
            $full=[IO.Path]::GetFullPath($path)
            $slot=@($part.slots|Where-Object {[IO.Path]::GetFullPath($_.home) -eq $full}|Select-Object -First 1)
            # Registered homes need no provider round trip merely to offer them.
            # The chosen account is verified before enrollment/readiness.
            $read=[pscustomobject]@{status='enrolled'}
            if(-not $slot.Count){
                $read=Read-CodexQuota $full '' (Get-CodexReadBudgetMs) -IdentityOnly
                if($read.status -ne 'ok' -or -not $read.standardTransport -or ($read.modelProvider -and $read.modelProvider -ne 'openai')){continue}
            }
            [pscustomobject]@{id=(Get-Hotpl8Hash ('codex|'+$full)).Substring(0,20);provider='codex';label=$(if($slot){$slot[0].label}else{'Existing Codex sign-in'});home=$full;slot=$(if($slot){[string]$slot[0].id}else{''});enrolled=($slot.Count -gt 0);status=$read.status}
        }
    }elseif($Provider -eq 'claude'){
        $exe=Resolve-CswapExecutable ''
        if($exe){
            $r=Invoke-Hotpl8Process $exe @('list','--json') 20000
            if($r.exitCode -ne 0){throw 'Native inventory unavailable.'}
            $inventory=$r.output|ConvertFrom-Json
            if($inventory.schemaVersion -ne 1){throw 'Native inventory unsupported.'}
            $part=(Get-Hotpl8ProviderView $null $policy claude).policy
            foreach($a in @($inventory.accounts)){
                if($a.number -notmatch '^[1-9][0-9]{0,3}$' -or $a.accountType -eq 'api_key'){continue}
                [pscustomobject]@{id=('claude-'+$a.number);provider='claude';label=$(if($a.alias){ConvertTo-Hotpl8SafeText $a.alias}else{'Claude account '+$a.number});home='';slot=[string]$a.number;enrolled=([int]$a.number -in @($part.prefer));status=[string]$a.usageStatus}
            }
        }
    }
}
function Start-Hotpl8OnboardingWorker([string]$Directory,[string]$Id) {
    $shell=(Get-Process -Id $PID).Path
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$shell;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $worker=Join-Path (Split-Path $PSScriptRoot -Parent) 'onboarding-worker.ps1'
    $psi.Arguments=(@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$worker,'-StateDirectory',$Directory,'-OperationId',$Id)|ForEach-Object{ConvertTo-NativeArgument $_}) -join ' '
    # The worker emits no native output and survives a short-lived agent request.
    if($env:OS -ne 'Windows_NT'){
        # Fixed shell program, with every dynamic value passed as a positional argument.
        # Disconnect the terminal without nohup creating a file in the caller's directory.
        $workerArgs=@('-c','exec /usr/bin/nohup "$@" </dev/null >/dev/null 2>&1','hotpl8-worker',$shell,'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$worker,'-StateDirectory',$Directory,'-OperationId',$Id)
        $psi.FileName='/bin/sh';$psi.Arguments=(@($workerArgs|ForEach-Object{ConvertTo-NativeArgument $_}) -join ' ')
    }else{
        Start-Hotpl8WindowsWorker $shell $psi.Arguments
        return
    }
    $p=[Diagnostics.Process]::Start($psi)
    $p.Dispose()
}
function Invoke-Hotpl8Onboarding([string]$Directory,[string]$Action='begin',[string]$Id,[string]$Provider,[string]$CandidateId,[switch]$NewAccount,[switch]$AllowInstall,[switch]$DeviceCode) {
    if($Provider -and $Provider -cnotin @('claude','codex')){throw 'Choose claude or codex.'}
    if($Action -cnotin @('begin','status','choose_provider','choose_account','sign_in','install','retry','cancel')){throw 'Unsupported onboarding action.'}
    if($Id){$null=Get-Hotpl8OnboardingPath $Directory $Id}elseif($Action -ne 'begin'){throw 'Operation ID is required.'}
    if($Action -eq 'status'){return Get-Hotpl8OnboardingResult (Get-Hotpl8OnboardingProgress $Directory $Id)}
    Initialize-Hotpl8Onboarding $Directory
    $lock=$null
    try{
        $lock=[IO.File]::Open((Join-Path $Directory 'onboarding/request.lock'),'OpenOrCreate','ReadWrite','None')
        if(-not $Id){
            # Human re-entry resumes the most recent unfinished compatible operation.
            $recent=@(Get-ChildItem (Join-Path $Directory 'onboarding') -Filter '*.json'|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 64)
            foreach($file in $recent){
                $old=Read-Hotpl8Json $file.FullName
                if($old.schemaVersion -eq 1 -and $old.id -cmatch '^[0-9a-f]{32}$'){$old=Get-Hotpl8OnboardingProgress $Directory $old.id}
                if($old.schemaVersion -eq 1 -and $old.id -cmatch '^[0-9a-f]{32}$' -and $old.phase -notin @('ready','canceled') -and [bool]$old.newAccount -eq [bool]$NewAccount -and (-not $Provider -or $old.provider -eq $Provider)){$Id=$old.id;break}
            }
            if(-not $Id){$Id=[guid]::NewGuid().ToString('N')}
        }
        $path=Get-Hotpl8OnboardingPath $Directory $Id
        if(Test-Path -LiteralPath $path){
            $op=Get-Hotpl8OnboardingProgress $Directory $Id
            if($Action -eq 'begin'){
                if(($Provider -and $op.provider -cne $Provider) -or ([bool]$NewAccount -ne [bool]$op.newAccount)){throw 'Operation ID already used for a different request.'}
                return Get-Hotpl8OnboardingResult $op
            }
        }else{
            if($Action -ne 'begin'){throw 'Onboarding operation not found.'}
            $op=[pscustomobject]@{schemaVersion=1;id=$Id;provider=$Provider;newAccount=[bool]$NewAccount;allowInstall=[bool]$AllowInstall;deviceCode=[bool]$DeviceCode;attempt=0;phase='preparing';message='Checking this installation.';updatedAt='';candidates=@();dependencies=@();selected=$null;handoff=$null;result=$null;action='discover'}
        }
        if($Action -eq 'cancel'){
            if($op.phase -eq 'ready'){return Get-Hotpl8OnboardingResult $op}
            Write-Hotpl8Text ($path+'.cancel') 'cancel' -NoBom
            $op.handoff=$null
            Set-Hotpl8OnboardingPhase $Directory $op 'canceled' 'Setup canceled. Existing accounts were retained.'
            return Get-Hotpl8OnboardingResult $op
        }
        if($op.phase -in @('ready','canceled')){return Get-Hotpl8OnboardingResult $op}
        if($Action -ne 'begin'){
            # A live worker owns transitions. Requests may cancel, never overwrite it.
            $probe=$null
            try{$probe=[IO.File]::Open(($path+'.worker'),'OpenOrCreate','ReadWrite','None')}catch{return Get-Hotpl8OnboardingResult $op}finally{if($probe){$probe.Dispose()}}
            if($op.phase -in @('preparing','verifying','awaiting_sign_in') -and ([datetimeoffset]::UtcNow-[datetimeoffset]::Parse($op.updatedAt)).TotalSeconds -lt 15){return Get-Hotpl8OnboardingResult $op}
            if($Action -cnotin (Get-Hotpl8OnboardingResult $op).nextActions){throw 'Action is not available at this setup step.'}
            if($Provider -and $Action -ne 'choose_provider' -and $op.provider -cne $Provider){throw 'Operation provider cannot change.'}
            if($Provider){$op.provider=$Provider}
            if($AllowInstall){$op.allowInstall=$true}
            if($DeviceCode){$op.deviceCode=$true}
            switch($Action){
                'choose_provider'{if(-not $Provider){throw 'Provider is required.'};$op.action='discover'}
                'choose_account'{
                    $matches=@($op.candidates|Where-Object id -CEQ $CandidateId)
                    if($matches.Count -ne 1){throw 'Choose an account from this operation.'}
                    $op.selected=$matches[0];$op.action='enroll'
                }
                'sign_in'{
                    if($op.phase -eq 'already_connected'){
                        $op|Add-Member NoteProperty attempt ([int]$op.attempt+1) -Force
                        $op.selected=$null;$op.result=$null
                    }
                    $op.action='login'
                }
                'install'{if(-not $AllowInstall){throw 'Dependency installation needs explicit authorization.'};$op.action='install'}
                'retry'{if($op.action -ne 'login'){$op.action=if($op.selected){'enroll'}else{'discover'}}}
                default{throw 'Unsupported onboarding action.'}
            }
        }
        $op.handoff=$null
        Set-Hotpl8OnboardingPhase $Directory $op 'preparing' 'Preparing account setup.'
        Start-Hotpl8OnboardingWorker $Directory $Id
        return Get-Hotpl8OnboardingResult $op
    }finally{if($lock){$lock.Dispose()}}
}
function Test-Hotpl8OnboardingCanceled([string]$Directory,$Operation) {
    return Test-Path -LiteralPath ((Get-Hotpl8OnboardingPath $Directory $Operation.id)+'.cancel')
}
function Invoke-Hotpl8OnboardingWorker([string]$Directory,[string]$Id) {
    $path=Get-Hotpl8OnboardingPath $Directory $Id;$lock=$null
    try{$lock=[IO.File]::Open(($path+'.worker'),'OpenOrCreate','ReadWrite','None')}catch{return}
    try{
        $op=Read-Hotpl8Onboarding $Directory $Id
        $releaseRoot=Split-Path $PSScriptRoot -Parent
        $build=Read-Hotpl8Json (Join-Path $releaseRoot 'build-info.json')
        $op|Add-Member NoteProperty worker ([pscustomobject]@{version=([IO.File]::ReadAllText((Join-Path $releaseRoot 'VERSION'))).Trim();sha=$build.sha;startedAt=[datetimeoffset]::UtcNow.ToString('o')}) -Force
        if($op.phase -in @('ready','canceled') -or (Test-Hotpl8OnboardingCanceled $Directory $op)){return}
        if(-not $op.provider){
            # Discovery is allowed to resolve intent only from usable, unenrolled accounts.
            $found=@()
            foreach($provider in @('claude','codex')){
                if(@(Get-Hotpl8OnboardingDependencies $provider).Count -eq 0){$found+=@(Get-Hotpl8OnboardingCandidates $Directory $provider|Where-Object {-not $_.enrolled -and $_.status -eq 'ok'})}
            }
            if($found.Count -eq 1){$op.provider=$found[0].provider;$op.selected=$found[0];$op.action='enroll'}
            else{Set-Hotpl8OnboardingPhase $Directory $op 'needs_provider' 'Which account would you like to connect: Claude or ChatGPT/Codex?';return}
        }
        $op.dependencies=@(Get-Hotpl8OnboardingDependencies $op.provider)
        if($op.dependencies.Count){
            if(-not $op.allowInstall){Set-Hotpl8OnboardingPhase $Directory $op 'needs_install_authorization' ('Install the required integration: '+($op.dependencies -join ', ')+'.');return}
            Install-Hotpl8OnboardingDependencies $Directory $op.provider
            $op.dependencies=@(Get-Hotpl8OnboardingDependencies $op.provider)
            if($op.dependencies.Count){throw 'Required integration is still unavailable.'}
        }
        if($op.action -in @('discover','install')){
            $op.candidates=@(Get-Hotpl8OnboardingCandidates $Directory $op.provider)
            $available=@($op.candidates|Where-Object {-not $_.enrolled})
            if($available.Count -eq 1){$op.selected=$available[0];$op.action='enroll'}
            elseif($available.Count -gt 1){Set-Hotpl8OnboardingPhase $Directory $op 'needs_account_choice' 'Choose an existing account, or sign into another.';return}
            elseif($op.candidates.Count -eq 1 -and -not $op.newAccount){$op.selected=$op.candidates[0];$op.action='enroll'}
            elseif(-not $op.newAccount -and $op.provider -eq 'claude' -and $op.candidates.Count -eq 0){
                $captured=Add-Hotpl8NativeClaudeAccount $Directory $op -Existing
                if($captured){$op.selected=$captured;$op.action='enroll'}
            }
            if($op.action -ne 'enroll'){Set-Hotpl8OnboardingPhase $Directory $op 'needs_sign_in' 'Sign in to connect your account. HotPl8 will finish automatically.';return}
        }
        if(Test-Hotpl8OnboardingCanceled $Directory $op){return}
        if($op.action -eq 'login'){
            $op.selected=Connect-Hotpl8NativeAccount $Directory $op
            if(-not $op.selected){return}
            $op.action='enroll';$op.handoff=$null;Save-Hotpl8Onboarding $Directory $op
        }
        if(Test-Hotpl8OnboardingCanceled $Directory $op){return}
        Set-Hotpl8OnboardingPhase $Directory $op 'verifying' 'Connecting the account and reading usage.'
        Complete-Hotpl8OnboardingAccount $Directory $op
    }catch{
        # Native exceptions/output can contain tokens. Persist only a fixed recovery message.
        if($op -and -not (Test-Hotpl8OnboardingCanceled $Directory $op)){
            $op.handoff=$null
            Set-Hotpl8OnboardingPhase $Directory $op 'pending' 'Setup could not finish yet. Your progress is saved; retry this operation.'
        }
    }finally{if($lock){$lock.Dispose()}}
}
