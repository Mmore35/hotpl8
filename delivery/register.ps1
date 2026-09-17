# Install only the updater task. Existing collectors are preserved separately.
param([string]$InstallDirectory,[string]$Python)
$ErrorActionPreference='Stop'
$config=Get-Content -LiteralPath (Join-Path $InstallDirectory 'delivery.json') -Raw -Encoding UTF8|ConvertFrom-Json
$name='LocalDelivery-'+$config.product
$description='Local Delivery owned installation '+$InstallDirectory
$existing=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
if($existing -and $existing.Description -ne $description){throw 'Updater task ownership mismatch.'}
$launcher=Join-Path $InstallDirectory 'update-launcher.vbs'
$body='CreateObject("Wscript.Shell").Run """'+$Python+'"" ""'+(Join-Path $InstallDirectory 'delivery.py')+'"" update", 0, True'
[IO.File]::WriteAllText($launcher,$body,(New-Object Text.UTF8Encoding($false)))
$action=New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"'+$launcher+'"') -WorkingDirectory $InstallDirectory
$periodic=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
$logon=New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
$settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$task=New-ScheduledTask -Action $action -Trigger @($periodic,$logon) -Settings $settings -Principal $principal -Description $description
Register-ScheduledTask -TaskName $name -InputObject $task -Force|Out-Null
