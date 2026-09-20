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
if($Operation -eq 'components'){
    ConvertTo-Json -InputObject @(Get-Hotpl8T3DeliveryStatus $InstallDirectory $StateDirectory) -Depth 8
    exit 0
}
Sync-Hotpl8T3Delivery $Operation $InstallDirectory $ReleaseDirectory $StateDirectory
if($Operation -in @('preflight','health','recover')){
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
if($Operation -in @('activate','recover')){
    $registration=Read-Hotpl8Json (Join-Path $InstallDirectory 'delivery.json')
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
}
# No HotPl8 daemon is killed: the collector is a scheduled one-shot. The runner
# holds runtime.lock and tick.lock across activation, so the next wake selects
# the new immutable release. Dashboards hand off when the current pointer changes.
