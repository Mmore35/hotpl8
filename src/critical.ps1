# Pure emergency selection. Callers persist the returned state under tick.lock.
function Get-Hotpl8CriticalSetting($Part,[string]$Name,[double]$Default) {
    if($null -ne $Part.critical.$Name){return [double]$Part.critical.$Name}
    return $Default
}
function Assert-Hotpl8CriticalPolicy($Part) {
    $c=$Part.critical;if(-not $c){return}
    if($c -isnot [pscustomobject]){throw 'critical must be an object.'}
    foreach($field in $c.PSObject.Properties){if($field.Name -notin @('enabled','enterPercent','exitPercent','floorPercent','drainToZero','pollSeconds','dwellSeconds','advantagePercent')){throw 'Invalid critical setting.'}}
    foreach($key in @('enabled','drainToZero')){if($null -ne $c.$key -and $c.$key -isnot [bool]){throw 'Invalid critical boolean.'}}
    foreach($key in @('enterPercent','exitPercent','floorPercent','advantagePercent')){if($null -ne $c.$key -and (-not (Test-Hotpl8Number $c.$key) -or $c.$key -lt 0 -or $c.$key -gt 100)){throw 'Invalid critical percentage.'}}
    if((Get-Hotpl8CriticalSetting $Part 'exitPercent' 25) -le (Get-Hotpl8CriticalSetting $Part 'enterPercent' 20)){throw 'Critical exit must exceed entry.'}
    if((Get-Hotpl8CriticalSetting $Part 'floorPercent' 1) -gt (Get-Hotpl8CriticalSetting $Part 'enterPercent' 20)){throw 'Critical floor exceeds entry.'}
    foreach($key in @('pollSeconds','dwellSeconds')){if($null -ne $c.$key -and (-not (Test-Hotpl8Number $c.$key) -or $c.$key -lt 60 -or $c.$key -gt 300)){throw 'Critical timing must be 60-300 seconds.'}}
}
function Get-Hotpl8CriticalDecision($Accounts,$Part,[string]$PreviousId,$State,[datetimeoffset]$Now) {
    $work=@($Accounts|Where-Object {-not $_.reserve})
    $known=@($work|Where-Object {$_.fresh -and -not $_.blocked})
    $threshold=if($State.active){Get-Hotpl8CriticalSetting $Part 'exitPercent' 25}else{Get-Hotpl8CriticalSetting $Part 'enterPercent' 20}
    $active=$Part.critical.enabled -eq $true -and $known.Count -gt 0 -and @($known|Where-Object {$_.bindingRemaining -gt $threshold}).Count -eq 0 -and @($known|Where-Object {$_.bindingRemaining -gt 0}).Count -gt 0
    $selected=$PreviousId;$since=$State.selectedAt;$basis='normal policy';$reason='normal policy';$ranking=@()
    if($active){
        $floor=if($Part.critical.drainToZero){0}else{Get-Hotpl8CriticalSetting $Part 'floorPercent' 1}
        $eligible=@($known|Where-Object {$_.bindingRemaining -gt 0 -and $_.bindingRemaining -ge $floor})
        $scaled=$eligible.Count -gt 0 -and @($eligible|Where-Object {-not $_.scaled}).Count -eq 0
        $basis=if($scaled){'usable capacity'}else{'binding-window percentage; capacity unknown'}
        $ranking=@($eligible|Sort-Object @{Expression={if($scaled){-$_.gross}else{-$_.bindingRemaining}}},@{Expression={if($_.slot -eq $PreviousId){0}else{1}}},slot)
        $best=if($ranking.Count){$ranking[0]}else{$null}
        $prior=@($eligible|Where-Object slot -EQ $PreviousId|Select-Object -First 1)
        $selected=if($best){$best.slot}else{$null};$reason='largest remaining allowance'
        if($best -and $prior.Count -and $selected -ne $PreviousId){
            $age=0.0;try{if($since){$age=($Now-[datetimeoffset]::Parse($since)).TotalSeconds}}catch{}
            $before=if($scaled){$prior[0].gross}else{$prior[0].bindingRemaining}
            $after=if($scaled){$best.gross}else{$best.bindingRemaining}
            if($age -lt (Get-Hotpl8CriticalSetting $Part 'dwellSeconds' 60) -or $after -lt $before*(1+(Get-Hotpl8CriticalSetting $Part 'advantagePercent' 10)/100)){$selected=$PreviousId;$reason='retained to avoid churn'}
        }
        if(-not $since -or $selected -ne $State.selected){$since=$Now.ToString('o')}
    }
    [pscustomobject]@{active=[bool]$active;selected=$selected;selectedAt=$since;reason=$reason;basis=$basis;coverage=([string]$known.Count+'/'+$work.Count);pollSeconds=$(if($active){Get-Hotpl8CriticalSetting $Part 'pollSeconds' 60}else{300});ranked=@($ranking|ForEach-Object slot);floorPercent=$(if($Part.critical.drainToZero){0}else{Get-Hotpl8CriticalSetting $Part 'floorPercent' 1})}
}
function Get-Hotpl8ClaudeCritical($Policy,$Accounts,[int]$Active,$State,[datetimeoffset]$Now) {
    (Get-ClaudeProviderDecision $Policy @($Policy.prefer) $Accounts $Active $Now $State).critical
}
