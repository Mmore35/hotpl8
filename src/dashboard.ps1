# Passive terminal dashboard: only reads the collector's cached files.
. (Join-Path $PSScriptRoot 'insights.ps1')
. (Join-Path $PSScriptRoot 'presentation.ps1')
function Get-DashboardCells([string]$Text) {
    if([regex]::IsMatch($Text,$script:Hotpl8SingleCellTextPattern)){return $Text.Length}
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
    if([regex]::IsMatch($text,$script:Hotpl8SingleCellTextPattern)){return $text.Substring(0,[math]::Min($text.Length,[math]::Max(0,$Width))).PadRight([math]::Max(0,$Width))}
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
function Format-DashboardAge([double]$Seconds) {
    # Glanceable durations: two units at most, seconds only under a minute.
    $s=[Math]::Max(0,[Math]::Floor($Seconds))
    if($s -ge 86400){return ('{0}d {1:00}h' -f [int][Math]::Floor($s/86400),[int][Math]::Floor(($s%86400)/3600))}
    if($s -ge 3600){return ('{0}h {1:00}m' -f [int][Math]::Floor($s/3600),[int][Math]::Floor(($s%3600)/60))}
    if($s -ge 60){return ([string][int][Math]::Floor($s/60)+'m')}
    return ([string][int]$s+'s')
}
function Format-DashboardReset($Reset,[datetimeoffset]$Now,[switch]$Unix,[switch]$Wide,[switch]$Unconfirmed) {
    if($null -eq $Reset -or [string]$Reset -eq ''){return 'reset ?'}
    try {
        $at=if($Unix){[datetimeoffset]::FromUnixTimeSeconds([long]$Reset)}else{[datetimeoffset]::Parse([string]$Reset)}
        if($at -le $Now){return 'reset due'}
        if($Unconfirmed){return 'reset unconfirmed'}
        $text='reset '+(Format-DashboardAge ($at-$Now).TotalSeconds)
        if($Wide){$text+='  ·  '+$at.ToLocalTime().ToString('ddd HH:mm')}
        return $text
    }catch{return 'reset ?'}
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
function Get-DashboardBadgeTone([string]$Badge) {
    # One meaning per color: mint = usable / chosen, lavender = held back on
    # purpose, red = out of balance, amber = needs a look, muted = inert.
    if($Badge -match 'EXHAUSTED|LOW BALANCE|BLOCKED'){return 'red'}
    if($Badge -match 'DISABLED|MONITORED|NO OBSERVATION'){return 'muted'}
    if($Badge -match 'RESERVE'){return 'lavender'}
    if($Badge -match '^(ACTIVE|NEXT LAUNCH|AVAILABLE)'){return 'mint'}
    return 'amber'
}
function Format-DashboardForecast($Forecast) {
    if(-not $Forecast){return $null}
    $hours=[math]::Round($Forecast.secondsToLimit/3600)
    return ('pace '+$Forecast.pace+'  ·  ~'+$hours+'h to limit  ·  '+$(if($Forecast.lastsToReset){'lasts to reset'}else{'may run out first'}))
}
function New-DashboardQuotaRow([string]$Label,$Used,$Reset,[datetimeoffset]$Now,[int]$Width,[switch]$Unix,[switch]$Unconfirmed,[switch]$Stale,$ObservedAt=$null,[string]$TweenKey='',$TweenFrom=$null,$TweenStart=-1,[double]$AnimationSeconds=0,[switch]$ReducedMotion) {
    $size=if($Width -ge 80){20}else{12}
    $motion=-not $ReducedMotion
    # A window whose own reported reset has passed since we read it refilled.
    # Draw the refilled window and say the confirming read has not landed yet,
    # instead of stamping the pre-reset value 'reset due'. A stale reading is
    # never rolled over: it already lost the right to speak for the account.
    $window=if($Stale){@{used=$Used;resetAt=$Reset;rolledOver=$false}}else{Resolve-Hotpl8Window $Used $Reset $ObservedAt $Now -Unix:$Unix}
    $value=$window.used
    $known=(Test-Hotpl8Number $value) -and $value -ge 0 -and $value -le 100
    $left=if($known){100-[double]$value}else{0}
    $low=$known -and -not $Stale -and $left -lt 10
    $health=if(-not $known -or $Stale){'muted'}else{Get-Hotpl8BudgetTone $left}
    $pulse=if($low -and $motion){Get-Hotpl8Pulse $AnimationSeconds}else{0}
    $fill=if($pulse){Get-Hotpl8ToneMix $health '255;255;255' (0.45*$pulse)}else{$health}
    $reveal=if($motion){Get-Hotpl8Reveal $AnimationSeconds}else{1}
    # The layout pass captures the glide; a live refresh is handed it and only reads it.
    $tween=if($motion -and $known -and $TweenKey -and $AnimationSeconds -gt 0 -and -not $PSBoundParameters.ContainsKey('TweenFrom')){Get-Hotpl8TweenAnchor ('quota|'+$TweenKey) $left $AnimationSeconds}else{@{from=$TweenFrom;start=$TweenStart}}
    $shown=if($motion -and $known){Get-Hotpl8Tween $left $tween.from $tween.start $AnimationSeconds}else{$left}
    $bar=if($known){@(New-Hotpl8BarSpans -Value $shown -Size $size -Tone $fill -Reveal $reveal)}else{@(New-Hotpl8Span ('·'*$size) 'border')}
    $percent=if($known){('{0,3:0}%' -f $left)}else{'   ?'}
    $mark=if($low -and ($pulse -ge 0.5 -or -not $motion)){'!'}else{' '}
    # A full window with no reset time has not started; say so instead of 'reset ?'.
    $resetText=if(-not $known){'no reading'}elseif($window.rolledOver){$(if($Width -ge 80){'reset · awaiting read'}else{'awaiting read'})}elseif($left -ge 100 -and ($null -eq $window.resetAt -or [string]$window.resetAt -eq '')){'idle'}else{Format-DashboardReset $window.resetAt $Now -Unix:$Unix -Wide:($Width -ge 96) -Unconfirmed:$Unconfirmed}
    $spans=@(New-Hotpl8Span ('    '+$Label.PadRight(3)) 'muted';New-Hotpl8Span $mark 'red')+$bar+@(New-Hotpl8Span ('  '+$percent) $health;New-Hotpl8Span ('   '+$resetText) 'muted')
    $live=$null
    if($motion -and $known){
        $until=[math]::Max(0.9,$(if($null -ne $tween.from -and $tween.start -ge 0){[double]$tween.start+0.5}else{0}))
        $live=New-Hotpl8Live 'New-DashboardQuotaRow' @{Label=$Label;Used=$Used;Reset=$Reset;Now=$Now;Width=$Width;Unix=[bool]$Unix;Unconfirmed=[bool]$Unconfirmed;Stale=[bool]$Stale;ObservedAt=$ObservedAt;TweenKey=$TweenKey;TweenFrom=$tween.from;TweenStart=$tween.start} $until -Loop:$low
    }
    New-Hotpl8StyledRow $spans $live
}
function New-DashboardAccountRow([string]$Name,[string]$Id,[string]$Badge,[string]$Accent,[switch]$Selected) {
    $marker=if($Selected){'● '}else{'○ '}
    New-Hotpl8StyledRow @(New-Hotpl8Span '  ';New-Hotpl8Span $marker $(if($Selected){$Accent}else{'border'});New-Hotpl8Span $Name $(if($Selected){'text'}else{'muted'});New-Hotpl8Span ('  ['+$Id+']  ·  ') 'border';New-Hotpl8Span $Badge (Get-DashboardBadgeTone $Badge))
}
function Get-Hotpl8DashboardRows($Status,$Policy,[datetimeoffset]$Now,[int]$Width=100,[switch]$Compact,[double]$AnimationSeconds=0,[switch]$ReducedMotion) {
    if (-not $Policy.prefer -and -not $Policy.codex.slots -and -not $Status) {
        New-DashboardRow '  No accounts yet.' text
        New-DashboardRow '  Codex   sign in with the native CLI, then' cyan
        New-DashboardRow '          hotpl8 enroll -Slot main -AccountHome PATH' text
        New-DashboardRow '  Claude  follow docs/install.md' peach
        New-DashboardRow '  then    hotpl8 refresh' mint
        return
    }
    $age=Get-DashboardAge $Status.generatedAt $Now
    $stale=($null -eq $age -or $age -gt 900 -or $age -lt -5)
    if(-not $Status -or -not $Status.generatedAt){New-DashboardRow '  no reading yet  ·  hotpl8 refresh' amber}
    elseif($stale){New-DashboardRow '  ! readings stale  ·  hotpl8 refresh' amber}
    $needsHelp = (@($Status.slots | Where-Object { $_.status -notin @('ok','disabled') }).Count -gt 0 -or
        @($Status.providers.codex.slots | Where-Object { $_.status -notin @('ok','disabled') }).Count -gt 0)
    if ($needsHelp) { New-DashboardRow '  ! account unavailable  ·  hotpl8 doctor' amber }
    if($Status.collector){
        $health=Get-Hotpl8Health $Status.collector $Now
        if($health -notin @('recent collection completed','collecting')){New-DashboardRow ('  ! '+$health) amber}
    }
    $claude=@($Status.slots|Where-Object {$null -ne $_})
    if(-not $claude.Count -and $Policy.labels){
        $claude=@($Policy.labels.PSObject.Properties|ForEach-Object{[pscustomobject]@{slot=$_.Name;label=$_.Value;status='no observation'}})
    }
    New-DashboardRow ('  CLAUDE  /  '+$claude.Count+' subscription'+$(if($claude.Count -ne 1){'s'})) peach
    if(-not $claude.Count){New-DashboardRow '    none in this snapshot' muted}
    foreach($slot in $claude){
        $isStale=($stale -or -not $slot.fresh -or ($slot.observedAt -and -not (Test-Hotpl8FreshTimestamp $slot.observedAt $Now)))
        $badge=if($slot.active){'ACTIVE'}elseif(@($Policy.reserve) -contains $slot.slot){'RESERVE'}else{'MONITORED'}
        if($slot.status -ne 'ok'){$badge=Format-DashboardState $slot.status}elseif($isStale){$badge='STALE'}elseif($slot.cold){$badge+=' · resting'}
        $name=if($slot.label){$slot.label}else{'Slot '+$slot.slot}
        $disabled=($slot.slot -in @($Policy.disabled) -or $slot.status -eq 'disabled')
        if($disabled){$badge='DISABLED'}
        if(Test-Hotpl8DetectedPlan $slot.plan $Now){$badge+=' · '+$slot.plan.label}
        New-DashboardAccountRow $name ([string]$slot.slot) $badge peach -Selected:([bool]$slot.active -and -not $disabled)
        if($disabled){continue}
        New-DashboardQuotaRow '5h' $slot.used5h $slot.reset5h $Now $Width -Stale:$isStale -ObservedAt $slot.observedAt -TweenKey ('claude|'+$slot.slot+'|5h') -AnimationSeconds $AnimationSeconds -ReducedMotion:$ReducedMotion
        New-DashboardQuotaRow '7d' $slot.used7d $slot.reset7d $Now $Width -Stale:$isStale -ObservedAt $slot.observedAt -TweenKey ('claude|'+$slot.slot+'|7d') -AnimationSeconds $AnimationSeconds -ReducedMotion:$ReducedMotion
        if(-not $Compact){
            if($isStale){
                $readingAge=Get-DashboardAge $slot.observedAt $Now
                New-DashboardRow ('    '+$(if($null -ne $readingAge){'last read '+(Format-DashboardAge $readingAge)+' ago  ·  awaiting update'}else{'no valid reading  ·  hotpl8 explain'})) amber
            }
            $forecast=if(-not $isStale){Format-DashboardForecast $slot.forecast}else{$null}
            if($forecast){New-DashboardRow ('    '+$forecast) muted}
            $notes=@();$attention=$false
            if($slot.warmOutcome){$outcome=[string]$slot.warmOutcome.outcome;$notes+=Format-DashboardWarmOutcome $outcome;if($outcome -in @('unconfirmed','failed','account_changed')){$attention=$true}}
            if($slot.actionBlock){$block=[string]$slot.actionBlock;$notes+=$(if($block -eq 'automation_paused'){'warming paused'}else{'warming off · '+$block.Replace('_',' ')})}
            if($slot.modelBlock){$notes+=([string]$slot.modelBlock).Replace('_',' ');$attention=$true}
            if($slot.plan -and -not (Test-Hotpl8DetectedPlan $slot.plan $Now)){$notes+='plan unverified'}
            foreach($scope in @($slot.scoped)){if($scope){$notes+=$scope.name+' '+$scope.pct+'% used'}}
            if($notes.Count){New-DashboardRow ('    '+($notes -join '  ·  ')) $(if($attention){'amber'}else{'muted'})}
            New-DashboardRow ''
        }
    }
    $codex=$Status.providers.codex
    $configured=@($Policy.codex.slots|Where-Object {$null -ne $_})
    if(-not $configured.Count){$configured=@($codex.slots|Where-Object {$null -ne $_})}
    New-DashboardRow ('  CODEX  /  '+$configured.Count+' subscription'+$(if($configured.Count -ne 1){'s'})) cyan
    if(-not $configured.Count){New-DashboardRow '    none enrolled yet' muted}
    if($codex.failureCode -eq 'state_io_failed'){New-DashboardRow '    ! local state write failed; retrying · last readings below' amber}
    elseif($codex.failureCode){New-DashboardRow ('    ! read failed  ·  '+$codex.failureCode+' / '+$codex.failureStage) amber}
    foreach($config in $configured){
        $slot=@($codex.slots|Where-Object id -EQ $config.id|Select-Object -First 1)
        $item=if($slot.Count){$slot[0]}else{$null}
        $name=if($config.label){$config.label}else{$config.id}
        $age=Get-DashboardAge $item.observedAt $Now
        $isStale=($null -eq $age -or $age -gt 900 -or $age -lt -5)
        $badge=Get-Hotpl8CodexAccountState $item $Policy.codex $codex $Now
        $disabled=($config.id -in @($Policy.codex.disabled) -or $item.status -eq 'disabled')
        if($disabled){$badge='DISABLED'}
        New-DashboardAccountRow $name ([string]$config.id) $badge cyan -Selected:($badge -eq 'NEXT LAUNCH')
        if($disabled){continue}
        if(-not $item -or -not $item.buckets){New-DashboardRow '    no reading yet' muted}
        foreach($bucket in @($item.buckets.PSObject.Properties|Where-Object Name -NE 'codex_bengalfox'|Sort-Object @{Expression={if($_.Name -eq 'codex'){0}else{1}}},Name)){
            $label=switch($bucket.Name){'codex'{'Main'};'codex_bengalfox'{'Spark'};default{$bucket.Name}}
            $state=switch($bucket.Value.status){'constraint_unknown'{'limit unknown'};'blocked'{'blocked'};'unsupported'{'unsupported quota'};default{''}}
            if($bucket.Name -ne 'codex'){New-DashboardRow ('    '+$label+$(if($state){'  ·  '+$state})) $(if($state){'amber'}else{'muted'})}
            $windows=@($bucket.Value.windows.PSObject.Properties|Sort-Object {[int]$_.Name})
            foreach($window in $windows){
                $label=if($window.Name -eq '300'){'5h'}elseif($window.Name -eq '10080'){'7d'}else{$window.Name+'m'}
                New-DashboardQuotaRow $label $window.Value.usedPercent $window.Value.resetsAt $Now $Width -Unix -Unconfirmed:($window.Value.anchorState -eq 'unconfirmed') -Stale:$isStale -ObservedAt $window.Value.observedAt -TweenKey ('codex|'+$config.id+'|'+$bucket.Name+'|'+$window.Name) -AnimationSeconds $AnimationSeconds -ReducedMotion:$ReducedMotion
            }
            if(-not $windows.Count){New-DashboardRow '    no quota yet' muted}
            if(-not $Compact){
                $forecast=if(-not $isStale){Format-DashboardForecast $bucket.Value.forecast}else{$null}
                if($forecast){New-DashboardRow ('    '+$forecast) muted}
                if($item.planType -and $item.planType -ne 'unknown'){New-DashboardRow ('    plan '+$item.planType) muted}
            }
        }
        if(-not $Compact){New-DashboardRow ''}
    }
    if(-not $Compact -and $Status.recentActions){
        New-DashboardRow '  RECENT' muted
        foreach($event in @($Status.recentActions|Select-Object -Last 3)){
            $note=Get-DashboardActivityNote $event $Policy $Now
            New-DashboardRow ('    '+$note.text+$(if($note.age){'  ·  '+$note.age+' ago'})) $(if($note.tone -eq 'amber'){'amber'}else{'muted'})
        }
    }
}
function Get-DashboardChips($Status,$Provider,[string]$Name,[datetimeoffset]$Now) {
    # Short right-aligned status words for a provider header. Empty when all is well.
    $p=$Provider;$c=if($p.immediate){$p.immediate}else{$p.capacity};$chips=@()
    if($Name -eq 'claude'){
        if($Status.hold -and $p.automation -ne 'automation paused'){$chips+=@{text='HELD';tone='amber'}}
        switch($p.automation){
            'automation paused'{$left=Get-DashboardAge $Status.automationPause.until $Now;$chips+=@{text=('PAUSED'+$(if($null -ne $left -and $left -lt 0){' '+(Format-DashboardAge (-$left))}));tone='amber'}}
            'rotation held'{}
            'automatic selection on'{$chips+=@{text='auto';tone='muted'}}
            'manual selection'{$chips+=@{text='manual';tone='muted'}}
            'monitor only'{$chips+=@{text='monitor';tone='muted'}}
        }
    }elseif($p.accounts){
        if($p.selected){$chips+=@{text=('next: '+$p.selected);tone='mint'}}else{$chips+=@{text='NO LAUNCH';tone='amber'}}
    }
    if($c.critical.active){$chips+=@{text='CRITICAL';tone='rose'}}
    $availability=[string]$p.availability
    if($availability -match '^Unavailable'){$chips+=@{text='UNAVAILABLE';tone='amber'}}
    elseif($availability -match '^Readings stale'){$chips+=@{text='STALE';tone='amber'}}
    elseif($availability -match 'manual selection needed'){$chips+=@{text='PICK MANUALLY';tone='amber'}}
    elseif($availability -match 'selection held'){$chips+=@{text='HELD';tone='amber'}}
    elseif($availability -match '^No accounts'){$chips+=@{text='none enabled';tone='muted'}}
    if($availability -match 'sign-in'){$chips+=@{text='SIGN-IN';tone='amber'}}
    if($p.collectionHealth -and $p.collectionHealth -notin @('manual / no collector evidence','recent collection completed','collecting')){$chips+=@{text=$p.collectionHealth;tone='amber'}}
    if($p.accounts -and -not $c.complete -and $null -eq $c.totalUnits){$chips+=@{text='plan unknown';tone='amber'}}
    if($p.accounts -and $p.measured -lt $p.accounts){$chips+=@{text=([string]$p.measured+'/'+$p.accounts+' read');tone='amber'}}
    if($p.disabled){$chips+=@{text=([string]$p.disabled+' off');tone='muted'}}
    if($p.duplicates){$chips+=@{text=([string]$p.duplicates+' dup');tone='muted'}}
    return ,$chips
}
function New-DashboardHeaderRow([string]$Title,[string]$Accent,$Chips,[int]$Width) {
    $chips=@($Chips)
    $length={param($items) $sum=0;foreach($chip in $items){$sum+=$chip.text.Length+2};[math]::Max(0,$sum-2)}
    # Keep the row on one line: drop the quietest chips first when space is short.
    while($chips.Count -and (2+$Title.Length+2+(& $length $chips)+2) -gt $Width){
        $drop=@($chips|Where-Object tone -EQ 'muted'|Select-Object -Last 1)
        if(-not $drop.Count){$drop=@($chips|Select-Object -Last 1)}
        $chips=@($chips|Where-Object {$_ -ne $drop[0]})
    }
    $spans=@(New-Hotpl8Span ('  '+$Title) $Accent)
    if($chips.Count){
        $spans+=New-Hotpl8Span (' '*[math]::Max(2,$Width-4-$Title.Length-(& $length $chips)))
        for($i=0;$i -lt $chips.Count;$i++){if($i){$spans+=New-Hotpl8Span '  '};$spans+=New-Hotpl8Span $chips[$i].text $chips[$i].tone}
    }
    New-Hotpl8StyledRow $spans
}
function New-DashboardOverviewBarRow($Overview,[datetimeoffset]$Now,[int]$Width,[string]$TweenKey='',$TweenFrom=$null,$TweenStart=-1,[double]$AnimationSeconds=0,[switch]$ReducedMotion) {
    $p=$Overview;$c=if($p.immediate){$p.immediate}else{$p.capacity};$motion=-not $ReducedMotion
    $value=[double]$c.knownUsablePercent
    $gain=if($c.complete -and $null -ne $c.projectedGainPercent -and $c.nextResetAt){[double]$c.projectedGainPercent}else{0}
    $unknown=if($c.complete){0}else{[double]$c.unknownPercent}
    $estimate=$c.metric -eq 'plan-weighted-quota-headroom'
    $percent=if($c.complete){$(if($estimate){'~'}else{''})+('{0:0}% now' -f $c.usableNowPercent)}else{'? now'}
    $refill=''
    # A refill beyond 24h is text only: it never hatches or shimmers the bar.
    $laterGain=if($c.complete -and $null -ne $c.laterRefillGainPercent -and $c.laterRefillAt){[double]$c.laterRefillGainPercent}else{0}
    if($gain -ge 0.5){$refill='+{0:0}% in {1}' -f $gain,(Format-DashboardAge ([datetimeoffset]::Parse($c.nextResetAt)-$Now).TotalSeconds)}
    elseif($laterGain -ge 0.5){$refill='+{0:0}% in {1}' -f $laterGain,(Format-DashboardAge ([datetimeoffset]::Parse($c.laterRefillAt)-$Now).TotalSeconds)}
    elseif($c.complete -and $c.nextResetAt){$refill='reset '+(Format-DashboardAge ([datetimeoffset]::Parse($c.nextResetAt)-$Now).TotalSeconds)}
    elseif($c.complete -and -not $c.projectionComplete){$refill='refill unconfirmed'}
    # Weekly-only accounts have no separate weekly figure: the estimate is the weekly figure.
    $weeklyOnly=@($c.accounts).Count -gt 0 -and @($c.accounts|Where-Object {@($_.windows|Where-Object name -NE '10080').Count -gt 0}).Count -eq 0
    $weekly=if($null -ne $p.remainingPercent -and (($estimate -and -not $weeklyOnly) -or [math]::Abs([double]$p.remainingPercent-$value) -ge 0.5)){'7d {0:0}%' -f $p.remainingPercent}else{''}
    $text=$percent+$(if($refill){'  '+$refill})
    $size=[math]::Min(40,$Width-8-$text.Length-$(if($weekly){3+$weekly.Length}else{0}))
    if($size -lt 12 -and $weekly){$weekly='';$size=[math]::Min(40,$Width-8-$text.Length)}
    $size=[math]::Max(8,$size)
    $health=Get-Hotpl8BudgetTone $value
    $low=$c.complete -and $value -lt 10
    $pulse=if($low -and $motion){Get-Hotpl8Pulse $AnimationSeconds}else{0}
    $fill=if($pulse){Get-Hotpl8ToneMix $health '255;255;255' (0.45*$pulse)}else{$health}
    $reveal=if($motion){Get-Hotpl8Reveal $AnimationSeconds}else{1}
    $shimmer=if($motion -and $gain -ge 0.5){($AnimationSeconds/3.2)%1}else{-1}
    $edge=if($low){Get-Hotpl8ToneMix 'red' 'border' (1-$pulse)}else{'border'}
    # The same glide as the account bars: the fill moves, the printed number does not lie.
    $tween=if($motion -and $TweenKey -and $AnimationSeconds -gt 0 -and -not $PSBoundParameters.ContainsKey('TweenFrom')){Get-Hotpl8TweenAnchor ('overview|'+$TweenKey) $value $AnimationSeconds}else{@{from=$TweenFrom;start=$TweenStart}}
    $shown=if($motion){Get-Hotpl8Tween $value $tween.from $tween.start $AnimationSeconds}else{$value}
    $spans=@(New-Hotpl8Span '  ';New-Hotpl8Span '[' $edge)+@(New-Hotpl8BarSpans -Value $shown -Gain $gain -Unknown $unknown -Size $size -Tone $fill -Reveal $reveal -Shimmer $shimmer)+@(New-Hotpl8Span ']' $edge)
    $spans+=New-Hotpl8Span ('  '+$percent) $(if($c.complete){$health}else{'muted'})
    if($refill){$spans+=New-Hotpl8Span ('  '+$refill) 'muted'}
    if($weekly){$spans+=New-Hotpl8Span ('   '+$weekly) 'muted'}
    $live=$null
    if($motion -and ($c.complete -or $value -gt 0)){
        $until=[math]::Max(0.9,$(if($null -ne $tween.from -and $tween.start -ge 0){[double]$tween.start+0.5}else{0}))
        $live=New-Hotpl8Live 'New-DashboardOverviewBarRow' @{Overview=$Overview;Now=$Now;Width=$Width;TweenKey=$TweenKey;TweenFrom=$tween.from;TweenStart=$tween.start} $until -Loop:($low -or $shimmer -ge 0)
    }
    New-Hotpl8StyledRow $spans $live
}
function Get-Hotpl8OverviewRows($Status,$Policy,[datetimeoffset]$Now,[int]$Width,[double]$AnimationSeconds=0,[switch]$ReducedMotion,$OverviewOverride=$null) {
    $overview=if($OverviewOverride){$OverviewOverride}else{Get-Hotpl8ProviderOverview $Status $Policy $Now}
    foreach($provider in @('claude','codex')){
        $p=$overview.$provider
        New-DashboardHeaderRow $provider.ToUpper() $(if($provider -eq 'claude'){'peach'}else{'cyan'}) (Get-DashboardChips $Status $p $provider $Now) $Width
        New-DashboardOverviewBarRow $p $Now $Width -TweenKey $provider -AnimationSeconds $AnimationSeconds -ReducedMotion:$ReducedMotion
    }
}
function Format-DashboardWarmOutcome([string]$Outcome) {
    switch($Outcome){
        'observed-active'{'warm ok'};'requested'{'warm sent'};'sent'{'warm sent'};'expired'{'warm done'}
        'unconfirmed'{'warm unconfirmed'};'failed'{'warm failed'};'account_changed'{'warm lost'}
        default{'warm '+$Outcome.Replace('_',' ')}
    }
}
function Get-DashboardActivityNote($Event,$Policy,[datetimeoffset]$Now) {
    # A few words per automation event, using the account labels people know.
    $slot=[string]$Event.slot;$label=$slot
    if($Event.provider -eq 'codex'){$match=@($Policy.codex.slots|Where-Object {$_.id -eq $slot}|Select-Object -First 1);if($match.Count -and $match[0].label){$label=[string]$match[0].label}}
    elseif($Policy.labels -and $Policy.labels.PSObject.Properties[$slot]){$label=[string]$Policy.labels.$slot}
    $reason=[string]$Event.reason;$tone='muted'
    $text=switch([string]$Event.kind){
        'switch'{if($reason -eq 'native_switch_succeeded'){'switched → '+$label}else{$tone='amber';'switch failed → '+$label}}
        'active_changed'{'active → '+$label}
        'warm_attempt'{if($reason -eq 'sent'){'warm sent · '+$label}else{$tone='amber';'warm failed · '+$label}}
        'warm_outcome'{if($reason -in @('unconfirmed','failed','account_changed')){$tone='amber'};(Format-DashboardWarmOutcome $reason)+' · '+$label}
        'recovery_probe'{if($reason -eq 'sent'){'probe sent · '+$label}else{$tone='amber';'probe failed · '+$label}}
        'recommendation'{'codex next → '+$label}
        default{([string]$Event.kind).Replace('_',' ')+' · '+$label}
    }
    $seconds=Get-DashboardAge $Event.at $Now
    $age=if($null -ne $seconds){Format-DashboardAge $seconds}else{''}
    if($tone -ne 'amber' -and $null -ne $seconds -and $seconds -lt 300){$tone='mint'}
    return @{text=$text;age=$age;tone=$tone;seconds=$seconds}
}
function New-DashboardTitleRow($Status,[datetimeoffset]$Now,[int]$Width,[switch]$Paused,[switch]$Nyan,[double]$AnimationSeconds=0,[switch]$ReducedMotion) {
    $left=if($Nyan){'  hotpl8  ·  nyan'}else{'  '+(Get-Hotpl8Cat $AnimationSeconds -ReducedMotion:$ReducedMotion)+'  hotpl8'}
    $meta=@()
    if($Status.displayPolicy){$meta+=@{text='PREVIEW POLICY';tone='lavender'}}
    if($Paused){$meta+=@{text='FROZEN';tone='amber'}}
    $age=Get-DashboardAge $Status.generatedAt $Now
    if($null -eq $age){$meta+=@{text='no reading';tone='amber'}}
    elseif($age -lt -5){$meta+=@{text='clock mismatch';tone='amber'}}
    elseif($age -gt 900){$meta+=@{text=('stale '+(Format-DashboardAge $age));tone='amber'}}
    else{$meta+=@{text=('read '+(Format-DashboardAge $age)+' ago');tone='muted'}}
    $length=0;foreach($m in $meta){$length+=$m.text.Length+3};$length-=3
    $spans=@(New-Hotpl8Span $left 'rose';New-Hotpl8Span (' '*[math]::Max(2,$Width-2-$left.Length-$length)))
    for($i=0;$i -lt $meta.Count;$i++){if($i){$spans+=New-Hotpl8Span ' · ' 'border'};$spans+=New-Hotpl8Span $meta[$i].text $meta[$i].tone}
    $live=$null
    if(-not $Nyan -and -not $ReducedMotion){$live=New-Hotpl8Live 'New-DashboardTitleRow' @{Status=$Status;Now=$Now;Width=$Width;Paused=[bool]$Paused;Nyan=$false} 0 -Loop -Rate 200}
    New-Hotpl8StyledRow $spans $live
}
function Get-Hotpl8NyanRow([int]$Index,[int]$Width,[double]$AnimationSeconds=0,[ValidateSet(5,9)][int]$Rows=9) {
    # Per-row entry point for live redraws; the whole sprite is computed once per instant.
    if(-not $script:Hotpl8NyanLast -or $script:Hotpl8NyanLast.at -ne $AnimationSeconds -or $script:Hotpl8NyanLast.width -ne $Width -or $script:Hotpl8NyanLast.height -ne $Rows){
        $script:Hotpl8NyanLast=@{at=$AnimationSeconds;width=$Width;height=$Rows;rows=@(Get-Hotpl8NyanAnsiRows $AnimationSeconds $Width (Get-Hotpl8DashboardPalette) $Rows)}
    }
    return $script:Hotpl8NyanLast.rows[$Index]
}
function Get-Hotpl8DashboardFrame($Status,$Policy,[datetimeoffset]$Now,[int]$Width=100,[int]$Height=40,[int]$Offset=0,[switch]$Paused,[double]$AnimationSeconds=0,[switch]$Nyan,[switch]$ReducedMotion,$OverviewOverride=$null,[switch]$Plain,$ResolvedOffset=$null) {
    $width=[Math]::Max(1,[Math]::Min(110,$Width)); $inside=$width-2
    if($width -lt 48 -or $Height -lt 17){
        if($ResolvedOffset){$ResolvedOffset.Value=0}
        @('hotpl8 (=^.^=)','Make the terminal larger.','Q quit / Esc back')|Select-Object -First ([Math]::Max(1,$Height))|ForEach-Object{New-DashboardRow (Format-DashboardText $_ $width) muted}
        return
    }
    $motionOff=$ReducedMotion -or $Policy.display.reducedMotion -or [bool]$env:HOTPL8_REDUCED_MOTION -or $Plain
    $rows=@(Get-Hotpl8DashboardRows $Status $Policy $Now $width -Compact:($Height -lt 32) -AnimationSeconds $AnimationSeconds -ReducedMotion:$motionOff)
    $summary=@(Get-Hotpl8OverviewRows $Status $Policy $Now $inside $AnimationSeconds -ReducedMotion:$motionOff -OverviewOverride $OverviewOverride)
    $nyanRows=@()
    $nyanHeight=Get-Hotpl8NyanSize $inside $Height $summary.Count
    if($Nyan -and $nyanHeight -gt 0){
        $nyanRows=@(Get-Hotpl8NyanRows $AnimationSeconds -ReducedMotion:$motionOff -Plain:$Plain -Width $inside -Rows $nyanHeight)
        if(-not $motionOff){for($i=0;$i -lt $nyanRows.Count;$i++){$nyanRows[$i]=New-Hotpl8StyledRow $nyanRows[$i].spans (New-Hotpl8Live 'Get-Hotpl8NyanRow' @{Index=$i;Width=$inside;Rows=$nyanHeight} 0 -Loop -Rate 42)}}
    }
    $available=[Math]::Max(1,$Height-7-$summary.Count-$nyanRows.Count)
    # Prefer showing every account over spending the viewport on forecasts and
    # other optional lines above an account that would otherwise disappear below
    # the fold. Base this on actual content, not just a fixed terminal height.
    if($Height -ge 32 -and $rows.Count -gt $available){
        $compactRows=@(Get-Hotpl8DashboardRows $Status $Policy $Now $width -Compact -AnimationSeconds $AnimationSeconds -ReducedMotion:$motionOff)
        if($compactRows.Count -le $available){$rows=$compactRows}
    }
    $offset=[Math]::Max(0,[Math]::Min($Offset,[Math]::Max(0,$rows.Count-$available)))
    # The interactive controller must use the exact displayed offset. Its old
    # height-minus-14 estimate omitted pinned rows and could strand the final
    # accounts; Nyan and adaptive compact layouts also change the true viewport.
    if($ResolvedOffset){$ResolvedOffset.Value=$offset}
    New-DashboardRow ('╭'+('─'*$inside)+'╮') border
    Add-Hotpl8FrameBorder (New-DashboardTitleRow $Status $Now $inside -Paused:$Paused -Nyan:$Nyan -AnimationSeconds $AnimationSeconds -ReducedMotion:$motionOff) $inside
    foreach($r in $nyanRows){Add-Hotpl8FrameBorder $r $inside}
    New-DashboardRow ('├'+('─'*$inside)+'┤') border
    foreach($row in $summary){Add-Hotpl8FrameBorder $row $inside}
    New-DashboardRow ('├'+('─'*$inside)+'┤') border
    $visible=@($rows|Select-Object -Skip $offset -First $available)
    # A thumb in the right border shows where the details viewport sits.
    $thumb=0;$thumbAt=0
    if($rows.Count -gt $available){
        $thumb=[math]::Max(1,[int][math]::Floor($available*$available/$rows.Count))
        $thumbAt=[int][math]::Round($offset/[math]::Max(1,$rows.Count-$available)*($available-$thumb))
    }
    for($i=0;$i -lt $visible.Count;$i++){
        if($thumb -and $i -ge $thumbAt -and $i -lt $thumbAt+$thumb){Add-Hotpl8FrameBorder $visible[$i] $inside '┃' 'muted'}
        else{Add-Hotpl8FrameBorder $visible[$i] $inside}
    }
    New-DashboardRow ('├'+('─'*$inside)+'┤') border
    $page=if($rows.Count -gt $available){'['+($offset+1)+'-'+[Math]::Min($rows.Count,$offset+$available)+'/'+$rows.Count+']'}else{''}
    # Narrow frames drop key hints before they can crowd the page indicator.
    $keys='  q  ·  ↑↓'
    foreach($candidate in @('  q quit  ·  space freeze  ·  ↑↓ scroll','  q quit  ·  ↑↓ scroll')){if($candidate.Length+$page.Length+4 -le $inside){$keys=$candidate;break}}
    # The latest automation event sits beside the page indicator when it fits.
    $footer=@(New-Hotpl8Span $keys 'muted')
    $recent=@($Status.recentActions|Where-Object {$_}|Select-Object -Last 1)
    $gap=[math]::Max(2,$inside-2-$keys.Length-$page.Length)
    if($recent.Count){
        $note=Get-DashboardActivityNote $recent[0] $Policy $Now
        $activity=$note.text+$(if($note.age){'  ·  '+$note.age+' ago'})
        if($activity.Length+4 -le $gap){$footer+=New-Hotpl8Span (' '*($gap-$activity.Length-$(if($page){2}else{0})));$footer+=New-Hotpl8Span $activity $note.tone;$gap=$(if($page){2}else{0})}
    }
    if($gap){$footer+=New-Hotpl8Span (' '*$gap)}
    if($page){$footer+=New-Hotpl8Span $page 'muted'}
    Add-Hotpl8FrameBorder (New-Hotpl8StyledRow $footer) $inside
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
function Move-Hotpl8DashboardScroll([long]$Offset,[string]$Key) {
    if($Key -eq 'Home'){return 0}
    if($Key -eq 'End'){return [int]::MaxValue}
    $delta=switch($Key){'UpArrow'{-1};'DownArrow'{1};'PageUp'{-10};'PageDown'{10};default{0}}
    # End and Down can arrive in the same input batch before the next render.
    # Saturate instead of overflowing the renderer's Int32 offset parameter.
    return [int][math]::Min([long][int]::MaxValue,[math]::Max([long]0,$Offset+$delta))
}
function New-Hotpl8DashboardRenderer {
    # A separate runspace keeps snapshot parsing and layout off the animation
    # thread. It only reads cached state, just like the foreground dashboard.
    $worker=[powershell]::Create()
    try{
        [void]$worker.AddScript({param($Source)
            . (Join-Path $Source 'common.ps1')
            . (Join-Path $Source 'providers/codex.ps1')
            . (Join-Path $Source 'dashboard.ps1')
        }).AddArgument($PSScriptRoot)
        $null=$worker.Invoke()
        if($worker.HadErrors){throw $worker.Streams.Error[0]}
        $worker.Commands.Clear()
        return $worker
    }catch{$worker.Dispose();throw}
}
function Start-Hotpl8DashboardRender($Worker,[string]$StateDirectory,$PolicyOverride,[int]$Width,[int]$Height,[int]$Offset,[bool]$Paused,[double]$AnimationSeconds,[bool]$ReducedMotion,[bool]$Plain,[bool]$Nyan) {
    $Worker.Commands.Clear();$Worker.Streams.Error.Clear()
    [void]$Worker.AddScript({param($StateDirectory,$PolicyOverride,$Width,$Height,$Offset,$Paused,$AnimationSeconds,$ReducedMotion,$Plain,$Nyan)
        $ErrorActionPreference='Stop'
        if(-not $Paused -or -not $script:RenderPolicy){
            $script:RenderPolicy=if($PolicyOverride){$PolicyOverride}else{Read-Hotpl8Json (Join-Path $StateDirectory 'policy.json')}
            $script:RenderStatus=Read-Hotpl8Snapshot $StateDirectory $PolicyOverride
            $script:RenderNow=[datetimeoffset]::UtcNow
        }
        $policy=$script:RenderPolicy;$status=$script:RenderStatus
        $resolved=$Offset
        $frame=@(Get-Hotpl8DashboardFrame $status $policy $script:RenderNow $Width $Height $Offset -Paused:$Paused -AnimationSeconds $AnimationSeconds -ReducedMotion:$ReducedMotion -Plain:$Plain -Nyan:$Nyan -OverviewOverride $status.providerOverview -ResolvedOffset ([ref]$resolved))
        $palette=Get-Hotpl8DashboardPalette
        $lines=@(foreach($row in $frame){if($Plain){$row.text}else{ConvertTo-Hotpl8AnsiRow $row $palette}})
        $cat=@($frame|Where-Object {$_.live.render -eq 'Get-Hotpl8NyanRow'}|Select-Object -First 1)
        if($cat.Count){
            # Prepare the complete loop here so first-use filtering and ANSI
            # conversion never stall the foreground animation after a resize.
            $size=$cat[0].live.arguments
            for($i=0;$i -lt (Get-Hotpl8NyanData).frames.Count;$i++){
                $null=Get-Hotpl8NyanAnsiScene $i ($size.Width-2) $palette $size.Rows
            }
        }
        $scenes=if($script:Hotpl8NyanScenes){$script:Hotpl8NyanScenes.Clone()}else{$null}
        $ansiScenes=if($script:Hotpl8NyanAnsiScenes){$script:Hotpl8NyanAnsiScenes.Clone()}else{$null}
        [pscustomobject]@{frame=$frame;lines=$lines;policy=$policy;width=$Width;height=$Height;requestedOffset=$Offset;offset=$resolved;paused=$Paused;scenes=$scenes;ansiScenes=$ansiScenes}
    }).AddArgument($StateDirectory).AddArgument($PolicyOverride).AddArgument($Width).AddArgument($Height).AddArgument($Offset).AddArgument($Paused).AddArgument($AnimationSeconds).AddArgument($ReducedMotion).AddArgument($Plain).AddArgument($Nyan)
    return $Worker.BeginInvoke()
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
    $worker=$null;$pending=$null
    $build=Read-Hotpl8Json (Join-Path (Split-Path $PSScriptRoot -Parent) 'build-info.json')
    $deliveryAt=-1000;$handoff=$false;$oldTitle=[Console]::Title
    try {
        [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
        [Console]::TreatControlCAsInput=$true; [Console]::CursorVisible=$false
        if($ansi){[Console]::Write($esc+'[?1049h'+$esc+'[?25l'+$esc+'[48;2;18;23;35m'+$esc+'[2J')}
        $worker=New-Hotpl8DashboardRenderer
        $policy=$null; $frameTime=0
        $layoutAt=-1000; $layoutWidth=0; $layoutHeight=0; $frame=@(); $lastLines=@(); $lines=@()
        while(-not $quit){
            if($env:HOTPL8_INSTALL_DIRECTORY -and $clock.ElapsedMilliseconds-$deliveryAt -ge 1000){
                $deliveryAt=$clock.ElapsedMilliseconds
                $installed=Read-Hotpl8Json (Join-Path $env:HOTPL8_INSTALL_DIRECTORY 'current.json')
                $delivery=Read-Hotpl8Json (Join-Path $env:HOTPL8_INSTALL_DIRECTORY 'delivery-status.json')
                if($build.sha -and $installed.sha -and $installed.sha -ne $build.sha){$handoff=$true;break}
                if($build.sha){[Console]::Title='HotPl8 main '+$build.sha.Substring(0,12)+' | '+$delivery.state}
            }
            if($clock.ElapsedMilliseconds -ge $next){
                $renderStarted=$clock.ElapsedMilliseconds
                if(-not $paused){$frameTime=$clock.Elapsed.TotalSeconds}
                $w=[Math]::Max(1,[Console]::WindowWidth-1);$h=[Math]::Max(1,[Console]::WindowHeight-1)
                $resized=$w -ne $layoutWidth -or $h -ne $layoutHeight
                if($pending -and $pending.IsCompleted){
                    $result=@($worker.EndInvoke($pending));$pending=$null
                    if($worker.HadErrors){throw $worker.Streams.Error[0]}
                    $ready=$result[0]
                    # Input or a resize may have overtaken this background render.
                    if($ready.width -eq $w -and $ready.height -eq $h -and $ready.requestedOffset -eq $offset -and $ready.paused -eq $paused){
                        $frame=$ready.frame;$lines=$ready.lines;$policy=$ready.policy;$offset=$ready.offset
                        if($ready.scenes){$script:Hotpl8NyanScenes=$ready.scenes}
                        if($ready.ansiScenes){$script:Hotpl8NyanAnsiScenes=$ready.ansiScenes}
                        $layoutWidth=$w;$layoutHeight=$h;$layoutAt=$clock.ElapsedMilliseconds
                    }else{$layoutAt=-1000}
                }
                $motionOff=$ReducedMotion -or $policy.display.reducedMotion -or [bool]$env:HOTPL8_REDUCED_MOTION -or -not $ansi
                if(-not $pending -and ($w -ne $layoutWidth -or $h -ne $layoutHeight -or $layoutAt -lt 0 -or (-not $paused -and $clock.ElapsedMilliseconds-$layoutAt -ge 1000))){
                    $pending=Start-Hotpl8DashboardRender $worker $StateDirectory $PolicyOverride $w $h $offset $paused $frameTime ([bool]$ReducedMotion) (-not $ansi) ([bool]$Nyan)
                }
                $rate=0
                # Refresh live rows even when a layout arrives: its animation time
                # is already old. All visible motion uses this one current instant.
                if($ansi -and -not $paused -and -not $motionOff){
                    for($i=0;$i -lt $frame.Count;$i++){
                        if(-not (Test-Hotpl8LiveRow $frame[$i] $frameTime)){continue}
                        $lines[$i]=ConvertTo-Hotpl8AnsiRow (Invoke-Hotpl8LiveRow $frame[$i] $frameTime) $colors
                        $rate=if($rate){[math]::Min($rate,$frame[$i].live.rate)}else{$frame[$i].live.rate}
                    }
                }
                $text=$lines -join "`r`n"
                if($lines.Count -and $layoutWidth -eq $w -and $layoutHeight -eq $h -and ($text -cne $last -or $resized)){
                    if($ansi){
                        if($resized -or -not $lastLines.Count){[Console]::Write($esc+'[H'+$text+$esc+'[J')}
                        else{
                            $changed='';for($i=0;$i -lt $lines.Count;$i++){if($i -ge $lastLines.Count -or $lines[$i] -cne $lastLines[$i]){$changed+=$esc+'['+($i+1)+';1H'+$lines[$i]}}
                            if($lines.Count -lt $lastLines.Count){$changed+=$esc+'['+($lines.Count+1)+';1H'+$esc+'[J'}
                            [Console]::Write($changed)
                        }
                    }else{[Console]::SetCursorPosition(0,0);[Console]::Write($text)}
                    $last=$text;$lastLines=@($lines)
                }
                # Rendering is part of the frame budget, not an additional delay.
                # If a layout pass runs late, skip catch-up frames instead of bursting.
                $next=$renderStarted+$(if($rate){$rate}elseif($pending){42}else{1000})
            }
            while([Console]::KeyAvailable){
                $key=[Console]::ReadKey($true)
                if($key.Key -in @('Q','Escape') -or ($key.Key -eq 'C' -and ($key.Modifiers -band [ConsoleModifiers]::Control))){$quit=$true;break}
                if($key.Key -eq 'Spacebar'){$paused=-not $paused}else{$offset=Move-Hotpl8DashboardScroll $offset ([string]$key.Key)}
                $next=0;$layoutAt=-1000
            }
            $wait=[int][math]::Max(1,[math]::Min(16,$next-$clock.ElapsedMilliseconds))
            Start-Sleep -Milliseconds $wait
        }
    }finally{
        if($worker){try{if($pending){$worker.Stop()}}finally{$worker.Dispose()}}
        if($ansi){[Console]::Write($esc+'[0m'+$esc+'[?25h'+$esc+'[?1049l')}
        if($terminal.handle){[void][HotPl8Console]::SetConsoleMode($terminal.handle,$terminal.mode)}
        [Console]::Title=$oldTitle
        [Console]::TreatControlCAsInput=$oldCtrl;[Console]::CursorVisible=$oldCursor;[Console]::OutputEncoding=$oldEncoding
    }
    if($handoff){exit 75}
}
