# Offline broker, native launcher and reversible settings integration.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/config.ps1')
. (Join-Path $root 'src/providers/claude.ps1')
. (Join-Path $root 'src/providers/codex.ps1')
. (Join-Path $root 'src/codex-routing.ps1')
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
    $route=Get-Hotpl8CodexRoute $request $dir $exe
    Assert ($route.slot -eq 'a' -and $route.auth.accessToken -eq 'FAKE-a') 'preferred native account selected'
    Assert (($route|ConvertTo-Json -Depth 10) -notmatch 'NEVER_EXPORT') 'refresh token never exported'
    $background=[pscustomobject]@{operation='select';intent='rebind';model='fixture-model';previousSlot='a';cwd=$dir}
    $script:controlReads=0
    $unexpectedRead={param($slot,$refresh);$script:controlReads++;throw 'unexpected native read'}
    Reject {Get-Hotpl8CodexRoute $background $dir $exe $unexpectedRead} 'routing_monitor_only'
    Assert ($script:controlReads -eq 0) 'monitor suppresses autonomous routing before native validation'
    $policy.mode='automate';$policy.switchEnabled=$false;Save 'policy.json' $policy
    Reject {Get-Hotpl8CodexRoute $background $dir $exe $unexpectedRead} 'routing_switching_disabled'
    $policy.switchEnabled=$true;Save 'policy.json' $policy
    Save 'automation-pause.json' @{until=$now.AddMinutes(5).ToString('o');reason='fixture'}
    Reject {Get-Hotpl8CodexRoute $background $dir $exe $unexpectedRead} 'routing_automation_paused'
    Assert ((Get-Hotpl8CodexRoute $request $dir $exe).slot -eq 'a') 'explicit admission remains available during pause'
    $pinned=[pscustomobject]@{operation='refresh';previousSlot='a';accountId='a';model='fixture-model';cwd=$dir}
    Assert ((Get-Hotpl8CodexRoute $pinned $dir $exe).slot -eq 'a') 'same-identity token refresh remains available during pause'
    [IO.File]::Delete((Join-Path $dir 'automation-pause.json'))
    $changedDuringRead={param($slot,$refresh,$budget)
        $result=Read-CodexQuota $slot.home $exe $budget $dir -IncludeAccessToken
        Save 'automation-pause.json' @{until=$now.AddMinutes(5).ToString('o');reason='during-validation'}
        return $result
    }
    Reject {Get-Hotpl8CodexRoute $request $dir $exe $changedDuringRead} 'routing_state_changed'
    [IO.File]::Delete((Join-Path $dir 'automation-pause.json'))
    # Same production margins as launch selection, measured on both sides before
    # exhaustion. No separate rollover threshold or quota scheduler.
    $ongoing=[pscustomobject]@{operation='select';intent='rebind';model='fixture-model';models=@('fixture-model');previousSlot='a';cwd=$dir}
    [IO.File]::WriteAllText((Join-Path $dir 'a/used-percent'),'94')
    Assert ((Get-Hotpl8CodexRoute $ongoing $dir $exe).slot -eq 'b') 'fresh native degraded quota yields to healthy work before the five percent floor'
    $script:fallbackReads=@{a=0;b=0}
    $unavailablePeer={param($slot,$refresh,$budget)
        $script:fallbackReads[$slot.id]++
        if($slot.id -eq 'b'){return [pscustomobject]@{status='authentication_required'}}
        Read-CodexQuota $slot.home $exe $budget $dir -IncludeAccessToken
    }
    $fallback=Get-Hotpl8CodexRoute $request $dir $exe $unavailablePeer
    Assert ($fallback.slot -eq 'a' -and $fallback.auth.accessToken -eq 'FAKE-a') 'validated degraded account remains a fallback when healthier peer fails'
    Assert ($script:fallbackReads.a -eq 1 -and $script:fallbackReads.b -eq 1) 'fallback uses one native validation per candidate'
    $changedBeforeFallback={param($slot,$refresh,$budget)
        if($slot.id -eq 'b'){
            Save 'automation-pause.json' @{until=$now.AddMinutes(5).ToString('o');reason='before-fallback'}
            return [pscustomobject]@{status='authentication_required'}
        }
        Read-CodexQuota $slot.home $exe $budget $dir -IncludeAccessToken
    }
    Reject {Get-Hotpl8CodexRoute $request $dir $exe $changedBeforeFallback} 'routing_state_changed'
    [IO.File]::Delete((Join-Path $dir 'automation-pause.json'))
    $reboundBeforeFallback={param($slot,$refresh,$budget)
        if($slot.id -eq 'b'){
            $drift=Read-Hotpl8Json (Join-Path $dir 'codex-state.json');$drift.slots.a.identityKey='changed';Save 'codex-state.json' $drift
            return [pscustomobject]@{status='authentication_required'}
        }
        Read-CodexQuota $slot.home $exe $budget $dir -IncludeAccessToken
    }
    Reject {Get-Hotpl8CodexRoute $request $dir $exe $reboundBeforeFallback} 'routing_binding_changed'
    Save 'codex-state.json' @{slots=$bindings}
    [IO.File]::WriteAllText((Join-Path $dir 'a/used-percent'),'96')
    Reject {Get-Hotpl8CodexRoute $request $dir $exe $unavailablePeer} 'routing_unavailable'
    Assert ((Get-Hotpl8CodexRoute $ongoing $dir $exe).slot -eq 'b') 'four percent rolls ongoing work before account exhaustion'
    Save 'hold.json' @{until=$now.AddMinutes(5).ToString('o');reason='fixture'}
    Reject {Get-Hotpl8CodexRoute $ongoing $dir $exe} 'routing_selection_held'
    $heldExhausted=[pscustomobject]@{operation='select';intent='admit';model='fixture-model';previousSlot='a';cwd=$dir}
    Reject {Get-Hotpl8CodexRoute $heldExhausted $dir $exe} 'routing_unavailable'
    $ongoing.previousSlot='b'
    Reject {Get-Hotpl8CodexRoute $ongoing $dir $exe} 'routing_selection_held'
    $heldAdmission=[pscustomobject]@{operation='select';intent='admit';model='fixture-model';previousSlot='b';cwd=$dir}
    Assert ((Get-Hotpl8CodexRoute $heldAdmission $dir $exe).slot -eq 'b') 'held admission preserves actual process account despite collector recommendation a'
    Reject {Get-Hotpl8CodexRoute $request $dir $exe} 'routing_binding_unknown'
    [IO.File]::Delete((Join-Path $dir 'hold.json'))
    [IO.File]::Delete((Join-Path $dir 'a/used-percent'))
    $policy.codex.modelMeters['other-model']='codex_bengalfox';Save 'policy.json' $policy
    $ongoing.models=@('fixture-model','other-model')
    Reject {Get-Hotpl8CodexRoute $ongoing $dir $exe} 'routing_unavailable'
    $ongoing.models=@('unmapped')
    Reject {Get-Hotpl8CodexRoute $ongoing $dir $exe} 'routing_model_unknown'
    $policy.codex.modelMeters.Remove('other-model');Save 'policy.json' $policy
    [IO.File]::WriteAllText((Join-Path $dir 'a/exhausted'),'1')
    $route=Get-Hotpl8CodexRoute $request $dir $exe
    Assert ($route.slot -eq 'b') 'fresh native exhaustion falls back before inference'
    $script:busyReads=0
    $contended={param($slot,$refresh)
        if($slot.id -eq 'b' -and ++$script:busyReads -le 2){return [pscustomobject]@{status='home_busy'}}
        Read-CodexQuota $slot.home $exe 5000 $dir -IncludeAccessToken -RefreshToken:$refresh
    }
    $route=Get-Hotpl8CodexRoute $request $dir $exe $contended
    Assert ($route.slot -eq 'b' -and $script:busyReads -eq 3) 'temporary account lock is retried before chat admission'
    $script:busyReads=0
    $execRequest=[pscustomobject]@{operation='exec';model='fixture-model';cwd=$dir}
    $route=Get-Hotpl8CodexRoute $execRequest $dir $exe $contended
    Assert ($route.slot -eq 'b' -and $script:busyReads -eq 3 -and -not $route.auth) 'exec shares contention recovery without exporting authentication'
    $script:failedReads=0
    $authFailure={param($slot,$refresh);$script:failedReads++;[pscustomobject]@{status='authentication_required'}}
    Reject {Get-Hotpl8CodexRoute $request $dir $exe $authFailure} 'routing_unavailable'
    Assert ($script:failedReads -eq 2) 'non-lock failures are not retried'
    $busyPreferred={param($slot,$isRefresh)
        if($slot.id -eq 'a'){return [pscustomobject]@{status='home_busy'}}
        Read-CodexQuota $slot.home $exe 5000 $dir -IncludeAccessToken
    }
    Assert ((Get-Hotpl8CodexRoute $request $dir $exe $busyPreferred).slot -eq 'b') 'persistently busy candidate can fall back to another validated account'
    $refresh=[pscustomobject]@{operation='refresh';previousSlot='a';accountId='a';model='fixture-model';cwd=$dir}
    Assert ((Get-Hotpl8CodexRoute $refresh $dir $exe).slot -eq 'a') 'refresh remains pinned even when quota exhausted'
    $script:refreshReads=0
    $refreshContention={param($slot,$isRefresh)
        Assert ($slot.id -eq 'a' -and $isRefresh) 'refresh lock retry retains the exact pinned account'
        if(++$script:refreshReads -eq 1){return [pscustomobject]@{status='home_busy'}}
        Read-CodexQuota $slot.home $exe 5000 $dir -IncludeAccessToken -RefreshToken
    }
    Assert ((Get-Hotpl8CodexRoute $refresh $dir $exe $refreshContention).slot -eq 'a') 'pinned refresh recovers from temporary contention'
    $busy={param($slot,$isRefresh);[pscustomobject]@{status='home_busy'}}
    $busyClock=[Diagnostics.Stopwatch]::StartNew()
    Reject {Get-Hotpl8CodexRoute $refresh $dir $exe $busy} 'routing_account_busy'
    Assert ($busyClock.ElapsedMilliseconds -lt 6500) 'persistent refresh contention has a bounded wait below the bridge deadline'
    $refresh.accountId='b';Reject {Get-Hotpl8CodexRoute $refresh $dir $exe} 'routing_refresh_failed'
    $policy.codex.disabled=@('b');Save 'policy.json' $policy
    Reject {Get-Hotpl8CodexRoute $request $dir $exe} 'routing_unavailable'
    $policy.codex.disabled=@();Save 'policy.json' $policy
    $status.observedAt=$now.AddHours(-1).ToString('o');Save 'status.json' @{providers=@{codex=$status}}
    Reject {Get-Hotpl8CodexRoute $request $dir $exe} 'routing_stale'
    $status.observedAt=$now.ToString('o');Save 'status.json' @{providers=@{codex=$status}}
    $request.model='unmapped';Reject {Get-Hotpl8CodexRoute $request $dir $exe} 'routing_model_unknown';$request.model='fixture-model'
    $oldIdentity=$bindings.b.identityKey;$bindings.b.identityKey=$bindings.a.identityKey;Save 'codex-state.json' @{slots=$bindings}
    Reject {Get-Hotpl8CodexRoute $request $dir $exe} 'routing_duplicate_identity'
    $bindings.b.identityKey=$oldIdentity;Save 'codex-state.json' @{slots=$bindings}
    $oldBinding=$bindings.b.binding;$bindings.b.binding='changed';Save 'codex-state.json' @{slots=$bindings}
    Reject {Get-Hotpl8CodexRoute $request $dir $exe} 'routing_unavailable'
    $bindings.b.binding=$oldBinding;Save 'codex-state.json' @{slots=$bindings}
    $env:OPENAI_API_KEY='fixture';Reject {Get-Hotpl8CodexRoute $request $dir $exe} 'routing_environment_conflict';$env:OPENAI_API_KEY=$null
    $shared=Join-Path $dir 'shared home';[void][IO.Directory]::CreateDirectory($shared)
    [IO.File]::WriteAllText((Join-Path $shared 'auth.json'),'original-auth-sentinel')
    [IO.File]::WriteAllText((Join-Path $shared 'config.toml'),'original-config-sentinel')
    $settings=@{unrelated='preserve';defaultModelSelection=@{instanceId='codex';model='fixture-model';options=@()};providerInstances=@{codex=@{driver='codex';enabled=$true;config=@{binaryPath='codex';homePath=$shared;shadowHomePath='';launchArgs=''}}}}
    Save 'settings.json' $settings
    $settingsPath=Join-Path $dir 'settings.json';$integration=Join-Path $dir 'integration space'
    $ps=(Get-Command powershell).Source
    $setup=Join-Path $root 'setup-t3.ps1'
    $beforeSettings=[IO.File]::ReadAllText($settingsPath)
    # Hosted Windows needs ~23s for first-use PowerShell/module initialization in
    # an isolated profile (also covered by test-onboarding.ps1). This installer
    # harness allowance does not change any native quota or routing timeout.
    $rejected=Invoke-Hotpl8Process $ps @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$setup,'-Operation','install','-StateDirectory',$dir,'-SettingsPath',$settingsPath,'-IntegrationDirectory',$integration,'-CodexExecutable',$exe,'-TargetProviderId','hotpl8-codex','-MakeDefault','-TextGenerationModel','unmapped') 45000
    Assert ($rejected.exitCode -ne 0 -and -not (Test-Path -LiteralPath $integration)) 'unknown helper model rejects setup before creating files'
    Assert ([IO.File]::ReadAllText($settingsPath) -ceq $beforeSettings) 'rejected helper configuration preserves all T3 settings'
    & $ps -NoProfile -ExecutionPolicy Bypass -File $setup -Operation install -StateDirectory $dir -SettingsPath $settingsPath -IntegrationDirectory $integration -CodexExecutable $exe -TargetProviderId hotpl8-codex -MakeDefault
    Assert ($LASTEXITCODE -eq 0) 'setup succeeds in isolated fixture'
    $installed=Read-Hotpl8Json $settingsPath
    Assert ($installed.providerInstances.codex.config.binaryPath -eq 'codex') 'active original provider not replaced'
    Assert ($installed.defaultModelSelection.instanceId -eq 'hotpl8-codex' -and $installed.defaultModelSelection.model -eq 'fixture-model') 'default routes new chats while preserving model'
    Assert ($installed.providerInstances.'hotpl8-codex'.config.homePath -eq $shared) 'new provider shares conversation home'
    Assert ($installed.textGenerationModelSelection.instanceId -eq 'hotpl8-codex' -and $installed.textGenerationModelSelection.model -eq 'fixture-model') 'implicit T3 helper default routes through a verified model'
    Assert ($installed.textGenerationModelSelection.options[0].value -eq 'low') 'helper default uses low reasoning'
    $launcher=Join-Path $integration 'hotpl8-codex.exe'
    Assert ((& $launcher --version) -eq 'codex-cli fixture') 'native launcher version/stdio passthrough'
    # Instrument only this disposable installed reader to signal actual lock
    # contention. Delegation still calls the unchanged native reader; waiting on
    # process startup alone can miss the race on a cold or loaded Windows runner.
    $fixtureConfig=Read-Hotpl8Json (Join-Path $integration 'bridge-config.json')
    $readerPath=Join-Path (Split-Path $fixtureConfig.script -Parent) 'providers/codex.ps1'
    $readerProbe=@'

