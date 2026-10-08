$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($file in @('common','config','collection','management','native')){. (Join-Path $root ('src/'+$file+'.ps1'))}
. (Join-Path $PSScriptRoot 'fixtures/screenshots.ps1')
. (Join-Path $PSScriptRoot 'fixtures/frame.ps1')
$fixture=Get-Hotpl8ScreenshotFixture;$now=$fixture.now
$script:passed=0;$script:failed=0
function Assert($Value,[string]$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check($Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message+' at '+$_.InvocationInfo.ScriptLineNumber}}
function Clone($Value){$Value|ConvertTo-Json -Depth 24|ConvertFrom-Json}
function Policy { $p=Clone $fixture.policy;$p.mode='automate';$p.reserve=@();$p|Add-Member NoteProperty critical @{enabled=$true};return $p }
function Snapshot {Clone $fixture.status}
# What the dashboard says of each provider, as the compiled reader draws it at that width:
# a row naming the provider and a row with its bar, between the title and the accounts.
function Summary($Status,$Policy,[int]$Width=110) {
    $frame=@(Get-Hotpl8TestFrame $Status $Policy $now $Width)
    $rules=@(0..($frame.Count-1)|Where-Object {$frame[$_].StartsWith('├')})
    Assert ($rules.Count -ge 2 -and $rules[1]-$rules[0] -gt 1) ('no summary: '+($frame -join "`n"))
    foreach($row in $frame[($rules[0]+1)..($rules[1]-1)]){Assert ($row.Length -eq $Width) $row;$row}
}
Check 'capacity profile edits are validated and preserve existing action defaults' {
    $p=Set-Hotpl8CapacityProfile $fixture.policy claude 1 claude-pro 1 0.3
    Assert-Hotpl8Policy $p
    Assert ($p.schemaVersion -eq 2 -and -not $p.switchEnabled -and $p.capacity.'1'.weekly -eq 1)
}

