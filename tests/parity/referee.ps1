# The referee for the compiled reader: PowerShell's own answers to `hotpl8 status` and
# `hotpl8 explain`, as text and with -AsJson, computed in this process at a pinned instant.
#
# It repeats the few lines of hotpl8.ps1 between reading the policy and printing, because
# the entry script reads the real clock. tests/test-native-parity.ps1 also runs cases
# through the real entry script, so those lines cannot drift unnoticed.
#
# The four forms share one reading of the files, taken in an order that shows each form the
# snapshot a run of its own would see: `status` first, then the pause `explain` adds. That
# holds while printing changes nothing in the snapshot, which the suite checks by asking for
# single forms too (-Only). Reading once is what makes a thousand comparisons affordable.
#
# An answer is one of:
#   kind='text'   lines  - what the command prints, one string per line
#   kind='value'  dump   - the typed form of the object -AsJson serialises (see below);
#                 json   - PowerShell's own text for it
#   kind='error'  message - the command fails; the reader must decline
function Get-Hotpl8ParityAnswers([string]$StateDirectory,[string]$PreviewPolicy,[datetimeoffset]$Now,[string]$Only) {
    $answers=@{}
    try {
        $policy = Read-Hotpl8Json $(if($PreviewPolicy){$PreviewPolicy}else{Join-Path $StateDirectory 'policy.json'})
        if (-not $policy) { throw 'No valid policy.json. Run hotpl8 setup or see docs/install.md.' }
        Assert-Hotpl8Policy $policy
        $status = Read-Hotpl8Snapshot $StateDirectory $(if($PreviewPolicy){$policy}) -Now $Now
    } catch {
        $failed=@{kind='error';message=$_.Exception.Message}
        foreach($mode in 'status','status-json','explain','explain-json'){$answers[$mode]=$failed}
        return $answers
    }
    if (-not $status -or -not $status.generatedAt) {
        $answers['status']=$answers['status-json']=@{kind='text';lines=@('No cached status. Run hotpl8 refresh.')}
    } else {
        if(-not $Only -or $Only -eq 'status-json'){
            try { $answers['status-json']=@{kind='value';json=($status | ConvertTo-Json -Depth 24)} } catch { $answers['status-json']=@{kind='error';message=$_.Exception.Message} }
            # Typed before `explain` adds to the snapshot. A failure here is the suite's own.
            if($answers['status-json'].kind -eq 'value'){$answers['status-json'].dump=ConvertTo-Hotpl8ParityDump $status}
        }
        if(-not $Only -or $Only -eq 'status'){
            try { $answers['status']=@{kind='text';lines=@(Format-Hotpl8Status $status $policy $StateDirectory $Now)} } catch { $answers['status']=@{kind='error';message=$_.Exception.Message} }
        }
    }
    if($Only -and -not $Only.StartsWith('explain')){return $answers}
    try {
        if($status){$status|Add-Member NoteProperty automationPause (Get-Hotpl8Pause $StateDirectory $Now) -Force}
    } catch {
        $answers['explain']=$answers['explain-json']=@{kind='error';message=$_.Exception.Message}
        return $answers
    }
    if(-not $Only -or $Only -eq 'explain-json'){
        try {
            $shown=[pscustomobject]@{generatedAt=$status.generatedAt;claude=$status.decision;codex=$status.providers.codex.decisions;pause=$status.automationPause;providerOverview=$status.providerOverview}
            $answers['explain-json']=@{kind='value';json=($shown|ConvertTo-Json -Depth 16)}
        } catch { $answers['explain-json']=@{kind='error';message=$_.Exception.Message} }
        if($answers['explain-json'].kind -eq 'value'){$answers['explain-json'].dump=ConvertTo-Hotpl8ParityDump $shown}
    }
    if(-not $Only -or $Only -eq 'explain'){
        try { $answers['explain']=@{kind='text';lines=@(Format-Hotpl8Explanation $status $Now|ForEach-Object {ConvertTo-Hotpl8SafeText $_})} } catch { $answers['explain']=@{kind='error';message=$_.Exception.Message} }
    }
    $answers
}

