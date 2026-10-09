$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/native.ps1')
. (Join-Path $PSScriptRoot 'fixtures/frame.ps1')
$now=[datetimeoffset]::Parse('2026-09-13T12:00:00Z')
$p=@{prefer=@(1,2,3);reserve=@(3);mode='automate';margin5h=20;margin7d=10;margin7dWork=5;codex=@{slots=@(@{id='main'});prefer=@('main');defaultMeter='codex';margin7d=5}}|ConvertTo-Json -Depth 9|ConvertFrom-Json
$s=@{generatedAt=$now.ToString('o');active=1;slots=@(1..3|ForEach-Object {@{slot=$_;status='ok';fresh=$true;streamKey=('fictional-'+$_);observedAt=$now.ToString('o');used5h=10;used7d=($_-1)*50;reset5h=$now.AddHours(1).ToString('o');reset7d=$now.AddDays(2).ToString('o')}});providers=@{codex=@{recommendedSlot='main';slots=@(@{id='main';status='ok';observedAt=$now.ToString('o');buckets=@{codex=@{status='observed';windows=@{'10080'=@{usedPercent=20;remainingPercent=80;anchorState='observed-active';resetsAt=$now.AddDays(2).ToUnixTimeSeconds()}}}}})}}}|ConvertTo-Json -Depth 15|ConvertFrom-Json
$script:passed=0;$script:failed=0
function Assert($Value){if(-not $Value){throw 'assertion failed'}}
function Check($Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message}}
function Copy-Value($Value){$Value|ConvertTo-Json -Depth 24|ConvertFrom-Json}
Check 'a paused frame never claims automatic routing' {
    $c=Copy-Value $s;$c|Add-Member NoteProperty automationPause @{until=$now.AddHours(1).ToString('o')}
    Assert ((@(Get-Hotpl8TestFrame $c $p $now 50 18 -Files @{'automation-pause.json'=$c.automationPause}) -join '') -cmatch 'auto-switch paused')
}
Check 'summary and view are pure and pinned when scrolling' {
    $before=$s|ConvertTo-Json -Depth 24 -Compress
    $first=@(Get-Hotpl8TestFrame $s $p $now 79 23)
    $last=@(Get-Hotpl8TestFrame $s $p $now 79 23 -As @('--offset','999'))
    Assert (($first[2..7] -join '') -ceq ($last[2..7] -join '') -and ($first -join '') -cne ($last -join ''))
    Assert (($s|ConvertTo-Json -Depth 24 -Compress) -eq $before)
    Assert (($first -join '') -match '│  CLAUDE\s' -and ($first -join '') -match '│  CODEX\s')
}
Check 'CLI status and explain re-evaluate policy and clock without collecting' {
    $dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-overview-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dir)
    try {
        $policy=Copy-Value $p;$policy|Add-Member NoteProperty schemaVersion 2;$policy|Add-Member NoteProperty disabled @(1)
        $c=Copy-Value $s;$c|Add-Member NoteProperty providerOverview @{claude=@{accounts=99;remainingPercent=100}}
        foreach($a in $c.slots){$a.observedAt=[datetimeoffset]::UtcNow.AddHours(-1).ToString('o')}
        Write-Hotpl8Text (Join-Path $dir 'policy.json') ($policy|ConvertTo-Json -Depth 24)
        Write-Hotpl8Text (Join-Path $dir 'status.json') ($c|ConvertTo-Json -Depth 24)
        Write-Hotpl8Text (Join-Path $dir 'automation-pause.json') (@{until=[datetimeoffset]::UtcNow.AddHours(1).ToString('o');reason='test'}|ConvertTo-Json)
        $before=(Get-FileHash (Join-Path $dir 'status.json')).Hash
        foreach($command in @('status','explain')){
            $output=& (Get-Hotpl8PowerShell) -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'hotpl8.ps1') $command -StateDirectory $dir -AsJson
            Assert ($LASTEXITCODE -eq 0)
            $o=($output|ConvertFrom-Json).providerOverview.claude
            Assert ($o.accounts -eq 2 -and $o.measured -eq 0 -and $null -eq $o.remainingPercent -and $o.automation -eq 'automation paused')
        }
        Assert ((Get-FileHash (Join-Path $dir 'status.json')).Hash -eq $before)
        Assert (@(Get-ChildItem $dir -File).Count -eq 3)
    }finally{
        $full=[IO.Path]::GetFullPath($dir)
        if((Split-Path $full -Parent) -eq [IO.Path]::GetTempPath().TrimEnd('\','/') -and (Split-Path $full -Leaf) -match '^hotpl8-overview-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
    }
}
'passed='+$script:passed+' failed='+$script:failed
if($script:failed){exit 1}
