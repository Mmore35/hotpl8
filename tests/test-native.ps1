# The compiled reader may answer only with exactly what PowerShell would print. Every other
# state -- absent, disabled, another build, a caller it does not follow, declined, failed,
# cut off -- must leave the answer to PowerShell. Offline, against a synthetic release.
# What the reader answers for status and explain is tests/test-native-parity.ps1.
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
# Stated here on its own, not asked of the code under test: which callers the reader follows.
$edition=if($PSVersionTable.PSEdition -eq 'Core'){'core'}else{'desktop'}
$shellVersion=$PSVersionTable.PSVersion
$followedShell=if($edition -eq 'core'){$shellVersion.Major -gt 7 -or ($shellVersion.Major -eq 7 -and $shellVersion.Minor -ge 5)}else{$shellVersion.Major -eq 5 -and $shellVersion.Minor -eq 1}
$region=[Globalization.CultureInfo]::CurrentCulture
$followedRegion=($region.Name -eq '' -or $region.Name -ceq 'en' -or $region.Name.StartsWith('en-',[StringComparison]::Ordinal)) -and (1.5).ToString($region) -ceq '1.5' -and (-1).ToString($region) -ceq '-1' -and ([datetime]'2026-01-02T03:04:05').ToString('t',$region).Contains(':')
$followed=$followedShell -and $followedRegion
$caller='--protocol|2|--shell|'+$edition
$names=@('HOTPL8_NATIVE','HOTPL8_TEST_NATIVE_LOG','HOTPL8_TEST_NATIVE_HANG','HOTPL8_TEST_NATIVE_OUTPUT','HOTPL8_TEST_NATIVE_EXIT')
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
# The fake answers a sentinel unless a case overrides one setting.
function Use-Fake([hashtable]$Settings=@{}) {
    Set-Reader $fake
    $values=@{HOTPL8_NATIVE='';HOTPL8_TEST_NATIVE_LOG=$log;HOTPL8_TEST_NATIVE_HANG='';HOTPL8_TEST_NATIVE_OUTPUT="native-sentinel`n";HOTPL8_TEST_NATIVE_EXIT='0'}
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
# The answer of src/native.ps1 under another regional format, which this thread then leaves again.
function Invoke-InRegion([Globalization.CultureInfo]$Region,[scriptblock]$Body) {
    $before=[Threading.Thread]::CurrentThread.CurrentCulture
    try{[Threading.Thread]::CurrentThread.CurrentCulture=$Region;& $Body}finally{[Threading.Thread]::CurrentThread.CurrentCulture=$before}
}
try{
    [void][IO.Directory]::CreateDirectory($release)
    foreach($file in @(Get-Hotpl8ReleaseFiles $root|Where-Object{-not $_.StartsWith('bin/')})){
        $target=Join-Path $release $file
        [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
        [IO.File]::Copy((Join-Path $root $file),$target)
    }
    if($windows){
        $source=Join-Path $PSScriptRoot 'native-fake.cs'
        if($edition -eq 'core'){
            # PowerShell 7 cannot build a program; the Windows PowerShell beside it can.
            $compile="Add-Type -TypeDefinition ([IO.File]::ReadAllText('"+$source.Replace("'","''")+"')) -OutputAssembly '"+$fake.Replace("'","''")+"' -OutputType ConsoleApplication"
            $null=Invoke-Hotpl8Process (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$compile) 60000
        }else{Add-Type -TypeDefinition ([IO.File]::ReadAllText($source)) -OutputAssembly $fake -OutputType ConsoleApplication}
        if(-not [IO.File]::Exists($fake)){throw 'Could not build the stand-in reader.'}
    }else{
        $script=@('#!/bin/sh','if [ -n "$HOTPL8_TEST_NATIVE_LOG" ]; then (IFS="|"; printf ''%s\n'' "$*" >> "$HOTPL8_TEST_NATIVE_LOG"); fi','if [ "$HOTPL8_TEST_NATIVE_HANG" = 1 ]; then exec sleep 30; fi','printf ''%s'' "$HOTPL8_TEST_NATIVE_OUTPUT"; printf ''fixture diagnostic'' >&2; exit "${HOTPL8_TEST_NATIVE_EXIT:-0}"','')
        [IO.File]::WriteAllText($fake,($script -join "`n"))
        [IO.File]::SetUnixFileMode($fake,[IO.UnixFileMode]'UserRead,UserWrite,UserExecute')
    }
    $version=(Get-Content (Join-Path $release 'VERSION') -Raw).Trim()
    $line=[Environment]::NewLine
    $emptyState=Join-Path $lab 'empty state';[void][IO.Directory]::CreateDirectory($emptyState)
    $previewPolicy=Join-Path $lab 'preview-policy.json'

    Check 'a release without a reader answers from PowerShell' {
        Set-Reader '';Set-Build (Get-BuildText $fixtureSha)
        foreach($name in $names){[Environment]::SetEnvironmentVariable($name,'')}
        Assert ($null -eq (Get-Hotpl8NativePath $release))
        Assert ($null -eq (Invoke-Hotpl8Native $release @('version','--root',$release)))
        $script:plain=Invoke-Entry @('version')
        Assert ($script:plain.exitCode -eq 0 -and $script:plain.output -ceq ($version+' main '+$fixtureSha.Substring(0,12)+$line)) $script:plain.output
        $script:plainJson=Invoke-Entry @('version','-AsJson')
        Assert ($script:plainJson.exitCode -eq 0 -and ($script:plainJson.output|ConvertFrom-Json).build.sha -ceq $fixtureSha)
    }
    Check 'the reader is told which PowerShell is asking, or is not asked' {
        Use-Fake
        $identity=Get-Hotpl8NativeIdentity $release
        if($followed){Assert (($identity -join '|') -ceq ($caller+'|--release|'+$fixtureSha)) ($identity -join '|')}
        else{Assert ($null -eq $identity) ($identity -join '|')}
        # Continuous integration must not pass by never asking the reader.
        if($env:GITHUB_ACTIONS -eq 'true'){Assert $followed ('This runner is not a caller the reader follows: '+$edition+' '+$shellVersion+' '+$region.Name)}
    }
    if(-not $followed){
        'NOTE the reader does not follow this caller ('+$edition+' '+$shellVersion+', regional format "'+$region.Name+'"); checking only that PowerShell answers.'
        Check 'a caller the reader does not follow gets the PowerShell answer and never starts the reader' {
            Use-Fake
            Assert ((Get-Hotpl8NativePath $release) -eq $reader)
            Assert ($null -eq (Invoke-Hotpl8Native $release @('version','--root',$release)))
            foreach($arguments in @(@('version'),@('version','-AsJson'))){
                $result=Invoke-Entry $arguments
                Assert ($result.exitCode -eq 0 -and $result.output -notmatch 'native-sentinel') $result.output
            }
            foreach($command in 'status','explain'){
                $result=Invoke-Entry @($command,'-StateDirectory',$emptyState)
                Assert ($result.output -notmatch 'native-sentinel') $result.output
            }
            Assert ((Get-Calls).Count -eq 0)
        }
    }else{
    Check 'a request reaches the reader in one start, with the caller and the release named' {
        Use-Fake
        Assert ((Get-Hotpl8NativePath $release) -eq $reader)
        $result=Invoke-Entry @('version')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq ('native-sentinel'+$line)) $result.output
        Assert (((Get-Calls) -join ';') -ceq ('version|'+$caller+'|--release|'+$fixtureSha+'|--root|'+$release)) ((Get-Calls) -join ';')
        Use-Fake
        $result=Invoke-Entry @('version','-AsJson')
        Assert ($result.output -ceq ('native-sentinel'+$line) -and ((Get-Calls) -join ';') -ceq ('version|'+$caller+'|--release|'+$fixtureSha+'|--root|'+$release+'|-AsJson')) ((Get-Calls) -join ';')
    }
    Check 'status and explain reach the reader with the directories they were given' {
        foreach($command in 'status','explain'){
            $prefix=$command+'|'+$caller+'|--release|'+$fixtureSha+'|--root|'+$release
            Use-Fake
            $result=Invoke-Entry @($command)
            Assert ($result.exitCode -eq 0 -and $result.output -ceq ('native-sentinel'+$line)) $result.output
            Assert (((Get-Calls) -join ';') -ceq $prefix) ((Get-Calls) -join ';')
            Use-Fake
            $result=Invoke-Entry @($command,'-StateDirectory',$emptyState,'-PreviewPolicy',$previewPolicy,'-AsJson')
            Assert ($result.exitCode -eq 0 -and $result.output -ceq ('native-sentinel'+$line)) $result.output
            Assert (((Get-Calls) -join ';') -ceq ($prefix+'|--state|'+$emptyState+'|--policy|'+$previewPolicy+'|-AsJson')) ((Get-Calls) -join ';')
            # The Mac launcher's Codex binding is not a reason to answer from PowerShell.
            Use-Fake
            $result=Invoke-Entry @($command,'-CodexExecutable',$fake,'-PreviewPolicy',$previewPolicy)
            Assert ($result.exitCode -eq 0 -and $result.output -ceq ('native-sentinel'+$line)) $result.output
            Assert (((Get-Calls) -join ';') -ceq ($prefix+'|--policy|'+$previewPolicy)) ((Get-Calls) -join ';')
        }
    }
    Check 'text arrives one line at a time and JSON as one value' {
        $text="first`n`n  third `nlast`n"
        $entry="& '"+(Join-Path $release 'hotpl8.ps1').Replace("'","''")+"' status"
        Use-Fake @{HOTPL8_TEST_NATIVE_OUTPUT=$text}
        $result=Invoke-Hotpl8Process $shell @('-NoProfile','-ExecutionPolicy','Bypass','-Command',('$all=@('+$entry+');$all.Count;$all|ForEach-Object{''<''+$_+''>''}')) 60000
        Assert ($result.output -ceq (@('4','<first>','<>','<  third >','<last>','') -join $line)) $result.output
        Use-Fake @{HOTPL8_TEST_NATIVE_OUTPUT=$text}
        $result=Invoke-Hotpl8Process $shell @('-NoProfile','-ExecutionPolicy','Bypass','-Command',('$all=@('+$entry+' -AsJson);$all.Count;$all[0].Replace([string][char]10,''/'')')) 60000
        Assert ($result.output -ceq (@('1','first//  third /last','') -join $line)) $result.output
    }
    Check 'the kill switch gives the PowerShell answer and never starts the reader' {
        Use-Fake @{HOTPL8_NATIVE='0'}
        $result=Invoke-Entry @('version')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq $script:plain.output) $result.output
        foreach($command in 'status','explain'){
            $result=Invoke-Entry @($command,'-StateDirectory',$emptyState)
            Assert ($result.output -notmatch 'native-sentinel') $result.output
        }
        Assert ((Get-Calls).Count -eq 0)
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
            Assert ((Get-Calls).Count -eq 1)
        }
        Use-Fake $cases[0]
        $result=Invoke-Entry @('version')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq $script:plain.output) $result.output
        Use-Fake $cases[1]
        $result=Invoke-Entry @('version','-AsJson')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq $script:plainJson.output) $result.output
        # What PowerShell says about a directory holding no policy is its own to say.
        $expected=Get-PowerShellAnswer @('status','-StateDirectory',$emptyState)
        foreach($case in $cases){
            Use-Fake $case
            $result=Invoke-Entry @('status','-StateDirectory',$emptyState)
            Assert ($result.exitCode -eq $expected.exitCode -and $result.output -ceq $expected.output) $result.output
            Assert ((Get-Calls).Count -eq 1)
        }
    }
    Check 'a missing, corrupt or non-executable reader file is not used' {
        Use-Fake;Set-Reader ''
        Assert ($null -eq (Get-Hotpl8NativePath $release))
        $result=Invoke-Entry @('version')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq $script:plain.output) $result.output
        # A file that is not a program fails to start, which is one more reason to answer here.
        $corrupt=Join-Path $lab 'corrupt'
        [IO.File]::WriteAllBytes($corrupt,[byte[]](1..64))
        Set-Reader $corrupt
        Assert ($null -eq (Invoke-Hotpl8Native $release @('version','--root',$release)))
        $result=Invoke-Entry @('version')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq $script:plain.output) $result.output
        if(-not $windows){
            Use-Fake
            [IO.File]::SetUnixFileMode($reader,[IO.UnixFileMode]'UserRead,UserWrite')
            Assert ($null -eq (Get-Hotpl8NativePath $release))
            Assert ($null -eq (Invoke-Hotpl8Native $release @('version','--root',$release)))
            Assert ((Get-Calls).Count -eq 0)
        }
    }
    Check 'a release whose build identity cannot be read does not use the reader' {
        foreach($text in @('{','[]','{"sha":"short"}','{"sha":5}',(Get-BuildText $fixtureSha.ToUpperInvariant()))){
            Use-Fake;Set-Build $text
            Assert ($null -eq (Get-Hotpl8NativeIdentity $release)) $text
            Assert ($null -eq (Invoke-Hotpl8Native $release @('version','--root',$release))) $text
            Assert ((Get-Calls).Count -eq 0)
        }
        Use-Fake;Set-Build '{'
        $result=Invoke-Entry @('version')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq ($version+$line)) $result.output
        Assert ((Get-Calls).Count -eq 0)
        Set-Build (Get-BuildText $fixtureSha)
    }
    Check 'a source checkout names no release' {
        Use-Fake;Set-Build ''
        Assert ((Invoke-Hotpl8Native $release @('version','--root',$release)) -ceq 'native-sentinel')
        Assert (((Get-Calls) -join ';') -ceq ('version|'+$caller+'|--root|'+$release)) ((Get-Calls) -join ';')
        Set-Build (Get-BuildText $fixtureSha)
    }
    Check 'a regional format the reader does not know is answered by PowerShell' {
        $comma=New-Object Globalization.CultureInfo 'en-US';$comma.NumberFormat.NumberDecimalSeparator=','
        $minus=New-Object Globalization.CultureInfo 'en-US';$minus.NumberFormat.NegativeSign=[string][char]0x2212
        $clock=New-Object Globalization.CultureInfo 'en-US';$clock.DateTimeFormat.TimeSeparator='.'
        foreach($other in @((New-Object Globalization.CultureInfo 'de-DE'),(New-Object Globalization.CultureInfo 'tr-TR'),(New-Object Globalization.CultureInfo 'th-TH'),(New-Object Globalization.CultureInfo 'ar-SA'),$comma,$minus,$clock)){
            Use-Fake
            Assert ($null -eq (Invoke-InRegion $other {Get-Hotpl8NativeIdentity $release})) $other.Name
            Assert ($null -eq (Invoke-InRegion $other {Invoke-Hotpl8Native $release @('version','--root',$release)})) $other.Name
            Assert ((Get-Calls).Count -eq 0)
        }
        foreach($known in @([Globalization.CultureInfo]::InvariantCulture,(New-Object Globalization.CultureInfo 'en-US'),(New-Object Globalization.CultureInfo 'en-GB'),(New-Object Globalization.CultureInfo 'en-AU'))){
            Use-Fake
            Assert ((Invoke-InRegion $known {Invoke-Hotpl8Native $release @('version','--root',$release)}) -ceq 'native-sentinel') $known.Name
        }
    }
    Check 'anything but a plain version, status or explain request never starts the reader' {
        Use-Fake
        $result=Invoke-Entry @('version','-StateDirectory',$lab)
        Assert ($result.exitCode -eq 0 -and $result.output -ceq $script:plain.output) $result.output
        $result=Invoke-Entry @('help')
        Assert ($result.exitCode -eq 0 -and $result.output -notmatch 'native-sentinel')
        foreach($arguments in @(@('status','-NoColor'),@('status','-Slot','main'),@('explain','-ReducedMotion'),@('explain','-Provider','claude'),@('status','-Once'))){
            $result=Invoke-Entry ($arguments+@('-StateDirectory',$emptyState))
            Assert ($result.output -notmatch 'native-sentinel') ($arguments -join ' ')
        }
        # A preview-only parameter stops these right after the point where the reader would
        # have been asked, before they observe or change anything.
        foreach($command in 'refresh','tick','watch','accounts','doctor','status','explain'){
            $result=Invoke-Entry @($command,'-StateDirectory',$emptyState,'-TrustRevision','x')
            Assert ($result.exitCode -ne 0 -and $result.output -notmatch 'native-sentinel') ($command+': '+$result.output)
        }
        Assert ((Get-Calls).Count -eq 0) ((Get-Calls) -join ';')
        # The Mac launcher's Codex binding is not a reason to answer from PowerShell.
        $result=Invoke-Entry @('version','-CodexExecutable',$fake)
        Assert ($result.exitCode -eq 0 -and $result.output -ceq ('native-sentinel'+$line)) $result.output
        Assert (((Get-Calls) -join ';') -ceq ('version|'+$caller+'|--release|'+$fixtureSha+'|--root|'+$release)) ((Get-Calls) -join ';')
    }
    Check 'a reader that does not finish is stopped' {
        Use-Fake @{HOTPL8_TEST_NATIVE_HANG='1'}
        $clock=[Diagnostics.Stopwatch]::StartNew()
        Assert ($null -eq (Invoke-Hotpl8NativeProcess $reader @('version') 500))
        Assert ($clock.ElapsedMilliseconds -lt 10000)
        if($windows){
            # A running image cannot be deleted, so this proves the process ended.
            for($attempt=0;;$attempt++){try{[IO.File]::Delete($reader);break}catch{if($attempt -ge 80){throw};Start-Sleep -Milliseconds 25}}
        }
    }
    foreach($name in $names){[Environment]::SetEnvironmentVariable($name,'')}
    $identity=Invoke-Hotpl8NativeProcess $real @('self-check')
    Check 'the built reader reports its protocol and commit' {
        Assert ($identity -and $identity.exitCode -eq 0 -and $identity.output -cmatch '\Ahotpl8-native protocol=2 sha=([a-f0-9]{40}|unknown)\n\z') $identity.output
    }
    $builtSha=if($identity.output -cmatch 'sha=([a-f0-9]{40})'){$Matches[1]}else{$null}
    Check 'the built reader gives the PowerShell answer for a source checkout' {
        Set-Reader $real;Set-Build ''
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
    Check 'the built reader declines a release of another commit, another protocol and another shell' {
        Assert $builtSha 'This reader was built without a commit.'
        Set-Reader $real;Set-Build (Get-BuildText ('c'*40))
        Assert ($null -eq (Invoke-Hotpl8Native $release @('version','--root',$release)))
        $result=Invoke-Entry @('version')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq ($version+' main cccccccccccc'+$line)) $result.output
        Set-Build (Get-BuildText $builtSha)
        $asked=Invoke-Hotpl8NativeProcess $reader @('version','--protocol','2','--shell',$edition,'--release',$builtSha,'--root',$release)
        Assert ($asked.exitCode -eq 0 -and $asked.output -ceq ($version+' main '+$builtSha.Substring(0,12)+"`n")) $asked.output
        foreach($asking in @(
            @('--protocol','1','--shell',$edition,'--release',$builtSha),
            @('--protocol','3','--shell',$edition,'--release',$builtSha),
            @('--protocol','2','--shell','other','--release',$builtSha),
            @('--protocol','2','--shell',$edition,'--release',('c'*40)),
            @('--protocol','2','--release',$builtSha),
            @('--shell',$edition,'--release',$builtSha),
            @()
        )){
            foreach($command in 'version','status','explain'){
                $declined=Invoke-Hotpl8NativeProcess $reader (@($command)+$asking+@('--root',$release))
                Assert ($declined.exitCode -eq 64 -and $declined.output -eq '') ($command+' '+($asking -join ' ')+': '+$declined.exitCode)
            }
        }
    }
    Check 'input the built reader does not model is declined and PowerShell answers' {
        Assert $builtSha 'This reader was built without a commit.'
        Set-Reader $real;Set-Build (Get-BuildText $builtSha ',"extra":{"nested":true}')
        $declined=Invoke-Hotpl8NativeProcess $reader @('version','--protocol','2','--shell',$edition,'--release',$builtSha,'--root',$release,'-AsJson')
        Assert ($declined.exitCode -eq 64 -and $declined.output -eq '') ([string]$declined.exitCode)
        foreach($command in 'refresh','tick','watch','help'){
            $declined=Invoke-Hotpl8NativeProcess $reader @($command,'--protocol','2','--shell',$edition,'--release',$builtSha,'--root',$release)
            Assert ($declined.exitCode -eq 64 -and $declined.output -eq '') $command
        }
        $expected=Get-PowerShellAnswer @('version','-AsJson')
        $result=Invoke-Entry @('version','-AsJson')
        Assert ($result.exitCode -eq 0 -and $result.output -ceq $expected.output -and ($result.output|ConvertFrom-Json).build.extra.nested) $result.output
        # A directory holding no policy is an error, and errors are PowerShell's to word.
        Set-Build (Get-BuildText $builtSha)
        $declined=Invoke-Hotpl8NativeProcess $reader @('status','--protocol','2','--shell',$edition,'--release',$builtSha,'--root',$release,'--state',$emptyState)
        Assert ($declined.exitCode -eq 64 -and $declined.output -eq '') ([string]$declined.exitCode)
        $expected=Get-PowerShellAnswer @('status','-StateDirectory',$emptyState)
        $result=Invoke-Entry @('status','-StateDirectory',$emptyState)
        Assert ($expected.exitCode -ne 0 -and $result.exitCode -eq $expected.exitCode -and $result.output -ceq $expected.output) $result.output
    }
    }
}finally{
    foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$prior[$name])}
    $full=[IO.Path]::GetFullPath($lab)
    if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-native-test-[a-f0-9]{32}$' -and (Test-Path -LiteralPath $full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
'Native: '+$script:passed+' passed, '+$script:failed+' failed.'
if($script:failed){exit 1}
