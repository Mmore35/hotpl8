# Preserve state and native account homes. Remove only this installation's owned integration.
param([Parameter(Mandatory=$true)][string]$InstallDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'lifecycle.ps1')
$root=Assert-Hotpl8Path $InstallDirectory
$installation=Read-Hotpl8Json (Join-Path $root 'installation.json')
if(-not $installation -or $installation.product -ne 'hotpl8' -or $installation.id -notmatch '^[a-f0-9]{12}$'){throw 'Not an owned installation.'}
$state=Assert-Hotpl8Path $installation.stateDirectory
$lock=[IO.File]::Open((Join-Path $state 'tick.lock'),'OpenOrCreate','ReadWrite','None')
try{
    Remove-Hotpl8App (Join-Path $root 'previous') -ValidateOnly
    Remove-Hotpl8App (Join-Path $root 'app') -ValidateOnly
    $policy=Read-Hotpl8Json (Join-Path $state 'policy.json')
    if(-not $policy){throw 'Cannot inspect installed hooks without a valid policy; restore policy before uninstalling.'}
    $updates=@()
    $command='powershell -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $root 'app/status-print.ps1')+'" -Provider codex -StateDirectory "'+$state+'"'
    foreach($slot in @($policy.codex.slots)){
        if(-not $slot){continue}
        $hookPath=Join-Path $slot.home 'hooks.json'
        if(-not (Test-Path -LiteralPath $hookPath)){continue}
        $hook=Read-Hotpl8Json $hookPath
        if(-not $hook){throw 'An enrolled home has invalid hooks.json; repair it before uninstalling.'}
        $entries=@();$changed=$false
        foreach($entry in @($hook.hooks.SessionStart)){
            if(-not $entry){continue}
            $kept=@($entry.hooks|Where-Object{$_.command -cne $command})
            if($kept.Count -ne @($entry.hooks).Count){
                $changed=$true
                if($kept.Count){$entry.hooks=$kept;$entries+=@($entry)}
            }else{$entries+=@($entry)}
        }
        if($changed){$hook.hooks.SessionStart=$entries;$updates+=@(@{path=$hookPath;value=$hook})}
    }
    if($installation.scheduled){
        $task=Get-ScheduledTask -TaskName ('HotPl8-'+$installation.id) -ErrorAction SilentlyContinue
        if($task -and $task.Description -ne ('HotPl8 owned installation '+$installation.id)){throw 'Task ownership mismatch.'}
        if($task){Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false}
    }
    foreach($update in $updates){Write-Hotpl8Text $update.path ($update.value|ConvertTo-Json -Depth 32) -NoBom}
    Remove-Hotpl8App (Join-Path $root 'previous')
    Remove-Hotpl8App (Join-Path $root 'app')
    if($installation.pathAdded){Set-Hotpl8UserPath $root $false}
    foreach($name in @('hotpl8.cmd','installation.json')){Remove-Item -LiteralPath (Join-Path $root $name) -Force}
    'Uninstalled HotPl8. Its state directory and all native accounts/conversations were preserved.'
}finally{$lock.Dispose()}
