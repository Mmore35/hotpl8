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
Check 'zero-gain short reset is skipped for a later useful refill' {
    $p=Policy;$s=Snapshot;$s.slots[0].used7d=95
    $c=Get-Hotpl8ProviderCapacity $s $p claude $now
    Near $c.projectedGainPercent 2
    Assert ([datetimeoffset]::Parse($c.nextResetAt) -eq [datetimeoffset]::Parse($s.slots[1].reset5h))
}
Check 'expired reset awaits evidence and never becomes full' {
    # The payload handed us an anchor that had already expired when we read
    # it: suspect, so it stays unknown rather than refilling.
    $p=Policy;$s=Snapshot;$s.slots[0].observedAt=$now.AddSeconds(-20).ToString('o')
    $s.slots[0].reset5h=$now.AddSeconds(-30).ToString('o')
    $c=Get-Hotpl8ProviderCapacity $s $p claude $now
    Assert (-not $c.complete -and $null -eq $c.usableNowPercent -and $c.unknownPercent -gt 0)
}
Check 'a reset that elapsed after we read the window refills it' {
    $p=Policy;$s=Snapshot;$s.slots[0].reset5h=$now.AddSeconds(-1).ToString('o')
    $c=Get-Hotpl8ProviderCapacity $s $p claude $now
    Assert ($c.complete -and $c.unknownPercent -eq 0)
    Assert ($c.usableNowPercent -gt (Get-Hotpl8ProviderCapacity (Snapshot) $p claude $now).usableNowPercent)
    # The elapsed reset drops out of the schedule instead of anchoring it.
    Assert ([datetimeoffset]::Parse($c.nextResetAt) -gt $now)
}
Check 'an observation stamped ahead of our clock never rolls over' {
    $p=Policy;$s=Snapshot;$s.slots[0].observedAt=$now.AddMinutes(1).ToString('o')
    $s.slots[0].reset5h=$now.AddSeconds(-1).ToString('o')
    $c=Get-Hotpl8ProviderCapacity $s $p claude $now
    Assert (-not $c.complete -and $c.unknownPercent -gt 0)
}
Check 'an elapsed reset cannot refill a window we never managed to read' {
    # Rolling over replaces the reading with a full window, so it must refuse
    # a reading it would be inventing. No reading is not 100% free, and an
    # out-of-range one has no more standing than a missing one.
    foreach($used in @($null,101)){
        $p=Policy;$s=Snapshot;$s.slots[0].observedAt=$now.AddMinutes(-5).ToString('o')
        $s.slots[0].reset5h=$now.AddSeconds(-1).ToString('o');$s.slots[0].used5h=$used
        $c=Get-Hotpl8ProviderCapacity $s $p claude $now
        Assert (-not $c.complete -and $c.unknownPercent -gt 0)
    }
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
Check 'actual state lock does not become a five-minute Codex outage' {
    $dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-storage-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dir)
    $handle=$null
    try{
        $p=@{schemaVersion=2;mode='monitor';prefer=@();codex=@{slots=@(@{id='fixture';home=$dir});defaultMeter='codex'}}
        Write-Hotpl8Text (Join-Path $dir 'policy.json') ($p|ConvertTo-Json -Depth 8)
        $script:nativeReads=0
        $reader={$script:nativeReads++;return [pscustomobject]@{status='ok';standardTransport=$true;identityKey='fictional';quota=$null;elapsedMs=0}}
        & (Join-Path $root 'tick.ps1') -StateDirectory $dir -ObserveOnly -CodexReader $reader
        $before=Read-Hotpl8Json (Join-Path $dir 'status.json')
        $handle=[IO.File]::Open((Join-Path $dir 'codex-state.json'),'Open','Read','ReadWrite')
        & (Join-Path $root 'tick.ps1') -StateDirectory $dir -ObserveOnly -CodexReader $reader
        $after=Read-Hotpl8Json (Join-Path $dir 'status.json');$c=Read-Hotpl8Json (Join-Path $dir 'collector.json')
        Assert ($after.providers.codex.failureCode -eq 'state_io_failed' -and $null -eq $after.providers.codex.recommendedSlot)
        Assert ($after.providers.codex.slots[0].observedAt -eq $before.providers.codex.slots[0].observedAt)
        $provider=$c.providers.codex
        Assert (([datetimeoffset]::Parse($provider.nextAttemptAt)-[datetimeoffset]::Parse($provider.lastAttemptAt)).TotalSeconds -eq 60)
        $reads=$script:nativeReads
        & (Join-Path $root 'tick.ps1') -StateDirectory $dir -Scheduled -ObserveOnly -CodexReader $reader
        Assert ($script:nativeReads -eq $reads)
        $handle.Dispose();$handle=$null
        $c.providers.codex.nextAttemptAt=[datetimeoffset]::UtcNow.AddSeconds(-1).ToString('o')
        Write-Hotpl8Text (Join-Path $dir 'collector.json') ($c|ConvertTo-Json -Depth 8)
        & (Join-Path $root 'tick.ps1') -StateDirectory $dir -Scheduled -ObserveOnly -CodexReader $reader
        $recovered=Read-Hotpl8Json (Join-Path $dir 'status.json')
        Assert ($recovered.providers.codex.slots[0].status -eq 'ok' -and -not $recovered.collector.providers.codex.failureCode)
        $handle=[IO.File]::Open((Join-Path $dir 'status.js'),'Open','Read','ReadWrite')
        & (Join-Path $root 'tick.ps1') -StateDirectory $dir -ObserveOnly -CodexReader $reader
        $mirrored=Read-Hotpl8Snapshot $dir
        Assert ($mirrored.collector.status -eq 'ok' -and $mirrored.providers.codex.slots[0].status -eq 'ok') 'a locked compatibility mirror must not break the primary snapshot'
        $handle.Dispose();$handle=$null
        $p.historyEnabled=$true
        Write-Hotpl8Text (Join-Path $dir 'policy.json') ($p|ConvertTo-Json -Depth 8)
        Write-Hotpl8Text (Join-Path $dir 'usage-history.json') '{"samples":[]}'
        $handle=[IO.File]::Open((Join-Path $dir 'usage-history.json'),'Open','Read','ReadWrite')
        & (Join-Path $root 'tick.ps1') -StateDirectory $dir -ObserveOnly -CodexReader $reader
        $withHistory=Read-Hotpl8Snapshot $dir
        Assert ($withHistory.generationId -ne $mirrored.generationId -and $withHistory.collector.status -eq 'ok') 'optional history cannot block a fresh snapshot'
        $handle.Dispose();$handle=$null
        Write-Hotpl8Text (Join-Path $dir 'activity.json') '{"events":[]}'
        $handle=[IO.File]::Open((Join-Path $dir 'activity.json'),'Open','Read','ReadWrite')
        $withHistory.active=2
        Add-Hotpl8Insights $withHistory ([pscustomobject]$p) $dir ([pscustomobject]@{active=1})
        Assert ($withHistory.providerOverview -and $withHistory.collector.status -eq 'ok') 'activity output cannot invalidate the current observation'
        $handle.Dispose();$handle=$null
        $events=@(Get-Content -LiteralPath (Join-Path $dir 'events.jsonl')|ForEach-Object {$_|ConvertFrom-Json})
        Assert ('history_output_failed' -in $events.code -and 'activity_output_failed' -in $events.code) 'optional write failures remain diagnosable'
    }finally{
        if($handle){$handle.Dispose()}
        $full=[IO.Path]::GetFullPath($dir)
        if((Split-Path $full -Parent) -eq [IO.Path]::GetTempPath().TrimEnd('\','/') -and (Split-Path $full -Leaf) -match '^hotpl8-storage-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
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
Check 'detected plan weights estimate current session allowance without inventing conversions' {
    $p=Policy;$s=Snapshot;$p.PSObject.Properties.Remove('capacity')
    foreach($slot in $s.slots){$slot|Add-Member NoteProperty plan @{status='detected';profile='claude-pro';observedAt=$now.ToString('o')} -Force}
    $s.slots[1].plan.profile='claude-max-5x'
    $s.slots[0].used5h=100;$s.slots[0].used7d=10
    $s.slots[1].used5h=50;$s.slots[1].used7d=10
    $o=Get-Hotpl8ProviderOverview $s $p $now
    $d=Get-Hotpl8CapacityDisplay $o.claude
    Assert (-not $d.weekly -and $d.title -eq 'Available now')
    Near $d.value (250/6);Near $o.claude.remainingPercent 90
    Assert ($o.claude.immediate.metric -eq 'plan-weighted-quota-headroom')
    Assert ($null -ne $d.gain -and $null -eq $o.claude.capacity.usableNowPercent)
    $text=((Get-Hotpl8OverviewRows $s $p $now 108).text)-join "`n"
    Assert ($text.Contains('~42% now') -and $text.Contains('7d 90%') -and -not $text.Contains('Weekly remaining'))
    $s.slots[0].observedAt=$now.AddHours(-1).ToString('o')
    $d=Get-Hotpl8CapacityDisplay (Get-Hotpl8ProviderOverview $s $p $now).claude
    Assert ($d.unknown -gt 0 -and $d.state.Contains('total unavailable') -and $null -eq $d.gain)
    Assert ($d.state.Contains('expired; awaiting update') -and -not $d.state.Contains('setup needed'))
}
Check 'equal Codex plans at zero and 95 percent show 47.5 percent and expose exclusions' {
    $p=Clone $fixture.policy;$s=Snapshot
    foreach($id in @('work','personal')){$p.codex.capacity.$id.weekly=1}
    foreach($slot in $s.providers.codex.slots){$slot.buckets.codex.windows.PSObject.Properties.Remove('300')}
    $s.providers.codex.slots[0].buckets.codex.windows.'10080'.remainingPercent=95
    $s.providers.codex.slots[0].buckets.codex.windows.'10080'.usedPercent=5
    $s.providers.codex.slots[1].buckets.codex.status='blocked'
    $s.providers.codex.slots[1].buckets.codex.windows.'10080'.remainingPercent=0
    $s.providers.codex.slots[1].buckets.codex.windows.'10080'.usedPercent=100
    Near (Get-Hotpl8ProviderOverview $s $p $now).codex.capacity.usableNowPercent 47.5
    $p.codex|Add-Member NoteProperty disabled @('personal') -Force
    $text=((Get-Hotpl8OverviewRows $s $p $now 108).text)-join "`n"
    Assert ($text.Contains('95% now') -and $text.Contains('next: work') -and $text.Contains('1 off'))
}
Check 'weekly allowance cannot fill the main bar while short windows are exhausted' {
    $p=Policy;$s=Snapshot;$p.PSObject.Properties.Remove('capacity')
    foreach($slot in $s.slots){
        $slot|Add-Member NoteProperty plan @{status='detected';profile='claude-pro';observedAt=$now.ToString('o')} -Force
        $slot.used5h=100;$slot.used7d=10;$slot.reset5h=$now.AddHours(5).ToString('o')
    }
    $d=Get-Hotpl8CapacityDisplay (Get-Hotpl8ProviderOverview $s $p $now).claude
    Near $d.value 0;Near $d.gain 100
    Assert ([datetimeoffset]::Parse($d.nextResetAt) -eq $now.AddHours(5))
    foreach($slot in $s.slots){$slot.used7d=100}
    $d=Get-Hotpl8CapacityDisplay (Get-Hotpl8ProviderOverview $s $p $now).claude
    Near $d.value 0;Assert ($null -eq $d.gain -and $null -eq $d.nextResetAt)
    # Already expired on arrival, so it cannot refill the exhausted fleet.
    $s.slots[0].observedAt=$now.AddSeconds(-20).ToString('o')
    $s.slots[0].reset7d=$now.AddSeconds(-30).ToString('o')
    $d=Get-Hotpl8CapacityDisplay (Get-Hotpl8ProviderOverview $s $p $now).claude
    Assert ($null -eq $d.gain -and $d.state.Contains('total unavailable'))
}
Check 'hatching means refill only and is contiguous with the measured fill at every viewport' {
    $p=Policy;$s=Snapshot;$p.PSObject.Properties.Remove('capacity')
    foreach($slot in $s.slots){$slot|Add-Member NoteProperty plan @{status='detected';profile='claude-pro';observedAt=$now.ToString('o')} -Force;$slot.used5h=60;$slot.used7d=20}
    foreach($width in @(46,77,108)){
        $rows=@(Get-Hotpl8OverviewRows $s $p $now $width)
        Assert ((Get-DashboardCells $rows[1].text) -le $width)
        Assert ($rows[1].text -match '\[█+[▏▎▍▌▋▊▉]?▒+·*\]' -and $rows[1].text.Contains('% in '))
    }
    $p=Policy;$s.slots[0].observedAt=$now.AddHours(-1).ToString('o')
    $rows=@(Get-Hotpl8OverviewRows $s $p $now 108)
    Assert ($rows[1].text -notmatch '[░▒]' -and $rows[1].text.Contains('? now') -and $rows[0].text.Contains('1/2 read'))
    $p.PSObject.Properties.Remove('capacity')
    $rows=@(Get-Hotpl8OverviewRows $s $p $now 108)
    Assert ($rows[1].text -notmatch '[░▒]' -and $rows[1].text.Contains('? now') -and $rows[0].text.Contains('1/2 read'))
}
Check 'refill horizon includes 24h exactly and excludes a second later' {
    $p=Policy;$s=Snapshot
    foreach($slot in $s.slots){$slot.reset5h=$now.AddHours(24).ToString('o')}
    $c=Get-Hotpl8ProviderCapacity $s $p claude $now
    Assert ($c.projectedGainPercent -gt 0 -and [datetimeoffset]::Parse($c.nextResetAt) -eq $now.AddHours(24))
    foreach($slot in $s.slots){$slot.reset5h=$now.AddHours(24).AddSeconds(1).ToString('o')}
    $c=Get-Hotpl8ProviderCapacity $s $p claude $now
    Assert ($null -eq $c.projectedGainPercent -and $null -eq $c.nextResetAt)
    Assert (@(Get-Hotpl8OverviewRows $s $p $now 108)[1].text -notmatch '▒')
}
Check 'unknown plans remain unknown instead of receiving invented tier weights' {
    $p=Policy;$s=Snapshot;$p.PSObject.Properties.Remove('capacity')
    $d=Get-Hotpl8CapacityDisplay (Get-Hotpl8ProviderOverview $s $p $now).claude
    Assert ($d.title -eq 'Available now' -and -not $d.capacity.complete -and $null -eq $d.gain)
    Assert ($d.state.Contains('total unavailable') -and $d.value -eq 0)
}
Check 'blocked zero account cannot hide a known refill from another Codex subscription' {
    $p=Policy;$s=Snapshot
    $blocked=$s.providers.codex.slots[1];$blocked.buckets.codex.status='blocked'
    $blocked.buckets.codex.windows.'10080'.usedPercent=100;$blocked.buckets.codex.windows.'10080'.remainingPercent=0
    $c=Get-Hotpl8ProviderCapacity $s $p.codex codex $now
    Assert ($c.complete -and -not $c.projectionComplete)
    Near $c.projectedGainPercent 6.5
    Assert ([datetimeoffset]::Parse($c.nextResetAt) -eq $now.AddHours(2))
    $blocked.observedAt=$now.AddHours(-1).ToString('o')
    Assert ($null -eq (Get-Hotpl8ProviderCapacity $s $p.codex codex $now).projectedGainPercent)
}
function Exhausted-Codex([string]$Reason='quota_exhausted') {
    $s=Snapshot
    $s.providers.codex.slots[0].buckets.codex.windows.PSObject.Properties.Remove('300')
    $empty=$s.providers.codex.slots[1];$empty.buckets.codex.status='blocked'
    if($Reason){$empty.buckets.codex|Add-Member NoteProperty blockReason $Reason -Force}
    $empty.buckets.codex.windows.'10080'.usedPercent=100;$empty.buckets.codex.windows.'10080'.remainingPercent=0
    return $s
}
Check 'confirmed quota exhaustion resetting inside 24h is projected as a refill' {
    $p=Policy;$s=Exhausted-Codex
    $c=Get-Hotpl8ProviderCapacity $s $p.codex codex $now
    Assert ($c.complete -and $c.projectionComplete)
    Near $c.usableNowPercent (100*2.95/6)
    Near $c.projectedGainPercent (100/6)
    Assert ([datetimeoffset]::Parse($c.nextResetAt) -eq $now.AddHours(18))
    Assert ($null -eq $c.laterRefillAt -and $null -eq $c.laterRefillGainPercent)
}
Check 'a confirmed refill beyond 24h is reported as later text without a projection' {
    $p=Policy;$s=Exhausted-Codex
    $s.providers.codex.slots[1].buckets.codex.windows.'10080'.resetsAt=$now.AddHours(30).ToUnixTimeSeconds()
    $c=Get-Hotpl8ProviderCapacity $s $p.codex codex $now
    Assert ($c.complete -and $c.projectionComplete)
    Assert ($null -eq $c.nextResetAt -and $null -eq $c.projectedGainPercent)
    Assert ([datetimeoffset]::Parse($c.laterRefillAt) -eq $now.AddHours(30))
    Near $c.laterRefillGainPercent (100/6)
}
Check 'a restricted block keeps the projection incomplete and the later fields empty' {
    $p=Policy;$s=Snapshot
    $blocked=$s.providers.codex.slots[1];$blocked.buckets.codex.status='blocked'
    $blocked.buckets.codex|Add-Member NoteProperty blockReason 'restricted' -Force
    $blocked.buckets.codex.windows.'10080'.usedPercent=100;$blocked.buckets.codex.windows.'10080'.remainingPercent=0
    $c=Get-Hotpl8ProviderCapacity $s $p.codex codex $now
    Assert ($c.complete -and -not $c.projectionComplete)
    Near $c.projectedGainPercent 6.5
    Assert ([datetimeoffset]::Parse($c.nextResetAt) -eq $now.AddHours(2))
    Assert ($null -eq $c.laterRefillAt -and $null -eq $c.laterRefillGainPercent)
}
Check 'an unconfirmed reset never grants a quota refill' {
    $p=Policy;$s=Snapshot
    $blocked=$s.providers.codex.slots[1];$blocked.buckets.codex.status='blocked'
    $blocked.buckets.codex|Add-Member NoteProperty blockReason 'quota_exhausted' -Force
    $blocked.buckets.codex.windows.'10080'.usedPercent=100;$blocked.buckets.codex.windows.'10080'.remainingPercent=0
    $blocked.buckets.codex.windows.'10080'.anchorState='unconfirmed'
    $c=Get-Hotpl8ProviderCapacity $s $p.codex codex $now
    Assert ($c.complete -and -not $c.projectionComplete)
    Near $c.projectedGainPercent 6.5
    Assert ($null -eq $c.laterRefillAt -and $null -eq $c.laterRefillGainPercent)
}
Check 'a stale quota exhaustion is never projected as a refill' {
    $p=Policy;$s=Exhausted-Codex
    $s.providers.codex.slots[1].observedAt=$now.AddHours(-1).ToString('o')
    $c=Get-Hotpl8ProviderCapacity $s $p.codex codex $now
    Assert (-not $c.complete -and -not $c.projectionComplete)
    Assert ($null -eq $c.projectedGainPercent -and $null -eq $c.nextResetAt)
    Assert ($null -eq $c.laterRefillAt -and $null -eq $c.laterRefillGainPercent)
}
Check 'a quota exhausted account adds nothing usable now and stays out of the critical choice' {
    $p=Policy;$plain=Get-Hotpl8ProviderCapacity (Exhausted-Codex $null) $p.codex codex $now
    $c=Get-Hotpl8ProviderCapacity (Exhausted-Codex) $p.codex codex $now
    Near $c.usableNowPercent $plain.usableNowPercent
    Near $c.knownUsablePercent $plain.knownUsablePercent
    Near $c.unknownPercent $plain.unknownPercent
    Assert ((ConvertTo-Json $c.critical -Depth 8) -eq (ConvertTo-Json $plain.critical -Depth 8))
    $account=@($c.accounts|Where-Object {$_.slot -eq 'personal'})[0]
    Assert ($account.blocked -and $account.knownZero -and $account.refillExpected -and $account.blockReason -eq 'quota_exhausted')
    Assert ($null -eq (Get-Hotpl8CapacityAmount $account $p.codex $now $false))
}
Check 'a weekly-only Codex pair shows one estimate, a later refill and no duplicate weekly figure' {
    $p=Policy;$s=Snapshot
    foreach($id in @('work','personal')){$p.codex.capacity.$id.weekly=1;$p.codex.capacity.$id.fiveHour=0.3}
    $work=$s.providers.codex.slots[0];$work.buckets.codex.windows.PSObject.Properties.Remove('300')
    $work.buckets.codex.windows.'10080'.usedPercent=52;$work.buckets.codex.windows.'10080'.remainingPercent=48
    $work.buckets.codex.windows.'10080'.resetsAt=$now.AddDays(6).ToUnixTimeSeconds()
    $empty=$s.providers.codex.slots[1];$empty.buckets.codex.status='blocked'
    $empty.buckets.codex|Add-Member NoteProperty blockReason 'quota_exhausted' -Force
    $empty.buckets.codex.windows.'10080'.usedPercent=100;$empty.buckets.codex.windows.'10080'.remainingPercent=0
    $empty.buckets.codex.windows.'10080'.resetsAt=$now.AddDays(3.6).ToUnixTimeSeconds()
    foreach($width in @(48,79,110)){
        $rows=@(Get-Hotpl8OverviewRows $s $p $now $width)
        $codex=$rows[3].text
        Assert ($codex.Contains('~24% now')) $codex
        Assert ($codex.Contains('+50% in ')) $codex
        Assert (-not $codex.Contains('7d') -and $codex -notmatch '[░▒]') $codex
        Assert ((Get-DashboardCells $codex) -le $width) $codex
        # Claude still carries its distinct weekly figure wherever there is room for it.
        if($width -ge 79){Assert ($rows[1].text -match '7d\s+\d') $rows[1].text}
    }
}
Check 'three equal plans show 91.7 now and refill to 100 despite unequal weekly percentages' {
    $p=Policy;$s=Snapshot;$p.PSObject.Properties.Remove('capacity');$p.prefer=@(1,2,3)
    $third=Clone $s.slots[0];$third.slot=3;$s.slots+=@($third)
    foreach($slot in $s.slots){$slot|Add-Member NoteProperty plan @{status='detected';profile='claude-pro';observedAt=$now.ToString('o')} -Force;$slot.used5h=0}
    $s.slots[0].used7d=22;$s.slots[1].used7d=20;$s.slots[2].used7d=29
    $s.slots[1].used5h=25;$s.slots[1].reset5h=$now.AddMinutes(42).ToString('o')
    $o=Get-Hotpl8ProviderOverview $s $p $now;$d=Get-Hotpl8CapacityDisplay $o.claude
    Near $d.value (275/3);Near ($d.value+$d.gain) 100
    Assert ([datetimeoffset]::Parse($d.nextResetAt) -eq $now.AddMinutes(42))
    Assert ($o.claude.immediate.accounts[0].unconvertedConstraints -contains '10080')
}
Check 'known weekly conversion caps a full session in session units and caps its refill' {
    $p=Policy;$s=Snapshot;$p.prefer=@(1)
    $s.slots[0].used5h=0;$s.slots[0].used7d=98
    $d=Get-Hotpl8CapacityDisplay (Get-Hotpl8ProviderOverview $s $p $now).claude
    Near $d.value (100*0.02/0.3)
    Assert ($null -eq $d.gain)
    $s.slots[0].reset7d=$now.AddHours(2).ToString('o')
    $d=Get-Hotpl8CapacityDisplay (Get-Hotpl8ProviderOverview $s $p $now).claude
    Near ($d.value+$d.gain) 100
}
Check 'unconverted weekly limits gate zero and policy reserve but never cap session percentages directly' {
    $p=Policy;$s=Snapshot;$p.prefer=@(1);$p.PSObject.Properties.Remove('capacity')
    $s.slots[0].used5h=0;$s.slots[0].used7d=98
    $d=Get-Hotpl8CapacityDisplay (Get-Hotpl8ProviderOverview $s $p $now).claude
    Near $d.value 100;Assert ($d.capacity.accounts[0].unconvertedConstraints -contains '10080' -and $d.state.Contains('weekly cap uncertain'))
    $s.slots[0].used7d=100
    Near (Get-Hotpl8CapacityDisplay (Get-Hotpl8ProviderOverview $s $p $now).claude).value 0
    $s.slots[0].used7d=98;$p|Add-Member NoteProperty margin7dWork 5;$p.critical.enabled=$false
    Near (Get-Hotpl8CapacityDisplay (Get-Hotpl8ProviderOverview $s $p $now).claude).value 0
}
Check 'calibrated mixed tiers normalize against session capacity and preserve the same ratio under unit changes' {
    $p=Policy;$s=Snapshot
    Near (Get-Hotpl8CapacityDisplay (Get-Hotpl8ProviderOverview $s $p $now).claude).value 87
    foreach($entry in $p.capacity.PSObject.Properties){$entry.Value.weekly*=10;$entry.Value.fiveHour*=10}
    Near (Get-Hotpl8CapacityDisplay (Get-Hotpl8ProviderOverview $s $p $now).claude).value 87
    $s.slots[0]|Add-Member NoteProperty plan @{status='detected';profile='claude-pro';observedAt=$now.ToString('o')} -Force
    Assert (-not (Get-Hotpl8ProviderOverview $s $p $now).claude.immediate.complete)
    $s.slots[1]|Add-Member NoteProperty plan @{status='detected';profile='claude-max-5x';observedAt=$now.ToString('o')} -Force
    Near (Get-Hotpl8CapacityDisplay (Get-Hotpl8ProviderOverview $s $p $now).claude).value 87
}
Check 'Codex details give two distinct account headers with one availability verdict each' {
    $p=Policy;$s=Snapshot;$first=$s.providers.codex.slots[0];$first.buckets.codex.status='blocked'
    $first.buckets.codex.windows.'10080'.remainingPercent=0;$first.buckets.codex.windows.'10080'.usedPercent=100
    $s.providers.codex.recommendedSlot='personal'
    $s.providers.codex.slots[1].buckets.codex.windows.'10080'.remainingPercent=95
    $text=((Get-Hotpl8DashboardRows $s $p $now 108).text)-join "`n"
    Assert ($text.Contains('Work  [work]') -and $text.Contains('EXHAUSTED') -and $text.Contains('Personal  [personal]') -and $text.Contains('NEXT LAUNCH')) $text
    Assert ($text.Substring($text.IndexOf('CODEX  /')) -notmatch 'MONITORED|Main  /|    Main')
}
'passed='+$script:passed+' failed='+$script:failed
if($script:failed){exit 1}
