# Synthetic owned installs only. No live registration, native accounts or I/O.
$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
foreach($file in @('common','config','provider-actions','management')){. (Join-Path $source ('src/'+$file+'.ps1'))}
. (Join-Path $source 'src/providers/codex.ps1')
$script:passed=0;$script:failed=0
function Assert($Value,[string]$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check([string]$Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message+' at '+$_.InvocationInfo.ScriptLineNumber}}
function Reject([scriptblock]$Body,[string]$Expected){$message=$null;try{& $Body|Out-Null}catch{$message=$_.Exception.Message};Assert ($message -and (-not $Expected -or $message -like ('*'+$Expected+'*'))) ('expected rejection '+$Expected+', got '+$message)}
function JsonFile($Path,$Value){Write-Hotpl8Text $Path ($Value|ConvertTo-Json -Depth 32) -NoBom}
$lab=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-delivery-policy-'+[guid]::NewGuid().ToString('N'))
$install=Join-Path $lab 'custom install';$state=Join-Path $lab 'separate state'
$oldEnv=$env:HOTPL8_INSTALL_DIRECTORY;$oldLocal=$env:LOCALAPPDATA
$a='a'*40;$b='b'*40
$marker=Join-Path $state 'delivery-owner.json';$txn=Join-Path $install 'transaction.json';$policyPath=Join-Path $state 'policy.json';$backup=Join-Path $state 'policy.previous.json'
function Pointer([string]$Sha){JsonFile (Join-Path $install 'current.json') @{protocol=1;sha=$Sha;release=('releases/'+$Sha)}}
function Reset {
    $env:HOTPL8_INSTALL_DIRECTORY=$null
    $env:LOCALAPPDATA=Join-Path $lab 'unused-default'
    foreach($path in @($marker,$txn,$backup)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}}
    JsonFile (Join-Path $install 'installation.json') @{product='hotpl8';id='012345abcdef';stateDirectory=$state}
    JsonFile (Join-Path $install 'delivery.json') @{protocol=1;product='hotpl8';stateDirectory=$state;writerLocks=@((Join-Path $state 'tick.lock'))}
    Copy-Item -LiteralPath (Join-Path $source 'policy.example.json') -Destination $policyPath -Force
    Pointer $a
}
function SaveV3 {Save-Hotpl8Policy $state (ConvertTo-Hotpl8PolicyV3 (Read-Hotpl8Json $policyPath)) (Get-FileHash -LiteralPath $policyPath).Hash}
try{
    [void][IO.Directory]::CreateDirectory($state)
    $old=Join-Path $install ('releases/'+$a);$new=Join-Path $install ('releases/'+$b)
    [void][IO.Directory]::CreateDirectory((Join-Path $old 'src/providers'))
    [void][IO.Directory]::CreateDirectory($new)
    Write-Hotpl8Text (Join-Path $old 'src/common.ps1') '# synthetic old shared primitives'
    Write-Hotpl8Text (Join-Path $old 'src/config.ps1') 'function Assert-Hotpl8Policy($Policy){if($Policy.schemaVersion -gt 2){throw "unsupported policy"}}'
    Write-Hotpl8Text (Join-Path $old 'src/providers/codex.ps1') 'function Assert-CodexPolicy($Policy){}'
    Copy-Item -LiteralPath (Join-Path $source 'src') -Destination $new -Recurse
    Copy-Item -LiteralPath (Join-Path $source 'data') -Destination $new -Recurse
    Check 'drain publishes verified custom ownership before pointer changes' {
        Reset;Set-Hotpl8DeliveryOwner $install $state
        $owner=Read-Hotpl8DeliveryOwner $state
        Assert ($owner.installDirectory -ieq $install -and $owner.installationId -eq '012345abcdef')
        Assert ((Read-Hotpl8Json (Join-Path $install 'current.json')).sha -eq $a)
        $bytes=[IO.File]::ReadAllText($marker);Set-Hotpl8DeliveryOwner $install $state
        Assert ([IO.File]::ReadAllText($marker) -ceq $bytes)
    }
    Check 'pending first upgrade refuses v3 with candidate selected and no environment hint' {
        Reset;Set-Hotpl8DeliveryOwner $install $state;Pointer $b
        JsonFile $txn @{previous=@{sha=$a;release=('releases/'+$a)};candidate=@{sha=$b}}
        $bytes=[IO.File]::ReadAllText($policyPath);Write-Hotpl8Text $backup 'retained-backup'
        Reject {SaveV3} 'unfinished'
        Assert ([IO.File]::ReadAllText($policyPath) -ceq $bytes)
        Assert ([IO.File]::ReadAllText($backup) -ceq 'retained-backup')
        Assert ((Read-Hotpl8Json (Join-Path $install 'current.json')).sha -eq $b)
    }
    Check 'malformed transaction still blocks migration' {
        Reset;Set-Hotpl8DeliveryOwner $install $state;Pointer $b;Write-Hotpl8Text $txn '{broken'
        Reject {SaveV3} 'unfinished'
    }
    Check 'committed old reader rejects v3 despite newer caller validators' {
        Reset;Set-Hotpl8DeliveryOwner $install $state
        Reject {SaveV3} 'committed delivery release cannot read'
        Assert ((Read-Hotpl8Json $policyPath).schemaVersion -eq 2)
        Assert (-not (Test-Path -LiteralPath $backup))
    }
    Check 'committed new reader permits migration and caller retains its validators' {
        Reset;Set-Hotpl8DeliveryOwner $install $state;Pointer $b
        SaveV3
        Assert ((Read-Hotpl8Json $policyPath).schemaVersion -eq 3)
        Assert ((Read-Hotpl8Json $backup).schemaVersion -eq 2)
        Assert-Hotpl8Policy (Read-Hotpl8Json $policyPath)
    }
    Check 'retained marker prevents migration after old-reader rollback' {
        Reset;Set-Hotpl8DeliveryOwner $install $state;Pointer $b;Pointer $a
        Reject {SaveV3} 'committed delivery release cannot read'
        Assert (Test-Path -LiteralPath $marker)
    }
    Check 'pre-marker installed launcher context detects interrupted activation' {
        Reset;$env:HOTPL8_INSTALL_DIRECTORY=$install;JsonFile $txn @{}
        Reject {SaveV3} 'unfinished'
        Assert (-not (Test-Path -LiteralPath $marker))
    }
    Check 'pre-marker verified default registration detects old reader' {
        Reset
        $defaultBase=Join-Path $lab 'default-base';$defaultRoot=Join-Path $defaultBase 'HotPl8'
        [void][IO.Directory]::CreateDirectory($defaultRoot)
        Copy-Item -LiteralPath (Join-Path $install 'installation.json') -Destination $defaultRoot
        Copy-Item -LiteralPath (Join-Path $install 'delivery.json') -Destination $defaultRoot
        $env:LOCALAPPDATA=$defaultBase
        $owner=Read-Hotpl8DeliveryOwner $state
        Assert ($owner.installDirectory -ieq $defaultRoot)
    }
    Check 'corrupt marker never falls back to an unowned source write' {
        Reset;Write-Hotpl8Text $marker '{broken'
        Reject {SaveV3} 'marker is invalid'
        Reject {Set-Hotpl8DeliveryOwner $install $state} 'marker is invalid'
    }
    Check 'corrupt pre-marker default metadata cannot imply unmanaged state' {
        Reset;$env:LOCALAPPDATA=Join-Path $lab 'default-base'
        $defaultRoot=Join-Path $env:LOCALAPPDATA 'HotPl8'
        Write-Hotpl8Text (Join-Path $defaultRoot 'installation.json') '{broken'
        Write-Hotpl8Text (Join-Path $defaultRoot 'delivery.json') '{broken'
        Reject {SaveV3} 'ownership is unreadable'
    }
    Check 'missing registration for a known managed owner blocks migration' {
        Reset;$env:HOTPL8_INSTALL_DIRECTORY=$install
        $owned=Read-Hotpl8Json (Join-Path $install 'installation.json');$owned|Add-Member NoteProperty managedBy 'local-delivery'
        JsonFile (Join-Path $install 'installation.json') $owned
        Remove-Item -LiteralPath (Join-Path $install 'delivery.json')
        Reject {SaveV3} 'registration is missing'
    }
    Check 'marker rejects changed installation identity' {
        Reset;Set-Hotpl8DeliveryOwner $install $state
        $owned=Read-Hotpl8Json (Join-Path $install 'installation.json');$owned.id='abcdef012345';JsonFile (Join-Path $install 'installation.json') $owned
        Reject {SaveV3} 'another installation'
    }
    Check 'drain rejects unprotected state writer before publishing marker' {
        Reset;$registration=Read-Hotpl8Json (Join-Path $install 'delivery.json');$registration.writerLocks=@();JsonFile (Join-Path $install 'delivery.json') $registration
        Reject {Set-Hotpl8DeliveryOwner $install $state} 'writer lock'
        Assert (-not (Test-Path -LiteralPath $marker))
    }
    Check 'current pointer traversal cannot supply a reader' {
        Reset;Set-Hotpl8DeliveryOwner $install $state
        JsonFile (Join-Path $install 'current.json') @{protocol=1;sha=$a;release='../outside'}
        Reject {SaveV3} 'current release is invalid'
    }
    Check 'same-schema controls remain writable during an unresolved transaction' {
        Reset;Set-Hotpl8DeliveryOwner $install $state;JsonFile $txn @{}
        $p=Read-Hotpl8Json $policyPath;$p.mode='automate';Save-Hotpl8Policy $state $p
        Assert ((Read-Hotpl8Json $policyPath).mode -eq 'automate')
    }
    Check 'writer lock prevents a migration racing active delivery' {
        Reset;Set-Hotpl8DeliveryOwner $install $state;Pointer $b
        $lock=[IO.File]::Open((Join-Path $state 'tick.lock'),'OpenOrCreate','ReadWrite','None')
        try{Reject {SaveV3}}finally{$lock.Dispose()}
        Assert ((Read-Hotpl8Json $policyPath).schemaVersion -eq 2)
    }
    Check 'unmanaged source state preserves explicit migration support' {
        Reset;SaveV3;Assert ((Read-Hotpl8Json $policyPath).schemaVersion -eq 3)
    }
}finally{
    $env:HOTPL8_INSTALL_DIRECTORY=$oldEnv;$env:LOCALAPPDATA=$oldLocal
    $resolved=[IO.Path]::GetFullPath($lab)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'hotpl8-delivery-policy-*'){
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
'Delivery policy ownership: '+$script:passed+' passed, '+$script:failed+' failed.'
if($script:failed){exit 1}
