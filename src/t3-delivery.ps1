# T3 lifecycle adapter. Ownership comes from the installer receipt and unchanged
# provider entry. A retained receipt for a removed provider is not enrollment.
function Get-Hotpl8T3LauncherDigest([string]$Path){
    # git archive and Windows checkouts may package identical C# with LF/CRLF.
    # Compare decoded source, retaining every difference except newline encoding.
    Get-Hotpl8Hash ([IO.File]::ReadAllText($Path).Replace("`r`n","`n"))
}
function Get-Hotpl8T3Integrations([string]$InstallDirectory,[string]$StateDirectory){
    $parent=Join-Path $InstallDirectory 'integrations'
    $registration=Read-Hotpl8Json (Join-Path $InstallDirectory 'delivery.json')
    foreach($known in @($registration.t3Integrations)){
        if(-not $known){continue}
        if($known.name -notmatch '^[a-zA-Z0-9_-]+$'){throw 'Invalid T3 component registration.'}
        $expected=Join-Path $parent $known.name
        $settings=Read-Hotpl8Json $known.settingsPath
        if(-not $settings){throw 'Registered T3 settings are unreadable.'}
        if($settings.providerInstances.($known.providerId).config.binaryPath -eq (Join-Path $expected 'hotpl8-codex.exe') -and -not (Test-Path -LiteralPath (Join-Path $expected 'receipt.json'))){throw 'Registered T3 integration is missing.'}
    }
    if(-not (Test-Path -LiteralPath $parent)){return}
    foreach($directory in @(Get-ChildItem -LiteralPath $parent -Directory)){
        $receiptPath=Join-Path $directory.FullName 'receipt.json'
        if(-not (Test-Path -LiteralPath $receiptPath)){
            if(Test-Path -LiteralPath (Join-Path $directory.FullName 'bridge-config.json')){throw 'T3 integration receipt is missing.'}
            continue
        }
        $receipt=Read-Hotpl8Json $receiptPath
        if(-not $receipt){throw 'T3 integration receipt is unreadable.'}
        $settings=Read-Hotpl8Json $receipt.settingsPath
        if(-not $settings){throw 'T3 integration settings are unreadable.'}
        $instance=$settings.providerInstances.($receipt.targetProviderId)
        if(-not $instance){continue}
        $launcher=Join-Path $directory.FullName 'hotpl8-codex.exe'
        if($instance.config.binaryPath -ne $launcher){continue}
        if(($instance|ConvertTo-Json -Depth 30 -Compress) -cne ($receipt.installedInstance|ConvertTo-Json -Depth 30 -Compress)){throw 'T3 provider ownership changed; reconcile before delivery.'}
        $configPath=Join-Path $directory.FullName 'bridge-config.json'
        $config=Read-Hotpl8Json $configPath
        if(-not $config -or $config.schemaVersion -ne 1 -or [IO.Path]::GetFullPath($config.stateDirectory) -ne [IO.Path]::GetFullPath($StateDirectory)){throw 'T3 delivery state binding does not match.'}
        foreach($path in @($launcher,$config.node,$config.codex,$config.powershell,$config.script)){
            if(-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)){throw 'T3 integration runtime is missing.'}
        }
        if($config.deliveryRoot -and [IO.Path]::GetFullPath($config.deliveryRoot) -ne [IO.Path]::GetFullPath($InstallDirectory)){throw 'T3 integration belongs to another delivery installation.'}
        [pscustomobject]@{directory=$directory.FullName;receipt=$receipt;config=$config;configPath=$configPath;launcher=$launcher}
    }
}

