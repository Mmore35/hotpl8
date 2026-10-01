# Ordinary per-user Mac installation. Managed installations keep their existing delivery owner.
[CmdletBinding()]
param([string]$InstallDirectory,[string]$StateDirectory,[switch]$Schedule,[switch]$NoPath)
$ErrorActionPreference='Stop'
foreach($file in @('common','config','lifecycle')){. (Join-Path $PSScriptRoot ('src/'+$file+'.ps1'))}
. (Join-Path $PSScriptRoot 'src/providers/codex.ps1')
if(-not $IsMacOS){throw 'This installer requires macOS.'}
if(-not $InstallDirectory){$InstallDirectory=Join-Path (Get-Hotpl8UserHome) 'Library/Application Support/HotPl8'}
$destination=Assert-Hotpl8Path $InstallDirectory
$old=Read-Hotpl8Json (Join-Path $destination 'installation.json')
if($old.managedBy -eq 'local-delivery' -or (Test-Path (Join-Path $destination 'managed/delivery.json'))){throw 'Use this managed installation''s delivery update command.'}
if($old -and ($old.product -ne 'hotpl8' -or $old.platform -ne 'macos' -or $old.id -notmatch '^[a-f0-9]{12}$')){throw 'Invalid installation ownership.'}
if(-not $old -and (Test-Path $destination) -and @(Get-ChildItem $destination -Force).Count){throw 'Destination is not an owned HotPl8 installation.'}
if(-not $StateDirectory){$StateDirectory=if($old){$old.stateDirectory}else{Join-Path $destination 'state'}}
$state=Assert-Hotpl8Path $StateDirectory
if($old -and $old.stateDirectory -cne $state){throw 'Updates must preserve existing state.'}
foreach($codeRoot in @($PSScriptRoot,(Join-Path $destination 'app'),(Join-Path $destination 'previous'))){
    if($state -eq $codeRoot -or $state.StartsWith($codeRoot+'/')){throw 'State must be separate from code.'}
}
if($state -eq $destination -or $destination -eq $PSScriptRoot -or $destination.StartsWith($PSScriptRoot+'/')){throw 'Installation and source must be separate.'}
$files=@(Get-Hotpl8ReleaseFiles $PSScriptRoot)
$checksums=Read-Hotpl8Json (Join-Path $PSScriptRoot 'checksums.json')
if($checksums){foreach($f in $files){if((Get-FileHash (Join-Path $PSScriptRoot $f)).Hash.ToLowerInvariant() -cne $checksums.$f){throw 'Release checksum mismatch.'}}}
foreach($dir in @($destination,$state)){[void][IO.Directory]::CreateDirectory($dir);[IO.File]::SetUnixFileMode($dir,[IO.UnixFileMode]'UserRead,UserWrite,UserExecute')}
$id=if($old){$old.id}else{[guid]::NewGuid().ToString('N').Substring(0,12)}
$receipt=[pscustomobject]@{product='hotpl8';schemaVersion=1;platform='macos';id=$id;stateDirectory=$state;version=$null;scheduled=[bool]($Schedule -or $old.scheduled);pathAdded=[bool](-not $NoPath -or $old.pathAdded)}
$app=Join-Path $destination 'app';$previous=Join-Path $destination 'previous';$stage=Join-Path $destination ('stage-'+[guid]::NewGuid().ToString('N'))
$shim=Join-Path $destination 'hotpl8'
$bin=Join-Path (Get-Hotpl8UserHome) '.local/bin';$link=Join-Path $bin 'hotpl8'
$label='com.hotpl8.collector.'+$id
$launch=Join-Path (Get-Hotpl8UserHome) ('Library/LaunchAgents/'+$label+'.plist')
# Ownership conflicts are rejected before replacing working application files.
if($receipt.pathAdded -and (Test-Path $link)){
    $item=Get-Item $link -Force
    if($item.LinkType -ne 'SymbolicLink' -or $item.Target -ne $shim){throw 'Existing hotpl8 command belongs to another installation.'}
}
if(Test-Path $launch){
    if(-not $old.scheduled){throw 'Collector ownership is not established.'}
    [xml]$installedJob=[IO.File]::ReadAllText($launch)
    if($installedJob.plist.dict.string -notcontains $label -or $installedJob.plist.dict.array.string -notcontains (Join-Path $destination 'app/tick.ps1') -or $installedJob.plist.dict.array.string -notcontains $state){throw 'Collector ownership mismatch.'}
}
$oldShim=if(Test-Path $shim){[IO.File]::ReadAllText($shim)}else{$null}
$lock=$null;$promoted=$false;$moved=$false;$createdLink=$false;$createdLaunch=$false
try{
    $lock=[IO.File]::Open((Join-Path $state 'tick.lock'),'OpenOrCreate','ReadWrite','None')
    if(-not $old){Write-Hotpl8Text (Join-Path $destination 'installation.json') ($receipt|ConvertTo-Json) -NoBom}
    foreach($f in $files){$target=Join-Path $stage $f;[void][IO.Directory]::CreateDirectory((Split-Path $target -Parent));[IO.File]::Copy((Join-Path $PSScriptRoot $f),$target)}
    if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'build-info.json')){[IO.File]::Copy((Join-Path $PSScriptRoot 'build-info.json'),(Join-Path $stage 'build-info.json'))}
    Write-Hotpl8Text (Join-Path $stage 'install-state.json') (@{stateDirectory=$state}|ConvertTo-Json) -NoBom
    $policy=Join-Path $state 'policy.json'
    if(Test-Path $policy){Assert-Hotpl8Policy (Read-Hotpl8Json $policy)}else{[IO.File]::Copy((Join-Path $stage 'policy.example.json'),$policy)}
    if(Test-Path $previous){Remove-Hotpl8App $previous}
    if(Test-Path $app){Remove-Hotpl8App $app -ValidateOnly;Move-Item $app $previous;$moved=$true}
    Move-Item $stage $app;$promoted=$true
    $shell=(Get-Process -Id $PID).Path
    # POSIX single-quoted literals; generated paths are not interpolated as shell code.
    $shellQuote="'"+$shell.Replace("'",("'"+'"'+"'"+'"'+"'"))+"'"
    $fileQuote="'"+(Join-Path $app 'hotpl8.ps1').Replace("'",("'"+'"'+"'"+'"'+"'"))+"'"
    $shim=Join-Path $destination 'hotpl8'
    Write-Hotpl8Text $shim ("#!/bin/sh`nexec "+$shellQuote+' -NoProfile -File '+$fileQuote+' "$@"'+"`n") -NoBom
    [IO.File]::SetUnixFileMode($shim,[IO.UnixFileMode]'UserRead,UserWrite,UserExecute')
    if($receipt.pathAdded){
        $bin=Join-Path (Get-Hotpl8UserHome) '.local/bin';[void][IO.Directory]::CreateDirectory($bin)
        $link=Join-Path $bin 'hotpl8'
        if(Test-Path $link){
            $item=Get-Item $link -Force
            if($item.LinkType -ne 'SymbolicLink' -or $item.Target -ne $shim){throw 'Existing hotpl8 command belongs to another installation.'}
        }else{New-Item -ItemType SymbolicLink -Path $link -Target $shim|Out-Null;$createdLink=$true}
    }
    if($receipt.scheduled){
        $label='com.hotpl8.collector.'+$id
        $launch=Join-Path (Get-Hotpl8UserHome) ('Library/LaunchAgents/'+$label+'.plist')
        [void][IO.Directory]::CreateDirectory((Split-Path $launch -Parent))
        $argv=@($shell,'-NoProfile','-NonInteractive','-File',(Join-Path $app 'tick.ps1'),'-Scheduled','-StateDirectory',$state)
        $arguments=(@($argv|ForEach-Object{'<string>'+[Security.SecurityElement]::Escape($_)+'</string>'}) -join '')
        $xml='<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>'+$label+'</string><key>ProgramArguments</key><array>'+$arguments+'</array><key>StartInterval</key><integer>60</integer><key>RunAtLoad</key><true/><key>StandardOutPath</key><string>/dev/null</string><key>StandardErrorPath</key><string>/dev/null</string></dict></plist>'
        if(Test-Path $launch){
            if(-not $old.scheduled){throw 'Collector ownership is not established.'}
            # An ordinary code update retains its existing enabled state and executable binding.
        }else{
            Write-Hotpl8Text $launch $xml -NoBom;$createdLaunch=$true
            $uid=(& /usr/bin/id -u).Trim()
            & /bin/launchctl bootstrap ('gui/'+$uid) $launch
            if($LASTEXITCODE -ne 0){Remove-Item $launch;throw 'Collector registration failed.'}
        }
    }
    $receipt.version=([IO.File]::ReadAllText((Join-Path $app 'VERSION'))).Trim()
    Write-Hotpl8Text (Join-Path $destination 'installation.json') ($receipt|ConvertTo-Json) -NoBom
    'Installed HotPl8. Run '+$shim+' setup'
}catch{
    if($createdLaunch){
        $uid=(& /usr/bin/id -u).Trim()
        & /bin/launchctl bootout ('gui/'+$uid+'/'+$label) 2>$null
        if(Test-Path $launch){Remove-Item -LiteralPath $launch}
    }
    if($createdLink -and (Test-Path $link)){Remove-Item -LiteralPath $link}
    if($oldShim){Write-Hotpl8Text $shim $oldShim -NoBom}elseif(Test-Path $shim){Remove-Item -LiteralPath $shim}
    if($old){Write-Hotpl8Text (Join-Path $destination 'installation.json') ($old|ConvertTo-Json) -NoBom}
    else{
        # Retain owned state after an interrupted first install so rerunning repairs it.
        $receipt.scheduled=$false;$receipt.pathAdded=$false;$receipt.version=$null
        Write-Hotpl8Text (Join-Path $destination 'installation.json') ($receipt|ConvertTo-Json) -NoBom
    }
    if($promoted){Remove-Hotpl8App $app}
    if($moved){Move-Item $previous $app}
    throw
}finally{if($lock){$lock.Dispose()};if(Test-Path $stage){Remove-Item -LiteralPath $stage -Recurse -Force}}
