# Restore the previous installed application without changing native accounts or policy.
param([Parameter(Mandatory=$true)][string]$InstallDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'src/common.ps1')
. (Join-Path $PSScriptRoot 'src/lifecycle.ps1')
$root=Assert-Hotpl8Path $InstallDirectory
$installation=Read-Hotpl8Json (Join-Path $root 'installation.json')
if(-not $installation -or $installation.product -ne 'hotpl8'){throw 'Not an owned installation.'}
$previous=Join-Path $root 'previous';$app=Join-Path $root 'app'
$null=@(Get-Hotpl8ReleaseFiles $previous)
$state=Assert-Hotpl8Path $installation.stateDirectory
$lock=[IO.File]::Open((Join-Path $state 'tick.lock'),'OpenOrCreate','ReadWrite','None')
try{
    Remove-Hotpl8App $app
    Move-Item -LiteralPath $previous -Destination $app
    $installation.version=(Get-Content (Join-Path $app 'VERSION') -Raw).Trim()
    Write-Hotpl8Text (Join-Path $root 'installation.json') ($installation|ConvertTo-Json) -NoBom
    'Restored '+$installation.version+'. Policy and native accounts preserved.'
}finally{$lock.Dispose()}