# A typed dump of a value: one node per line, so two values are equal exactly when their
# dumps are. It records what ConvertTo-Json hides -- whether a number is a 32-bit or 64-bit
# integer, a decimal (with its scale) or a double (by its bits).
#
#   n  null        b:true  boolean      i:5  Int32      l:5  Int64
#   m:4.50  decimal        d:<16 hex digits>  double    s:text  string
#   [ ... ]  array         { ... }  object, in property order
#   h{ ... }  hash table, keys in ordinal order (a hash table has no defined order)
#   v  a property holding "no value" rather than null     ?:Type  anything else
function ConvertTo-Hotpl8ParityString([string]$Text) {
    if($Text -cmatch '\A[\x20-\x5b\x5d-\x7e]*\z'){return $Text}
    $builder=New-Object Text.StringBuilder
    foreach($c in $Text.ToCharArray()){
        $n=[int]$c
        if($n -eq 92){[void]$builder.Append('\\')}
        elseif($n -lt 32 -or $n -gt 126){[void]$builder.Append('\u'+$n.ToString('x4'))}
        else{[void]$builder.Append($c)}
    }
    $builder.ToString()
}
function Add-Hotpl8ParityNode([Collections.Generic.List[string]]$Out,[string]$Indent,[string]$Label,$Value) {
    $head=$Indent+$Label
    $invariant=[Globalization.CultureInfo]::InvariantCulture
    if($null -eq $Value){$Out.Add($head+'n');return}
    if($Value -is [bool]){$Out.Add($head+$(if($Value){'b:true'}else{'b:false'}));return}
    if($Value -is [int]){$Out.Add($head+'i:'+$Value.ToString($invariant));return}
    if($Value -is [long]){$Out.Add($head+'l:'+$Value.ToString($invariant));return}
    if($Value -is [decimal]){$Out.Add($head+'m:'+$Value.ToString($invariant));return}
    if($Value -is [double]){$Out.Add($head+'d:'+[BitConverter]::DoubleToInt64Bits($Value).ToString('x16'));return}
    if($Value -is [string]){$Out.Add($head+'s:'+(ConvertTo-Hotpl8ParityString $Value));return}
    $inner=$Indent+' '
    if($Value -is [array]){
        $Out.Add($head+'[')
        for($i=0;$i -lt $Value.Length;$i++){Add-Hotpl8ParityNode $Out $inner '' $Value[$i]}
        $Out.Add($Indent+']');return
    }
    if($Value -is [Collections.IDictionary]){
        $Out.Add($head+'h{')
        $keys=@($Value.Keys|ForEach-Object {[string]$_});[Array]::Sort($keys,[StringComparer]::Ordinal)
        foreach($key in $keys){Add-Hotpl8ParityNode $Out $inner ((ConvertTo-Hotpl8ParityString $key)+': ') $Value[$key]}
        $Out.Add($Indent+'}');return
    }
    if($Value.GetType().FullName -eq 'System.Management.Automation.PSCustomObject'){
        $Out.Add($head+'{')
        foreach($property in $Value.PSObject.Properties){
            $label=(ConvertTo-Hotpl8ParityString $property.Name)+': '
            # "No value" turns into null when it is passed to a function, so it is tested here.
            # It equals null but, unlike null, is an object.
            if($null -eq $property.Value -and $property.Value -is [psobject]){$Out.Add($inner+$label+'v')}
            else{Add-Hotpl8ParityNode $Out $inner $label $property.Value}
        }
        $Out.Add($Indent+'}');return
    }
    $Out.Add($head+'?:'+$Value.GetType().FullName)
}
function ConvertTo-Hotpl8ParityDump($Value) {
    $out=New-Object 'Collections.Generic.List[string]'
    Add-Hotpl8ParityNode $out '' '' $Value
    ($out -join "`n")+"`n"
}

# Case files carry times relative to the instant a case runs at, so the same text serves a
# pinned instant and the real clock:
#   @t-42s@  that instant minus 42 seconds, as 2026-09-12T11:59:18.0000000+00:00
#   @z+2h@   the same, as 2026-09-12T14:00:00Z
#   @f+83m@  the same, as 2026-09-12T13:23:00.250000+00:00 (the instant plus a quarter second)
#   @u+3d@   the same, as Unix seconds
# Units are s, m, h and d.
function Expand-Hotpl8ParityText([string]$Text,[datetimeoffset]$Now) {
    [regex]::Replace($Text,'@([tuzf])([+-]\d+)([smhd])@',{
        param($match)
        $amount=[int]$match.Groups[2].Value
        $at=switch($match.Groups[3].Value){'s'{$Now.AddSeconds($amount)}'m'{$Now.AddMinutes($amount)}'h'{$Now.AddHours($amount)}default{$Now.AddDays($amount)}}
        switch($match.Groups[1].Value){
            't'{$at.ToString('o')}
            'z'{$at.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture)}
            'f'{$at.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)+'.250000+00:00'}
            default{$at.ToUnixTimeSeconds().ToString([Globalization.CultureInfo]::InvariantCulture)}
        }
    })
}
