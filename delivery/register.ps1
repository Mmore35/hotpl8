# Native trigger policy stays here. Immutable hosts permit next-wake replacement
# while an admitted updater finishes with its own loaded version and locks.
param([string]$InstallDirectory,[string]$Python,[switch]$PlanOnly,
      [string]$CollectorTaskName,[string]$AdoptCollectorLauncher)
$ErrorActionPreference='Stop'
$release=Split-Path $PSScriptRoot -Parent
. (Join-Path $release 'src/common.ps1')
. (Join-Path $release 'src/job-host.ps1')
. (Join-Path $release 'src/lifecycle.ps1')
$config=Read-Hotpl8Json (Join-Path $InstallDirectory 'delivery.json')
$name='LocalDelivery-'+$config.product
$description='Local Delivery owned installation '+$InstallDirectory
$exe=Install-Hotpl8JobHost $InstallDirectory
$argv=@('540',(Join-Path $InstallDirectory 'job-runs/updater'),$InstallDirectory,$Python,(Join-Path $InstallDirectory 'delivery.py'),'update')
$arguments=(@($argv|ForEach-Object{ConvertTo-NativeArgument $_}) -join ' ')
$plan=@{name=$name;description=$description;execute=$exe;arguments=$arguments}
if($PlanOnly){$plan|ConvertTo-Json;return}
$existing=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
if($existing -and $existing.Description -ne $description){throw 'Updater task ownership mismatch.'}
$collector=$null;$collectorDefinition=$null
if(-not $CollectorTaskName -and $config.scheduledJobs){$CollectorTaskName=$config.scheduledJobs.collectorTask}
if($CollectorTaskName){
    $owned=Read-Hotpl8Json (Join-Path $InstallDirectory 'installation.json')
    if(-not $owned -or $owned.product -ne 'hotpl8' -or $owned.stateDirectory -ine $config.stateDirectory){throw 'Collector binding mismatch.'}
    $collectorDefinition=Get-Hotpl8TaskDefinition $owned $InstallDirectory
    $collector=Get-ScheduledTask -TaskName $CollectorTaskName -ErrorAction Stop
    $managed=$config.scheduledJobs -and $config.scheduledJobs.collectorTask -eq $CollectorTaskName
    if(-not $managed -and $collector.Description -ne $collectorDefinition.description){
        if(-not $AdoptCollectorLauncher -or $collector.Actions.Count -ne 1 -or $collector.Actions[0].Arguments.Trim('"') -ine [IO.Path]::GetFullPath($AdoptCollectorLauncher) -or $collector.Actions[0].Execute -notmatch '(^|[\\/])wscript(?:\.exe)?$'){throw 'Legacy collector ownership mismatch.'}
    }
}
$recovery=Join-Path $InstallDirectory ('job-recovery/'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff'))
$null=New-Item -ItemType Directory -Path $recovery -Force
foreach($task in @($existing,$collector)){
    if($task){Export-ScheduledTask -TaskName $task.TaskName|Set-Content -LiteralPath (Join-Path $recovery (($task.TaskName -replace '[^a-zA-Z0-9_.-]','_')+'.xml')) -Encoding Unicode}
}
$action=New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory $InstallDirectory
if($existing){
    # Set only Actions: logon+interval, identity, battery and enabled state survive.
    Set-ScheduledTask -TaskName $name -Action $action|Out-Null
}else{
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    $periodic=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $logon=New-ScheduledTaskTrigger -AtLogOn -User $user
    $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $name -InputObject (New-ScheduledTask -Action $action -Trigger @($periodic,$logon) -Settings $settings -Principal $principal -Description $description)|Out-Null
}
if($collector){
    $ca=New-ScheduledTaskAction -Execute $collectorDefinition.execute -Argument $collectorDefinition.arguments -WorkingDirectory $InstallDirectory
    Set-ScheduledTask -TaskName $CollectorTaskName -Action $ca|Out-Null
}
$actual=Get-ScheduledTask -TaskName $name
if($actual.Actions.Count -ne 1 -or $actual.Actions[0].Execute -ne $exe -or $actual.Actions[0].Arguments -ne $arguments){throw 'Updater action verification failed.'}
$config|Add-Member NoteProperty scheduledJobs @{version=1;collectorTask=$CollectorTaskName;host=$exe;at=[DateTime]::UtcNow.ToString('o');recovery=$recovery} -Force
Write-Hotpl8Text (Join-Path $InstallDirectory 'delivery.json') ($config|ConvertTo-Json -Depth 12) -NoBom
$plan|ConvertTo-Json
