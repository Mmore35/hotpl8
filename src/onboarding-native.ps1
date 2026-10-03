# Explicit native sign-in only. No provider prompts, global logout, or token copying.
function New-Hotpl8OnboardingProcess([string]$Executable,[string[]]$Arguments,[string]$AccountHome,[string]$Provider,[switch]$PreserveProfileBindings) {
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$Executable;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.Arguments=(@($Arguments|ForEach-Object{ConvertTo-NativeArgument $_}) -join ' ')
    if([IO.Path]::GetExtension($Executable) -in @('.cmd','.bat','.ps1')){throw 'A native executable is required.'}
    $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $psi.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    foreach($key in @('OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','CODEX_SQLITE_HOME','ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','CLAUDE_CODE_OAUTH_TOKEN','CLAUDE_CODE_USE_BEDROCK','CLAUDE_CODE_USE_VERTEX','CLAUDE_CODE_USE_FOUNDRY')){$psi.EnvironmentVariables.Remove($key)}
    if(-not $PreserveProfileBindings){$psi.EnvironmentVariables.Remove('CLAUDE_SECURESTORAGE_CONFIG_DIR')}
    if($AccountHome){
        $psi.WorkingDirectory=$AccountHome
        $psi.EnvironmentVariables[$(if($Provider -eq 'codex'){'CODEX_HOME'}else{'CLAUDE_CONFIG_DIR'})]=$AccountHome
    }
    return $psi
}
function Invoke-Hotpl8NativeCapture([string]$Executable,[string[]]$Arguments,[string]$AccountHome,[int]$TimeoutMs=20000,[switch]$PreserveProfileBindings) {
    return Invoke-Hotpl8ProcessInfo (New-Hotpl8OnboardingProcess $Executable $Arguments $AccountHome claude -PreserveProfileBindings:$PreserveProfileBindings) $TimeoutMs
}
function Get-Hotpl8ClaudeExecutable {return (Get-Command claude -ErrorAction Stop).Source}
function Add-Hotpl8NativeClaudeAccount([string]$Directory,$Operation,[switch]$Existing) {
    $profile=if($Existing){$env:CLAUDE_CONFIG_DIR}else{$Operation.selected.home}
    $exe=Get-Hotpl8ClaudeExecutable
    $status=Invoke-Hotpl8NativeCapture $exe @('auth','status','--json') $profile -PreserveProfileBindings:$Existing
    if($status.exitCode -ne 0){return $null}
    $identity=$status.output|ConvertFrom-Json
    if(-not $identity.loggedIn -or $identity.authMethod -ne 'claude.ai' -or -not $identity.email){return $null}
    $cswap=Resolve-CswapExecutable ''
    $capture=Invoke-Hotpl8NativeCapture $cswap @('add') $profile -PreserveProfileBindings:$Existing
    if($capture.exitCode -ne 0){throw 'Native capture did not complete.'}
    $inventory=Invoke-Hotpl8Process $cswap @('list','--json') 20000
    if($inventory.exitCode -ne 0){throw 'Native inventory unavailable.'}
    $data=$inventory.output|ConvertFrom-Json
    $matches=@($data.accounts|Where-Object { $_.email -eq $identity.email -and (-not $identity.orgId -or $_.organizationUuid -eq $identity.orgId) })
    if($data.schemaVersion -ne 1 -or $matches.Count -ne 1){throw 'Captured identity is ambiguous.'}
    $row=$matches[0]
    return [pscustomobject]@{id=('claude-'+$row.number);provider='claude';label=('Claude account '+$row.number);home=$profile;slot=[string]$row.number;enrolled=$false;status=[string]$row.usageStatus}
}
function Connect-Hotpl8NativeAccount([string]$Directory,$Operation) {
    $provider=$Operation.provider
    # Stable across retries; a successful sign-in survives interruption and quota failures.
    if(-not $Operation.selected){
        $nativeRoot=New-Hotpl8PrivateDirectory (Join-Path $Directory 'accounts')
        $native=New-Hotpl8PrivateDirectory (Join-Path $nativeRoot ($provider+'-'+$Operation.id+'-'+[int]$Operation.attempt))
        $Operation.selected=[pscustomobject]@{id=$Operation.id;provider=$provider;label='';home=$native;slot='';enrolled=$false;status='unknown'}
        Save-Hotpl8Onboarding $Directory $Operation
    }
    $native=$Operation.selected.home
    $proc=$null
    try{
        if($provider -eq 'codex'){
            $existing=Read-CodexQuota $native '' (Get-CodexReadBudgetMs) -IdentityOnly
            if($existing.status -eq 'ok'){return $Operation.selected}
            $exe=Resolve-CodexExecutable ''
            $psi=New-Hotpl8OnboardingProcess $exe @('app-server','--stdio') $native codex
            $proc=Start-CodexQuotaProcess $psi
            $errors=$proc.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
            $clock=[Diagnostics.Stopwatch]::StartNew()
            $null=Invoke-CodexRpc $proc $clock 15000 1 initialize @{clientInfo=@{name='hotpl8-onboarding';version='1'}}
            $proc.StandardInput.WriteLine('{"method":"initialized"}');$proc.StandardInput.Flush()
            $kind=if($Operation.deviceCode){'chatgptDeviceCode'}else{'chatgpt'}
            $login=Invoke-CodexRpc $proc $clock 30000 2 'account/login/start' @{type=$kind}
            $url=if($Operation.deviceCode){[string]$login.verificationUrl}else{[string]$login.authUrl}
            $uri=[uri]$url
            if($uri.Scheme -ne 'https' -or $uri.Host -notin @('auth.openai.com','chatgpt.com','auth0.openai.com')){throw 'Unexpected native sign-in origin.'}
            $Operation.handoff=[pscustomobject]@{url=$url;code=$(if($Operation.deviceCode){$login.userCode}else{$null});expiresAt=[datetimeoffset]::UtcNow.AddMinutes(15).ToString('o')}
            Set-Hotpl8OnboardingPhase $Directory $Operation 'awaiting_sign_in' 'Complete provider sign-in. HotPl8 is waiting and will finish automatically.'
            $line=$null;$done=$false
            while($clock.Elapsed.TotalMinutes -lt 15){
                if(Test-Hotpl8OnboardingCanceled $Directory $Operation){
                    $proc.StandardInput.WriteLine((@{id=3;method='account/login/cancel';params=@{loginId=$login.loginId}}|ConvertTo-Json -Compress));$proc.StandardInput.Flush();return $null
                }
                if(-not $line){$line=$proc.StandardOutput.ReadLineAsync()}
                if($line.Wait(200)){
                    $text=$line.Result;$line=$null
                    if($null -eq $text){break}
                    if($text.Length -gt 1048576){throw 'Native response exceeded limit.'}
                    $event=$text|ConvertFrom-Json
                    if($event.method -eq 'account/login/completed' -and $event.params.loginId -eq $login.loginId){
                        if(-not $event.params.success){throw 'Native sign-in failed.'}
                        $done=$true;break
                    }
                }
            }
            if(-not $done){throw 'Native sign-in expired.'}
            return $Operation.selected
        }
        $captured=Add-Hotpl8NativeClaudeAccount $Directory $Operation
        if($captured){return $captured}
        $exe=Get-Hotpl8ClaudeExecutable
        Initialize-Hotpl8LoginReader
        $proc=Start-CodexQuotaProcess (New-Hotpl8OnboardingProcess $exe @('auth','login','--claudeai') $native claude)
        $proc.StandardInput.Close()
        $clock=[Diagnostics.Stopwatch]::StartNew();$streams=@()
        foreach($reader in @($proc.StandardOutput,$proc.StandardError)){$streams+=@{reader=(New-Object HotPl8.NativeLoginReader($reader.BaseStream));text=''}}
        Set-Hotpl8OnboardingPhase $Directory $Operation 'awaiting_sign_in' 'Complete Claude sign-in in the browser. HotPl8 will finish automatically.'
        while(-not $proc.HasExited -and $clock.Elapsed.TotalMinutes -lt 15){
            if(Test-Hotpl8OnboardingCanceled $Directory $Operation){return $null}
            foreach($stream in $streams){
                if($stream.reader.LimitExceeded){throw 'Native output exceeded limit.'}
                $bytes=$stream.reader.Take()
                if($null -ne $bytes){
                    $stream.text+=[Text.Encoding]::UTF8.GetString($bytes)
                    # A pipe chunk can end halfway through a valid-looking URL.
                    # Wait for the native output delimiter before exposing the handoff.
                    $match=[regex]::Match($stream.text,'https://(?:claude\.ai|platform\.claude\.com|console\.anthropic\.com)/[^\s\x1b]+(?=[\s\x1b])')
                    if($match.Success -and -not $Operation.handoff){
                        $Operation.handoff=[pscustomobject]@{url=$match.Value;code=$null;expiresAt=[datetimeoffset]::UtcNow.AddMinutes(15).ToString('o')}
                        Save-Hotpl8Onboarding $Directory $Operation
                    }
                    if($stream.text.Length -gt 16384){$stream.text=$stream.text.Substring($stream.text.Length-8192)}
                }
            }
            Start-Sleep -Milliseconds 100
        }
        if(-not $proc.HasExited -or $proc.ExitCode -ne 0){throw 'Native sign-in did not complete.'}
        return Add-Hotpl8NativeClaudeAccount $Directory $Operation
    }finally{Stop-Hotpl8Process $proc}
}
function Register-Hotpl8OnboardingCodex([string]$Directory,$Operation) {
    $path=Join-Path $Directory 'policy.json';$hash=(Get-FileHash $path).Hash
    $policy=Read-Hotpl8Json $path;Assert-Hotpl8Policy $policy
    $part=if($policy.schemaVersion -eq 3){$policy.providers.codex}else{$policy.codex}
    if(-not $part){
        $part=(Read-Hotpl8Json (Join-Path (Split-Path $PSScriptRoot -Parent) 'policy.example.json')).codex
        if($policy.schemaVersion -eq 3){$policy.providers|Add-Member NoteProperty codex $part}else{$policy|Add-Member NoteProperty codex $part}
    }
    $candidate=$Operation.selected
    $read=Read-CodexQuota $candidate.home '' (Get-CodexReadBudgetMs) -IdentityOnly
    if($read.status -ne 'ok' -or -not $read.identityKey -or -not $read.identityVerified -or -not $read.standardTransport -or ($read.modelProvider -and $read.modelProvider -ne 'openai')){throw 'Native subscription identity unavailable.'}
    # Compare identity without requiring any peer to have quota. Incomplete identity
    # verification retains the candidate home in the operation, outside usable capacity.
    foreach($registration in @(Get-Hotpl8ConfiguredProviders $policy|Where-Object driver -EQ 'codex-app-server')){
        foreach($peer in @($registration.policy.slots)){
            if([IO.Path]::GetFullPath($peer.home) -eq [IO.Path]::GetFullPath($candidate.home)){$candidate.slot=$peer.id;$candidate.provider=$registration.id;return}
            $identity=Read-CodexQuota $peer.home '' (Get-CodexReadBudgetMs) -IdentityOnly
            if($identity.status -ne 'ok' -or -not $identity.identityVerified){throw 'Existing identity pending verification.'}
            if($identity.identityKey -eq $read.identityKey){$candidate.slot=$peer.id;$candidate.provider=$registration.id;$candidate.enrolled=$true;return}
        }
    }
    if(-not $candidate.slot){$candidate.slot='account-'+$Operation.id.Substring(0,8)}
    $label=if($candidate.label){$candidate.label}else{'Codex '+(@($part.slots).Count+1)}
    $part.slots=@($part.slots)+@([pscustomobject]@{id=$candidate.slot;home=$candidate.home;label=$label})
    $part.prefer=@($part.prefer)+@($candidate.slot)
    if(Test-Hotpl8OnboardingCanceled $Directory $Operation){throw 'setup_canceled'}
    Save-Hotpl8Policy $Directory $policy $hash
    # A returning subscription gets its parked settings back; never fail a
    # completed enrollment over that.
    try{$null=Restore-Hotpl8ParkedAccount $Directory codex $candidate.slot $candidate.home ''}catch{}
}
function Complete-Hotpl8OnboardingAccount([string]$Directory,$Operation) {
    if(Test-Hotpl8OnboardingCanceled $Directory $Operation){return}
    $commitLock=$null
    try{
        $commitLock=[IO.File]::Open((Join-Path $Directory 'onboarding/request.lock'),'OpenOrCreate','ReadWrite','None')
        if(Test-Hotpl8OnboardingCanceled $Directory $Operation){return}
    if($Operation.provider -eq 'codex'){Register-Hotpl8OnboardingCodex $Directory $Operation}
    else{
        $policy=Read-Hotpl8Json (Join-Path $Directory 'policy.json')
        $registrations=@(Get-Hotpl8ConfiguredProviders $policy|Where-Object driver -EQ 'claude-cswap'|ForEach-Object id)
        $existing=@(Get-Hotpl8ProviderAccounts $policy|Where-Object {$_.provider -in $registrations -and [string]$_.slot -eq $Operation.selected.slot})
        if($existing.Count){$Operation.selected.enrolled=$true;$Operation.selected.provider=$existing[0].provider}
        if(-not $existing.Count){Add-Hotpl8RegisteredAccount $Directory claude $Operation.selected.slot '' $Operation.selected.label ''|Out-Null}
    }
    }finally{if($commitLock){$commitLock.Dispose()}}
    $Operation.result=[pscustomobject]@{enrolled=$true;slot=$Operation.selected.slot;provider=$Operation.selected.provider;alreadyPresent=[bool]($Operation.selected.enrolled -and $Operation.newAccount);observed=$false;status='checking_usage'}
    Save-Hotpl8Onboarding $Directory $Operation
    if($Operation.result.alreadyPresent){
        $Operation.result.status='already_present'
        Set-Hotpl8OnboardingPhase $Directory $Operation 'already_connected' 'This account is already connected. Sign in with another account to add a subscription.'
        return
    }
    # Ordinary observe-only refresh preserves provider backoff and never warms/switches.
    $shell=(Get-Process -Id $PID).Path
    $script=Join-Path (Split-Path $PSScriptRoot -Parent) 'hotpl8.ps1'
    $null=Invoke-Hotpl8Process $shell @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script,'refresh','-StateDirectory',$Directory) 90000
    $snapshot=Read-Hotpl8Json (Join-Path $Directory 'status.json')
    $view=Get-Hotpl8ProviderView $snapshot (Read-Hotpl8Json (Join-Path $Directory 'policy.json')) $Operation.selected.provider
    $rows=if($Operation.provider -eq 'codex'){@($view.snapshot.providers.codex.slots|Where-Object id -EQ $Operation.selected.slot)}else{@($view.snapshot.slots|Where-Object slot -EQ $Operation.selected.slot)}
    if($rows.Count -eq 1 -and $rows[0].status -eq 'ok' -and (Test-Hotpl8FreshTimestamp $rows[0].observedAt)){
        $Operation.result.observed=$true;$Operation.result.status='observed'
        if($Operation.result.alreadyPresent){Set-Hotpl8OnboardingPhase $Directory $Operation 'already_connected' 'This account is already connected. Sign in with another account to add a subscription.'}
        else{Set-Hotpl8OnboardingPhase $Directory $Operation 'ready' 'Account connected. Usage is available in HotPl8.'}
    }else{
        $Operation.result.status='checking_usage'
        Set-Hotpl8OnboardingPhase $Directory $Operation 'pending' 'Account connected. Usage is not available yet; retry or let scheduled collection update it.'
    }
}
