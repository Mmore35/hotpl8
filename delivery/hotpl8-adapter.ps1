# Product operations for Local Delivery protocol 1. State is never rolled back.
[CmdletBinding()]
param(
    [ValidateSet('preflight','drain','activate','health','recover','components')][string]$Operation,
    [string]$InstallDirectory, [string]$ReleaseDirectory, [string]$StateDirectory
)
$ErrorActionPreference='Stop'
. (Join-Path $ReleaseDirectory 'src/common.ps1')
. (Join-Path $ReleaseDirectory 'src/config.ps1')
. (Join-Path $ReleaseDirectory 'src/providers/codex.ps1')
. (Join-Path $ReleaseDirectory 'src/t3-delivery.ps1')
. (Join-Path $ReleaseDirectory 'src/job-host.ps1')
. (Join-Path $ReleaseDirectory 'src/delivery-policy.ps1')
if($Operation -eq 'drain'){
    # Older runners also call drain under tick.lock before changing current.json.
    # Retain this ownership state even if activation later rolls code back.
    Set-Hotpl8DeliveryOwner $InstallDirectory $StateDirectory
}
if($Operation -eq 'components'){
    ConvertTo-Json -InputObject @(@(Get-Hotpl8T3DeliveryStatus $InstallDirectory $StateDirectory)+@(Get-Hotpl8JobComponentStatus $InstallDirectory)) -Depth 8
    exit 0
}
if($Operation -in @('preflight','activate','health','recover')){
    $policy=Read-Hotpl8Json (Join-Path $StateDirectory 'policy.json')
    Assert-Hotpl8Policy $policy
    if($policy.codex){Assert-CodexPolicy $policy.codex}
    $build=Read-Hotpl8Json (Join-Path $ReleaseDirectory 'build-info.json')
    if($build.sha -notmatch '^[a-f0-9]{40}$'){throw 'Candidate has no exact source identity.'}
    # Cached status/doctor never contacts providers or authorizes account actions.
    $exe=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $result=Invoke-Hotpl8Process $exe @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $ReleaseDirectory 'hotpl8.ps1'),'doctor','-StateDirectory',$StateDirectory,'-AsJson') 30000
    if($result.exitCode -ne 0){throw 'Candidate policy/readiness validation failed.'}
}
if($Operation -in @('preflight','health')){
    # version, status and explain are answered by the compiled reader alone, so a release
    # whose reader does not start on this machine is never selected.
    . (Join-Path $ReleaseDirectory 'src/native.ps1')
    $answer=$null
    try{$answer=Invoke-Hotpl8NativeProcess (Get-Hotpl8NativePath $ReleaseDirectory) @('version','--root',$ReleaseDirectory)}catch{$answer=$null}
    if(-not $answer -or $answer.exitCode -ne 0){throw 'Candidate has no compiled reader that starts on this machine.'}
}
Sync-Hotpl8T3Delivery $Operation $InstallDirectory $ReleaseDirectory $StateDirectory
if($Operation -in @('activate','recover')){
    $registration=Read-Hotpl8Json (Join-Path $InstallDirectory 'delivery.json')
    if($registration.scheduledJobs){
        # Enrolled native components update through the same verified release.
        # Hosts are immutable; updating Actions does not stop the admitted updater.
        & (Join-Path $ReleaseDirectory 'delivery/register.ps1') -InstallDirectory $InstallDirectory -Python $registration.python|Out-Null
        $registration=Read-Hotpl8Json (Join-Path $InstallDirectory 'delivery.json')
    }
    if($registration){
        $registration|Add-Member NoteProperty componentHealth $true -Force
        Write-Hotpl8Text (Join-Path $InstallDirectory 'delivery.json') ($registration|ConvertTo-Json -Depth 10) -NoBom
    }
    $owned=Read-Hotpl8Json (Join-Path $InstallDirectory 'installation.json')
    if($owned){
        $build=Read-Hotpl8Json (Join-Path $ReleaseDirectory 'build-info.json')
        $owned|Add-Member NoteProperty sourceSha $build.sha -Force
        $owned|Add-Member NoteProperty channel 'main' -Force
        $owned|Add-Member NoteProperty managedBy 'local-delivery' -Force
        $owned.version=(Get-Content -LiteralPath (Join-Path $ReleaseDirectory 'VERSION') -Raw).Trim()
        Write-Hotpl8Text (Join-Path $InstallDirectory 'installation.json') ($owned|ConvertTo-Json -Depth 6) -NoBom
    }
    # hotpl8 asks a reader beside the installed launcher before it starts PowerShell
    # (docs/install.md, "The launcher"). Nothing here may stop an activation: without these
    # files every command still starts through launch.ps1.
    try{
        . (Join-Path $ReleaseDirectory 'src/native.ps1')
        $shipped=Get-Hotpl8NativePath $ReleaseDirectory
        $launcher=Join-Path $ReleaseDirectory 'delivery/launch.cmd'
        $handOff=Join-Path $ReleaseDirectory 'delivery/hotpl8.cmd'
        if((Test-Path -LiteralPath $shipped -PathType Leaf) -and (Test-Path -LiteralPath $launcher -PathType Leaf) -and (Test-Path -LiteralPath $handOff -PathType Leaf)){
            $beside=Join-Path $InstallDirectory 'hotpl8-native.exe'
            foreach($old in @(Get-ChildItem -LiteralPath $InstallDirectory -Filter 'hotpl8-native.*.old' -File)){try{Remove-Item -LiteralPath $old.FullName -Force}catch{}}
            if(-not (Test-Path -LiteralPath $beside -PathType Leaf) -or (Get-FileHash -LiteralPath $beside -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $shipped -Algorithm SHA256).Hash){
                # A reader that is answering cannot be written over, but it can be moved aside.
                if(Test-Path -LiteralPath $beside -PathType Leaf){Move-Item -LiteralPath $beside -Destination (Join-Path $InstallDirectory ('hotpl8-native.'+[guid]::NewGuid().ToString('N')+'.old'))}
                Copy-Item -LiteralPath $shipped -Destination $beside
            }
            $installed=Join-Path $InstallDirectory 'launch.cmd'
            if(-not (Test-Path -LiteralPath $installed -PathType Leaf)){Copy-Item -LiteralPath $launcher -Destination $installed}
            # An installation enrolled before the reader has a launcher that starts PowerShell
            # for every command. Sessions started from it come back to it by position; the
            # hand-off is one line and shorter, so they end at the end of it.
            $door=Join-Path $InstallDirectory 'hotpl8.cmd'
            $enrolled="@echo off`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0launch.ps1`" -Entry hotpl8 %*`nexit /b %errorlevel%`n"
            if((Test-Path -LiteralPath $door -PathType Leaf) -and [IO.File]::ReadAllText($door).Replace("`r`n","`n") -ceq $enrolled){Copy-Item -LiteralPath $handOff -Destination $door -Force}
        }
    }catch{}
}
# No HotPl8 daemon is killed: the collector is a scheduled one-shot. The runner
# holds runtime.lock and tick.lock across activation, so the next wake selects
# the new immutable release. Dashboards hand off when the current pointer changes.
