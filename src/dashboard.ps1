# Passive terminal dashboard: only reads the collector's cached files.
. (Join-Path $PSScriptRoot 'insights.ps1')
. (Join-Path $PSScriptRoot 'presentation.ps1')
function Get-DashboardCells([string]$Text) {
    $cells=0; $elements=[Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while($elements.MoveNext()) {
        $part=[string]$elements.Current; $code=[char]::ConvertToUtf32($part,0)
        $wide=($code -ge 0x1100 -and ($code -le 0x115f -or ($code -ge 0x2e80 -and $code -le 0xa4cf) -or ($code -ge 0xac00 -and $code -le 0xd7a3) -or ($code -ge 0xf900 -and $code -le 0xfaff) -or ($code -ge 0xfe10 -and $code -le 0xfe6f) -or ($code -ge 0xff00 -and $code -le 0xff60) -or ($code -ge 0xffe0 -and $code -le 0xffe6) -or $code -ge 0x1f300))
        $cells+= $(if($wide){2}else{1})
    }
    return $cells
}
function Format-DashboardText([string]$Text,[int]$Width) {
    # Cached labels must never inject terminal controls. Keep printable Unicode.
    $text=[regex]::Replace($Text,'[\p{Cc}\p{Cf}]',' ')
    $result=''; $cells=0; $elements=[Globalization.StringInfo]::GetTextElementEnumerator($text)
    while($elements.MoveNext()) {
        $part=[string]$elements.Current
        try{$size=Get-DashboardCells $part}catch{$part='?';$size=1}
        if($cells+$size -gt $Width){break}
        $result+=$part; $cells+=$size
    }
    return $result+(' '*[Math]::Max(0,$Width-$cells))
}
function Get-DashboardAge($At,[datetimeoffset]$Now) {
    try {if(-not $At){return $null}; return ($Now-[datetimeoffset]::Parse([string]$At)).TotalSeconds} catch {return $null}
}
function Format-DashboardDuration([double]$Seconds) {
    $s=[Math]::Max(0,[Math]::Floor($Seconds))
    if($s -ge 86400){return ('{0}d {1:00}h' -f [int][Math]::Floor($s/86400),[int][Math]::Floor(($s%86400)/3600))}
    if($s -ge 3600){return ('{0}h {1:00}m' -f [int][Math]::Floor($s/3600),[int][Math]::Floor(($s%3600)/60))}
    return ('{0}m {1:00}s' -f [int][Math]::Floor($s/60),[int]($s%60))
}
function Format-DashboardReset($Reset,[datetimeoffset]$Now,[switch]$Unix,[switch]$Wide,[switch]$Unconfirmed) {
    if($null -eq $Reset -or [string]$Reset -eq ''){return 'reset unknown'}
    try {
        $at=if($Unix){[datetimeoffset]::FromUnixTimeSeconds([long]$Reset)}else{[datetimeoffset]::Parse([string]$Reset)}
        if($at -le $Now){return 'reset awaiting update'}
        if($Unconfirmed){return 'reset not confirmed'}
        $text='reset in '+(Format-DashboardDuration ($at-$Now).TotalSeconds)
        if($Wide){$text+='  /  '+$at.ToLocalTime().ToString('ddd HH:mm')}
        return $text
    }catch{return 'reset unknown'}
}
function New-DashboardRow([string]$Text,[string]$Tone='text'){return [pscustomobject]@{text=$Text;tone=$Tone}}
function Format-DashboardState([string]$State) {
    switch($State){
        {$_ -in @('authentication_required','subscription_login_required','relogin_required','no_credentials')}{return 'SIGN-IN NEEDED'}
        {$_ -in @('timeout','transport_failed','rpc_failed','collection_failed')}{return 'READ UNAVAILABLE'}
        'unsupported_configuration'{return 'CUSTOM CONFIGURATION'}
        'duplicate_subscription'{return 'DUPLICATE ACCOUNT'}
        'backoff'{return 'RETRYING LATER'}
        'rate_limited'{return 'RATE LIMITED'}
        default{return $State.Replace('_',' ').ToUpperInvariant()}
    }
}
function New-DashboardQuotaRow([string]$Label,$Used,$Reset,[datetimeoffset]$Now,[int]$Width,[switch]$Unix,[switch]$Unconfirmed,[switch]$Stale,[double]$AnimationSeconds=0,[switch]$ReducedMotion) {
    $size=if($Width -ge 80){14}else{8}
    $tone='muted'; $percent='   ?'; $bar='·'*$size
    if((Test-Hotpl8Number $Used) -and $Used -ge 0 -and $Used -le 100) {
        $left=100-[double]$Used; $percent=('{0,3:0}%' -f $left)
        $fill=[int][Math]::Floor($left*$size/100); $bar=('━'*$fill)+('·'*($size-$fill))
        $tone=if($Stale){'muted'}else{Get-Hotpl8BudgetTone $left}
    }
    $resetText=Format-DashboardReset $Reset $Now -Unix:$Unix -Wide:($Width -ge 96) -Unconfirmed:$Unconfirmed
    New-Hotpl8StyledRow @(New-Hotpl8Span ('    '+$Label.PadRight(3)+'  ');New-Hotpl8Span $(if(-not $Stale -and $percent -ne '   ?' -and $left -lt 10){'!'}else{' '}) $(if(-not $ReducedMotion -and ($AnimationSeconds%2) -ge 1){'text'}else{$tone});New-Hotpl8Span ($bar+' '+$percent+' left') $tone;New-Hotpl8Span ('   '+$resetText) 'muted')
}
function Get-Hotpl8DashboardRows($Status,$Policy,[datetimeoffset]$Now,[int]$Width=100,[switch]$Compact,[double]$AnimationSeconds=0,[switch]$ReducedMotion) {
    if (-not $Policy.prefer -and -not $Policy.codex.slots -and -not $Status) {
        New-DashboardRow '  Connect an account to see its quota here.' text
        New-DashboardRow '  Codex: sign in with the native CLI, then:' lavender
        New-DashboardRow '    hotpl8 enroll -Slot main -AccountHome PATH' text
        New-DashboardRow '  Claude: follow docs/install.md.' peach
        New-DashboardRow '  Next: hotpl8 refresh' mint
        return
    }
    $age=Get-DashboardAge $Status.generatedAt $Now
    $stale=($null -eq $age -or $age -gt 900 -or $age -lt -5)
    if(-not $Status -or -not $Status.generatedAt){New-DashboardRow '  No reading yet. Run hotpl8 refresh.' amber}
    elseif($stale){New-DashboardRow '  ! Usage is stale. Run hotpl8 refresh.' amber}
    $needsHelp = (@($Status.slots | Where-Object { $_.status -ne 'ok' }).Count -gt 0 -or
        @($Status.providers.codex.slots | Where-Object { $_.status -ne 'ok' }).Count -gt 0)
    if ($needsHelp) { New-DashboardRow '  Account unavailable? Run hotpl8 doctor; see docs/troubleshooting.md.' amber }
    if($Status.collector){
        $health=Get-Hotpl8Health $Status.collector $Now
        if(-not $Compact -or $health -notin @('recent collection completed','collecting')){New-DashboardRow ('  '+$health) $(if($health -in @('recent collection completed','collecting')){'muted'}else{'amber'})}
    }
    if($Status.automationPause){New-DashboardRow ('  AUTOMATION PAUSED: '+$Status.automationPause.reason) amber}
    $claude=@($Status.slots|Where-Object {$null -ne $_})
    if(-not $claude.Count -and $Policy.labels){
        $claude=@($Policy.labels.PSObject.Properties|ForEach-Object{[pscustomobject]@{slot=$_.Name;label=$_.Value;status='no observation'}})
    }
    New-DashboardRow ('  CLAUDE  /  '+$claude.Count+' subscription'+$(if($claude.Count -ne 1){'s'})) peach
    if(-not $claude.Count){New-DashboardRow '    No Claude accounts in this snapshot.' muted}
    foreach($slot in $claude){
        $isStale=($stale -or -not $slot.fresh)
        $badge=if($slot.active){'ACTIVE'}elseif(@($Policy.reserve) -contains $slot.slot){'RESERVE'}else{'MONITORED'}
        if($slot.status -ne 'ok'){$badge=Format-DashboardState $slot.status}elseif($isStale){$badge='STALE'}elseif($slot.cold){$badge+=' / resting'}
        $name=if($slot.label){$slot.label}else{'Slot '+$slot.slot}
        New-DashboardRow ('  '+$(if($slot.active){'● '}else{'○ '})+$name+'  ['+$slot.slot+']  ·  '+$badge) $(if($slot.active){'peach'}else{'text'})
        New-DashboardQuotaRow '5h' $slot.used5h $slot.reset5h $Now $Width -Stale:$isStale -AnimationSeconds $AnimationSeconds -ReducedMotion:$ReducedMotion
        New-DashboardQuotaRow '7d' $slot.used7d $slot.reset7d $Now $Width -Stale:$isStale -AnimationSeconds $AnimationSeconds -ReducedMotion:$ReducedMotion
        if(-not $Compact){
            if($slot.forecast -and -not $isStale){New-DashboardRow ('    '+(Format-Hotpl8Forecast $slot.forecast)) muted}
            if($slot.warmOutcome){New-DashboardRow ('    Warm: '+$slot.warmOutcome.outcome) $(if($slot.warmOutcome.outcome -eq 'observed-active'){'mint'}else{'amber'})}
            if($slot.actionBlock){New-DashboardRow ('    Warming: '+$slot.actionBlock.Replace('_',' ')) muted}
            if($slot.modelBlock){New-DashboardRow ('    Selection: '+$slot.modelBlock.Replace('_',' ')) amber}
            foreach($scope in @($slot.scoped)){if($scope){New-DashboardRow ('    '+$scope.name+' weekly: '+$scope.pct+'% used') muted}}
        }
        if(-not $Compact){New-DashboardRow ''}
    }
    $codex=$Status.providers.codex
    $configured=@($Policy.codex.slots|Where-Object {$null -ne $_})
    if(-not $configured.Count){$configured=@($codex.slots|Where-Object {$null -ne $_})}
    New-DashboardRow ('  CODEX  /  '+$configured.Count+' subscription'+$(if($configured.Count -ne 1){'s'})) cyan
    if(-not $configured.Count){New-DashboardRow '    No Codex accounts enrolled yet.' muted}
    if($codex.failureCode){New-DashboardRow ('    Read failed: '+$codex.failureCode+' / '+$codex.failureStage) amber}
    foreach($config in $configured){
        $slot=@($codex.slots|Where-Object id -EQ $config.id|Select-Object -First 1)
        $item=if($slot.Count){$slot[0]}else{$null}
        $name=if($config.label){$config.label}else{$config.id}
        $age=Get-DashboardAge $item.observedAt $Now
        $isStale=($null -eq $age -or $age -gt 900 -or $age -lt -5)
        $badge=if(-not $item){'NO OBSERVATION'}elseif($item.status -ne 'ok'){Format-DashboardState $item.status}elseif($isStale){'STALE'}else{'MONITORED'}
        if($item -and -not $isStale -and $Policy.codex -and $codex.recommendedSlot -eq $config.id -and (Get-CodexEligibility $item $Policy.codex $codex.defaultMeter $Now ([bool]$codex.critical.($codex.defaultMeter).active)) -eq 'eligible'){$badge='NEXT LAUNCH'}
        New-DashboardRow ('  ○ '+$name+'  ['+$config.id+']  ·  '+$badge) cyan
        if($item.planType -and $item.planType -ne 'unknown' -and -not $Compact){New-DashboardRow ('    Native plan: '+$item.planType+' / capacity conversion configured separately') muted}
        if(-not $item -or -not $item.buckets){New-DashboardRow '    Waiting for quota readings.' muted}
        foreach($bucket in @($item.buckets.PSObject.Properties|Sort-Object @{Expression={if($_.Name -eq 'codex'){0}elseif($_.Name -eq 'codex_bengalfox'){1}else{2}}},Name)){
            $label=switch($bucket.Name){'codex'{'Main'};'codex_bengalfox'{'Spark'};default{$bucket.Name}}
            $state=switch($bucket.Value.status){'constraint_unknown'{'limit status unknown'};'blocked'{'blocked'};'unsupported'{'unsupported quota'};default{''}}
            if(-not $Compact -or $bucket.Name -ne 'codex' -or $state){New-DashboardRow ('    '+$label+$(if($state){'  /  '+$state})) $(if($state){'amber'}else{'muted'})}
            $windows=@($bucket.Value.windows.PSObject.Properties|Sort-Object {[int]$_.Name})
            foreach($window in $windows){
                $label=if($window.Name -eq '300'){'5h'}elseif($window.Name -eq '10080'){'7d'}else{$window.Name+'m'}
                New-DashboardQuotaRow $label $window.Value.usedPercent $window.Value.resetsAt $Now $Width -Unix -Unconfirmed:($window.Value.anchorState -eq 'unconfirmed') -Stale:$isStale -AnimationSeconds $AnimationSeconds -ReducedMotion:$ReducedMotion
            }
            if(-not $Compact -and $bucket.Name -eq 'codex' -and $windows.Count -eq 1 -and $windows[0].Name -eq '10080'){New-DashboardRow '    Weekly allowance · no five-hour window' muted}
            if(-not $windows.Count){New-DashboardRow '    Quota not available yet.' muted}
            if(-not $Compact -and $bucket.Value.forecast -and -not $isStale){New-DashboardRow ('    '+(Format-Hotpl8Forecast $bucket.Value.forecast)) muted}
        }
        if(-not $Compact){New-DashboardRow ''}
    }
    if($Status.hold){New-DashboardRow ('  Rotation held until '+[string]$Status.hold.until) amber}
    if(-not $Compact -and $Status.recentActions){
        New-DashboardRow '  RECENT ACTIONS / hotpl8 explain for selection details' muted
        foreach($event in @($Status.recentActions|Select-Object -Last 3)){New-DashboardRow ('    '+$event.provider+' '+$event.slot+': '+$event.kind+' / '+$event.reason) muted}
    }
}
function Get-Hotpl8OverviewRows($Status,$Policy,[datetimeoffset]$Now,[int]$Width,[double]$AnimationSeconds=0,[switch]$ReducedMotion,$OverviewOverride=$null) {
    $overview=if($OverviewOverride){$OverviewOverride}else{Get-Hotpl8ProviderOverview $Status $Policy $Now}
    foreach($provider in @('claude','codex')){
        $p=$overview.$provider;$c=$p.capacity
        $tone=if($provider -eq 'claude'){'peach'}else{'cyan'}
        New-DashboardRow ('  '+$provider.ToUpper()+' / Available capacity (estimate)') $tone
        $size=[math]::Max(10,[math]::Min(45,$Width-30))
        $value=$c.knownUsablePercent
        $fill=[int][math]::Floor($value*$size/100)
        $gain=if($null -ne $c.projectedGainPercent){[int][math]::Floor($c.projectedGainPercent*$size/100)}else{0}
        $unknown=[math]::Min($size-$fill-$gain,[int][math]::Ceiling($c.unknownPercent*$size/100))
        $empty=[math]::Max(0,$size-$fill-$gain-$unknown)
        $health=Get-Hotpl8BudgetTone $value
        $warning=$c.complete -and $value -lt 10
        $pulse=if($warning -and -not $ReducedMotion -and ($AnimationSeconds%2) -ge 1){'text'}else{$health}
        $suffix=if($c.nextResetAt){' '+$(if($null -ne $c.projectedGainPercent){'+{0:0.#}% ' -f $c.projectedGainPercent}else{''})+(Format-DashboardDuration ([datetimeoffset]::Parse($c.nextResetAt)-$Now).TotalSeconds)}else{' reset unknown'}
        $spaces=[math]::Max(1,$Width-4-$size-$suffix.Length)
        $spans=@(New-Hotpl8Span '  ';New-Hotpl8Span '[' $(if($warning){$pulse}else{'border'});New-Hotpl8Span ('█'*$fill) $health;New-Hotpl8Span ('▒'*$gain) $tone;New-Hotpl8Span ('·'*$empty) 'border';New-Hotpl8Span ('?'*$unknown) 'muted';New-Hotpl8Span ']' $(if($warning){$pulse}else{'border'});New-Hotpl8Span ((' '*$spaces)+$suffix) 'muted')
        New-Hotpl8StyledRow $spans
        $state=if($c.complete){'{0:0.#}% now' -f $c.usableNowPercent}else{[string]$p.measured+'/'+$p.accounts+' quota readings; capacity setup needed'}
        if($c.critical.active){$state+=' / CRITICAL / target '+$c.critical.pollSeconds+'s'}
        $state+=' / '+$p.automation
        if($p.collectionHealth -notin @('manual / no collector evidence','recent collection completed','collecting')){$state=$p.collectionHealth+' / '+$state}
        New-DashboardRow ('  '+$state) 'muted'
    }
}
function Get-Hotpl8DashboardFrame($Status,$Policy,[datetimeoffset]$Now,[int]$Width=100,[int]$Height=40,[int]$Offset=0,[switch]$Paused,[double]$AnimationSeconds=0,[switch]$Nyan,[switch]$ReducedMotion,$OverviewOverride=$null,[switch]$Plain) {
    $width=[Math]::Max(1,[Math]::Min(110,$Width)); $inside=$width-2
    if($width -lt 48 -or $Height -lt 15){
        @('hotpl8 (=^.^=)','Make the terminal larger.','Q quit / Esc back')|Select-Object -First ([Math]::Max(1,$Height))|ForEach-Object{New-DashboardRow (Format-DashboardText $_ $width) muted}
        return
    }
    $rows=@(Get-Hotpl8DashboardRows $Status $Policy $Now $width -Compact:($Height -lt 32) -AnimationSeconds $AnimationSeconds -ReducedMotion:($ReducedMotion -or $Policy.display.reducedMotion -or [bool]$env:HOTPL8_REDUCED_MOTION))
    $motionOff=$ReducedMotion -or $Policy.display.reducedMotion -or [bool]$env:HOTPL8_REDUCED_MOTION
    $summary=@(Get-Hotpl8OverviewRows $Status $Policy $Now ($width-2) $AnimationSeconds -ReducedMotion:$motionOff -OverviewOverride $OverviewOverride)
    $nyanRows=if($Nyan -and $Height -ge 24){@(Get-Hotpl8NyanRows $AnimationSeconds -ReducedMotion:$motionOff -Plain:$Plain)}else{@()}
    $available=[Math]::Max(1,$Height-7-$summary.Count-1-$nyanRows.Count)
    $offset=[Math]::Max(0,[Math]::Min($Offset,[Math]::Max(0,$rows.Count-$available)))
    $age=Get-DashboardAge $Status.generatedAt $Now
    $freshness=if($null -eq $age){'no reading yet'}elseif($age -lt -5){'clock mismatch'}else{'usage read '+(Format-DashboardDuration $age)+' ago'}
    if($Status.displayPolicy){$freshness='PREVIEW POLICY (display only) / '+$freshness}
    New-DashboardRow ('╭'+('─'*$inside)+'╮') border
    New-DashboardRow ('│'+(Format-DashboardText ('  '+$(if($Nyan){'~~~'}else{Get-Hotpl8Cat $AnimationSeconds -ReducedMotion:$motionOff})+'  hotpl8'+$(if($Nyan -and -not $nyanRows.Count){' / nyan (enlarge for animation)'}else{''})) $inside)+'│') rose
    foreach($r in $nyanRows){Add-Hotpl8FrameBorder $r $inside}
    New-DashboardRow ('│'+(Format-DashboardText ('  '+$(if($Paused){'VIEW FROZEN'}else{'CACHED VIEW'})+'  ·  '+$freshness) $inside)+'│') muted
    New-DashboardRow ('├'+('─'*$inside)+'┤') border
    foreach($row in $summary){Add-Hotpl8FrameBorder $row $inside}
    New-DashboardRow ('│'+(Format-DashboardText '  ACCOUNT DETAILS / scroll below' $inside)+'│') muted
    foreach($row in @($rows|Select-Object -Skip $offset -First $available)){Add-Hotpl8FrameBorder $row $inside}
    New-DashboardRow ('├'+('─'*$inside)+'┤') border
    $keys='  Q quit  ·  Space freeze view  ·  ↑↓ scroll'
    if($rows.Count -gt $available){$keys+='  ['+($offset+1)+'-'+[Math]::Min($rows.Count,$offset+$available)+'/'+$rows.Count+']'}
    New-DashboardRow ('│'+(Format-DashboardText $keys $inside)+'│') muted
    New-DashboardRow ('╰'+('─'*$inside)+'╯') border
}
function Enable-Hotpl8Terminal {
    if($env:NO_COLOR){return @{enabled=$false;handle=$null;mode=$null}}
    if($env:OS -ne 'Windows_NT'){return @{enabled=$true;handle=$null;mode=$null}}
    try{
        if(-not ('HotPl8Console' -as [type])){
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HotPl8Console {
 [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
 [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
 [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
}
'@
        }
        $handle=[HotPl8Console]::GetStdHandle(-11); [uint32]$mode=0
        $enabled=([HotPl8Console]::GetConsoleMode($handle,[ref]$mode) -and [HotPl8Console]::SetConsoleMode($handle,($mode -bor 4)))
        return @{enabled=$enabled;handle=$handle;mode=$mode}
    }catch{return @{enabled=$false;handle=$null;mode=$null}}
}
function Get-Hotpl8DashboardPalette {
    # Shared by terminal output and the documentation screenshot harness.
    return @{text='220;225;238';muted='143;156;181';border='65;79;105';rose='246;169;193';peach='255;155;92';cyan='97;208;220';lavender='194;180;255';mint='151;222;191';amber='244;207;137'}
}
function Show-Hotpl8Dashboard([string]$StateDirectory,[switch]$Nyan,[switch]$ReducedMotion,[switch]$NoColor,$PolicyOverride=$null) {
    $policyPath=Join-Path $StateDirectory 'policy.json'; $statusPath=Join-Path $StateDirectory 'status.json'
    # Pipes and non-console hosts get one plain frame; they must never hang.
    $interactive=$false
    try{$interactive=(-not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected -and [Console]::WindowHeight -gt 0)}catch{}
    if(-not $interactive){Get-Hotpl8DashboardFrame (Read-Hotpl8Snapshot $StateDirectory $PolicyOverride) $(if($PolicyOverride){$PolicyOverride}else{Read-Hotpl8Json $policyPath}) ([datetimeoffset]::UtcNow) 100 10000 -Nyan:$Nyan -ReducedMotion -Plain|ForEach-Object{$_.text};return}
    $esc=[string][char]27; $terminal=Enable-Hotpl8Terminal; $ansi=$terminal.enabled -and -not $NoColor -and -not $(if($PolicyOverride){$PolicyOverride.display.noColor}else{(Read-Hotpl8Json $policyPath).display.noColor})
    $colors=Get-Hotpl8DashboardPalette
    $oldEncoding=[Console]::OutputEncoding; $oldCtrl=[Console]::TreatControlCAsInput; $oldCursor=[Console]::CursorVisible
    $offset=0; $paused=$false; $quit=$false; $last=''; $next=0; $clock=[Diagnostics.Stopwatch]::StartNew()
    try {
        [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
        [Console]::TreatControlCAsInput=$true; [Console]::CursorVisible=$false
        if($ansi){[Console]::Write($esc+'[?1049h'+$esc+'[?25l'+$esc+'[48;2;18;23;35m'+$esc+'[2J')}
        $status=$null; $policy=$null; $readAt=-1000; $frameTime=0; $viewNow=[datetimeoffset]::UtcNow
        while(-not $quit){
            if($clock.ElapsedMilliseconds -ge $next){
                if((-not $paused -or -not $policy) -and $clock.ElapsedMilliseconds-$readAt -ge 1000){$policy=if($PolicyOverride){$PolicyOverride}else{Read-Hotpl8Json $policyPath};$status=Read-Hotpl8Snapshot $StateDirectory $PolicyOverride;$readAt=$clock.ElapsedMilliseconds}
                if(-not $paused){$frameTime=$clock.Elapsed.TotalSeconds;$viewNow=[datetimeoffset]::UtcNow}
                $w=[Math]::Max(1,[Console]::WindowWidth-1);$h=[Math]::Max(1,[Console]::WindowHeight-1)
                $rows=@(Get-Hotpl8DashboardRows $status $policy ([datetimeoffset]::UtcNow) $w -Compact:($h -lt 32))
                $offset=[Math]::Max(0,[Math]::Min($offset,[Math]::Max(0,$rows.Count-[Math]::Max(1,$h-14))))
                $frame=@(Get-Hotpl8DashboardFrame $status $policy $viewNow $w $h $offset -Paused:$paused -AnimationSeconds $frameTime -Nyan:$Nyan -ReducedMotion:($ReducedMotion -or -not $ansi) -OverviewOverride $status.providerOverview -Plain:(-not $ansi))
                $lines=@(foreach($row in $frame){if($ansi){ConvertTo-Hotpl8AnsiRow $row $colors}else{$row.text}})
                $text=$lines -join "`r`n"
                if($text -cne $last){if($ansi){[Console]::Write($esc+'[H'+$text+$esc+'[J')}else{[Console]::SetCursorPosition(0,0);[Console]::Write($text)};$last=$text}
                $next=$clock.ElapsedMilliseconds+$(if($ReducedMotion -or $policy.display.reducedMotion -or -not $ansi -or (-not $Nyan -and $frameTime%11 -lt 10 -and $frameTime%17 -lt 15)){1000}else{200})
            }
            while([Console]::KeyAvailable){
                $key=[Console]::ReadKey($true)
                if($key.Key -in @('Q','Escape') -or ($key.Key -eq 'C' -and ($key.Modifiers -band [ConsoleModifiers]::Control))){$quit=$true;break}
                switch([string]$key.Key){'Spacebar'{$paused=-not $paused};'UpArrow'{$offset--};'DownArrow'{$offset++};'PageUp'{$offset-=10};'PageDown'{$offset+=10};'Home'{$offset=0};'End'{$offset=[int]::MaxValue}}
                $next=0
            }
            Start-Sleep -Milliseconds 100
        }
    }finally{
        if($ansi){[Console]::Write($esc+'[0m'+$esc+'[?25h'+$esc+'[?1049l')}
        if($terminal.handle){[void][HotPl8Console]::SetConsoleMode($terminal.handle,$terminal.mode)}
        [Console]::TreatControlCAsInput=$oldCtrl;[Console]::CursorVisible=$oldCursor;[Console]::OutputEncoding=$oldEncoding
    }
}
