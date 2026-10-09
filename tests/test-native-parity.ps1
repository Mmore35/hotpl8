# What the compiled program answers from a set of files: `hotpl8 status`, `hotpl8 explain`,
# the dashboard, what the tray shows, and the values behind them. The program is the one
# place these rules are calculated, so this suite pins what it says for each case.
#
#   text     What the program prints for each case is compared with expected-status.txt,
#            expected-explain.txt, expected-tray.txt and expected-watch.txt in tests/parity.
#            The last is the dashboard as `hotpl8 watch` gives it to a pipe: one frame, 100
#            columns wide and as tall as it needs.
#   values   What `status -AsJson` and `explain -AsJson` hold for each case, value by value
#            and type by type, under Windows PowerShell's numbers and PowerShell 7's: a line
#            of digests to a case in expected-values.txt. They were recorded while PowerShell
#            still calculated the same rules and agreed with every one of them. A digest says
#            that a value changed, not which; -Only NAME -Values prints the values.
#   variations  Seeded changes to the cases (tests/parity/fuzz.ps1). The program answers or
#            refuses each in words of its own, and for the first seed what it says is
#            compared with expected-variations.txt, in the same form.
#
# After a change that is meant, run this suite with -Update and review the difference like
# any other change.
#
# Starting a program costs more than any answer, so the program answers all the questions of
# a check in one start (its batch command).
#
# The program computes as the PowerShell that reads its answers on a platform does: Windows
# PowerShell 5.1 on Windows, PowerShell 7 elsewhere. Both sets of number rules are asked for
# on every machine, and the expected text holds both. Offline; every name, label and reading
# in the cases is fictional.
#
#   -Only NAME   run the cases whose name matches the wildcard, and nothing else. A variation
#                is named by its seed and number: -Only 'fuzz 7-203*' makes that one again
#   -Fuzz N      how many seeded variations to ask (0 for none); -Seed chooses which
#   -Deep        at least 1,500 variations
#   -Values      with -Only, print the typed values the program holds for each case chosen
#   -Update      write what the program says now to the expected text, then check as usual
param([string]$Only,[int]$Fuzz=500,[int]$Seed=1,[switch]$Deep,[switch]$Values,[switch]$Update)
$ErrorActionPreference='Stop'
if($Deep){$Fuzz=[Math]::Max($Fuzz,1500)}
if($Update -and $Only){throw 'The expected text is written for every case; leave out -Only.'}
$variation=$Only -match '^fuzz (\d+)-(\d+)'
if($variation){$Seed=[int]$Matches[1];$Fuzz=[int]$Matches[2]}
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/native.ps1')
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
function Assert($Value,$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check($Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message}}
# A case's files in a directory of their own, with every time written relative to $At. A case
# with provider definitions gets a copy of the product's data to hold them, and the program
# is asked as the program of that copy.
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
    $copy=$root
    if($Case.ContainsKey('catalog')){
        $copy=Join-Path $directory 'root'
        $definitions=Join-Path $copy 'data/providers'
        [void][IO.Directory]::CreateDirectory($definitions)
        Copy-Item -LiteralPath (Join-Path $root 'data/capacity-profiles.json') -Destination (Join-Path $copy 'data')
        foreach($name in $Case.catalog.Keys){[IO.File]::WriteAllText((Join-Path $definitions $name),$Case.catalog[$name],[Text.UTF8Encoding]::new($false))}
    }
    [pscustomobject]@{state=$state;preview=$preview;root=$copy}
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
function Get-FirstDifference([string]$Expected,[string]$Actual,[string]$Left='expected',[string]$Right='reader') {
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
# A refusal names the line of the program's source that made it, which moves with every edit.
function Get-RefusalText([string]$Said) { [regex]::Replace($Said,'\(((?:[a-z_]+/)*[a-z_]+\.rs):\d+\)','($1)') }
# What the program prints for one command on each case, as the text of its expected file: a
# heading per case, then the output or the refusal. The instant and the time zone are pinned,
# and both sets of number rules are asked for, so the text is the same on every machine.
# Where the two sets answer differently the case has a section for each.
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
            $text=if($result.kind -cne 'answer'){'refused: '+(Get-RefusalText $result.output)+"`n"}
                elseif($Command -eq 'tray'){ConvertTo-TrayText $result.output}else{$result.output}
            if($text -cmatch '(?m)^== ' -or $text -cnotmatch '\A[^\r]*\n\z'){throw ($shown[$index].name+': the output cannot be kept in the expected text')}
            $text
        }
        if($texts[0] -ceq $texts[1]){$sections[$shown[$index].name]=$texts[0]}
        else{$sections[$shown[$index].name+' [Windows PowerShell numbers]']=$texts[0];$sections[$shown[$index].name+' [PowerShell 7 numbers]']=$texts[1]}
    }
    ,$sections
}
# What the program holds for each case or variation, as one line: its name, then for each form
# (status -AsJson, explain -AsJson) and each set of number rules whether it answered and a
# digest of its typed values, which show a number's type and every digit where JSON text
# would not, or of its refusal. A case with files of its own on a Mac is marked.
function Get-VariationLines([object[]]$Varied) {
    $questions=New-Object Collections.ArrayList
    foreach($case in $Varied){
        $place=New-Lab $case $now
        foreach($form in $forms){foreach($shell in 'desktop','core'){[void]$questions.Add((Get-ReaderArguments $form $place -Dump -Shell $shell -Zone '0'))}}
    }
    $results=Invoke-ReaderBatch $questions.ToArray()
    $sha=[Security.Cryptography.SHA256]::Create();$utf8=[Text.UTF8Encoding]::new($false)
    try{
        for($index=0;$index -lt $Varied.Count;$index++){
            $said=foreach($offset in 0..3){
                $result=$results[4*$index+$offset]
                if($result.kind -cnotin 'answer','ruled','stopped'){throw ($Varied[$index].name+': the reader took the question as '+$result.kind)}
                $text=if($result.kind -ceq 'answer'){$result.output}else{Get-RefusalText $result.output}
                $result.kind+' '+(-join($sha.ComputeHash($utf8.GetBytes($text))[0..7]|ForEach-Object{$_.ToString('x2')}))
            }
            if($Varied[$index].name.Contains(' | ')){throw ($Varied[$index].name+': a name cannot be kept in a line of digests')}
            [pscustomobject]@{name=$Varied[$index].name;platform=$Varied[$index].ContainsKey('macFiles');line=($Varied[$index].name+' | '+($said -join ' | '))}
        }
    }finally{$sha.Dispose()}
}
# The lines of digests a file holds, and the file written from the lines the program gives now.
function Read-DigestLines([string]$File) {
    Assert ([IO.File]::Exists((Join-Path $root $File))) ($File+' is missing; write it with -Update')
    ,@([IO.File]::ReadAllText((Join-Path $root $File)).Replace("`r`n","`n").Split("`n")|Where-Object{$_ -and -not $_.StartsWith('#')})
}
function Write-DigestLines([string]$File,[string]$Of,[object[]]$Lines) {
    $head='# What the compiled program holds for each '+$Of+": for status -AsJson and explain -AsJson, under`n# Windows PowerShell's numbers and PowerShell 7's, whether it answered and a digest of its typed`n# values or of its refusal.`n# Written by tests/test-native-parity.ps1 -Update. Review a change here; do not edit by hand.`n"
    [IO.File]::WriteAllText((Join-Path $root $File),$head+(($Lines|ForEach-Object{$_.line}) -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
    'WROTE '+$File|Out-Host
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
    $from=if($variation){Get-Hotpl8ParityFuzzCases $cases $Fuzz $Seed}else{$cases}
    $chosen=@($from|Where-Object{-not $Only -or $_.name -like $Only})
    $plain=@($cases|Where-Object{$_.name -ceq 'plain'})[0]
    Check 'the cases have unique names' {
        Assert (@($cases|ForEach-Object{$_.name}|Sort-Object -Unique).Count -eq $cases.Count) 'two parity cases share a name'
        Assert ($chosen.Count -gt 0) ('no parity case is named like '+$Only)
        Assert $plain 'no parity case is named plain'
    }
    Check 'a wrong answer is noticed' {
        # The program is shown other readings: a comparison that cannot fail proves nothing.
        $other=@{name='plain, edited';files=@{}}
        foreach($name in $plain.files.Keys){$other.files[$name]=$plain.files[$name]}
        $other.files['status.json']=Edit-Hotpl8ParityText $other.files['status.json'] '"used5h":38' '"used5h":39'
        foreach($form in $commands){
            $said=Get-PrintedText @($plain,$other) $form
            $first=[ordered]@{};$second=[ordered]@{}
            foreach($name in $said.Keys){if($name.StartsWith('plain, edited')){$second[$name.Replace('plain, edited','plain')]=$said[$name]}else{$first[$name]=$said[$name]}}
            Assert (@($first.Keys).Count -gt 0 -and (Compare-PrintedText $first $first).Count -eq 0) ($form+': the unedited case must match itself')
            $seen=@(Compare-PrintedText $first $second)
            Assert ($seen.Count -gt 0 -and $seen[0] -like 'plain*: row *: expected <*> reader <*>') ($form+': an edited reading went unnoticed')
        }
        $lines=@(Get-VariationLines @($plain,$other))
        Assert ($lines.Count -eq 2 -and $lines[0].line -cmatch '^plain( \| answer [0-9a-f]{16}){4}$') $lines[0].line
        Assert ($lines[0].line.Substring(5) -cne $lines[1].line.Substring(13)) 'an edited reading has the digests of the unedited one'
        Assert ($lines[0].line -cnotmatch 'e3b0c44298fc1c14') 'a digest is of nothing'
        # The expected text: what is written is what is read back, and each kind of difference is seen.
        $sections=[ordered]@{'one'="first line`n`nthird line`n";'two [PowerShell 7 numbers]'="refused: words`n"}
        $read=ConvertFrom-ExpectedText (ConvertTo-ExpectedText $sections 'status').Replace("`n","`r`n")
        Assert (@($read.Keys).Count -eq 2 -and $read['one'] -ceq $sections['one'] -and (Compare-PrintedText $read $sections).Count -eq 0)
        $changed=[ordered]@{'one'="first line`n`nthird line.`n";'three'="new`n"}
        $seen=Compare-PrintedText $read $changed
        Assert ($seen.Count -eq 3 -and $seen[0] -ceq 'one: row 3: expected <third line> reader <third line.>' -and $seen[1] -ceq 'three: not in the expected text' -and $seen[2] -like 'two *: in the expected text, but no case prints it')
        Assert ((Compare-PrintedText $read ([ordered]@{'one'=$sections['one']}) -Partial).Count -eq 0)
        Assert ((Get-RefusalText 'One of its values is not one HotPl8 writes (src/contract.rs:16).') -ceq 'One of its values is not one HotPl8 writes (src/contract.rs).')
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
    Check 'each JSON answer is plain text a caller can read, and a case that must be refused is' {
        $asked=New-Object Collections.ArrayList
        foreach($case in $chosen){
            $place=New-Lab $case $now
            foreach($form in $forms){[void]$asked.Add((Get-ReaderArguments $form $place))}
        }
        $results=Invoke-ReaderBatch $asked.ToArray()
        $wrong=New-Object Collections.ArrayList;$answered=0
        for($index=0;$index -lt $results.Count;$index++){
            $case=$chosen[[Math]::Floor($index/$forms.Count)];$result=$results[$index];$which=$case.name+' ['+$forms[$index%$forms.Count]+']'
            if($result.kind -cnotin 'answer','ruled','stopped'){[void]$wrong.Add($which+': the reader took the question as '+$result.kind);continue}
            if($case.ContainsKey('expect') -and $case.expect -eq 'refuse' -and $result.kind -ceq 'answer'){[void]$wrong.Add($which+': the reader answers a case marked as one it refuses; if that is meant, change the case')}
            if($result.kind -cne 'answer'){continue}
            $answered++
            # A state with no snapshot has no values, and the command says so.
            if($result.output -ceq "No cached status. Run hotpl8 refresh.`n"){continue}
            if($result.output -cnotmatch '\A[\x20-\x7e\n]*[^\n]\n\z'){[void]$wrong.Add($which+': the JSON text is not plain ASCII ended by one line feed');continue}
            try{$null=ConvertFrom-Json -InputObject $result.output}catch{[void]$wrong.Add($which+': the JSON text cannot be read back')}
        }
        Assert ($wrong.Count -eq 0) (''+$wrong.Count+" answers:`n     "+(Get-WrongText $wrong.ToArray()))
        # A reader that refused everything would pass every line above.
        Assert ($Only -or $answered -ge 0.6*$results.Count) ('the reader answered only '+$answered+' of '+$results.Count)
    }
    if($Values){
        foreach($case in $chosen){
            $place=New-Lab $case $now
            $asked=@(foreach($form in $forms){foreach($shell in 'desktop','core'){,(Get-ReaderArguments $form $place -Dump -Shell $shell -Zone '0')}})
            $results=Invoke-ReaderBatch $asked
            for($index=0;$index -lt 4;$index++){'== '+$case.name+' ['+$forms[[Math]::Floor($index/2)]+', '+('Windows PowerShell','PowerShell 7')[$index%2]+' numbers] '+$results[$index].kind;$results[$index].output.TrimEnd("`n")}
        }
    }
    # A variation is recorded by its number, not here.
    if($variation){Get-VariationLines $chosen|ForEach-Object{'     '+$_.line}}
    else{
    $script:held=$null
    Check 'status -AsJson and explain -AsJson hold the expected values' {
        $expected='tests/parity/expected-values.txt'
        $script:held=@(Get-VariationLines $chosen)
        if($Update){Write-DigestLines $expected 'parity case' $script:held}
        $recorded=@{};foreach($line in (Read-DigestLines $expected)){$recorded[$line.Substring(0,$line.IndexOf(' | '))]=$line}
        $wrong=New-Object Collections.ArrayList
        foreach($one in $script:held){
            # A case with files of its own on a Mac is recorded from the ones it has on Windows.
            if($one.platform -and -not $windows){continue}
            if(-not $recorded.ContainsKey($one.name)){[void]$wrong.Add($one.name+': not recorded')}
            elseif($recorded[$one.name] -cne $one.line){[void]$wrong.Add('expected <'+$recorded[$one.name]+'> reader <'+$one.line+'>')}
        }
        if(-not $Only){foreach($name in $recorded.Keys){if(-not @($script:held|Where-Object{$_.name -ceq $name}).Count){[void]$wrong.Add($name+': recorded, but no case is named so')}}}
        Assert ($wrong.Count -eq 0) (''+$wrong.Count+" cases; see one's values with -Only NAME -Values, and if the change is meant, run this suite with -Update and review it:`n     "+(Get-WrongText $wrong.ToArray()))
    }
    if($script:held){'     '+$script:held.Count+' cases'}
    foreach($command in $commands){
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
        $script:varied=$null
        Check ('the reader answers or refuses '+$Fuzz+' seeded variations (seed '+$Seed+') as recorded') {
            $script:varied=@(Get-VariationLines (Get-Hotpl8ParityFuzzCases $cases $Fuzz $Seed))
            Assert ($script:varied.Count -eq $Fuzz)
            # A reader that refused everything would be as steady as one that answers.
            $answered=@($script:varied|Where-Object{$_.line -cmatch ' \| answer '}).Count
            Assert ($answered -ge 0.3*$Fuzz) ('the reader answered only '+$answered+' of '+$Fuzz+' variations')
            # The first seed's are recorded. A variation made from a case with files of its
            # own on a Mac holds a Windows path, and what is said of it is compared on Windows.
            if($Seed -ne 1){return}
            $expected='tests/parity/expected-variations.txt'
            if($Update){Write-DigestLines $expected 'seeded variation of the parity cases (seed 1)' $script:varied}
            $recorded=Read-DigestLines $expected
            Assert ($recorded.Count -ge 100) ('only '+$recorded.Count+' variations are recorded')
            $wrong=New-Object Collections.ArrayList
            for($index=0;$index -lt [Math]::Min($recorded.Count,$script:varied.Count);$index++){
                $one=$script:varied[$index]
                if($one.platform -and -not $windows){continue}
                if($one.line -cne $recorded[$index]){[void]$wrong.Add('expected <'+$recorded[$index]+'> reader <'+$one.line+'>')}
            }
            Assert ($wrong.Count -eq 0) (''+$wrong.Count+" variations; make one again with -Only 'fuzz 1-N*', and if the change is meant, run this suite with -Update and review it:`n     "+(Get-WrongText $wrong.ToArray()))
        }
        if($script:varied){'     '+@($script:varied|Where-Object{$_.line -cmatch ' \| answer '}).Count+' answered in some form, '+@($script:varied|Where-Object{$_.line -cnotmatch ' \| answer '}).Count+' refused in every form'}
    }
    }
}finally{
    [Environment]::SetEnvironmentVariable('HOTPL8_STATE_DIRECTORY',$priorState)
    $full=[IO.Path]::GetFullPath($lab)
    if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-parity-test-[a-f0-9]{32}$' -and (Test-Path -LiteralPath $full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
'Native parity ('+$edition+' '+$shellVersion.Major+'.'+$shellVersion.Minor+'): '+$script:passed+' passed, '+$script:failed+' failed.'
if($script:failed){exit 1}
