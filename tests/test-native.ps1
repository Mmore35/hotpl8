# The compiled reader may answer only with exactly what PowerShell would print. Every other
# state -- absent, disabled, another build, declined, failed, cut off -- must leave the answer
# to PowerShell. Offline, against a synthetic release.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/lifecycle.ps1')
. (Join-Path $root 'src/native.ps1')
$windows=$env:OS -eq 'Windows_NT'
if(-not $windows -and -not $IsMacOS){throw 'This suite requires Windows or macOS.'}
$relative=if($windows){'bin/windows/hotpl8-native.exe'}else{'bin/macos/hotpl8-native'}
$real=Join-Path $root $relative
if(-not [IO.File]::Exists($real)){throw 'Build the native reader first: scripts/build-native.ps1'}
$shell=(Get-Process -Id $PID).Path
$lab=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-native-test-'+[guid]::NewGuid().ToString('N'))
$release=Join-Path $lab 'release with spaces'
$reader=Join-Path $release $relative
$log=Join-Path $lab 'calls.log'
$fake=Join-Path $lab $(if($windows){'fake.exe'}else{'fake'})
$buildFile=Join-Path $release 'build-info.json'
$fixtureSha='a'*40
$names=@('HOTPL8_NATIVE','HOTPL8_TEST_NATIVE_LOG','HOTPL8_TEST_NATIVE_HANG','HOTPL8_TEST_NATIVE_CHECK_OUTPUT','HOTPL8_TEST_NATIVE_CHECK_EXIT','HOTPL8_TEST_NATIVE_OUTPUT','HOTPL8_TEST_NATIVE_EXIT')
$prior=@{};foreach($name in $names){$prior[$name]=[Environment]::GetEnvironmentVariable($name)}
$script:passed=0;$script:failed=0
function Assert($Value,$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check($Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message+' at '+$_.ScriptStackTrace}}
function Set-Reader([string]$Source) {
    if([IO.File]::Exists($reader)){[IO.File]::Delete($reader)}
    if(-not $Source){return}
    [void][IO.Directory]::CreateDirectory((Split-Path $reader -Parent))
    [IO.File]::Copy($Source,$reader)
    if(-not $windows){[IO.File]::SetUnixFileMode($reader,[IO.UnixFileMode]'UserRead,UserWrite,UserExecute')}
}
function Set-Build([string]$Text) {
    if([IO.File]::Exists($buildFile)){[IO.File]::Delete($buildFile)}
    if($Text){Write-Hotpl8Text $buildFile $Text -NoBom}
}
function Get-BuildText([string]$Sha,[string]$Extra='') {
    '{"protocol":1,"product":"hotpl8","repository":"example/hotpl8","sha":"'+$Sha+'","channel":"main"'+$Extra+'}'
}
# The fake answers a matching identity and a sentinel unless a case overrides one setting.
function Use-Fake([hashtable]$Settings=@{}) {
    Set-Reader $fake
    $values=@{HOTPL8_NATIVE='';HOTPL8_TEST_NATIVE_LOG=$log;HOTPL8_TEST_NATIVE_HANG='';HOTPL8_TEST_NATIVE_CHECK_OUTPUT=('hotpl8-native protocol=1 sha='+$fixtureSha+"`n");HOTPL8_TEST_NATIVE_CHECK_EXIT='0';HOTPL8_TEST_NATIVE_OUTPUT="native-sentinel`n";HOTPL8_TEST_NATIVE_EXIT='0'}
    foreach($key in $Settings.Keys){$values[$key]=$Settings[$key]}
    foreach($key in $values.Keys){[Environment]::SetEnvironmentVariable($key,$values[$key])}
    [IO.File]::WriteAllText($log,'')
}
function Get-Calls {@([IO.File]::ReadAllLines($log))}
function Invoke-Entry([string[]]$Arguments) {
    Invoke-Hotpl8Process $shell (@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $release 'hotpl8.ps1'))+$Arguments) 60000
}
function Get-PowerShellAnswer([string[]]$Arguments) {
    $before=$env:HOTPL8_NATIVE;$env:HOTPL8_NATIVE='0'
    try{Invoke-Entry $Arguments}finally{[Environment]::SetEnvironmentVariable('HOTPL8_NATIVE',$before)}
}
function Test-SameJson([string]$Left,[string]$Right) {
    ($Left|ConvertFrom-Json|ConvertTo-Json -Depth 8 -Compress) -ceq ($Right|ConvertFrom-Json|ConvertTo-Json -Depth 8 -Compress)
}
try{
    [void][IO.Directory]::CreateDirectory($release)
    foreach($file in @(Get-Hotpl8ReleaseFiles $root|Where-Object{-not $_.StartsWith('bin/')})){
        $target=Join-Path $release $file
        [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
        [IO.File]::Copy((Join-Path $root $file),$target)
    }
    if($windows){
        Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'native-fake.cs'))) -OutputAssembly $fake -OutputType ConsoleApplication
    }else{
        $script=@('#!/bin/sh','if [ -n "$HOTPL8_TEST_NATIVE_LOG" ]; then (IFS="|"; printf ''%s\n'' "$*" >> "$HOTPL8_TEST_NATIVE_LOG"); fi','if [ "$HOTPL8_TEST_NATIVE_HANG" = 1 ]; then exec sleep 30; fi','if [ "$1" = self-check ]; then','  printf ''%s'' "$HOTPL8_TEST_NATIVE_CHECK_OUTPUT"; printf ''fixture diagnostic'' >&2; exit "${HOTPL8_TEST_NATIVE_CHECK_EXIT:-0}"','fi','printf ''%s'' "$HOTPL8_TEST_NATIVE_OUTPUT"; printf ''fixture diagnostic'' >&2; exit "${HOTPL8_TEST_NATIVE_EXIT:-0}"','')
        [IO.File]::WriteAllText($fake,($script -join "`n"))
        [IO.File]::SetUnixFileMode($fake,[IO.UnixFileMode]'UserRead,UserWrite,UserExecute')
    }
    $version=(Get-Content (Join-Path $release 'VERSION') -Raw).Trim()
    $line=[Environment]::NewLine

    Check 'a release without a reader answers from PowerShell' {
        Set-Reader '';Set-Build (Get-BuildText $fixtureSha)
        foreach($name in $names){[Environment]::SetEnvironmentVariable($name,'')}
        Assert ($null -eq (Get-Hotpl8NativePath $release))
        $script:plain=Invoke-Entry @('version')
        Assert ($script:plain.exitCode -eq 0 -and $script:plain.output -ceq ($version+' main '+$fixtureSha.Substring(0,12)+$line)) $script:plain.output
        $script:plainJson=Invoke-Entry @('version','-AsJson')
        Assert ($script:plainJson.exitCode -eq 0 -and ($script:plainJson.output|ConvertFrom-Json).build.sha -ceq $fixtureSha)
    }
    Check 'a reader that reports this protocol and commit is used' {
        Use-Fake
        Assert ((Get-Hotpl8NativePath $release) -eq $reader)
        Use-Fake
        $result=Invoke-Entry @('version')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq ('native-sentinel'+$line)) $result.output
        $calls=Get-Calls
        Assert ($calls.Count -eq 2 -and $calls[0] -ceq 'self-check' -and $calls[1] -ceq ('version|--root|'+$release)) ($calls -join ';')
        Use-Fake
        $result=Invoke-Entry @('version','-AsJson')
        Assert ($result.output -ceq ('native-sentinel'+$line) -and (Get-Calls)[1] -ceq ('version|--root|'+$release+'|-AsJson'))
    }
    Check 'the kill switch gives the PowerShell answer and never starts the reader' {
        Use-Fake @{HOTPL8_NATIVE='0'}
        $result=Invoke-Entry @('version')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq $script:plain.output) $result.output
        Assert ((Get-Calls).Count -eq 0)
    }
    Check 'a reader with another protocol, commit or failed check is not used' {
        $cases=@(
            @{HOTPL8_TEST_NATIVE_CHECK_OUTPUT=('hotpl8-native protocol=2 sha='+$fixtureSha+"`n")},
            @{HOTPL8_TEST_NATIVE_CHECK_OUTPUT=('hotpl8-native protocol=1 sha='+('b'*40)+"`n")},
            @{HOTPL8_TEST_NATIVE_CHECK_OUTPUT="hotpl8-native protocol=1 sha=unknown`n"},
            @{HOTPL8_TEST_NATIVE_CHECK_OUTPUT=('hotpl8-native protocol=1 sha='+$fixtureSha)},
            @{HOTPL8_TEST_NATIVE_CHECK_OUTPUT=('hotpl8-native protocol=1 sha='+$fixtureSha+"`nmore`n")},
            @{HOTPL8_TEST_NATIVE_CHECK_OUTPUT=''},
            @{HOTPL8_TEST_NATIVE_CHECK_EXIT='3'}
        )
        foreach($case in $cases){
            Use-Fake $case
            Assert ($null -eq (Get-Hotpl8NativePath $release)) ($case.Values -join ' ')
            Assert ($null -eq (Invoke-Hotpl8Native $release @('version','--root',$release)))
            Assert (@(Get-Calls|Where-Object{$_ -cne 'self-check'}).Count -eq 0)
        }
        Use-Fake $cases[1]
        $result=Invoke-Entry @('version')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq $script:plain.output) $result.output
    }
    Check 'a reader that declines, fails or is cut off leaves the answer to PowerShell' {
        $cases=@(
            @{HOTPL8_TEST_NATIVE_EXIT='64'},
            @{HOTPL8_TEST_NATIVE_EXIT='1'},
            @{HOTPL8_TEST_NATIVE_EXIT='3'},
            @{HOTPL8_TEST_NATIVE_OUTPUT='native-sentinel'},
            @{HOTPL8_TEST_NATIVE_OUTPUT=''}
        )
        foreach($case in $cases){
            Use-Fake $case
            Assert ($null -eq (Invoke-Hotpl8Native $release @('version','--root',$release))) ($case.Values -join ' ')
            Assert ((Get-Calls).Count -eq 2)
        }
        Use-Fake $cases[0]
        $result=Invoke-Entry @('version')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq $script:plain.output) $result.output
        Use-Fake $cases[1]
        $result=Invoke-Entry @('version','-AsJson')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq $script:plainJson.output) $result.output
    }
    Check 'a missing, corrupt or non-executable reader file is not used' {
        Use-Fake;Set-Reader ''
        Assert ($null -eq (Get-Hotpl8NativePath $release))
        $result=Invoke-Entry @('version')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq $script:plain.output) $result.output
        $corrupt=Join-Path $lab 'corrupt'
        [IO.File]::WriteAllBytes($corrupt,[byte[]](1..64))
        Set-Reader $corrupt
        Assert ($null -eq (Get-Hotpl8NativePath $release))
        $result=Invoke-Entry @('version')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq $script:plain.output) $result.output
        if(-not $windows){
            Use-Fake
            [IO.File]::SetUnixFileMode($reader,[IO.UnixFileMode]'UserRead,UserWrite')
            Assert ($null -eq (Get-Hotpl8NativePath $release))
            Assert ((Get-Calls).Count -eq 0)
        }
    }
    Check 'a release whose build identity cannot be read does not use the reader' {
        foreach($text in @('{','[]','{"sha":"short"}','{"sha":5}',(Get-BuildText $fixtureSha.ToUpperInvariant()))){
            Use-Fake;Set-Build $text
            Assert ($null -eq (Get-Hotpl8NativePath $release)) $text
            Assert ((Get-Calls).Count -eq 0)
        }
        Use-Fake;Set-Build '{'
        $result=Invoke-Entry @('version')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq ($version+$line)) $result.output
        Set-Build (Get-BuildText $fixtureSha)
    }
    Check 'a source checkout accepts the protocol alone' {
        Use-Fake @{HOTPL8_TEST_NATIVE_CHECK_OUTPUT="hotpl8-native protocol=1 sha=unknown`n"};Set-Build ''
        Assert ((Get-Hotpl8NativePath $release) -eq $reader)
        Use-Fake @{HOTPL8_TEST_NATIVE_CHECK_OUTPUT="hotpl8-native protocol=2 sha=unknown`n"}
        Assert ($null -eq (Get-Hotpl8NativePath $release))
        Set-Build (Get-BuildText $fixtureSha)
    }
    Check 'only a plain version request reaches the reader' {
        Use-Fake
        $result=Invoke-Entry @('version','-StateDirectory',$lab)
        Assert ($result.exitCode -eq 0 -and $result.output -ceq $script:plain.output) $result.output
        $result=Invoke-Entry @('help')
        Assert ($result.exitCode -eq 0 -and $result.output -notmatch 'native-sentinel')
        Assert ((Get-Calls).Count -eq 0)
        # The Mac launcher's Codex binding is not a reason to answer from PowerShell.
        $result=Invoke-Entry @('version','-CodexExecutable',$fake)
        Assert ($result.exitCode -eq 0 -and $result.output -ceq ('native-sentinel'+$line)) $result.output
        Assert ((Get-Calls)[1] -ceq ('version|--root|'+$release)) ((Get-Calls) -join ';')
    }
    Check 'a reader that does not finish is stopped' {
        Use-Fake @{HOTPL8_TEST_NATIVE_HANG='1'}
        $clock=[Diagnostics.Stopwatch]::StartNew()
        Assert ($null -eq (Invoke-Hotpl8NativeProcess $reader @('self-check') 500))
        Assert ($clock.ElapsedMilliseconds -lt 10000)
        if($windows){
            # A running image cannot be deleted, so this proves the process ended.
            for($attempt=0;;$attempt++){try{[IO.File]::Delete($reader);break}catch{if($attempt -ge 80){throw};Start-Sleep -Milliseconds 25}}
        }
    }
    foreach($name in $names){[Environment]::SetEnvironmentVariable($name,'')}
    $identity=Invoke-Hotpl8NativeProcess $real @('self-check')
    Check 'the built reader reports its protocol and commit' {
        Assert ($identity -and $identity.exitCode -eq 0 -and $identity.output -cmatch '\Ahotpl8-native protocol=1 sha=([a-f0-9]{40}|unknown)\n\z') $identity.output
    }
    $builtSha=if($identity.output -cmatch 'sha=([a-f0-9]{40})'){$Matches[1]}else{$null}
    Check 'the built reader gives the PowerShell answer for a source checkout' {
        Set-Reader $real;Set-Build ''
        Assert ((Get-Hotpl8NativePath $release) -eq $reader)
        $expected=Get-PowerShellAnswer @('version')
        Assert ($expected.exitCode -eq 0 -and $expected.output -ceq ($version+$line))
        Assert (((Invoke-Hotpl8Native $release @('version','--root',$release))+$line) -ceq $expected.output)
        $result=Invoke-Entry @('version')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq $expected.output) $result.output
        $expected=Get-PowerShellAnswer @('version','-AsJson')
        Assert (Test-SameJson (Invoke-Hotpl8Native $release @('version','--root',$release,'-AsJson')) $expected.output)
        $result=Invoke-Entry @('version','-AsJson')
        Assert ($result.exitCode -eq 0 -and (Test-SameJson $result.output $expected.output)) $result.output
    }
    Check 'the built reader gives the PowerShell answer for a release of its own commit' {
        Assert $builtSha 'This reader was built without a commit; rebuild it with scripts/build-native.ps1 inside a git checkout.'
        Set-Reader $real;Set-Build (Get-BuildText $builtSha)
        Assert ((Get-Hotpl8NativePath $release) -eq $reader)
        $expected=Get-PowerShellAnswer @('version')
        Assert ($expected.exitCode -eq 0 -and $expected.output -ceq ($version+' main '+$builtSha.Substring(0,12)+$line))
        Assert (((Invoke-Hotpl8Native $release @('version','--root',$release))+$line) -ceq $expected.output)
        $result=Invoke-Entry @('version')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq $expected.output) $result.output
        $expected=Get-PowerShellAnswer @('version','-AsJson')
        $native=Invoke-Hotpl8Native $release @('version','--root',$release,'-AsJson')
        Assert (Test-SameJson $native $expected.output) $native
        Assert (@(($native|ConvertFrom-Json).build.PSObject.Properties.Name) -join ',' -ceq 'protocol,product,repository,sha,channel')
    }
    Check 'the built reader is not used for a release of another commit' {
        Set-Reader $real;Set-Build (Get-BuildText ('c'*40))
        Assert ($null -eq (Get-Hotpl8NativePath $release))
        $result=Invoke-Entry @('version')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq ($version+' main cccccccccccc'+$line)) $result.output
    }
    Check 'input the built reader does not model is declined and PowerShell answers' {
        Assert $builtSha 'This reader was built without a commit.'
        Set-Reader $real;Set-Build (Get-BuildText $builtSha ',"extra":{"nested":true}')
        $declined=Invoke-Hotpl8NativeProcess $reader @('version','--root',$release,'-AsJson')
        Assert ($declined.exitCode -eq 64 -and $declined.output -eq '') ([string]$declined.exitCode)
        $declined=Invoke-Hotpl8NativeProcess $reader @('status')
        Assert ($declined.exitCode -eq 64 -and $declined.output -eq '')
        $expected=Get-PowerShellAnswer @('version','-AsJson')
        $result=Invoke-Entry @('version','-AsJson')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq $expected.output -and ($result.output|ConvertFrom-Json).build.extra.nested) $result.output
    }
}finally{
    foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$prior[$name])}
    $full=[IO.Path]::GetFullPath($lab)
    if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-native-test-[a-f0-9]{32}$' -and (Test-Path -LiteralPath $full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
'Native: '+$script:passed+' passed, '+$script:failed+' failed.'
if($script:failed){exit 1}
