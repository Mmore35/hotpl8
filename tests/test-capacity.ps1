$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($file in @('common','config','dashboard','collection','management')){. (Join-Path $root ('src/'+$file+'.ps1'))}
. (Join-Path $PSScriptRoot 'fixtures/screenshots.ps1')
$fixture=Get-Hotpl8ScreenshotFixture;$now=$fixture.now
$script:passed=0;$script:failed=0
function Assert($Value,[string]$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check($Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message+' at '+$_.InvocationInfo.ScriptLineNumber}}
function Clone($Value){$Value|ConvertTo-Json -Depth 24|ConvertFrom-Json}
function Near($Actual,$Expected){Assert ([math]::Abs($Actual-$Expected) -lt 0.00001) ('expected '+$Expected+' got '+$Actual)}
function Policy { $p=Clone $fixture.policy;$p.mode='automate';$p.reserve=@();$p|Add-Member NoteProperty critical @{enabled=$true};return $p }
function Snapshot {Clone $fixture.status}
Check 'mixed tiers use units and both window constraints, not average percentages' {
    $p=Policy;$s=Snapshot;$c=Get-Hotpl8ProviderCapacity $s $p claude $now
    Assert $c.complete;Near $c.totalUnits 6;Near $c.usableNowPercent 26.1
    Near $c.projectedGainPercent 1.9
}
Check 'projection never double counts previously available quota' {
    $p=Policy;$s=Snapshot;$s.slots[0].reset5h=$s.slots[1].reset5h
    $c=Get-Hotpl8ProviderCapacity $s $p claude $now
    Near ($c.usableNowPercent+$c.projectedGainPercent) 30
}
Check 'weekly constraint can make next short reset add zero' {
    $p=Policy;$s=Snapshot;$s.slots[0].used7d=95
    $c=Get-Hotpl8ProviderCapacity $s $p claude $now
    Near $c.projectedGainPercent 0
}
Check 'expired reset awaits evidence and never becomes full' {
    $p=Policy;$s=Snapshot;$s.slots[0].reset5h=$now.AddSeconds(-1).ToString('o')
    $c=Get-Hotpl8ProviderCapacity $s $p claude $now
    Assert (-not $c.complete -and $null -eq $c.usableNowPercent -and $c.unknownPercent -gt 0)
}
Check 'unknown conversion cannot borrow another account weight' {
    $p=Policy;$p.capacity.'2'.PSObject.Properties.Remove('weekly')
    $c=Get-Hotpl8ProviderCapacity (Snapshot) $p claude $now
    Assert ($null -eq $c.totalUnits -and $null -eq $c.usableNowPercent)
}
Check 'disabled and duplicate membership are handled consistently' {
    $p=Policy;$p|Add-Member NoteProperty disabled @(2)
    $c=Get-Hotpl8ProviderCapacity (Snapshot) $p claude $now
    Near $c.totalUnits 1
    $p=Policy;$s=Snapshot;$s.slots[0]|Add-Member NoteProperty streamKey same;$s.slots[1]|Add-Member NoteProperty streamKey same
    Near (Get-Hotpl8ProviderCapacity $s $p claude $now).totalUnits 1
}
Check 'hold counts only the usable selected account' {
    $p=Policy;$s=Snapshot;$s.hold=@{until=$now.AddHours(1).ToString('o')}
    Near (Get-Hotpl8ProviderCapacity $s $p claude $now).usableNowPercent 3.1
}
Check 'single weekly-only Codex normalizes without guessed tier weights' {
    $p=Clone $fixture.policy.codex;$p.slots=@($p.slots[0]);$p.PSObject.Properties.Remove('capacity')
    $s=Snapshot;$s.providers.codex.slots=@($s.providers.codex.slots[0]);$s.providers.codex.slots[0].buckets.codex.windows.PSObject.Properties.Remove('300')
    $c=Get-Hotpl8ProviderCapacity $s $p codex $now
    Assert $c.complete;Near $c.usableNowPercent 59
    $p.slots+=([pscustomobject]@{id='disabled-copy'})
    $p|Add-Member NoteProperty disabled @('disabled-copy')
    $c=Get-Hotpl8ProviderCapacity $s $p codex $now
    Assert $c.complete;Near $c.usableNowPercent 59
}
Check 'unconfirmed reset does not hide current measured quota or invent projection' {
    $p=Clone $fixture.policy.codex;$s=Snapshot
    foreach($slot in $s.providers.codex.slots){foreach($w in $slot.buckets.codex.windows.PSObject.Properties){$w.Value.anchorState='unconfirmed'}}
    $c=Get-Hotpl8ProviderCapacity $s $p codex $now
    Assert ($c.complete -and $null -eq $c.nextResetAt -and $null -eq $c.projectedGainPercent)
}
Check 'critical ranking chooses more usable units over higher percentage' {
    $p=Policy;$s=Snapshot
    $s.slots[0].used5h=85;$s.slots[0].used7d=85;$s.slots[1].used5h=92;$s.slots[1].used7d=92
    $a=@(Get-Hotpl8CapacityAccounts $s $p claude $now)
    $d=Get-Hotpl8CriticalDecision $a $p '1' @{selected='1';selectedAt=$now.AddMinutes(-2).ToString('o')} $now
    Assert ($d.active -and $d.selected -eq '2' -and $d.pollSeconds -eq 60)
}
Check 'critical hysteresis persists until fresh recovery exceeds exit threshold' {
    $p=Policy;$s=Snapshot;foreach($slot in $s.slots){$slot.used5h=77;$slot.used7d=77}
    $a=@(Get-Hotpl8CapacityAccounts $s $p claude $now)
    Assert (-not (Get-Hotpl8CriticalDecision $a $p '1' $null $now).active)
    Assert ((Get-Hotpl8CriticalDecision $a $p '1' @{active=$true} $now).active)
    $s.slots[0].used5h=70;$s.slots[0].used7d=70;$a=@(Get-Hotpl8CapacityAccounts $s $p claude $now)
    Assert (-not (Get-Hotpl8CriticalDecision $a $p '1' @{active=$true} $now).active)
}
Check 'dwell prevents bounce but exhaustion bypasses it' {
    $p=Policy;$s=Snapshot;foreach($slot in $s.slots){$slot.used5h=90;$slot.used7d=90}
    $state=@{active=$true;selected='1';selectedAt=$now.ToString('o')}
    $a=@(Get-Hotpl8CapacityAccounts $s $p claude $now)
    Assert ((Get-Hotpl8CriticalDecision $a $p '1' $state $now).selected -eq '1')
    $s.slots[0].used5h=100;$a=@(Get-Hotpl8CapacityAccounts $s $p claude $now)
    Assert ((Get-Hotpl8CriticalDecision $a $p '1' $state $now).selected -eq '2')
}
Check 'emergency floors and explicit drain still reject zero' {
    $p=Policy;$s=Snapshot;foreach($slot in $s.slots){$slot.used5h=99.5;$slot.used7d=99.5}
    $a=@(Get-Hotpl8CapacityAccounts $s $p claude $now)
    Assert (-not (Get-Hotpl8CriticalDecision $a $p '1' $null $now).selected)
    $p.critical.drainToZero=$true
    Assert ((Get-Hotpl8CriticalDecision $a $p '1' $null $now).selected)
    foreach($slot in $s.slots){$slot.used5h=100};$a=@(Get-Hotpl8CapacityAccounts $s $p claude $now)
    Assert (-not (Get-Hotpl8CriticalDecision $a $p '1' $null $now).active)
}
Check 'unknown and disabled accounts cannot become emergency candidates' {
    $p=Policy;$s=Snapshot;$s.slots[0].fresh=$false;$s.slots[1].used5h=95
    $a=@(Get-Hotpl8CapacityAccounts $s $p claude $now)
    Assert ((Get-Hotpl8CriticalDecision $a $p '1' $null $now).selected -eq '2')
}
Check 'backoff skips preserve original retry deadline and can recover' {
    $state=[pscustomobject]@{providers=[pscustomobject]@{}}
    Set-Hotpl8CollectionResult $state codex $false $now
    $deadline=$state.providers.codex.nextAttemptAt
    $failure=Get-Hotpl8CodexFailure $null collection_failed invalid_cached_shape
    foreach($second in @(60,120,240)){
        Assert (-not (Test-Hotpl8CollectionDue $state codex $true $now.AddSeconds($second)))
        $failure=Get-Hotpl8CodexFailure $failure backoff $null
        Assert ($state.providers.codex.nextAttemptAt -eq $deadline -and $state.providers.codex.failures -eq 1)
    }
    Assert (Test-Hotpl8CollectionDue $state codex $true $now.AddMinutes(5))
    Set-Hotpl8CollectionResult $state codex $true $now.AddMinutes(5) 60
    Assert ($state.providers.codex.failures -eq 0 -and (Test-Hotpl8CollectionDue $state codex $true $now.AddMinutes(6)))
}
Check 'failure preserves stale account evidence without mutating previous snapshot' {
    $s=Snapshot;$before=$s|ConvertTo-Json -Depth 24
    $f=Get-Hotpl8CodexFailure $s.providers.codex collection_failed invalid_cached_shape
    Assert ($f.slots.Count -eq 2 -and $f.slots[0].status -eq 'collection_failed' -and -not $f.recommendedSlot)
    Assert (($s|ConvertTo-Json -Depth 24) -eq $before)
}
Check 'capacity profile edits are validated and preserve existing action defaults' {
    $p=Set-Hotpl8CapacityProfile $fixture.policy claude 1 claude-pro 1 0.3
    Assert-Hotpl8Policy $p
    Assert ($p.schemaVersion -eq 2 -and -not $p.switchEnabled -and $p.capacity.'1'.weekly -eq 1)
}
Check 'styled rows fit cell boundaries and strip untrusted terminal escapes' {
    $row=New-Hotpl8StyledRow @(New-Hotpl8Span ('x'+[char]27+'[2J') peach)
    $frame=Add-Hotpl8FrameBorder $row 12
    Assert ((Get-DashboardCells $frame.text) -eq 14 -and $frame.text -notmatch [char]27)
}
Check 'cat and nyan animate deterministically and respect reduced motion' {
    Assert ((Get-Hotpl8Cat 10.8) -ne (Get-Hotpl8Cat 0))
    Assert ((Get-Hotpl8Cat 10.8 -ReducedMotion) -eq (Get-Hotpl8Cat 0 -ReducedMotion))
    $a=@(Get-Hotpl8NyanRows 0);$b=@(Get-Hotpl8NyanRows 0.4)
    Assert (($a|ConvertTo-Json -Depth 8) -ne ($b|ConvertTo-Json -Depth 8))
    Assert (($a|ConvertTo-Json -Depth 8) -eq (@(Get-Hotpl8NyanRows 0.4 -ReducedMotion)|ConvertTo-Json -Depth 8))
}
Check 'combined dashboard is bounded at all supported viewports including nyan' {
    foreach($size in @(@(48,15),@(79,24),@(100,40))){
        $frame=@(Get-Hotpl8DashboardFrame (Snapshot) (Policy) $now $size[0] $size[1] 999 -Nyan)
        Assert ($frame.Count -le $size[1]);foreach($r in $frame){Assert ((Get-DashboardCells $r.text) -eq $size[0])}
    }
}

