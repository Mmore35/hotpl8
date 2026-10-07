# The rules PowerShell and the compiled program both still calculate, held to one set of
# cases. tests/parity/shared-rules.json is read here and by the program's own tests
# (cargo test in native/), so neither side can change one of these rules alone. Everything
# is fictional and staged under a temporary directory: no account, no cswap and no program
# of this machine is looked for or run.
# -Update rewrites the answers of the control cases from what PowerShell gives. The
# program's tests then have to agree with them; a case is never edited to make them pass.
param([switch]$Update)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($file in @('common','config','insights','collection')){. (Join-Path $root ('src/'+$file+'.ps1'))}
. (Join-Path $root 'src/providers/claude.ps1')
. (Join-Path $root 'src/providers/codex.ps1')
$script:passed=0;$script:failed=0
function Assert($Value,[string]$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check([string]$Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message}}
$shared=Join-Path $root 'tests/parity/shared-rules.json'
$utf8=New-Object Text.UTF8Encoding($false)
$rules=[IO.File]::ReadAllText($shared,$utf8)|ConvertFrom-Json
$dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-shared-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
function New-Stage([string]$Name){$at=Join-Path $dir ($Name+'-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($at);$at}
# What the control files of one case say: the name of their bytes, the hold, and what an
# action is told about them.
function Get-ControlAnswer($Case){
    $at=New-Stage 'control'
    foreach($file in $Case.files.PSObject.Properties){[IO.File]::WriteAllBytes((Join-Path $at $file.Name),$utf8.GetBytes([string]$file.Value))}
    $snapshot=Get-Hotpl8ControlSnapshot $at
    $hold=Get-Hold $at
    $context=Get-Hotpl8ProviderActionContext $snapshot.policy $at $Case.context ([datetimeoffset]::Parse($Case.now))
    $held=if($hold){[ordered]@{until=$hold.until.ToString('o');reason=$hold.reason}}else{$null}
    ConvertTo-Json -Compress -Depth 12 -InputObject ([ordered]@{generation=$snapshot.generation;hold=$held;context=$context})
}
try{
    Check 'the control files say what the shared cases say' {
        # One case to a line, its answer last, as native/src/control.rs reads them.
        $lines=[IO.File]::ReadAllText($shared,$utf8).Split("`n")
        $cases=0;$wrong=@()
        for($i=0;$i -lt $lines.Count;$i++){
            if(-not $lines[$i].StartsWith('{"name"') -or -not $lines[$i].Contains(',"files":')){continue}
            $cases++
            $text=$lines[$i].TrimEnd(',');$mark=$text.IndexOf(',"expected":')
            $case=$text|ConvertFrom-Json
            $answer=Get-ControlAnswer $case
            if($Update){$lines[$i]=$text.Substring(0,$mark+12)+$answer+'}'+$lines[$i].Substring($text.Length)}
            elseif($answer -cne $text.Substring($mark+12,$text.Length-$mark-13)){$wrong+=$case.name+' gave '+$answer}
        }
        Assert ($cases -gt 20) ('cases '+$cases)
        if($Update){[IO.File]::WriteAllText($shared,($lines -join "`n"),$utf8)}
        Assert ($wrong.Count -eq 0) ('differ: '+($wrong -join '; '))
    }
    Check 'cswap is found where the shared cases say' {
        # The one place every user of a machine shares cannot be staged, so a machine that
        # has a cswap there cannot run these cases.
        if(Test-Path -LiteralPath '/usr/local/bin/cswap'){'NOTE the cswap cases were left out: this machine has /usr/local/bin/cswap';return}
        Assert (@($rules.cswap).Count -gt 8) ('cases '+@($rules.cswap).Count)
        $kept=@{owned=$env:HOTPL8_NATIVE_BIN;path=$env:PATH;local=$env:LOCALAPPDATA;roaming=$env:APPDATA;home=$HOME}
        $wrong=@()
        try{
            foreach($case in @($rules.cswap)){
                $at=New-Stage 'cswap'
                foreach($place in 'owned','home','path','local','roaming'){[void][IO.Directory]::CreateDirectory((Join-Path $at $place))}
                # Each staged cswap holds the name of its place, which is how the one found is told.
                foreach($place in @($case.present)){
                    $file=Join-Path $at $(if($place -in 'owned','path'){$place+'/cswap.exe'}else{$place})
                    [void][IO.Directory]::CreateDirectory((Split-Path $file -Parent));[IO.File]::WriteAllText($file,$place)
                }
                $env:HOTPL8_NATIVE_BIN=Join-Path $at 'owned';$env:PATH=Join-Path $at 'path';$env:LOCALAPPDATA=Join-Path $at 'local';$env:APPDATA=Join-Path $at 'roaming'
                Set-Variable -Name HOME -Value (Join-Path $at 'home') -Force
                $found=Resolve-CswapExecutable ([string]$case.named)
                $answer=if($found -and (Test-Path -LiteralPath $found -PathType Leaf)){[IO.File]::ReadAllText($found)}else{$found}
                if(($null -eq $answer) -ne ($null -eq $case.expected) -or [string]$answer -cne [string]$case.expected){$wrong+=$case.name+' gave '+$answer}
            }
        }finally{
            $env:HOTPL8_NATIVE_BIN=$kept.owned;$env:PATH=$kept.path;$env:LOCALAPPDATA=$kept.local;$env:APPDATA=$kept.roaming
            Set-Variable -Name HOME -Value $kept.home -Force
        }
        Assert ($wrong.Count -eq 0) ('differ: '+($wrong -join '; '))
        Assert ((Get-CswapReadTimeoutMs) -eq $rules.readTimeoutMs) 'how long the list of accounts may take changed'
    }
    Check 'each ordering of a replay picks what the shared cases say' {
        $frames=@([IO.File]::ReadAllLines((Join-Path $root 'tests/parity/replay-frames.txt'))|Where-Object{$_})
        $expected=@([IO.File]::ReadAllLines((Join-Path $root 'tests/parity/replay-expected.txt'))|Where-Object{$_})
        $text={param($Value) if($null -eq $Value){'null'}else{[string]$Value}}
        Assert (@($rules.replay).Count -gt 7) ('cases '+@($rules.replay).Count)
        $said=@(foreach($case in @($rules.replay)){
            $picked=@(foreach($at in @($case.pick)){ConvertFrom-Hotpl8Json $frames[$at]})
            $r=Invoke-Hotpl8Replay $picked $case.policy
            foreach($d in @($r.decisions)){$case.name+'|'+(& $text $d.stream)+'|'+(& $text $d.at)+'|'+(& $text $d.selected)+'|'+(& $text $d.reserve)}
            foreach($s in @($r.summary)){$case.name+'|sum|'+(& $text $s.stream)+'|'+(& $text $s.switches)+'|'+(& $text $s.reserveSelections)+'|'+(& $text $s.unavailable)}
            $case.name+'|frames|'+(& $text $r.frames)+'|'+(& $text $r.schemaVersion)
        })
        # PowerShell 7 gives the same totals in its own order.
        if($PSVersionTable.PSEdition -eq 'Core'){$said=@($said|Sort-Object);$expected=@($expected|Sort-Object)}
        Assert ($said.Count -eq $expected.Count) ('lines '+$said.Count+', not '+$expected.Count)
        for($i=0;$i -lt $said.Count;$i++){Assert ($said[$i] -ceq $expected[$i]) ('line '+($i+1)+': '+$said[$i]+', not '+$expected[$i])}
    }
    Check 'a failure is recorded under the kind the shared cases say' {
        $absent=$null
        $failures=@{
            'access denied'={throw (New-Object UnauthorizedAccessException 'fictional')}
            'a file'={throw (New-Object IO.IOException 'fictional')}
            'a missing member'={$absent.member=1}
            # No parameter PowerShell itself refuses carries this name in Windows PowerShell,
            # so the record is made here.
            'a wrong parameter'={throw (New-Object Management.Automation.ErrorRecord (New-Object ArgumentException 'fictional'),'ParameterBindingFailed','InvalidArgument',$null)}
            'anything else'={throw 'fictional'}
        }
        Assert (@($rules.failures).Count -eq $failures.Count) 'the failures named here and in the shared cases differ'
        foreach($case in @($rules.failures)){
            $caught=$null
            try{& $failures[$case.failure]}catch{$caught=$_}
            Assert ($null -ne $caught) ($case.failure+' did not fail')
            $kind=Get-Hotpl8FailureCode $caught
            Assert ($kind -ceq $case.kind) ($case.failure+' is '+$kind+', not '+$case.kind)
        }
    }
}finally{
    $resolved=[IO.Path]::GetFullPath($dir)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $resolved -Leaf) -match '^hotpl8-shared-[a-f0-9]{32}$'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
'passed='+$script:passed+' failed='+$script:failed
if($script:failed){exit 1}
