# Seeded variations of the parity cases, for inputs nobody thought to write down.
#
# A variation takes the files of one case, sometimes the policy or a side file of another,
# and changes a few values in the JSON text: a number, a time, a word, a literal, or one
# property removed. The same seed gives the same cases on every machine and PowerShell
# version, and each is made from the ones before it alone, so a failure names a case that
# tests/test-native-parity.ps1 makes again from the start of its name: -Only 'fuzz 7-203*'.
#
# The program may answer a variation or refuse it. Every variation is made from the files a
# case has on Windows, so a seed gives the same ones everywhere; one made from a case with
# files of its own on a Mac is marked, and what the program says of it counts on Windows only.

function New-Hotpl8ParityRandom([int]$Seed) { @{state=[long]($Seed -band 0x7fffffff)} }
function Get-Hotpl8ParityRandom($Random,[int]$Below) {
    $Random.state=($Random.state*1103515245+12345)%2147483648
    [int]((($Random.state -shr 12)%$Below))
}
function Get-Hotpl8ParityPick($Random,[string[]]$From) { $From[(Get-Hotpl8ParityRandom $Random $From.Count)] }

# One change to a JSON text. Returns the text unchanged when it holds nothing of that kind.
function Edit-Hotpl8ParityFuzzText([string]$Text,$Random) {
    $numbers='0','1','2','5','20','25','50','75','99','100','101','-1','0.5','1.0','12.25','33.333','99.95','100.0','0.1','66.66666666666667','0.30000000000000004','1000000','2147483648','1E-05','5.0000000001659828E-05','3.8e1','1E+16','null','true','"7"','[]','{}'
    $words='""','null','"ok"','"stale"','"unknown"','"error"','"auto"','"monitor"','"observed"','"eligible"','"work"','"codex"','"two\nlines"','"tab\there"',('"caf'+[char]0xe9+'"'),'"A"','"a"','7','{}'
    $literals='true','false','null','0','1','""','[]','{}'
    $kind=Get-Hotpl8ParityRandom $Random 6
    $pattern=switch($kind){
        0{'(?<=[:\[,] ?)-?\d+(?:\.\d+)?(?=[,\]}\r\n])'}
        1{'@([tzfu])([+-]\d+)([smhd])@'}
        2{'"[A-Za-z0-9]+": ?(?:"[^"\\]*"|-?\d+(?:\.\d+)?|true|false|null|@u[+-]\d+[smhd]@),'}
        3{'(?<=: ?)"[A-Za-z_ -]{0,24}"(?=[,}\]\r\n])'}
        4{'(?<=[:\[,] ?)(?:true|false|null)(?=[,\]}\r\n])'}
        default{'(?<=: ?)"[A-Za-z_ -]{0,24}"(?=[,}\]\r\n])'}
    }
    $found=[regex]::Matches($Text,$pattern)
    if(-not $found.Count){return $Text}
    $match=$found[(Get-Hotpl8ParityRandom $Random $found.Count)]
    $new=switch($kind){
        0{Get-Hotpl8ParityPick $Random $numbers}
        1{
            # 'u' stays a bare number; the three text forms may trade places.
            $form=$match.Groups[1].Value
            if($form -ne 'u'){$form=Get-Hotpl8ParityPick $Random @('t','z','f')}
            $unit=Get-Hotpl8ParityPick $Random @('s','s','m','h','d')
            $amount=switch($unit){
                's'{Get-Hotpl8ParityPick $Random @('0','1','4','5','6','42','59','60','299','300','301','899','900','901')}
                'm'{Get-Hotpl8ParityPick $Random @('1','14','15','16','83','300')}
                'h'{Get-Hotpl8ParityPick $Random @('1','2','5','24','52','167','168','169')}
                default{Get-Hotpl8ParityPick $Random @('1','3','7','8','400','800')}
            }
            '@'+$form+(Get-Hotpl8ParityPick $Random @('+','-'))+$amount+$unit+'@'
        }
        2{''}
        3{Get-Hotpl8ParityPick $Random $words}
        4{Get-Hotpl8ParityPick $Random $literals}
        # A word the file already uses somewhere else.
        default{$found[(Get-Hotpl8ParityRandom $Random $found.Count)].Value}
    }
    $Text.Remove($match.Index,$match.Length).Insert($match.Index,$new)
}

function Get-Hotpl8ParityFuzzCases([object[]]$Cases,[int]$Count,[int]$Seed) {
    $random=New-Hotpl8ParityRandom $Seed
    $filesOf={param($case)
        $files=@{}
        foreach($name in $case.files.Keys){$files[$name]=$case.files[$name]}
        $files
    }
    $bases=@($Cases|Where-Object {$_.files.ContainsKey('status.json')})
    $side='collector.json','automation-pause.json','automation-leases.json'
    $result=New-Object Collections.ArrayList
    for($index=1;$index -le $Count;$index++){
        $base=$bases[(Get-Hotpl8ParityRandom $random $bases.Count)]
        $files=& $filesOf $base
        $notes=@($base.name)
        $platform=$base.ContainsKey('macFiles')
        if((Get-Hotpl8ParityRandom $random 3) -eq 0){
            $other=$Cases[(Get-Hotpl8ParityRandom $random $Cases.Count)]
            $otherFiles=& $filesOf $other
            if($otherFiles.ContainsKey('policy.json')){$files['policy.json']=$otherFiles['policy.json'];$notes+=('policy of '+$other.name);if($other.ContainsKey('macFiles')){$platform=$true}}
        }
        if((Get-Hotpl8ParityRandom $random 4) -eq 0){
            $other=$Cases[(Get-Hotpl8ParityRandom $random $Cases.Count)]
            $otherFiles=& $filesOf $other
            foreach($name in $side){if($otherFiles.ContainsKey($name)){$files[$name]=$otherFiles[$name];$notes+=($name+' of '+$other.name);if($other.ContainsKey('macFiles')){$platform=$true}}}
        }
        $names=@($files.Keys|Sort-Object)
        $changes=1+(Get-Hotpl8ParityRandom $random 3)
        for($change=0;$change -lt $changes;$change++){
            # Mostly the snapshot: it is where the readings are.
            $name=if((Get-Hotpl8ParityRandom $random 3) -ne 0 -and $files.ContainsKey('status.json')){'status.json'}else{$names[(Get-Hotpl8ParityRandom $random $names.Count)]}
            $files[$name]=Edit-Hotpl8ParityFuzzText $files[$name] $random
        }
        $case=@{name=('fuzz '+$Seed+'-'+$index+' from '+($notes -join ', '));files=$files}
        if($platform){$case.macFiles=@{}}
        if($base.ContainsKey('preview')){$case.preview=$base.preview}
        if($base.ContainsKey('noBom')){$case.noBom=$base.noBom}
        if($base.ContainsKey('catalog')){$case.catalog=$base.catalog}
        [void]$result.Add($case)
    }
    return $result.ToArray()
}
