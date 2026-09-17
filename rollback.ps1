# Restore the previous installed application without changing native accounts or policy.
param([Parameter(Mandatory=$true)][string]$InstallDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'src/common.ps1')
. (Join-Path $PSScriptRoot 'src/lifecycle.ps1')
. (Join-Path $PSScriptRoot 'src/leases.ps1')
$root=Assert-Hotpl8Path $InstallDirectory
$installation=Read-Hotpl8Json (Join-Path $root 'installation.json')
if($installation.managedBy -eq 'local-delivery'){throw 'This installation uses Local Delivery. See docs/delivery.md for coordinated recovery.'}
if(-not $installation -or $installation.product -ne 'hotpl8'){throw 'Not an owned installation.'}
$previous=Join-Path $root 'previous';$app=Join-Path $root 'app'
$null=@(Get-Hotpl8ReleaseFiles $previous)
$state=Assert-Hotpl8Path $installation.stateDirectory
$lock=[IO.File]::Open((Join-Path $state 'tick.lock'),'OpenOrCreate','ReadWrite','None')
try{
    # Conservatively refuse while lease protection is needed, even for a newer previous build.
    # Expired/released ledgers are safe for old collectors and do not block rollback.
    if(Get-Hotpl8LeasePause $state){throw 'Agent pauses are active or their state is invalid. Release or allow pauses to expire, or repair invalid state before rollback. Installation was preserved.'}
    # The previous reader must understand today's policy before replacing working code.
    try{
        & {
            . (Join-Path $previous 'src/config.ps1')
            $policy=Read-Hotpl8Json (Join-Path $state 'policy.json')
            Assert-Hotpl8Policy $policy
            if($policy.codex){. (Join-Path $previous 'src/providers/codex.ps1');Assert-CodexPolicy $policy.codex}
        }
    }catch{throw 'Previous version cannot read the current policy. Restore a compatible policy backup before rollback. Installation was preserved.'}
    Remove-Hotpl8App $app
    Move-Item -LiteralPath $previous -Destination $app
    $installation.version=(Get-Content (Join-Path $app 'VERSION') -Raw).Trim()
    Write-Hotpl8Text (Join-Path $root 'installation.json') ($installation|ConvertTo-Json) -NoBom
    'Restored '+$installation.version+'. Policy and native accounts preserved.'
}finally{$lock.Dispose()}
