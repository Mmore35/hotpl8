# Styled spans retain plain text and terminal-cell layout without allowing ANSI in data.
$script:Hotpl8SingleCellTextPattern='^[\x20-\x7e·•←-⇿─-◿]*$'
$script:Hotpl8Background='18;23;35'
function Get-Hotpl8DashboardPalette {
    # Shared by terminal output and the documentation screenshot harness.
    # Provider accents (peach = Claude, cyan = Codex) never encode health;
    # health always comes from Get-Hotpl8BudgetTone.
    return @{text='220;225;238';muted='143;156;181';border='65;79;105';rose='246;169;193';peach='255;155;92';cyan='97;208;220';lavender='194;180;255';mint='151;222;191';amber='244;207;137';red='239;98;104'}
}
function New-Hotpl8Span([string]$Text,[string]$Tone='text',[string]$Background='') {
    [pscustomobject]@{text=([regex]::Replace($Text,'[\p{Cc}\p{Cf}]',' '));tone=$Tone;background=$Background}
}
function New-Hotpl8StyledRow($Spans,$Live=$null) {
    $parts=@($Spans);$row=[pscustomobject]@{text=(($parts|ForEach-Object text)-join '');tone='text';spans=$parts}
    # Live rows carry the name of their renderer plus its arguments so the
    # interactive loop can redraw just those rows between layout passes
    # (intro reveal, low-balance pulse, refill shimmer, mascot). Whole-frame
    # layout stays once per second.
    if($Live){$row|Add-Member NoteProperty live $Live}
    $row
}
function New-Hotpl8Live([string]$Render,[hashtable]$Arguments,[double]$Until=0,[switch]$Loop,[int]$Rate=150) {
    return @{render=$Render;arguments=$Arguments;until=$Until;loop=[bool]$Loop;rate=$Rate;border=$null}
}
function Test-Hotpl8LiveRow($Row,[double]$At) {
    return [bool]($Row.live -and ($Row.live.loop -or $At -lt $Row.live.until))
}
function Invoke-Hotpl8LiveRow($Row,[double]$At) {
    $live=$Row.live;$arguments=$live.arguments
    $fresh=& $live.render @arguments -AnimationSeconds $At
    # Renderers may hand back a finished, already bordered terminal line.
    if($fresh.ansi){return $fresh}
    if($live.border){return Add-Hotpl8FrameBorder $fresh $live.border.width $live.border.glyph $live.border.tone}
    return $fresh
}
function Get-Hotpl8RowSpans($Row) {
    if($Row.spans){return $Row.spans}
    New-Hotpl8Span $Row.text $Row.tone
}
function Add-Hotpl8FrameBorder($Row,[int]$Width,[string]$RightGlyph='│',[string]$RightTone='border') {
    $spans=@(New-Hotpl8Span '│' 'border');$used=0
    foreach($part in @(Get-Hotpl8RowSpans $Row)){
        # Common terminal glyphs need no per-character grapheme enumeration.
        if([regex]::IsMatch($part.text,$script:Hotpl8SingleCellTextPattern)){
            $count=[math]::Min($part.text.Length,[math]::Max(0,$Width-$used))
            if($count){$spans+=New-Hotpl8Span $part.text.Substring(0,$count) $part.tone $part.background;$used+=$count}
            continue
        }
        $elements=[Globalization.StringInfo]::GetTextElementEnumerator($part.text);$text=''
        while($elements.MoveNext()){$glyph=[string]$elements.Current;$size=Get-DashboardCells $glyph;if($used+$size -gt $Width){break};$text+=$glyph;$used+=$size}
        if($text){$spans+=New-Hotpl8Span $text $part.tone $part.background}
    }
    if($used -lt $Width){$spans+=New-Hotpl8Span (' '*($Width-$used))}
    $spans+=New-Hotpl8Span $RightGlyph $RightTone
    $live=$null
    if($Row.live){$live=$Row.live.Clone();$live.border=@{width=$Width;glyph=$RightGlyph;tone=$RightTone}}
    New-Hotpl8StyledRow $spans $live
}
function Get-Hotpl8BudgetTone([double]$Remaining) {
    # Interpolate between explicit color stops; health and provider accents are independent.
    $stops=@(@(0,222,48,65),@(10,239,65,67),@(25,255,148,63),@(40,244,214,70),@(100,91,220,135))
    $value=[math]::Max(0,[math]::Min(100,$Remaining))
    for($i=1;$i -lt $stops.Count;$i++){
        if($value -le $stops[$i][0]){
            $a=$stops[$i-1];$b=$stops[$i];$t=($value-$a[0])/($b[0]-$a[0])
            return ((1..3|ForEach-Object {[string][int][math]::Round($a[$_]+($b[$_]-$a[$_])*$t)})-join ';')
        }
    }
}
function Get-Hotpl8Color([string]$Tone,$Palette) {
    if($Tone -match '^\d{1,3};\d{1,3};\d{1,3}$'){return $Tone}
    if($Palette.ContainsKey($Tone)){return $Palette[$Tone]};return $Palette.text
}
function Get-Hotpl8ToneMix([string]$Tone,[string]$Target,[double]$Amount) {
    # Blend two tones; named tones resolve through the palette first.
    $palette=Get-Hotpl8DashboardPalette
    $a=(Get-Hotpl8Color $Tone $palette).Split(';');$b=(Get-Hotpl8Color $Target $palette).Split(';')
    $k=[math]::Max(0,[math]::Min(1,$Amount))
    return ((0..2|ForEach-Object {[string][int][math]::Round([int]$a[$_]+([int]$b[$_]-[int]$a[$_])*$k)})-join ';')
}
function Get-Hotpl8Ease([double]$Progress) {
    $p=[math]::Max(0,[math]::Min(1,$Progress));return 1-[math]::Pow(1-$p,3)
}
function Get-Hotpl8Pulse([double]$Seconds,[double]$Period=1.6) {
    # 0..1 breathing curve; smooth, never a hard blink.
    if($Period -le 0){return 0};$phase=($Seconds%$Period)/$Period
    return (1-[math]::Cos(2*[math]::PI*$phase))/2
}
function Get-Hotpl8Reveal([double]$Seconds) {
    # Bars grow into place during the first second; static renders are complete.
    if($Seconds -le 0 -or $Seconds -ge 0.9){return 1}
    return Get-Hotpl8Ease ($Seconds/0.9)
}
function New-Hotpl8BarSpans([double]$Value,[double]$Gain=0,[double]$Unknown=0,[int]$Size=20,[string]$Tone='mint',[string]$GainTone='',[string]$UnknownTone='amber',[double]$Reveal=1,[double]$Shimmer=-1) {
    # One bar vocabulary everywhere: █ usable now (eighth-cell precision),
    # ▒ projected refill, ╌ unmeasured allowance, · empty track.
    $Size=[math]::Max(1,$Size);$r=[math]::Max(0,[math]::Min(1,$Reveal))
    $solid=[math]::Max(0,[math]::Min(100,$Value))*$r
    $withGain=[math]::Min(100,$solid+[math]::Max(0,$Gain)*$r)
    $withUnknown=[math]::Min(100,$withGain+[math]::Max(0,$Unknown)*$r)
    $cells=$solid*$Size/100
    $whole=[int][math]::Floor($cells+1e-9)
    $eighths=[int][math]::Floor(($cells-$whole)*8+1e-9)
    $partial=if($whole -lt $Size -and $eighths -gt 0){[string]('▏▎▍▌▋▊▉'[$eighths-1])}else{''}
    $used=$whole+$partial.Length
    $gainCount=[math]::Max(0,[int][math]::Round($withGain*$Size/100)-$used)
    $unknownCount=[math]::Max(0,[int][math]::Round($withUnknown*$Size/100)-$used-$gainCount)
    $empty=[math]::Max(0,$Size-$used-$gainCount-$unknownCount)
    if(-not $GainTone){$GainTone=Get-Hotpl8ToneMix $Tone $script:Hotpl8Background 0.45}
    $spans=@()
    if($whole){$spans+=New-Hotpl8Span ('█'*$whole) $Tone}
    if($partial){$spans+=New-Hotpl8Span $partial $Tone}
    if($gainCount){
        $spark=if($Shimmer -ge 0 -and $Shimmer -lt 1){[math]::Min($gainCount-1,[int][math]::Floor($Shimmer*$gainCount))}else{-1}
        if($spark -ge 0){
            $bright=Get-Hotpl8ToneMix $GainTone '255;255;255' 0.5
            if($spark){$spans+=New-Hotpl8Span ('▒'*$spark) $GainTone}
            $spans+=New-Hotpl8Span '▒' $bright
            if($gainCount-$spark-1){$spans+=New-Hotpl8Span ('▒'*($gainCount-$spark-1)) $GainTone}
        }else{$spans+=New-Hotpl8Span ('▒'*$gainCount) $GainTone}
    }
    if($unknownCount){$spans+=New-Hotpl8Span ('╌'*$unknownCount) $UnknownTone}
    if($empty){$spans+=New-Hotpl8Span ('·'*$empty) 'border'}
    return $spans
}
function ConvertTo-Hotpl8AnsiRow($Row,$Palette) {
    if($Row.ansi){return $Row.ansi}
    $esc=[string][char]27;$out=''
    foreach($span in @(Get-Hotpl8RowSpans $Row)){
        $out+=$esc+'[38;2;'+(Get-Hotpl8Color $span.tone $Palette)+'m'
        $out+=$esc+'[48;2;'+$(if($span.background){Get-Hotpl8Color $span.background $Palette}else{$script:Hotpl8Background})+'m'+$span.text
    }
    return $out+$esc+'[48;2;'+$script:Hotpl8Background+'m'+$esc+'[K'
}
function Get-Hotpl8Cat([double]$AnimationSeconds,[switch]$ReducedMotion) {
    if($ReducedMotion){return '(=^.^=)'}
    if(($AnimationSeconds%11) -ge 10.6){return '(=-.-=)'}
    return '(=^.^=)'
}
function Get-Hotpl8NyanData {
    if(-not $script:Hotpl8Nyan){$script:Hotpl8Nyan=Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'data/nyan-frames.json') -Raw|ConvertFrom-Json}
    return $script:Hotpl8Nyan
}
function Get-Hotpl8NyanSize([int]$Width,[int]$Height=40,[int]$SummaryRows=4) {
    # Switch between two purpose-drawn pixel grids; fractional scaling destroys
    # the facial features. Reserve at least four rows for account details.
    $budget=$Height-7-$SummaryRows-4
    if($budget -lt 5){return 0}
    if($Width -ge 82 -and $Height -ge 36 -and $budget -ge 9){return 9}
    return 5
}
function Get-Hotpl8NyanScene([int]$Index,[int]$Width,[ValidateSet(5,9)][int]$Rows=9) {
    # Runs of identical cells for one sprite frame at one width. The bundled
    # sprite is the rainbow's first wave period followed by the cat; the wave
    # tiles leftward so the rainbow streams across the whole frame.
    if(-not $script:Hotpl8NyanScenes){$script:Hotpl8NyanScenes=@{}}
    $key=[string]$Index+'|'+$Width+'|'+$Rows
    if($script:Hotpl8NyanScenes.ContainsKey($key)){return $script:Hotpl8NyanScenes[$key]}
    $data=Get-Hotpl8NyanData
    $art=if($Rows -lt 9){$data.compact}else{$data}
    $frame=$art.frames[$Index];$Rows=$frame.Count/2
    $sprite=$frame[0].Length;$period=[int]$art.period
    $catX=[math]::Max(0,$Width-$sprite-[math]::Max(3,[int][math]::Floor($Width*0.2)))
    $sceneRows=@()
    for($row=0;$row -lt $Rows*2;$row+=2){
        $runs=New-Object Collections.ArrayList;$last=$null
        for($x=0;$x -lt $Width;$x++){
            $col=$x-$catX
            if($col -ge $sprite){$fg=$script:Hotpl8Background;$bg=$script:Hotpl8Background}
            else{
                $i=if($col -ge 0){$col}else{(($col%$period)+$period)%$period}
                $fg=[string]$data.palette.([string]$frame[$row][$i]);$bg=[string]$data.palette.([string]$frame[$row+1][$i])
            }
            if($fg -eq $script:Hotpl8Background -and $bg -eq $script:Hotpl8Background){$glyph=' ';$fg='';$bg=''}
            else{$glyph='▀'}
            if($last -and $last.glyph -eq $glyph -and $last.tone -eq $fg -and $last.background -eq $bg){$last.length++}
            else{$last=[pscustomobject]@{start=$x;length=1;glyph=$glyph;tone=$fg;background=$bg};[void]$runs.Add($last)}
        }
        $sceneRows+=,@($runs.ToArray())
    }
    if($script:Hotpl8NyanScenes.Count -gt 48){$script:Hotpl8NyanScenes=@{}}
    $script:Hotpl8NyanScenes[$key]=$sceneRows
    return $sceneRows
}
function Get-Hotpl8NyanStars([double]$Seconds,[int]$Inner,[ValidateSet(5,9)][int]$Rows=9) {
    # Pixel stars drifting left through open sky: row, seed column, cells per
    # second, twinkle phase. Each one is a half block so it matches the sprite.
    $seeds=@(@(0,7,4.0,0),@(0,53,3.0,2),@(1,29,3.5,1),@(2,71,4.5,3),@(3,17,3.0,2),@(4,47,4.0,0),@(5,3,3.5,1),@(6,61,3.0,3),@(7,35,4.5,2),@(8,23,3.5,0),@(8,79,4.0,1))
    $i=0
    foreach($seed in $seeds){
        $twinkle=[int][math]::Floor($Seconds*1.25+$seed[3])%4
        [pscustomobject]@{row=[math]::Min($Rows-1,[int][math]::Floor($seed[0]*$Rows/9));x=[int](((([math]::Floor($seed[1]-$Seconds*$seed[2]*3))%$Inner)+$Inner)%$Inner);glyph=$(if($i%2){'▄'}else{'▀'});tone=@('muted','text','muted','border')[$twinkle]}
        $i++
    }
}
function Get-Hotpl8NyanAnsiScene([int]$Index,[int]$Width,$Palette,[ValidateSet(5,9)][int]$Rows=9) {
    # One sprite frame as ready-made ANSI chunks; sky chunks stay editable for stars.
    if(-not $script:Hotpl8NyanAnsiScenes){$script:Hotpl8NyanAnsiScenes=@{}}
    $key=[string]$Index+'|'+$Width+'|'+$Rows
    if($script:Hotpl8NyanAnsiScenes.ContainsKey($key)){return $script:Hotpl8NyanAnsiScenes[$key]}
    $esc=[string][char]27;$bg=$esc+'[48;2;'+$script:Hotpl8Background+'m'
    $scene=Get-Hotpl8NyanScene $Index $Width $Rows;$sceneRows=@()
    for($r=0;$r -lt $scene.Count;$r++){
        $chunks=@()
        foreach($run in @($scene[$r])){
            if($run.glyph -eq ' '){$chunks+=@{start=$run.start;length=$run.length;sky=$true;text=($bg+(' '*$run.length))}}
            else{$chunks+=@{start=$run.start;length=$run.length;sky=$false;text=($esc+'[38;2;'+(Get-Hotpl8Color $run.tone $Palette)+'m'+$esc+'[48;2;'+(Get-Hotpl8Color $run.background $Palette)+'m'+($run.glyph*$run.length))}}
        }
        $sceneRows+=,@($chunks)
    }
    if($script:Hotpl8NyanAnsiScenes.Count -gt 48){$script:Hotpl8NyanAnsiScenes=@{}}
    $script:Hotpl8NyanAnsiScenes[$key]=$sceneRows
    return $sceneRows
}
function Get-Hotpl8NyanAnsiRows([double]$AnimationSeconds,[int]$Width,$Palette,[ValidateSet(5,9)][int]$Rows=9) {
    # Interactive fast path: bordered terminal lines assembled from cached chunks
    # with stars spliced in as string edits. Uses the same frame, scene and star
    # math as Get-Hotpl8NyanRows so layout passes and live ticks agree.
    $data=Get-Hotpl8NyanData
    $index=[int][math]::Floor($AnimationSeconds*12)%$data.frames.Count
    $inner=[math]::Max(26,$Width-2)
    $scene=Get-Hotpl8NyanAnsiScene $index $inner $Palette $Rows
    $stars=@(Get-Hotpl8NyanStars $AnimationSeconds $inner $Rows)
    $esc=[string][char]27;$bg=$esc+'[48;2;'+$script:Hotpl8Background+'m'
    $edge=$esc+'[38;2;'+$Palette.border+'m'+$bg+'│'
    $pad=' '*[math]::Max(0,$Width-1-$inner)
    for($r=0;$r -lt $scene.Count;$r++){
        $line=$edge+$bg+' '
        $rowStars=@($stars|Where-Object {$_.row -eq $r}|Sort-Object x)
        foreach($chunk in @($scene[$r])){
            if($chunk.sky -and $rowStars.Count){
                $hits=@($rowStars|Where-Object {$_.x -ge $chunk.start -and $_.x -lt $chunk.start+$chunk.length})
                if($hits.Count){
                    $text=$bg;$cursor=$chunk.start
                    foreach($hit in $hits){if($hit.x -lt $cursor){continue};$text+=(' '*($hit.x-$cursor))+$esc+'[38;2;'+(Get-Hotpl8Color $hit.tone $Palette)+'m'+$hit.glyph;$cursor=$hit.x+1}
                    $line+=$text+(' '*($chunk.start+$chunk.length-$cursor))
                    continue
                }
            }
            $line+=$chunk.text
        }
        [pscustomobject]@{text='';tone='text';ansi=($line+$pad+$edge+$bg+$esc+'[K')}
    }
}
function Get-Hotpl8NyanRows([double]$AnimationSeconds,[switch]$ReducedMotion,[switch]$Plain,[int]$Width=0,[ValidateSet(5,9)][int]$Rows=9) {
    if($Plain){
        foreach($line in @('  ~~~~~~[::::] /\_/\','  ~~~~~~[::::]( o.o )  hotpl8 / nyan','         "  "  " "')){New-Hotpl8StyledRow @(New-Hotpl8Span $line)}
        return
    }
    $data=Get-Hotpl8NyanData;$t=if($ReducedMotion){0}else{$AnimationSeconds}
    $index=[int][math]::Floor($t*12)%$data.frames.Count
    $inner=if($Width -gt 0){[math]::Max(26,$Width-2)}else{$data.frames[0][0].Length+2}
    $scene=Get-Hotpl8NyanScene $index $inner $Rows
    $stars=@(Get-Hotpl8NyanStars $t $inner $Rows)
    $sceneRows=@()
    for($r=0;$r -lt $scene.Count;$r++){
        $runs=@($scene[$r]|ForEach-Object {[pscustomobject]@{start=$_.start;length=$_.length;glyph=$_.glyph;tone=$_.tone;background=$_.background}})
        foreach($star in $stars){
            if($star.row -ne $r){continue}
            $x=$star.x;$glyph=$star.glyph;$tone=$star.tone
            for($i=0;$i -lt $runs.Count;$i++){
                $run=$runs[$i]
                if($x -lt $run.start -or $x -ge $run.start+$run.length){continue}
                if($run.glyph -ne ' '){break}
                $pieces=@()
                if($x -gt $run.start){$pieces+=[pscustomobject]@{start=$run.start;length=($x-$run.start);glyph=' ';tone='';background=''}}
                $pieces+=[pscustomobject]@{start=$x;length=1;glyph=$glyph;tone=$tone;background=''}
                if($x+1 -lt $run.start+$run.length){$pieces+=[pscustomobject]@{start=$x+1;length=($run.start+$run.length-$x-1);glyph=' ';tone='';background=''}}
                $before=@(if($i -gt 0){$runs[0..($i-1)]})
                $after=@(if($i+1 -lt $runs.Count){$runs[($i+1)..($runs.Count-1)]})
                $runs=@($before+$pieces+$after)
                break
            }
        }
        $spans=@(New-Hotpl8Span ' ')
        foreach($run in $runs){$spans+=New-Hotpl8Span ($run.glyph*$run.length) $(if($run.tone){$run.tone}else{'text'}) $run.background}
        $sceneRows+=New-Hotpl8StyledRow $spans
    }
    return $sceneRows
}
