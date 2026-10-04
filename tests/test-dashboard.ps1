$root = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference='Stop'
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/providers/codex.ps1')
. (Join-Path $root 'src/dashboard.ps1')
. (Join-Path $root 'tests/fixtures/terminal.ps1')
$now=[datetimeoffset]::Parse('2026-09-10T12:00:00Z')
$p=@{prefer=@(1,2,3);reserve=@(1);labels=@{'1'='reserve';'2'='work';'3'='work2'};codex=@{slots=@(@{id='main';label='Main'});defaultMeter='codex'}}|ConvertTo-Json -Depth 5|ConvertFrom-Json
$s=@{generatedAt=$now.ToString('o');active=3;slots=@(1..3|ForEach-Object{@{slot=$_;label='Claude '+$_;status='ok';active=($_ -eq 3);fresh=$true;used5h=25;used7d=50;reset5h=$now.AddHours(2).ToString('o');reset7d=$now.AddDays(2).ToString('o')}});providers=@{codex=@{defaultMeter='codex';recommendedSlot='main';slots=@(@{id='main';label='Main';status='ok';observedAt=$now.ToString('o');buckets=@{codex=@{status='observed';windows=@{'10080'=@{usedPercent=35;remainingPercent=65;resetsAt=$now.AddDays(3).ToUnixTimeSeconds();anchorState='observed-active'}}};codex_bengalfox=@{status='constraint_unknown';windows=@{'300'=@{usedPercent=0;remainingPercent=100;resetsAt=$now.AddHours(5).ToUnixTimeSeconds();anchorState='unconfirmed'}}}}})}}}|ConvertTo-Json -Depth 15|ConvertFrom-Json
$script:passed=0;$script:failed=0
function Assert($Value,[string]$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check([string]$Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message}}
function Copy-Value($Value){$Value|ConvertTo-Json -Depth 20|ConvertFrom-Json}
function Render($Value=$s,[int]$Width=100,[int]$Height=100,[int]$Offset=0){@(Get-Hotpl8DashboardFrame $Value $p $now $Width $Height $Offset)}
Check 'empty policy leads to guided setup without implying a running collector' {
    $empty=@{mode='monitor';prefer=@();codex=@{slots=@()}}|ConvertTo-Json -Depth 4|ConvertFrom-Json
    $text=((Get-Hotpl8DashboardFrame $null $empty $now 80 24).text)-join "`n"
    Assert ($text.Contains('hotpl8 setup') -and $text.Contains('ask your agent'))
    Assert (-not $text.Contains('AccountHome') -and -not $text.Contains('hotpl8 refresh'))
    Assert ($text.Contains('no reading') -and -not $text.Contains('LIVE') -and -not $text.Contains('every 5m'))
    # With no account there is nothing to switch between, so the title stays quiet.
    Assert (-not $text.Contains('auto-switch'))
}
Check 'stale and failed readings offer a recovery action' {
    $c=Copy-Value $s;$c.generatedAt=$now.AddHours(-1).ToString('o');$c.slots[0].status='authentication_required'
    $text=((Render $c).text)-join "`n"
    Assert ($text.Contains('hotpl8 refresh') -and $text.Contains('SIGN-IN NEEDED') -and -not $text.Contains('account unavailable'))
}
Check 'one busy or slow Codex read retries quietly until its last success ages out' {
    foreach($failure in @('home_busy','timeout')){
        $c=Copy-Value $s;$c.providers.codex.slots[0].status=$failure;$c.providers.codex.slots[0].observedAt=$now.AddMinutes(-5).ToString('o')
        $text=((Render $c).text)-join "`n"
        Assert ($text.Contains('READ RETRYING') -and -not $text.Contains('account unavailable'))
        $c.providers.codex.slots[0].observedAt=$now.AddHours(-1).ToString('o')
        $text=((Render $c).text)-join "`n"
        Assert (-not $text.Contains('READ RETRYING') -and $text.Contains($failure.Replace('_',' ').ToUpperInvariant()) -and -not $text.Contains('account unavailable'))
    }
    $c=Copy-Value $s;$c.providers.codex.slots[0].status='transport_failed'
    $text=((Render $c).text)-join "`n"
    Assert ($text.Contains('TRANSPORT FAILED') -and -not $text.Contains('account unavailable'))
    Assert ((Get-DashboardBadgeTone 'READ RETRYING') -eq 'amber')
}
Check 'an account problem appears on its own row, never as a general line or header chip' {
    Assert (-not (((Render).text)-join "`n").Contains('account unavailable'))
    $c=Copy-Value $s;$c.providers.codex.slots[0].status='authentication_required'
    $rows=@((Render $c).text)
    $text=$rows -join "`n"
    Assert ($text.Contains('AUTHENTICATION REQUIRED') -and -not $text.Contains('account unavailable') -and -not $text.Contains('provider checks incomplete'))
    $summary=@($rows[3..6]) -join "`n"
    foreach($word in @('SIGN-IN','read','plan unknown','UNAVAILABLE','PICK MANUALLY','NO LAUNCH','monitor')){Assert (-not $summary.Contains($word)) $word}
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
Check 'a reset that elapsed after the reading refills the bar instead of breaking it' {
    # Both variants are a fully calibrated fleet with an elapsed 5h reset.
    # They differ only in whether the anchor was already expired when it
    # arrived, which is the whole rule.
    function Elapsed([string]$Mode){
        $c=Copy-Value $s
        foreach($a in $c.slots){
            $a|Add-Member NoteProperty plan @{status='detected';profile='claude-pro';observedAt=$now.ToString('o')} -Force
            $observed=if($Mode -eq 'rolled'){$now.AddMinutes(-5)}else{$now.AddSeconds(-20)}
            $a|Add-Member NoteProperty observedAt $observed.ToString('o') -Force
            $a.reset5h=$(if($Mode -eq 'rolled'){$now.AddSeconds(-1)}else{$now.AddSeconds(-30)}).ToString('o')
        }
        return $c
    }
    $rolled=((Render (Elapsed rolled)).text)-join "`n"
    Assert ($rolled -match '5h\s+\S+\s+100%')
    Assert ($rolled.Contains('reset · awaiting read') -and -not $rolled.Contains('reset due'))
    # The fleet stays measured, so the headline keeps a real percentage
    # instead of the dotted unknown segment.
    Assert (-not $rolled.Contains('? now'))
    $narrow=((Render (Elapsed rolled) 79).text)-join "`n"
    Assert ($narrow.Contains('awaiting read') -and -not $narrow.Contains('reset · awaiting read'))
    $expired=((Render (Elapsed expired)).text)-join "`n"
    Assert ($expired -match '5h\s+\S+\s+75%')
    # Nothing readable: the Claude summary stays empty rather than inventing a total.
    $lines=@($expired -split "`n");$at=[array]::FindIndex($lines,[Predicate[string]]{param($l) $l -match '^│\s+CLAUDE\s'})
    Assert ($expired.Contains('reset due') -and -not $expired.Contains('? now') -and $at -ge 0 -and $lines[$at+1] -notmatch '% now')
    # A reading that never arrived is not refilled by an elapsed reset: the
    # bar stays the dotted unknown rather than claiming a full window.
    $unreadable=Elapsed rolled
    foreach($a in $unreadable.slots){$a.used5h=$null}
    $text=((Render $unreadable).text)-join "`n"
    Assert ($text.Contains('no reading') -and $text -notmatch '5h\s+\S+\s+100%')
}
Check 'the title states auto-switch as the collector last applied it' {
    function Title($Status,$Policy){(@(@(Get-Hotpl8DashboardFrame $Status $Policy $now 100 40)[1].spans)|ForEach-Object text) -join ''}
    $on=Copy-Value $p;$on|Add-Member NoteProperty mode 'automate' -Force;$on|Add-Member NoteProperty switchEnabled $true -Force
    $c=Copy-Value $s;$c|Add-Member NoteProperty actions @{switching=$true;warming=$false;probing=$false} -Force
    $title=Title $c $on;Assert ($title.Contains('● auto-switch on') -and -not $title.Contains('warming')) $title
    # An observe-only run reports switching off even though the policy allows it.
    $c.actions.switching=$false;$title=Title $c $on;Assert ($title.Contains('○ auto-switch off')) $title
    $c.PSObject.Properties.Remove('actions');$c|Add-Member NoteProperty mode 'monitor' -Force
    $title=Title $c $on;Assert ($title.Contains('auto-switch off')) $title
    $monitor=Copy-Value $p;$monitor|Add-Member NoteProperty mode 'monitor' -Force
    $c.mode='automate';$title=Title $c $monitor;Assert ($title.Contains('auto-switch off')) $title
    $c=Copy-Value $s;$c|Add-Member NoteProperty actions @{switching=$false;warming=$false;probing=$false} -Force
    $c|Add-Member NoteProperty automationPause @{until=$now.AddMinutes(42).ToString('o')} -Force
    $title=Title $c $on;Assert ($title.Contains('◐ auto-switch paused 42m')) $title
    $c=Copy-Value $s;$c|Add-Member NoteProperty actions @{switching=$true;warming=$true;probing=$false} -Force
    $c|Add-Member NoteProperty hold @{until=$now.AddHours(2).ToString('o')} -Force
    $title=Title $c $on;Assert ($title.Contains('◐ auto-switch held 2h 00m') -and $title.Contains('● warming on')) $title
}
Check 'the auto-switch state is never dropped at any supported width' {
    foreach($width in @(48,60,79,100)){
        $row=@(Get-Hotpl8DashboardFrame $s $p $now $width 40)[1]
        $text=(@($row.spans)|ForEach-Object text) -join ''
        # The fixture policy predates modes, so its legacy switching stays on.
        Assert ($text.Contains('● auto-switch on') -and (Get-DashboardCells $text) -eq $width) ([string]$width+': '+$text)
    }
}
Check 'the title gives way in whole words at narrow widths and keeps the state and any warning' {
    $on=Copy-Value $p;$on|Add-Member NoteProperty mode 'automate' -Force;$on|Add-Member NoteProperty switchEnabled $true -Force
    $monitor=Copy-Value $p;$monitor|Add-Member NoteProperty mode 'monitor' -Force
    $stale=Copy-Value $s;$stale.generatedAt=$now.AddMinutes(-65).ToString('o')
    $pausedStale=Copy-Value $stale;$pausedStale|Add-Member NoteProperty actions @{switching=$false;warming=$false;probing=$false} -Force
    $pausedStale|Add-Member NoteProperty automationPause @{until=$now.AddHours(3).ToString('o')} -Force
    $held=Copy-Value $s;$held|Add-Member NoteProperty actions @{switching=$true;warming=$false;probing=$false} -Force
    $held|Add-Member NoteProperty hold @{until=$now.AddHours(2).ToString('o')} -Force
    $cases=@(
        @{name='off, stale';status=$stale;policy=$monitor;frozen=$false;words=@('off','stale');full=@('○ auto-switch off','stale 1h 05m')},
        @{name='accounts, no snapshot';status=$null;policy=$on;frozen=$false;words=@('on','no reading');full=@('● auto-switch on','no reading')},
        @{name='frozen';status=$s;policy=$on;frozen=$true;words=@('on','FROZEN');full=@('● auto-switch on','FROZEN · read 0s ago')},
        @{name='paused, stale';status=$pausedStale;policy=$on;frozen=$false;words=@('paused','stale');full=@('◐ auto-switch paused 3h 00m','stale 1h 05m')},
        @{name='held';status=$held;policy=$on;frozen=$false;words=@('held','0s');full=@('◐ auto-switch held 2h 00m','read 0s ago')}
    )
    foreach($case in $cases){
        foreach($width in @(48,50,60,79,100)){
            $row=@(Get-Hotpl8DashboardFrame $case.status $case.policy $now $width 40 -Paused:$case.frozen -ReducedMotion)[1]
            $text=(@($row.spans)|ForEach-Object text) -join ''
            $label=$case.name+' at '+$width+': '+$text
            # A two-cell margin before the border means nothing was cut to fit.
            Assert ((Get-DashboardCells $text) -eq $width -and $text -match '  │$') $label
            Assert ($text -match '\bauto(-switch)? ') $label
            foreach($word in $case.words){Assert ($text -match ('(^|[\s·])'+[regex]::Escape($word)+'($|[\s·])')) ($label+' lacks '+$word)}
            if($width -eq 100){foreach($phrase in $case.full){Assert ($text.Contains($phrase)) ($label+' lacks '+$phrase)}}
        }
    }
}
Check 'Codex next launch is named by its label and recent history never repeats the footer' {
    $one=Copy-Value $s;$one|Add-Member NoteProperty recentActions @(@{provider='codex';slot='main';kind='recommendation';reason='next_launch_only';at=$now.AddMinutes(-5).ToString('o')}) -Force
    $text=((Render $one).text)-join "`n"
    Assert ($text.Contains('next: Main') -and -not $text.Contains('RECENT')) $text
    # Too narrow for the footer to carry it, so the single event stays listed.
    $narrow=((Render $one 48).text)-join "`n"
    Assert ($narrow.Contains('RECENT') -and $narrow.Contains('codex next')) $narrow
    $two=Copy-Value $one;$two.recentActions=@($one.recentActions[0],$one.recentActions[0])
    Assert ((((Render $two).text)-join "`n").Contains('RECENT'))
}
Check 'a changed bar glides to its new value while the printed number stays exact' {
    # Pure function of the animation clock, so the layout runspace and the
    # live-row loop draw the same frame from the same captured anchor.
    Assert ((Get-Hotpl8Tween 80 20 10 10) -eq 20)
    Assert ((Get-Hotpl8Tween 80 20 10 10.5) -eq 80)
    $mid=Get-Hotpl8Tween 80 20 10 10.25
    Assert ($mid -gt 20 -and $mid -lt 80)
    # No anchor means no glide: the first frame of a bar is its real value.
    Assert ((Get-Hotpl8Tween 80 $null -1 10) -eq 80)
    $c=Copy-Value $s
    $null=@(Get-Hotpl8DashboardFrame $c $p $now 100 100 0 -AnimationSeconds 10)
    $c.slots[0].used5h=75
    $row=@(@(Get-Hotpl8DashboardFrame $c $p $now 100 100 0 -AnimationSeconds 10)|Where-Object {$_.text -match '5h '})[0]
    # 25% remains, drawn part way down from the 75% still on screen.
    Assert ($row.text -match '5h\s+\S+\s+25%')
    Assert ($row.live.until -gt 10)
    $bar=($row.text -split '\s+')[2]
    $later=@(@(Get-Hotpl8DashboardFrame $c $p $now 100 100 0 -AnimationSeconds 10.6)|Where-Object {$_.text -match '5h '})[0]
    Assert ((($later.text -split '\s+')[2]) -ne $bar)
    # Only a target that actually moved restarts the glide. Layout passes run
    # about every second and a glide lasts half of one, so re-anchoring on the
    # currently-shown value instead would stretch every glide it landed in.
    $key='fixture|anchor'
    $null=Get-Hotpl8TweenAnchor $key 75 0
    $moved=Get-Hotpl8TweenAnchor $key 25 1
    Assert ($moved.start -eq 1 -and $moved.from -eq 75)
    $repeat=Get-Hotpl8TweenAnchor $key 25 1.3
    Assert ($repeat.start -eq 1 -and $repeat.from -eq 75)
    # ...and it ends on time rather than being re-eased indefinitely.
    Assert ((Get-Hotpl8TweenAnchor $key 25 1.6).start -lt 0)
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
        $out=& (Get-Hotpl8PowerShell) -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'hotpl8.ps1') -StateDirectory $dir
        Assert ($LASTEXITCODE -eq 0 -and ($out -join "`n").Contains('hotpl8'))
        Assert (-not ($out -join "`n").Contains('PREVIEW POLICY'))
        foreach($command in @('watch','nyan','status')){
            $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'hotpl8.ps1'),$command,'-StateDirectory',$dir)
            if($command -eq 'status'){$args+='-AsJson'}
            $normal=& (Get-Hotpl8PowerShell) @args
            Assert ($LASTEXITCODE -eq 0)
            $preview=& (Get-Hotpl8PowerShell) @args -PreviewPolicy (Join-Path $dir 'policy.json')
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
Check 'nyan scales in both dimensions and keeps account space at small sizes' {
    $sizes=@()
    foreach($viewport in @(@(48,24),@(79,28),@(94,35),@(110,40),@(79,17))){
        $frame=@(Get-Hotpl8DashboardFrame $s $p $now $viewport[0] $viewport[1] -Nyan)
        Assert ($frame.Count -le $viewport[1])
        foreach($row in $frame){Assert ((Get-DashboardCells $row.text) -eq $viewport[0])}
        $cat=@($frame|Where-Object {$_.live.render -eq 'Get-Hotpl8NyanRow'})
        $sizes+=$cat.Count
        if($cat.Count){Assert ($cat.Count -in @(5,9))}
    }
    Assert ($sizes[0] -eq 5 -and $sizes[2] -eq 5 -and $sizes[3] -eq 9 -and $sizes[4] -eq 0)
}
Check 'scaled live nyan matches layout through a whole loop and same-width resize' {
    foreach($height in @(5,9,5)){
        foreach($tick in 0..11){
            $at=$tick/12.0+0.001
            $styled=@(Get-Hotpl8NyanRows $at -Width 77 -Rows $height)
            for($i=0;$i -lt $height;$i++){
                $live=Get-Hotpl8NyanRow $i 77 $at -Rows $height
                $text=[regex]::Replace($live.ansi,([string][char]27+'\[[0-9;]*[mK]'),'')
                $expected=Add-Hotpl8FrameBorder $styled[$i] 77
                Assert ($text -ceq $expected.text)
            }
        }
    }
    $a=@(Get-Hotpl8NyanRows 0 -Width 77 -Rows 5 -ReducedMotion)|ConvertTo-Json -Depth 8
    $b=@(Get-Hotpl8NyanRows 9 -Width 77 -Rows 5 -ReducedMotion)|ConvertTo-Json -Depth 8
    Assert ($a -ceq $b)
}
Check 'Apple Terminal uses complete background cells with every source pixel intact' {
    $previous=$env:TERM_PROGRAM
    try{
        $env:TERM_PROGRAM='Apple_Terminal'
        $data=Get-Hotpl8NyanData
        foreach($height in @(10,18)){
            $art=if($height -eq 10){$data.compact}else{$data}
            foreach($tick in 0..11){
                # At exactly the sprite width, source column zero is terminal column zero.
                $scene=Get-Hotpl8NyanScene $tick ($art.frames[0][0].Length*2) $height
                Assert ($scene.Count -eq $height)
                for($r=0;$r -lt $height;$r++){
                    $pixels=@(foreach($run in $scene[$r]){
                        Assert ($run.glyph -eq ' ')
                        for($x=0;$x -lt $run.length;$x++){
                            if($run.background){$run.background}else{$script:Hotpl8Background}
                        }
                    })
                    for($x=0;$x -lt $pixels.Count;$x++){
                        $expected=$data.palette.([string]$art.frames[$tick][$r][[int][math]::Floor($x/2)])
                        Assert ($pixels[$x] -ceq $expected)
                    }
                }
            }
        }
        foreach($viewport in @(@(48,24),@(79,28),@(94,35),@(110,40),@(79,17))){
            $frame=@(Get-Hotpl8DashboardFrame $s $p $now $viewport[0] $viewport[1] -Nyan)
            Assert ($frame.Count -le $viewport[1])
            foreach($row in $frame){Assert ((Get-DashboardCells $row.text) -eq $viewport[0])}
            $cat=@($frame|Where-Object {$_.live.render -eq 'Get-Hotpl8NyanRow'})
            if($cat.Count){
                Assert ($cat.Count -in @(10,18))
                foreach($row in $cat){Assert ($row.text -notmatch '[▀▄█]')}
            }
        }
        Assert ((Get-Hotpl8NyanSize 108 40) -eq 18)
        Assert ((Get-Hotpl8NyanSize 77 28) -eq 10)
        $env:TERM_PROGRAM='Windows_Terminal'
        Assert ((Get-Hotpl8NyanSize 108 40) -eq 9)
        Assert ((Get-Hotpl8NyanSize 77 28) -eq 5)
    }finally{$env:TERM_PROGRAM=$previous}
}
Check 'ANSI preview decoder preserves RGB and indexed pixels and rejects unsupported SGR' {
    $esc=[string][char]27
    $parts=@(ConvertFrom-Hotpl8TestAnsiRow ($esc+'[38;2;1;2;3m'+$esc+'[48;5;234m'+'A'+$esc+'[38;5;196mB'+$esc+'[K'))
    Assert ($parts.Count -eq 2 -and $parts[0].tone -eq '1;2;3' -and $parts[0].background -eq '28;28;28')
    Assert ($parts[1].text -eq 'B' -and $parts[1].tone -eq '255;0;0')
    $rejected=$false
    try{$null=ConvertFrom-Hotpl8TestAnsiRow ($esc+'[35mtext')}catch{$rejected=$true}
    Assert $rejected
}
Check 'live and static Nyan pixels match in both color modes across all frames and sizes' {
    $previous=$env:TERM_PROGRAM
    try{
        foreach($terminal in @('Apple_Terminal','iTerm.app')){
            $env:TERM_PROGRAM=$terminal;$palette=Get-Hotpl8DashboardPalette
            foreach($height in $(if($terminal -eq 'Apple_Terminal'){@(10,18)}else{@(5,9)})){
                foreach($tick in 0..11){
                    $at=$tick/12.0+0.001
                    $styled=@(Get-Hotpl8NyanRows $at -Width 77 -Rows $height)
                    $live=@(Get-Hotpl8NyanAnsiRows $at 77 $palette $height)
                    for($i=0;$i -lt $height;$i++){
                        $expected=ConvertTo-Hotpl8AnsiRow (Add-Hotpl8FrameBorder $styled[$i] 77) $palette
                        $cells=@(foreach($ansi in @($expected,$live[$i].ansi)){
                            $pixels=@(foreach($span in @(ConvertFrom-Hotpl8TestAnsiRow $ansi)){
                                foreach($glyph in $span.text.ToCharArray()){
                                    # A space's foreground is invisible; the fast path can retain it.
                                    ([string]$glyph)+'|'+$(if($glyph -eq ' '){''}else{$span.tone})+'|'+$span.background
                                }
                            })
                            $pixels -join '/'
                        })
                        Assert ($cells[0] -ceq $cells[1])
                    }
                }
            }
        }
    }finally{$env:TERM_PROGRAM=$previous}
}
Check 'Apple Terminal uses fixed indexed colors even with an inherited truecolor hint' {
    $previous=$env:TERM_PROGRAM;$previousColor=$env:COLORTERM
    try{
        $env:TERM_PROGRAM='Apple_Terminal';$env:COLORTERM='truecolor'
        Assert ((Get-Hotpl8TerminalColorMode) -eq '256')
        $esc=[string][char]27
        Assert ((Get-Hotpl8AnsiColor '18;23;35' -Background) -ceq ($esc+'[48;5;234m'))
        Assert ((Get-Hotpl8AnsiColor '255;0;0') -ceq ($esc+'[38;5;196m'))
        Assert ((Get-Hotpl8AnsiColor '0;0;0') -ceq ($esc+'[38;5;16m'))
        Assert ((Get-Hotpl8AnsiColor '255;255;255') -ceq ($esc+'[38;5;231m'))
        $palette=Get-Hotpl8DashboardPalette
        foreach($height in @(5,9)){
            foreach($tick in 0..11){
                $at=$tick/12.0+0.001
                $rows=@(Get-Hotpl8NyanRows $at -Width 77 -Rows $height)
                $live=@(Get-Hotpl8NyanAnsiRows $at 77 $palette $height)
                foreach($row in @($rows)+@($live)){
                    $ansi=ConvertTo-Hotpl8AnsiRow $row $palette
                    Assert ($ansi -notmatch '\[(?:38|48);2;')
                    $codes=[regex]::Matches($ansi,$esc+'\[([0-9;]+)m')
                    Assert ($codes.Count -gt 0)
                    foreach($code in $codes){
                        Assert ($code.Groups[1].Value -match '^(38|48);5;(\d+)$')
                        $index=[int]($code.Groups[1].Value.Split(';')[-1])
                        Assert ($index -ge 16 -and $index -le 255)
                    }
                }
            }
        }
        $frame=@(Get-Hotpl8DashboardFrame $s $p $now 113 33 -Nyan)
        $text=(@($frame|ForEach-Object {ConvertTo-Hotpl8AnsiRow $_ $palette}) -join '')
        Assert ($text.Contains($esc+'[48;5;234m') -and $text -notmatch '\[(?:38|48);2;')
    }finally{$env:TERM_PROGRAM=$previous;$env:COLORTERM=$previousColor}
}
Check 'truecolor output and cached animation remain distinct from indexed output' {
    $previous=$env:TERM_PROGRAM
    try{
        $palette=Get-Hotpl8DashboardPalette;$esc=[string][char]27
        foreach($terminal in @('iTerm.app','Apple_Terminal','iTerm.app')){
            $env:TERM_PROGRAM=$terminal
            $row=New-Hotpl8StyledRow @(New-Hotpl8Span 'fixture' 'text')
            $text=(ConvertTo-Hotpl8AnsiRow $row $palette)+((Get-Hotpl8NyanAnsiRows 0 77 $palette 5).ansi -join '')
            if($terminal -eq 'Apple_Terminal'){
                Assert ($text -match '\[38;5;' -and $text -notmatch '\[(?:38|48);2;')
            }else{
                Assert ($text.Contains($esc+'[38;2;220;225;238m'))
                Assert ($text.Contains($esc+'[48;2;18;23;35m') -and $text -notmatch '\[(?:38|48);5;')
            }
        }
    }finally{$env:TERM_PROGRAM=$previous}
}
Check 'background layout renders fixtures and preserves a frozen snapshot on resize' {
    $dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-animation-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dir)
    $worker=$null;$previousTerminal=$env:TERM_PROGRAM
    try{
        $env:TERM_PROGRAM='Apple_Terminal'
        Write-Hotpl8Text (Join-Path $dir 'policy.json') ($p|ConvertTo-Json -Depth 20)
        Write-Hotpl8Text (Join-Path $dir 'status.json') ($s|ConvertTo-Json -Depth 20)
        $before=Get-FileHash (Join-Path $dir 'status.json')
        $worker=New-Hotpl8DashboardRenderer
        $pending=Start-Hotpl8DashboardRender $worker $dir $null 79 28 0 $false 0 $false $false $true
        Assert ($pending.AsyncWaitHandle.WaitOne(15000))
        $result=@($worker.EndInvoke($pending))[0]
        Assert (-not $worker.HadErrors -and $result.frame.Count -le 28 -and $result.lines.Count -eq $result.frame.Count)
        Assert (($result.lines -join '') -match '\[48;5;234m' -and ($result.lines -join '') -notmatch '\[(?:38|48);2;')
        Assert (@($result.frame|Where-Object {$_.live.render -eq 'Get-Hotpl8NyanRow'}).Count -gt 0)
        Assert ((Get-FileHash (Join-Path $dir 'status.json')).Hash -eq $before.Hash)
        $changed=Copy-Value $s;$changed.slots[0].label='Changed fixture'
        Write-Hotpl8Text (Join-Path $dir 'status.json') ($changed|ConvertTo-Json -Depth 20)
        $pending=Start-Hotpl8DashboardRender $worker $dir $null 94 35 0 $true 0 $false $false $true
        Assert ($pending.AsyncWaitHandle.WaitOne(15000))
        $result=@($worker.EndInvoke($pending))[0]
        Assert (-not $worker.HadErrors -and $result.frame.Count -le 35 -and $result.paused)
        Assert (($result.frame.text -join '') -notmatch 'Changed fixture')
    }finally{
        $env:TERM_PROGRAM=$previousTerminal
        if($worker){$worker.Dispose()}
        $full=[IO.Path]::GetFullPath($dir)
        Assert ($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-animation-[a-f0-9]{32}$')
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
Check 'both nyan sizes retain exact palette pixels and compact eyes in every frame' {
    $data=Get-Hotpl8NyanData
    $colors=@('')+@($data.palette.PSObject.Properties|ForEach-Object Value)
    Assert ($data.compact.frames.Count -eq $data.frames.Count)
    foreach($i in 0..11){
        $small=$data.compact.frames[$i]
        Assert ($small.Count -eq 10 -and @($small|Where-Object {$_.Length -ne 32}).Count -eq 0)
        Assert ($small[5][21] -eq '.' -and $small[5][27] -eq '.')
        Assert ($small[6][20] -eq '%' -and $small[6][29] -eq '%')
        foreach($height in @(5,9)){
            $scene=Get-Hotpl8NyanScene $i 44 $height
            Assert ($scene.Count -eq $height)
            foreach($row in $scene){foreach($run in $row){Assert ($run.tone -in $colors -and $run.background -in $colors)}}
        }
    }
}
'passed='+$script:passed+' failed='+$script:failed
if($script:failed){exit 1}
