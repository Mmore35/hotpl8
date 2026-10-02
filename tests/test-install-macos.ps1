# Ordinary Mac package lifecycle; no launchd jobs or production PATH changes.
$ErrorActionPreference='Stop'
if(-not $IsMacOS){throw 'This suite requires macOS.'}
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
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
