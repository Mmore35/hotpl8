# Explicit, reversible T3 binary integration. Never copies native credentials.
[CmdletBinding()]
param(
    [ValidateSet('install','doctor','remove')][string]$Operation='doctor',
    [string]$StateDirectory,
    [string]$SettingsPath=(Join-Path $env:USERPROFILE '.t3/userdata/settings.json'),
    [string]$IntegrationDirectory=(Join-Path $env:LOCALAPPDATA 'HotPl8/integrations/t3-codex'),
    [string]$CodexExecutable,
    [string]$NodeExecutable,
    [string]$ProviderId='codex',
    [string]$TargetProviderId='hotpl8-codex',
    [switch]$MakeDefault
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'src/common.ps1')
. (Join-Path $PSScriptRoot 'src/config.ps1')
$StateDirectory=Resolve-Hotpl8StateDirectory $StateDirectory $PSScriptRoot
$SettingsPath=[IO.Path]::GetFullPath($SettingsPath)
$IntegrationDirectory=[IO.Path]::GetFullPath($IntegrationDirectory)
$receiptPath=Join-Path $IntegrationDirectory 'receipt.json'
$launcher=Join-Path $IntegrationDirectory 'hotpl8-codex.exe'
$receipt=Read-Hotpl8Json $receiptPath
$settingsText=[IO.File]::ReadAllText($SettingsPath)
$settings=$settingsText|ConvertFrom-Json
$instance=$settings.providerInstances.$ProviderId
if(-not $instance -or $instance.driver -ne 'codex'){throw 'Choose an existing T3 Codex provider instance.'}
if($TargetProviderId -notmatch '^[a-z][a-z0-9-]{0,63}$' -or $TargetProviderId -eq $ProviderId){throw 'Use a distinct valid target provider ID.'}
if($Operation -eq 'doctor'){
    $config=Read-Hotpl8Json (Join-Path $IntegrationDirectory 'bridge-config.json')
    [pscustomobject]@{
        installed=[bool]$receipt
        connected=($settings.providerInstances.$TargetProviderId.config.binaryPath -eq $launcher -and (Test-Path -LiteralPath $launcher))
        nativeAvailable=[bool]($config.codex -and (Test-Path -LiteralPath $config.codex))
        nodeAvailable=[bool]($config.node -and (Test-Path -LiteralPath $config.node))
        codeAvailable=[bool]($config.script -and (Test-Path -LiteralPath $config.script))
        policyAvailable=(Test-Path -LiteralPath (Join-Path $StateDirectory 'policy.json'))
        scope='New T3 provider processes; existing sessions retain their current provider'
    }|ConvertTo-Json
    exit 0
}
if($Operation -eq 'remove'){
    if(-not $receipt -or $receipt.settingsPath -ne $SettingsPath -or $receipt.providerId -ne $ProviderId -or $receipt.targetProviderId -ne $TargetProviderId){throw 'No matching integration receipt.'}
    if(($settings.providerInstances.$TargetProviderId|ConvertTo-Json -Depth 30 -Compress) -cne ($receipt.installedInstance|ConvertTo-Json -Depth 30 -Compress)){throw 'T3 provider settings changed since install; preserve them and reconcile manually.'}
    # Removal closes this provider in T3. Refuse while the desktop is running;
    # callers using another T3 server must stop that server first as documented.
    if($SettingsPath -eq [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.t3/userdata/settings.json')) -and (Get-Process -Name 'T3 Code (Alpha)','T3 Code' -ErrorAction SilentlyContinue)){throw 'Close T3 before removal so active integration sessions are not interrupted.'}
    $settings.providerInstances.PSObject.Properties.Remove($TargetProviderId)
    if($receipt.changedDefault -and ($settings.defaultModelSelection|ConvertTo-Json -Depth 20 -Compress) -ceq ($receipt.installedDefault|ConvertTo-Json -Depth 20 -Compress)){
        $settings.defaultModelSelection=$receipt.originalDefault
    }
    if([IO.File]::ReadAllText($SettingsPath) -cne $settingsText){throw 'T3 settings changed concurrently; retry.'}
    Write-Hotpl8Text $SettingsPath ($settings|ConvertTo-Json -Depth 50) -NoBom
    # Retain binaries/receipt for already-running sessions and inspection. No process killing.
    'HotPl8 provider removed. Original T3 provider and unrelated settings preserved.'
    exit 0
}
if($receipt){throw 'Integration already has a receipt. Remove it or choose a new integration directory for an upgrade.'}
if($settings.providerInstances.PSObject.Properties[$TargetProviderId]){throw 'Target provider already exists; choose another target ID.'}
if($instance.config.shadowHomePath){throw 'Clear the T3 shadow home before installation; this integration uses the existing shared home.'}
if($instance.config.launchArgs){throw 'Review and clear custom launch arguments before installation.'}
$shared=if($instance.config.homePath){[Environment]::ExpandEnvironmentVariables([string]$instance.config.homePath)}else{Join-Path $env:USERPROFILE '.codex'}
if($shared.StartsWith('~/') -or $shared.StartsWith('~\')){$shared=Join-Path $env:USERPROFILE $shared.Substring(2)}
if(-not [IO.Path]::IsPathRooted($shared) -or -not (Test-Path -LiteralPath $shared -PathType Container)){throw 'T3 shared home must exist at an absolute path.'}
$native=Resolve-CodexExecutable $CodexExecutable
if(-not $NodeExecutable){$NodeExecutable=(Get-Command node -ErrorAction Stop).Source}
$NodeExecutable=[IO.Path]::GetFullPath($NodeExecutable)
if([IO.Path]::GetExtension($NodeExecutable) -ne '.exe' -or -not (Test-Path -LiteralPath $NodeExecutable)){throw 'A native Node executable is required.'}
$nodeVersion=& $NodeExecutable --version
if($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^v(\d+)\.' -or [int]$Matches[1] -lt 22){throw 'Node 22 or newer is required for this optional integration.'}
$policy=Read-Hotpl8Json (Join-Path $StateDirectory 'policy.json')
Assert-Hotpl8Policy $policy
if(-not $policy.codex.slots){throw 'Enroll Codex accounts and refresh HotPl8 first.'}
$instance=$instance|ConvertTo-Json -Depth 30|ConvertFrom-Json
$originalDefault=$settings.defaultModelSelection|ConvertTo-Json -Depth 20|ConvertFrom-Json
[void][IO.Directory]::CreateDirectory($IntegrationDirectory)
$lock=$null
try{
    $lock=[IO.File]::Open((Join-Path $IntegrationDirectory 'setup.lock'),'OpenOrCreate','ReadWrite','None')
    if(Test-Path -LiteralPath $receiptPath){throw 'Integration was installed concurrently.'}
    # Pin a complete source snapshot, independent of working tree edits and app updates.
    $manifest=Read-Hotpl8Json (Join-Path $PSScriptRoot 'release-files.json')
    $code=Join-Path $IntegrationDirectory ('code-'+[guid]::NewGuid().ToString('N'))
    $inventory=@()
    foreach($relative in $manifest.files){
        $source=Join-Path $PSScriptRoot $relative
        $target=Join-Path $code $relative
        [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
        [IO.File]::Copy($source,$target,$false)
        $inventory+=($relative+':'+(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant())
    }
    $config=[pscustomobject]@{schemaVersion=1;node=$NodeExecutable;script=(Join-Path $code 'src/t3-codex.mjs');powershell=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe');codex=$native;stateDirectory=$StateDirectory;sharedHome=[IO.Path]::GetFullPath($shared)}
    Write-Hotpl8Text (Join-Path $IntegrationDirectory 'bridge-config.json') ($config|ConvertTo-Json) -NoBom
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'src/t3-launcher.cs'))) -ReferencedAssemblies System.Web.Extensions -OutputAssembly $launcher -OutputType ConsoleApplication
    $instance.config.binaryPath=$launcher
    $instance|Add-Member NoteProperty displayName 'HotPl8 Codex' -Force
    $settings.providerInstances|Add-Member NoteProperty $TargetProviderId $instance
    $changedDefault=$MakeDefault -and $settings.defaultModelSelection.instanceId -eq $ProviderId
    if($changedDefault){$settings.defaultModelSelection.instanceId=$TargetProviderId}
    $receipt=[pscustomobject]@{schemaVersion=1;settingsPath=$SettingsPath;providerId=$ProviderId;targetProviderId=$TargetProviderId;sourceDigest=(Get-Hotpl8Hash ($inventory -join "`n"));installedInstance=$instance;changedDefault=[bool]$changedDefault;originalDefault=$originalDefault;installedDefault=$settings.defaultModelSelection;installedAt=[datetimeoffset]::UtcNow.ToString('o')}
    Write-Hotpl8Text $receiptPath ($receipt|ConvertTo-Json -Depth 40) -NoBom
    if([IO.File]::ReadAllText($SettingsPath) -cne $settingsText){throw 'T3 settings changed concurrently; configuration was not applied. Inspect the receipt before retrying.'}
    Write-Hotpl8Text $SettingsPath ($settings|ConvertTo-Json -Depth 50) -NoBom
    'HotPl8 Codex added to T3. Select it for existing threads; the original provider is unchanged. Run setup-t3.ps1 -Operation doctor to inspect it.'
}finally{if($lock){$lock.Dispose()}}
