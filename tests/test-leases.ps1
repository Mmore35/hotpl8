$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/automation.ps1')
. (Join-Path $root 'src/management.ps1')
$script:passed=0;$script:failed=0
function Assert($Value){if(-not $Value){throw 'assertion failed'}}
function Check([string]$Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message}}
function Assert-Code([string]$Code,[scriptblock]$Body){$actual=$null;try{& $Body|Out-Null}catch{$actual=$_.Exception.Data['Hotpl8Code']};Assert ($actual -eq $Code)}
$dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-lease-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
$now=[datetimeoffset]'2030-01-01T00:00:00Z'
$a=[guid]::NewGuid().ToString();$b=[guid]::NewGuid().ToString()
$path=Join-Path $dir 'automation-leases.json'
try {
    Check 'missing ledger reads as unpaused without creating files' {
        Assert ($null -eq (Get-Hotpl8Pause $dir $now))
        Assert (@(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0)
    }
    Check 'independent owners, private summary, retry never extends, and conflicts reject' {
        $first=Invoke-Hotpl8LeaseAcquire $dir $a 'agent-a' 10 $now
        $null=Invoke-Hotpl8LeaseAcquire $dir $b 'agent-b' 20 $now
        $before=(Get-FileHash $path).Hash
        $retry=Invoke-Hotpl8LeaseAcquire $dir $a 'agent-a' 10 $now.AddMinutes(2)
        Assert ($retry.until -eq $first.until -and (Get-FileHash $path).Hash -eq $before)
        Assert-Code 'lease_conflict' { Invoke-Hotpl8LeaseAcquire $dir $a 'agent-a' 11 $now }
        Assert-Code 'lease_conflict' { Invoke-Hotpl8LeaseAcquire $dir $a 'Agent-a' 10 $now }
        $summary=Get-Hotpl8Pause $dir $now
        Assert ($summary.leaseCount -eq 2 -and [datetimeoffset]$summary.until -eq $now.AddMinutes(20))
        $json=$summary|ConvertTo-Json
        Assert ($json -notmatch $a -and $json -notmatch $b -and $json -notmatch 'agent-a|agent-b')
        $null=Invoke-Hotpl8LeaseRelease $dir $a $now.AddMinutes(3)
        Assert ((Get-Hotpl8Pause $dir $now.AddMinutes(3)).leaseCount -eq 1)
        $before=(Get-FileHash $path).Hash
        $null=Invoke-Hotpl8LeaseRelease $dir $a $now.AddMinutes(4)
        $retry=Invoke-Hotpl8LeaseAcquire $dir $a 'agent-a' 10 $now.AddMinutes(5)
        Assert ($retry.released -and -not $retry.active -and (Get-FileHash $path).Hash -eq $before)
    }
    Check 'manual resume cannot clear agent leases, lease release cannot clear manual pause' {
        Set-Hotpl8Pause $dir 0 'resumed'
        Assert ((Get-Hotpl8Pause $dir $now).leaseCount -eq 1)
        Write-Hotpl8Text (Join-Path $dir 'automation-pause.json') (@{until=$now.AddHours(1).ToString('o');reason='manual'}|ConvertTo-Json)
        Assert ((Get-Hotpl8Pause $dir $now).reason -eq 'manual_and_agent_leases')
        $null=Invoke-Hotpl8LeaseRelease $dir $b $now
        Assert ((Get-Hotpl8Pause $dir $now).reason -eq 'manual')
        Assert ($null -eq (Get-Hotpl8Pause $dir $now.AddHours(2)))
    }
    Check 'expiry is UTC and read-only; expired acquisition retries remain expired' {
        $id=[guid]::NewGuid().ToString()
        $null=Invoke-Hotpl8LeaseAcquire $dir $id 'clock' 60 ([datetimeoffset]'2030-01-01T04:00:00+02:00')
        Assert ((Get-Hotpl8LeasePause $dir $now.AddHours(2)).leaseCount -eq 1)
        $before=(Get-FileHash $path).Hash
        Assert ($null -eq (Get-Hotpl8LeasePause $dir $now.AddHours(3)))
        $retry=Invoke-Hotpl8LeaseAcquire $dir $id 'clock' 60 $now.AddHours(4)
        Assert (-not $retry.active -and -not $retry.released -and (Get-FileHash $path).Hash -eq $before)
    }
    Check 'release before acquisition records a repeat-safe cancel tombstone' {
        $id=[guid]::NewGuid().ToString()
        $null=Invoke-Hotpl8LeaseRelease $dir $id $now
        $before=(Get-FileHash $path).Hash
        $null=Invoke-Hotpl8LeaseRelease $dir $id $now.AddHours(1)
        Assert ((Get-FileHash $path).Hash -eq $before)
        Assert-Code 'lease_conflict' { Invoke-Hotpl8LeaseAcquire $dir $id 'late-delivery' 1 $now.AddHours(23) }
        Assert ((Invoke-Hotpl8LeaseAcquire $dir $id 'late-delivery' 1 $now.AddHours(24)).active)
    }
    Check 'invalid direct arguments are rejected' {
        foreach ($id in @('not-a-uuid',[guid]::Empty.ToString(),@('x'))) { Assert-Code 'invalid_arguments' { Invoke-Hotpl8LeaseRelease $dir $id $now } }
        foreach ($owner in @('',('x'*81),"line`nfeed",42)) { Assert-Code 'invalid_arguments' { Invoke-Hotpl8LeaseAcquire $dir ([guid]::NewGuid().ToString()) $owner 1 $now } }
        foreach ($minutes in @(0,1441)) { Assert-Code 'invalid_arguments' { Invoke-Hotpl8LeaseAcquire $dir ([guid]::NewGuid().ToString()) 'agent' $minutes $now } }
    }
    Check 'corrupt and unsupported ledgers fail closed without overwriting bytes' {
        $good=[IO.File]::ReadAllText($path)
        try {
            foreach ($bad in @('{','null','[]','{"schemaVersion":2,"entries":[]}','{"schemaVersion":1,"entries":{}}','{"schemaVersion":1,"entries":[null]}')) {
                [IO.File]::WriteAllText($path,$bad)
                Assert (Get-Hotpl8Pause $dir $now).invalid
                Assert-Code 'lease_state_invalid' { Invoke-Hotpl8LeaseAcquire $dir ([guid]::NewGuid().ToString()) 'agent' 1 $now }
                Assert-Code 'lease_state_invalid' { Invoke-Hotpl8LeaseRelease $dir $a $now }
                Assert ([IO.File]::ReadAllText($path) -ceq $bad)
            }
            $ledger=$good|ConvertFrom-Json
            $ledger.entries+=@($ledger.entries[0])
            [IO.File]::WriteAllText($path,($ledger|ConvertTo-Json -Depth 8))
            Assert (Get-Hotpl8LeasePause $dir $now).invalid
            foreach ($mutation in @(
                {param($e) $e.retainUntil=$now.AddMinutes(1).ToString('o')},
                {param($e) $e.until='not-a-date'},
                {param($e) $e.minutes='10'},
                {param($e) $e.leaseId='invalid'},
                {param($e) $e|Add-Member NoteProperty unexpected 'value'},
                {param($e) $e.PSObject.Properties.Remove('releasedAt')}
            )) {
                $ledger=$good|ConvertFrom-Json
                & $mutation $ledger.entries[0]
                [IO.File]::WriteAllText($path,($ledger|ConvertTo-Json -Depth 8))
                Assert (Get-Hotpl8LeasePause $dir $now).invalid
                Assert-Code 'lease_state_invalid' { Invoke-Hotpl8LeaseRelease $dir $a $now }
            }
        } finally { [IO.File]::WriteAllText($path,$good) }
    }
    Check 'unreadable state and failed atomic replacement preserve existing data' {
        $before=(Get-FileHash $path).Hash
        $handle=[IO.File]::Open($path,'Open','ReadWrite','None')
        try {
            Assert (Get-Hotpl8LeasePause $dir $now).invalid
            Assert-Code 'lease_state_invalid' { Invoke-Hotpl8LeaseRelease $dir $a $now }
        } finally { $handle.Dispose() }
        $handle=[IO.File]::Open($path,'Open','Read','Read')
        try { Assert-Code 'state_write_failed' { Invoke-Hotpl8LeaseAcquire $dir ([guid]::NewGuid().ToString()) 'blocked-write' 1 $now } }
        finally { $handle.Dispose() }
        Assert ((Get-FileHash $path).Hash -eq $before)
        Assert (@(Get-ChildItem $dir -Filter '*.tmp').Count -eq 0)
    }
    Check 'shared collector lock rejects mutations but allows passive reads' {
        $before=(Get-FileHash $path).Hash
        $handle=[IO.File]::Open((Join-Path $dir 'tick.lock'),'Open','ReadWrite','None')
        try {
            Assert-Code 'collector_busy' { Invoke-Hotpl8LeaseRelease $dir $a $now }
            $null=Get-Hotpl8LeasePause $dir $now
        } finally { $handle.Dispose() }
        Assert ((Get-FileHash $path).Hash -eq $before)
    }
    Check 'capacity includes retained tombstones and pruning waits at least 24 hours' {
        $capacity=Join-Path $dir 'capacity';[void][IO.Directory]::CreateDirectory($capacity)
        $entries=@(1..256|ForEach-Object { [pscustomobject]@{leaseId=[guid]::NewGuid().ToString();owner=$null;minutes=$null;acquiredAt=$null;until=$null;releasedAt=$now.ToString('o');retainUntil=$now.AddHours(24).ToString('o')} })
        Save-Hotpl8LeaseLedger $capacity $entries
        $id=[guid]::NewGuid().ToString()
        Assert-Code 'lease_capacity' { Invoke-Hotpl8LeaseAcquire $capacity $id 'full' 1 $now.AddHours(23) }
        Assert-Code 'lease_capacity' { Invoke-Hotpl8LeaseRelease $capacity $id $now.AddHours(23) }
        $null=Invoke-Hotpl8LeaseRelease $capacity $entries[0].leaseId $now.AddHours(23)
        $null=Invoke-Hotpl8LeaseAcquire $capacity $id 'room' 1440 $now.AddHours(24)
        Assert ((Read-Hotpl8LeaseLedger $capacity).entries.Count -eq 1)
        Assert ((Get-Hotpl8LeasePause $capacity $now.AddHours(47)).leaseCount -eq 1)
    }
    Check 'simultaneous processes retry busy locks without losing acquisitions' {
        $parallel=Join-Path $dir 'parallel';[void][IO.Directory]::CreateDirectory($parallel)
        $worker=Join-Path $dir 'worker.ps1'
        $workerSource=@'
param($Root,$Directory,$Id)
$ErrorActionPreference='Stop'
. (Join-Path $Root 'src/common.ps1')
. (Join-Path $Root 'src/leases.ps1')
for($attempt=0;$attempt -lt 100;$attempt++) {
    try { $null=Invoke-Hotpl8LeaseAcquire $Directory $Id 'parallel' 10; exit 0 }
    catch { if($_.Exception.Data['Hotpl8Code'] -ne 'collector_busy'){exit 2};Start-Sleep -Milliseconds 20 }
}
exit 3
'@
        [IO.File]::WriteAllText($worker,$workerSource)
        $processes=@()
        try {
            foreach ($i in 1..4) {
                $psi=New-Object Diagnostics.ProcessStartInfo
                $psi.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
                $psi.Arguments=(@('-NoProfile','-ExecutionPolicy','Bypass','-File',$worker,$root,$parallel,[guid]::NewGuid().ToString())|ForEach-Object {ConvertTo-NativeArgument $_}) -join ' '
                $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
                $processes+=@([Diagnostics.Process]::Start($psi))
            }
            foreach ($proc in $processes) { Assert ($proc.WaitForExit(30000));Assert ($proc.ExitCode -eq 0) }
            Assert ((Get-Hotpl8LeasePause $parallel).leaseCount -eq 4)
        } finally { foreach ($proc in $processes) { if (-not $proc.HasExited) { $proc.Kill() };$proc.Dispose() } }
    }
    Check 'rollback refuses active or invalid leases but permits expired and released state' {
        foreach ($kind in @('active','invalid','expired','released')) {
            $installation=Join-Path $dir ('rollback-'+$kind);$state=Join-Path $installation 'state'
            [void][IO.Directory]::CreateDirectory($state)
            foreach ($version in @('app','previous')) {
                $code=Join-Path $installation $version
                [void][IO.Directory]::CreateDirectory((Join-Path $code 'src'))
                Write-Hotpl8Text (Join-Path $code 'release-files.json') '{"schemaVersion":1,"files":["VERSION","release-files.json","src/config.ps1"]}'
                Write-Hotpl8Text (Join-Path $code 'VERSION') $version
                Write-Hotpl8Text (Join-Path $code 'src/config.ps1') 'function Assert-Hotpl8Policy($Policy) {}'
            }
            Write-Hotpl8Text (Join-Path $installation 'installation.json') (@{product='hotpl8';stateDirectory=$state;version='app'}|ConvertTo-Json)
            $time=[datetimeoffset]::UtcNow
            if ($kind -eq 'expired') { $time=$time.AddHours(-2) }
            $id=[guid]::NewGuid().ToString();$null=Invoke-Hotpl8LeaseAcquire $state $id 'rollback-fixture' 60 $time
            if ($kind -eq 'released') { $null=Invoke-Hotpl8LeaseRelease $state $id }
            if ($kind -eq 'invalid') { Write-Hotpl8Text (Join-Path $state 'automation-leases.json') '{' }
            $rejected=$false
            try { & (Join-Path $root 'rollback.ps1') -InstallDirectory $installation|Out-Null }
            catch { $rejected=$true;Assert ($_.Exception.Message -like 'Agent pauses are active*') }
            Assert ($rejected -eq ($kind -in @('active','invalid')))
            $expected=if($rejected){'app'}else{'previous'}
            Assert ((Get-Content (Join-Path $installation 'app/VERSION') -Raw).Trim() -eq $expected)
        }
    }
} finally {
    $full=[IO.Path]::GetFullPath($dir)
    if ($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-lease-test-[a-f0-9]{32}$') { Remove-Item -LiteralPath $full -Recurse -Force }
}
'Lease tests: '+$script:passed+' passed; '+$script:failed+' failed.'
if($script:failed){exit 1}
