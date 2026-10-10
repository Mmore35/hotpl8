$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/config.ps1')
. (Join-Path $root 'src/diagnostics.ps1')
. (Join-Path $root 'src/collection.ps1')
. (Join-Path $root 'src/providers/codex.ps1')
$script:passed=0;$script:failed=0
function Assert($Value){if(-not $Value){throw 'assertion failed'}}
function Check([string]$Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message}}
function Copy-Value($Value){$Value|ConvertTo-Json -Depth 24|ConvertFrom-Json}
$dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-safety-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
$savedFixture=$env:HOTPL8_SAFE_FIXTURE;$savedCalls=$env:HOTPL8_SAFE_CALLS;$savedState=$env:HOTPL8_STATE_DIRECTORY
try{
    $policy=Read-Hotpl8Json (Join-Path $root 'policy.example.json')
    Check 'new policy switches and continues by itself but never warms or probes' {
        Assert-Hotpl8Policy $policy
        $a=Get-Hotpl8Actions $policy $false
        Assert ($a.switching -and $a.continuing -and -not $a.warming -and -not $a.probing)
    }
    Check 'continue follows the mode and its own setting, which is true or false only' {
        $p=Copy-Value $policy
        Assert (-not (Get-Hotpl8Actions $p $true).continuing)
        $p.mode='monitor';$a=Get-Hotpl8Actions $p $false
        Assert (-not $a.continuing -and -not $a.switching -and -not $a.warming -and -not $a.probing)
        $p.mode='automate';$p.switchEnabled=$false
        Assert (Get-Hotpl8Actions $p $false).continuing
        $p.automation|Add-Member NoteProperty continue $false;Assert-Hotpl8Policy $p
        Assert (-not (Get-Hotpl8Actions $p $false).continuing)
        $p.automation.continue=$true;Assert-Hotpl8Policy $p
        Assert (Get-Hotpl8Actions $p $false).continuing
        $p.automation.continue='false';$threw=$false
        try{Assert-Hotpl8Policy $p}catch{$threw=$true}
        Assert $threw
    }
    Check 'legacy actions preserved while refresh overrides them' {
        $p=Copy-Value @{prefer=@(1);warm=$true}
        $a=Get-Hotpl8Actions $p $false
        Assert ($a.switching -and $a.warming -and $a.probing -and $a.continuing)
        $a=Get-Hotpl8Actions $p $true
        Assert (-not $a.switching -and -not $a.warming -and -not $a.probing -and -not $a.continuing)
    }
    Check 'invalid numeric, boolean, duplicate, and mode fields rejected' {
        foreach($entry in @(@('warm','false'),@('margin5h',101),@('maxUsageAgeS',-1),@('mode','monitr'),@('prefer',@(1,1)))){
            $p=Copy-Value $policy;$p.($entry[0])=$entry[1];$threw=$false
            try{Assert-Hotpl8Policy $p}catch{$threw=$true}
            Assert $threw
        }
    }
    Check 'explicit state outranks environment and installation binding' {
        $env:HOTPL8_STATE_DIRECTORY=Join-Path $dir 'environment'
        Write-Hotpl8Text (Join-Path $dir 'install-state.json') (@{stateDirectory=(Join-Path $dir 'installed')}|ConvertTo-Json)
        Assert ((Resolve-Hotpl8StateDirectory $dir $root) -eq $dir)
        Assert ((Resolve-Hotpl8StateDirectory '' $dir) -eq $env:HOTPL8_STATE_DIRECTORY)
        $env:HOTPL8_STATE_DIRECTORY=$null
        Assert ((Resolve-Hotpl8StateDirectory '' $dir) -eq (Join-Path $dir 'installed'))
    }
    $stub=Join-Path $dir 'fixture.cmd'
    $env:HOTPL8_SAFE_FIXTURE=Join-Path $dir 'fixture.json';$env:HOTPL8_SAFE_CALLS=Join-Path $dir 'calls.txt'
    [IO.File]::WriteAllText($stub,"@echo off`r`nif `"%~1`"==`"list`" (type `"%HOTPL8_SAFE_FIXTURE%`") else (echo %*>>`"%HOTPL8_SAFE_CALLS%`")`r`nexit /b 0`r`n")
    $now=[datetimeoffset]::UtcNow
    $p=Copy-Value @{prefer=@(2,1);reserve=@();mode='monitor';warm=$true;probeEnabled=$true;switchEnabled=$true;order='prefer';margin5h=25;margin7d=20;hysteresis=10;labels=@{'1'='Reserve';'2'='Work'}}
    $fixture=Copy-Value @{schemaVersion=1;activeAccountNumber=1;accounts=@(
        @{number=1;email='one@example.invalid';usageStatus='ok';usageAgeSeconds=0;usage=@{fiveHour=@{pct=90;resetsAt=$now.AddHours(1).ToString('o')};sevenDay=@{pct=20;resetsAt=$now.AddDays(1).ToString('o')}}},
        @{number=2;email='two@example.invalid';usageStatus='ok';usageAgeSeconds=0;usage=@{fiveHour=@{pct=10;resetsAt=$now.AddHours(1).ToString('o')};sevenDay=@{pct=20;resetsAt=$now.AddDays(1).ToString('o')}}}
    )}
    Check 'scheduled Claude collection updates before cached native readings expire' {
        Write-Hotpl8Text $env:HOTPL8_SAFE_FIXTURE ($fixture|ConvertTo-Json -Depth 12)
        Write-Hotpl8Text (Join-Path $dir 'policy.json') ($p|ConvertTo-Json -Depth 12)
        & (Get-Hotpl8PowerShell) -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tick.ps1') -StateDirectory $dir -CswapExecutable $stub -Scheduled -ObserveOnly -Strict
        Assert ($LASTEXITCODE -eq 0)
        $state=Read-Hotpl8Json (Join-Path $dir 'collector.json')
        $delay=([datetimeoffset]::Parse($state.providers.claude.nextAttemptAt)-[datetimeoffset]::Parse($state.providers.claude.lastAttemptAt)).TotalSeconds
        Assert ($delay -eq 60)
        # Native idle polling: 600s + 10% jitter. Observe the existing cache,
        # allowing one scheduler minute and one observation interval of delay.
        Assert ((660+60+$delay) -lt 900)
        Assert (@((Read-Hotpl8Json (Join-Path $dir 'status.json')).slots|Where-Object fresh).Count -eq 2)
        Assert (-not (Test-Path -LiteralPath $env:HOTPL8_SAFE_CALLS))
    }
    Check 'readings cswap lets grow old are asked for again at the next wake' {
        # cswap spaces its requests up to 30 minutes apart after a refusal and goes on
        # answering with the reading it has. A wait here would hide the next one.
        $old=Copy-Value $fixture;foreach($account in $old.accounts){$account.usageAgeSeconds=1500}
        Write-Hotpl8Text $env:HOTPL8_SAFE_FIXTURE ($old|ConvertTo-Json -Depth 12)
        $wake={
            $state=Read-Hotpl8Json (Join-Path $dir 'collector.json')
            $state.providers.claude.nextAttemptAt=[datetimeoffset]::UtcNow.AddSeconds(-1).ToString('o')
            Write-Hotpl8Text (Join-Path $dir 'collector.json') ($state|ConvertTo-Json -Depth 12)
            & (Get-Hotpl8PowerShell) -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tick.ps1') -StateDirectory $dir -CswapExecutable $stub -Scheduled -Strict
        }
        & $wake
        Assert ($LASTEXITCODE -eq 1)
        $claude=(Read-Hotpl8Json (Join-Path $dir 'collector.json')).providers.claude
        Assert ($claude.failures -eq 0 -and $claude.status -eq 'ok')
        Assert (([datetimeoffset]::Parse($claude.nextAttemptAt)-[datetimeoffset]::Parse($claude.lastAttemptAt)).TotalSeconds -eq 60)
        $status=Read-Hotpl8Json (Join-Path $dir 'status.json')
        Assert (@($status.slots|Where-Object fresh).Count -eq 0 -and @($status.slots|Where-Object status -eq 'ok').Count -eq 2)
        Assert ($status.collector.status -eq 'incomplete')
        Write-Hotpl8Text $env:HOTPL8_SAFE_FIXTURE ($fixture|ConvertTo-Json -Depth 12)
        & $wake
        Assert ($LASTEXITCODE -eq 0)
        $status=Read-Hotpl8Json (Join-Path $dir 'status.json')
        Assert (@($status.slots|Where-Object fresh).Count -eq 2 -and $status.collector.status -eq 'ok')
    }
    Check 'the account read outlasts cswap''s waits for a renewal reply' {
        # cswap: 10 s lock wait and 30 s reply wait, a 5 s usage request, then the
        # same two waits once more. Killing the read inside that span can discard a
        # token the server has already replaced.
        Assert ((Get-CswapReadTimeoutMs) -ge 85000)
    }
    Check 'bounded process times out and redacts its output' {
        $hostExe=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $clock=[Diagnostics.Stopwatch]::StartNew();$errorCode=''
        try{$null=Invoke-Hotpl8Process $hostExe @('-NoProfile','-Command','Start-Sleep -Seconds 10') 500}catch{$errorCode=$_.Exception.Message}
        Assert ($errorCode -eq 'process_timeout' -and $clock.ElapsedMilliseconds -lt 4000)
    }
    Check 'oversized process output is rejected without echoing it' {
        $hostExe=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $errorCode=''
        # Reading up to the limit takes about 9.5 s on an idle machine, so the time allowed
        # is well clear of it: this check is of the limit, and the one above of the time.
        try{$null=Invoke-Hotpl8Process $hostExe @('-NoProfile','-Command',"[Console]::Write(('x' * 1100000))") 60000}catch{$errorCode=$_.Exception.Message}
        Assert ($errorCode -eq 'process_output_limit')
    }
    Check 'doctor never exports labels homes or environment secrets' {
        $p.labels.'1'='PRIVATE_CANARY'
        Write-Hotpl8Text (Join-Path $dir 'policy.json') ($p|ConvertTo-Json -Depth 12)
        $before=@(Get-ChildItem -LiteralPath $dir -File).Count
        $text=Get-Hotpl8Doctor $dir|ConvertTo-Json -Depth 10
        Assert (-not $text.Contains('PRIVATE_CANARY') -and -not $text.Contains($dir))
        Assert (@(Get-ChildItem -LiteralPath $dir -File).Count -eq $before)
    }
    Check 'state replacement survives a concurrent legacy reader and preserves valid JSON' {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public static class Hotpl8ReaderFixture {
    public static Thread Hold(string path, int ms) {
        var ready = new ManualResetEvent(false);
        var thread = new Thread(() => {
            using(var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
                ready.Set(); Thread.Sleep(ms);
            }
        });
        thread.Start(); ready.WaitOne(); ready.Dispose(); return thread;
    }
}
'@
        $path=Join-Path $dir 'concurrent.json'
        Write-Hotpl8Text $path '{"generation":1}'
        $thread=[Hotpl8ReaderFixture]::Hold($path,125)
        try{Write-Hotpl8Text $path '{"generation":2}'}finally{$thread.Join()}
        Assert ((Read-Hotpl8Json $path).generation -eq 2)
        Assert (@(Get-ChildItem -LiteralPath $dir -Filter 'concurrent.json.*.tmp').Count -eq 0)
    }
    Check 'Windows replace delete-phase contention retries safely' {
        $script:replaceAttempts=0
        function Move-Hotpl8AtomicFile($Source,$Destination){
            $script:replaceAttempts++
            if($script:replaceAttempts -le 2){throw [IO.IOException]::new('fixture contention',-2147023721)} # 0x80070497 / 1175
            [IO.File]::Replace($Source,$Destination,[NullString]::Value)
        }
        $path=Join-Path $dir 'delete-phase.json'
        [IO.File]::WriteAllText($path,'{"generation":1}')
        Write-Hotpl8Text $path '{"generation":2}'
        Assert ($script:replaceAttempts -eq 3 -and (Read-Hotpl8Json $path).generation -eq 2)
        Assert (@(Get-ChildItem -LiteralPath $dir -Filter 'delete-phase.json.*.tmp').Count -eq 0)
    }
    Check 'partial replacement failure retains recoverable staged data' {
        function Move-Hotpl8AtomicFile($Source,$Destination){
            [IO.File]::Delete($Destination)
            throw [IO.IOException]::new('fixture partial rename',-2147023720) # 1176: old name may be gone
        }
        $path=Join-Path $dir 'partial.json';[IO.File]::WriteAllText($path,'{"generation":1}')
        $caught=$null
        try{Write-Hotpl8Text $path '{"generation":2}'}catch{$caught=$_}
        $staged=@(Get-ChildItem -LiteralPath $dir -Filter 'partial.json.*.tmp')
        Assert ($caught -and $staged.Count -eq 1 -and (Read-Hotpl8Json $staged[0].FullName).generation -eq 2)
    }
    Check 'persistent file lock fails visibly without destroying the last complete snapshot' {
        $path=Join-Path $dir 'status.json';Write-Hotpl8Text $path '{"generation":1}'
        $handle=[IO.File]::Open($path,'Open','Read','ReadWrite');$caught=$null
        try{Write-Hotpl8Text $path '{"generation":2}'}catch{$caught=$_}finally{$handle.Dispose()}
        Assert ($null -ne $caught -and (Get-Hotpl8FailureCode $caught) -eq 'state_io_failed')
        Assert ((Read-Hotpl8Json $path).generation -eq 1)
        Assert ($caught.Exception.Data['Hotpl8StateFile'] -eq 'status.json' -and $caught.Exception.Data['Hotpl8IoCode'] -eq 32)
    }
    Check 'a failure is recorded under the kind the shared cases say' {
        # tests/parity/shared-rules.json is read here and by the program's own tests, which
        # name the same kinds (native/src/ps.rs).
        $rules=[IO.File]::ReadAllText((Join-Path $root 'tests/parity/shared-rules.json'),(New-Object Text.UTF8Encoding($false)))|ConvertFrom-Json
        $absent=$null
        $failures=@{
            'access denied'={throw (New-Object UnauthorizedAccessException 'fictional')}
            'a file'={throw (New-Object IO.IOException 'fictional')}
            'a missing member'={$absent.member=1}
            # No parameter PowerShell itself refuses carries this name in Windows PowerShell,
            # so the record is made here.
            'a wrong parameter'={throw (New-Object Management.Automation.ErrorRecord (New-Object ArgumentException 'fictional'),'ParameterBindingFailed','InvalidArgument',$null)}
            'anything else'={throw 'fictional'}
        }
        Assert (@($rules.failures).Count -eq $failures.Count)
        foreach($case in @($rules.failures)){
            $caught=$null
            try{& $failures[$case.failure]}catch{$caught=$_}
            Assert ($null -ne $caught -and (Get-Hotpl8FailureCode $caught) -ceq $case.kind)
        }
    }
    Check 'fixed-code event log rotates to a bounded backup' {
        [IO.File]::WriteAllText((Join-Path $dir 'events.jsonl'),('x'*262145))
        Write-Hotpl8Event $dir 'test_event'
        Assert ((Get-Item (Join-Path $dir 'events.jsonl')).Length -lt 1000)
        Assert (Test-Path -LiteralPath (Join-Path $dir 'events.jsonl.1'))
    }
    Check 'a command file that ships starts programs by their whole path' {
        # cmd looks for a bare name in the current directory before PATH, and hotpl8 is typed
        # in folders that hold other people's files. A line of a command file is therefore one
        # of the few shapes below: cmd's own words, or a program named from this file's
        # directory or from SystemRoot. The two launchers of before start PowerShell by its
        # bare name; they ship unchanged for the sessions still running from them (docs/install.md,
        # "The launcher"), and nothing that ships hands over to them.
        $before=@('hotpl8-launch.cmd','delivery/launch.cmd')
        $shape='^(@echo off|rem( .*)?|:[a-z]+|if (not )?(exist "%~dp0[^"%]+"|errorlevel \d+|defined [A-Za-z]+) goto [a-z]+|exit /b (%errorlevel%|\d+)|echo [^&|<>%]*>&2|@?"%~dp0[^"%]+" .*|"%SystemRoot%\\System32\\[^"%]+" .*)$'
        $files=@((Read-Hotpl8Json (Join-Path $root 'release-files.json')).files|Where-Object{$_ -match '\.(cmd|bat)$'})
        foreach($name in $before+@('hotpl8.cmd','hotpl8-launch2.cmd','delivery/hotpl8.cmd','delivery/launch2.cmd')){Assert ($name -cin $files)}
        foreach($name in $files){
            $other=@([IO.File]::ReadAllLines((Join-Path $root $name))|Where-Object{$_ -and $_ -cnotmatch $shape})
            if($name -cin $before){Assert ($other.Count -eq 1 -and $other[0].StartsWith('powershell -NoProfile '))}
            elseif($other.Count){throw ($name+' starts something by a bare name: '+$other[0])}
        }
        foreach($name in 'hotpl8.cmd','delivery/hotpl8.cmd'){
            $line=[IO.File]::ReadAllText((Join-Path $root $name))
            Assert ($line -cmatch '\A@"%~dp0[a-z0-9-]+2\.cmd" %\*\r\n\z')
        }
        # The hand-off install.ps1 writes beside an ordinary installation names the release's own.
        Assert ([IO.File]::ReadAllText((Join-Path $root 'install.ps1')).Contains('$shim=''@"%~dp0app\hotpl8.cmd" %*''+[Environment]::NewLine'))
    }
}finally{
    $env:HOTPL8_SAFE_FIXTURE=$savedFixture;$env:HOTPL8_SAFE_CALLS=$savedCalls;$env:HOTPL8_STATE_DIRECTORY=$savedState
    $full=[IO.Path]::GetFullPath($dir)
    if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-safety-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
'passed='+$script:passed+' failed='+$script:failed
if($script:failed){exit 1}