$script:FixtureNativeReader=${function:Read-CodexQuota}
function Read-CodexQuota([string]$AccountHome,[string]$Executable,[int]$TimeoutMs=5000,[string]$WorkingDirectory,[switch]$IncludeAccessToken,[switch]$RefreshToken){
    $read=& $script:FixtureNativeReader @PSBoundParameters
    if($read.status -eq 'home_busy'){[IO.File]::WriteAllText((Join-Path $AccountHome 'quota-contended'),'fixture')}
    return $read
}
'@
    [IO.File]::AppendAllText($readerPath,$readerProbe)
    # Hold the title helper's native quota read while a new app-server validates
    # the same healthy home. This is T3's concurrent first-message launch shape.
    $gate=Join-Path $dir 'b/quota-gate';[IO.File]::WriteAllText($gate,'fixture')
    $env:HOTPL8_TEST_LAUNCH=Join-Path $dir 'title.json'
    $titlePsi=New-CodexProcessInfo $launcher $shared @('exec','--model','fixture-model','-s','read-only','-') $dir
    $titlePsi.RedirectStandardInput=$true;$titlePsi.RedirectStandardOutput=$true;$titlePsi.RedirectStandardError=$true;$titlePsi.CreateNoWindow=$true
    $titleProc=Start-CodexQuotaProcess $titlePsi
    $null=$titleProc.StandardOutput.ReadToEndAsync();$null=$titleProc.StandardError.ReadToEndAsync()
    $titleProc.StandardInput.Write('fixture title');$titleProc.StandardInput.Close()
    $gateClock=[Diagnostics.Stopwatch]::StartNew()
    while(-not (Test-Path -LiteralPath (Join-Path $dir 'b/quota-entered')) -and $gateClock.ElapsedMilliseconds -lt 15000){Start-Sleep -Milliseconds 20}
    Assert (Test-Path -LiteralPath (Join-Path $dir 'b/quota-entered')) 'title broker owns the native home lock before chat startup'
    $psi=New-CodexProcessInfo $launcher $shared @('app-server') $dir
    $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
    $proc=Start-CodexQuotaProcess $psi
    $null=$proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.WriteLine('{"id":1,"method":"initialize","params":{"clientInfo":{"name":"fixture","version":"1"}}}');$proc.StandardInput.Flush()
    $initialization=$proc.StandardOutput.ReadLineAsync()
    $contentionClock=[Diagnostics.Stopwatch]::StartNew()
    while(-not (Test-Path -LiteralPath (Join-Path $dir 'b/quota-contended')) -and -not $initialization.IsCompleted -and $contentionClock.ElapsedMilliseconds -lt 5000){Start-Sleep -Milliseconds 10}
    [IO.File]::Delete($gate)
    Assert (Test-Path -LiteralPath (Join-Path $dir 'b/quota-contended')) 'chat native validation encounters the title helper lock'
    Assert ($initialization.Wait(15000)) 'concurrent chat startup responds within its deadline'
    $initialized=$initialization.Result|ConvertFrom-Json
    Assert ($initialized.id -eq 1 -and -not $initialized.error) 'chat startup survives concurrent title admission'
    Assert ($titleProc.WaitForExit(15000) -and $titleProc.ExitCode -eq 7) 'concurrent title helper retains native exit status'
    Assert ((Read-Hotpl8Json $env:HOTPL8_TEST_LAUNCH).input -eq 'fixture title' -and [IO.File]::ReadAllLines($env:HOTPL8_TEST_LAUNCH+'.runs').Count -eq 1) 'title input is submitted exactly once'
    Stop-Hotpl8Process $titleProc;$titleProc=$null
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $null=Invoke-CodexRpc $proc $clock 20000 2 'thread/start' @{model='fixture-model';cwd=$dir}
    [IO.File]::WriteAllText((Join-Path $shared 'keep-active'),'fixture')
    $turn=Invoke-CodexRpc $proc $clock 20000 3 'turn/start' @{threadId='thread-fixture';model='fixture-model';input=@()}
    Assert ($turn.account -eq 'b') 'real launcher/proxy/broker chooses healthy account for turn'
    # Collector-style atomic publication wakes the installed bridge. Neither a
    # user turn nor a new process is required for native login to change.
    [IO.File]::Delete((Join-Path $dir 'a/exhausted'))
    [IO.File]::WriteAllText((Join-Path $dir 'b/used-percent'),'96')
    $status.recommendations.codex='a';Save 'status.json' @{providers=@{codex=$status}}
    $rolled=$false;$rollClock=[Diagnostics.Stopwatch]::StartNew();$rpcId=40
    while($rollClock.ElapsedMilliseconds -lt 20000){
        $readClock=[Diagnostics.Stopwatch]::StartNew()
        $current=Invoke-CodexRpc $proc $readClock 2000 (++$rpcId) 'account/read' @{}
        if($current.account.email -eq 'a@example.invalid'){$rolled=$true;break}
        Start-Sleep -Milliseconds 50
    }
    Assert $rolled 'collector publication rebinds ongoing installed native process'
    $followClock=[Diagnostics.Stopwatch]::StartNew()
    $follow=Invoke-CodexRpc $proc $followClock 5000 (++$rpcId) 'turn/start' @{threadId='thread-fixture';model='fixture-model';input=@(@{type='text';text='fixture followup'})}
    Assert ($follow.account -eq 'a' -and $follow.turn.id -eq $turn.turn.id -and $follow.toolExecutions -eq 1) 'followup keeps active turn and executed effects after rollover'
    [IO.File]::Delete((Join-Path $dir 'b/used-percent'))
    [IO.File]::WriteAllText((Join-Path $dir 'a/exhausted'),'1')
    Stop-Hotpl8Process $proc;$proc=$null
    $env:HOTPL8_TEST_LAUNCH=Join-Path $dir 'exec.json'
    $execPsi=New-CodexProcessInfo $launcher $shared @('exec','--model','fixture-model','-s','read-only','--output-last-message','space & % fixture.json','-') $dir
    $execPsi.RedirectStandardInput=$true;$execPsi.RedirectStandardOutput=$true;$execPsi.RedirectStandardError=$true;$execPsi.CreateNoWindow=$true
    $proc=Start-CodexQuotaProcess $execPsi;$proc.StandardInput.Write('fixture prompt');$proc.StandardInput.Close();$proc.WaitForExit()
    Assert ($proc.ExitCode -eq 7) 'exec native exit code propagated'
    $trace=Read-Hotpl8Json $env:HOTPL8_TEST_LAUNCH
    Assert ($trace.home -eq (Join-Path $dir 'b') -and $trace.input -eq 'fixture prompt' -and $trace.args[6] -eq 'space & % fixture.json') 'exec home, stdin and argument boundaries preserved'
    Stop-Hotpl8Process $proc;$proc=$null
    Assert ([IO.File]::ReadAllText((Join-Path $shared 'auth.json')) -eq 'original-auth-sentinel') 'shared native auth unchanged'
    Assert ([IO.File]::ReadAllText((Join-Path $shared 'config.toml')) -eq 'original-config-sentinel') 'shared native config unchanged'
    # A lock that never clears is distinct from quota exhaustion and leaves only
    # a fixed failure code in the existing bounded diagnostic log.
    $lockPath=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-codex-'+(Get-Hotpl8Hash ([IO.Path]::GetFullPath((Join-Path $dir 'b')).ToLowerInvariant()))+'.lock')
    $accountLock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')
    $brokerPsi=New-CodexProcessInfo $ps $shared @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'src/codex-route.ps1'),'-StateDirectory',$dir,'-Executable',$exe) $dir
    $brokerPsi.RedirectStandardInput=$true;$brokerPsi.RedirectStandardOutput=$true;$brokerPsi.RedirectStandardError=$true;$brokerPsi.CreateNoWindow=$true
    $proc=Start-CodexQuotaProcess $brokerPsi
    $brokerOutput=$proc.StandardOutput.ReadToEndAsync();$null=$proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.WriteLine(($request|ConvertTo-Json -Compress));$proc.StandardInput.Close()
    Assert ($proc.WaitForExit(15000)) 'persistent contention returns a bounded broker failure'
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
    Assert (-not $one.providerInstances.codex.displayName -and $one.textGenerationModelSelection.instanceId -eq 'codex' -and $one.textGenerationModelSelection.model -eq 'fixture-model') 'normal provider label and verified helper model retained'
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
