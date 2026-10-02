# Public download trust checks, entirely offline with synthetic release packages.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
$lab=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-bootstrap-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($lab)
$global:Hotpl8BootstrapTest_commit='a'*40;$global:Hotpl8BootstrapTest_failure='';$script:passed=0;$script:failed=0
$stage=Join-Path $lab 'package';[void][IO.Directory]::CreateDirectory($stage)
Write-Hotpl8Text (Join-Path $stage 'start.ps1') 'param([switch]$AsJson,[switch]$InstallDependencies,[switch]$NoSchedule,[switch]$NoPath,[string]$Provider,[string]$InstallDirectory);''fixture-setup-started''' -NoBom
$platform=if($env:OS -eq 'Windows_NT'){'windows'}else{'macos'}
$global:Hotpl8BootstrapTest_assetName=if($platform -eq 'windows'){'hotpl8-main.zip'}else{'hotpl8-macos-main.zip'}
$manifest=@{protocol=1;product='hotpl8';repository='Mmore35/hotpl8';sha=$global:Hotpl8BootstrapTest_commit;platform=$platform;stateCompatibility=1;files=@{'start.ps1'=(Get-FileHash (Join-Path $stage 'start.ps1')).Hash.ToLowerInvariant()}}
Write-Hotpl8Text (Join-Path $stage 'delivery-manifest.json') ($manifest|ConvertTo-Json -Depth 8) -NoBom
$global:Hotpl8BootstrapTest_archive=Join-Path $lab 'fixture.zip'
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $global:Hotpl8BootstrapTest_archive
$global:Hotpl8BootstrapTest_digest=(Get-FileHash $global:Hotpl8BootstrapTest_archive).Hash.ToLowerInvariant()
function Invoke-RestMethod($Uri,$Headers,$TimeoutSec){
 if($Uri -match '/actions/workflows/ci.yml/runs'){
  return [pscustomobject]@{workflow_runs=@([pscustomobject]@{head_sha=$global:Hotpl8BootstrapTest_commit;head_branch='main';event='push';status='completed';conclusion=$(if($global:Hotpl8BootstrapTest_failure -eq 'workflow'){'failure'}else{'success'});head_repository=@{full_name='Mmore35/hotpl8'}})}
 }
 if($Uri -match '/releases/tags/main-'){
  return [pscustomobject]@{draft=$false;tag_name=('main-'+$global:Hotpl8BootstrapTest_commit);assets=@([pscustomobject]@{name=$global:Hotpl8BootstrapTest_assetName;digest=('sha256:'+$(if($global:Hotpl8BootstrapTest_failure -eq 'digest'){'b'*64}else{$global:Hotpl8BootstrapTest_digest}));size=(Get-Item $global:Hotpl8BootstrapTest_archive).Length;browser_download_url=('https://github.com/Mmore35/hotpl8/releases/download/main-'+$global:Hotpl8BootstrapTest_commit+'/'+$global:Hotpl8BootstrapTest_assetName)})}
 }
 if($Uri -match '/commits/main-'){return @{sha=$(if($global:Hotpl8BootstrapTest_failure -eq 'tag'){'b'*40}else{$global:Hotpl8BootstrapTest_commit})}}
 throw 'Unexpected API request.'
}
function Invoke-WebRequest($Uri,$OutFile,$TimeoutSec,[switch]$UseBasicParsing){Copy-Item -LiteralPath $global:Hotpl8BootstrapTest_archive -Destination $OutFile}
function Assert($Value,$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check($Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message+' at '+$_.ScriptStackTrace}}
try{
 Check 'bootstrap reaches setup only after workflow tag digest and inventory verification' {
  $result=& (Join-Path $root 'get.ps1') -AsJson -NoSchedule -NoPath
  Assert ($result -eq 'fixture-setup-started')
 }
 Check 'failed workflow mismatched tag and digest never execute setup' {
  foreach($case in @('workflow','tag','digest')){
   $global:Hotpl8BootstrapTest_failure=$case;$rejected=$false
   try{$result=& (Join-Path $root 'get.ps1') -Commit $global:Hotpl8BootstrapTest_commit -AsJson}catch{$rejected=$true}
   Assert $rejected $case
  }
  $global:Hotpl8BootstrapTest_failure=''
 }
 Check 'tampered file inventory fails even when asset digest matches' {
  Write-Hotpl8Text (Join-Path $stage 'start.ps1') 'throw "tampered-script-executed"' -NoBom
  Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $global:Hotpl8BootstrapTest_archive -Force
  $global:Hotpl8BootstrapTest_digest=(Get-FileHash $global:Hotpl8BootstrapTest_archive).Hash.ToLowerInvariant()
  $rejected=$false
  try{& (Join-Path $root 'get.ps1') -Commit $global:Hotpl8BootstrapTest_commit -AsJson|Out-Null}catch{$rejected=$_.Exception.Message -eq 'Release file checksum mismatch.'}
  Assert $rejected
 }
}finally{Remove-Item -LiteralPath $lab -Recurse -Force}
'Bootstrap: '+$script:passed+' passed, '+$script:failed+' failed.'
if($script:failed){exit 1}
