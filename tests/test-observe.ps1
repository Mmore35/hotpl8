# delivery/observe.ps1 judges a scenario by running two readers, the candidate's and its
# baseline's, over the same fictional state at each simulated time. Here both readers are a
# stand-in whose answer a file beside it chooses, so a verdict can be tested in both
# directions: a real change passes, the same change backwards fails, and a reader that
# breaks is never a PASS. What live_preview.py hands it is tests/test_live_preview.py.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/native.ps1')
if($env:OS -ne 'Windows_NT'){'Observe: skipped; the stand-in reader is built with Windows PowerShell.';exit 0}
$shell=(Get-Process -Id $PID).Path
$desktop=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$observe=Join-Path $root 'delivery/observe.ps1'
$lab=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-observe-test-'+[guid]::NewGuid().ToString('N'))
$reader='bin/windows/hotpl8-native.exe'
$script:passed=0;$script:failed=0
function Assert($Value,$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check($Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message+' at '+$_.ScriptStackTrace}}

# say: what every surface answers. late, lateAt: a line added once the clock reaches lateAt.
# crash: the surface that exits 3. write: a file it leaves in the state directory.
$fakeSource=@'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
public class ObserveFake {
 public static int Main(string[] args) {
  var here = Path.GetDirectoryName(System.Reflection.Assembly.GetEntryAssembly().Location);
  var config = new Dictionary<string, string>();
  foreach (var line in File.ReadAllLines(Path.Combine(here, "fake.txt"))) {
   var i = line.IndexOf('=');
   if (i > 0) config[line.Substring(0, i)] = line.Substring(i + 1);
  }
  var surface = args.Length > 0 ? args[0] : "";
  string now = "", root = "", state = "", v;
  var json = surface == "tray";
  for (var i = 1; i < args.Length; i++) {
   if (args[i] == "--now" && i + 1 < args.Length) now = args[++i];
   else if (args[i] == "--root" && i + 1 < args.Length) root = args[++i];
   else if (args[i] == "--state" && i + 1 < args.Length) state = args[++i];
   else if (args[i] == "-AsJson") json = true;
  }
  if (config.TryGetValue("crash", out v) && v == surface) { Console.Error.Write("fictional crash in " + root); return 3; }
  if (config.TryGetValue("write", out v)) File.WriteAllText(Path.Combine(state, v), "x");
  var local = Environment.GetEnvironmentVariable("LOCALAPPDATA");
  if (!string.IsNullOrEmpty(local)) File.WriteAllText(Path.Combine(local, "observe-fake-touched"), "x");
  var say = config.TryGetValue("say", out v) ? v : "";
  var late = config.TryGetValue("late", out v) && config.ContainsKey("lateAt") && string.CompareOrdinal(now, config["lateAt"]) >= 0 ? v : "";
  var text = json
   ? "{\"surface\":\"" + surface + "\",\"say\":\"" + say + "\",\"late\":" + (late.Length > 0 ? "true" : "false") + "}"
   : surface + ": " + say + (late.Length > 0 ? "\n" + late : "") + "\nreleased from " + root + "\nstate " + state + "\n";
  var bytes = new UTF8Encoding(false).GetBytes(text);
  using (var stdout = Console.OpenStandardOutput()) stdout.Write(bytes, 0, bytes.Length);
  return 0;
 }
}
'@
function New-Side([string]$Name,[hashtable]$Config,[switch]$Source){
    $dir=Join-Path $lab $Name
    if(Test-Path -LiteralPath $dir){Remove-Item -LiteralPath $dir -Recurse -Force}
    $bin=Join-Path $dir 'bin/windows';[void][IO.Directory]::CreateDirectory($bin)
    [IO.File]::Copy($script:fake,(Join-Path $dir $reader))
    Write-Hotpl8Text (Join-Path $bin 'fake.txt') ((@($Config.Keys|ForEach-Object{$_+'='+$Config[$_]})) -join "`n")
    if($Source){
        # The fixture observe.ps1 builds the state from is the candidate's own.
        foreach($part in 'src','tests/fixtures'){Copy-Item -LiteralPath (Join-Path $root $part) -Destination (Join-Path $dir $part) -Recurse}
    }
    return $dir
}
function Invoke-Observe($Plan,[string]$Name){
    $scenario=Join-Path $lab ($Name+'.json')
    Write-Hotpl8Text $scenario ($Plan|ConvertTo-Json -Depth 10)
    $report=Join-Path $lab ('report-'+$Name)
    $result=Invoke-Hotpl8NativeProcess $desktop @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$observe,
        '-Candidate',(Join-Path $lab 'candidate'),'-Baseline',(Join-Path $lab 'baseline'),'-Scenario',$scenario,'-Report',$report,
        '-CandidateSha',('a'*40),'-BaselineSha',('b'*40),'-Pr','34')
    $summary=$null
    if(Test-Path -LiteralPath (Join-Path $report 'report.json')){$summary=Get-Content -LiteralPath (Join-Path $report 'report.json') -Raw -Encoding UTF8|ConvertFrom-Json}
    return [pscustomobject]@{exitCode=$result.exitCode;output=$result.output;errors=$result.errors;report=$report;summary=$summary}
}
$visible=@{claim='The dashboard says new words'
    steps=@(@{name='start';at='0'},@{name='plus3h';at='+3h'})
    checks=@(@{name='new words drawn';step='start';capture='watch-100x26-plain';text='new words';candidate=$true;baseline=$false},
             @{step='plus3h';capture='tray';json='say';candidate='new words';baseline='old words'})}
