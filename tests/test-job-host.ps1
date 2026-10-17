# Actual native containment, synthetic workers only. -Native also creates one
# uniquely named task to prove action replacement preserves admitted work.
param([switch]$Native)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/job-host.ps1')
$lab=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-host-test-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $lab
$taskName='Hotpl8-host-fixture-'+[guid]::NewGuid().ToString('N')
$registered=$false;$owned=@();$passed=0
function Assert($ok,[string]$message){if(-not $ok){throw $message};$script:passed++;'PASS '+$message}
function Start-FixtureHost([int]$Seconds,[string]$Script){
    $argv=if([IO.Path]::GetExtension($Script) -eq '.exe'){@([string]$Seconds,(Join-Path $lab 'runs'),$lab,$Script)}else{@([string]$Seconds,(Join-Path $lab 'runs'),$lab,(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'),'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Script)}
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$script:hostExe;$psi.Arguments=(@($argv|ForEach-Object{ConvertTo-NativeArgument $_}) -join ' ')
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $p=[Diagnostics.Process]::Start($psi);$script:owned+=@($p);return $p
}
try{
    $hostExe=Install-Hotpl8JobHost $lab
    Assert ((Install-Hotpl8JobHost $lab) -eq $hostExe) 'immutable host reinstall selects the same path'
    $worker=Join-Path $lab 'worker.ps1'
    'exit 7'|Set-Content -LiteralPath $worker
    $p=Start-FixtureHost 10 $worker;$p.WaitForExit()
    Assert ($p.ExitCode -eq 7) 'GUI host propagates exit 7'
    $receipt=Get-ChildItem (Join-Path $lab 'runs') -Filter run.json -Recurse|Select-Object -First 1|Get-Content -Raw|ConvertFrom-Json
    Assert ($receipt.status -eq 'failed' -and $receipt.exitCode -eq 7 -and $receipt.hostCreatedAt) 'completion identifies this host and failure'
    $latest=Get-Content (Join-Path $lab 'runs/latest.json') -Raw|ConvertFrom-Json
    Assert ($latest.runId -eq $receipt.runId -and $latest.status -eq 'failed' -and $latest.completedAt -eq $receipt.completedAt) 'the host publishes its final receipt as latest.json'
    Assert (-not @(Get-ChildItem (Join-Path $lab 'runs') -Filter '*.tmp' -File)) 'publishing leaves no staged file'
    # Each folder is judged by its own receipt and created that many days ago.
    function New-FixtureRun([string]$Name,[int]$Days,$Receipt){
        $run=Join-Path $lab ('runs/'+$Name);$null=New-Item -ItemType Directory -Path $run
        if($Receipt -is [string]){$Receipt|Set-Content -LiteralPath (Join-Path $run 'run.json')}
        elseif($Receipt){$Receipt|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $run 'run.json')}
        (Get-Item -LiteralPath $run).CreationTimeUtc=[DateTime]::UtcNow.AddDays(-$Days)
    }
    $ago={param($d)[DateTime]::UtcNow.AddDays(-$d).ToString('o')}
    New-FixtureRun 'complete-8d' 8 @{status='complete';startedAt=(& $ago 8);completedAt=(& $ago 8)}
    New-FixtureRun 'complete-1d' 1 @{status='complete';startedAt=(& $ago 1);completedAt=(& $ago 1)}
    New-FixtureRun 'complete-new-folder' 0 @{status='complete';startedAt=(& $ago 8);completedAt=(& $ago 8)}
    New-FixtureRun 'failed-10d' 10 @{status='failed';startedAt=(& $ago 10);completedAt=(& $ago 10)}
    New-FixtureRun 'timed-out-31d' 31 @{status='timed-out';startedAt=(& $ago 31);completedAt=(& $ago 31)}
    New-FixtureRun 'running-31d' 31 @{status='running';startedAt=(& $ago 31)}
    New-FixtureRun 'unreadable-40d' 40 '{'
    New-FixtureRun 'no-receipt-40d' 40 $null
    'exit 0'|Set-Content -LiteralPath $worker
    $p=Start-FixtureHost 10 $worker;$p.WaitForExit()
    $left=@(Get-ChildItem (Join-Path $lab 'runs') -Directory|ForEach-Object Name)
    Assert ($p.ExitCode -eq 0) 'a wake that removes old runs keeps its exit code'
    Assert (-not ($left -match '^(complete-8d|timed-out-31d|running-31d)$')) 'complete runs older than 7 days and others older than 30 are removed'
    Assert (@($left -match '^(complete-1d|complete-new-folder|failed-10d|unreadable-40d|no-receipt-40d)$').Count -eq 5) 'recent runs, failures under 30 days and folders without a readable receipt are kept'
    Assert (@($left -match '^[a-f0-9]{32}$').Count -eq 2) 'every run made by a host is kept'
    Remove-Item -LiteralPath (Join-Path $lab 'runs') -Recurse -Force
    # Native fixture avoids charging two cold PowerShell startups to a four-second
    # fault deadline on a loaded hosted runner. The production deadline is unchanged.
    $treeWorker=Join-Path $lab 'tree-worker.exe'
    Add-Type -TypeDefinition @'
using System; using System.IO; using System.Diagnostics; using System.Threading;
public static class TreeFixture {
 public static int Main(string[] args) {
  string exe=System.Reflection.Assembly.GetExecutingAssembly().Location;
  if(args.Length==0) {
   var p=Process.Start(new ProcessStartInfo(exe,"child"){UseShellExecute=false,CreateNoWindow=true});
   File.WriteAllText(Path.Combine(Path.GetDirectoryName(exe),"child.json"),"{\"pid\":"+p.Id+",\"created\":\""+p.StartTime.ToUniversalTime().ToString("o")+"\"}");
  }
  Thread.Sleep(60000);return 0;
 }
}
'@ -OutputAssembly $treeWorker -OutputType ConsoleApplication
    foreach($mode in @('timeout','abrupt')){
        Remove-Item -LiteralPath (Join-Path $lab 'child.json') -ErrorAction SilentlyContinue
        $p=Start-FixtureHost $(if($mode -eq 'timeout'){4}else{30}) $treeWorker
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        while(-not(Test-Path (Join-Path $lab 'child.json')) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
        $child=Get-Content (Join-Path $lab 'child.json') -Raw|ConvertFrom-Json
        if($mode -eq 'abrupt'){$p.Kill()}
        Assert ($p.WaitForExit(10000)) "$mode host ends within deadline"
        Start-Sleep -Milliseconds 300
        $left=Get-Process -Id $child.pid -ErrorAction SilentlyContinue
        Assert (-not $left -or $left.StartTime.ToUniversalTime().ToString('o') -ne $child.created) "$mode contains the immediate grandchild"
        if($mode -eq 'timeout'){Assert ($p.ExitCode -eq 124) 'timeout has a distinct failure code'}
    }
    # Shadowing the cmdlet keeps the default suite off the real scheduler.
    $install=Join-Path $lab 'install';$null=New-Item -ItemType Directory -Path $install
    @{product='fixture';scheduledJobs=@{version=1;collectorTask='Fixture collector';host=$hostExe}}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $install 'delivery.json')
    function New-FixtureTask([string]$Execute,[bool]$Enabled){[pscustomobject]@{Actions=@([pscustomobject]@{Execute=$Execute});Settings=[pscustomobject]@{Enabled=$Enabled}}}
    function Get-FixtureComponentState([hashtable]$Tasks){
        function Get-ScheduledTask{[CmdletBinding()]param([string]$TaskName) $Tasks[$TaskName]}
        $state=@{};foreach($c in @(Get-Hotpl8JobComponentStatus $install)){$state[$c.component]=$c.state};$state
    }
    $state=Get-FixtureComponentState @{'Fixture collector'=(New-FixtureTask $hostExe $true);'LocalDelivery-fixture'=(New-FixtureTask $hostExe $true)}
    Assert ($state['scheduled-collector'] -eq 'current' -and $state['scheduled-updater'] -eq 'current') 'enabled matching tasks report current'
    $state=Get-FixtureComponentState @{'Fixture collector'=(New-FixtureTask $hostExe $false);'LocalDelivery-fixture'=(New-FixtureTask $hostExe $false)}
    Assert ($state['scheduled-collector'] -eq 'disabled' -and $state['scheduled-updater'] -eq 'disabled') 'a turned-off task reports disabled, not current'
    $state=Get-FixtureComponentState @{'Fixture collector'=(New-FixtureTask $hostExe $true)}
    Assert ($state['scheduled-collector'] -eq 'current' -and $state['scheduled-updater'] -eq 'error') 'a missing task reports error'
    $other=Join-Path $lab 'other-host.exe'
    $state=Get-FixtureComponentState @{'Fixture collector'=(New-FixtureTask $other $true);'LocalDelivery-fixture'=(New-FixtureTask $other $false)}
    Assert ($state['scheduled-collector'] -eq 'error' -and $state['scheduled-updater'] -eq 'error') 'a mismatched task reports error even when turned off'
    # latest.json is read in place of searching the run folders, which only a host from
    # before it leaves behind.
    $runs=Join-Path $install 'job-runs/collector';$null=New-Item -ItemType Directory -Path (Join-Path $runs 'older-host-run') -Force
    @{status='failed';host='scan';completedAt='2030-01-01T12:00:00Z'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $runs 'older-host-run/run.json')
    function Get-FixtureCollector{
        function Get-ScheduledTask{[CmdletBinding()]param([string]$TaskName) New-FixtureTask $hostExe $true}
        @(Get-Hotpl8JobComponentStatus $install)[0]
    }
    Assert ((Get-FixtureCollector).execution -eq 'failed') 'without latest.json the newest receipt in the run folders is read'
    @{status='complete';host='latest';completedAt='2030-01-01T11:00:00Z'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $runs 'latest.json')
    $collector=Get-FixtureCollector
    Assert ($collector.execution -eq 'complete' -and $collector.observedHost -eq 'latest') 'latest.json is read when it is there'
    Remove-Item -LiteralPath (Join-Path $install 'job-runs') -Recurse -Force
    # Every check is stamped in delivery-status.json, whoever started it; a run of the
    # installation's own task also leaves a receipt. Times are seconds before a fixed noon;
    # a string is written as it stands.
    $noon=[datetimeoffset]'2030-01-01T12:00:00Z'
    function Get-FixtureUpdater([bool]$Enabled,$Check,$Started,$Completed,[string]$Execute=$hostExe){
        Remove-Item -LiteralPath (Join-Path $install 'delivery-status.json'),(Join-Path $install 'job-runs') -Recurse -Force -ErrorAction SilentlyContinue
        if($Check -is [string]){@{state='current';lastCheck=$Check}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $install 'delivery-status.json')}
        elseif($null -ne $Check){@{state='current';lastCheck=($noon.AddSeconds(-$Check).ToString('yyyy-MM-ddTHH:mm:ss.ffffff')+'+00:00')}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $install 'delivery-status.json')}
        if($Started -is [string]){$run=Join-Path $install 'job-runs/updater/fixture-run';$null=New-Item -ItemType Directory -Path $run -Force;$Started|Set-Content -LiteralPath (Join-Path $run 'run.json')}
        elseif($null -ne $Started){
            $run=Join-Path $install 'job-runs/updater/fixture-run';$null=New-Item -ItemType Directory -Path $run -Force
            $receipt=@{schemaVersion=1;host=$hostExe;status='running';startedAt=$noon.AddSeconds(-$Started).UtcDateTime.ToString('o')}
            if($null -ne $Completed){$receipt.status='complete';$receipt.completedAt=$noon.AddSeconds(-$Completed).UtcDateTime.ToString('o')}
            $receipt|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $run 'run.json')
        }
        $tasks=@{'Fixture collector'=(New-FixtureTask $hostExe $true);'LocalDelivery-fixture'=(New-FixtureTask $Execute $Enabled)}
        function Get-ScheduledTask{[CmdletBinding()]param([string]$TaskName) $tasks[$TaskName]}
        @(Get-Hotpl8JobComponentStatus $install $noon)
    }
    $rows=Get-FixtureUpdater $false
    Assert ($rows[1].state -eq 'disabled' -and $rows[1].PSObject.Properties['lastCheckAgeSeconds'] -and $null -eq $rows[1].lastCheckAgeSeconds) 'a turned-off updater with no check on record reports disabled and no age'
    Assert (-not $rows[0].PSObject.Properties['lastCheck'] -and -not $rows[0].PSObject.Properties['lastCheckAgeSeconds']) 'the collector row carries no updater check'
    $updater=(Get-FixtureUpdater $false 120)[1]
    Assert ($updater.state -eq 'external' -and $updater.lastCheckAgeSeconds -eq 120 -and $updater.lastCheck -eq '2030-01-01T11:58:00.000000+00:00') 'a turned-off updater that never ran, checked two minutes ago, reports external and the age'
    Assert ((Get-FixtureUpdater $false 120 125 110)[1].state -eq 'disabled') 'a check made by the task''s own last run does not report external'
    Assert ((Get-FixtureUpdater $false 120 610 600)[1].state -eq 'external') 'a check stamped after the task''s own last run ended reports external'
    $updater=(Get-FixtureUpdater $false 7200)[1]
    Assert ($updater.state -eq 'disabled' -and $updater.lastCheckAgeSeconds -eq 7200) 'two hours without a check reports disabled again, with the age'
    Assert ((Get-FixtureUpdater $false 3600)[1].state -eq 'external' -and (Get-FixtureUpdater $false 3601)[1].state -eq 'disabled') 'the last check counts for one hour'
    Assert ((Get-FixtureUpdater $false 120 300)[1].state -eq 'disabled') 'a check inside the time allowed to a run that left no completion is that run''s own'
    Assert ((Get-FixtureUpdater $false 120 900)[1].state -eq 'external') 'a check after the time allowed to a run that left no completion is from outside'
    Assert ((Get-FixtureUpdater $false 120 '{')[1].state -eq 'disabled' -and (Get-FixtureUpdater $false 120 '{"status":"running"}')[1].state -eq 'disabled') 'a receipt that cannot be read, or holds no time, does not report external'
    $updater=(Get-FixtureUpdater $false (-60))[1]
    Assert ($updater.state -eq 'disabled' -and $updater.lastCheckAgeSeconds -eq -60) 'a check stamped in the future does not report external'
    $updater=(Get-FixtureUpdater $false 'soon')[1]
    Assert ($updater.state -eq 'disabled' -and $updater.lastCheck -eq 'soon' -and $null -eq $updater.lastCheckAgeSeconds) 'a check time that cannot be read reports disabled and no age'
    $updater=(Get-FixtureUpdater $true 120)[1]
    Assert ($updater.state -eq 'current' -and $updater.lastCheckAgeSeconds -eq 120) 'a turned-on updater reports current and the age of its last check'
    Assert ((Get-FixtureUpdater $false 120 -Execute $other)[1].state -eq 'error') 'a mismatched task reports error whatever was checked'
    if($Native){
        'Start-Sleep -Seconds 8; Set-Content (Join-Path $PSScriptRoot "finished.txt") "done"; exit 0'|Set-Content -LiteralPath $worker
        $argv=@('20',(Join-Path $lab 'runs'),$lab,(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'),'-NoProfile','-NonInteractive','-File',$worker)
        $action=New-ScheduledTaskAction -Execute $hostExe -Argument ((@($argv|ForEach-Object{ConvertTo-NativeArgument $_})) -join ' ') -WorkingDirectory $lab
        $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $taskName -InputObject (New-ScheduledTask -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew))|Out-Null
        $registered=$true
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 2
        Assert ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') 'fixture native task owns a live host'
        $nextWorker=Join-Path $lab 'next-worker.ps1'
        'exit 0'|Set-Content -LiteralPath $nextWorker
        $nextArguments=$action.Arguments.Replace($worker,$nextWorker)
        $nextAction=New-ScheduledTaskAction -Execute $hostExe -Argument $nextArguments -WorkingDirectory $lab
        [xml]$before=Export-ScheduledTask -TaskName $taskName
        Set-ScheduledTask -TaskName $taskName -Action $nextAction|Out-Null
        [xml]$after=Export-ScheduledTask -TaskName $taskName
        Assert ($after.Task.Actions.Exec.Arguments -eq $nextArguments -and $before.Task.Settings.OuterXml -eq $after.Task.Settings.OuterXml -and $before.Task.Principals.OuterXml -eq $after.Task.Principals.OuterXml) 'next action changes while native policy stays intact'
        Start-Sleep -Seconds 10
        Assert (Test-Path (Join-Path $lab 'finished.txt')) 'replacing next-wake action lets admitted work complete'
        Assert ((Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult -eq 0) 'native result records admitted completion'
    }
    "Host checks: $passed passed"
}finally{
    if($registered){Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
    foreach($p in $owned){if(-not $p.HasExited){$p.Kill();$p.WaitForExit()};$p.Dispose()}
    $full=[IO.Path]::GetFullPath($lab)
    if((Split-Path $full -Parent) -ne [IO.Path]::GetTempPath().TrimEnd('\','/') -or (Split-Path $full -Leaf) -notmatch '^hotpl8-host-test-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup'}
    # A host that was killed leaves its workers to the system, which ends them a moment later;
    # until then they hold the run's output files open. The removal is tried again until they
    # have gone, and a file still held after ten seconds fails the suite as before.
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while($true){
        try{Remove-Item -LiteralPath $full -Recurse -Force;break}
        catch{if([DateTime]::UtcNow -ge $deadline){throw};Start-Sleep -Milliseconds 200}
    }
}
