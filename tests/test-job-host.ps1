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
    Remove-Item -LiteralPath $full -Recurse -Force
}
