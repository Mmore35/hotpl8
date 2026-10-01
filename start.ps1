# Public extracted-package entrypoint: install and begin the same operation humans and agents use.
[CmdletBinding()]
param([string]$InstallDirectory,[ValidateSet('claude','codex')][string]$Provider,[switch]$AsJson,[switch]$InstallDependencies,[switch]$NoSchedule,[switch]$NoPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'src/common.ps1')
if(-not $InstallDirectory){$InstallDirectory=if($env:OS -eq 'Windows_NT'){Join-Path $env:LOCALAPPDATA 'HotPl8'}else{Join-Path (Get-Hotpl8UserHome) 'Library/Application Support/HotPl8'}}
$installer=if($env:OS -eq 'Windows_NT'){'install.ps1'}elseif($IsMacOS){'install-macos.ps1'}else{throw 'Guided installation currently supports Windows and macOS.'}
$null=& (Join-Path $PSScriptRoot $installer) -InstallDirectory $InstallDirectory -Schedule:(-not $NoSchedule) -NoPath:$NoPath
$entry=Join-Path $InstallDirectory 'app/hotpl8.ps1'
$options=@{AsJson=$AsJson;InstallDependencies=$InstallDependencies}
if($Provider){$options.Provider=$Provider}
if(-not $AsJson){$options.Interactive=$true}
if($AsJson){
    $result=((& $entry setup @options)|Out-String)|ConvertFrom-Json
    if($LASTEXITCODE -ne 0){throw 'Installed onboarding could not begin.'}
    $receipt=Get-Content (Join-Path $InstallDirectory 'installation.json') -Raw|ConvertFrom-Json
    $command=Join-Path ([IO.Path]::GetFullPath($InstallDirectory)) $(if($env:OS -eq 'Windows_NT'){'hotpl8.cmd'}else{'hotpl8'})
    $result|Add-Member NoteProperty installation ([pscustomobject]@{command=$command;scheduled=[bool]$receipt.scheduled;version=$receipt.version})
    $result|ConvertTo-Json -Depth 16
}else{& $entry setup @options}