$none=@{claim='Only documentation changes';change='none';reason='No reader or fixture file changes'}

try{
    [void][IO.Directory]::CreateDirectory($lab)
    $script:fake=Join-Path $lab 'fake.exe'
    # PowerShell 7 cannot build a program; the Windows PowerShell beside it can.
    $source=Join-Path $lab 'fake.cs';Write-Hotpl8Text $source $fakeSource
    $compile="Add-Type -TypeDefinition ([IO.File]::ReadAllText('"+$source.Replace("'","''")+"')) -OutputAssembly '"+$script:fake.Replace("'","''")+"' -OutputType ConsoleApplication"
    $null=Invoke-Hotpl8NativeProcess $desktop @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$compile)
    if(-not [IO.File]::Exists($script:fake)){throw 'Could not build the stand-in reader.'}

    Check 'a claimed change passes forward and fails when the two sides are swapped' {
        $null=New-Side candidate @{say='new words'} -Source;$null=New-Side baseline @{say='old words'}
        $result=Invoke-Observe $visible 'forward'
        Assert ($result.exitCode -eq 0 -and $result.output.Contains('Observed: PASS')) ($result.output+$result.errors)
        Assert ($result.summary.verdict -eq 'PASS' -and @($result.summary.checks|Where-Object{$_.met}).Count -eq 2) ($result.summary|ConvertTo-Json -Depth 6)
        # Every surface, both sides, every step: 14 captures each.
        Assert (@(Get-ChildItem -LiteralPath (Join-Path $result.report 'frames') -Recurse -File).Count -eq 56) 'frame count'
        Assert ([IO.File]::ReadAllText((Join-Path $result.report 'frames/candidate/start/watch-100x26-plain.txt')).StartsWith('watch: new words')) 'candidate frame'
        Assert ([IO.File]::Exists((Join-Path $result.report 'report.md')) -and [IO.File]::Exists((Join-Path $result.report 'scenario.json'))) 'report files'
        $null=New-Side candidate @{say='old words'} -Source;$null=New-Side baseline @{say='new words'}
        $result=Invoke-Observe $visible 'swapped'
        Assert ($result.exitCode -eq 10 -and $result.summary.verdict -eq 'FAIL' -and @($result.summary.reasons) -contains '2 of 2 checks not met') ($result.output+$result.errors)
        Assert ([IO.File]::ReadAllText((Join-Path $result.report 'report.md')).Contains('**no**')) 'report.md marks the unmet checks'
    }
    Check 'a check measures the change, so a baseline that already shows it fails' {
        $null=New-Side candidate @{say='new words'} -Source;$null=New-Side baseline @{say='new words'}
        $result=Invoke-Observe $visible 'already'
        Assert ($result.exitCode -eq 10) ($result.output+$result.errors)
        $first=@($result.summary.checks)[0]
        Assert ($first.observed.candidate -eq 'present' -and $first.observed.baseline -eq 'present' -and -not $first.met) ($first|ConvertTo-Json -Depth 4)
    }
    Check 'each step is drawn at its own simulated time' {
        # The candidate shows a message three hours later than main does.
        $null=New-Side candidate @{say='same';late='probe failed';lateAt='2026-09-12T15:00:00Z'} -Source
        $null=New-Side baseline @{say='same';late='probe failed';lateAt='2026-09-12T12:00:00Z'}
        $plan=@{claim='probe failed waits three hours';steps=@(@{name='start';at='0'},@{name='plus2h';at='+2h'},@{name='plus3h';at='+3h'})
            checks=@(@{step='start';capture='status';text='probe failed';candidate=$false;baseline=$true},
                     @{step='plus2h';capture='watch-80x24-ansi';text='probe failed';candidate=$false;baseline=$true},
                     @{step='plus3h';capture='status-json';json='late';candidate='true';baseline='true'})}
        $result=Invoke-Observe $plan 'clock'
        Assert ($result.exitCode -eq 0) ($result.output+$result.errors+($result.summary|ConvertTo-Json -Depth 6))
        Assert ((@($result.summary.steps|ForEach-Object{$_.now}) -join ',') -ceq '2026-09-12T12:00:00Z,2026-09-12T14:00:00Z,2026-09-12T15:00:00Z') 'step times'
    }
    Check 'no visible change: identical answers pass and any difference fails' {
        $null=New-Side candidate @{say='same'} -Source;$null=New-Side baseline @{say='same'}
        $result=Invoke-Observe $none 'none'
        # The two releases live at different paths; their answers still compare equal.
        Assert ($result.exitCode -eq 0 -and @($result.summary.differences).Count -eq 0) ($result.output+$result.errors)
        Assert ([IO.File]::ReadAllText((Join-Path $result.report 'frames/baseline/start/status.txt')).Contains('released from <root>')) 'paths hidden'
        $null=New-Side baseline @{say='drifted'}
        $result=Invoke-Observe $none 'drift'
        Assert ($result.exitCode -eq 10 -and @($result.summary.differences).Count -eq 14) ($result.output+@($result.summary.differences).Count)
    }
    Check 'a reader that fails, or is missing, is a FAIL and never a PASS' {
        $null=New-Side candidate @{say='same';crash='explain'} -Source;$null=New-Side baseline @{say='same'}
        $result=Invoke-Observe $none 'crash'
        Assert ($result.exitCode -eq 10 -and @($result.summary.reasons) -contains 'not every surface answered on both sides') ($result.output+$result.errors)
        Assert (@($result.summary.problems) -contains 'candidate at start, explain: exit 3: fictional crash in <root>') (@($result.summary.problems) -join ';')
        $null=New-Side candidate @{say='same'} -Source
        [IO.File]::Delete((Join-Path $lab ('candidate/'+$reader)))
        $result=Invoke-Observe $none 'missing'
        Assert ($result.exitCode -eq 10 -and (@($result.summary.problems) -join ';').Contains('ships no compiled reader')) ($result.output+$result.errors)
    }
    Check 'it writes only inside its report and keeps no path from this machine' {
        $null=New-Side candidate @{say='same';write='collector.json'} -Source;$null=New-Side baseline @{say='same'}
        $outside={@(Get-ChildItem -LiteralPath $lab -Recurse -File|Where-Object{-not $_.FullName.StartsWith((Join-Path $lab 'report-'))}|ForEach-Object{$_.FullName+'|'+$_.Length+'|'+$_.LastWriteTimeUtc.Ticks})}
        $before=& $outside
        $result=Invoke-Observe $none 'contained'
        $after=@(& $outside|Where-Object{$_ -notlike ((Join-Path $lab 'contained.json')+'|*')})
        $before=@($before|Where-Object{$_ -notlike ((Join-Path $lab 'contained.json')+'|*')})
        Assert (-not (Compare-Object $before $after)) ((Compare-Object $before $after|Out-String))
        # The reader's own writes are recorded, and its home is the lab's.
        Assert (@($result.summary.stateWrites) -contains 'candidate at start wrote collector.json') (@($result.summary.stateWrites) -join ';')
        Assert ([IO.File]::Exists((Join-Path (Join-Path (Join-Path $result.report 'lab') 'home') 'AppData/Local/observe-fake-touched'))) 'home redirected'
        foreach($file in Get-ChildItem -LiteralPath $result.report -Recurse -File|Where-Object{$_.FullName -notlike '*\lab\*'}){
            $text=[IO.File]::ReadAllText($file.FullName)
            foreach($form in @($lab,$lab.Replace('\','/'),$lab.Replace('\','\\'),$env:USERNAME)){
                Assert ($text.IndexOf($form,[StringComparison]::OrdinalIgnoreCase) -lt 0) ($file.FullName+' holds '+$form)
            }
        }
    }
    Check 'an unusable scenario is refused before anything is judged' {
        $null=New-Side candidate @{say='same'} -Source;$null=New-Side baseline @{say='same'}
        $plans=@(@{change='none';reason='x'},@{claim='no checks'},@{claim='x';change='none'},@{claim='x';change='sideways';reason='x'},
            @{claim='x';checks=@(@{step='later';capture='status';text='x';candidate=$true;baseline=$false})},
            @{claim='x';checks=@(@{step='start';capture='nowhere';text='x';candidate=$true;baseline=$false})},
            @{claim='x';checks=@(@{step='start';capture='status';text='x';candidate=$true})})
        for($i=0;$i -lt $plans.Count;$i++){
            $result=Invoke-Observe $plans[$i] ('invalid'+$i)
            Assert ($result.exitCode -eq 1 -and -not $result.summary -and $result.errors.Contains('Invalid observe scenario')) ([string]$i+': '+$result.exitCode+' '+$result.errors)
        }
    }
}finally{
    $full=[IO.Path]::GetFullPath($lab)
    if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-observe-test-[a-f0-9]{32}$' -and (Test-Path -LiteralPath $full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
'Observe: '+$script:passed+' passed, '+$script:failed+' failed.'
if($script:failed){exit 1}
