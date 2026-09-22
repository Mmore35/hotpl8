# Execute the real registrar with inert command substitutes in a disposable tree.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$lab=Join-Path ([IO.Path]::GetTempPath()) ('delivery-owner-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path (Join-Path $lab 'delivery'),(Join-Path $lab 'src'),(Join-Path $lab 'install') -Force
Copy-Item -LiteralPath (Join-Path $root 'delivery/register.ps1') -Destination (Join-Path $lab 'delivery/register.ps1')
$common=@'
function Read-Hotpl8Json($Path){if(Test-Path -LiteralPath $Path){Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}}
function Write-Hotpl8Text($Path,$Text,[switch]$NoBom){[IO.File]::WriteAllText($Path,$Text)}
function ConvertTo-NativeArgument($Value){'"'+$Value+'"'}
'@
$common|Set-Content -LiteralPath (Join-Path $lab 'src/common.ps1')
'function Install-Hotpl8JobHost($Root){Join-Path $Root "fixture.exe"}'|Set-Content -LiteralPath (Join-Path $lab 'src/job-host.ps1')
'function Get-Hotpl8TaskDefinition($Owned,$Install){@{description="fixture collector";execute="fixture.exe";arguments="collect"}}'|Set-Content -LiteralPath (Join-Path $lab 'src/lifecycle.ps1')
$install=Join-Path $lab 'install';$entry=Join-Path $lab 'manager.py'
'# fixture'|Set-Content -LiteralPath $entry
$config=@{product='fixture';stateDirectory=$lab;scheduledJobs=@{collectorTask='collector-fixture'}}
$config|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $install 'delivery.json')
@{product='hotpl8';stateDirectory=$lab}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $install 'installation.json')
@{protocol=1;entry=$entry;entrySha256=(Get-FileHash $entry).Hash}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $install 'delivery-owner.json')
$global:deliveryFixtureUpdater=$null;$global:deliveryFixtureChanges=@()
function Get-ScheduledTask($TaskName){if($TaskName -eq 'LocalDelivery-fixture'){$global:deliveryFixtureUpdater}else{@{TaskName=$TaskName;Description='fixture collector'}}}
function Register-ScheduledTask{throw 'Central owner must never recreate product updater'}
function New-ScheduledTaskAction($Execute,$Argument,$WorkingDirectory){@{Execute=$Execute;Arguments=$Argument}}
function Set-ScheduledTask($TaskName,$Action){$global:deliveryFixtureChanges+=@($TaskName);if($TaskName -ne 'collector-fixture'){throw 'Product updater action was changed'}}
function Export-ScheduledTask($TaskName){'<fixture />'}
function Assert($ok,$message){if(-not $ok){throw $message};'PASS '+$message}
try{
    & (Join-Path $lab 'delivery/register.ps1') -InstallDirectory $install -Python 'fixture-python.exe'|Out-Null
    Assert ($global:deliveryFixtureChanges.Count -eq 1 -and $global:deliveryFixtureChanges[0] -eq 'collector-fixture') 'missing product updater stays absent and collector still updates'
    $global:deliveryFixtureChanges=@();$global:deliveryFixtureUpdater=@{TaskName='LocalDelivery-fixture';Description=('Local Delivery owned installation '+$install);Settings=@{Enabled=$false}}
    & (Join-Path $lab 'delivery/register.ps1') -InstallDirectory $install -Python 'fixture-python.exe'|Out-Null
    Assert ($global:deliveryFixtureChanges.Count -eq 1 -and -not $global:deliveryFixtureUpdater.Settings.Enabled) 'disabled recovery task stays disabled and untouched'
    $global:deliveryFixtureChanges=@();$global:deliveryFixtureUpdater.Settings.Enabled=$true;$refused=$false
    try{& (Join-Path $lab 'delivery/register.ps1') -InstallDirectory $install -Python 'fixture-python.exe'|Out-Null}catch{$refused=$_.Exception.Message -match 'remain disabled'}
    Assert ($refused -and $global:deliveryFixtureChanges.Count -eq 0) 'competing enabled updater refuses activation'
    'changed'|Set-Content -LiteralPath $entry;$refused=$false
    try{& (Join-Path $lab 'delivery/register.ps1') -InstallDirectory $install -Python 'fixture-python.exe'|Out-Null}catch{$refused=$_.Exception.Message -match 'Invalid central'}
    Assert $refused 'invalid manager identity fails closed'
}finally{
    $resolved=[IO.Path]::GetFullPath($lab);$temporary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not $resolved.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'delivery-owner-*'){throw 'Unexpected fixture cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
