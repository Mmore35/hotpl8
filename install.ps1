# Per-user Windows installer. Does not download dependencies, sign in, or send prompts.
[CmdletBinding()]
param([string]$InstallDirectory,[string]$StateDirectory,[switch]$Schedule,[switch]$NoPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'config.ps1')
. (Join-Path $PSScriptRoot 'lifecycle.ps1')
if($env:OS -ne 'Windows_NT'){throw 'This installer supports Windows. Other systems can use a source checkout experimentally.'}
if(-not $InstallDirectory){$InstallDirectory=Join-Path $env:LOCALAPPDATA 'HotPl8'}
$destination=Assert-Hotpl8Path $InstallDirectory
$source=Assert-Hotpl8Path $PSScriptRoot
if($destination -eq $source -or $source.StartsWith($destination+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Run installation from a separate extracted release.'}
$old=Read-Hotpl8Json (Join-Path $destination 'installation.json')
if((Test-Path -LiteralPath $destination) -and -not $old -and @(Get-ChildItem -LiteralPath $destination -Force).Count){throw 'Destination is not an owned HotPl8 installation.'}
if($old -and ($old.product -ne 'hotpl8' -or $old.id -notmatch '^[a-f0-9]{12}$')){throw 'Invalid installation ownership.'}
if(-not $StateDirectory){$StateDirectory=if($old){$old.stateDirectory}else{Join-Path $destination 'state'}}
$state=Assert-Hotpl8Path $StateDirectory
if($old -and $state -ine $old.stateDirectory){throw 'Update must preserve the existing state directory.'}
if($state -eq $destination -or $state.StartsWith($destination+'\app',[StringComparison]::OrdinalIgnoreCase) -or $state.StartsWith($destination+'\previous',[StringComparison]::OrdinalIgnoreCase)){throw 'State must be separate from application files.'}
$files=@(Get-Hotpl8ReleaseFiles $source)
$hashes=Read-Hotpl8Json (Join-Path $source 'checksums.json')
if($hashes){
    foreach($file in $files){
        if(-not $hashes.$file -or (Get-FileHash -LiteralPath (Join-Path $source $file) -Algorithm SHA256).Hash -ine $hashes.$file){throw ('Release checksum mismatch: '+$file)}
    }
}
[void][IO.Directory]::CreateDirectory($destination)
[void][IO.Directory]::CreateDirectory($state)
$lock=$null; $stage=Join-Path $destination ('stage-'+[guid]::NewGuid().ToString('N'))
$app=Join-Path $destination 'app'; $previous=Join-Path $destination 'previous'
$promoted=$false; $moved=$false
$oldPath=[Environment]::GetEnvironmentVariable('Path','User')
$installationId=if($old){$old.id}else{[guid]::NewGuid().ToString('N').Substring(0,12)}
try{
    if(-not $old){
        # Retain ownership if a first installation fails, so preserved state does
        # not make a retry look like an unrelated nonempty destination.
        $recovery=@{product='hotpl8';schemaVersion=1;id=$installationId;version=$null;stateDirectory=$state;pathAdded=$false;scheduled=$false}
        Write-Hotpl8Text (Join-Path $destination 'installation.json') ($recovery|ConvertTo-Json) -NoBom
    }
    $lock=[IO.File]::Open((Join-Path $state 'tick.lock'),'OpenOrCreate','ReadWrite','None')
    [void][IO.Directory]::CreateDirectory($stage)
    foreach($file in $files){
        $target=Join-Path $stage $file
        [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
        [IO.File]::Copy((Join-Path $source $file),$target,$false)
    }
    Write-Hotpl8Text (Join-Path $stage 'install-state.json') (@{stateDirectory=$state}|ConvertTo-Json) -NoBom
    $policyPath=Join-Path $state 'policy.json'
    if(Test-Path -LiteralPath $policyPath){Assert-Hotpl8Policy (Read-Hotpl8Json $policyPath)}
    else{[IO.File]::Copy((Join-Path $source 'policy.example.json'),$policyPath,$false)}
    if(Test-Path -LiteralPath $previous){Remove-Hotpl8App $previous}
    if(Test-Path -LiteralPath $app){
        # Verify old owned content before moving it; updates retain it for rollback.
        $null=@(Get-Hotpl8ReleaseFiles $app)
        $null=Assert-Hotpl8Path $app
        Move-Item -LiteralPath $app -Destination $previous
        $moved=$true
    }
    Move-Item -LiteralPath $stage -Destination $app
    $promoted=$true
    $installation=[pscustomobject]@{
        product='hotpl8';schemaVersion=1
        id=$installationId
        version=(Get-Content (Join-Path $app 'VERSION') -Raw).Trim()
        stateDirectory=$state
        pathAdded=((-not $NoPath) -or ($old -and $old.pathAdded))
        scheduled=([bool]$Schedule -or ($old -and $old.scheduled))
    }
    $shim="@echo off"+[Environment]::NewLine+'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\hotpl8.ps1" %*'+[Environment]::NewLine+'exit /b %errorlevel%'+[Environment]::NewLine
    Write-Hotpl8Text (Join-Path $destination 'hotpl8.cmd') $shim -NoBom
    if(-not $NoPath){Set-Hotpl8UserPath $destination $true}
    if($installation.scheduled){Register-Hotpl8Task $installation $destination}
    Write-Hotpl8Text (Join-Path $destination 'installation.json') ($installation|ConvertTo-Json) -NoBom
    'Installed HotPl8 '+$installation.version+'. Open a new terminal and run hotpl8 doctor.'
    'Accounts remain in their native tools. Follow docs/install.md to enroll them.'
}catch{
    if(-not $NoPath){[Environment]::SetEnvironmentVariable('Path',$oldPath,'User')}
    if($promoted){Remove-Hotpl8App $app}
    if($moved){Move-Item -LiteralPath $previous -Destination $app}
    throw
}finally{
    if($lock){$lock.Dispose()}
    if(Test-Path -LiteralPath $stage){
        # Only the unique stage created by this invocation is removed.
        $resolved=Assert-Hotpl8Path $stage
        if((Split-Path $resolved -Parent) -ne $destination -or (Split-Path $resolved -Leaf) -notmatch '^stage-[a-f0-9]{32}$'){throw 'Invalid staging path'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
