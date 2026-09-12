$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'providers/codex.ps1')
. (Join-Path $PSScriptRoot 'dashboard.ps1')
$now=[datetimeoffset]::Parse('2026-09-10T12:00:00Z')
$p=@{prefer=@(1,2,3);reserve=@(1);labels=@{'1'='reserve';'2'='work';'3'='work2'};codex=@{slots=@(@{id='main';label='Main'});defaultMeter='codex'}}|ConvertTo-Json -Depth 5|ConvertFrom-Json
$s=@{generatedAt=$now.ToString('o');active=3;slots=@(1..3|ForEach-Object{@{slot=$_;label='Claude '+$_;status='ok';active=($_ -eq 3);fresh=$true;used5h=25;used7d=50;reset5h=$now.AddHours(2).ToString('o');reset7d=$now.AddDays(2).ToString('o')}});providers=@{codex=@{defaultMeter='codex';recommendedSlot='main';slots=@(@{id='main';label='Main';status='ok';observedAt=$now.ToString('o');buckets=@{codex=@{status='observed';windows=@{'10080'=@{usedPercent=35;remainingPercent=65;resetsAt=$now.AddDays(3).ToUnixTimeSeconds();anchorState='observed-active'}}};codex_bengalfox=@{status='constraint_unknown';windows=@{'300'=@{usedPercent=0;remainingPercent=100;resetsAt=$now.AddHours(5).ToUnixTimeSeconds();anchorState='unconfirmed'}}}}})}}}|ConvertTo-Json -Depth 15|ConvertFrom-Json
$script:passed=0;$script:failed=0
function Assert($Value){if(-not $Value){throw 'assertion failed'}}
function Check([string]$Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message}}
function Copy-Value($Value){$Value|ConvertTo-Json -Depth 20|ConvertFrom-Json}
function Render($Value=$s,[int]$Width=100,[int]$Height=100,[int]$Offset=0){@(Get-Hotpl8DashboardFrame $Value $p $now $Width $Height $Offset)}
Check 'all accounts and separate main/Spark meters are displayed' {
    $t=((Render).text)-join "`n"
    Assert ($t.Contains('3 subscriptions') -and $t.Contains('1 subscription'))
    foreach($name in @('Claude 1','Claude 2','Claude 3','NEXT LAUNCH','ACTIVE','Spark','limit status unknown','no five-hour window')){Assert ($t.Contains($name))}
    Assert ($t.Contains('75% left') -and $t.Contains('65% left'))
    Assert ($t.IndexOf('    Main') -lt $t.IndexOf('    Spark'))
}
Check 'missing readings never become full balances or hide configured accounts' {
    $t=((Render $null).text)-join "`n"
    Assert ($t.Contains('reserve') -and $t.Contains('Main') -and $t.Contains('NO OBSERVATION'))
    Assert (-not $t.Contains('100% left'))
}
Check 'stale and exhausted Codex accounts never show next launch' {
    $c=Copy-Value $s;$c.providers.codex.slots[0].observedAt=$now.AddHours(-1).ToString('o')
    $t=((Render $c).text)-join "`n";Assert ($t.Contains('STALE') -and -not $t.Contains('NEXT LAUNCH'))
    $c=Copy-Value $s;$c.providers.codex.slots[0].buckets.codex.windows.'10080'.remainingPercent=0
    Assert (-not (((Render $c).text)-join "`n").Contains('NEXT LAUNCH'))
}
Check 'elapsed resets await observation and unconfirmed resets are not countdowns' {
    Assert ((Format-DashboardReset $now.AddSeconds(-1).ToString('o') $now) -eq 'reset awaiting update')
    Assert ((Format-DashboardReset $now.AddHours(1).ToUnixTimeSeconds() $now -Unix -Unconfirmed) -eq 'reset not confirmed')
    Assert ((Format-DashboardDuration 3599) -eq '59m 59s')
}
Check 'narrow frames and a scrolled last page fit their viewport' {
    foreach($width in @(50,79,100,110)){
        foreach($offset in @(0,999)){
            $rows=Render $s $width 18 $offset
            Assert ($rows.Count -le 18)
            foreach($row in $rows){Assert ((Get-DashboardCells $row.text) -eq $width)}
        }
    }
    Assert ((((Render $s 79 18 999).text)-join "`n").Contains('Spark'))
}
Check 'standard 80-column terminal shows both providers and Spark without scrolling' {
    $rows=Render $s 79 23
    $text=$rows.text -join "`n"
    Assert ($rows.Count -le 23 -and $text.Contains('65% left') -and $text.Contains('Spark'))
}
Check 'tiny resized terminals show a bounded recovery hint' {
    $rows=Render $s 15 4
    Assert ($rows.Count -le 4)
    foreach($row in $rows){Assert ((Get-DashboardCells $row.text) -eq 15)}
    Assert (($rows.text -join '').Contains('hotpl8'))
}
Check 'labels cannot emit terminal controls; wide labels keep borders aligned' {
    $c=Copy-Value $s;$c.slots[0].label=([string][char]27)+'[2J'+"`r`n"+'中文 cafe'
    $rows=Render $c 50 100
    foreach($row in $rows){Assert ((Get-DashboardCells $row.text) -eq 50);Assert ($row.text -notmatch '[\x00-\x1f\x7f]')}
}
Check 'opening through a pipe returns one plain frame without changing cache' {
    $dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-view-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dir)
    try {
        Write-Hotpl8Text (Join-Path $dir 'status.json') ($s|ConvertTo-Json -Depth 20)
        Write-Hotpl8Text (Join-Path $dir 'policy.json') ($p|ConvertTo-Json -Depth 10)
        $before=(Get-FileHash (Join-Path $dir 'status.json')).Hash
        $out=& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'hotpl8.ps1') -StateDirectory $dir
        Assert ($LASTEXITCODE -eq 0 -and ($out -join "`n").Contains('hotpl8'))
        Assert ((Get-FileHash (Join-Path $dir 'status.json')).Hash -eq $before)
        Assert (@(Get-ChildItem $dir -File).Count -eq 2)
    } finally {
        if([IO.Path]::GetFullPath($dir).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){[IO.Directory]::Delete($dir,$true)}
    }
}
'passed='+$script:passed+' failed='+$script:failed
if($script:failed){exit 1}