# A program that answers as Codex does, with one fictional account.
function New-FakeCodex([string]$Directory){
    $path=Join-Path $Directory 'fake codex.exe'
    Add-Type -Path (Join-Path $root 'tests/fake-codex.cs') -ReferencedAssemblies System.Web.Extensions -OutputAssembly $path -OutputType ConsoleApplication
    return $path
}
Check 'real scheduled tick normalizes sparse failure and retries only when due' {
    $dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-capacity-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dir)
    try{
        $p=@{schemaVersion=2;mode='monitor';prefer=@();codex=@{slots=@(@{id='fixture';home=$dir});defaultMeter='codex'}}
        Write-Hotpl8Text (Join-Path $dir 'policy.json') ($p|ConvertTo-Json -Depth 8)
        Write-Hotpl8Text (Join-Path $dir 'status.json') '{"providers":{"codex":{"status":"collection_failed","slots":[],"recommendedSlot":null}}}'
        # One failed read as the collector records it, with its retry five minutes on.
        $clock=[datetimeoffset]::UtcNow;$deadline=$clock.AddMinutes(5).ToString('o')
        $state=[pscustomobject]@{providers=[pscustomobject]@{codex=[pscustomobject]@{lastAttemptAt=$clock.ToString('o');lastSuccessAt=$null;failures=1;nextAttemptAt=$deadline;status='unavailable'}}}
        Write-Hotpl8Text (Join-Path $dir 'collector.json') ($state|ConvertTo-Json -Depth 8)
        foreach($attempt in 1..2){
            # No such program: a read during the wait would be a second failure and a new deadline.
            & (Join-Path $root 'tick.ps1') -StateDirectory $dir -Scheduled -ObserveOnly -CodexExecutable (Join-Path $dir 'no-codex.exe')
            $after=Read-Hotpl8Json (Join-Path $dir 'collector.json')
            Assert ($after.providers.codex.failures -eq 1 -and $after.providers.codex.nextAttemptAt -eq $deadline)
        }
        $after.providers.codex.nextAttemptAt=$clock.AddSeconds(-1).ToString('o')
        Write-Hotpl8Text (Join-Path $dir 'collector.json') ($after|ConvertTo-Json -Depth 8)
        & (Join-Path $root 'tick.ps1') -StateDirectory $dir -Scheduled -ObserveOnly -CodexExecutable (New-FakeCodex $dir)
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
        $codex=New-FakeCodex $dir
        & (Join-Path $root 'tick.ps1') -StateDirectory $dir -ObserveOnly -CodexExecutable $codex
        $before=Read-Hotpl8Json (Join-Path $dir 'status.json')
        $handle=[IO.File]::Open((Join-Path $dir 'codex-state.json'),'Open','Read','ReadWrite')
        & (Join-Path $root 'tick.ps1') -StateDirectory $dir -ObserveOnly -CodexExecutable $codex
        $after=Read-Hotpl8Json (Join-Path $dir 'status.json');$c=Read-Hotpl8Json (Join-Path $dir 'collector.json')
        Assert ($after.providers.codex.failureCode -eq 'state_io_failed' -and $null -eq $after.providers.codex.recommendedSlot)
        Assert ($after.providers.codex.slots[0].observedAt -eq $before.providers.codex.slots[0].observedAt)
        $provider=$c.providers.codex
        Assert (([datetimeoffset]::Parse($provider.nextAttemptAt)-[datetimeoffset]::Parse($provider.lastAttemptAt)).TotalSeconds -eq 60)
        & (Join-Path $root 'tick.ps1') -StateDirectory $dir -Scheduled -ObserveOnly -CodexExecutable $codex
        $waiting=(Read-Hotpl8Json (Join-Path $dir 'collector.json')).providers.codex
        Assert ($waiting.lastAttemptAt -eq $provider.lastAttemptAt -and $waiting.nextAttemptAt -eq $provider.nextAttemptAt -and $waiting.failures -eq $provider.failures) 'a wake inside the wait reads nothing'
        $handle.Dispose();$handle=$null
        $c.providers.codex.nextAttemptAt=[datetimeoffset]::UtcNow.AddSeconds(-1).ToString('o')
        Write-Hotpl8Text (Join-Path $dir 'collector.json') ($c|ConvertTo-Json -Depth 8)
        & (Join-Path $root 'tick.ps1') -StateDirectory $dir -Scheduled -ObserveOnly -CodexExecutable $codex
        $recovered=Read-Hotpl8Json (Join-Path $dir 'status.json')
        Assert ($recovered.providers.codex.slots[0].status -eq 'ok' -and -not $recovered.collector.providers.codex.failureCode)
        $handle=[IO.File]::Open((Join-Path $dir 'status.js'),'Open','Read','ReadWrite')
        & (Join-Path $root 'tick.ps1') -StateDirectory $dir -ObserveOnly -CodexExecutable $codex
        $mirrored=Read-Hotpl8Snapshot $dir
        Assert ($mirrored.collector.status -eq 'ok' -and $mirrored.providers.codex.slots[0].status -eq 'ok') 'a locked compatibility mirror must not break the primary snapshot'
        $handle.Dispose();$handle=$null
        $p.historyEnabled=$true
        Write-Hotpl8Text (Join-Path $dir 'policy.json') ($p|ConvertTo-Json -Depth 8)
        Write-Hotpl8Text (Join-Path $dir 'usage-history.json') '{"samples":[]}'
        $handle=[IO.File]::Open((Join-Path $dir 'usage-history.json'),'Open','Read','ReadWrite')
        & (Join-Path $root 'tick.ps1') -StateDirectory $dir -ObserveOnly -CodexExecutable $codex
        $withHistory=Read-Hotpl8Snapshot $dir
        Assert ($withHistory.generationId -ne $mirrored.generationId -and $withHistory.collector.status -eq 'ok') 'optional history cannot block a fresh snapshot'
        $handle.Dispose();$handle=$null
        Write-Hotpl8Text (Join-Path $dir 'activity.json') '{"events":[]}'
        # A recommendation that differs from the last one recorded is an event to write down.
        $stored=Read-Hotpl8Json (Join-Path $dir 'status.json');$stored.providers.codex.recommendedSlot='another'
        Write-Hotpl8Text (Join-Path $dir 'status.json') ($stored|ConvertTo-Json -Depth 24)
        $handle=[IO.File]::Open((Join-Path $dir 'activity.json'),'Open','Read','ReadWrite')
        & (Join-Path $root 'tick.ps1') -StateDirectory $dir -ObserveOnly -CodexExecutable $codex
        $withActivity=Read-Hotpl8Snapshot $dir
        Assert ($withActivity.generationId -ne $withHistory.generationId -and $withActivity.providerOverview -and $withActivity.collector.status -eq 'ok') 'activity output cannot invalidate the current observation'
        $handle.Dispose();$handle=$null
        $events=@(Get-Content -LiteralPath (Join-Path $dir 'events.jsonl')|ForEach-Object {$_|ConvertFrom-Json})
        Assert ('history_output_failed' -in $events.code -and 'activity_output_failed' -in $events.code) 'optional write failures remain diagnosable'
    }finally{
        if($handle){$handle.Dispose()}
        $full=[IO.Path]::GetFullPath($dir)
        if((Split-Path $full -Parent) -eq [IO.Path]::GetTempPath().TrimEnd('\','/') -and (Split-Path $full -Leaf) -match '^hotpl8-storage-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
    }
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
Check 'detected plan weights estimate current session allowance without inventing conversions' {
    $p=Policy;$s=Snapshot;$p.PSObject.Properties.Remove('capacity')
    foreach($slot in $s.slots){$slot|Add-Member NoteProperty plan @{status='detected';profile='claude-pro';observedAt=$now.ToString('o')} -Force}
    $s.slots[1].plan.profile='claude-max-5x'
    $s.slots[0].used5h=100;$s.slots[0].used7d=10
    $s.slots[1].used5h=50;$s.slots[1].used7d=10
    $text=(Summary $s $p)-join "`n"
    Assert ($text.Contains('~42% now') -and $text.Contains('7d 90%') -and -not $text.Contains('Weekly remaining'))
}
Check 'equal Codex plans with one switched off show the other alone' {
    $p=Clone $fixture.policy;$s=Snapshot
    foreach($id in @('work','personal')){$p.codex.capacity.$id.weekly=1}
    foreach($slot in $s.providers.codex.slots){$slot.buckets.codex.windows.PSObject.Properties.Remove('300')}
    $s.providers.codex.slots[0].buckets.codex.windows.'10080'.remainingPercent=95
    $s.providers.codex.slots[0].buckets.codex.windows.'10080'.usedPercent=5
    $s.providers.codex.slots[1].buckets.codex.status='blocked'
    $s.providers.codex.slots[1].buckets.codex.windows.'10080'.remainingPercent=0
    $s.providers.codex.slots[1].buckets.codex.windows.'10080'.usedPercent=100
    $p.codex|Add-Member NoteProperty disabled @('personal') -Force
    $text=(Summary $s $p)-join "`n"
    Assert ($text.Contains('95% now') -and $text.Contains('next: Work') -and -not $text.Contains('1 off'))
}
Check 'hatching means refill only and is contiguous with the measured fill at every viewport' {
    $p=Policy;$s=Snapshot;$p.PSObject.Properties.Remove('capacity')
    foreach($slot in $s.slots){$slot|Add-Member NoteProperty plan @{status='detected';profile='claude-pro';observedAt=$now.ToString('o')} -Force;$slot.used5h=60;$slot.used7d=20}
    foreach($width in @(48,79,110)){
        $rows=@(Summary $s $p $width)
        Assert ($rows[1] -match '\[█+[▏▎▍▌▋▊▉]?▒+·*\]' -and $rows[1].Contains('% in '))
    }
    # One unreadable account leaves a measured bar, with or without plan weights;
    # the problem belongs on its account row, not in the header.
    $p=Policy;$s.slots[0].observedAt=$now.AddHours(-1).ToString('o')
    $rows=@(Summary $s $p)
    Assert ($rows[1] -match '\d+% now' -and -not $rows[1].Contains('? now') -and -not $rows[0].Contains('read'))
    $p.PSObject.Properties.Remove('capacity')
    $rows=@(Summary $s $p)
    Assert ($rows[1] -match '\d+% now' -and -not $rows[1].Contains('? now') -and -not $rows[0].Contains('read'))
}
Check 'refill horizon includes 24h exactly and excludes a second later' {
    $p=Policy;$s=Snapshot
    foreach($slot in $s.slots){$slot.reset5h=$now.AddHours(24).ToString('o')}
    Assert (@(Summary $s $p)[1] -match '▒')
    foreach($slot in $s.slots){$slot.reset5h=$now.AddHours(24).AddSeconds(1).ToString('o')}
    Assert (@(Summary $s $p)[1] -notmatch '▒')
}
Check 'no account read leaves no figure for now' {
    $p=Policy;$s=Snapshot;$s.providers.codex.slots[0].status='timeout';$s.providers.codex.slots[0].observedAt=$now.AddHours(-2).ToString('o')
    foreach($slot in $s.slots){$slot.observedAt=$now.AddHours(-2).ToString('o')}
    Assert (@(Summary $s $p)[1] -notmatch '% now')
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
        $rows=@(Summary $s $p $width)
        $codex=$rows[3]
        Assert ($codex.Contains('~24% now')) $codex
        Assert ($codex.Contains('+50% in ')) $codex
        Assert (-not $codex.Contains('7d') -and $codex -notmatch '[░▒]') $codex
        # Claude still carries its distinct weekly figure wherever there is room for it.
        if($width -ge 79){Assert ($rows[1] -match '7d\s+\d') $rows[1]}
    }
}
Check 'Codex details give two distinct account headers with one availability verdict each' {
    $p=Policy;$s=Snapshot;$first=$s.providers.codex.slots[0];$first.buckets.codex.status='blocked'
    $first.buckets.codex.windows.'10080'.remainingPercent=0;$first.buckets.codex.windows.'10080'.usedPercent=100
    $s.providers.codex.recommendedSlot='personal'
    $s.providers.codex.slots[1].buckets.codex.windows.'10080'.remainingPercent=95
    $s.providers.codex.slots[1].buckets.codex.windows.'10080'.usedPercent=5
    $text=@(Get-Hotpl8TestFrame $s $p $now)-join "`n"
    Assert ($text.Contains('Work  [work]') -and $text.Contains('EXHAUSTED') -and $text.Contains('Personal  [personal]') -and $text.Contains('NEXT LAUNCH')) $text
    Assert ($text.Substring($text.IndexOf('CODEX  /')) -notmatch 'MONITORED|Main  /|    Main')
}
'passed='+$script:passed+' failed='+$script:failed
if($script:failed){exit 1}
