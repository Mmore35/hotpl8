# Offline broker, native launcher and reversible settings integration.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/native.ps1')
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/config.ps1')
. (Join-Path $root 'src/providers/claude.ps1')
. (Join-Path $root 'src/providers/codex.ps1')
$dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-t3-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
$passed=0
function Assert($Value,[string]$Why){if(-not $Value){throw $Why};$script:passed++}
function Reject([scriptblock]$Body,[string]$Code){try{& $Body;throw 'accepted unexpectedly'}catch{Assert ($_.Exception.Message -eq $Code) ('expected '+$Code+', got '+$_.Exception.Message+' at '+$_.ScriptStackTrace)}}
function Save($Name,$Value){Write-Hotpl8Text (Join-Path $dir $Name) ($Value|ConvertTo-Json -Depth 30)}
$savedEnv=@{}
foreach($key in @('OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','CODEX_SQLITE_HOME','OPENAI_BASE_URL','HOTPL8_TEST_LAUNCH')){$savedEnv[$key]=[Environment]::GetEnvironmentVariable($key);[Environment]::SetEnvironmentVariable($key,$null)}
$proc=$null;$titleProc=$null;$accountLock=$null
try{
    $exe=Join-Path $dir 'fake-codex.exe'
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 't3-fake-codex.cs'))) -ReferencedAssemblies System.Web.Extensions -OutputAssembly $exe -OutputType ConsoleApplication
    $now=[datetimeoffset]::UtcNow
    $slots=@();$rows=@();$bindings=@{}
    foreach($id in @('a','b')){
        $accountHome=Join-Path $dir $id;[void][IO.Directory]::CreateDirectory($accountHome)
        Write-Hotpl8Text (Join-Path $accountHome 'auth.json') (@{tokens=@{account_id=$id;access_token=('FAKE-'+$id);refresh_token='NEVER_EXPORT'}}|ConvertTo-Json)
        $slots+=@{id=$id;home=$accountHome;label=$id}
        $read=Read-CodexQuota $accountHome $exe 5000 $dir
        Assert ($read.status -eq 'ok' -and -not $read.PSObject.Properties['auth']) 'ordinary collection must not export access tokens'
        $bindings[$id]=@{binding=(Get-Hotpl8Hash $accountHome);identityKey=$read.identityKey}
        $rows+=@{id=$id;status='ok';observedAt=$now.ToString('o');defaultModel='fixture-model';buckets=(ConvertTo-CodexBuckets $read.quota $null $now)}
    }
    $policy=@{schemaVersion=2;mode='monitor';prefer=@();codex=@{slots=$slots;prefer=@('a','b');reserve=@();order='prefer';defaultMeter='codex';modelMeters=@{'fixture-model'='codex'};margin7d=20;margin7dWork=5}}
    $status=@{observedAt=$now.ToString('o');recommendations=@{codex='a'};slots=$rows}
    Save 'policy.json' $policy;Save 'status.json' @{providers=@{codex=$status}};Save 'codex-state.json' @{slots=$bindings}
    $request=[pscustomobject]@{operation='select';model='fixture-model';cwd=$dir}
    # Which account a request is given is decided by the compiled program, and each rule of
    # that decision is tested beside it (native/src/route.rs). These start the program as
    # the bridge does and let it read the fixture Codex: one request a process.
    $native=Get-Hotpl8NativePath $root
    function Ask($Request,[string]$Line){
        if(-not $Line){$Line=$Request|ConvertTo-Json -Depth 10 -Compress}
        $answer=Invoke-Hotpl8NativeProcess $native @('route','--root',$root,'--state',$dir,'--codex',$exe) -Asked ($Line+"`n")
        $script:answered=$answer.output
        if($answer.errors -or $answer.output -cnotmatch '\A[^\n]+\n\z'){throw 'a route answers one line and nothing else'}
        $said=$answer.output|ConvertFrom-Json
        if($said.error){
            if($answer.exitCode -ne 1 -or @($said.PSObject.Properties).Count -ne 1){throw 'a refusal is its code alone and ends with 1'}
            throw [string]$said.error
        }
        if($answer.exitCode -ne 0){throw 'an account that is given ends with 0'}
        $said
    }
    $route=Ask $request
    Assert ($route.slot -eq 'a' -and $route.home -eq (Join-Path $dir 'a') -and $route.meter -eq 'codex' -and $route.auth.accessToken -eq 'FAKE-a' -and $route.auth.chatgptAccountId -eq 'a') 'preferred native account selected'
    Assert ($script:answered -notmatch 'NEVER_EXPORT') 'refresh token never exported'
    Assert ($route.criticalState.selected -eq 'a' -and $route.authorizationGeneration -match '^[a-f0-9]{64}$') 'an answer names what it was authorized under'
    $execRequest=[pscustomobject]@{operation='exec';model='fixture-model';cwd=$dir}
    $route=Ask $execRequest
    Assert ($route.slot -eq 'a' -and $null -eq $route.auth -and $script:answered -notmatch 'FAKE-') 'a run that is not a chat is not handed the sign-in'
    # A saturated machine makes every native read slow, the collector's included.
    [IO.File]::WriteAllText((Join-Path $dir 'a/start-delay-ms'),'7000')
    Assert ((Ask $request).slot -eq 'a') 'a slow native read still admits the preferred account'
    [IO.File]::Delete((Join-Path $dir 'a/start-delay-ms'))
    $background=[pscustomobject]@{operation='select';intent='rebind';model='fixture-model';previousSlot='a';cwd=$dir}
    Reject {Ask $background} 'routing_monitor_only'
    $policy.mode='automate';$policy.switchEnabled=$true;Save 'policy.json' $policy
    Save 'automation-pause.json' @{until=[datetimeoffset]::UtcNow.AddMinutes(5).ToString('o');reason='fixture'}
    Reject {Ask $background} 'routing_automation_paused'
    Assert ((Ask $request).slot -eq 'a') 'explicit admission remains available during pause'
    [IO.File]::Delete((Join-Path $dir 'automation-pause.json'))
    # What a fresh read finds decides, not what the collector last published.
    $ongoing=[pscustomobject]@{operation='select';intent='rebind';model='fixture-model';models=@('fixture-model');previousSlot='a';cwd=$dir}
    [IO.File]::WriteAllText((Join-Path $dir 'a/used-percent'),'94')
    Assert ((Ask $ongoing).slot -eq 'b') 'fresh native degraded quota yields to healthy work before the five percent floor'
    [IO.File]::Delete((Join-Path $dir 'a/used-percent'))
    [IO.File]::WriteAllText((Join-Path $dir 'a/exhausted'),'1')
    $route=Ask $request
    Assert ($route.slot -eq 'b' -and $route.auth.accessToken -eq 'FAKE-b') 'fresh native exhaustion rolls before send'
    $refresh=[pscustomobject]@{operation='refresh';previousSlot='a';accountId='a';model='fixture-model';cwd=$dir}
    $route=Ask $refresh
    Assert ($route.slot -eq 'a' -and $route.auth.accessToken -eq 'FAKE-a') 'refresh remains pinned even when quota exhausted'
    $refresh.accountId='b';Reject {Ask $refresh} 'routing_refresh_failed'
    $status.observedAt=$now.AddHours(-1).ToString('o');Save 'status.json' @{providers=@{codex=$status}}
    Reject {Ask $request} 'routing_stale'
    $status.observedAt=$now.ToString('o');Save 'status.json' @{providers=@{codex=$status}}
    $policy.codex.Remove('modelMeters');$policy.codex.disabled=@();Save 'policy.json' $policy
    $oldIdentity=$bindings.b.identityKey;$bindings.b.identityKey=$bindings.a.identityKey;Save 'codex-state.json' @{slots=$bindings}
    Reject {Ask $request} 'routing_duplicate_identity'
    $bindings.b.identityKey=$oldIdentity;Save 'codex-state.json' @{slots=$bindings}
    # The caller's own environment is what the program is started with.
    $env:OPENAI_API_KEY='fixture';Reject {Ask $request} 'routing_environment_conflict';$env:OPENAI_API_KEY=$null
    Reject {Ask $null ('{"operation":"select","cwd":"'+('c'*16384)+'"}')} 'routing_invalid_request'
    Reject {Ask $null 'select'} 'routing_failed'
    $refused=@([IO.File]::ReadAllLines((Join-Path $dir 'events.jsonl'))|ForEach-Object{$_|ConvertFrom-Json})
    Assert ((@($refused|ForEach-Object code) -join ' ') -ceq 'routing_monitor_only routing_automation_paused routing_refresh_failed routing_stale routing_duplicate_identity routing_environment_conflict routing_invalid_request routing_failed') 'each refusal leaves its code and an account that is given leaves nothing'
    Assert (-not @($refused|Where-Object{@($_.PSObject.Properties).Count -ne 2 -or -not $_.at})) 'a refusal is recorded as its code and the time'
    [IO.File]::Delete((Join-Path $dir 'events.jsonl'))
    $backgroundRequest=[pscustomobject]@{operation='select';intent='rebind';model='fixture-model';previousSlot='b';cwd=$dir}
    $shared=Join-Path $dir 'shared home';[void][IO.Directory]::CreateDirectory($shared)
    [IO.File]::WriteAllText((Join-Path $shared 'auth.json'),'original-auth-sentinel')
    [IO.File]::WriteAllText((Join-Path $shared 'config.toml'),'original-config-sentinel')
    $settings=@{unrelated='preserve';defaultModelSelection=@{instanceId='codex';model='fixture-model';options=@()};providerInstances=@{codex=@{driver='codex';enabled=$true;config=@{binaryPath='codex';homePath=$shared;shadowHomePath='';launchArgs=''}}}}
    Save 'settings.json' $settings
    $settingsPath=Join-Path $dir 'settings.json';$integration=Join-Path $dir 'integration space'
    $ps=Get-Hotpl8PowerShell
    $setup=Join-Path $root 'setup-t3.ps1'
    $beforeSettings=[IO.File]::ReadAllText($settingsPath)
    # Hosted Windows needs ~23s for first-use PowerShell/module initialization in
    # an isolated profile (also covered by test-onboarding.ps1). This installer
    # harness allowance does not change any native quota or routing timeout.
    $settings.defaultModelSelection.model='';Save 'settings.json' $settings
    $missingModelSettings=[IO.File]::ReadAllText($settingsPath)
    $rejected=Invoke-Hotpl8Process $ps @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$setup,'-Operation','install','-StateDirectory',$dir,'-SettingsPath',$settingsPath,'-IntegrationDirectory',$integration,'-CodexExecutable',$exe,'-TargetProviderId','hotpl8-codex','-MakeDefault') 45000
    Assert ($rejected.exitCode -ne 0 -and -not (Test-Path -LiteralPath $integration)) 'missing native helper selection rejects setup before creating files'
    Assert ([IO.File]::ReadAllText($settingsPath) -ceq $missingModelSettings) 'rejected helper configuration preserves all T3 settings'
    Write-Hotpl8Text $settingsPath $beforeSettings
    $futureIntegration=$integration+' future'
    & $ps -NoProfile -ExecutionPolicy Bypass -File $setup -Operation install -StateDirectory $dir -SettingsPath $settingsPath -IntegrationDirectory $futureIntegration -CodexExecutable $exe -TargetProviderId hotpl8-codex -MakeDefault -TextGenerationModel 'future/helper:revision'
    Assert ($LASTEXITCODE -eq 0) 'unregistered explicit native helper installs without a model map'
    Assert ((Read-Hotpl8Json $settingsPath).textGenerationModelSelection.model -ceq 'future/helper:revision') 'explicit helper model is preserved exactly'
    & $ps -NoProfile -ExecutionPolicy Bypass -File $setup -Operation remove -StateDirectory $dir -SettingsPath $settingsPath -IntegrationDirectory $futureIntegration
    Assert ($LASTEXITCODE -eq 0 -and -not (Read-Hotpl8Json $settingsPath).PSObject.Properties['textGenerationModelSelection']) 'removing explicit helper restores its original absence'
    & $ps -NoProfile -ExecutionPolicy Bypass -File $setup -Operation install -StateDirectory $dir -SettingsPath $settingsPath -IntegrationDirectory $integration -CodexExecutable $exe -TargetProviderId hotpl8-codex -MakeDefault
    Assert ($LASTEXITCODE -eq 0) 'setup succeeds in isolated fixture'
    $installed=Read-Hotpl8Json $settingsPath
    Assert ($installed.providerInstances.codex.config.binaryPath -eq 'codex') 'active original provider not replaced'
    Assert ($installed.defaultModelSelection.instanceId -eq 'hotpl8-codex' -and $installed.defaultModelSelection.model -eq 'fixture-model') 'default routes new chats while preserving model'
    Assert ($installed.providerInstances.'hotpl8-codex'.config.homePath -eq $shared) 'new provider shares conversation home'
    Assert ($installed.textGenerationModelSelection.instanceId -eq 'hotpl8-codex' -and $installed.textGenerationModelSelection.model -eq 'fixture-model') 'implicit T3 helper default routes through a native default model'
    Assert ($installed.textGenerationModelSelection.options[0].value -eq 'low') 'helper default uses low reasoning'
    $launcher=Join-Path $integration 'hotpl8-codex.exe'
    Assert ((& $launcher --version) -eq 'codex-cli fixture') 'native launcher version/stdio passthrough'
    # Hold the title helper's native quota read while a new app-server validates
    # the same healthy home. This is T3's concurrent first-message launch shape.
    $gate=Join-Path $dir 'b/quota-gate';[IO.File]::WriteAllText($gate,'fixture')
    $env:HOTPL8_TEST_LAUNCH=Join-Path $dir 'title.json'
    $titlePsi=New-CodexProcessInfo $launcher $shared @('exec','--model','future-helper-model','-s','read-only','-') $dir
    $titlePsi.RedirectStandardInput=$true;$titlePsi.RedirectStandardOutput=$true;$titlePsi.RedirectStandardError=$true;$titlePsi.CreateNoWindow=$true
    $titleProc=Start-CodexQuotaProcess $titlePsi
    $null=$titleProc.StandardOutput.ReadToEndAsync();$null=$titleProc.StandardError.ReadToEndAsync()
    $titleProc.StandardInput.Write('fixture title');$titleProc.StandardInput.Close()
    $gateClock=[Diagnostics.Stopwatch]::StartNew()
    while(-not (Test-Path -LiteralPath (Join-Path $dir 'b/quota-entered')) -and $gateClock.ElapsedMilliseconds -lt 15000){Start-Sleep -Milliseconds 20}
    Assert (Test-Path -LiteralPath (Join-Path $dir 'b/quota-entered')) 'title broker owns the native home lock before chat startup'
    # The chat's admission reads the spent account first and the held one next. The fixture
    # Codex says when the first was read, which is when the second is asked for.
    [IO.File]::Delete((Join-Path $dir 'a/quota-observed'))
    $psi=New-CodexProcessInfo $launcher $shared @('app-server') $dir
    $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
    $proc=Start-CodexQuotaProcess $psi
    $null=$proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.WriteLine('{"id":1,"method":"initialize","params":{"clientInfo":{"name":"fixture","version":"1"}}}');$proc.StandardInput.Flush()
    $initialization=$proc.StandardOutput.ReadLineAsync()
    $contentionClock=[Diagnostics.Stopwatch]::StartNew()
    while(-not (Test-Path -LiteralPath (Join-Path $dir 'a/quota-observed')) -and -not $initialization.IsCompleted -and $contentionClock.ElapsedMilliseconds -lt 8000){Start-Sleep -Milliseconds 10}
    Assert (Test-Path -LiteralPath (Join-Path $dir 'a/quota-observed')) 'chat native validation reaches the account the title helper holds'
    # Healthy native readers can own the lock longer than the old 2.5 s retry
    # cutoff. Hold it for 3 s AFTER the chat has asked for it, then finish normally.
    Start-Sleep -Milliseconds 3000
    Assert (-not $initialization.IsCompleted) 'chat native validation waits for the title helper lock'
    [IO.File]::Delete($gate)
    Assert ($initialization.Wait(15000)) 'concurrent chat startup responds within its deadline'
    $initialized=$initialization.Result|ConvertFrom-Json
    Assert ($initialized.id -eq 1 -and -not $initialized.error) 'chat startup survives concurrent title admission'
    Assert ($titleProc.WaitForExit(15000) -and $titleProc.ExitCode -eq 7) 'concurrent title helper retains native exit status'
    Assert ((Read-Hotpl8Json $env:HOTPL8_TEST_LAUNCH).input -eq 'fixture title' -and [IO.File]::ReadAllLines($env:HOTPL8_TEST_LAUNCH+'.runs').Count -eq 1) 'title input is submitted exactly once'
    Stop-Hotpl8Process $titleProc;$titleProc=$null
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $null=Invoke-CodexRpc $proc $clock 20000 2 'thread/start' @{model='fixture-model';cwd=$dir}
    [IO.File]::WriteAllText((Join-Path $shared 'keep-active'),'fixture')
    $turn=Invoke-CodexRpc $proc $clock 20000 3 'turn/start' @{threadId='thread-fixture';model='future-chat-model';input=@()}
    Assert ($turn.account -eq 'b') 'real launcher/proxy/broker chooses healthy account for turn'
    Assert ($turn.requestModel -eq 'future-chat-model') 'unregistered model reaches native unchanged'
    # Collector publication may validate a preferred peer, but applying its auth
    # while a turn runs revokes native network permission. Defer until idle.
    [IO.File]::Delete((Join-Path $dir 'a/exhausted'))
    [IO.File]::WriteAllText((Join-Path $dir 'b/used-percent'),'96')
    [IO.File]::Delete((Join-Path $dir 'a/quota-observed'))
    $status.recommendations.codex='a';Save 'status.json' @{providers=@{codex=$status}}
    $validatedPeer=$false;$rollClock=[Diagnostics.Stopwatch]::StartNew();$rpcId=40
    while($rollClock.ElapsedMilliseconds -lt 20000){
        $readClock=[Diagnostics.Stopwatch]::StartNew()
        $current=Invoke-CodexRpc $proc $readClock 2000 (++$rpcId) 'account/read' @{}
        Assert ($current.account.email -eq 'b@example.invalid') 'active native account is retained during background validation'
        if(Test-Path (Join-Path $dir 'a/quota-observed')){$validatedPeer=$true;break}
        Start-Sleep -Milliseconds 50
    }
    Assert $validatedPeer 'collector publication validates the preferred peer'
    $followClock=[Diagnostics.Stopwatch]::StartNew()
    $follow=Invoke-CodexRpc $proc $followClock 5000 (++$rpcId) 'turn/start' @{threadId='thread-fixture';model='future-chat-model';input=@(@{type='text';text='fixture followup'})}
    Assert ($follow.account -eq 'b' -and $follow.turn.id -eq $turn.turn.id -and $follow.toolExecutions -eq 1) 'followup keeps active account turn and executed effects'
    Assert (-not (Test-Path (Join-Path $shared 'network-revoked'))) 'no live auth change revokes native network permission'
    [IO.File]::Delete((Join-Path $shared 'keep-active'))
    $finish=Invoke-CodexRpc $proc ([Diagnostics.Stopwatch]::StartNew()) 5000 (++$rpcId) 'turn/start' @{threadId='thread-fixture';input=@()}
    Assert ($finish.account -eq 'b' -and $finish.toolExecutions -eq 1) 'original work completes under the original account'
    $next=Invoke-CodexRpc $proc ([Diagnostics.Stopwatch]::StartNew()) 15000 (++$rpcId) 'turn/start' @{threadId='thread-fixture';model='future-chat-model';input=@()}
    Assert ($next.account -eq 'a' -and $next.toolExecutions -eq 2) 'next idle admission switches accounts without replaying prior work'
    [IO.File]::Delete((Join-Path $dir 'b/used-percent'))
    [IO.File]::WriteAllText((Join-Path $dir 'a/exhausted'),'1')
    Stop-Hotpl8Process $proc;$proc=$null
    $env:HOTPL8_TEST_LAUNCH=Join-Path $dir 'exec.json'
    $execPsi=New-CodexProcessInfo $launcher $shared @('exec','-s','read-only','--output-last-message','space & % fixture.json','-') $dir
    $execPsi.RedirectStandardInput=$true;$execPsi.RedirectStandardOutput=$true;$execPsi.RedirectStandardError=$true;$execPsi.CreateNoWindow=$true
    $proc=Start-CodexQuotaProcess $execPsi;$proc.StandardInput.Write('fixture prompt');$proc.StandardInput.Close();$proc.WaitForExit()
    Assert ($proc.ExitCode -eq 7) 'exec native exit code propagated'
    $trace=Read-Hotpl8Json $env:HOTPL8_TEST_LAUNCH
    Assert ($trace.home -eq (Join-Path $dir 'b') -and $trace.input -eq 'fixture prompt' -and ($trace.args -join '|') -ceq 'exec|-s|read-only|--output-last-message|space & % fixture.json|-') 'exec home, stdin and argument boundaries preserved'
    Stop-Hotpl8Process $proc;$proc=$null
    Assert ([IO.File]::ReadAllText((Join-Path $shared 'auth.json')) -eq 'original-auth-sentinel') 'shared native auth unchanged'
    Assert ([IO.File]::ReadAllText((Join-Path $shared 'config.toml')) -eq 'original-config-sentinel') 'shared native config unchanged'
    # A lock that never clears is distinct from quota exhaustion and leaves only
    # a fixed failure code in the existing bounded diagnostic log.
    $lockPath=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-codex-'+(Get-Hotpl8Hash ([IO.Path]::GetFullPath((Join-Path $dir 'b')).ToLowerInvariant()))+'.lock')
    $accountLock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')
    $brokerPsi=New-CodexProcessInfo $ps $shared @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'src/codex-route.ps1'),'-StateDirectory',$dir,'-Executable',$exe) $dir
    $brokerPsi.RedirectStandardInput=$true;$brokerPsi.RedirectStandardOutput=$true;$brokerPsi.RedirectStandardError=$true;$brokerPsi.CreateNoWindow=$true
    # A background validation that meets the lock was skipped, not failed: it
    # answers at once and leaves no event behind.
    $proc=Start-CodexQuotaProcess $brokerPsi
    $brokerOutput=$proc.StandardOutput.ReadToEndAsync();$null=$proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.WriteLine(($backgroundRequest|ConvertTo-Json -Compress));$proc.StandardInput.Close()
    Assert ($proc.WaitForExit(20000)) 'a skipped background validation answers without waiting for the lock'
    Assert (($brokerOutput.Result|ConvertFrom-Json).error -eq 'routing_account_busy' -and -not (Test-Path -LiteralPath (Join-Path $dir 'events.jsonl'))) 'a skipped background validation is not recorded as a failure'
    Stop-Hotpl8Process $proc;$proc=$null
    # An admission waits for the lock until its 30 s deadline.
    $proc=Start-CodexQuotaProcess $brokerPsi
    $brokerOutput=$proc.StandardOutput.ReadToEndAsync();$null=$proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.WriteLine(($request|ConvertTo-Json -Compress));$proc.StandardInput.Close()
    $deadlineClock=[Diagnostics.Stopwatch]::StartNew()
    Assert ($proc.WaitForExit(50000) -and $deadlineClock.ElapsedMilliseconds -ge 20000) 'persistent contention returns a bounded broker failure at the admission deadline'
    Assert (($brokerOutput.Result|ConvertFrom-Json).error -eq 'routing_account_busy') 'pipe response distinguishes contention from no capacity'
    $accountLock.Dispose();$accountLock=$null;Stop-Hotpl8Process $proc;$proc=$null
    $events=[IO.File]::ReadAllText((Join-Path $dir 'events.jsonl'))
    $event=($events.Trim()|ConvertFrom-Json)
    Assert ($event.code -eq 'routing_account_busy' -and @($event.PSObject.Properties).Count -eq 2) 'diagnostic event contains only time and fixed failure code'
    Assert ($events -notmatch 'FAKE-|NEVER_EXPORT|fixture-model|account_id' -and -not $events.Contains($dir)) 'contention diagnostics do not disclose credentials or account paths'
    & $ps -NoProfile -ExecutionPolicy Bypass -File $setup -Operation remove -StateDirectory $dir -SettingsPath $settingsPath -IntegrationDirectory $integration
    Assert ($LASTEXITCODE -eq 0) 'rollback succeeds'
    $restored=Read-Hotpl8Json $settingsPath
    Assert ($restored.providerInstances.codex.config.binaryPath -eq 'codex' -and $restored.unrelated -eq 'preserve') 'original provider restored, unrelated settings preserved'
    Assert ($restored.defaultModelSelection.instanceId -eq 'codex' -and -not $restored.providerInstances.PSObject.Properties['hotpl8-codex']) 'rollback removes only added instance and restores matching default'
    Assert (-not $restored.PSObject.Properties['textGenerationModelSelection']) 'rollback restores absent helper setting instead of leaving a removed provider reference'
    $single=Join-Path $dir 'single-provider'
    $beforeSingle=[IO.File]::ReadAllText($settingsPath)|ConvertFrom-Json|ConvertTo-Json -Depth 50 -Compress
    & $ps -NoProfile -ExecutionPolicy Bypass -File $setup -Operation install -StateDirectory $dir -SettingsPath $settingsPath -IntegrationDirectory $single -CodexExecutable $exe -MakeDefault
    Assert ($LASTEXITCODE -eq 0) 'default installation uses the existing Codex provider'
    $one=Read-Hotpl8Json $settingsPath
    Assert (@($one.providerInstances.PSObject.Properties).Count -eq 1 -and -not $one.providerInstances.PSObject.Properties['hotpl8-codex']) 'no duplicate provider or model catalog'
    Assert ($one.defaultModelSelection.instanceId -eq 'codex' -and $one.providerInstances.codex.config.homePath -eq $shared) 'existing conversation ID and home retained'
    Assert ($one.providerInstances.codex.config.binaryPath -eq (Join-Path $single 'hotpl8-codex.exe')) 'ordinary Codex routes through the bridge'
    Assert (-not $one.providerInstances.codex.displayName -and $one.textGenerationModelSelection.instanceId -eq 'codex' -and $one.textGenerationModelSelection.model -eq 'fixture-model') 'normal provider label and native helper model retained'
    & $ps -NoProfile -ExecutionPolicy Bypass -File $setup -Operation remove -StateDirectory $dir -SettingsPath $settingsPath -IntegrationDirectory $single
    Assert ($LASTEXITCODE -eq 0) 'in-place removal succeeds'
    Assert (((Read-Hotpl8Json $settingsPath)|ConvertTo-Json -Depth 50 -Compress) -ceq $beforeSingle) 'in-place removal restores original settings exactly'
    # New installs join an enrolled release without a second provider or an
    # updater race. Build a disposable verified package layout, not live state.
    $managedRoot=Join-Path $dir 'managed-install'
    $sha=('e'*40)
    $release=Join-Path $managedRoot ('releases/'+$sha)
    $hashes=@{}
    foreach($name in (Read-Hotpl8Json (Join-Path $root 'release-files.json')).files){
        $target=Join-Path $release $name
        [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
        [IO.File]::Copy((Join-Path $root $name),$target,$false)
        $hashes[$name]=(Get-FileHash $target).Hash.ToLowerInvariant()
    }
    Write-Hotpl8Text (Join-Path $release 'build-info.json') (@{protocol=1;product='hotpl8';sha=$sha}|ConvertTo-Json) -NoBom
    $hashes['build-info.json']=(Get-FileHash (Join-Path $release 'build-info.json')).Hash.ToLowerInvariant()
    Write-Hotpl8Text (Join-Path $release 'delivery-manifest.json') (@{protocol=1;product='hotpl8';sha=$sha;files=$hashes}|ConvertTo-Json -Depth 10) -NoBom
    [void][IO.Directory]::CreateDirectory((Join-Path $managedRoot 'receipts'))
    Write-Hotpl8Text (Join-Path $managedRoot ('receipts/'+$sha+'.json')) (@{manifestDigest=(Get-FileHash (Join-Path $release 'delivery-manifest.json')).Hash.ToLowerInvariant()}|ConvertTo-Json) -NoBom
    Write-Hotpl8Text (Join-Path $managedRoot 'current.json') (@{protocol=1;sha=$sha;release=('releases/'+$sha)}|ConvertTo-Json) -NoBom
    Write-Hotpl8Text (Join-Path $managedRoot 'delivery.json') (@{protocol=1;product='hotpl8';channel='main';stateDirectory=$dir}|ConvertTo-Json) -NoBom
    $managedIntegration=Join-Path $managedRoot 'integrations/t3-codex'
    & $ps -NoProfile -ExecutionPolicy Bypass -File $setup -Operation install -StateDirectory $dir -SettingsPath $settingsPath -IntegrationDirectory $managedIntegration -CodexExecutable $exe -MakeDefault
    Assert ($LASTEXITCODE -eq 0) 'new managed setup enrolls without nested-lock deadlock'
    Assert ((Read-Hotpl8Json (Join-Path $managedIntegration 'bridge-config.json')).deliveryRoot -eq $managedRoot) 'new setup uses delivery selection'
    Assert ((Read-Hotpl8Json (Join-Path $managedRoot 'delivery.json')).componentHealth) 'new setup registers recurring component readiness'
    $diagnostic=Invoke-Hotpl8Process $ps @('-NoProfile','-ExecutionPolicy','Bypass','-File',$setup,'-Operation','doctor','-StateDirectory',$dir,'-SettingsPath',$settingsPath,'-IntegrationDirectory',$managedIntegration) 30000
    Assert ($diagnostic.exitCode -eq 0 -and ($diagnostic.output|ConvertFrom-Json).delivery.nextLaunchSha -eq $sha) 'doctor proves managed next-launch revision without provider actions'
    Write-Output ($passed.ToString()+' T3 broker/Windows integration checks passed.')
}finally{
    if($gate -and (Test-Path -LiteralPath $gate)){[IO.File]::Delete($gate)}
    if($accountLock){$accountLock.Dispose()}
    Stop-Hotpl8Process $titleProc
    Stop-Hotpl8Process $proc
    foreach($key in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($key,$savedEnv[$key])}
    if([IO.Path]::GetFullPath($dir).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $dir -Leaf) -match '^hotpl8-t3-[a-f0-9]{32}$'){Remove-Item -LiteralPath $dir -Recurse -Force}
}
