# Independent decoder for the renderer's fixed RGB/indexed ANSI subset.
# Used by visual previews and cell-by-cell regression comparisons, never live state.
function ConvertFrom-Hotpl8TestAnsiRow([string]$Ansi) {
    $foreground='220;225;238';$background='18;23;35'
    $esc=[string][char]27
    foreach($part in [regex]::Split($Ansi,('('+ $esc +'\[[0-9;]*[mK])'))){
        if(-not $part){continue}
        if($part -eq ($esc+'[K')){continue}
        # Culture-sensitive prefix matching can ignore the ESC control character.
        if($part.StartsWith($esc,[StringComparison]::Ordinal)){
            if($part -notmatch ('^'+$esc+'\[(38|48);(.*)m$')){throw 'Unsupported preview terminal sequence.'}
            $target=$Matches[1];$values=@($Matches[2].Split(';')|ForEach-Object {[int]$_})
            if($values[0] -eq 2 -and $values.Count -eq 4){$rgb=$values[1..3]-join ';'}
            elseif($values[0] -eq 5 -and $values.Count -eq 2 -and $values[1] -ge 16 -and $values[1] -le 255){
                $index=$values[1]
                if($index -ge 232){$gray=8+10*($index-232);$rgb=@($gray,$gray,$gray)-join ';'}
                else{
                    $index-=16;$levels=@(0,95,135,175,215,255)
                    $rgb=@($levels[[int][math]::Floor($index/36)],$levels[[int][math]::Floor(($index%36)/6)],$levels[$index%6])-join ';'
                }
            }else{throw 'Unsupported preview color.'}
            if($target -eq '38'){$foreground=$rgb}else{$background=$rgb}
        }else{New-Hotpl8Span $part $foreground $background}
    }
}
