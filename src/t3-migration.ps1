# Gradual enrollment only: no T3 event/database or conversation operations.
function Get-Hotpl8T3TransitionPlan([string]$SettingsPath,[string]$IntegrationDirectory,[string]$ProviderId='codex') {
    $settings=Read-Hotpl8Json $SettingsPath
    if(-not $settings -or $settings.providerInstances.$ProviderId.driver -ne 'codex'){throw 'Choose an existing T3 Codex provider instance.'}
    $receipt=Read-Hotpl8Json (Join-Path $IntegrationDirectory 'receipt.json')
    if(-not $receipt -and (Test-Path -LiteralPath (Join-Path $IntegrationDirectory 'receipt.json'))){throw 'T3 integration receipt is unreadable; preserve it and reconcile.'}
    if($receipt -and $receipt.targetProviderId -ne $ProviderId){$IntegrationDirectory=$IntegrationDirectory+'-ordinary'}
    $receipt=Read-Hotpl8Json (Join-Path $IntegrationDirectory 'receipt.json')
    if(-not $receipt -and (Test-Path -LiteralPath (Join-Path $IntegrationDirectory 'receipt.json'))){throw 'T3 integration receipt is unreadable; preserve it and reconcile.'}
    if($receipt -and ($receipt.targetProviderId -ne $ProviderId -or -not (Test-Hotpl8T3Path $receipt.settingsPath $SettingsPath))){throw 'Ordinary integration directory belongs to another provider or settings file.'}
    $instance=$settings.providerInstances.$ProviderId
    if($instance.config.shadowHomePath -or $instance.config.launchArgs){throw 'Review custom launch arguments or shadow home before transition.'}
    $launcher=Join-Path $IntegrationDirectory 'hotpl8-codex.exe'
    $managed=$receipt -and (Test-Hotpl8T3Path $instance.config.binaryPath $launcher) -and (($instance|ConvertTo-Json -Depth 30 -Compress) -ceq ($receipt.installedInstance|ConvertTo-Json -Depth 30 -Compress))
    if($receipt -and -not $managed -and $receipt.phase -notin @('prepared','removed') -and (($instance|ConvertTo-Json -Depth 30 -Compress) -cne ($receipt.originalInstance|ConvertTo-Json -Depth 30 -Compress))){throw 'Ordinary provider ownership changed; preserve settings and reconcile.'}
    $legacy=@($settings.providerInstances.PSObject.Properties|Where-Object {$_.Name -ne $ProviderId -and $_.Value.driver -eq 'codex'}|ForEach-Object {$_.Name})
    $pending=$receipt.phase -in @('staging','prepared')
    [pscustomobject]@{operation='transition';providerId=$ProviderId;integrationDirectory=[IO.Path]::GetFullPath($IntegrationDirectory);ordinaryManaged=[bool]$managed;state=$(if($pending){'setup-recovery-required'}elseif($managed -and $legacy.Count){'ordinary-managed/legacy-retained'}elseif($managed){'ordinary-managed'}else{'ordinary-bypassed'});setupPhase=$receipt.phase;retainedProviderIds=$legacy;requiresHostShutdown=(-not $managed -or $pending);threadMigration='none';aliasRemoval='none'}
}

