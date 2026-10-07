# Ordinary Mac package lifecycle; no launchd jobs or production PATH changes.
$ErrorActionPreference='Stop'
if(-not $IsMacOS){throw 'This suite requires macOS.'}
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/lifecycle.ps1')
$lab=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-macos-install-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($lab)
$shell=(Get-Process -Id $PID).Path
$script:passed=0;$script:failed=0
function Assert($Value,$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check($Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message+' at '+$_.ScriptStackTrace}}
function InstallFixture($Destination,$Source=$root){
 $r=Invoke-Hotpl8Process $shell @('-NoProfile','-File',(Join-Path $Source 'install-macos.ps1'),'-InstallDirectory',$Destination,'-NoPath') 60000
 Assert ($r.exitCode -eq 0) 'Mac fixture install failed'
}
try{
 Check 'fresh Mac install runs its owned command from paths containing spaces and apostrophes' {
  $script:installed=Join-Path $lab "ordinary user's app"
  InstallFixture $script:installed
  $r=Invoke-Hotpl8Process (Join-Path $script:installed 'hotpl8') @('version','-AsJson') 15000
  Assert ($r.exitCode -eq 0 -and ($r.output|ConvertFrom-Json))
  $receipt=Read-Hotpl8Json (Join-Path $script:installed 'installation.json')
  Assert ($receipt.platform -eq 'macos' -and -not $receipt.scheduled -and -not $receipt.pathAdded)
  Assert (([IO.File]::GetUnixFileMode((Join-Path $script:installed 'state')) -band [IO.UnixFileMode]'OtherRead,GroupRead') -eq 0)
 }
 Check 'a schedule starts the installed collector, and a job with either start is this installation''s' {
  # install-macos.ps1 writes this start into the launchd job it creates, and a broken one
  # is silent: it is asserted and run. Nothing here creates or changes a launchd job.
  $state=Join-Path $script:installed 'state';$app=Join-Path $script:installed 'app';$kept=Join-Path $script:installed 'previous'
  $compiled=@((Join-Path $app 'bin/macos/hotpl8-native'),'collect','--root',$app,'--state',$state,'--scheduled','--powershell',$shell)
  $older=@($shell,'-NoProfile','-NonInteractive','-File',(Join-Path $app 'tick.ps1'),'-Scheduled','-StateDirectory',$state)
  Assert ((@(Get-Hotpl8MacCollectorStart $script:installed $state $shell) -join "`n") -ceq ($compiled -join "`n")) 'a fresh installation does not name its collector'
  # rollback.ps1 puts the release under previous back and leaves the job alone. While that
  # release is one from before the collector was compiled, the job gets the start every
  # release answers to.
  [void][IO.Directory]::CreateDirectory($kept)
  try{Assert ((@(Get-Hotpl8MacCollectorStart $script:installed $state $shell) -join "`n") -ceq ($older -join "`n")) 'a release that cannot answer the collector start is kept for a rollback'}
  finally{Remove-Item -LiteralPath $kept -Recurse -Force}
  $label='com.hotpl8.collector.abcdef123456'
  $job={param($Label,$Words) [xml]('<plist version="1.0"><dict><key>Label</key><string>'+$Label+'</string><key>ProgramArguments</key><array>'+(@($Words|ForEach-Object{'<string>'+[Security.SecurityElement]::Escape($_)+'</string>'}) -join '')+'</array><key>StartInterval</key><integer>60</integer></dict></plist>')}
  foreach($start in @(,$compiled)+@(,$older)){Assert (Test-Hotpl8MacCollectorJob (& $job $label $start) $label $script:installed $state) 'an installation does not know its own job'}
  Assert (-not (Test-Hotpl8MacCollectorJob (& $job 'com.hotpl8.collector.000000000000' $compiled) $label $script:installed $state)) 'a job under another label is taken'
  Assert (-not (Test-Hotpl8MacCollectorJob (& $job $label $compiled) $label (Join-Path $lab 'another') $state)) 'another installation''s job is taken'
  Assert (-not (Test-Hotpl8MacCollectorJob (& $job $label $compiled) $label $script:installed (Join-Path $lab 'another state'))) 'a job over another state is taken'
  Assert (-not (Test-Hotpl8MacCollectorJob (& $job $label @($shell,'-File',(Join-Path $app 'hotpl8.ps1'),$state)) $label $script:installed $state)) 'a job that starts no collector is taken'
  $policyPath=Join-Path $state 'policy.json';$original=[IO.File]::ReadAllBytes($policyPath);$homeBefore=$env:HOME;$claudeBefore=$env:CLAUDE_CONFIG_DIR
  try{
   # A preferred slot makes the wake collect. The backoff marker keeps that collection
   # away from cswap, so no account or credential home is touched.
   $env:HOME=Join-Path $lab 'user home';[void][IO.Directory]::CreateDirectory($env:HOME);$env:CLAUDE_CONFIG_DIR=Join-Path $env:HOME 'claude'
   $p=Read-Hotpl8Json $policyPath;$p.prefer=@(1)
   Write-Hotpl8Text $policyPath ($p|ConvertTo-Json -Depth 12) -NoBom
   foreach($start in @(,$compiled)+@(,$older)){
    $now=[datetimeoffset]::UtcNow
    Write-Hotpl8Text (Join-Path $state 'collector.json') (@{schemaVersion=1;providers=@{claude=@{lastAttemptAt=$now.ToString('o');failures=1;nextAttemptAt=$now.AddMinutes(30).ToString('o');status='unavailable'}}}|ConvertTo-Json -Depth 8) -NoBom
    Remove-Item -LiteralPath (Join-Path $state 'status.txt') -Force -ErrorAction SilentlyContinue
    $r=Invoke-Hotpl8Process $start[0] @($start|Select-Object -Skip 1) 60000
    Assert ($r.exitCode -eq 0) ('the scheduled start failed: '+$start[0])
    Assert (Test-Path -LiteralPath (Join-Path $state 'status.txt')) ('the scheduled start published nothing: '+$start[0])
    $status=Read-Hotpl8Json (Join-Path $state 'status.json')
    Assert ($status.collector.scheduled -eq $true -and $status.claudeError -eq 'backoff') ('the scheduled start did not collect as scheduled: '+$start[0])
   }
  }finally{
   $env:HOME=$homeBefore;$env:CLAUDE_CONFIG_DIR=$claudeBefore
   [IO.File]::WriteAllBytes($policyPath,$original)
   foreach($name in @('status.txt','status.js','status.json','collector.json')){Remove-Item -LiteralPath (Join-Path $state $name) -Force -ErrorAction SilentlyContinue}
  }
 }
 Check 'a reader that arrives without its executable bit is installed executable' {
  # Archive extraction drops the bit, and File.Copy keeps whatever the source has, so a
  # checkout cannot show the loss. This copy of the package has the bit cleared.
  $source=Join-Path $lab 'unpacked'
  foreach($file in @(Get-Hotpl8ReleaseFiles $root -Platform macos)){
   $target=Join-Path $source $file;[void][IO.Directory]::CreateDirectory((Split-Path $target -Parent));[IO.File]::Copy((Join-Path $root $file),$target)
  }
  $relative='bin/macos/hotpl8-native'
  [IO.File]::SetUnixFileMode((Join-Path $source $relative),[IO.UnixFileMode]'UserRead,UserWrite')
  $destination=Join-Path $lab 'restored install'
  InstallFixture $destination $source
  Assert (([IO.File]::GetUnixFileMode((Join-Path $destination ('app/'+$relative))) -band [IO.UnixFileMode]::UserExecute) -ne 0) 'installed reader is not executable'
 }
 Check 'update and rollback retain policy and resumable operations' {
  $state=Join-Path $script:installed 'state'
  [void][IO.Directory]::CreateDirectory((Join-Path $state 'onboarding'))
  Write-Hotpl8Text (Join-Path $state 'onboarding/fixture.json') '{"phase":"pending"}' -NoBom
  $hash=(Get-FileHash (Join-Path $state 'policy.json')).Hash
  InstallFixture $script:installed
  Assert (Test-Path (Join-Path $script:installed 'previous/hotpl8.ps1'))
  $r=Invoke-Hotpl8Process $shell @('-NoProfile','-File',(Join-Path $root 'rollback.ps1'),'-InstallDirectory',$script:installed) 30000
  Assert ($r.exitCode -eq 0) 'rollback failed'
  Assert ((Get-FileHash (Join-Path $state 'policy.json')).Hash -eq $hash -and (Test-Path (Join-Path $state 'onboarding/fixture.json')))
 }
 Check 'foreign destination and state inside application are rejected without changing files' {
  $foreign=Join-Path $lab foreign;[void][IO.Directory]::CreateDirectory($foreign)
  Write-Hotpl8Text (Join-Path $foreign 'keep.txt') 'keep'
  $r=Invoke-Hotpl8Process $shell @('-NoProfile','-File',(Join-Path $root 'install-macos.ps1'),'-InstallDirectory',$foreign,'-NoPath') 10000
  Assert ($r.exitCode -ne 0 -and (Test-Path (Join-Path $foreign 'keep.txt')))
  $destination=Join-Path $lab badstate
  $r=Invoke-Hotpl8Process $shell @('-NoProfile','-File',(Join-Path $root 'install-macos.ps1'),'-InstallDirectory',$destination,'-StateDirectory',(Join-Path $destination 'previous/state'),'-NoPath') 10000
  Assert ($r.exitCode -ne 0 -and -not (Test-Path $destination))
 }
 Check 'uninstall retains native homes and setup progress' {
  $state=Join-Path $script:installed 'state'
  [void][IO.Directory]::CreateDirectory((Join-Path $state 'accounts/fixture'))
  Write-Hotpl8Text (Join-Path $state 'accounts/fixture/keep.txt') 'native data'
  $r=Invoke-Hotpl8Process $shell @('-NoProfile','-File',(Join-Path $root 'uninstall.ps1'),'-InstallDirectory',$script:installed) 30000
  Assert ($r.exitCode -eq 0) 'uninstall failed'
  Assert (-not (Test-Path (Join-Path $script:installed 'app')) -and (Test-Path (Join-Path $state 'accounts/fixture/keep.txt')) -and (Test-Path (Join-Path $state 'onboarding/fixture.json')))
 }
}finally{Remove-Item -LiteralPath $lab -Recurse -Force}
'Mac installation: '+$script:passed+' passed, '+$script:failed+' failed.'
if($script:failed){exit 1}