function Sync-Hotpl8T3Delivery([string]$Operation,[string]$InstallDirectory,[string]$ReleaseDirectory,[string]$StateDirectory){
    $items=@(Get-Hotpl8T3Integrations $InstallDirectory $StateDirectory)
    if($Operation -eq 'activate'){
        $registration=Read-Hotpl8Json (Join-Path $InstallDirectory 'delivery.json')
        if($registration){
            $known=@($registration.t3Integrations|Where-Object {$_})
            foreach($item in $items){
                $name=Split-Path $item.directory -Leaf
                if($name -notmatch '^[a-zA-Z0-9_-]+$'){throw 'Use a simple directory name for a managed T3 integration.'}
                $known=@($known|Where-Object {$_.name -ne $name})+@([pscustomobject]@{name=$name;settingsPath=$item.receipt.settingsPath;providerId=$item.receipt.targetProviderId})
            }
            $registration|Add-Member NoteProperty t3Integrations @($known) -Force
            $registration|Add-Member NoteProperty componentHealth $true -Force
            Write-Hotpl8Text (Join-Path $InstallDirectory 'delivery.json') ($registration|ConvertTo-Json -Depth 10) -NoBom
        }
    }
    foreach($item in $items){
        $entry=Join-Path $ReleaseDirectory 'src/t3-entry.mjs'
        if(-not (Test-Path -LiteralPath $entry)){throw 'Release omits the managed T3 entrypoint.'}
        # The native launcher is deliberately not replaced while T3 may hold it
        # open. A change to its protocol requires a separately tested migration.
        if(-not $item.config.deliveryRoot){
            $legacySource=Join-Path (Split-Path $item.config.script -Parent) 't3-launcher.cs'
            if(-not (Test-Path -LiteralPath $legacySource) -or (Get-Hotpl8T3LauncherDigest $legacySource) -ne (Get-Hotpl8T3LauncherDigest (Join-Path $ReleaseDirectory 'src/t3-launcher.cs'))){throw 'T3 launcher requires an explicit compatibility migration.'}
        }elseif($item.config.launcherSourceDigest -ne (Get-Hotpl8T3LauncherDigest (Join-Path $ReleaseDirectory 'src/t3-launcher.cs'))){
            throw 'T3 launcher requires an explicit compatibility migration.'
        }
        if($Operation -eq 'activate'){
            $guard=$null
            try{
                $guard=[IO.File]::Open((Join-Path $item.directory 'setup.lock'),'OpenOrCreate','ReadWrite','None')
                $text=[IO.File]::ReadAllText($item.configPath)
                $config=$text|ConvertFrom-Json
                $digest=(Get-FileHash -LiteralPath $entry -Algorithm SHA256).Hash.ToLowerInvariant()
                $bootstrap=Join-Path $item.directory ('entry-'+$digest+'.mjs')
                if(Test-Path -LiteralPath $bootstrap){
                    if((Get-FileHash -LiteralPath $bootstrap).Hash.ToLowerInvariant() -ne $digest){throw 'T3 bootstrap was modified.'}
                }else{[IO.File]::Copy($entry,$bootstrap,$false)}
                # One atomic switch; receipt remains install/removal history.
                # Bootstrap reads current.json, so even an OLD release's recover
                # adapter rolls back new bridge processes without knowing this file.
                $config|Add-Member NoteProperty deliveryRoot ([IO.Path]::GetFullPath($InstallDirectory)) -Force
                $config|Add-Member NoteProperty bootstrapDigest $digest -Force
                $config|Add-Member NoteProperty launcherSourceDigest (Get-Hotpl8T3LauncherDigest (Join-Path $ReleaseDirectory 'src/t3-launcher.cs')) -Force
                $config.script=$bootstrap
                if([IO.File]::ReadAllText($item.configPath) -cne $text){throw 'T3 configuration changed concurrently.'}
                Write-Hotpl8Text $item.configPath ($config|ConvertTo-Json -Depth 10) -NoBom
            }finally{if($guard){$guard.Dispose()}}
        }
        if($Operation -in @('health','recover')){
            $config=Read-Hotpl8Json $item.configPath
            if(-not $config.deliveryRoot -or (Get-FileHash -LiteralPath $config.script).Hash.ToLowerInvariant() -ne $config.bootstrapDigest){throw 'T3 is not bound to managed delivery.'}
            $result=Invoke-Hotpl8Process $config.node @($config.script,'--bridge-config',$item.configPath,'--delivery-probe') 15000
            $build=Read-Hotpl8Json (Join-Path $ReleaseDirectory 'build-info.json')
            if($result.exitCode -ne 0 -or ($result.output|ConvertFrom-Json).sha -ne $build.sha){throw 'T3 selected release failed readiness.'}
        }
    }
}

function Get-Hotpl8T3DeliveryStatus([string]$InstallDirectory,[string]$StateDirectory){
    $current=Read-Hotpl8Json (Join-Path $InstallDirectory 'current.json')
    $delivery=Read-Hotpl8Json (Join-Path $InstallDirectory 'delivery-status.json')
    foreach($item in @(Get-Hotpl8T3Integrations $InstallDirectory $StateDirectory)){
        $running=@();$unknown=0
        $processes=@(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction Stop | Where-Object {$_.CommandLine -and $_.CommandLine.Contains($item.configPath) -and $_.CommandLine.Contains('--bridge-config')})
        foreach($proc in $processes){
            $record=Read-Hotpl8Json (Join-Path $item.directory ('processes/'+$proc.ProcessId+'.json'))
            $verified=$false
            try{
                $age=([datetimeoffset]::UtcNow-([datetimeoffset]$record.observedAt)).TotalSeconds
                $verified=$record -and $record.sha -match '^[a-f0-9]{40}$' -and [Math]::Abs(([datetimeoffset]$record.startedAt-([datetimeoffset]$proc.CreationDate)).TotalSeconds) -lt 5 -and $age -ge 0 -and $age -lt 90
            }catch{} # Invalid/stale/PID-reused receipts never prove loaded code.
            if($verified){$running+=$record.sha}else{$unknown++}
        }
        $managed=[bool]$item.config.deliveryRoot
        $valid=$true
        if($managed){
            $valid=(Get-FileHash -LiteralPath $item.config.script).Hash.ToLowerInvariant() -eq $item.config.bootstrapDigest
            if($valid){
                $probe=Invoke-Hotpl8Process $item.config.node @($item.config.script,'--bridge-config',$item.configPath,'--delivery-probe') 15000
                $valid=$probe.exitCode -eq 0 -and ($probe.output|ConvertFrom-Json).sha -eq $current.sha
            }
        }
        $state=if(-not $managed){'unmanaged'}elseif($unknown){'running-version-unknown'}elseif(@($running|Where-Object {$_ -ne $current.sha}).Count){'restart-pending'}else{'current'}
        if(-not $valid){$state='error'}
        [pscustomobject]@{component='t3-codex';providerId=$item.receipt.targetProviderId;state=$state;desiredSha=$delivery.desiredSha;installedSha=$current.sha;nextLaunchSha=$(if($managed){$current.sha}else{$item.receipt.sourceCommit});runningShas=@($running|Select-Object -Unique);unknownRunningProcesses=$unknown;adoption='New provider processes; active work is retained'}
    }
}
