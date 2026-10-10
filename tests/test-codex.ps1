$root = Split-Path $PSScriptRoot -Parent
# Offline acceptance tests. No live accounts or OpenAI requests.
$ErrorActionPreference = 'Stop'
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/config.ps1')
. (Join-Path $root 'src/providers/codex.ps1')
. (Join-Path $root 'src/native.ps1')
$script:passed = 0; $script:failed = 0
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; 'PASS ' + $Name }
    catch { $script:failed++; 'FAIL ' + $Name + ': ' + $_.Exception.Message }
}
function Assert($Value, [string]$Message = 'assertion failed') { if (-not $Value) { throw $Message } }
function Copy-Value($Value) { return $Value | ConvertTo-Json -Depth 24 | ConvertFrom-Json }
$now = [datetimeoffset]::UtcNow
# An account as a collection leaves it: one weekly window, a tenth used, an hour to its reset.
function Make-Slot([string]$Id) {
    $week = [pscustomobject]@{ usedPercent = 10; remainingPercent = 90; resetsAt = $now.ToUnixTimeSeconds() + 3600; anchorState = 'observed-active'; observedAt = $now.ToString('o') }
    $b = [pscustomobject]@{ codex = [pscustomobject]@{ meter = 'codex'; status = 'observed'; blockReason = $null; windows = [pscustomobject]@{ '10080' = $week }; warm = 'not applicable: no five-hour window' } }
    return [pscustomobject]@{ id = $Id; label = $Id; status = 'ok'; observedAt = $now.ToString('o'); buckets = $b; defaultModel = 'fixture-model'; modelProvider = 'openai' }
}
$dir = Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
$oldScenario = $env:HOTPL8_TEST_SCENARIO; $oldLaunch = $env:HOTPL8_TEST_LAUNCH
$clearedEnv = @{}
foreach ($key in @('OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','CODEX_SQLITE_HOME','OPENAI_BASE_URL')) { $clearedEnv[$key] = [Environment]::GetEnvironmentVariable($key); [Environment]::SetEnvironmentVariable($key,$null) }
try {
    $homeA = Join-Path $dir 'home A'; $homeB = Join-Path $dir 'home B'
    New-Item -ItemType Directory -Path $homeA,$homeB | Out-Null
    $policy = Copy-Value @{ slots = @(@{ id='a'; home=$homeA },@{ id='b'; home=$homeB }); prefer=@('a','b'); reserve=@(); order='soonest-reset'; margin5h=25; margin7d=20; margin7dWork=5; defaultMeter='codex'; modelMeters=@{ 'fixture-model'='codex' } }
    Check 'invalid duplicate homes rejected' { $p=Copy-Value $policy; $p.slots[1].home=$homeA; $threw=$false; try { Assert-CodexPolicy $p } catch { $threw=$true }; Assert $threw }
    Check 'invalid policy margins rejected' { $p=Copy-Value $policy; $p.margin5h='25'; $threw=$false; try { Assert-CodexPolicy $p } catch { $threw=$true }; Assert $threw }
    Check 'atomic replacement works repeatedly' { $path=Join-Path $dir 'atomic.txt'; Write-Hotpl8Text $path 'one'; Write-Hotpl8Text $path 'two'; Assert ([IO.File]::ReadAllText($path) -eq 'two') }
    Check 'locked file retains complete snapshot' { $path=Join-Path $dir 'locked.txt'; Write-Hotpl8Text $path 'old'; $lock=[IO.File]::Open($path,'Open','Read','None'); try { try { Write-Hotpl8Text $path 'new' } catch { } } finally { $lock.Dispose() }; Assert ([IO.File]::ReadAllText($path) -eq 'old') }
    $fake = Join-Path $dir 'fake codex.exe'
    Add-Type -Path (Join-Path $root 'tests/fake-codex.cs') -ReferencedAssemblies System.Web.Extensions -OutputAssembly $fake -OutputType ConsoleApplication
    # Diagnose the offline executable before interpreting transport failures as
    # product regressions. Only synthetic fixture stderr is safe to expose here.
    $smokeInfo=New-CodexProcessInfo $fake $homeA @('app-server') $dir
    $smokeInfo.RedirectStandardInput=$true;$smokeInfo.RedirectStandardOutput=$true;$smokeInfo.RedirectStandardError=$true
    $smokeInfo.CreateNoWindow=$true
    $smokeInfo.EnvironmentVariables['HOTPL8_TEST_SCENARIO']='ok'
    $smoke=$null
    try{
        $smoke=Start-CodexQuotaProcess $smokeInfo
        $smokeOut=$smoke.StandardOutput.ReadToEndAsync();$smokeError=$smoke.StandardError.ReadToEndAsync()
        $smoke.StandardInput.WriteLine('{"id":1,"method":"initialize"}');$smoke.StandardInput.Close()
        if(-not $smoke.WaitForExit(10000)){throw 'Offline fixture startup timed out.'}
        if($smoke.ExitCode -ne 0){throw ('Offline fixture startup failed ('+$smoke.ExitCode+'): '+$smokeError.Result)}
        Assert (($smokeOut.Result|ConvertFrom-Json).id -eq 1) 'Offline fixture produced no initialization response.'
    }finally{Stop-Hotpl8Process $smoke}
    Check 'UTF-8 console cannot add a pipe BOM to a question, and a home outside ASCII or longer than 200 characters is read' {
        $original=[Console]::InputEncoding
        $unicodeHome=Join-Path $dir ('home-'+[char]0x00e9)
        $longHome=Join-Path $dir ('h'*(239-$dir.Length))
        [void][IO.Directory]::CreateDirectory($unicodeHome);[void][IO.Directory]::CreateDirectory($longHome)
        try{
            [Console]::InputEncoding=[Text.Encoding]::UTF8
            $env:HOTPL8_TEST_SCENARIO='ok'
            $r=Read-CodexQuota $homeA $fake 5000
            Assert ($r.status -eq 'ok') $r.status
            $r=Read-CodexQuota $unicodeHome $fake 5000
            Assert ($r.status -eq 'ok') $r.status
            Assert ($longHome.Length -eq 240) $longHome.Length
            $r=Read-CodexQuota $longHome $fake 5000
            Assert ($r.status -eq 'ok') $r.status
            $r=Read-CodexQuota ($unicodeHome+'-absent') $fake 5000
            Assert ($r.status -eq 'home_missing') $r.status
            Assert ([Console]::InputEncoding.GetPreamble().Length -eq 3) 'Console encoding was not restored.'
        }finally{[Console]::InputEncoding=$original}
    }
    foreach ($scenario in @('ok','notify','stderr')) {
        $env:HOTPL8_TEST_SCENARIO=$scenario
        Check ('native transport '+$scenario) { $r=Read-CodexQuota $homeA $fake 3000; Assert ($r.status -eq 'ok') $r.status; Assert ($r.model -eq 'fixture-model'); Assert (-not ($r | ConvertTo-Json -Depth 12).Contains('@example.invalid')) }
    }
    foreach ($pair in @(@('noauth','subscription_login_required'),@('401','authentication_required'),@('403','access_denied'),@('429','rate_limited'),@('invalid','invalid_json'),@('exit','process_exited'),@('hang','timeout'),@('partial','timeout'))) {
        $env:HOTPL8_TEST_SCENARIO=$pair[0]
        Check ('transport failure '+$pair[0]) {
            # Error classification needs time to start the fixture on a busy host.
            # Only deliberately stalled processes test the short timeout contract.
            $budget=if($pair[1] -eq 'timeout'){500}else{3000}
            $r=Read-CodexQuota $homeA $fake $budget
            Assert ($r.status -eq $pair[1]) $r.status
            Assert ($r.elapsedMs -lt ($budget+2000))
            Assert (-not ($r | ConvertTo-Json).Contains('SECRET_DO_NOT_LOG'))
        }
    }
    $env:HOTPL8_TEST_SCENARIO='ok'
    # One wake of the collector over the policy's two homes, the stand-in answering as the
    # scenario says: what the wake published for Codex.
    function Wake([string]$Directory,[string]$Scenario='ok') {
        Write-Hotpl8Text (Join-Path $Directory 'policy.json') (@{codex=$policy}|ConvertTo-Json -Depth 12)
        $env:HOTPL8_TEST_SCENARIO=$Scenario
        try { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tick.ps1') -StateDirectory $Directory -CswapExecutable (Join-Path $dir 'absent.exe') -CodexExecutable $fake | Out-Null }
        finally { $env:HOTPL8_TEST_SCENARIO='ok' }
        return (Read-Hotpl8Json (Join-Path $Directory 'status.json')).providers.codex
    }
    Check 'a wake reads two independent configured homes' {
        $c=Wake $dir
        Assert ($c.slots.Count -eq 2); Assert ($c.recommendedSlot -eq 'a')
        Assert (-not ([IO.File]::ReadAllText((Join-Path $dir 'status.json'))).Contains('identityKey'))
    }
    Check 'last-good snapshot keeps its age on read failure, and the refusal is not written down' {
        # A directory of its own: a wake that could read no account is not due again for minutes.
        $refused=Join-Path $dir 'refused';New-Item -ItemType Directory $refused|Out-Null
        $null=Wake $refused
        $first=Read-Hotpl8Json (Join-Path $refused 'codex-state.json')
        $c=Wake $refused '401'
        $a=$c.slots | Where-Object id -EQ a
        Assert ($a.status -eq 'authentication_required') ('a '+$a.status)
        Assert ($a.observedAt -eq $first.slots.a.lastSuccessAt) ('age changed: ' + $a.observedAt + ' vs ' + $first.slots.a.lastSuccessAt)
        Assert ($null -eq $c.recommendedSlot) ('recommended ' + $c.recommendedSlot)
        foreach($file in @(Get-ChildItem -LiteralPath $refused -File | Where-Object Extension -In '.json','.jsonl','.js','.txt','.log')) {
            Assert (-not ([IO.File]::ReadAllText($file.FullName)).Contains('SECRET_DO_NOT_LOG')) $file.Name
        }
    }
    $status=[pscustomobject]@{observedAt=$now.ToString('o');recommendations=[pscustomobject]@{codex='a'};slots=@((Make-Slot a),(Make-Slot b))}
    Check 'pure Codex hook is bounded and does not collect' {
        $payload=@{ generatedAt=$now.ToString('o'); active=0; slots=@(); providers=@{ codex=$status } }
        Write-Hotpl8Text (Join-Path $dir 'policy.json') (@{codex=$policy}|ConvertTo-Json -Depth 12)
        Write-Hotpl8Text (Join-Path $dir 'status.json') ($payload|ConvertTo-Json -Depth 24)
        $env:HOTPL8_SLOT='a'; $env:HOTPL8_METER='codex'; $env:HOTPL8_STATE_DIRECTORY=$dir
        $out=& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'status-print.ps1') -Provider codex -StateDirectory $dir
        $obj=$out|ConvertFrom-Json
        Assert ($obj.hookSpecificOutput.hookEventName -eq 'SessionStart'); Assert ($out.Length -lt 4000)
        $savedHome=$env:CODEX_HOME
        try {
            $env:HOTPL8_SLOT=$null; $env:HOTPL8_METER=$null; $env:CODEX_HOME=$homeA
            $direct=& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'status-print.ps1') -Provider codex -StateDirectory $dir
            $directObj=$direct|ConvertFrom-Json
            Assert ($directObj.hookSpecificOutput.additionalContext.Contains('"boundSlot":"a"'))
        } finally { $env:CODEX_HOME=$savedHome }
        $env:HOTPL8_SLOT=$null; $env:HOTPL8_METER=$null; $env:HOTPL8_STATE_DIRECTORY=$null
    }
    Check 'real tick publishes Codex without cswap' {
        $p=@{codex=$policy}; Write-Hotpl8Text (Join-Path $dir 'policy.json') ($p|ConvertTo-Json -Depth 12)
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tick.ps1') -StateDirectory $dir -CswapExecutable (Join-Path $dir 'absent.exe') -CodexExecutable $fake
        $actual=Read-Hotpl8Json (Join-Path $dir 'status.json')
        Assert ($actual.providers.codex.slots.Count -eq 2); Assert ($actual.schemaVersion -eq 2); Assert ($actual.slots.Count -eq 0)
        Assert ($actual.providers.codex.recommendedSlot -eq 'a') 'the accounts were not read'
        Assert (([IO.File]::ReadAllText((Join-Path $dir 'status.js'))).StartsWith('window.CSWAP = '))
    }
    Check 'per-home lock prevents overlapping native readers' {
        $lockPath=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-codex-'+(Get-Hotpl8Hash ([IO.Path]::GetFullPath($homeA).ToLowerInvariant()))+'.lock')
        $lock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')
        try { $r=Read-CodexQuota $homeA $fake 1000;Assert ($r.status -eq 'home_busy') } finally { $lock.Dispose() }
    }
    Check 'a wake waits for a home another reader holds' {
        # The compiled collector and the readers still in PowerShell keep to one lock for a home.
        $waitDir=Join-Path $dir 'lock-wait';New-Item -ItemType Directory $waitDir|Out-Null
        Write-Hotpl8Text (Join-Path $waitDir 'policy.json') (@{codex=$policy}|ConvertTo-Json -Depth 12)
        $lockPath=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-codex-'+(Get-Hotpl8Hash ([IO.Path]::GetFullPath($homeA).ToLowerInvariant()))+'.lock')
        $lock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None');$wake=$null
        try {
            $words='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $root 'tick.ps1')+'" -StateDirectory "'+$waitDir+'" -CswapExecutable "'+(Join-Path $dir 'absent.exe')+'" -CodexExecutable "'+$fake+'"'
            $wake=Start-Process -FilePath powershell -ArgumentList $words -WindowStyle Hidden -PassThru
            # Longer than a wake that did not wait would have taken.
            Assert (-not $wake.WaitForExit(3000)) 'the wake did not wait for the home'
        } finally { $lock.Dispose() }
        Assert ($wake.WaitForExit(30000)) 'the wake did not finish'
        $c=(Read-Hotpl8Json (Join-Path $waitDir 'status.json')).providers.codex
        foreach($s in $c.slots){Assert ($s.status -eq 'ok') ($s.id+' '+$s.status)}
    }
    Check 'setup preserves Claude policy and unrelated hooks; repeat is idempotent' {
        $configDir=Join-Path $dir 'setup';New-Item -ItemType Directory $configDir|Out-Null
        Write-Hotpl8Text (Join-Path $configDir 'policy.json') '{"prefer":[3,2,1],"warm":true}'
        Write-Hotpl8Text (Join-Path $homeA 'hooks.json') '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo existing"}]}]}}'
        $setupArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'setup-codex.ps1'),'-Slot','a','-AccountHome',$homeA,'-StateDirectory',$configDir,'-CodexExecutable',$fake,'-Model','fixture-model','-InstallHook')
        & powershell @setupArgs | Out-Null;Assert ($LASTEXITCODE -eq 0)
        & powershell @setupArgs | Out-Null;Assert ($LASTEXITCODE -eq 0)
        $p=Read-Hotpl8Json (Join-Path $configDir 'policy.json');$h=Read-Hotpl8Json (Join-Path $homeA 'hooks.json')
        Assert (-not $p.codex.PSObject.Properties['modelMeters']) 'legacy setup -Model creates no model registry'
        Assert ($p.prefer.Count -eq 3);Assert $p.warm;Assert ($p.codex.slots.Count -eq 1);Assert ($h.hooks.Stop[0].hooks[0].command -eq 'echo existing');Assert ($h.hooks.SessionStart.Count -eq 1);Assert ([IO.File]::ReadAllBytes((Join-Path $homeA 'hooks.json'))[0] -eq 123)
    }
    Check 'the session hook names PowerShell by its whole path, and a hook of before is given that text' {
        $configDir=Join-Path $dir 'setup';$hookFile=Join-Path $homeA 'hooks.json'
        $words=' -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $root 'status-print.ps1')+'" -Provider codex -StateDirectory "'+$configDir+'"'
        $whole=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')+$words
        $own=@((Read-Hotpl8Json $hookFile).hooks.SessionStart[0].hooks)
        Assert ($own.Count -eq 1 -and $own[0].command -ceq $whole) ('registered: '+$own[0].command)
        # Codex starts the text as a command line, and a bare name in one is looked for in the
        # current directory first. A hook of before is given today's text where it stands;
        # one for another state directory is someone else's and is left.
        $before='powershell'+$words;$other=$before.Replace($configDir,(Join-Path $dir 'another state'))
        Write-Hotpl8Text $hookFile (@{hooks=@{SessionStart=@(@{matcher='startup';hooks=@(@{type='command';command='echo first'},@{type='command';command=$before;timeout=2},@{type='command';command=$other})})}}|ConvertTo-Json -Depth 8) -NoBom
        $setupArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'setup-codex.ps1'),'-Slot','a','-AccountHome',$homeA,'-StateDirectory',$configDir,'-CodexExecutable',$fake,'-InstallHook')
        foreach($time in 1,2){
            & powershell @setupArgs | Out-Null;Assert ($LASTEXITCODE -eq 0)
            $after=Read-Hotpl8Json $hookFile
            Assert ($after.hooks.SessionStart.Count -eq 1 -and (@($after.hooks.SessionStart[0].hooks|ForEach-Object{$_.command}) -join "`n") -ceq (@('echo first',$whole,$other) -join "`n")) ('run '+$time+': '+(@($after.hooks.SessionStart[0].hooks|ForEach-Object{$_.command}) -join ' ; '))
            Assert ($after.hooks.SessionStart[0].hooks[1].timeout -eq 2 -and $after.hooks.SessionStart[0].matcher -ceq 'startup')
        }
        # A folder whose name a command line reads as more than a name is refused before
        # either file is written.
        $odd=Join-Path $dir '100% state';New-Item -ItemType Directory $odd|Out-Null
        Copy-Item -LiteralPath (Join-Path $configDir 'policy.json') -Destination (Join-Path $odd 'policy.json')
        $hookHash=(Get-FileHash -LiteralPath $hookFile).Hash;$policyHash=(Get-FileHash -LiteralPath (Join-Path $odd 'policy.json')).Hash
        $oddArgs=@($setupArgs|ForEach-Object{if($_ -ceq $configDir){$odd}else{$_}})
        $ended=Invoke-Hotpl8NativeProcess 'powershell.exe' $oddArgs
        Assert ($ended.exitCode -ne 0 -and $ended.errors.Contains('The hook cannot name this folder safely')) ([string]$ended.exitCode+' '+$ended.errors)
        Assert ((Get-FileHash -LiteralPath $hookFile).Hash -eq $hookHash -and (Get-FileHash -LiteralPath (Join-Path $odd 'policy.json')).Hash -eq $policyHash -and -not (Test-Path -LiteralPath (Join-Path $odd 'policy.previous.json')))
        foreach($name in 'a"b','a`b','a$b','a%b',("a`nb")){
            $refused=$false;try{$null=Get-Hotpl8CodexHookCommand (Join-Path $root 'status-print.ps1') 'codex' (Join-Path $dir $name)}catch{$refused=$true}
            Assert $refused ('named: '+$name)
        }
        # Names people do have are not refused.
        foreach($name in ('Jos'+[char]0xe9),'Program Files (x86)','a&b^c',"it's"){$null=Get-Hotpl8CodexHookCommand (Join-Path $root 'status-print.ps1') 'codex' (Join-Path $dir $name)}
        # The hook is not written from an environment that does not say where Windows is.
        $keep=$env:SystemRoot
        try{
            foreach($value in '','Windows','\Windows','C:Windows'){
                $env:SystemRoot=$value;$refused=$false
                try{$null=Get-Hotpl8CodexHookCommand (Join-Path $root 'status-print.ps1') 'codex' $configDir}catch{$refused=$true}
                Assert $refused ('SystemRoot: '+$value)
            }
        }finally{$env:SystemRoot=$keep}
    }
    Check 'enroll command validates the native home and preserves monitoring on repeat' {
        $enrollment=Join-Path $dir 'cli enrollment';New-Item -ItemType Directory $enrollment|Out-Null
        $monitor=Read-Hotpl8Json (Join-Path $root 'policy.example.json');$monitor.mode='monitor'
        Write-Hotpl8Text (Join-Path $enrollment 'policy.json') ($monitor|ConvertTo-Json -Depth 24)
        $arguments=@('enroll','-Slot','main','-AccountHome',$homeA,'-Label','Everyday','-StateDirectory',$enrollment,'-CodexExecutable',$fake)
        foreach($attempt in 1..2){
            $out=& (Join-Path $root 'hotpl8.cmd') @arguments
            Assert ($LASTEXITCODE -eq 0) ($out -join ' ')
            Assert (($out -join ' ').Contains('Next: hotpl8 refresh'))
        }
        $saved=Read-Hotpl8Json (Join-Path $enrollment 'policy.json')
        Assert ($saved.codex.slots.Count -eq 1 -and $saved.codex.slots[0].home -eq $homeA)
        Assert ($saved.codex.slots[0].label -eq 'Everyday' -and $saved.mode -eq 'monitor' -and -not $saved.warm)
        Assert (-not (Test-Path (Join-Path $enrollment 'auth.json')))
    }
    # A launch is the compiled program's, and its rules are tested where they are held
    # (native/src/launch.rs). These start one as a session does, against the stand-in, and
    # read how it ended and what the stand-in recorded of its start.
    function Launch([string[]]$Words) {
        $env:HOTPL8_TEST_LAUNCH=Join-Path $dir ('launch-'+[guid]::NewGuid().ToString('N')+'.json')
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'hotpl8.ps1'),'codex','-StateDirectory',$dir,'-CodexExecutable',$fake)+$Words
        $ended=Invoke-Hotpl8NativeProcess 'powershell.exe' $arguments
        $record=if(Test-Path -LiteralPath $env:HOTPL8_TEST_LAUNCH){Read-Hotpl8Json $env:HOTPL8_TEST_LAUNCH}else{$null}
        return [pscustomobject]@{exitCode=$ended.exitCode;errors=$ended.errors.Trim();record=$record}
    }
    Check 'automatic native launch rechecks the real binding' {
        # The launcher reads the record the collector kept of the account it read.
        $c=Wake $dir
        $l=Launch @('test')
        Assert ($l.exitCode -eq 7) $l.errors
        Assert ($l.record.home -eq $homeA -and $l.record.slot -eq 'a' -and ($l.record.args -join '|') -eq 'test')
    }
    Check 'native argument quoting and child home preserved' {
        $env:HOTPL8_TEST_LAUNCH=Join-Path $dir 'launch.json'
        $argsToTest=@('a b','a"b','C:\ends with slash\','', '$literal', 'x&y', 'semi;colon', 'Unicode: Ω中')
        $original=$env:CODEX_HOME
        # A session that has moved: its location is no longer the directory of its process.
        Push-Location -LiteralPath $homeA
        try { & (Join-Path $root 'hotpl8.ps1') codex -Slot b -Model future-model -StateDirectory $dir -CodexExecutable $fake @argsToTest }
        finally { Pop-Location }
        $code=$LASTEXITCODE
        $record=Read-Hotpl8Json $env:HOTPL8_TEST_LAUNCH
        Assert ($code -eq 7); Assert ($record.home -eq $homeB); Assert ($record.slot -eq 'b'); Assert ($record.cwd -eq $homeA); Assert ($env:CODEX_HOME -eq $original)
        $expected=@('--model','future-model')+$argsToTest
        $actual=@($record.args)
        Assert ($actual.Count -eq $expected.Count) ('argument count '+$actual.Count)
        for ($i=0; $i -lt $actual.Count; $i++) { Assert ($actual[$i] -ceq $expected[$i]) ('argument '+$i) }
    }
    Check 'a launch with no words gives Codex none' {
        $l=Launch @('-Slot','a')
        Assert ($l.exitCode -eq 7 -and $l.record.home -eq $homeA -and @($l.record.args).Count -eq 0) $l.errors
    }
    Check 'Windows command shim launches the selected home and preserves exit code' {
        $env:HOTPL8_TEST_LAUNCH=Join-Path $dir 'cmd-launch.json'
        & (Join-Path $root 'hotpl8.cmd') codex -Slot a -StateDirectory $dir -CodexExecutable $fake exec --json 'fixture prompt'
        Assert ($LASTEXITCODE -eq 7)
        $record=Read-Hotpl8Json $env:HOTPL8_TEST_LAUNCH
        Assert ($record.home -eq $homeA); Assert ($record.cwd -eq (Get-Location).Path)
        Assert (($record.args -join '|') -eq 'exec|--json|fixture prompt')
    }
    Check 'a launch that is refused says why and starts nothing' {
        $l=Launch @('-Slot','a','exec','--remote=ws://other')
        Assert ($l.exitCode -eq 1 -and -not $l.record)
        Assert ($l.errors -ceq 'HotPl8: Use HotPl8 -Model for model selection. Config/profile/auth/workdir overrides require native Codex directly; they cannot be verified against a subscription recommendation.') $l.errors
        $l=Launch @('resume','abc')
        Assert ($l.exitCode -eq 1 -and -not $l.record)
        Assert ($l.errors -ceq 'HotPl8: Resume/fork requires -Slot naming the home that owns the conversation.') $l.errors
        $l=Launch @('-Slot','b','resume','abc')
        Assert ($l.exitCode -eq 7 -and $l.record.home -eq $homeB -and ($l.record.args -join '|') -eq 'resume|abc') $l.errors
        # An option of another command is refused as it always was, by the entry.
        $l=Launch @('-Slot','a','-Label','x')
        Assert ($l.exitCode -eq 1 -and -not $l.record)
        Assert ($l.errors -ceq 'HotPl8: -AccountHome and -Label are enrollment options. Use hotpl8 enroll.') $l.errors
    }
    Check 'API auth override detected without printing secret' {
        $env:OPENAI_API_KEY='SECRET_DO_NOT_LOG'
        try { $l=Launch @('-Slot','a','test') } finally { $env:OPENAI_API_KEY=$null }
        Assert ($l.exitCode -eq 1 -and -not $l.record)
        Assert ($l.errors -ceq 'HotPl8: Conflicting environment setting: OPENAI_API_KEY. Use native Codex directly for an explicitly different authentication mode.') $l.errors
    }
    Check 'binding changed since collection prevents automatic dispatch' {
        $c=Wake $dir
        $path=Join-Path $dir 'codex-state.json'
        $state=Read-Hotpl8Json $path;$state.slots.a.identityKey='different'
        Write-Hotpl8Text $path ($state|ConvertTo-Json -Depth 24)
        $l=Launch @('test')
        Assert ($l.exitCode -eq 1 -and -not $l.record)
        Assert ($l.errors -ceq 'HotPl8: Account binding changed since collection. Refresh HotPl8 before automatic launch.') $l.errors
        # The account that is named is the user's own choice.
        $l=Launch @('-Slot','a','test')
        Assert ($l.exitCode -eq 7 -and $l.record.home -eq $homeA) $l.errors
    }
    Check 'quota observation history contains no private identity' {
        $history=Get-Content -LiteralPath (Join-Path $dir 'codex-observations.jsonl') -Raw -Encoding UTF8
        Assert ($history.Contains('observedAt'));Assert (-not $history.Contains('identityKey'));Assert (-not $history.Contains('@example.invalid'))
    }
    Check 'empty Codex section contributes nothing' {
        $empty=Join-Path $dir 'empty-section';New-Item -ItemType Directory $empty|Out-Null
        Write-Hotpl8Text (Join-Path $empty 'policy.json') '{"codex":{}}'
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tick.ps1') -StateDirectory $empty -CodexExecutable $fake
        Assert (-not (Test-Path -LiteralPath (Join-Path $empty 'status.json')))
    }
    Check 'PowerShell -File entrypoints resolve default state directory' {
        $entry=Join-Path $dir 'entry';New-Item -ItemType Directory -Path $entry|Out-Null
        Copy-Item (Join-Path $root 'src') $entry -Recurse
        foreach($name in @('hotpl8.ps1','setup-codex.ps1','VERSION')) {Copy-Item (Join-Path $root $name) $entry}
        # status is the compiled reader's, so a copy that answers it holds one.
        New-Item -ItemType Directory -Path (Join-Path $entry 'bin/windows')|Out-Null
        Copy-Item (Join-Path $root 'bin/windows/hotpl8-native.exe') (Join-Path $entry 'bin/windows')
        Write-Hotpl8Text (Join-Path $entry 'policy.json') '{"prefer":[3,2,1],"warm":true}'
        $output=& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $entry 'hotpl8.ps1') status
        Assert ($LASTEXITCODE -eq 0);Assert ($output -like '*No cached status*')
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $entry 'setup-codex.ps1') -Slot a -AccountHome $homeA -CodexExecutable $fake | Out-Null
        Assert ($LASTEXITCODE -eq 0);Assert ((Read-Hotpl8Json (Join-Path $entry 'policy.json')).codex.slots.Count -eq 1)
    }
    Check 'removing Codex configuration restores Claude-only operation' {
        $rollback=Join-Path $dir 'rollback';New-Item -ItemType Directory $rollback|Out-Null
        $stub=Join-Path $rollback 'cswap.cmd'
        [IO.File]::WriteAllText($stub,"@echo off`r`ntype `"%HOTPL8_TEST_CLAUDE_FIXTURE%`"`r`nexit /b 0`r`n")
        $env:HOTPL8_TEST_CLAUDE_FIXTURE=Join-Path $rollback 'claude.json'
        $u=@{pct=10;resetsAt=$now.AddHours(2).ToString('o')}
        $fixture=@{activeAccountNumber=1;accounts=@(@{number=1;active=$true;usageStatus='ok';usageAgeSeconds=0;usage=@{fiveHour=$u;sevenDay=$u}})}
        Write-Hotpl8Text $env:HOTPL8_TEST_CLAUDE_FIXTURE ($fixture|ConvertTo-Json -Depth 10)
        $p=[pscustomobject]@{prefer=@(1);margin5h=25;margin7d=20;hysteresis=10;warm=$false;codex=$policy}
        Write-Hotpl8Text (Join-Path $rollback 'policy.json') ($p|ConvertTo-Json -Depth 12)
        $tickArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'tick.ps1'),'-StateDirectory',$rollback,'-CswapExecutable',$stub,'-CodexExecutable',$fake)
        & powershell @tickArgs|Out-Null
        $before=Read-Hotpl8Json (Join-Path $rollback 'status.json');Assert ($before.providers.codex.slots.Count -eq 2)
        $historyHash=(Get-FileHash -LiteralPath (Join-Path $rollback 'codex-observations.jsonl')).Hash
        $p.PSObject.Properties.Remove('codex');Write-Hotpl8Text (Join-Path $rollback 'policy.json') ($p|ConvertTo-Json -Depth 12)
        & powershell @tickArgs|Out-Null
        $after=Read-Hotpl8Json (Join-Path $rollback 'status.json')
        Assert ($null -eq $after.providers);Assert ($after.active -eq $before.active);Assert ($after.slots[0].used5h -eq $before.slots[0].used5h)
        Assert ((Get-FileHash -LiteralPath (Join-Path $rollback 'codex-observations.jsonl')).Hash -eq $historyHash)
        $env:HOTPL8_TEST_CLAUDE_FIXTURE=$null
    }
    Check 'missing policy means no writes or process' { $empty=Join-Path $dir 'empty'; New-Item -ItemType Directory $empty|Out-Null; & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tick.ps1') -StateDirectory $empty -CodexExecutable $fake; Assert (@(Get-ChildItem -LiteralPath $empty).Count -eq 0) }
    Check 'tick lock prevents overlapping collection' {
        $before=(Get-FileHash -LiteralPath (Join-Path $dir 'status.json')).Hash
        $lock=[IO.File]::Open((Join-Path $dir 'tick.lock'),'OpenOrCreate','ReadWrite','None')
        try { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tick.ps1') -StateDirectory $dir -CodexExecutable $fake } finally { $lock.Dispose() }
        Assert ((Get-FileHash -LiteralPath (Join-Path $dir 'status.json')).Hash -eq $before)
    }
} finally {
    $env:HOTPL8_TEST_SCENARIO=$oldScenario; $env:HOTPL8_TEST_LAUNCH=$oldLaunch
    foreach ($key in $clearedEnv.Keys) { [Environment]::SetEnvironmentVariable($key,$clearedEnv[$key]) }
    $resolved=[IO.Path]::GetFullPath($dir)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $resolved -Leaf) -like 'hotpl8-test-*') { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
'passed=' + $script:passed + ' failed=' + $script:failed
if ($script:failed) { exit 1 }
