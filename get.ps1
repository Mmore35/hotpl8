# Public unauthenticated bootstrap for a tested main package. No Git, gh, or private manager.
[CmdletBinding()]
param([ValidateSet('claude','codex')][string]$Provider,[string]$InstallDirectory,[switch]$AsJson,[switch]$InstallDependencies,[switch]$NoSchedule,[switch]$NoPath,[ValidatePattern('^[0-9a-f]{40}$')][string]$Commit)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$repository='Mmore35/hotpl8';$api='https://api.github.com/repos/'+$repository
$headers=@{'User-Agent'='HotPl8-public-setup'}
$platform=if($env:OS -eq 'Windows_NT'){'windows'}elseif($IsMacOS){'macos'}else{throw 'Public installation supports Windows and macOS.'}
if(-not $Commit){
 $latest=Invoke-RestMethod ($api+'/actions/workflows/ci.yml/runs?branch=main&event=push&status=success&per_page=10') -Headers $headers -TimeoutSec 30
 $Commit=(@($latest.workflow_runs|Where-Object {$_.head_branch -ceq 'main' -and $_.event -ceq 'push' -and $_.conclusion -ceq 'success' -and $_.head_repository.full_name -ieq $repository}|Select-Object -First 1)).head_sha
}
if($Commit -cnotmatch '^[0-9a-f]{40}$'){throw 'Invalid published revision.'}
$runs=Invoke-RestMethod ($api+'/actions/workflows/ci.yml/runs?head_sha='+$Commit+'&event=push&per_page=30') -Headers $headers -TimeoutSec 30
$passed=@($runs.workflow_runs|Where-Object {$_.head_sha -ceq $Commit -and $_.head_branch -ceq 'main' -and $_.event -ceq 'push' -and $_.status -ceq 'completed' -and $_.conclusion -ceq 'success' -and $_.head_repository.full_name -ieq $repository})
if(-not $passed.Count){throw 'This main revision has not passed both platform checks yet. Retry after its build completes.'}
$release=Invoke-RestMethod ($api+'/releases/tags/main-'+$Commit) -Headers $headers -TimeoutSec 30
$tag=Invoke-RestMethod ($api+'/commits/main-'+$Commit) -Headers $headers -TimeoutSec 30
if($release.draft -or $release.tag_name -cne ('main-'+$Commit) -or $tag.sha -cne $Commit){throw 'Release identity mismatch.'}
$name=if($platform -eq 'macos'){'hotpl8-macos-main.zip'}else{'hotpl8-main.zip'}
$assets=@($release.assets|Where-Object name -CEQ $name)
if($assets.Count -ne 1 -or $assets[0].digest -cnotmatch '^sha256:[a-f0-9]{64}$' -or $assets[0].size -gt 250000000 -or -not $assets[0].browser_download_url.StartsWith('https://github.com/'+$repository+'/releases/download/main-'+$Commit+'/')){throw 'Verified release asset unavailable.'}
$stage=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-download-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($stage)
try{
 $zip=Join-Path $stage 'package.zip'
 Invoke-WebRequest -UseBasicParsing $assets[0].browser_download_url -OutFile $zip -TimeoutSec 180
 if((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -cne $assets[0].digest.Substring(7)){throw 'Release checksum mismatch.'}
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 $archive=[IO.Compression.ZipFile]::OpenRead($zip)
 try{
  $names=@{}
  foreach($entry in $archive.Entries){
   if($entry.FullName -cnotmatch '^[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)*$' -or $entry.FullName -match '(^|/)\.\.?(/|$)' -or $names.ContainsKey($entry.FullName) -or $entry.Length -gt 50000000){throw 'Invalid release inventory.'}
   $names[$entry.FullName]=$true
  }
 }finally{$archive.Dispose()}
 $unpack=Join-Path $stage 'package';Expand-Archive -LiteralPath $zip -DestinationPath $unpack
 $manifest=Get-Content (Join-Path $unpack 'delivery-manifest.json') -Raw|ConvertFrom-Json
 if($manifest.protocol -ne 1 -or $manifest.product -cne 'hotpl8' -or $manifest.repository -cne $repository -or $manifest.platform -cne $platform -or $manifest.sha -cne $Commit -or $manifest.stateCompatibility -ne 1){throw 'Release manifest identity mismatch.'}
 if(@($manifest.files.PSObject.Properties).Count -ne ($names.Count-1)){throw 'Release manifest inventory mismatch.'}
 foreach($file in $manifest.files.PSObject.Properties){
  if(-not $names.ContainsKey($file.Name) -or (Get-FileHash (Join-Path $unpack $file.Name) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.Value){throw 'Release file checksum mismatch.'}
 }
 if(-not (Test-Path (Join-Path $unpack 'start.ps1'))){throw 'This published package predates guided installation. Use a reviewed onboarding candidate until its main build is published.'}
 $options=@{AsJson=$AsJson;InstallDependencies=$InstallDependencies;NoSchedule=$NoSchedule;NoPath=$NoPath}
 if($Provider){$options.Provider=$Provider};if($InstallDirectory){$options.InstallDirectory=$InstallDirectory}
 & (Join-Path $unpack 'start.ps1') @options
}finally{Remove-Item -LiteralPath $stage -Recurse -Force}
