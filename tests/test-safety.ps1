$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/config.ps1')
. (Join-Path $root 'src/diagnostics.ps1')
. (Join-Path $root 'src/collection.ps1')
. (Join-Path $root 'src/providers/claude.ps1')
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
    Check 'new policy disables every automatic action' {
        Assert-Hotpl8Policy $policy
        $a=Get-Hotpl8Actions $policy $false
        Assert (-not $a.switching -and -not $a.warming -and -not $a.probing)
    }
    Check 'legacy actions preserved while refresh overrides them' {
        $p=Copy-Value @{prefer=@(1);warm=$true}
        $a=Get-Hotpl8Actions $p $false
        Assert ($a.switching -and $a.warming -and $a.probing)
        $a=Get-Hotpl8Actions $p $true
        Assert (-not $a.switching -and -not $a.warming -and -not $a.probing)
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
    Check 'monitor proposes a useful switch but never executes it' {
        Write-Hotpl8Text $env:HOTPL8_SAFE_FIXTURE ($fixture|ConvertTo-Json -Depth 12)
        $r=Invoke-ClaudeTick $p $dir $stub
        Assert ($r.payload.proposedSlot -eq 2 -and $r.payload.active -eq 1)
        Assert (-not (Test-Path -LiteralPath $env:HOTPL8_SAFE_CALLS))
    }
    Check 'explicit refresh blocks actions even with automate policy' {
        $p.mode='automate'
        $r=Invoke-ClaudeTick $p $dir $stub -ObserveOnly
        Assert ($r.payload.proposedSlot -eq 2 -and $r.payload.active -eq 1)
        Assert (-not (Test-Path -LiteralPath $env:HOTPL8_SAFE_CALLS))
    }
    Check 'disabled account and invalid age cannot be selected' {
        foreach($mutation in @('disabled','age','percentage','malformed-age','age-overflow')){
            $f=Copy-Value $fixture
            if($mutation -eq 'disabled'){$f.accounts[1]|Add-Member NoteProperty disabled $true}
            if($mutation -eq 'age'){$f.accounts[1].usageAgeSeconds=-1}
            if($mutation -eq 'malformed-age'){$f.accounts[1].usageAgeSeconds='not-a-number'}
            if($mutation -eq 'age-overflow'){$f.accounts[1].usageAgeSeconds=1e100}
            if($mutation -eq 'percentage'){$f.accounts[1].usage.fiveHour.pct=-10}
            Write-Hotpl8Text $env:HOTPL8_SAFE_FIXTURE ($f|ConvertTo-Json -Depth 12)
            $r=Invoke-ClaudeTick $p $dir $stub -ObserveOnly
            Assert ($null -eq $r.payload.proposedSlot)
            if($mutation -eq 'disabled'){Assert ($r.payload.slots[0].status -eq 'disabled')}
            else{Assert ($r.payload.slots[0].status -eq 'unsupported')}
        }
    }
    Check 'explicit Claude model constraints reject missing exhausted and expired scoped quota' {
        $modelPolicy=Copy-Value $p;$modelPolicy|Add-Member NoteProperty schemaVersion 2
        $modelPolicy|Add-Member NoteProperty claudeModels @('seven_day_opus')
        foreach($kind in @('missing','exhausted','expired','available')){
            $f=Copy-Value $fixture
            if($kind -ne 'missing'){
                $f.accounts[1].usage|Add-Member NoteProperty scoped @([pscustomobject]@{name='seven_day_opus';pct=$(if($kind -eq 'exhausted'){99}else{10});resetsAt=$(if($kind -eq 'expired'){$now.AddDays(-1).ToString('o')}else{$now.AddDays(1).ToString('o')})})
            }
            Write-Hotpl8Text $env:HOTPL8_SAFE_FIXTURE ($f|ConvertTo-Json -Depth 12)
            $r=Invoke-ClaudeTick $modelPolicy $dir $stub -ObserveOnly
            if($kind -eq 'available'){Assert ($r.payload.proposedSlot -eq 2)}else{Assert ($null -eq $r.payload.proposedSlot -and $r.payload.slots[0].modelBlock)}
        }
    }
    Check 'persistent pause reaches the provider and suppresses switch and warm dispatch' {
        . (Join-Path $root 'src/management.ps1')
        $f=Copy-Value $fixture;$f.accounts[1].usage.fiveHour.resetsAt=''
        Write-Hotpl8Text $env:HOTPL8_SAFE_FIXTURE ($f|ConvertTo-Json -Depth 12)
        Set-Hotpl8Pause $dir 60 'fixture'
        try{
            $r=Invoke-ClaudeTick $p $dir $stub
            Assert ($r.payload.active -eq 1 -and -not (Test-Path -LiteralPath $env:HOTPL8_SAFE_CALLS))
        }finally{Set-Hotpl8Pause $dir 0 'resumed'}
    }
    Check 'warm receipt prevents duplicate dispatch and reconciles a later native observation' {
        # Native dispatch is a test seam here; the real collector state machine runs.
        function Invoke-SlotPing { $script:warmDispatches++;return $true }
        $script:warmDispatches=0
        $wp=Copy-Value $p;$wp.mode='automate';$wp.switchEnabled=$false;$wp.probeEnabled=$false
        $f=Copy-Value $fixture;$f.accounts[1].usage.fiveHour.resetsAt=''
        Write-Hotpl8Text $env:HOTPL8_SAFE_FIXTURE ($f|ConvertTo-Json -Depth 12)
        $r=Invoke-ClaudeTick $wp $dir $stub
        Assert ($script:warmDispatches -eq 1 -and $r.payload.slots[0].warmOutcome.outcome -eq 'sent')
        Write-Hotpl8Text (Join-Path $dir 'warm-state.json') '{"lastWarm":{},"lastProbe":{}}'
        $r=Invoke-ClaudeTick $wp $dir $stub
        Assert ($script:warmDispatches -eq 1 -and $r.payload.slots[0].warmOutcome.outcome -eq 'sent')
        $f.accounts[1].usage.fiveHour.resetsAt=[datetimeoffset]::UtcNow.AddHours(5).ToString('o')
        Write-Hotpl8Text $env:HOTPL8_SAFE_FIXTURE ($f|ConvertTo-Json -Depth 12)
        $r=Invoke-ClaudeTick $wp $dir $stub -ObserveOnly
        Assert ($script:warmDispatches -eq 1 -and $r.payload.slots[0].warmOutcome.outcome -eq 'observed-active')
    }
    Check 'cold warming retains freshness weekly and scoped quota guards' {
        function Invoke-SlotPing { $script:warmDispatches++;return $true }
        foreach($mutation in @('stale','weekly-reset','percentage','scoped-exhausted','scoped-missing')){
            $script:warmDispatches=0
            $wp=Copy-Value $p;$wp.mode='automate';$wp.switchEnabled=$false;$wp.probeEnabled=$false
            $f=Copy-Value $fixture;$f.accounts[1].usage.fiveHour.resetsAt=''
            if($mutation -eq 'stale'){$f.accounts[1].usageAgeSeconds=901}
            if($mutation -eq 'weekly-reset'){$f.accounts[1].usage.sevenDay.resetsAt=''}
            if($mutation -eq 'percentage'){$f.accounts[1].usage.fiveHour.pct=-1}
            if($mutation -like 'scoped-*'){
                $wp|Add-Member NoteProperty claudeModels @('seven_day_opus')
                if($mutation -eq 'scoped-exhausted'){$f.accounts[1].usage|Add-Member NoteProperty scoped @(@{name='seven_day_opus';pct=99;resetsAt=$now.AddDays(1).ToString('o')})}
            }
            Write-Hotpl8Text $env:HOTPL8_SAFE_FIXTURE ($f|ConvertTo-Json -Depth 12)
            # Each case starts without receipts or cooldowns that could mask a
            # broken quota guard by independently suppressing dispatch.
            $caseDirectory=Join-Path $dir ('cold-'+$mutation)
            [void][IO.Directory]::CreateDirectory($caseDirectory)
            $r=Invoke-ClaudeTick $wp $caseDirectory $stub
            Assert ($script:warmDispatches -eq 0 -and $null -eq $r.payload.proposedSlot)
        }
    }
    Check 'monitor does not warm cold accounts or probe dead accounts' {
        $f=Copy-Value $fixture;$f.accounts[0].usage.fiveHour.resetsAt=''
        $f.accounts[1].usage=$null;$f.accounts[1].usageStatus='relogin_required'
        $f.accounts[1]|Add-Member NoteProperty lastGoodAgeSeconds 90000
        Write-Hotpl8Text $env:HOTPL8_SAFE_FIXTURE ($f|ConvertTo-Json -Depth 12)
        $p.mode='monitor';$null=Invoke-ClaudeTick $p $dir $stub
        Assert (-not (Test-Path -LiteralPath $env:HOTPL8_SAFE_CALLS))
        Assert (-not (Test-Path -LiteralPath (Join-Path $dir 'cred-audit.log')))
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
        try{$null=Invoke-Hotpl8Process $hostExe @('-NoProfile','-Command',"[Console]::Write(('x' * 1100000))") 10000}catch{$errorCode=$_.Exception.Message}
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
        Write-Hotpl8Event $dir 'collector_failed' $caught
        $event=Get-Content (Join-Path $dir 'events.jsonl') -Tail 1|ConvertFrom-Json
        Assert ($event.source -eq 'common.ps1' -and $event.line -gt 0 -and $event.failureCode -eq 'state_io_failed')
        Assert ($event.stateFile -eq 'status.json' -and $event.ioCode -eq 32)
        Assert (($event|ConvertTo-Json) -notmatch [regex]::Escape($dir))
    }
    Check 'unexpected diagnostic errors never export their message or invocation' {
        try{throw 'PRIVATE_CANARY native credential data'}catch{$_.Exception.Data['Hotpl8StateFile']='PRIVATE_CANARY';Write-Hotpl8Event $dir 'collector_failed' $_}
        $line=Get-Content (Join-Path $dir 'events.jsonl') -Tail 1
        Assert ($line -notmatch 'PRIVATE_CANARY|credential|Invocation|test-safety')
    }
    Check 'fixed-code event log rotates to a bounded backup' {
        [IO.File]::WriteAllText((Join-Path $dir 'events.jsonl'),('x'*262145))
        Write-Hotpl8Event $dir 'test_event'
        Assert ((Get-Item (Join-Path $dir 'events.jsonl')).Length -lt 1000)
        Assert (Test-Path -LiteralPath (Join-Path $dir 'events.jsonl.1'))
    }
}finally{
    $env:HOTPL8_SAFE_FIXTURE=$savedFixture;$env:HOTPL8_SAFE_CALLS=$savedCalls;$env:HOTPL8_STATE_DIRECTORY=$savedState
    $full=[IO.Path]::GetFullPath($dir)
    if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-safety-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
'passed='+$script:passed+' failed='+$script:failed
if($script:failed){exit 1}
