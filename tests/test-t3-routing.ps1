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
function Reject([scriptblock]$Body,[string]$Code){try{& $Body;throw 'accepted unexpectedly'}catch{Assert ($_.Exception.Message -eq $Code) ('expected '+$Code+', got '+$_.Exception.Message)}}
function Save($Name,$Value){Write-Hotpl8Text (Join-Path $dir $Name) ($Value|ConvertTo-Json -Depth 30)}
$savedEnv=@{}
foreach($key in @('OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','CODEX_SQLITE_HOME','OPENAI_BASE_URL','HOTPL8_TEST_LAUNCH')){$savedEnv[$key]=[Environment]::GetEnvironmentVariable($key);[Environment]::SetEnvironmentVariable($key,$null)}
$proc=$null
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
    [IO.File]::WriteAllText((Join-Path $dir 'a/exhausted'),'1')
    $route=Get-Hotpl8CodexRoute $request $dir $exe
    Assert ($route.slot -eq 'b') 'fresh native exhaustion falls back before inference'
    $refresh=[pscustomobject]@{operation='refresh';previousSlot='a';accountId='a';model='fixture-model';cwd=$dir}
    Assert ((Get-Hotpl8CodexRoute $refresh $dir $exe).slot -eq 'a') 'refresh remains pinned even when quota exhausted'
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
    $rejected=Invoke-Hotpl8Process $ps @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$setup,'-Operation','install','-StateDirectory',$dir,'-SettingsPath',$settingsPath,'-IntegrationDirectory',$integration,'-CodexExecutable',$exe,'-MakeDefault','-TextGenerationModel','unmapped') 45000
    Assert ($rejected.exitCode -ne 0 -and -not (Test-Path -LiteralPath $integration)) 'unknown helper model rejects setup before creating files'
    Assert ([IO.File]::ReadAllText($settingsPath) -ceq $beforeSettings) 'rejected helper configuration preserves all T3 settings'
    & $ps -NoProfile -ExecutionPolicy Bypass -File $setup -Operation install -StateDirectory $dir -SettingsPath $settingsPath -IntegrationDirectory $integration -CodexExecutable $exe -MakeDefault
    Assert ($LASTEXITCODE -eq 0) 'setup succeeds in isolated fixture'
    $installed=Read-Hotpl8Json $settingsPath
    Assert ($installed.providerInstances.codex.config.binaryPath -eq 'codex') 'active original provider not replaced'
    Assert ($installed.defaultModelSelection.instanceId -eq 'hotpl8-codex' -and $installed.defaultModelSelection.model -eq 'fixture-model') 'default routes new chats while preserving model'
    Assert ($installed.providerInstances.'hotpl8-codex'.config.homePath -eq $shared) 'new provider shares conversation home'
    Assert ($installed.textGenerationModelSelection.instanceId -eq 'hotpl8-codex' -and $installed.textGenerationModelSelection.model -eq 'fixture-model') 'implicit T3 helper default routes through a verified model'
    Assert ($installed.textGenerationModelSelection.options[0].value -eq 'low') 'helper default uses low reasoning'
    $launcher=Join-Path $integration 'hotpl8-codex.exe'
    Assert ((& $launcher --version) -eq 'codex-cli fixture') 'native launcher version/stdio passthrough'
    $psi=New-CodexProcessInfo $launcher $shared @('app-server') $dir
    $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
    $proc=Start-CodexQuotaProcess $psi
    $null=$proc.StandardError.ReadToEndAsync()
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $null=Invoke-CodexRpc $proc $clock 20000 1 'initialize' @{clientInfo=@{name='fixture';version='1'}}
    $null=Invoke-CodexRpc $proc $clock 20000 2 'thread/start' @{model='fixture-model';cwd=$dir}
    $turn=Invoke-CodexRpc $proc $clock 20000 3 'turn/start' @{threadId='thread-fixture';model='fixture-model';input=@()}
    Assert ($turn.account -eq 'b') 'real launcher/proxy/broker chooses healthy account for turn'
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
    & $ps -NoProfile -ExecutionPolicy Bypass -File $setup -Operation remove -StateDirectory $dir -SettingsPath $settingsPath -IntegrationDirectory $integration
    Assert ($LASTEXITCODE -eq 0) 'rollback succeeds'
    $restored=Read-Hotpl8Json $settingsPath
    Assert ($restored.providerInstances.codex.config.binaryPath -eq 'codex' -and $restored.unrelated -eq 'preserve') 'original provider restored, unrelated settings preserved'
    Assert ($restored.defaultModelSelection.instanceId -eq 'codex' -and -not $restored.providerInstances.PSObject.Properties['hotpl8-codex']) 'rollback removes only added instance and restores matching default'
    Assert (-not $restored.PSObject.Properties['textGenerationModelSelection']) 'rollback restores absent helper setting instead of leaving a removed provider reference'
    Write-Output ($passed.ToString()+' T3 broker/Windows integration checks passed.')
}finally{
    Stop-Hotpl8Process $proc
    foreach($key in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($key,$savedEnv[$key])}
    if([IO.Path]::GetFullPath($dir).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $dir -Leaf) -match '^hotpl8-t3-[a-f0-9]{32}$'){Remove-Item -LiteralPath $dir -Recurse -Force}
}
