# version, status and explain are the compiled reader's alone. This checks the ways a request
# reaches it -- through the PowerShell entry, and as the words a user typed, which the
# launchers hand it before they start PowerShell -- and what a copy without a reader it can
# start says instead of an answer. Offline, against a synthetic release.
# What the reader answers from a set of files is tests/test-native-parity.ps1.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/lifecycle.ps1')
. (Join-Path $root 'src/native.ps1')
. (Join-Path $PSScriptRoot 'parity/cases.ps1')
$windows=$env:OS -eq 'Windows_NT'
if(-not $windows -and -not $IsMacOS){throw 'This suite requires Windows or macOS.'}
$relative=if($windows){'bin/windows/hotpl8-native.exe'}else{'bin/macos/hotpl8-native'}
$real=Join-Path $root $relative
if(-not [IO.File]::Exists($real)){throw 'Build the native reader first: scripts/build-native.ps1'}
$shell=(Get-Process -Id $PID).Path
$lab=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-native-test-'+[guid]::NewGuid().ToString('N'))
$release=Join-Path $lab 'release with spaces'
$reader=Join-Path $release $relative
$entry=Join-Path $release 'hotpl8.ps1'
$log=Join-Path $lab 'calls.log'
$fake=Join-Path $lab $(if($windows){'fake.exe'}else{'fake'})
$buildFile=Join-Path $release 'build-info.json'
$fixtureSha='a'*40
$line=[Environment]::NewLine
$noReader='HotPl8: This copy has no compiled reader it can start, and version, status and explain are answered by it. A release ships one; in a checkout, build it with scripts/build-native.ps1.'+$line
$noPolicy='HotPl8: No valid policy.json. Run hotpl8 setup or see docs/install.md.'+$line
# The launchers start the Windows PowerShell on PATH by name; a stand-in is put before it.
$stub=Join-Path $lab 'stub'
$desktop=if($windows){Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'}
$names=@('HOTPL8_TEST_NATIVE_LOG','HOTPL8_TEST_NATIVE_OUTPUT','HOTPL8_TEST_NATIVE_EXIT')
# What install.ps1 writes beside an ordinary installation's app directory.
$shim='@"%~dp0app\hotpl8.cmd" %*'+"`r`n"
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
function Set-Build([string]$Sha) {
    if([IO.File]::Exists($buildFile)){[IO.File]::Delete($buildFile)}
    if($Sha){Write-Hotpl8Text $buildFile ('{"protocol":1,"product":"hotpl8","repository":"example/hotpl8","sha":"'+$Sha+'","channel":"main"}') -NoBom}
}
# What a start printed, what it said on the error stream and how it ended.
function Invoke-Entry([string[]]$Arguments) {
    Invoke-Hotpl8NativeProcess $shell (@('-NoProfile','-ExecutionPolicy','Bypass','-File',$entry)+$Arguments)
}
function Invoke-Reader([string[]]$Arguments) { Invoke-Hotpl8NativeProcess $reader $Arguments }
# An answer of the reader as PowerShell's output shows it: every line ended the platform's way.
function ConvertTo-EntryOutput([string]$Text) { $Text.Replace("`n",$line) }
# Two starts read the clock twice. The instant an answer was computed at always differs and
# is left out; anything else that changed between them is asked again, and a difference
# that is still there on the third try is a difference.
function Hide-Clock([string]$Text) { [regex]::Replace($Text,'(?<="computedAt": ")[^"]+','') }
function Assert-SameAnswer([string]$Label,[scriptblock]$Through,[scriptblock]$Direct) {
    for($try=1;;$try++){
        $got=& $Through;$wanted=& $Direct
        if($got.exitCode -eq 0 -and $got.errors -eq '' -and $got.output.Contains($line) -and (Hide-Clock $got.output) -ceq (Hide-Clock $wanted)){return}
        if($try -ge 3){throw ($Label+': exit '+$got.exitCode+' <'+$got.output+'> <'+$got.errors+'>, expected <'+$wanted+'>')}
    }
}
# The stand-in reader answers a sentinel unless a case overrides one setting.
function Use-Fake([hashtable]$Settings=@{}) {
    Set-Reader $fake
    $values=@{HOTPL8_TEST_NATIVE_LOG=$log;HOTPL8_TEST_NATIVE_OUTPUT="native-sentinel`n";HOTPL8_TEST_NATIVE_EXIT='0'}
    foreach($key in $Settings.Keys){$values[$key]=$Settings[$key]}
    foreach($key in $values.Keys){[Environment]::SetEnvironmentVariable($key,$values[$key])}
    [IO.File]::WriteAllText($log,'')
}
function Get-Calls {@([IO.File]::ReadAllLines($log))}
# What cmd makes of a line typed at it: the status it ends with and the bytes each stream was
# given, a character for a byte. The line reaches cmd as it is written here.
function Invoke-Typed([string]$Typed,[hashtable]$Environment=@{}) {
    $out=Join-Path $lab 'typed.out';$err=Join-Path $lab 'typed.err'
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$env:ComSpec
    $info.Arguments='/d /s /c "'+$Typed+' < NUL > "'+$out+'" 2> "'+$err+'""'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    foreach($key in $Environment.Keys){$info.EnvironmentVariables[$key]=$Environment[$key]}
    $process=[Diagnostics.Process]::Start($info)
    try{$process.WaitForExit();$code=$process.ExitCode}finally{$process.Dispose()}
    $bytes=[Text.Encoding]::GetEncoding(28591)
    [pscustomobject]@{exitCode=$code;output=$bytes.GetString([IO.File]::ReadAllBytes($out));errors=$bytes.GetString([IO.File]::ReadAllBytes($err))}
}
# Two whole starts that must end the same way with the same bytes on both streams, the
# instant aside and asked again as above. Gives back the first of them.
function Assert-SameStart([string]$Label,[scriptblock]$Through,[scriptblock]$Direct) {
    for($try=1;;$try++){
        $got=& $Through;$wanted=& $Direct
        if($got.exitCode -eq $wanted.exitCode -and (Hide-Clock $got.output) -ceq (Hide-Clock $wanted.output) -and $got.errors -ceq $wanted.errors){return $got}
        if($try -ge 3){throw ($Label+': exit '+$got.exitCode+' <'+$got.output+'> <'+$got.errors+'>, expected exit '+$wanted.exitCode+' <'+$wanted.output+'> <'+$wanted.errors+'>')}
    }
}
try{
    [void][IO.Directory]::CreateDirectory($release)
    foreach($file in @(Get-Hotpl8ReleaseFiles $root|Where-Object{-not $_.StartsWith('bin/')})){
        $target=Join-Path $release $file
        [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
        [IO.File]::Copy((Join-Path $root $file),$target)
    }
    $version=(Get-Content (Join-Path $release 'VERSION') -Raw).Trim()
    $emptyState=Join-Path $lab 'empty state';[void][IO.Directory]::CreateDirectory($emptyState)
    # Fictional readings, observed a moment ago by this machine's clock.
    $state=Join-Path $lab 'state with spaces';[void][IO.Directory]::CreateDirectory($state)
    $plain=@(Get-Hotpl8ParityCases|Where-Object{$_.name -ceq 'plain'})[0]
    foreach($name in $plain.files.Keys){Write-Hotpl8Text (Join-Path $state $name) (Expand-Hotpl8ParityText $plain.files[$name] ([datetimeoffset]::UtcNow))}
    $previewPolicy=Join-Path $lab 'preview-policy.json'
    Write-Hotpl8Text $previewPolicy (Edit-Hotpl8ParityText (Expand-Hotpl8ParityText $plain.files['policy.json'] ([datetimeoffset]::UtcNow)) '"mode":"monitor"' '"mode":"automate"')
    # The same readings under labels no code page holds whole.
    $farState=Join-Path $lab 'far state';[void][IO.Directory]::CreateDirectory($farState)
    $far=@(Get-Hotpl8ParityCases|Where-Object{$_.name -ceq 'labels outside ASCII'})[0]
    foreach($name in $far.files.Keys){Write-Hotpl8Text (Join-Path $farState $name) (Expand-Hotpl8ParityText $far.files[$name] ([datetimeoffset]::UtcNow))}
    # A program that stands in for a reader, and on Windows for PowerShell: it records the
    # words it was started with and ends as its environment says.
    if($windows){
        $source=Join-Path $PSScriptRoot 'native-fake.cs'
        if($PSVersionTable.PSEdition -eq 'Core'){
            # PowerShell 7 cannot build a program; the Windows PowerShell beside it can.
            $compile="Add-Type -TypeDefinition ([IO.File]::ReadAllText('"+$source.Replace("'","''")+"')) -OutputAssembly '"+$fake.Replace("'","''")+"' -OutputType ConsoleApplication"
            $null=Invoke-Hotpl8Process $desktop @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$compile) 60000
        }else{Add-Type -TypeDefinition ([IO.File]::ReadAllText($source)) -OutputAssembly $fake -OutputType ConsoleApplication}
        if(-not [IO.File]::Exists($fake)){throw 'Could not build the stand-in program.'}
        [void][IO.Directory]::CreateDirectory($stub);[IO.File]::Copy($fake,(Join-Path $stub 'powershell.exe'))
    }else{
        $script=@('#!/bin/sh','if [ -n "$HOTPL8_TEST_NATIVE_LOG" ]; then (IFS="|"; printf ''%s\n'' "$*" >> "$HOTPL8_TEST_NATIVE_LOG"); fi','printf ''%s'' "$HOTPL8_TEST_NATIVE_OUTPUT"; printf ''fixture diagnostic'' >&2; exit "${HOTPL8_TEST_NATIVE_EXIT:-0}"','')
        [IO.File]::WriteAllText($fake,($script -join "`n"))
        [IO.File]::SetUnixFileMode($fake,[IO.UnixFileMode]'UserRead,UserWrite,UserExecute')
    }
    Set-Reader $real;Set-Build $fixtureSha

    Check 'the hand-over calls no command that would load a module first' {
        # Each of these costs a fresh Windows PowerShell 50 to 80 ms on first use.
        $tree=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src/native.ps1'),[ref]$null,[ref]$null)
        $used=@($tree.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_}|Sort-Object -Unique)
        $extra=@($used|Where-Object{$_ -notin @('ForEach-Object','Invoke-Hotpl8NativeProcess','Get-Hotpl8NativePath')})
        Assert (-not $extra.Count) ('src/native.ps1 calls '+($extra -join ', '))
        $text=[IO.File]::ReadAllText((Join-Path $root 'hotpl8.ps1'))
        $handOver=$text.Substring(0,$text.IndexOf(". (Join-Path `$PSScriptRoot 'src/common.ps1')",[StringComparison]::Ordinal))
        $tree=[Management.Automation.Language.Parser]::ParseInput($handOver+'}catch{}',[ref]$null,[ref]$null)
        $used=@($tree.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_}|Sort-Object -Unique)
        Assert (($used -join ',') -ceq 'Exit-Hotpl8Native,Where-Object') ('the hand-over in hotpl8.ps1 calls '+($used -join ', '))
    }
    Check 'the built reader names the commit it was built from' {
        $identity=Invoke-Hotpl8NativeProcess $real @('self-check')
        Assert ($identity.exitCode -eq 0 -and $identity.output -cmatch '\Ahotpl8-native sha=([a-f0-9]{40}|unknown)\n\z') $identity.output
        if($env:GITHUB_ACTIONS -eq 'true'){Assert ($identity.output -cnotmatch 'unknown') 'Continuous integration tests the reader it built from a commit.'}
    }
    Check 'version names a release and its commit, or a checkout' {
        $result=Invoke-Entry @('version')
        Assert ($result.exitCode -eq 0 -and $result.errors -eq '' -and $result.output -ceq ($version+' main '+$fixtureSha.Substring(0,12)+$line)) $result.output
        $result=Invoke-Entry @('version','-AsJson')
        $value=$result.output|ConvertFrom-Json
        Assert ($result.exitCode -eq 0 -and $value.version -ceq $version -and $value.build.sha -ceq $fixtureSha) $result.output
        Assert ((@($value.build.PSObject.Properties.Name) -join ',') -ceq 'protocol,product,repository,sha,channel')
        Set-Build ''
        # The Mac launcher's Codex binding changes nothing.
        $result=Invoke-Entry @('version','-CodexExecutable',$real)
        Assert ($result.exitCode -eq 0 -and $result.errors -eq '' -and $result.output -ceq ($version+$line)) $result.output
        Set-Build $fixtureSha
    }
    Check 'status and explain through the entry are the reader''s answers' {
        foreach($command in 'status','explain'){
            foreach($json in $false,$true){
                $asked=@($command,'--root',$release,'--state',$state);$typed=@($command,'-StateDirectory',$state)
                if($json){$asked+='-AsJson';$typed+='-AsJson'}
                Assert-SameAnswer ($typed -join ' ') {Invoke-Entry $typed} {ConvertTo-EntryOutput (Invoke-Reader $asked).output}
            }
        }
        $asked=@('status','--root',$release,'--state',$state,'--policy',$previewPolicy)
        Assert ((Invoke-Reader @('status','--root',$release,'--state',$state)).output.Contains('monitor only') -and -not (Invoke-Reader $asked).output.Contains('monitor only')) 'the preview policy does not show'
        Assert-SameAnswer 'a preview policy' {Invoke-Entry @('status','-PreviewPolicy',$previewPolicy,'-StateDirectory',$state,'-CodexExecutable',$real)} {ConvertTo-EntryOutput (Invoke-Reader $asked).output}
        # A parameter the three do not read takes the long way round to the same answer.
        Assert-SameAnswer 'status -NoColor' {Invoke-Entry @('status','-NoColor','-StateDirectory',$state)} {ConvertTo-EntryOutput (Invoke-Reader @('status','--root',$release,'--state',$state)).output}
        Assert-SameAnswer 'explain -ReducedMotion -AsJson' {Invoke-Entry @('explain','-ReducedMotion','-StateDirectory',$state,'-AsJson')} {ConvertTo-EntryOutput (Invoke-Reader @('explain','--root',$release,'--state',$state,'-AsJson')).output}
    }
    Check 'text arrives one line at a time and JSON as one value' {
        $lines=(Invoke-Reader @('explain','--root',$release,'--state',$state)).output.Split("`n").Count-1
        $call="& '"+$entry.Replace("'","''")+"' explain -StateDirectory '"+$state.Replace("'","''")+"'"
        $result=Invoke-Hotpl8NativeProcess $shell @('-NoProfile','-ExecutionPolicy','Bypass','-Command',('$all=@('+$call+');$all.Count;@($all|Where-Object{$_ -match "[\r\n]"}).Count'))
        Assert ($lines -gt 5 -and $result.output -ceq (@([string]$lines,'0','') -join $line)) $result.output
        $result=Invoke-Hotpl8NativeProcess $shell @('-NoProfile','-ExecutionPolicy','Bypass','-Command',('$all=@('+$call+' -AsJson);$all.Count;$all[0].GetType().Name;($all[0]|ConvertFrom-Json).generatedAt.Length -gt 0'))
        Assert ($result.output -ceq (@('1','String','True','') -join $line)) $result.output
    }
    Check 'a refusal is said in the reader''s words and ends with 1' {
        foreach($arguments in @(@('status'),@('explain','-AsJson'),@('status','-NoColor'))){
            $result=Invoke-Entry ($arguments+@('-StateDirectory',$emptyState))
            Assert ($result.exitCode -eq 1 -and $result.output -eq '' -and $result.errors -ceq $noPolicy) (($arguments -join ' ')+': '+$result.exitCode+' '+$result.output+$result.errors)
        }
        # A parameter that belongs to another command is the entry's to refuse, as for any command.
        $result=Invoke-Entry @('status','-StateDirectory',$state,'-TrustRevision','x')
        Assert ($result.exitCode -eq 1 -and $result.output -eq '' -and $result.errors -like 'HotPl8: Live and TrustRevision are preview-only.*') $result.errors
        $result=Invoke-Entry @('version','-PreviewPolicy',$previewPolicy)
        Assert ($result.exitCode -eq 1 -and $result.output -eq '' -and $result.errors -like 'HotPl8: PreviewPolicy is display-only.*') $result.errors
    }
    Check 'the words a user types are answered without PowerShell' {
        $result=Invoke-Reader @('user','version')
        Assert ($result.exitCode -eq 0 -and $result.errors -eq '' -and $result.output -ceq ($version+' main '+$fixtureSha.Substring(0,12)+$line)) $result.output
        Assert-SameAnswer 'user explain' {Invoke-Reader @('user','Explain','-statedirectory',$state)} {ConvertTo-EntryOutput (Invoke-Reader @('explain','--root',$release,'--state',$state)).output}
        Assert-SameAnswer 'user status -AsJson' {Invoke-Reader @('user','status','-AsJson','-StateDirectory',$state,'-PreviewPolicy',$previewPolicy,'-CodexExecutable',$real)} {ConvertTo-EntryOutput (Invoke-Reader @('status','--root',$release,'--state',$state,'--policy',$previewPolicy,'-AsJson')).output}
        $result=Invoke-Reader @('user','status','-StateDirectory',$emptyState)
        Assert ($result.exitCode -eq 1 -and $result.output -eq '' -and $result.errors -ceq $noPolicy) $result.errors
    }
    Check 'every other request is left to PowerShell with 64 and nothing printed' {
        foreach($words in @(@(),@('watch'),@('refresh'),@('nyan','-StateDirectory',$state),@('status','-NoColor'),@('status','-Slot','main'),@('version','-StateDirectory',$state),@('status','--now','2026-09-12T12:00:00Z'))){
            $result=Invoke-Reader (@('user')+$words)
            Assert ($result.exitCode -eq 64 -and $result.output -eq '' -and $result.errors -eq '') (($words -join ' ')+': '+$result.exitCode+' '+$result.output+$result.errors)
        }
        # A reader that is not inside a release has nothing to answer about.
        $alone=Join-Path $lab ('alone/'+$relative)
        [void][IO.Directory]::CreateDirectory((Split-Path $alone -Parent));[IO.File]::Copy($real,$alone)
        if(-not $windows){[IO.File]::SetUnixFileMode($alone,[IO.UnixFileMode]'UserRead,UserWrite,UserExecute')}
        $result=Invoke-Hotpl8NativeProcess $alone @('user','version')
        Assert ($result.exitCode -eq 64 -and $result.output -eq '' -and $result.errors -eq '') ([string]$result.exitCode+' '+$result.output)
    }
    Check 'a start that is not a request is refused, not guessed at' {
        $result=Invoke-Reader @()
        Assert ($result.exitCode -eq 1 -and $result.output -eq '' -and $result.errors -ceq "HotPl8: The reader was started without a request.`n") $result.errors
        foreach($words in @(@('refresh','--root',$release),@('status'),@('status','--root',$release,'-NoColor'),@('version','--root',$release,'--state',$state),@('status','--root',$release,'--dump'))){
            $result=Invoke-Reader $words
            Assert ($result.exitCode -eq 1 -and $result.output -eq '' -and $result.errors -clike 'HotPl8: The reader was started with words it does not take: *') (($words -join ' ')+': '+$result.exitCode+' '+$result.output+$result.errors)
        }
    }
    Check 'a copy without a reader it can start says so and answers nothing' {
        Set-Reader ''
        foreach($arguments in @(@('version'),@('status','-StateDirectory',$state),@('explain','-AsJson','-StateDirectory',$state),@('status','-NoColor','-StateDirectory',$state))){
            $result=Invoke-Entry $arguments
            Assert ($result.exitCode -eq 1 -and $result.output -eq '' -and $result.errors -ceq $noReader) (($arguments -join ' ')+': '+$result.exitCode+' '+$result.output+$result.errors)
        }
        # Nothing else asks for it.
        $result=Invoke-Entry @('help')
        Assert ($result.exitCode -eq 0 -and $result.errors -eq '' -and $result.output -match 'refresh: collect quotas') $result.errors
        # A file that is not a program fails to start.
        $corrupt=Join-Path $lab 'corrupt'
        [IO.File]::WriteAllBytes($corrupt,[byte[]](1..64))
        Set-Reader $corrupt
        $result=Invoke-Entry @('version')
        Assert ($result.exitCode -eq 1 -and $result.output -eq '' -and $result.errors -ceq $noReader) $result.errors
        if(-not $windows){
            Set-Reader $real
            [IO.File]::SetUnixFileMode($reader,[IO.UnixFileMode]'UserRead,UserWrite')
            $result=Invoke-Entry @('version')
            Assert ($result.exitCode -eq 1 -and $result.output -eq '' -and $result.errors -ceq $noReader) $result.errors
        }
        Set-Reader $real
    }
    Check 'the live preview asks a candidate''s reader for the dashboard, and shows PowerShell''s when it has none' {
        # delivery/live-preview.ps1 runs from the installed release against a candidate's source.
        $demo=Join-Path $lab 'preview state';[void][IO.Directory]::CreateDirectory($demo)
        $url='https://github.com/example/hotpl8/pull/1'
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'delivery/live-preview.ps1'),'-SourceDirectory',$release,'-StateDirectory',$demo,'-PrUrl',$url,'-Revision',$fixtureSha)
        $asked='user|nyan|-StateDirectory|'+$demo
        Use-Fake
        $result=Invoke-Hotpl8Process $shell $arguments 60000
        Assert ($result.exitCode -eq 0 -and $result.output.Contains('native-sentinel') -and -not $result.output.Contains('Demo Everyday') -and $result.output.Contains('Preview ended: '+$url)) $result.output
        Assert (((Get-Calls) -join ';') -ceq $asked) ((Get-Calls) -join ';')
        Assert ((@([IO.Directory]::GetFiles($demo)|ForEach-Object{[IO.Path]::GetFileName($_)}|Sort-Object) -join ',') -ceq 'policy.json,status.json')
        # A compiled dashboard that fails is shown failing; the other one does not cover for it.
        Use-Fake @{HOTPL8_TEST_NATIVE_OUTPUT='';HOTPL8_TEST_NATIVE_EXIT='3'}
        $result=Invoke-Hotpl8Process $shell $arguments 60000
        Assert ($result.exitCode -eq 3 -and -not $result.output.Contains('Demo Everyday') -and $result.output.Contains('Preview ended: '+$url)) $result.output
        # This build's reader has no dashboard, and a candidate may ship no reader at all.
        foreach($name in $names){[Environment]::SetEnvironmentVariable($name,'')}
        foreach($candidate in $real,''){
            Set-Reader $candidate
            $result=Invoke-Hotpl8Process $shell $arguments 60000
            Assert ($result.exitCode -eq 0 -and $result.output.Contains('Demo Everyday') -and $result.output.Contains('Preview ended: '+$url)) $result.output
        }
        Set-Reader $real
    }
    Check 'a launcher that sessions are started from keeps the text it shipped with' {
        # cmd comes back to a command file by position after every line, so text that is
        # installed where sessions run from is never changed. A launcher that has to change
        # ships under a new name, and the one-line hand-off names it: docs/install.md, "The
        # launcher". A new digest here is that mistake, not an update to make.
        $pins=@{'hotpl8.cmd'='79F68986A2102B54F45ABE0B1B222FA0B18C007B642BB50C4AB00060A9A1A20D';'hotpl8-launch.cmd'='43F0883120321A3486CD6679BADFDEAD9863028FA7665B046D2A5D2F8D476013';'delivery/launch.cmd'='AF6CA4572B7E09C3889F262C2E9503850439138CCCD4FCB0C937ADBB01F4E356';'delivery/hotpl8.cmd'='9D66AA8EC9DA41F7B41C0180ADBE5FDCF5DE73ED2DA02566D8E66F5655C080A9'}
        foreach($name in $pins.Keys){Assert ((Get-FileHash -LiteralPath (Join-Path $root $name) -Algorithm SHA256).Hash -eq $pins[$name]) ($name+' is not the text that shipped')}
        # A hand-off is shorter than the place cmd comes back to in the launchers installed before it.
        foreach($name in 'hotpl8.cmd','delivery/hotpl8.cmd'){Assert ([IO.File]::ReadAllBytes((Join-Path $root $name)).Length -lt 80) ($name+' is too long')}
        Assert ($shim.Length -lt 80 -and [IO.File]::ReadAllText((Join-Path $root 'install.ps1')).Contains("`$shim='"+$shim.TrimEnd()+"'+[Environment]::NewLine")) 'install.ps1 writes another hand-off'
    }
    if($windows){
        Check 'a session started from a launcher of before ends once, as it would have' {
            # The three texts sessions were started from before the reader was asked first, each
            # with what is now put in its place while the session is still running.
            $ended="exit /b %errorlevel%`r`n"
            $changes=@(
                @(("@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0hotpl8.ps1`" %*`r`n"+$ended),[IO.File]::ReadAllBytes((Join-Path $root 'hotpl8.cmd')),$true),
                @(("@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0app\hotpl8.ps1`" %*`r`n"+$ended),[Text.Encoding]::ASCII.GetBytes($shim),$true),
                @(("@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0launch.ps1`" -Entry hotpl8 %*`r`n"+$ended),[IO.File]::ReadAllBytes((Join-Path $root 'delivery/hotpl8.cmd')),$true),
                # The mistake the hand-offs are there to prevent: the launcher's own text in that place.
                @(("@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0hotpl8.ps1`" %*`r`n"+$ended),[IO.File]::ReadAllBytes((Join-Path $root 'hotpl8-launch.cmd')),$false))
            $number=0
            foreach($change in $changes){
                $number++;$session=Join-Path $lab ('session'+$number);[void][IO.Directory]::CreateDirectory($session)
                $launcher=Join-Path $session 'hotpl8.cmd';$go=Join-Path $session 'go';$err=Join-Path $session 'err'
                [IO.File]::WriteAllText($launcher,$change[0]);[IO.File]::WriteAllText($log,'')
                $info=[Diagnostics.ProcessStartInfo]::new()
                $info.FileName=$env:ComSpec
                $info.Arguments='/d /s /c ""'+$launcher+'" watch -ReducedMotion < NUL > NUL 2> "'+$err+'""'
                $info.UseShellExecute=$false;$info.CreateNoWindow=$true
                $settings=@{PATH=$stub+';'+$env:PATH;HOTPL8_TEST_NATIVE_LOG=$log;HOTPL8_TEST_NATIVE_OUTPUT='';HOTPL8_TEST_NATIVE_EXIT='7';HOTPL8_TEST_NATIVE_UNTIL=$go}
                foreach($key in $settings.Keys){$info.EnvironmentVariables[$key]=$settings[$key]}
                $process=[Diagnostics.Process]::Start($info)
                try{
                    # The session is running once the stand-in has written down its words.
                    for($wait=0;$wait -lt 2000 -and -not [IO.FileInfo]::new($log).Length;$wait++){Start-Sleep -Milliseconds 10}
                    [IO.File]::WriteAllBytes($launcher,$change[1]);[IO.File]::WriteAllText($go,'')
                    if(-not $process.WaitForExit(60000)){$process.Kill();throw 'the session did not end'}
                    $code=$process.ExitCode
                }finally{$process.Dispose()}
                $calls=@(Get-Calls);$errors=[IO.File]::ReadAllText($err)
                $clean=($code -eq 7 -and $calls.Count -eq 1 -and $calls[0].EndsWith('|watch|-ReducedMotion') -and $errors -ceq 'fixture diagnostic')
                Assert ($clean -eq $change[2]) ('change '+$number+': exit '+$code+', '+$calls.Count+' starts, <'+$errors+'>')
            }
            # rollback.ps1 puts an older release under app and leaves the hand-off beside it:
            # that release's hotpl8.cmd is the first of these texts, and it is what answers.
            $back=Join-Path $lab 'rolled back';[void][IO.Directory]::CreateDirectory((Join-Path $back 'app'))
            [IO.File]::WriteAllText((Join-Path $back 'hotpl8.cmd'),$shim);[IO.File]::WriteAllText((Join-Path $back 'app\hotpl8.cmd'),$changes[0][0])
            Use-Fake @{HOTPL8_TEST_NATIVE_OUTPUT='';HOTPL8_TEST_NATIVE_EXIT='7'}
            $result=Invoke-Typed ('"'+(Join-Path $back 'hotpl8.cmd')+'" status -AsJson') @{PATH=$stub+';'+$env:PATH}
            Assert ($result.exitCode -eq 7 -and ((Get-Calls) -join ';') -ceq ('-NoProfile|-ExecutionPolicy|Bypass|-File|'+(Join-Path $back 'app\hotpl8.ps1')+'|status|-AsJson')) ([string]$result.exitCode+' '+((Get-Calls) -join ';')+' '+$result.errors)
            foreach($name in $names){[Environment]::SetEnvironmentVariable($name,'')}
            Set-Reader $real
        }
        Check 'the launcher prints what PowerShell printed, byte for byte' {
            $launcher='"'+(Join-Path $release 'hotpl8.cmd')+'"';$slow='"'+$desktop+'" -NoProfile -ExecutionPolicy Bypass -File "'+$entry+'"'
            # Windows PowerShell writes a file or a pipe in the console's code page, which holds part of these labels.
            Assert ((Invoke-Reader @('status','--root',$release,'--state',$farState)).output -cmatch '[^\x00-\x7f]') 'the labels are plain'
            foreach($words in @(('status -StateDirectory "'+$farState+'"'),('Explain -statedirectory "'+$farState+'"'),('explain -StateDirectory "'+$farState+'" -AsJson'))){
                $got=Assert-SameStart $words {Invoke-Typed ($launcher+' '+$words)} {Invoke-Typed ($slow+' '+$words)}
                Assert ($got.exitCode -eq 0 -and $got.errors -eq '' -and $got.output.EndsWith("`r`n")) ($words+': '+$got.exitCode+' '+$got.errors)
            }
            $words='status -StateDirectory "'+$emptyState+'"'
            $got=Assert-SameStart $words {Invoke-Typed ($launcher+' '+$words)} {Invoke-Typed ($slow+' '+$words)}
            Assert ($got.exitCode -eq 1 -and $got.output -eq '' -and $got.errors -ceq $noPolicy) ($words+': '+$got.exitCode+' '+$got.errors)
        }
        Check 'the launcher starts PowerShell with the words the reader leaves to it, and only then' {
            $launcher='"'+(Join-Path $release 'hotpl8.cmd')+'"';$started='-NoProfile|-ExecutionPolicy|Bypass|-File|'+$entry
            $path=@{PATH=$stub+';'+$env:PATH}
            Use-Fake @{HOTPL8_TEST_NATIVE_OUTPUT='';HOTPL8_TEST_NATIVE_EXIT='99'};Set-Reader $real
            foreach($words in @('version',('status -StateDirectory "'+$state+'"'),('Explain -asjson -statedirectory "'+$state+'"'))){
                $result=Invoke-Typed ($launcher+' '+$words) $path
                Assert ($result.exitCode -eq 0 -and $result.errors -eq '' -and $result.output.Length -gt 0 -and -not (Get-Calls).Count) ($words+': '+$result.exitCode+' '+$result.errors+((Get-Calls) -join ';'))
            }
            $result=Invoke-Typed ($launcher+' status -StateDirectory "'+$emptyState+'"') $path
            Assert ($result.exitCode -eq 1 -and $result.output -eq '' -and $result.errors -ceq $noPolicy -and -not (Get-Calls).Count) ([string]$result.exitCode+' '+$result.errors)
            # Everything else is PowerShell's, in the same words, and ends as PowerShell ended.
            foreach($pair in @(@('refresh -Slot main','|refresh|-Slot|main'),@(('status -NoColor -StateDirectory "'+$state+'"'),('|status|-NoColor|-StateDirectory|'+$state)),@('',''))){
                [IO.File]::WriteAllText($log,'')
                $result=Invoke-Typed ($launcher+' '+$pair[0]) $path
                Assert ($result.exitCode -eq 99 -and $result.output -eq '' -and ((Get-Calls) -join ';') -ceq ($started+$pair[1])) ($pair[0]+': '+$result.exitCode+' '+((Get-Calls) -join ';'))
            }
            # So is a copy with no reader: the entry says what is missing.
            Set-Reader '';[IO.File]::WriteAllText($log,'')
            $result=Invoke-Typed ($launcher+' version') $path
            Assert ($result.exitCode -eq 99 -and ((Get-Calls) -join ';') -ceq ($started+'|version')) ([string]$result.exitCode+' '+((Get-Calls) -join ';'))
            # A reader ends with 0 for an answer and 1 for a refusal. Any other status, a crash
            # among them, is no answer of its own, and PowerShell is asked.
            foreach($status in 0,1,2,64,255,-1,-1073740791){
                Use-Fake @{HOTPL8_TEST_NATIVE_EXIT=[string]$status}
                $result=Invoke-Typed ($launcher+' refresh') $path
                $asked=if($status -in 0,1){@('user|refresh')}else{@('user|refresh',($started+'|refresh'))}
                Assert ($result.exitCode -eq $status -and $result.output -ceq ("native-sentinel`n"*$asked.Count) -and ((Get-Calls) -join ';') -ceq ($asked -join ';')) ([string]$status+': '+$result.exitCode+' '+((Get-Calls) -join ';'))
            }
            foreach($name in $names){[Environment]::SetEnvironmentVariable($name,'')}
            Set-Reader $real
        }
        Check 'an installation that updates itself answers from the release in force' {
            # As delivery/setup.py lays one out: the launcher, the reader beside it, and releases.
            $managed=Join-Path $lab 'managed';$inForce=Join-Path $managed ('releases\'+$fixtureSha)
            [void][IO.Directory]::CreateDirectory((Join-Path $managed 'releases'))
            Copy-Item -LiteralPath $release -Destination $inForce -Recurse
            foreach($pair in @(@('delivery/hotpl8.cmd','hotpl8.cmd'),@('delivery/launch.cmd','launch.cmd'),@('delivery/launch.ps1','launch.ps1'),@($relative,'hotpl8-native.exe'))){[IO.File]::Copy((Join-Path $release $pair[0]),(Join-Path $managed $pair[1]))}
            Write-Hotpl8Text (Join-Path $managed 'delivery.json') (@{stateDirectory=$state}|ConvertTo-Json) -NoBom
            $point={param($Release) Write-Hotpl8Text (Join-Path $managed 'current.json') ([ordered]@{protocol=1;sha=$fixtureSha;release=$Release}|ConvertTo-Json) -NoBom}
            & $point ('releases/'+$fixtureSha)
            $script=Join-Path $managed 'launch.ps1'
            $launcher='"'+(Join-Path $managed 'hotpl8.cmd')+'"';$slow='"'+$desktop+'" -NoProfile -ExecutionPolicy Bypass -File "'+$script+'" -Entry hotpl8'
            # The state directory is the installation's, whatever the caller's environment names.
            $path=@{PATH=$stub+';'+$env:PATH;HOTPL8_STATE_DIRECTORY=$emptyState}
            Use-Fake @{HOTPL8_TEST_NATIVE_OUTPUT='';HOTPL8_TEST_NATIVE_EXIT='99'};Set-Reader $real
            $result=Invoke-Typed ($launcher+' version') $path
            Assert ($result.exitCode -eq 0 -and $result.errors -eq '' -and $result.output -ceq ($version+' main '+$fixtureSha.Substring(0,12)+$line) -and -not (Get-Calls).Count) ([string]$result.exitCode+' '+$result.output+$result.errors)
            foreach($words in 'status','explain -AsJson'){
                $got=Assert-SameStart $words {Invoke-Typed ($launcher+' '+$words) $path} {Invoke-Typed ($slow+' '+$words)}
                Assert ($got.exitCode -eq 0 -and $got.errors -eq '' -and -not (Get-Calls).Count) ($words+': '+$got.exitCode+' '+$got.errors+((Get-Calls) -join ';'))
            }
            # Everything else goes to launch.ps1 in the same words.
            $result=Invoke-Typed ($launcher+' refresh -Slot main') $path
            Assert ($result.exitCode -eq 99 -and ((Get-Calls) -join ';') -ceq ('-NoProfile|-ExecutionPolicy|Bypass|-File|'+$script+'|-Entry|hotpl8|refresh|-Slot|main')) ([string]$result.exitCode+' '+((Get-Calls) -join ';'))
            foreach($name in $names){[Environment]::SetEnvironmentVariable($name,'')}
            # What is out of the ordinary is launch.ps1's to report, in the words it has for it:
            # an update in progress,
            $update=[IO.File]::Open((Join-Path $managed 'runtime.lock'),'OpenOrCreate','ReadWrite','None')
            try{$result=Invoke-Typed ($launcher+' status')}finally{$update.Dispose()}
            Assert ($result.exitCode -eq 1 -and $result.output -eq '' -and $result.errors.Contains('HotPl8 is updating; retry shortly.')) ([string]$result.exitCode+' '+$result.output+$result.errors)
            # a pointer that names no release,
            & $point 'releases/other'
            $result=Invoke-Typed ($launcher+' status')
            Assert ($result.exitCode -eq 1 -and $result.output -eq '' -and $result.errors.Contains('Invalid installed release pointer.')) ([string]$result.exitCode+' '+$result.output+$result.errors)
            & $point ('releases/'+$fixtureSha)
            # and a release whose reader does not start.
            [IO.File]::Delete((Join-Path $inForce $relative))
            $result=Invoke-Typed ($launcher+' status')
            Assert ($result.exitCode -eq 1 -and $result.output -eq '' -and $result.errors -ceq $noReader) ([string]$result.exitCode+' '+$result.output+$result.errors)
        }
    }
}finally{
    foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$prior[$name])}
    $full=[IO.Path]::GetFullPath($lab)
    if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-native-test-[a-f0-9]{32}$' -and (Test-Path -LiteralPath $full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
'Native: '+$script:passed+' passed, '+$script:failed+' failed.'
if($script:failed){exit 1}
