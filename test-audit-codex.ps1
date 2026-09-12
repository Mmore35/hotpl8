$ErrorActionPreference='Stop'
$dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-audit-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
$path=Join-Path $dir 'observations.jsonl'
$now=[datetimeoffset]::Parse('2026-09-10T12:00:00Z')
$script:passed=0; $script:failed=0
function Row([datetimeoffset]$Time,[string]$Status='ok'){
    @{observedAt=$Time.ToString('o');slots=@(@{id='main';status=$Status;observedAt=$Time.ToString('o')})}|ConvertTo-Json -Depth 5 -Compress
}
function Run($Lines,[datetimeoffset]$Since=[datetimeoffset]::MinValue){
    [IO.File]::WriteAllLines($path,[string[]]$Lines,(New-Object Text.UTF8Encoding($false)))
    & (Join-Path $PSScriptRoot 'audit-codex.ps1') -Slot main -HistoryPath $path -Now $now -Since $Since -RequiredHours 1|ConvertFrom-Json
}
function Check([string]$Name,[scriptblock]$Body){
    try{& $Body; $script:passed++; 'PASS '+$Name}catch{$script:failed++; 'FAIL '+$Name+': '+$_.Exception.Message}
}
function Assert($Condition){if(-not $Condition){throw 'assertion failed'}}
try{
    $healthy=@(for($i=12;$i -ge 0;$i--){Row $now.AddMinutes(-5*$i)})
    Check 'complete dense fresh coverage qualifies and leaves source untouched' {
        $r=Run $healthy; $before=(Get-FileHash $path).Hash
        $again=& (Join-Path $PSScriptRoot 'audit-codex.ps1') -Slot main -HistoryPath $path -Now $now -RequiredHours 1|ConvertFrom-Json
        Assert ($r.coverageStatus -eq 'sufficient' -and $again.currentContinuousHours -eq 1)
        Assert ((Get-FileHash $path).Hash -eq $before)
    }
    Check 'a long wall-clock span with a hole is not continuous coverage' {
        $r=Run @((Row $now.AddHours(-2)),(Row $now))
        Assert ($r.coverageStatus -eq 'incomplete' -and $r.gaps -eq 1 -and $r.currentContinuousHours -eq 0)
    }
    Check 'failed read interrupts the current run' {
        $rows=@($healthy); $rows[6]=Row $now.AddMinutes(-30) 'authentication_required'
        $r=Run $rows; Assert ($r.failed -eq 1 -and $r.coverageStatus -eq 'incomplete' -and $r.currentContinuousHours -lt 0.5)
    }
    Check 'malformed log row is not silently skipped into a passing run' {
        $rows=@($healthy); $rows[6]='{partial'; $r=Run $rows
        Assert ($r.invalidRows -eq 1 -and $r.coverageStatus -eq 'incomplete')
    }
    Check 'stale final observation cannot grant current coverage' {
        $rows=@(for($i=12;$i -ge 0;$i--){Row $now.AddMinutes(-20-5*$i)})
        $r=Run $rows; Assert ($r.coverageStatus -eq 'stale' -and $r.longestContinuousHours -eq 1)
    }
    Check 'revision boundary excludes older successes' {
        $r=Run $healthy $now.AddMinutes(-30)
        Assert ($r.observations -eq 7 -and $r.currentContinuousHours -eq 0.5 -and $r.coverageStatus -eq 'incomplete')
    }
    Check 'wrong home and future rows cannot count as successful observations' {
        $wrong=(Row $now.AddMinutes(-5)).Replace('main','other')
        $r=Run @($wrong,(Row $now.AddMinutes(5)))
        Assert ($r.invalidRows -eq 2 -and $r.successful -eq 0 -and $r.coverageStatus -eq 'no_observations')
    }
    Check 'out-of-order rows interrupt rather than reorder history' {
        $rows=@($healthy); $rows[6]=Row $now.AddHours(-2); $r=Run $rows
        Assert ($r.invalidRows -eq 1 -and $r.coverageStatus -eq 'incomplete')
    }
    Check 'missing history is explicitly unavailable' {
        $r=& (Join-Path $PSScriptRoot 'audit-codex.ps1') -Slot main -HistoryPath (Join-Path $dir 'absent.jsonl')|ConvertFrom-Json
        Assert ($r.coverageStatus -eq 'no_observations' -and $r.observations -eq 0)
    }
}finally{
    # Only this test's GUID-named directory is removed, using one native API.
    if([IO.Path]::GetFullPath($dir).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){
        [IO.Directory]::Delete($dir,$true)
    }
}
'passed='+$script:passed+' failed='+$script:failed
if($script:failed){exit 1}
