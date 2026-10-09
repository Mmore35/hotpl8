# Private, finite native-login worker; invoked only by an explicit onboarding operation.
param([Parameter(Mandatory=$true)][string]$StateDirectory,[Parameter(Mandatory=$true)][string]$OperationId)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
try{
    foreach($file in @('common','config','diagnostics','management','onboarding','onboarding-native','onboarding-install')){. (Join-Path $PSScriptRoot ('src/'+$file+'.ps1'))}
    . (Join-Path $PSScriptRoot 'src/providers/codex.ps1')
    Initialize-Hotpl8OnboardingTools $StateDirectory
    Invoke-Hotpl8OnboardingWorker $StateDirectory $OperationId
}catch{exit 1}