Check 'real scheduled tick normalizes sparse failure and retries only when due' {
    $dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-capacity-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dir)
    try{
        $p=@{schemaVersion=2;mode='monitor';prefer=@();codex=@{slots=@(@{id='fixture';home=$dir});defaultMeter='codex'}}
        Write-Hotpl8Text (Join-Path $dir 'policy.json') ($p|ConvertTo-Json -Depth 8)
        Write-Hotpl8Text (Join-Path $dir 'status.json') '{"providers":{"codex":{"status":"collection_failed","slots":[],"recommendedSlot":null}}}'
        $clock=[datetimeoffset]::UtcNow;$state=[pscustomobject]@{providers=[pscustomobject]@{}}
        Set-Hotpl8CollectionResult $state codex $false $clock
        $deadline=$state.providers.codex.nextAttemptAt
        Write-Hotpl8Text (Join-Path $dir 'collector.json') ($state|ConvertTo-Json -Depth 8)
        foreach($attempt in 1..2){
            & (Join-Path $root 'tick.ps1') -StateDirectory $dir -Scheduled -ObserveOnly -CodexReader {throw 'reader must not run during backoff'}
            $after=Read-Hotpl8Json (Join-Path $dir 'collector.json')
            Assert ($after.providers.codex.failures -eq 1 -and $after.providers.codex.nextAttemptAt -eq $deadline)
        }
        $after.providers.codex.nextAttemptAt=$clock.AddSeconds(-1).ToString('o')
        Write-Hotpl8Text (Join-Path $dir 'collector.json') ($after|ConvertTo-Json -Depth 8)
        & (Join-Path $root 'tick.ps1') -StateDirectory $dir -Scheduled -ObserveOnly -CodexReader {return [pscustomobject]@{status='ok';standardTransport=$true;identityKey='fictional';quota=$null;elapsedMs=0}}
        $after=Read-Hotpl8Json (Join-Path $dir 'collector.json')
        Assert ($after.providers.codex.failures -eq 0)
        Assert ((Read-Hotpl8Json (Join-Path $dir 'status.json')).providers.codex.slots[0].status -eq 'ok')
    }finally{
        $full=[IO.Path]::GetFullPath($dir)
        if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-capacity-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
    }
}
Check 'Codex emergency recommendation and preflight eligibility agree' {
    $p=Clone $fixture.policy.codex;$p|Add-Member NoteProperty critical @{enabled=$true}
    $s=Snapshot
    foreach($slot in $s.providers.codex.slots){foreach($w in $slot.buckets.codex.windows.PSObject.Properties){$w.Value.usedPercent=95;$w.Value.remainingPercent=5}}
    $selected=Select-CodexSlot $s.providers.codex.slots $p codex '' $null $now
    Assert ($selected -eq 'work')
    Assert ((Get-CodexEligibility $s.providers.codex.slots[0] $p codex $now $true) -eq 'eligible')
    Assert ((Get-CodexEligibility $s.providers.codex.slots[0] $p codex $now $false) -eq 'below_margin')
    $s.providers.codex.slots[0].buckets.codex.status='blocked'
    Assert ((Get-CodexEligibility $s.providers.codex.slots[0] $p codex $now $true) -eq 'blocked')
}
Check 'display policy override changes estimate without changing cached data or live policy' {
    $dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-capacity-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dir)
    try{
        $s=Snapshot;$p=Policy
        Write-Hotpl8Text (Join-Path $dir 'status.json') ($s|ConvertTo-Json -Depth 24)
        Write-Hotpl8Text (Join-Path $dir 'policy.json') ($p|ConvertTo-Json -Depth 24)
        $hash=(Get-FileHash (Join-Path $dir 'policy.json')).Hash
        $override=Clone $p;$override|Add-Member NoteProperty disabled @(2)
        $read=Read-Hotpl8Snapshot $dir $override
        Assert ($read.providerOverview.claude.accounts -eq 1)
        Assert ((Get-FileHash (Join-Path $dir 'policy.json')).Hash -eq $hash)
    }finally{
        $full=[IO.Path]::GetFullPath($dir)
        if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-capacity-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
    }
}
Check 'new Codex account remains visible beside confirmed exhausted subscription' {
    $p=Clone $fixture.policy;$s=Snapshot
    foreach($id in @('work','personal')){$p.codex.capacity.$id.weekly=1}
    foreach($slot in $s.providers.codex.slots){$slot.buckets.codex.windows.PSObject.Properties.Remove('300')}
    $empty=$s.providers.codex.slots[1];$empty.buckets.codex.status='blocked'
    $empty.buckets.codex.windows.'10080'.usedPercent=100;$empty.buckets.codex.windows.'10080'.remainingPercent=0
    $c=Get-Hotpl8ProviderCapacity $s $p.codex codex $now
    Assert $c.complete;Near $c.totalUnits 2;Near $c.usableNowPercent 29.5;Near $c.unknownPercent 0
    Assert (-not $c.projectionComplete -and $null -eq $c.projectedGainPercent)
    $overview=Get-Hotpl8ProviderOverview $s $p $now
    Assert ($overview.codex.measured -eq 2 -and $overview.codex.selected -eq 'work')
    $empty.observedAt=$now.AddHours(-1).ToString('o')
    Assert (-not (Get-Hotpl8ProviderCapacity $s $p.codex codex $now).complete)
    $empty.observedAt=$now.ToString('o');$empty.buckets.codex.status='constraint_unknown'
    Assert (-not (Get-Hotpl8ProviderCapacity $s $p.codex codex $now).complete)
}
Check 'tray capacity and projection lines appear once per provider' {
    . (Join-Path $root 'src/tray.ps1')
    $p=Policy;$s=Snapshot;$s|Add-Member NoteProperty providerOverview (Get-Hotpl8ProviderOverview $s $p $now) -Force
    $details=(Get-Hotpl8TrayModel $s $p $now).details
    Assert ([regex]::Matches($details,'(?m)^  Capacity:').Count -eq 2)
    Assert ([regex]::Matches($details,'(?m)^  Next reset:').Count -eq 2)
}
'passed='+$script:passed+' failed='+$script:failed
if($script:failed){exit 1}
