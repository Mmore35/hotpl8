# Styled spans retain plain text and terminal-cell layout without allowing ANSI in data.
$script:Hotpl8SingleCellTextPattern='^[\x20-\x7e\u00b7\u2022\u2190-\u21ff\u2500-\u25ff]*$'
function New-Hotpl8Span([string]$Text,[string]$Tone='text',[string]$Background='') {
    [pscustomobject]@{text=([regex]::Replace($Text,'[\p{Cc}\p{Cf}]',' '));tone=$Tone;background=$Background}
}
function New-Hotpl8StyledRow($Spans) {
    $parts=@($Spans);[pscustomobject]@{text=(($parts|ForEach-Object text)-join '');tone='text';spans=$parts}
}
function Get-Hotpl8RowSpans($Row) {
    if($Row.spans){return $Row.spans}
    New-Hotpl8Span $Row.text $Row.tone
}
function Add-Hotpl8FrameBorder($Row,[int]$Width) {
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
    $spans+=New-Hotpl8Span '│' 'border';New-Hotpl8StyledRow $spans
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
function ConvertTo-Hotpl8AnsiRow($Row,$Palette) {
    $esc=[string][char]27;$out=''
    foreach($span in @(Get-Hotpl8RowSpans $Row)){
        $out+=$esc+'[38;2;'+(Get-Hotpl8Color $span.tone $Palette)+'m'
        $out+=$esc+'[48;2;'+$(if($span.background){Get-Hotpl8Color $span.background $Palette}else{'18;23;35'})+'m'+$span.text
    }
    return $out+$esc+'[48;2;18;23;35m'+$esc+'[K'
}
function Get-Hotpl8Cat([double]$AnimationSeconds,[switch]$ReducedMotion) {
    if($ReducedMotion){return '(=^.^=)'}
    if(($AnimationSeconds%11) -ge 10.6){return '(=-.-=)'}
    return '(=^.^=)'
}
function Get-Hotpl8NyanRows([double]$AnimationSeconds,[switch]$ReducedMotion,[switch]$Plain) {
    if($Plain){
        foreach($line in @('  ~~~~~~[::::] /\_/\','  ~~~~~~[::::]( o.o )  hotpl8 / nyan','         "  "  " "')){New-Hotpl8StyledRow @(New-Hotpl8Span $line)}
        return
    }
    if(-not $script:Hotpl8Nyan){$script:Hotpl8Nyan=Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'data/nyan-frames.json') -Raw|ConvertFrom-Json}
    $data=$script:Hotpl8Nyan;$index=if($ReducedMotion){0}else{[int][math]::Floor($AnimationSeconds*5)%$data.frames.Count}
    if(-not $script:Hotpl8NyanRowsCache){$script:Hotpl8NyanRowsCache=@{}}
    if($script:Hotpl8NyanRowsCache.ContainsKey($index)){return $script:Hotpl8NyanRowsCache[$index]}
    $frame=$data.frames[$index]
    $rows=@()
    for($row=0;$row -lt $frame.Count;$row+=2){
        $spans=@(New-Hotpl8Span '  ')
        for($x=0;$x -lt $frame[$row].Length;$x++){
            $top=[string]$frame[$row][$x];$bottom=[string]$frame[$row+1][$x]
            $spans+=New-Hotpl8Span '▀' $data.palette.$top $data.palette.$bottom
        }
        if($row -eq 4){$spans+=New-Hotpl8Span '   hotpl8 / nyan' 'peach'}
        $rows+=New-Hotpl8StyledRow $spans
    }
    $script:Hotpl8NyanRowsCache[$index]=$rows
    return $rows
}
