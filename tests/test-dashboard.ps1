$root = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference='Stop'
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/providers/codex.ps1')
. (Join-Path $root 'src/dashboard.ps1')
$now=[datetimeoffset]::Parse('2026-09-10T12:00:00Z')
$p=@{prefer=@(1,2,3);reserve=@(1);labels=@{'1'='reserve';'2'='work';'3'='work2'};codex=@{slots=@(@{id='main';label='Main'});defaultMeter='codex'}}|ConvertTo-Json -Depth 5|ConvertFrom-Json
$s=@{generatedAt=$now.ToString('o');active=3;slots=@(1..3|ForEach-Object{@{slot=$_;label='Claude '+$_;status='ok';active=($_ -eq 3);fresh=$true;used5h=25;used7d=50;reset5h=$now.AddHours(2).ToString('o');reset7d=$now.AddDays(2).ToString('o')}});providers=@{codex=@{defaultMeter='codex';recommendedSlot='main';slots=@(@{id='main';label='Main';status='ok';observedAt=$now.ToString('o');buckets=@{codex=@{status='observed';windows=@{'10080'=@{usedPercent=35;remainingPercent=65;resetsAt=$now.AddDays(3).ToUnixTimeSeconds();anchorState='observed-active'}}};codex_bengalfox=@{status='constraint_unknown';windows=@{'300'=@{usedPercent=0;remainingPercent=100;resetsAt=$now.AddHours(5).ToUnixTimeSeconds();anchorState='unconfirmed'}}}}})}}}|ConvertTo-Json -Depth 15|ConvertFrom-Json
$script:passed=0;$script:failed=0
function Assert($Value){if(-not $Value){throw 'assertion failed'}}
function Check([string]$Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message}}
function Copy-Value($Value){$Value|ConvertTo-Json -Depth 20|ConvertFrom-Json}
function Render($Value=$s,[int]$Width=100,[int]$Height=100,[int]$Offset=0){@(Get-Hotpl8DashboardFrame $Value $p $now $Width $Height $Offset)}
Check 'empty policy has enrollment and refresh guidance without implying a running collector' {
    $empty=@{mode='monitor';prefer=@();codex=@{slots=@()}}|ConvertTo-Json -Depth 4|ConvertFrom-Json
    $text=((Get-Hotpl8DashboardFrame $null $empty $now 80 24).text)-join "`n"
    Assert ($text.Contains('hotpl8 enroll') -and $text.Contains('hotpl8 refresh'))
    Assert ($text.Contains('no reading') -and -not $text.Contains('LIVE') -and -not $text.Contains('every 5m'))
}
Check 'stale and failed readings offer a recovery action' {
    $c=Copy-Value $s;$c.generatedAt=$now.AddHours(-1).ToString('o');$c.slots[0].status='authentication_required'
    $text=((Render $c).text)-join "`n"
    Assert ($text.Contains('hotpl8 refresh') -and $text.Contains('hotpl8 doctor') -and $text.Contains('SIGN-IN NEEDED'))
}
Check 'all accounts remain visible while Spark is excluded from the dashboard' {
    $t=((Render).text)-join "`n"
    Assert ($t.Contains('3 subscriptions') -and $t.Contains('1 subscription'))
    foreach($name in @('Claude 1','Claude 2','Claude 3','NEXT LAUNCH','ACTIVE')){Assert ($t.Contains($name))}
    Assert ($t -match '5h\s+\S+\s+75%' -and $t -match '7d\s+\S+\s+65%')
    Assert ($t.Contains('Main  [main]') -and -not $t.Contains('    Main') -and -not $t.Contains('Spark'))
}
Check 'missing readings never become full balances or hide configured accounts' {
    $t=((Render $null).text)-join "`n"
    Assert ($t.Contains('reserve') -and $t.Contains('Main') -and $t.Contains('NO OBSERVATION'))
    Assert ($t -notmatch '\s100%')
}
Check 'stale and exhausted Codex accounts never show next launch' {
    $c=Copy-Value $s;$c.providers.codex.slots[0].observedAt=$now.AddHours(-1).ToString('o')
    $t=((Render $c).text)-join "`n";Assert ($t.Contains('STALE') -and -not $t.Contains('NEXT LAUNCH'))
    $c=Copy-Value $s;$c.providers.codex.slots[0].buckets.codex.windows.'10080'.remainingPercent=0
    Assert (-not (((Render $c).text)-join "`n").Contains('NEXT LAUNCH'))
}
Check 'elapsed resets await observation and unconfirmed resets are not countdowns' {
    Assert ((Format-DashboardReset $now.AddSeconds(-1).ToString('o') $now) -eq 'reset due')
    Assert ((Format-DashboardReset $now.AddHours(1).ToUnixTimeSeconds() $now -Unix -Unconfirmed) -eq 'reset unconfirmed')
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
    Assert ((((Render $s 79 18 999).text)-join "`n") -match '7d\s+\S+\s+65%')
}
Check 'standard terminal prioritizes both provider summaries above account details' {
    $rows=Render $s 79 23
    $text=$rows.text -join "`n"
    Assert ($rows.Count -le 23 -and $text -match '(?m)^│  CLAUDE\s' -and $text -match '(?m)^│  CODEX\s' -and $text.Contains('% now'))
    Assert ($text.IndexOf('│  CLAUDE ') -lt $text.IndexOf('│  CODEX ') -and $text.IndexOf('│  CODEX ') -lt $text.IndexOf('CLAUDE  /'))
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
        $out=& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'hotpl8.ps1') -StateDirectory $dir
        Assert ($LASTEXITCODE -eq 0 -and ($out -join "`n").Contains('hotpl8'))
        Assert (-not ($out -join "`n").Contains('PREVIEW POLICY'))
        foreach($command in @('watch','nyan','status')){
            $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'hotpl8.ps1'),$command,'-StateDirectory',$dir)
            if($command -eq 'status'){$args+='-AsJson'}
            $normal=& powershell @args
            Assert ($LASTEXITCODE -eq 0)
            $preview=& powershell @args -PreviewPolicy (Join-Path $dir 'policy.json')
            Assert ($LASTEXITCODE -eq 0)
            if($command -eq 'status'){
                Assert (-not (($normal -join "`n"|ConvertFrom-Json).displayPolicy))
                Assert (($preview -join "`n"|ConvertFrom-Json).displayPolicy)
            }else{
                Assert (-not ($normal -join "`n").Contains('PREVIEW POLICY'))
                Assert (($preview -join "`n").Contains('PREVIEW POLICY'))
            }
        }
        Assert ((Get-FileHash (Join-Path $dir 'status.json')).Hash -eq $before)
        Assert (@(Get-ChildItem $dir -File).Count -eq 2)
    } finally {
        if([IO.Path]::GetFullPath($dir).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){[IO.Directory]::Delete($dir,$true)}
    }
}
Check 'disabled Codex login never presents cached percentages as its current balance' {
    $c=Copy-Value $s;$c.providers.codex.slots[0].status='disabled'
    $text=((Render $c).text)-join "`n"
    Assert ($text.Contains('Main  [main]  ·  DISABLED'))
    Assert ($text -notmatch '7d\s+\S+\s+65%' -and -not $text.Contains('NEXT LAUNCH'))
}
Check 'three Claude accounts with verbose metadata cannot hide the usable second Codex account in a standard terminal' {
    $c=Copy-Value $s;$policy=Copy-Value $p
    $policy.codex.slots+=@([pscustomobject]@{id='work';label='Work'})
    $work=Copy-Value $c.providers.codex.slots[0];$work.id='work';$work.label='Work'
    $work.buckets.codex.windows.'10080'.usedPercent=22;$work.buckets.codex.windows.'10080'.remainingPercent=78
    $c.providers.codex.slots+=@($work);$c.providers.codex.recommendedSlot='work'
    $main=$c.providers.codex.slots[0];$main.buckets.codex.status='blocked'
    $main.buckets.codex.windows.'10080'.usedPercent=100;$main.buckets.codex.windows.'10080'.remainingPercent=0
    foreach($slot in $c.slots){
        $slot|Add-Member NoteProperty warmOutcome @{outcome='observed-active'}
        $slot|Add-Member NoteProperty actionBlock 'outside_work_hours'
        $slot|Add-Member NoteProperty modelBlock 'model_below_margin'
    }
    foreach($width in @(79,110)){
        $frame=@(Get-Hotpl8DashboardFrame $c $policy $now $width 40)
        $text=$frame.text -join "`n"
        Assert ($text.Contains('Main  [main]') -and $text.Contains('EXHAUSTED'))
        Assert ($text.Contains('Work  [work]') -and $text.Contains('NEXT LAUNCH') -and $text -match '7d\s+\S+\s+78%')
        Assert ($frame.Count -le 40)
        foreach($row in $frame){Assert ((Get-DashboardCells $row.text) -eq $width)}
    }
    $last=@(Get-Hotpl8DashboardFrame $c $policy $now 79 24 999)
    Assert (($last.text -join "`n").Contains('Work  [work]'))
    Assert (($last.text -join "`n") -match '7d\s+\S+\s+78%')
    # Replay controller offsets, including its saved position on the next redraw.
    # At 21 rows the old controller stopped short of the last page.
    foreach($nyan in @($false,$true)){
        $height=if($nyan){28}else{21}
        $offset=0
        for($press=0;$press -lt 25;$press++){
            $offset=Move-Hotpl8DashboardScroll $offset 'DownArrow'
            $last=@(Get-Hotpl8DashboardFrame $c $policy $now 79 $height $offset -Nyan:$nyan -ResolvedOffset ([ref]$offset))
        }
        $text=$last.text -join "`n"
        Assert ($text -match '7d\s+\S+\s+78%' -and $text -match '-15/15\]')
        if(-not $nyan){Assert ($text.Contains('[6-15/15]') -and $offset -eq 5)}
        $offset=Move-Hotpl8DashboardScroll $offset 'End'
        $offset=Move-Hotpl8DashboardScroll $offset 'DownArrow'
        $offset=Move-Hotpl8DashboardScroll $offset 'PageDown'
        $last=@(Get-Hotpl8DashboardFrame $c $policy $now 79 $height $offset -Nyan:$nyan -ResolvedOffset ([ref]$offset))
        Assert (($last.text -join "`n") -match '7d\s+\S+\s+78%' -and $offset -lt 15)
        $offset=Move-Hotpl8DashboardScroll $offset 'UpArrow'
        $last=@(Get-Hotpl8DashboardFrame $c $policy $now 79 $height $offset -Nyan:$nyan -ResolvedOffset ([ref]$offset))
        Assert (($last.text -join "`n") -notmatch '-15/15\]')
    }
    $offset=10
    $null=@(Get-Hotpl8DashboardFrame $c $policy $now 110 40 $offset -ResolvedOffset ([ref]$offset))
    Assert ($offset -eq 0)
    $offset=Move-Hotpl8DashboardScroll $offset 'PageUp'
    Assert ($offset -eq 0)
}
Check 'Claude detail marks an expired per-account observation stale despite a fresh collector tick' {
    $c=Copy-Value $s;$c.slots[0]|Add-Member NoteProperty observedAt $now.AddHours(-1).ToString('o') -Force
    $text=((Render $c).text)-join "`n"
    Assert ($text.Contains('Claude 1  [1]  ·  STALE'))
}
'passed='+$script:passed+' failed='+$script:failed
if($script:failed){exit 1}
