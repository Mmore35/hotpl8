$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/insights.ps1')
. (Join-Path $root 'src/dashboard.ps1')
. (Join-Path $root 'src/tray.ps1')
$now=[datetimeoffset]::Parse('2026-09-13T12:00:00Z')
$p=@{prefer=@(1,2,3);reserve=@(3);mode='automate';margin5h=20;margin7d=10;margin7dWork=5;codex=@{slots=@(@{id='main'});prefer=@('main');defaultMeter='codex';margin7d=5}}|ConvertTo-Json -Depth 9|ConvertFrom-Json
$s=@{generatedAt=$now.ToString('o');active=1;slots=@(1..3|ForEach-Object {@{slot=$_;status='ok';fresh=$true;streamKey=('fictional-'+$_);observedAt=$now.ToString('o');used5h=10;used7d=($_-1)*50;reset5h=$now.AddHours(1).ToString('o');reset7d=$now.AddDays(2).ToString('o')}});providers=@{codex=@{recommendedSlot='main';slots=@(@{id='main';status='ok';observedAt=$now.ToString('o');buckets=@{codex=@{status='observed';windows=@{'10080'=@{usedPercent=20;remainingPercent=80;anchorState='observed-active';resetsAt=$now.AddDays(2).ToUnixTimeSeconds()}}}}})}}}|ConvertTo-Json -Depth 15|ConvertFrom-Json
$script:passed=0;$script:failed=0
function Assert($Value){if(-not $Value){throw 'assertion failed'}}
function Check($Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message}}
function Copy-Value($Value){$Value|ConvertTo-Json -Depth 24|ConvertFrom-Json}
Check 'fixed membership averages full, half and exhausted accounts' {
    $o=Get-Hotpl8ProviderOverview $s $p $now
    Assert ($o.claude.accounts -eq 3 -and $o.claude.remainingPercent -eq 50 -and $o.claude.includesReserve)
    Assert ($o.codex.remainingPercent -eq 80 -and $o.codex.availability -eq 'Ready for next launch')
}
Check 'all full and all empty are distinct from unknown' {
    $c=Copy-Value $s;foreach($a in $c.slots){$a.used7d=0}
    Assert ((Get-Hotpl8ProviderOverview $c $p $now).claude.remainingPercent -eq 100)
    foreach($a in $c.slots){$a.used7d=100}
    $o=(Get-Hotpl8ProviderOverview $c $p $now).claude
    Assert ($o.remainingPercent -eq 0 -and $o.availability -like 'Unavailable*' -and $o.unknownPercent -eq 0)
}
Check 'failed readings retain membership and unknown share' {
    $c=Copy-Value $s;$c.slots[1].status='authentication_required'
    $o=(Get-Hotpl8ProviderOverview $c $p $now).claude
    Assert ($o.accounts -eq 3 -and $o.measured -eq 2 -and $null -eq $o.remainingPercent)
    Assert ([Math]::Abs($o.unknownPercent-100/3) -lt 0.001 -and [Math]::Abs($o.knownRemainingPercent-100/3) -lt 0.001)
}
Check 'stale and elapsed windows never refill or imply readiness' {
    $o=Get-Hotpl8ProviderOverview $s $p $now.AddHours(4)
    Assert ($o.claude.unknownPercent -eq 100 -and $o.codex.unknownPercent -eq 100)
    $c=Copy-Value $s;foreach($a in $c.slots){$a.reset7d=$now.AddSeconds(-1).ToString('o')}
    Assert ((Get-Hotpl8ProviderOverview $c $p $now).claude.measured -eq 0)
    $c.providers.codex.slots[0].buckets.codex.windows.'10080'.anchorState='unconfirmed'
    Assert ((Get-Hotpl8ProviderOverview $c $p $now).codex.measured -eq 1)
}
Check 'all missing, malformed percentages and unconfigured accounts are unknown' {
    $o=Get-Hotpl8ProviderOverview $null $p $now
    Assert ($o.claude.accounts -eq 3 -and $o.claude.measured -eq 0)
    $c=Copy-Value $s;$c.slots[0].used7d=-1;$c.slots[1].used7d='bad';$c.slots[2].used7d=101
    Assert ((Get-Hotpl8ProviderOverview $c $p $now).claude.measured -eq 0)
    Assert ((Get-Hotpl8ProviderOverview $null $null $now).codex.availability -eq 'No accounts enabled')
}
Check 'disabled policy changes immediately change membership without collecting' {
    $policy=Copy-Value $p;$policy|Add-Member NoteProperty disabled @(1)
    $o=(Get-Hotpl8ProviderOverview $s $policy $now).claude
    Assert ($o.accounts -eq 2 -and $o.remainingPercent -eq 25 -and $o.disabled -eq 1)
}
Check 'known duplicate identity cannot inflate headroom' {
    $c=Copy-Value $s;$c.slots[1].streamKey=$c.slots[0].streamKey;$c.slots[1].used7d=0
    $o=(Get-Hotpl8ProviderOverview $c $p $now).claude
    Assert ($o.accounts -eq 2 -and $o.duplicates -eq 1 -and $o.remainingPercent -eq 50)
}
Check 'short-window exhaustion preserves weekly inventory but blocks readiness' {
    $c=Copy-Value $s;foreach($a in $c.slots){$a.used5h=100;$a.used7d=10}
    $o=(Get-Hotpl8ProviderOverview $c $p $now).claude
    Assert ($o.remainingPercent -eq 90 -and $o.availability -like 'Unavailable*')
}
Check 'new model constraints re-evaluate cached scope observations' {
    $policy=Copy-Value $p;$policy|Add-Member NoteProperty claudeModels @('opus')
    $o=(Get-Hotpl8ProviderOverview $s $policy $now).claude
    Assert ($o.availability -like 'Unavailable*' -and $o.members[0].reason -eq 'model_quota_unknown')
    $c=Copy-Value $s;$c.slots[0]|Add-Member NoteProperty scoped @(@{name='opus';pct=5;resetsAt=$now.AddDays(1).ToString('o')})
    Assert ((Get-Hotpl8ProviderOverview $c $policy $now).claude.availability -eq 'Ready')
}
Check 'pause and monitor status never claim automatic routing' {
    $c=Copy-Value $s;$c|Add-Member NoteProperty automationPause @{until=$now.AddHours(1).ToString('o')}
    Assert ((Get-Hotpl8ProviderOverview $c $p $now).claude.automation -eq 'automation paused')
    Assert (((Get-Hotpl8DashboardFrame $c $p $now 50 18).text -join '') -match 'automation paused')
    $policy=Copy-Value $p;$policy.mode='monitor'
    Assert ((Get-Hotpl8ProviderOverview $s $policy $now).claude.automation -eq 'monitor only')
}
Check 'held unavailable current account does not claim usable automatic selection' {
    $c=Copy-Value $s;$c.slots[0].used5h=100;$c|Add-Member NoteProperty hold @{until=$now.AddHours(1).ToString('o')}
    $o=(Get-Hotpl8ProviderOverview $c $p $now).claude
    Assert ($o.availability -like '*manual selection needed' -and $o.automation -eq 'rotation held')
}
Check 'meters never combine and unknown configured scope stays unknown' {
    $policy=Copy-Value $p;$policy.codex.defaultMeter='codex_bengalfox'
    $o=(Get-Hotpl8ProviderOverview $s $policy $now).codex
    Assert ($o.measured -eq 0 -and $o.availability -like 'Unavailable*')
}
Check 'collector and sign-in failures remain visible in the overview' {
    $c=Copy-Value $s;$c|Add-Member NoteProperty collector @{startedAt=$now.AddMinutes(-8).ToString('o')}
    $c.slots[1].status='authentication_required'
    $o=Get-Hotpl8ProviderOverview $c $p $now
    Assert ($o.claude.availability -like '*sign-in needed*' -and $o.claude.availability -like '*collector stalled*')
    Assert ($o.codex.availability -like '*collector stalled*')
}
Check 'summary and view are pure, shared with tray, and pinned when scrolling' {
    $before=$s|ConvertTo-Json -Depth 24 -Compress
    $overview=Get-Hotpl8ProviderOverview $s $p $now
    $tray=Get-Hotpl8TrayModel $s $p $now
    Assert ($tray.providerOverview.claude.remainingPercent -eq $overview.claude.remainingPercent)
    $first=@(Get-Hotpl8DashboardFrame $s $p $now 79 23 0)
    $last=@(Get-Hotpl8DashboardFrame $s $p $now 79 23 999)
    Assert (($first[4..11].text -join '') -eq ($last[4..11].text -join ''))
    Assert (($s|ConvertTo-Json -Depth 24 -Compress) -eq $before)
    Assert (($first.text -join '') -match 'CLAUDE / Weekly remaining' -and ($first.text -join '') -match 'CODEX / Available')
}
Check 'CLI status and explain re-evaluate policy and clock without collecting' {
    $dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-overview-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dir)
    try {
        $policy=Copy-Value $p;$policy|Add-Member NoteProperty schemaVersion 2;$policy|Add-Member NoteProperty disabled @(1)
        $c=Copy-Value $s;$c|Add-Member NoteProperty providerOverview @{claude=@{accounts=99;remainingPercent=100}}
        foreach($a in $c.slots){$a.observedAt=[datetimeoffset]::UtcNow.AddHours(-1).ToString('o')}
        Write-Hotpl8Text (Join-Path $dir 'policy.json') ($policy|ConvertTo-Json -Depth 24)
        Write-Hotpl8Text (Join-Path $dir 'status.json') ($c|ConvertTo-Json -Depth 24)
        Write-Hotpl8Text (Join-Path $dir 'automation-pause.json') (@{until=[datetimeoffset]::UtcNow.AddHours(1).ToString('o');reason='test'}|ConvertTo-Json)
        $before=(Get-FileHash (Join-Path $dir 'status.json')).Hash
        foreach($command in @('status','explain')){
            $output=& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'hotpl8.ps1') $command -StateDirectory $dir -AsJson
            Assert ($LASTEXITCODE -eq 0)
            $o=($output|ConvertFrom-Json).providerOverview.claude
            Assert ($o.accounts -eq 2 -and $o.measured -eq 0 -and $null -eq $o.remainingPercent -and $o.automation -eq 'automation paused')
        }
        Assert ((Get-FileHash (Join-Path $dir 'status.json')).Hash -eq $before)
        Assert (@(Get-ChildItem $dir -File).Count -eq 3)
    }finally{
        $full=[IO.Path]::GetFullPath($dir)
        if((Split-Path $full -Parent) -eq [IO.Path]::GetTempPath().TrimEnd('\','/') -and (Split-Path $full -Leaf) -match '^hotpl8-overview-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
    }
}
'passed='+$script:passed+' failed='+$script:failed
if($script:failed){exit 1}
