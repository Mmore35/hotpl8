# `hotpl8 status`, `hotpl8 explain`, the dashboard and what the tray shows are the compiled
# reader's, but the rules behind them are still computed twice: by the reader for those, and
# by PowerShell for the agent interface and account management. This suite holds the two to
# each other and pins what the reader prints.
#
#   data     What PowerShell's rules compute from a set of files (tests/parity/referee.ps1) is
#            what the reader computes, value for value and type for type. Where PowerShell
#            refuses the files the reader refuses them, in the same words when the words are
#            HotPl8's own.
#   text     PowerShell has no status text, no explanation, no dashboard and no tray view.
#            What the reader prints for each case is compared with expected-status.txt,
#            expected-explain.txt, expected-tray.txt and expected-watch.txt in tests/parity.
#            The last is the dashboard as `hotpl8 watch` gives it to a pipe: one frame, 100
#            columns wide and as tall as it needs. After a change that is meant, run this
#            suite with -Update and review the difference like any other change.
#
# Starting a program costs more than any answer, so the reader answers all the questions of a
# check in one start (its batch command), and PowerShell reads each case's files once.
#
# The reader computes as the PowerShell that collects on its platform does: Windows
# PowerShell 5.1 on Windows, PowerShell 7 elsewhere. The data is compared under the rules of
# the PowerShell this suite runs in, so scripts/test.ps1 covers the first and the Mac suite
# the second; run it in the other PowerShell to compare those rules on this machine. The
# expected text holds both. Offline; every name, label and reading in the cases is fictional.
#
#   -Only NAME   run the cases whose name matches the wildcard, and nothing else. A variation
#                is named by its seed and number: -Only 'fuzz 7-203*' makes that one again
#   -Fuzz N      how many seeded variations to add (0 for none); -Seed chooses which
#   -Deep        at least 1,500 variations
#   -Update      write what the reader prints now to the expected text, then check as usual
param([string]$Only,[int]$Fuzz=150,[int]$Seed=1,[switch]$Deep,[switch]$Update)
$ErrorActionPreference='Stop'
if($Deep){$Fuzz=[Math]::Max($Fuzz,1500)}
if($Update -and $Only){throw 'The expected text is written for every case; leave out -Only.'}
$variation=$Only -match '^fuzz (\d+)-(\d+)'
if($variation){$Seed=[int]$Matches[1];$Fuzz=[int]$Matches[2]}
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
$real=Get-Hotpl8NativePath $root
if(-not [IO.File]::Exists($real)){throw 'Build the native reader first: scripts/build-native.ps1'}
$edition=if($PSVersionTable.PSEdition -eq 'Core'){'core'}else{'desktop'}
$shellVersion=$PSVersionTable.PSVersion
if($edition -eq 'core' -and ($shellVersion.Major -lt 7 -or ($shellVersion.Major -eq 7 -and $shellVersion.Minor -lt 5))){throw 'The reader computes as PowerShell 7.5 or later does. Run this suite in one, or in Windows PowerShell.'}
$now=[datetimeoffset]::Parse('2026-09-12T12:00:00Z',[Globalization.CultureInfo]::InvariantCulture)
$forms='status-json','explain-json'
$commands='status','explain','tray','watch'
$lab=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-parity-test-'+[guid]::NewGuid().ToString('N'))
$priorState=$env:HOTPL8_STATE_DIRECTORY
$script:passed=0;$script:failed=0;$script:labs=0;$script:batches=0
# PowerShell's rules read the provider definitions of the copy they are part of. A case may
# bring definitions of its own; this names the directory that holds them while that case is
# computed, and the product's own function reads it.
$script:definitions=''
$packagedCatalog=${function:Get-Hotpl8ProviderCatalog}
function Get-Hotpl8ProviderCatalog([string]$Directory=$script:definitions) {
    if($Directory){& $packagedCatalog $Directory}else{& $packagedCatalog}
}
function Assert($Value,$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check($Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message}}
# A case's files in a directory of their own, with every time written relative to $At. A case
# with provider definitions gets a copy of the product's data to hold them: the reader is
# asked as the reader of that copy, and PowerShell's rules are pointed at its definitions.
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
    $copy=$root;$definitions=''
    if($Case.ContainsKey('catalog')){
        $copy=Join-Path $directory 'root'
        $definitions=Join-Path $copy 'data/providers'
        [void][IO.Directory]::CreateDirectory($definitions)
        Copy-Item -LiteralPath (Join-Path $root 'data/capacity-profiles.json') -Destination (Join-Path $copy 'data')
        foreach($name in $Case.catalog.Keys){[IO.File]::WriteAllText((Join-Path $definitions $name),$Case.catalog[$name],[Text.UTF8Encoding]::new($false))}
    }
    [pscustomobject]@{state=$state;preview=$preview;root=$copy;definitions=$definitions}
}
# What PowerShell's rules give for a case's files, read from the definitions the case brings.
function Get-Answers($Place) {
    $script:definitions=$Place.definitions
    try{Get-Hotpl8ParityAnswers $Place.state $Place.preview $now}finally{$script:definitions=''}
}
function Get-Expectation($Case,[string]$Form) {
    if(-not $Case.ContainsKey('expect')){return 'answer'}
    if($Case.expect -isnot [Collections.IDictionary]){return [string]$Case.expect}
    if($Case.expect.ContainsKey($Form)){return [string]$Case.expect[$Form]}
    if($Case.expect.ContainsKey('default')){return [string]$Case.expect['default']}
    'answer'
}
# The reader's own command line for a form: status, explain, tray, status-json or explain-json.
# -Dump asks for the typed form of the -AsJson value, which shows a number's type and exact
# digits where JSON text would not. -Shell and -Zone pin what the machine would decide.
function Get-ReaderArguments([string]$Form,$Place,[switch]$Dump,[string]$Shell=$edition,[string]$Zone) {
    $arguments=@($Form.Split('-')[0],'--root',$Place.root,'--state',$Place.state,'--shell',$Shell,'--now',$now.ToString('o'))
    if($Place.preview){$arguments+=@('--policy',$Place.preview)}
    if($Form.EndsWith('json')){$arguments+='-AsJson';if($Dump){$arguments+='--dump'}}
    if($Zone){$arguments+=@('--zone',$Zone)}
    $arguments
}
# Many questions in one start of the reader. For each it writes "<kind> <bytes>" on a line,
# then that many bytes: the output for `answer`, and for a refusal what the user would be
# told (`ruled` in words HotPl8 has always used, `stopped` in the reader's own).
function Invoke-ReaderBatch([object[]]$Requests) {
    $script:batches++
    $file=Join-Path $lab ('questions-'+$script:batches+'.txt')
    $lines=foreach($request in $Requests){
        '['+(@($request|ForEach-Object{
            if($_ -match '[\x00-\x1f]'){throw 'a question for the reader holds a control character'}
            '"'+$_.Replace('\','\\').Replace('"','\"')+'"'
        }) -join ',')+']'
    }
    [IO.File]::WriteAllLines($file,[string[]]@($lines),[Text.UTF8Encoding]::new($false))
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$real;$info.Arguments='batch '+(ConvertTo-NativeArgument $file)
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $bytes=[IO.MemoryStream]::new()
    $process=[Diagnostics.Process]::Start($info)
    try{
        # Bytes, not text: the lengths count bytes, and an answer may hold any character.
        $copy=$process.StandardOutput.BaseStream.CopyToAsync($bytes);$errors=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(600000)){try{$process.Kill()}catch{$null=$_};throw 'the reader did not finish its questions in ten minutes'}
        $process.WaitForExit();$copy.Wait();$null=$errors.Result
        $status=$process.ExitCode
    }finally{$process.Dispose()}
    $buffer=$bytes.ToArray();$utf8=[Text.UTF8Encoding]::new($false);$at=0
    $results=New-Object Collections.ArrayList
    while($at -lt $buffer.Length){
        $end=[Array]::IndexOf($buffer,[byte]10,$at)
        if($end -lt 0){break}
        $head=[Text.Encoding]::ASCII.GetString($buffer,$at,$end-$at).Split(' ')
        $length=[int]$head[1]
        if($end+1+$length -gt $buffer.Length){break}
        [void]$results.Add([pscustomobject]@{kind=$head[0];output=$utf8.GetString($buffer,$end+1,$length)})
        $at=$end+1+$length
    }
    if($status -ne 0 -or $results.Count -ne $Requests.Count){
        # The reader ends each answer before it starts the next, so the one that stopped it is known.
        $stopped=if($results.Count -lt $Requests.Count){'; it stopped at: '+($Requests[$results.Count] -join ' ')}
        throw ('the reader answered '+$results.Count+' of '+$Requests.Count+' questions and exited with '+$status+$stopped)
    }
    ,$results.ToArray()
}
function Get-FirstDifference([string]$Expected,[string]$Actual,[string]$Left='PowerShell',[string]$Right='reader') {
    $a=$Expected.Split("`n");$b=$Actual.Split("`n")
    for($index=0;$index -lt [Math]::Max($a.Count,$b.Count);$index++){
        $one=if($index -lt $a.Count){$a[$index]}else{'<nothing>'}
        $other=if($index -lt $b.Count){$b[$index]}else{'<nothing>'}
        if($one -cne $other){
            if($one.Length -gt 160){$one=$one.Substring(0,160)+'...'};if($other.Length -gt 160){$other=$other.Substring(0,160)+'...'}
            return ('row '+($index+1)+': '+$Left+' <'+$one+'> '+$Right+' <'+$other+'>')
        }
    }
    'no difference'
}
# 'same'; 'refused' when neither answers; 'stricter' when the reader refuses files that
# PowerShell's rules take, which a case has to allow. Anything else says what is wrong.
function Compare-Answer($Answer,$Result,[string]$Expectation) {
    if(-not $Result){return 'the reader gave no answer'}
    if($Result.kind -cnotin 'answer','ruled','stopped'){return ('the reader took the question as '+$Result.kind+': '+$Result.output)}
    $refuses=$Result.kind -cne 'answer'
    if($Answer.kind -eq 'error'){
        if(-not $refuses){return ('the reader answers where PowerShell refuses with: '+$Answer.message)}
        if($Result.kind -ceq 'ruled' -and $Result.output -cne $Answer.message){return ('the reader refuses with <'+$Result.output+'> where PowerShell says <'+$Answer.message+'>')}
        return 'refused'
    }
    if($refuses){
        if($Expectation -eq 'answer'){return ('the reader refuses an answer it must give: '+$Result.output)}
        return 'stricter'
    }
    $expected=if($Answer.kind -eq 'value'){$Answer.dump}else{$Answer.text}
    if($Result.output -cne $expected){return ('the answers differ at '+(Get-FirstDifference $expected $Result.output))}
    if($Expectation -eq 'refuse'){return 'the reader answers a case marked as one it refuses; if that is meant, change the case'}
    'same'
}
# A parsed JSON text as one line, with its numbers set aside in the order they appear.
function ConvertTo-PlainTree($Value,[Collections.ArrayList]$Numbers) {
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
        foreach($item in $Value){[void]$parts.Add((ConvertTo-PlainTree $item $Numbers))}
        return ('['+($parts -join ',')+']')
    }
    foreach($property in $Value.PSObject.Properties){
        [void]$parts.Add(($property.Name.Length.ToString()+':'+$property.Name+'='+(ConvertTo-PlainTree $property.Value $Numbers)))
    }
    '{'+($parts -join ',')+'}'
}
# Whether two JSON texts read back as the same value: $null, or what differs. The typed form
# compares a number's type and every digit. This is about the text a caller parses, where
# 6 and 6.0 are one number (Windows PowerShell writes the first, the reader the second), and
# where the same double is written with seventeen digits by one and the shortest by the other.
function Compare-JsonText([string]$Left,[string]$Right) {
    $leftNumbers=New-Object Collections.ArrayList;$rightNumbers=New-Object Collections.ArrayList
    $leftTree=ConvertTo-PlainTree (ConvertFrom-Json -InputObject $Left) $leftNumbers
    $rightTree=ConvertTo-PlainTree (ConvertFrom-Json -InputObject $Right) $rightNumbers
    if($leftTree -cne $rightTree){return 'members or text differ'}
    for($index=0;$index -lt $leftNumbers.Count;$index++){
        $a=$leftNumbers[$index];$b=$rightNumbers[$index]
        if([Math]::Abs($a-$b) -gt 1e-12*[Math]::Max([double]1,[Math]::Max([Math]::Abs($a),[Math]::Abs($b)))){
            return ('number '+($index+1)+' is '+$a.ToString('R',[Globalization.CultureInfo]::InvariantCulture)+' and '+$b.ToString('R',[Globalization.CultureInfo]::InvariantCulture))
        }
    }
}
# Every form of every case at the pinned instant. Returns the tally and the failures.
function Test-Cases([object[]]$Cases,[switch]$Layout) {
    $tally=@{same=0;stricter=0;refused=0}
    $wrong=New-Object Collections.ArrayList
    # Every question first, so that one start of the reader answers them all.
    $places=New-Object Collections.ArrayList;$questions=New-Object Collections.ArrayList
    foreach($case in $Cases){
        $place=New-Lab $case $now
        [void]$places.Add($place)
        foreach($form in $forms){
            [void]$questions.Add((Get-ReaderArguments $form $place -Dump))
            if($Layout -and $form.EndsWith('json')){[void]$questions.Add((Get-ReaderArguments $form $place))}
        }
    }
    $results=Invoke-ReaderBatch $questions.ToArray()
    $next=0
    for($index=0;$index -lt $Cases.Count;$index++){
        $case=$Cases[$index];$place=$places[$index]
        $answers=Get-Answers $place
        foreach($form in $forms){
            $answer=$answers[$form];$result=$results[$next++]
            $printed=if($Layout -and $form.EndsWith('json')){$results[$next++]}
            $verdict=Compare-Answer $answer $result (Get-Expectation $case $form)
            if($tally.ContainsKey($verdict)){$tally[$verdict]++}else{[void]$wrong.Add($case.name+' ['+$form+']: '+$verdict);continue}
            if(-not $Layout -or $verdict -ne 'same' -or $answer.kind -ne 'value'){continue}
            # The JSON text a caller receives: plain ASCII, ended once, and the same tree as
            # PowerShell's own text for the value when each is read back.
            $problem=if(-not $printed -or $printed.kind -cne 'answer'){'the reader gives the typed form but not the JSON text'}
                elseif($printed.output -cnotmatch '\A[\x20-\x7e\n]*[^\n]\n\z'){'the JSON text is not plain ASCII ended by one line feed'}
                else{
                    $differs=Compare-JsonText $answer.json $printed.output
                    if($differs){'the JSON text reads back as another value than PowerShell''s: '+$differs}
                }
            if($problem){[void]$wrong.Add($case.name+' ['+$form+']: '+$problem)}
        }
    }
    [pscustomobject]@{tally=$tally;wrong=$wrong.ToArray()}
}
function Get-WrongText([object[]]$Wrong) {
    $shown=@($Wrong|Select-Object -First 12)
    ($shown -join "`n     ")+$(if($Wrong.Count -gt $shown.Count){"`n     and "+($Wrong.Count-$shown.Count)+' more'})
}
# What the tray shows, as lines. The reader answers the tray with JSON, in which every line
# of the window is part of one string.
function ConvertTo-TrayText([string]$Json) {
    $model=$Json|ConvertFrom-Json
    $lines=@('title: '+$model.title;'announces: '+$(if($model.notify){'yes'}else{'no'}))
    foreach($alert in @($model.alerts)){if($alert){$lines+='alert: '+$alert.key+' | '+$alert.title+' | '+$alert.text}}
    $lines+='window:'
    $lines+=@(([string]$model.details) -split "`r?`n"|ForEach-Object{('  '+$_).TrimEnd()})
    ($lines -join "`n")+"`n"
}
# What the reader prints for one command on each case, as the text of its expected file:
# a heading per case, then the output or the refusal. The instant and the time zone are
# pinned, and both sets of number rules are asked for, so the text is the same on every
# machine. Where the two sets print differently the case has a section for each.
function Get-PrintedText([object[]]$Cases,[string]$Command) {
    # A case whose files differ on a Mac would need a text of its own there.
    $shown=@($Cases|Where-Object{-not $_.ContainsKey('macFiles')})
    $shells='desktop','core'
    $questions=New-Object Collections.ArrayList
    foreach($case in $shown){
        $place=New-Lab $case $now
        foreach($shell in $shells){[void]$questions.Add((Get-ReaderArguments $Command $place -Shell $shell -Zone '0'))}
    }
    $results=Invoke-ReaderBatch $questions.ToArray()
    $sections=[ordered]@{}
    for($index=0;$index -lt $shown.Count;$index++){
        $texts=foreach($offset in 0,1){
            $result=$results[2*$index+$offset]
            if($result.kind -cnotin 'answer','ruled','stopped'){throw ($shown[$index].name+': the reader took the question as '+$result.kind)}
            # A refusal names the line of the reader's source that made it, which moves with every edit.
            $text=if($result.kind -cne 'answer'){'refused: '+[regex]::Replace($result.output,'\(((?:[a-z_]+/)*[a-z_]+\.rs):\d+\)','($1)')+"`n"}
                elseif($Command -eq 'tray'){ConvertTo-TrayText $result.output}else{$result.output}
            if($text -cmatch '(?m)^== ' -or $text -cnotmatch '\A[^\r]*\n\z'){throw ($shown[$index].name+': the output cannot be kept in the expected text')}
            $text
        }
        if($texts[0] -ceq $texts[1]){$sections[$shown[$index].name]=$texts[0]}
        else{$sections[$shown[$index].name+' [Windows PowerShell numbers]']=$texts[0];$sections[$shown[$index].name+' [PowerShell 7 numbers]']=$texts[1]}
    }
    ,$sections
}
function ConvertTo-ExpectedText($Sections,[string]$Command) {
    $what=if($Command -eq 'tray'){'the tray shows'}elseif($Command -eq 'watch'){'`hotpl8 watch` gives a pipe'}else{'`hotpl8 '+$Command+'` prints'}
    $builder=New-Object Text.StringBuilder
    [void]$builder.Append('# What '+$what+' for each parity case at '+$now.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture)+", read in UTC.`n# Written by tests/test-native-parity.ps1 -Update. Review a change here; do not edit by hand.`n")
    foreach($name in $Sections.Keys){[void]$builder.Append("`n== "+$name+"`n"+$Sections[$name])}
    $builder.ToString()
}
function ConvertFrom-ExpectedText([string]$Text) {
    $sections=[ordered]@{}
    $name=$null;$body=New-Object Text.StringBuilder
    foreach($line in $Text.Replace("`r`n","`n").Split("`n")){
        if($line.StartsWith('== ',[StringComparison]::Ordinal)){
            if($null -ne $name){$sections[$name]=$body.ToString()}
            $name=$line.Substring(3);$body=New-Object Text.StringBuilder
            if($sections.Contains($name)){throw ('the expected text has two sections named '+$name)}
        }elseif($null -ne $name){[void]$body.Append($line+"`n")}
    }
    if($null -ne $name){$sections[$name]=$body.ToString()}
    # Each section is followed by the blank line before the next heading, or by the end of the file.
    foreach($key in @($sections.Keys)){$sections[$key]=$sections[$key].Substring(0,$sections[$key].Length-1)}
    ,$sections
}
# What differs between the expected sections and the ones printed now, as sentences.
function Compare-PrintedText($Expected,$Actual,[switch]$Partial) {
    $wrong=New-Object Collections.ArrayList
    foreach($name in $Actual.Keys){
        if(-not $Expected.Contains($name)){[void]$wrong.Add($name+': not in the expected text')}
        elseif($Expected[$name] -cne $Actual[$name]){[void]$wrong.Add($name+': '+(Get-FirstDifference $Expected[$name] $Actual[$name] 'expected' 'reader'))}
    }
    if(-not $Partial){foreach($name in $Expected.Keys){if(-not $Actual.Contains($name)){[void]$wrong.Add($name+': in the expected text, but no case prints it')}}}
    ,$wrong.ToArray()
}
try{
    [void][IO.Directory]::CreateDirectory($lab)
    # The state directory comes from each case, never from the machine the suite runs on.
    $env:HOTPL8_STATE_DIRECTORY=''
    $cases=@(Get-Hotpl8ParityCases)
    $from=if($variation){Get-Hotpl8ParityFuzzCases $cases $Fuzz $Seed -Mac:(-not $windows)}else{$cases}
    $chosen=@($from|Where-Object{-not $Only -or $_.name -like $Only})
    $plain=@($cases|Where-Object{$_.name -ceq 'plain'})[0]
    Check 'the cases have unique names' {
        Assert (@($cases|ForEach-Object{$_.name}|Sort-Object -Unique).Count -eq $cases.Count) 'two parity cases share a name'
        Assert ($chosen.Count -gt 0) ('no parity case is named like '+$Only)
        Assert $plain 'no parity case is named plain'
    }
    Check 'a wrong answer is noticed' {
        # The reader is shown other readings than PowerShell: a comparison that cannot fail proves nothing.
        $other=@{name='plain, edited';files=@{}}
        foreach($name in $plain.files.Keys){$other.files[$name]=$plain.files[$name]}
        $other.files['status.json']=Edit-Hotpl8ParityText $other.files['status.json'] '"used5h":38' '"used5h":39'
        $place=New-Lab $plain $now;$edited=New-Lab $other $now
        $answers=Get-Answers $place
        $results=Invoke-ReaderBatch @(foreach($form in $forms){,(Get-ReaderArguments $form $place -Dump);,(Get-ReaderArguments $form $edited -Dump)})
        $stopped=[pscustomobject]@{kind='stopped';output='This state cannot be shown.'}
        $failed=@{kind='error';message='failed'}
        for($index=0;$index -lt $forms.Count;$index++){
            $form=$forms[$index];$answer=$answers[$form];$result=$results[2*$index]
            Assert ((Compare-Answer $answer $result 'answer') -ceq 'same') ($form+': the unedited case must match')
            Assert ((Compare-Answer $answer $results[2*$index+1] 'answer') -like 'the answers differ at row *') ($form+': an edited reading went unnoticed')
            Assert ((Compare-Answer $answer $stopped 'answer') -like 'the reader refuses an answer it must give*')
            Assert ((Compare-Answer $answer $stopped 'either') -ceq 'stricter')
            Assert ((Compare-Answer $answer $stopped 'refuse') -ceq 'stricter')
            Assert ((Compare-Answer $answer $result 'refuse') -like 'the reader answers a case marked*')
            Assert ((Compare-Answer $failed $result 'either') -like 'the reader answers where PowerShell refuses*')
            Assert ((Compare-Answer $failed $stopped 'answer') -ceq 'refused')
            Assert ((Compare-Answer $failed ([pscustomobject]@{kind='ruled';output='failed'}) 'answer') -ceq 'refused')
            Assert ((Compare-Answer $failed ([pscustomobject]@{kind='ruled';output='Failed'}) 'either') -like 'the reader refuses with <Failed> where PowerShell says <failed>')
            Assert ((Compare-Answer $answer ([pscustomobject]@{kind='misspelled';output='words'}) 'either') -ceq 'the reader took the question as misspelled: words')
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
        # The expected text: what is written is what is read back, and each kind of difference is seen.
        $sections=[ordered]@{'one'="first line`n`nthird line`n";'two [PowerShell 7 numbers]'="refused: words`n"}
        $read=ConvertFrom-ExpectedText (ConvertTo-ExpectedText $sections 'status').Replace("`n","`r`n")
        Assert (@($read.Keys).Count -eq 2 -and $read['one'] -ceq $sections['one'] -and (Compare-PrintedText $read $sections).Count -eq 0)
        $changed=[ordered]@{'one'="first line`n`nthird line.`n";'three'="new`n"}
        $seen=Compare-PrintedText $read $changed
        Assert ($seen.Count -eq 3 -and $seen[0] -ceq 'one: row 3: expected <third line> reader <third line.>' -and $seen[1] -ceq 'three: not in the expected text' -and $seen[2] -like 'two *: in the expected text, but no case prints it') ($seen -join '; ')
        Assert ((Compare-PrintedText $read ([ordered]@{'one'=$sections['one']}) -Partial).Count -eq 0)
    }
    Check 'one start for many questions changes no answer' {
        $refusing=@{name='refusing';files=@{'policy.json'='{"mode":"sideways"}'}}
        $asked=New-Object Collections.ArrayList
        foreach($case in @($plain,$refusing)+@($cases|Where-Object{$_.name -cin 'operations','preview policy'})){
            $place=New-Lab $case $now
            foreach($form in $forms+$commands){[void]$asked.Add((Get-ReaderArguments $form $place))}
        }
        Assert ($asked.Count -eq 24) 'a case this check relies on is gone'
        $together=Invoke-ReaderBatch $asked.ToArray()
        for($index=0;$index -lt $asked.Count;$index++){
            $alone=Invoke-Hotpl8NativeProcess $real $asked[$index]
            $same=if($together[$index].kind -ceq 'answer'){$alone.exitCode -eq 0 -and $alone.output -ceq $together[$index].output -and $alone.errors -eq ''}
                else{$alone.exitCode -eq 1 -and $alone.output -eq '' -and $alone.errors -ceq ('HotPl8: '+$together[$index].output+"`n")}
            Assert $same (($asked[$index] -join ' ')+': the reader answers differently among other questions than in a start of its own')
        }
        Assert (@($together|Where-Object{$_.kind -ceq 'answer'}).Count -eq 18 -and @($together|Where-Object{$_.kind -ceq 'ruled'}).Count -eq 6)
    }
    $script:curated=$null
    Check ('PowerShell''s rules and the reader''s agree on '+$chosen.Count+' cases') {
        $script:curated=Test-Cases $chosen -Layout
        $tally=$script:curated.tally
        Assert ($script:curated.wrong.Count -eq 0) (''+$script:curated.wrong.Count+" of "+($chosen.Count*$forms.Count)+" comparisons:`n     "+(Get-WrongText $script:curated.wrong))
        Assert (($tally.same+$tally.stricter+$tally.refused) -eq ($chosen.Count*$forms.Count))
    }
    if($script:curated){'     '+$script:curated.tally.same+' the same, '+$script:curated.tally.refused+' refused by both, '+$script:curated.tally.stricter+' refused by the reader alone, as their cases say'}
    # A variation has no section in the expected text.
    foreach($command in @(if(-not $variation){$commands})){
    $script:printed=$null
    Check $(if($command -eq 'tray'){'the tray shows the expected text'}else{$command+' prints the expected text'}) {
        $expected='tests/parity/expected-'+$command+'.txt';$expectedFile=Join-Path $root $expected
        $script:printed=Get-PrintedText $chosen $command
        if($Update){
            [IO.File]::WriteAllText($expectedFile,(ConvertTo-ExpectedText $script:printed $command),[Text.UTF8Encoding]::new($false))
            'WROTE '+$expected|Out-Host
        }
        Assert ([IO.File]::Exists($expectedFile)) ($expected+' is missing; write it with -Update')
        $wrong=Compare-PrintedText (ConvertFrom-ExpectedText ([IO.File]::ReadAllText($expectedFile))) $script:printed -Partial:([bool]$Only)
        Assert ($wrong.Count -eq 0) (''+$wrong.Count+" sections; if the change is meant, run this suite with -Update and review it:`n     "+(Get-WrongText $wrong))
    }
    if($script:printed){'     '+@($script:printed.Keys).Count+' sections'}
    }
    if(-not $Only){
    Check 'reset times follow this machine''s own time zone' {
        # A winter and a summer instant, so a zone with daylight saving shows both of its offsets.
        $instants=@('2027-01-15T12:00:00Z','2027-07-15T12:00:00Z'|ForEach-Object{[datetimeoffset]::Parse($_,[Globalization.CultureInfo]::InvariantCulture)})
        $text=$plain.files['status.json'].Replace('"resetsAt":@u+2h@','"resetsAt":'+$instants[0].ToUnixTimeSeconds()).Replace('"resetsAt":@u+3d@','"resetsAt":'+$instants[1].ToUnixTimeSeconds())
        Assert ($text -cne $plain.files['status.json'])
        $place=New-Lab @{name='reset times';files=@{'policy.json'=$plain.files['policy.json'];'status.json'=$text}} $now
        $result=(Invoke-ReaderBatch @(,(Get-ReaderArguments 'status' $place)))[0]
        Assert ($result.kind -ceq 'answer') $result.output
        foreach($instant in $instants){
            $local='reset '+$instant.ToLocalTime().ToString('MM-dd HH:mm zzz',[Globalization.CultureInfo]::InvariantCulture)+' ('
            Assert $result.output.Contains($local) ('the reader does not print <'+$local+'>')
        }
    }
    if($Fuzz -gt 0){
        $script:fuzzed=$null
        Check ('PowerShell''s rules and the reader''s agree on '+$Fuzz+' seeded variations (seed '+$Seed+')') {
            $script:fuzzed=Test-Cases (Get-Hotpl8ParityFuzzCases $cases $Fuzz $Seed -Mac:(-not $windows))
            $tally=$script:fuzzed.tally
            Assert ($script:fuzzed.wrong.Count -eq 0) (''+$script:fuzzed.wrong.Count+" comparisons:`n     "+(Get-WrongText $script:fuzzed.wrong))
            # A reader that refused everything would agree with everything.
            $answerable=$tally.same+$tally.stricter
            Assert ($answerable -ge $Fuzz -and $tally.same -ge 0.6*$answerable) ('the reader answered only '+$tally.same+' of the '+$answerable+' variations PowerShell answers')
        }
        if($script:fuzzed){'     '+$script:fuzzed.tally.same+' the same, '+$script:fuzzed.tally.refused+' refused by both, '+$script:fuzzed.tally.stricter+' refused by the reader alone'}
    }
    }
}finally{
    [Environment]::SetEnvironmentVariable('HOTPL8_STATE_DIRECTORY',$priorState)
    $full=[IO.Path]::GetFullPath($lab)
    if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-parity-test-[a-f0-9]{32}$' -and (Test-Path -LiteralPath $full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
'Native parity ('+$edition+' '+$shellVersion.Major+'.'+$shellVersion.Minor+'): '+$script:passed+' passed, '+$script:failed+' failed.'
if($script:failed){exit 1}
