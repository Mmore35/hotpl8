# What the compiled reader answers for status and explain must be what PowerShell answers.
# The referee is PowerShell itself (tests/parity/referee.ps1), asked in this process at a
# pinned instant; the reader is asked the same question about the same files. A reader that
# declines is not wrong, PowerShell answers then, but a case says when declining is allowed.
#
# The reader follows the number and time rules of the PowerShell that asks, so on Windows
# the suite runs under Windows PowerShell and again under PowerShell 7. Offline; every
# name, label and reading in the cases is fictional.
#
#   -Only NAME   run the cases whose name matches the wildcard, and nothing else
#   -Fuzz N      how many seeded variations to add (0 for none); -Seed chooses which
#   -Deep        at least 1,500 variations
#   -Inner       this is the second pass; do not start another
param([string]$Only,[int]$Fuzz=150,[int]$Seed=1,[switch]$Deep,[switch]$Inner)
$ErrorActionPreference='Stop'
if($Deep){$Fuzz=[Math]::Max($Fuzz,1500)}
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/config.ps1')
. (Join-Path $root 'src/providers/claude.ps1')
. (Join-Path $root 'src/providers/codex.ps1')
. (Join-Path $root 'src/insights.ps1')
. (Join-Path $root 'src/native.ps1')
. (Join-Path $PSScriptRoot 'parity/referee.ps1')
. (Join-Path $PSScriptRoot 'parity/cases.ps1')
. (Join-Path $PSScriptRoot 'parity/fuzz.ps1')
$windows=$env:OS -eq 'Windows_NT'
if(-not $windows -and -not $IsMacOS){throw 'This suite requires Windows or macOS.'}
$relative=if($windows){'bin/windows/hotpl8-native.exe'}else{'bin/macos/hotpl8-native'}
$real=Join-Path $root $relative
if(-not [IO.File]::Exists($real)){throw 'Build the native reader first: scripts/build-native.ps1'}
$shell=(Get-Process -Id $PID).Path
$edition=if($PSVersionTable.PSEdition -eq 'Core'){'core'}else{'desktop'}
$shellVersion=$PSVersionTable.PSVersion
$followed=if($edition -eq 'core'){$shellVersion.Major -gt 7 -or ($shellVersion.Major -eq 7 -and $shellVersion.Minor -ge 5)}else{$shellVersion.Major -eq 5 -and $shellVersion.Minor -eq 1}
$now=[datetimeoffset]::Parse('2026-09-12T12:00:00Z',[Globalization.CultureInfo]::InvariantCulture)
$modes='status','explain','status-json','explain-json'
$lab=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-parity-test-'+[guid]::NewGuid().ToString('N'))
$priorNative=$env:HOTPL8_NATIVE;$priorState=$env:HOTPL8_STATE_DIRECTORY
$script:passed=0;$script:failed=0;$script:labs=0
function Assert($Value,$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check($Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message}}
# A case's files in a directory of their own, with every time written relative to $At.
function New-Lab($Case,[datetimeoffset]$At) {
    $script:labs++
    $directory=Join-Path $lab ([string]$script:labs)
    $state=Join-Path $directory 'state'
    [void][IO.Directory]::CreateDirectory($state)
    $files=@{};foreach($name in $Case.files.Keys){$files[$name]=$Case.files[$name]}
    if(-not $windows -and $Case.ContainsKey('macFiles')){foreach($name in $Case.macFiles.Keys){$files[$name]=$Case.macFiles[$name]}}
    foreach($name in $files.Keys){Write-Hotpl8Text (Join-Path $state $name) (Expand-Hotpl8ParityText $files[$name] $At) -NoBom:([bool]$Case.noBom)}
    $preview=''
    if($Case.ContainsKey('preview')){$preview=Join-Path $directory 'preview-policy.json';Write-Hotpl8Text $preview (Expand-Hotpl8ParityText $Case.preview $At)}
    [pscustomobject]@{state=$state;preview=$preview}
}
function Get-Expectation($Case,[string]$Mode) {
    if(-not $Case.ContainsKey('expect')){return 'answer'}
    if($Case.expect -isnot [Collections.IDictionary]){return [string]$Case.expect}
    if($Case.expect.ContainsKey($Mode)){return [string]$Case.expect[$Mode]}
    if($Case.expect.ContainsKey('default')){return [string]$Case.expect['default']}
    'answer'
}
# The reader's own command line. -Dump asks for the typed form of the -AsJson value, which
# shows a number's type and exact digits where JSON text would not.
function Invoke-Reader([string]$Mode,$Place,[switch]$Dump,[switch]$RealClock) {
    $arguments=@($Mode.Split('-')[0],'--protocol','2','--shell',$edition,'--root',$root,'--state',$Place.state)
    if($Place.preview){$arguments+=@('--policy',$Place.preview)}
    if($Mode.EndsWith('json')){$arguments+='-AsJson';if($Dump){$arguments+='--dump'}}
    if(-not $RealClock){$arguments+=@('--now',$now.ToString('o'))}
    Invoke-Hotpl8NativeProcess $real $arguments 20000
}
function Get-FirstDifference([string]$Expected,[string]$Actual) {
    $left=$Expected.Split("`n");$right=$Actual.Split("`n")
    for($index=0;$index -lt [Math]::Max($left.Count,$right.Count);$index++){
        $a=if($index -lt $left.Count){$left[$index]}else{'<nothing>'}
        $b=if($index -lt $right.Count){$right[$index]}else{'<nothing>'}
        if($a -cne $b){
            if($a.Length -gt 160){$a=$a.Substring(0,160)+'...'};if($b.Length -gt 160){$b=$b.Substring(0,160)+'...'}
            return ('row '+($index+1)+': PowerShell <'+$a+'> reader <'+$b+'>')
        }
    }
    'no difference'
}
# What PowerShell's answer obliges the reader to print, or $null when it must decline.
function Get-ExpectedOutput($Answer) {
    if($Answer.kind -eq 'error'){return $null}
    if($Answer.kind -eq 'value'){return (ConvertTo-Hotpl8ParityDump $Answer.value)}
    $lines=@($Answer.lines|ForEach-Object{[string]$_})
    # A line holding a line feed cannot be told from two lines once it is printed.
    if(@($lines|Where-Object{$_.Contains("`n")}).Count){return $null}
    ($lines -join "`n")+"`n"
}
# 'same', 'declined' or 'refused' (PowerShell fails and the reader declines) when the reader
# did what the case allows; otherwise a sentence saying what is wrong.
function Compare-Answer($Answer,$Result,[string]$Expectation) {
    if(-not $Result){return 'the reader did not start or did not finish'}
    $declined=$Result.exitCode -eq 64 -and $Result.output -eq ''
    if(-not $declined -and $Result.exitCode -ne 0){return ('the reader exited with '+$Result.exitCode)}
    $expected=Get-ExpectedOutput $Answer
    if($null -eq $expected){
        if($declined){return 'refused'}
        if($Answer.kind -eq 'error'){return ('the reader answers where PowerShell fails with: '+$Answer.message)}
        return 'the reader answers text that has a line feed inside a line'
    }
    if($declined){if($Expectation -eq 'answer'){return 'the reader declines an answer it must give'};return 'declined'}
    if($Result.output -cne $expected){return ('the answers differ at '+(Get-FirstDifference $expected $Result.output))}
    if($Expectation -eq 'decline'){return 'the reader answers a case marked as one it does not model; if that is meant, change the case'}
    'same'
}
# A parsed JSON text as one line, with its numbers set aside in the order they appear.
function ConvertTo-PlainTree($Value,[Collections.ArrayList]$Numbers,[switch]$Loose) {
    if($null -eq $Value){return 'null'}
    if($Value -is [string]){return ('s:'+$Value.Length+':'+$Value)}
    if($Value -is [bool]){return ('b:'+$Value)}
    if($Value -is [datetime]){return ('t:'+$Value.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture))}
    if($Value -is [ValueType]){
        # Windows PowerShell reads a fraction as a decimal, and its conversion from decimal to
        # double can land one step away. Reading the decimal's text does not.
        $number=if($Value -is [decimal]){[double]::Parse($Value.ToString([Globalization.CultureInfo]::InvariantCulture),[Globalization.CultureInfo]::InvariantCulture)}else{[double]$Value}
        [void]$Numbers.Add($number)
        return 'n'
    }
    $parts=New-Object Collections.ArrayList
    if($Value -is [Array]){
        foreach($item in $Value){[void]$parts.Add((ConvertTo-PlainTree $item $Numbers -Loose:$Loose))}
        return ('['+($parts -join ',')+']')
    }
    foreach($property in $Value.PSObject.Properties){
        # The one member that records when the answer was computed.
        $inner=if($Loose -and $property.Name -ceq 'computedAt'){'clock'}else{ConvertTo-PlainTree $property.Value $Numbers -Loose:$Loose}
        [void]$parts.Add(($property.Name.Length.ToString()+':'+$property.Name+'='+$inner))
    }
    '{'+($parts -join ',')+'}'
}
# Whether two JSON texts read back as the same value: $null, or what differs. The typed form
# compares a number's type and every digit. This is about the text a caller parses, where
# 6 and 6.0 are one number (Windows PowerShell writes the first, the reader the second), and
# where the same double is written with seventeen digits by one and the shortest by the other.
function Compare-JsonText([string]$Left,[string]$Right,[switch]$Loose) {
    $leftNumbers=New-Object Collections.ArrayList;$rightNumbers=New-Object Collections.ArrayList
    $leftTree=ConvertTo-PlainTree (ConvertFrom-Json -InputObject $Left) $leftNumbers -Loose:$Loose
    $rightTree=ConvertTo-PlainTree (ConvertFrom-Json -InputObject $Right) $rightNumbers -Loose:$Loose
    if($leftTree -cne $rightTree){return 'members or text differ'}
    for($index=0;$index -lt $leftNumbers.Count;$index++){
        $a=$leftNumbers[$index];$b=$rightNumbers[$index]
        if([Math]::Abs($a-$b) -gt 1e-12*[Math]::Max([double]1,[Math]::Max([Math]::Abs($a),[Math]::Abs($b)))){
            return ('number '+($index+1)+' is '+$a.ToString('R',[Globalization.CultureInfo]::InvariantCulture)+' and '+$b.ToString('R',[Globalization.CultureInfo]::InvariantCulture))
        }
    }
}
function Invoke-Entry([string[]]$Arguments,[bool]$Native) {
    try{
        $env:HOTPL8_NATIVE=if($Native){''}else{'0'}
        Invoke-Hotpl8Process $shell (@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'hotpl8.ps1'))+$Arguments) 120000
    }finally{[Environment]::SetEnvironmentVariable('HOTPL8_NATIVE',$priorNative)}
}
# Every mode of every case at the pinned instant. Returns the tally and the failures.
function Test-Cases([object[]]$Cases,[switch]$Layout) {
    $tally=@{same=0;declined=0;refused=0}
    $wrong=New-Object Collections.ArrayList
    foreach($case in $Cases){
        $place=New-Lab $case $now
        foreach($mode in $modes){
            $json=$mode.EndsWith('json')
            $answer=Get-Hotpl8ParityAnswer $mode.Split('-')[0] $place.state $place.preview $json $now
            $verdict=Compare-Answer $answer (Invoke-Reader $mode $place -Dump) (Get-Expectation $case $mode)
            if($tally.ContainsKey($verdict)){$tally[$verdict]++}else{[void]$wrong.Add($case.name+' ['+$mode+']: '+$verdict);continue}
            if(-not $Layout -or $verdict -ne 'same' -or $answer.kind -ne 'value'){continue}
            # The JSON text a caller receives: plain ASCII, ended once, and the same tree as
            # PowerShell's own text for the value when each is read back.
            $printed=Invoke-Reader $mode $place
            $problem=if(-not $printed -or $printed.exitCode -ne 0){'the reader gives the typed form but not the JSON text'}
                elseif($printed.output -cnotmatch '\A[\x20-\x7e\n]*[^\n]\n\z'){'the JSON text is not plain ASCII ended by one line feed'}
                else{
                    $differs=Compare-JsonText $answer.json $printed.output
                    if($differs){'the JSON text reads back as another value than PowerShell''s: '+$differs}
                }
            if($problem){[void]$wrong.Add($case.name+' ['+$mode+']: '+$problem)}
        }
    }
    [pscustomobject]@{tally=$tally;wrong=$wrong.ToArray()}
}
function Get-WrongText([object[]]$Wrong) {
    $shown=@($Wrong|Select-Object -First 12)
    ($shown -join "`n     ")+$(if($Wrong.Count -gt $shown.Count){"`n     and "+($Wrong.Count-$shown.Count)+' more'})
}
$child=$null
try{
    [void][IO.Directory]::CreateDirectory($lab)
    # The state directory comes from each case, never from the machine the suite runs on.
    $env:HOTPL8_STATE_DIRECTORY=''
    $cases=@(Get-Hotpl8ParityCases)
    $chosen=@($cases|Where-Object{-not $Only -or $_.name -like $Only})
    if($windows -and -not $Inner -and -not $Only){
        # Windows PowerShell and PowerShell 7 count and tell time differently, and the reader
        # follows whichever asks. The second pass runs beside this one.
        $pwsh=if($env:HOTPL8_TEST_PWSH){$env:HOTPL8_TEST_PWSH}else{(Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1).Source}
        if($pwsh -and $edition -eq 'desktop'){
            $info=New-Object Diagnostics.ProcessStartInfo
            $info.FileName=$pwsh
            $info.Arguments=(@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Inner','-Fuzz',[string]$Fuzz,'-Seed',[string]$Seed|ForEach-Object{ConvertTo-NativeArgument $_}) -join ' ')
            $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
            $process=[Diagnostics.Process]::Start($info)
            $child=[pscustomobject]@{process=$process;output=$process.StandardOutput.ReadToEndAsync();errors=$process.StandardError.ReadToEndAsync()}
        }
    }
    if(-not $followed){
        'NOTE the reader does not follow '+$edition+' '+$shellVersion+'; checking only that it is not asked.'
        Check 'a PowerShell the reader does not follow is not handed over' {
            Assert ($null -eq (Get-Hotpl8NativeIdentity $root))
            Assert ($null -eq (Invoke-Hotpl8Native $root @('version','--root',$root)))
        }
    }else{
    Check 'the cases have unique names and the reader is asked as hotpl8.ps1 asks it' {
        Assert (@($cases|ForEach-Object{$_.name}|Sort-Object -Unique).Count -eq $cases.Count) 'two parity cases share a name'
        Assert ($chosen.Count -gt 0) ('no parity case is named like '+$Only)
        $identity=Get-Hotpl8NativeIdentity $root
        if([IO.File]::Exists((Join-Path $root 'build-info.json'))){$identity=@($identity|Select-Object -First 4)}
        Assert (($identity -join ' ') -ceq ('--protocol 2 --shell '+$edition)) ('this suite asks as "--protocol 2 --shell '+$edition+'", hotpl8.ps1 as "'+($identity -join ' ')+'"')
    }
    Check 'a wrong answer is noticed' {
        # The reader is shown other readings than PowerShell: a comparison that cannot fail proves nothing.
        $plain=@($cases|Where-Object{$_.name -ceq 'plain'})[0]
        $other=@{name='plain, edited';files=@{}}
        foreach($name in $plain.files.Keys){$other.files[$name]=$plain.files[$name]}
        $other.files['status.json']=Edit-Hotpl8ParityText $other.files['status.json'] '"used5h":38' '"used5h":39'
        $place=New-Lab $plain $now;$edited=New-Lab $other $now
        foreach($mode in $modes){
            $answer=Get-Hotpl8ParityAnswer $mode.Split('-')[0] $place.state $place.preview $mode.EndsWith('json') $now
            Assert ((Compare-Answer $answer (Invoke-Reader $mode $place -Dump) 'answer') -ceq 'same') ($mode+': the unedited case must match')
            if($mode -ne 'explain'){Assert ((Compare-Answer $answer (Invoke-Reader $mode $edited -Dump) 'answer') -like 'the answers differ at row *') ($mode+': an edited reading went unnoticed')}
            Assert ((Compare-Answer $answer ([pscustomobject]@{exitCode=64;output=''}) 'answer') -ceq 'the reader declines an answer it must give')
            Assert ((Compare-Answer $answer ([pscustomobject]@{exitCode=64;output=''}) 'either') -ceq 'declined')
            Assert ((Compare-Answer $answer (Invoke-Reader $mode $place -Dump) 'decline') -like 'the reader answers a case marked*')
            Assert ((Compare-Answer @{kind='error';message='failed'} (Invoke-Reader $mode $place -Dump) 'either') -like 'the reader answers where PowerShell fails*')
            Assert ((Compare-Answer $answer ([pscustomobject]@{exitCode=1;output=''}) 'either') -ceq 'the reader exited with 1')
        }
        $text='{"a":[6,"6",null,{"b":true}],"c":7.7999999999999989}'
        foreach($same in $text,'{ "a": [6.0, "6", null, {"b": true}], "c": 7.799999999999999 }'){
            Assert ($null -eq (Compare-JsonText $text $same)) $same
        }
        foreach($changed in '{"a":[6,6,null,{"b":true}],"c":7.7999999999999989}','{"a":[6.5,"6",null,{"b":true}],"c":7.7999999999999989}','{"a":[6,"6",null,{"B":true}],"c":7.7999999999999989}','{"a":[6,"6",{"b":true},null],"c":7.7999999999999989}','{"a":[6,"6",null,{"b":true}],"c":7.7999999999999989,"d":null}','{"a":[6,"6",null,{"b":true}],"c":7.79999999999}','{"a":[6,"6",null,{"b":true}],"c":"7.7999999999999989"}'){
            Assert (Compare-JsonText $text $changed) $changed
        }
        Assert ($null -eq (Compare-JsonText '{"a":4294967296}' '{"a":4294967296.0}'))
        Assert (Compare-JsonText '{"a":4294967296}' '{"a":4294967297}')
    }
    $script:curated=$null
    Check ('PowerShell and the reader agree on '+$chosen.Count+' cases in four forms') {
        $script:curated=Test-Cases $chosen -Layout
        $tally=$script:curated.tally
        Assert ($script:curated.wrong.Count -eq 0) (''+$script:curated.wrong.Count+" of "+($chosen.Count*$modes.Count)+" comparisons:`n     "+(Get-WrongText $script:curated.wrong))
        Assert (($tally.same+$tally.declined+$tally.refused) -eq ($chosen.Count*$modes.Count))
    }
    if($script:curated){'     '+$script:curated.tally.same+' the same, '+$script:curated.tally.declined+' left to PowerShell, '+$script:curated.tally.refused+' failing in PowerShell and declined'}
    if(-not $Only){
    Check 'the entry script prints the same either way, read against the real clock' {
        # hotpl8.ps1 reads the clock itself, so each attempt writes files around the present
        # instant and asks three times within seconds. An answer that crosses a minute between
        # the asks differs honestly; a real difference differs on every attempt.
        foreach($name in 'plain','operations','manual pause','one agent lease','preview policy','policy only'){
            $case=@($cases|Where-Object{$_.name -ceq $name})[0]
            Assert $case ('no parity case is named '+$name)
            foreach($mode in $modes){
                $arguments=@($mode.Split('-')[0])
                if($mode.EndsWith('json')){$arguments+='-AsJson'}
                $problem=$null
                for($attempt=1;$attempt -le 3;$attempt++){
                    $place=New-Lab $case ([datetimeoffset]::UtcNow)
                    $all=$arguments+@('-StateDirectory',$place.state)
                    if($place.preview){$all+=@('-PreviewPolicy',$place.preview)}
                    $direct=Invoke-Reader $mode $place -RealClock
                    $fast=Invoke-Entry $all $true
                    $slow=Invoke-Entry $all $false
                    $problem=if(-not $direct -or $direct.exitCode -ne 0){'the reader does not answer'}
                        elseif($fast.exitCode -ne 0 -or $slow.exitCode -ne 0){'the entry script failed: '+$fast.exitCode+' with the reader, '+$slow.exitCode+' without'}
                        elseif($mode.EndsWith('json') -and $slow.output.StartsWith('{',[StringComparison]::Ordinal)){
                            $differs=Compare-JsonText $slow.output $fast.output -Loose
                            if($differs){'the JSON reads back differently with the reader than without: '+$differs}
                            elseif(Compare-JsonText $direct.output $fast.output -Loose){'the entry script printed something else than the reader'}
                        }
                        elseif($fast.output -cne $slow.output){'the text differs at '+(Get-FirstDifference $slow.output.Replace("`r",'') $fast.output.Replace("`r",''))}
                        elseif($fast.output.Replace("`r",'') -cne $direct.output){'the entry script printed something else than the reader'}
                    if(-not $problem){break}
                }
                Assert (-not $problem) ($name+' ['+$mode+'], three attempts: '+$problem)
            }
        }
    }
    if($Fuzz -gt 0){
        $script:fuzzed=$null
        Check ('PowerShell and the reader agree on '+$Fuzz+' seeded variations (seed '+$Seed+')') {
            $script:fuzzed=Test-Cases (Get-Hotpl8ParityFuzzCases $cases $Fuzz $Seed -Mac:(-not $windows))
            $tally=$script:fuzzed.tally
            Assert ($script:fuzzed.wrong.Count -eq 0) (''+$script:fuzzed.wrong.Count+" comparisons:`n     "+(Get-WrongText $script:fuzzed.wrong))
            # A reader that declined everything would agree with everything.
            $answerable=$tally.same+$tally.declined
            Assert ($answerable -ge $Fuzz -and $tally.same -ge 0.6*$answerable) ('the reader answered only '+$tally.same+' of the '+$answerable+' variations PowerShell answers')
        }
        if($script:fuzzed){'     '+$script:fuzzed.tally.same+' the same, '+$script:fuzzed.tally.declined+' left to PowerShell, '+$script:fuzzed.tally.refused+' failing in PowerShell and declined'}
    }
    }
    }
    if($windows -and -not $Inner -and -not $Only -and $edition -eq 'desktop'){
        Check 'the same holds under PowerShell 7' {
            Assert $child 'PowerShell 7 was not found. Install it, or name its pwsh in HOTPL8_TEST_PWSH.'
            if(-not $child.process.WaitForExit(1800000)){try{$child.process.Kill()}catch{$null=$_};throw 'the PowerShell 7 pass did not finish in thirty minutes'}
            $child.process.WaitForExit()
            $text=$child.output.Result
            $text.TrimEnd().Split("`n")|ForEach-Object{'  | '+$_.TrimEnd()}|Out-Host
            Assert ($child.process.ExitCode -eq 0 -and $text -cmatch '(?m)^Native parity \(core [0-9.]+\): [1-9][0-9]* passed, 0 failed\.') ('the PowerShell 7 pass failed'+$(if($child.errors.Result){': '+$child.errors.Result.Trim()}))
            Assert ($text -cmatch '(?m)^PASS PowerShell and the reader agree on ') 'the reader does not follow that PowerShell 7; the second pass needs 7.5 or later'
        }
    }
}finally{
    if($child){try{if(-not $child.process.HasExited){$child.process.Kill()}}catch{$null=$_};$child.process.Dispose()}
    [Environment]::SetEnvironmentVariable('HOTPL8_NATIVE',$priorNative)
    [Environment]::SetEnvironmentVariable('HOTPL8_STATE_DIRECTORY',$priorState)
    $full=[IO.Path]::GetFullPath($lab)
    if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-parity-test-[a-f0-9]{32}$' -and (Test-Path -LiteralPath $full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
'Native parity ('+$edition+' '+$shellVersion.Major+'.'+$shellVersion.Minor+'): '+$script:passed+' passed, '+$script:failed+' failed.'
if($script:failed){exit 1}
