# Short shared authorization boundary. Lock order for state writers is tick.lock
# then action-control.lock; native I/O never runs while action-control.lock is held.
# A change after authorization governs the next action, not an already admitted one.
function Invoke-Hotpl8ControlWrite([string]$Directory,[scriptblock]$Action,[int]$TimeoutMs=1000) {
    $clock=[Diagnostics.Stopwatch]::StartNew();$controlLock=$null
    try {
        while(-not $controlLock){
            try {$controlLock=[IO.File]::Open((Join-Path $Directory 'action-control.lock'),'OpenOrCreate','ReadWrite','None')}
            catch {
                $cause=$_.Exception;while($cause.InnerException){$cause=$cause.InnerException}
                if($cause -isnot [IO.IOException] -or ($cause.HResult -band 65535) -notin @(32,33)){throw 'action_state_unavailable'}
                if($clock.ElapsedMilliseconds -ge $TimeoutMs){throw 'action_control_busy'}
                Start-Sleep -Milliseconds 15
            }
        }
        & $Action
    } finally {if($controlLock){$controlLock.Dispose()}}
}
function Get-Hotpl8ControlGeneration([string]$Directory) {
    # These files are configuration/leases, never credential or conversation files.
    # Hash exact bytes so an uncooperative external edit is also detected on reread.
    $parts=@(foreach($name in @('policy.json','hold.json','automation-pause.json','automation-leases.json')){
        $path=Join-Path $Directory $name
        try {$item=Get-Item -LiteralPath $path -ErrorAction Stop}
        catch [System.Management.Automation.ItemNotFoundException] {$item=$null}
        if($item){if($item.PSIsContainer){throw 'action_state_unavailable'};$name+':'+(Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash}
        else {$name+':absent'}
    })
    return (Get-Hotpl8Hash ($parts -join '|'))
}
function Invoke-Hotpl8ActionAuthorization([string]$Directory,[string]$ExpectedGeneration,[scriptblock]$Authorize) {
    Invoke-Hotpl8ControlWrite $Directory {
        if(-not $ExpectedGeneration -or (Get-Hotpl8ControlGeneration $Directory) -cne $ExpectedGeneration){throw 'action_state_changed'}
        & $Authorize
    }
}
function Get-Hotpl8ControlSnapshot([string]$Directory) {
    Invoke-Hotpl8ControlWrite $Directory {
        $before=Get-Hotpl8ControlGeneration $Directory
        $policy=Read-Hotpl8Json (Join-Path $Directory 'policy.json')
        $after=Get-Hotpl8ControlGeneration $Directory
        if($before -cne $after){throw 'action_state_changed'}
        [pscustomobject]@{policy=$policy;generation=$after}
    }
}
function Get-Hotpl8ProviderActionContext($Policy,[string]$Directory,$Context,[datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
    $copy=$Context|ConvertTo-Json -Depth 24|ConvertFrom-Json
    $actions=Get-Hotpl8Actions $Policy $false
    $pause=Get-Hotpl8Pause $Directory $Now
    $hold=Get-Hold $Directory
    $copy|Add-Member NoteProperty mode $(if($Policy.mode -eq 'monitor'){'monitor'}else{'automate'}) -Force
    $copy|Add-Member NoteProperty switching ([bool]$actions.switching) -Force
    $copy|Add-Member NoteProperty paused ([bool]$pause) -Force
    $copy|Add-Member NoteProperty hold ([bool]$hold) -Force
    if($pause.invalid -and $Context.intent -notin @('refresh','control')){$copy|Add-Member NoteProperty safetyInvalid $true -Force}
    if($Context.intent -in @('warm','probe')){
        $enabled=if($Context.intent -eq 'warm'){$actions.warming}else{$actions.probing}
        $copy|Add-Member NoteProperty actionEnabled ([bool]$enabled) -Force
    }
    return $copy
}