function Assert-Hotpl8T3HostStopped([string]$SettingsPath,$Processes=$null) {
    # Runtime PID covers standalone servers, including those configured by env.
    # Process inspection also catches desktop/CLI startup before runtime publication.
    if($null -eq $Processes){$Processes=@(Get-CimInstance Win32_Process -ErrorAction Stop)}
    $folder=Split-Path ([IO.Path]::GetFullPath($SettingsPath)) -Parent
    $runtimePath=Join-Path $folder 'server-runtime.json'
    if(Test-Path -LiteralPath $runtimePath){
        $runtime=Read-Hotpl8Json $runtimePath
        if(-not $runtime -or -not $runtime.pid){throw 'T3 runtime record is unreadable; verify host shutdown before setup.'}
        if(@($Processes|Where-Object {$_.ProcessId -eq $runtime.pid}).Count){throw 'Close the complete T3 host, including its standalone server, before changing provider settings.'}
    }
    $default=[IO.Path]::GetFullPath((Join-Path (Get-Hotpl8UserHome) '.t3/userdata/settings.json'))
    foreach($process in @($Processes)){
        $name=[string]$process.Name;$command=[string]$process.CommandLine
        $desktop=$name -match '^(T3 Code( \(Alpha\))?|t3code|t3)\.exe$'
        $server=$name -match '^(node|bun|t3|t3code)(\.exe)?$' -and $command -match '(?i)(server\.asar|[\\/]t3code[\\/]|[\\/]@t3tools[\\/]|[\\/]t3[\\/]|[\\/]apps[\\/]server[\\/]|[\\/]t3(code)?\.(mjs|cjs|js)|(?:^|\s)t3(code)?(?:\s|$))'
        if(($desktop -or $server) -and ((Test-Hotpl8T3Path $SettingsPath $default) -or $command.Replace('/','\').IndexOf($folder,[StringComparison]::OrdinalIgnoreCase) -ge 0)){throw 'Close the complete T3 host, including its standalone server, before changing provider settings.'}
    }
}

function Get-Hotpl8T3SettingsChanges($Before,$After) {
    foreach($key in @('defaultModelSelection','textGenerationModelSelection','sourceControlWriterModelSelection')){
        $present=[bool]$After.PSObject.Properties[$key]
        if(($Before.$key|ConvertTo-Json -Depth 40 -Compress) -cne ($After.$key|ConvertTo-Json -Depth 40 -Compress) -or [bool]$Before.PSObject.Properties[$key] -ne $present){[pscustomobject]@{parent='';key=$key;present=$present;value=$After.$key}}
    }
    $keys=@(@($Before.providerInstances.PSObject.Properties.Name)+@($After.providerInstances.PSObject.Properties.Name)|Select-Object -Unique)
    foreach($key in $keys){
        $present=[bool]$After.providerInstances.PSObject.Properties[$key]
        if(($Before.providerInstances.$key|ConvertTo-Json -Depth 40 -Compress) -cne ($After.providerInstances.$key|ConvertTo-Json -Depth 40 -Compress)){
            [pscustomobject]@{parent='providerInstances';key=$key;present=$present;value=$After.providerInstances.$key}
        }
    }
}

function Enter-Hotpl8T3SettingsLock([string]$SettingsPath) {
    try{return [IO.File]::Open(([IO.Path]::GetFullPath($SettingsPath)+'.hotpl8.lock'),'OpenOrCreate','ReadWrite','None')}catch{throw 'T3 settings setup is busy; retry after its current operation.'}
}
function Complete-Hotpl8T3SettingsTransaction([string]$SettingsPath,[string]$ReceiptPath,$Receipt) {
    if($Receipt.phase -ne 'prepared'){return}
    $guard=Enter-Hotpl8T3SettingsLock $SettingsPath
    try{
        # Another setup may have acknowledged or superseded this journal since
        # the caller read it. Only the current receipt can authorize recovery.
        $currentReceipt=Read-Hotpl8Json $ReceiptPath
        if(-not $currentReceipt){throw 'T3 integration receipt is unreadable; preserve it and reconcile.'}
        Complete-Hotpl8T3SettingsTransactionLocked $SettingsPath $ReceiptPath $currentReceipt
    }finally{$guard.Dispose()}
}
function Complete-Hotpl8T3SettingsTransactionLocked([string]$SettingsPath,[string]$ReceiptPath,$Receipt) {
    if($Receipt.phase -ne 'prepared'){return}
    if(-not (Test-Hotpl8T3Path $Receipt.settingsPath $SettingsPath) -or $Receipt.transaction.operation -notin @('install','remove','defaults')){throw 'Invalid T3 setup transaction.'}
    Assert-Hotpl8T3HostStopped $SettingsPath
    $current=[IO.File]::ReadAllText($SettingsPath);$digest=Get-Hotpl8Hash $current
    if($digest -eq $Receipt.transaction.beforeDigest){
        $next=$current|ConvertFrom-Json
        foreach($change in @($Receipt.transaction.changes)){
            if($change.parent -eq 'providerInstances'){
                if($change.key -ne $Receipt.targetProviderId){throw 'Invalid T3 transaction provider ownership.'}
                $part=$next.providerInstances
            }elseif(-not $change.parent -and $change.key -in @('defaultModelSelection','textGenerationModelSelection','sourceControlWriterModelSelection')){$part=$next}
            else{throw 'Invalid T3 transaction settings key.'}
            if($change.present){
                if($part.PSObject.Properties[$change.key]){$part.PSObject.Properties[$change.key].Value=$change.value}else{$part|Add-Member NoteProperty $change.key $change.value}
            }else{$part.PSObject.Properties.Remove([string]$change.key)}
        }
        $nextText=$next|ConvertTo-Json -Depth 50
        if((Get-Hotpl8Hash $nextText) -ne $Receipt.transaction.afterDigest){throw 'T3 transaction contents do not match the planned settings.'}
        # The host remains closed for this operation. Recheck immediately before
        # the atomic file replacement; no host restart is performed by setup.
        Assert-Hotpl8T3HostStopped $SettingsPath
        if([IO.File]::ReadAllText($SettingsPath) -cne $current){throw 'T3 settings changed concurrently; no settings were replaced.'}
        Write-Hotpl8Text $SettingsPath $nextText -NoBom
    }elseif($digest -ne $Receipt.transaction.afterDigest){throw 'T3 setup transaction conflicts with current settings; preserve them and reconcile.'}
    $Receipt|Add-Member NoteProperty phase $(if($Receipt.transaction.operation -eq 'remove'){'removed'}else{'installed'}) -Force
    Write-Hotpl8Text $ReceiptPath ($Receipt|ConvertTo-Json -Depth 50) -NoBom
}

function Invoke-Hotpl8T3SettingsTransaction([string]$SettingsPath,[string]$ExpectedText,$Next,[string]$ReceiptPath,$Receipt,[string]$Operation) {
    # All integrations targeting one settings file share this lock. If an
    # integration lock is also needed, acquire it before this short transaction.
    $guard=Enter-Hotpl8T3SettingsLock $SettingsPath
    try{
    Assert-Hotpl8T3HostStopped $SettingsPath
    if([IO.File]::ReadAllText($SettingsPath) -cne $ExpectedText){throw 'T3 settings changed concurrently; no settings were replaced.'}
    $nextText=$Next|ConvertTo-Json -Depth 50
    $Receipt|Add-Member NoteProperty phase 'prepared' -Force
    $Receipt|Add-Member NoteProperty transaction ([pscustomobject]@{operation=$Operation;beforeDigest=(Get-Hotpl8Hash $ExpectedText);afterDigest=(Get-Hotpl8Hash $nextText);changes=@(Get-Hotpl8T3SettingsChanges ($ExpectedText|ConvertFrom-Json) $Next)}) -Force
    Write-Hotpl8Text $ReceiptPath ($Receipt|ConvertTo-Json -Depth 50) -NoBom
    Complete-Hotpl8T3SettingsTransactionLocked $SettingsPath $ReceiptPath $Receipt
    }finally{$guard.Dispose()}
}
