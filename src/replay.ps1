# Replay invokes production selectors without calling a provider or writing state.
function Invoke-Hotpl8Replay($Frames,$Policy) {
    $results=@();$prior=@{};$switches=@{};$reserves=@{};$unavailable=@{}
    foreach($frame in @($Frames)){
        $now=[datetimeoffset]::Parse($frame.generatedAt)
        foreach($order in @('prefer','soonest-reset','weekly-expiry','balanced')){
            $p=$Policy|ConvertTo-Json -Depth 24|ConvertFrom-Json
            $p|Add-Member NoteProperty order $order -Force
            if($p.prefer){
                $acc=@{}
                foreach($s in @($frame.slots)){
                    if(-not $s){continue}
                    $acc[[int]$s.slot]=@{h5=$(if($null -ne $s.used5h){100-$s.used5h}else{$null});h7=$(if($null -ne $s.used7d){100-$s.used7d}else{$null});fresh=($s.fresh -and (Test-Hotpl8FreshTimestamp $s.observedAt $now) -and $s.slot -notin @($p.disabled));modelBlocked=[bool]$s.modelBlock;obj=@{usage=@{fiveHour=@{resetsAt=$s.reset5h};sevenDay=@{resetsAt=$s.reset7d}}}}
                }
                $key='claude/'+$order;$current=if($prior.ContainsKey($key)){$prior[$key]}else{$frame.active}
                $selected=Get-ClaudeSelection $p @($p.prefer) $acc ([int]$current) $now
                $choice=if($frame.hold){if($selected.activeOk){$current}else{$null}}elseif($null -ne $selected.target){$selected.target}elseif($selected.activeOk){$current}else{$null}
                $results+=New-Hotpl8ReplayRow $key $now $choice $current @($p.reserve) $prior $switches $reserves $unavailable
            }
            if($p.codex.slots){
                $p.codex|Add-Member NoteProperty order $order -Force
                foreach($meter in @('codex','codex_bengalfox')){
                    $key='codex/'+$meter+'/'+$order;$current=$prior[$key]
                    $choice=Select-CodexSlot $frame.providers.codex.slots $p.codex $meter $current $frame.providers.codex.hold $now
                    $results+=New-Hotpl8ReplayRow $key $now $choice $current @($p.codex.reserve) $prior $switches $reserves $unavailable
                }
            }
        }
    }
    return [pscustomobject]@{schemaVersion=1;frames=@($Frames).Count;decisions=$results;summary=@(foreach($key in @($prior.Keys|Sort-Object)){[pscustomobject]@{stream=$key;switches=[int]$switches[$key];reserveSelections=[int]$reserves[$key];unavailable=[int]$unavailable[$key]}});limitation='Observed-trace comparison only. Alternate choices change future usage; this does not measure quota savings.'}
}
function New-Hotpl8ReplayRow($Key,$Now,$Choice,$Current,$Reserve,$Prior,$Switches,$Reserves,$Unavailable) {
    if($Choice -and $Current -and $Choice -ne $Current){$Switches[$Key]=[int]$Switches[$Key]+1}
    $isReserve=([bool]$Choice -and $Choice -in $Reserve)
    if($isReserve){$Reserves[$Key]=[int]$Reserves[$Key]+1}
    if(-not $Choice){$Unavailable[$Key]=[int]$Unavailable[$Key]+1}
    $Prior[$Key]=$Choice
    return [pscustomobject]@{stream=$Key;at=$Now.ToString('o');selected=$Choice;reserve=$isReserve}
}
