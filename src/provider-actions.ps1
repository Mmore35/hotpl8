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
                $busyCodes=if($env:OS -eq 'Windows_NT'){@(32,33)}else{@(35)} # Darwin EWOULDBLOCK from .NET flock
                if($cause -isnot [IO.IOException] -or ($cause.HResult -band 65535) -notin $busyCodes){throw 'action_state_unavailable'}
                if($clock.ElapsedMilliseconds -ge $TimeoutMs){throw 'action_control_busy'}
                Start-Sleep -Milliseconds 15
            }
        }
        & $Action
    } finally {if($controlLock){$controlLock.Dispose()}}
}
