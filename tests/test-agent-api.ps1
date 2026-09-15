# Offline agent contract tests: synthetic state, actual CLI framing, production selectors.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($name in @('common','config','diagnostics','insights','management','agent-api')){. (Join-Path $root ('src/'+$name+'.ps1'))}
. (Join-Path $root 'src/providers/claude.ps1')
. (Join-Path $root 'src/providers/codex.ps1')
$script:passed=0;$script:failed=0
function Assert($Value,[string]$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check([string]$Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message+' at '+$_.InvocationInfo.ScriptLineNumber}}
function Clone($Value){$Value|ConvertTo-Json -Depth 24|ConvertFrom-Json}
$dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-agent-tests-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
$now=[datetimeoffset]::UtcNow
function SaveFixture {
    $script:policy=Read-Hotpl8Json (Join-Path $root 'policy.example.json')
    $script:policy.prefer=@(1,2);$script:policy.reserve=@(2)
    $script:policy.labels=Clone @{'1'='SECRET-LABEL';'2'='SECOND-LABEL'}
    $script:policy.codex.slots=@(Clone @{id='work';label='PRIVATE-LABEL';home=(Join-Path $dir 'native-home')})
    $script:policy.codex.prefer=@('work');$script:policy.codex.modelMeters=Clone @{'model-main'='codex';'model-spark'='codex_bengalfox'}
    $script:snapshot=Clone @{
        schemaVersion=2;generatedAt=$now.ToString('o');active=1
        slots=@(foreach($id in @(1,2)){@{slot=$id;status='ok';fresh=$true;observedAt=$now.ToString('o');used5h=20;used7d=30;reset5h=$now.AddHours(2).ToString('o');reset7d=$now.AddDays(3).ToString('o');label='SECRET-LABEL';identityKey='SECRET-IDENTITY'}})
        providers=@{codex=@{observedAt=$now.ToString('o');recommendedSlot='work';recommendations=@{codex='work'};slots=@(@{id='work';status='ok';observedAt=$now.ToString('o');buckets=@{codex=@{status='observed';windows=@{'10080'=@{remainingPercent=70;usedPercent=30;resetsAt=$now.AddDays(2).ToUnixTimeSeconds();anchorState='observed-active'}}};codex_bengalfox=@{status='observed';windows=@{'300'=@{remainingPercent=0;usedPercent=100;resetsAt=$now.AddHours(1).ToUnixTimeSeconds()}}}}})}}
    }
    WriteFixture
}
function WriteFixture {
    Write-Hotpl8Text (Join-Path $dir 'policy.json') ($script:policy|ConvertTo-Json -Depth 24)
    Write-Hotpl8Text (Join-Path $dir 'status.json') ($script:snapshot|ConvertTo-Json -Depth 24)
}
function Request([string]$Operation,$Arguments=@{},[bool]$AllowPause=$true) {
    Invoke-Hotpl8AgentRequest (Clone @{apiVersion=1;operation=$Operation;arguments=$Arguments}) $dir $AllowPause
}
function Invoke-AgentTestCli([string]$Json,[string]$Command='agent') {
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $psi.Arguments=(@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'hotpl8.ps1'),$Command,'-StateDirectory',$dir)|ForEach-Object {ConvertTo-NativeArgument $_}) -join ' '
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($psi)
    try{
        $process.StandardInput.Write($Json);$process.StandardInput.Close()
        $out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
        Assert ($process.WaitForExit(90000)) 'CLI timed out after 90 seconds'
        [pscustomobject]@{exit=$process.ExitCode;output=$out.Result;error=$err.Result}
    }finally{if(-not $process.HasExited){$process.Kill()};$process.Dispose()}
}
try{
    Check 'new API startup doctor works without policy or snapshot and writes nothing' {
        $r=Request doctor;Assert $r.ok;Assert (-not $r.data.policyPresent)
        Assert (@(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0)
        Assert ((Request status).error.code -eq 'policy_invalid')
    }
    SaveFixture
    Check 'readiness reuses production Codex selector and distinguishes meters' {
        $main=Request readiness @{provider='codex';model='model-main'}
        Assert $main.ok ($main|ConvertTo-Json -Depth 5)
        $expected=Select-CodexSlot $snapshot.providers.codex.slots $policy.codex 'codex' 'work' $null $now
        Assert ($main.data.eligible -and $main.data.selectedSlot -eq $expected -and $main.data.requiresNativeValidation)
        $spark=Request readiness @{provider='codex';model='model-spark'}
        Assert ($spark.ok -and -not $spark.data.eligible -and $spark.data.meter -eq 'codex_bengalfox')
        Assert ((Request readiness @{provider='codex';model='not-mapped'}).error.code -eq 'model_unknown')
        Assert ((Request readiness @{provider='claude';model='arbitrary'}).error.code -eq 'model_unknown')
    }
    Check 'inspect responses are compact and omit labels identities paths and raw snapshot fields' {
        foreach($op in @('status','explain','capabilities','doctor','accounts')){
            $r=Request $op;Assert $r.ok ($op+': '+($r|ConvertTo-Json -Depth 5))
            $json=$r|ConvertTo-Json -Depth 24
            Assert ($json -notmatch 'SECRET-|PRIVATE-LABEL|SECOND-LABEL|native-home|identityKey|accessToken|refreshToken')
            Assert ($r.apiVersion -eq 1 -and $null -eq $r.error -and $r.computedAt)
        }
    }
    Check 'all read operations preserve directory bytes and never invoke native processes' {
        function Invoke-Hotpl8Process {throw 'Native process called'}
        function Read-CodexQuota {throw 'Native quota called'}
        function Invoke-ClaudeTick {throw 'Collector called'}
        $before=@(Get-ChildItem -LiteralPath $dir -File|ForEach-Object {$_.Name+':'+(Get-FileHash $_.FullName).Hash}) -join ','
        foreach($op in @('status','explain','capabilities','doctor','accounts')){Assert (Request $op).ok}
        Assert (Request readiness @{provider='claude'}).ok
        Assert (Request readiness @{provider='codex'}).ok
        $after=@(Get-ChildItem -LiteralPath $dir -File|ForEach-Object {$_.Name+':'+(Get-FileHash $_.FullName).Hash}) -join ','
        Assert ($before -eq $after)
    }
    Check 'strict version object operation and argument validation uses stable errors' {
        foreach($json in @('[]','null','42','true','"text"','{"apiVersion":1,"operation":"status","arguments":{},"extra":1}')){Assert (-not (Invoke-Hotpl8AgentJson $json $dir).ok)}
        Assert ((Invoke-Hotpl8AgentJson '{broken' $dir).error.code -eq 'invalid_json')
        Assert ((Invoke-Hotpl8AgentJson ('x'*65537) $dir).error.code -eq 'request_too_large')
        Assert ((Invoke-Hotpl8AgentJson '{"apiVersion":"1","operation":"status","arguments":{}}' $dir).error.code -eq 'unsupported_version')
        Assert ((Request 'STATUS').error.code -eq 'unknown_operation')
        Assert ((Request status @{path='anything'}).error.code -eq 'invalid_arguments')
        Assert ((Request readiness @{provider='other'}).error.code -eq 'invalid_arguments')
        Assert ((Request readiness @{provider=@('claude')}).error.code -eq 'invalid_arguments')
        Assert ((Request status @()).error.code -eq 'invalid_arguments')
    }
    Check 'real JSON CLI has one JSON response correct exit code and clean stderr' {
        $bomRequest=[string][char]0xfeff+'{"apiVersion":1,"operation":"status","arguments":{}}'
        Assert (Invoke-Hotpl8AgentJson $bomRequest $dir).ok 'UTF-8 preamble must not be treated as JSON content'
        $r=Invoke-AgentTestCli '{"apiVersion":1,"operation":"status","arguments":{}}'
        Assert ($r.exit -eq 0 -and -not $r.error) ($r|ConvertTo-Json -Depth 5)
        Assert (($r.output.Trim() -split "`n").Count -eq 1)
        Assert ($r.output|ConvertFrom-Json).ok
        $r=Invoke-AgentTestCli '{bad';Assert ($r.exit -eq 1 -and -not $r.error);Assert (($r.output|ConvertFrom-Json).error.code -eq 'invalid_json')
    }
    Check 'legacy JSON status remains unwrapped' {
        $psi=New-Object Diagnostics.ProcessStartInfo
        $psi.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $psi.Arguments=(@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'hotpl8.ps1'),'status','-AsJson','-StateDirectory',$dir)|ForEach-Object {ConvertTo-NativeArgument $_}) -join ' '
        $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true
        $p=[Diagnostics.Process]::Start($psi);try{$raw=$p.StandardOutput.ReadToEnd();$p.WaitForExit();Assert ($p.ExitCode -eq 0);$parsed=$raw|ConvertFrom-Json;Assert ($parsed.schemaVersion -eq 2 -and -not $parsed.PSObject.Properties['apiVersion'])}finally{$p.Dispose()}
    }
    Check 'disabled removed and duplicate Codex observations cannot authorize selection' {
        $policy.codex|Add-Member NoteProperty disabled @('work') -Force;WriteFixture;Assert (-not (Request readiness @{provider='codex'}).data.eligible)
        SaveFixture;$snapshot.providers.codex.slots+=@($snapshot.providers.codex.slots[0]);WriteFixture
        $r=Request readiness @{provider='codex'};Assert (-not $r.data.eligible -and $r.data.accounts[0].reason -eq 'duplicate_observation')
        SaveFixture;$policy.codex.slots=@();$policy.codex.prefer=@();WriteFixture
        $r=Request readiness @{provider='codex'};Assert ($r.ok -and -not $r.data.eligible -and $r.data.accounts.Count -eq 0)
    }
    Check 'stale future malformed and elapsed-reset Codex readings fail conservatively' {
        foreach($time in @($now.AddHours(-1),$now.AddMinutes(2))){SaveFixture;$snapshot.providers.codex.slots[0].observedAt=$time.ToString('o');WriteFixture;$r=Request readiness @{provider='codex'};Assert ($r.ok -and -not $r.data.eligible -and $r.data.accounts[0].reason -eq 'stale')}
        SaveFixture;$snapshot.providers.codex.slots[0].buckets.codex.windows.'10080'.remainingPercent='70';WriteFixture
        $r=Request readiness @{provider='codex'};Assert ($r.ok -and $r.data.accounts[0].reason -eq 'malformed')
        SaveFixture;$snapshot.providers.codex.slots[0].buckets.codex.windows.'10080'.resetsAt=$now.AddSeconds(-1).ToUnixTimeSeconds();WriteFixture
        Assert (-not (Request readiness @{provider='codex'}).data.eligible)
    }
    Check 'Claude current and proposed accounts respect pause hold monitor and scope' {
        SaveFixture;$snapshot.slots[0].used5h=100;WriteFixture
        $r=Request readiness @{provider='claude'}
        Assert ($r.ok -and -not $r.data.eligible -and $r.data.proposedSlot -eq '2' -and $r.data.requiresSelection -and -not $r.data.switchingPermitted)
        $policy.mode='automate';$policy.switchEnabled=$true;WriteFixture
        $r=Request readiness @{provider='claude'};Assert ($r.data.eligible -and $r.data.selectedSlot -eq '2' -and $r.data.switchingPermitted)
        Set-Hotpl8Pause $dir 10 'test';$r=Request readiness @{provider='claude'};Assert ($r.data.automationPaused -and -not $r.data.eligible)
        Set-Hotpl8Pause $dir 0 'resume'
        Write-Hotpl8Text (Join-Path $dir 'hold.json') (@{until=$now.AddHours(1).ToString('o')}|ConvertTo-Json)
        Assert (Request readiness @{provider='claude'}).data.selectionHeld
        Write-Hotpl8Text (Join-Path $dir 'hold.json') (@{until=$now.AddHours(-1).ToString('o')}|ConvertTo-Json)
        $policy|Add-Member NoteProperty claudeModels @('scoped-model') -Force;WriteFixture
        $r=Request readiness @{provider='claude'};Assert (-not $r.data.eligible -and $r.data.accounts[1].reason -eq 'model_quota_unknown')
    }
    Check 'legacy hold ambiguity agrees with production instead of blocking forever' {
        SaveFixture;$policy.mode='automate';$policy.switchEnabled=$true;$snapshot.slots[0].used5h=100;WriteFixture
        $holdPath=Join-Path $dir 'hold.json'
        foreach($content in @('{broken','{}','{"until":"invalid"}','{"until":"2000-01-01T00:00:00Z"}')){
            Write-Hotpl8Text $holdPath $content
            Assert (-not (Get-Hold $dir)) 'fixture must fail open in production'
            $r=Request readiness @{provider='claude'}
            Assert ($r.ok -and -not $r.data.selectionHeld -and $r.data.switchingPermitted -and $r.data.selectedSlot -eq '2')
        }
        Write-Hotpl8Text $holdPath (@{until=$now.AddHours(1).ToString('o')}|ConvertTo-Json)
        Assert (Get-Hold $dir)
        Assert (Request readiness @{provider='claude'}).data.selectionHeld
        $handle=[IO.File]::Open($holdPath,'Open','ReadWrite','None')
        try{
            Assert (-not (Get-Hold $dir))
            $r=Request readiness @{provider='claude'}
            Assert ($r.ok -and -not $r.data.selectionHeld -and $r.data.selectedSlot -eq '2')
        }finally{$handle.Dispose()}
        Write-Hotpl8Text $holdPath (@{until=$now.AddHours(-1).ToString('o')}|ConvertTo-Json)
    }
    Check 'Claude current-time freshness and zero floors do not permit exhausted quota' {
        SaveFixture;$policy.margin5h=0;$policy.margin7d=0;$policy.margin7dWork=0
        foreach($s in $snapshot.slots){$s.used5h=100};WriteFixture
        Assert (-not (Request readiness @{provider='claude'}).data.eligible)
        SaveFixture;$policy.maxUsageAgeS=5;foreach($s in $snapshot.slots){$s.observedAt=$now.AddSeconds(-10).ToString('o')};WriteFixture
        $r=Request readiness @{provider='claude'};Assert (-not $r.data.eligible -and $r.data.accounts[0].reason -eq 'stale')
    }
    Check 'critical readiness agrees with production selector and excludes reserve drain' {
        SaveFixture;$policy.mode='automate';$policy.switchEnabled=$true;$policy.critical.enabled=$true
        foreach($s in $snapshot.slots){$s.used5h=88};WriteFixture
        $r=Request readiness @{provider='claude'};Assert ($r.ok -and $r.data.critical -and $r.data.eligible -and $r.data.selectedSlot -eq '1') ($r|ConvertTo-Json -Depth 7)
        Assert (-not $r.data.accounts[1].eligible)
        $policy.codex.critical.enabled=$true;$snapshot.providers.codex.slots[0].buckets.codex.windows.'10080'.remainingPercent=12;$snapshot.providers.codex.slots[0].buckets.codex.windows.'10080'.usedPercent=88;WriteFixture
        $r=Request readiness @{provider='codex'};Assert ($r.ok -and $r.data.critical -and $r.data.eligible)
    }
    Check 'lease API validates types gates writes and preserves manual pause' {
        SaveFixture;$id=[guid]::NewGuid().ToString('D')
        Assert ((Request pause.acquire @{leaseId=$id;owner='fixture';minutes=10} $false).error.code -eq 'permission_denied')
        foreach($m in @('10',0,1441,1.1)) {Assert ((Request pause.acquire @{leaseId=$id;owner='fixture';minutes=$m}).error.code -eq 'invalid_arguments')}
        $r=Request pause.acquire @{leaseId=$id;owner='fixture';minutes=10};Assert $r.ok ($r|ConvertTo-Json)
        Assert (Request readiness @{provider='codex'}).data.automationPaused
        Assert ((Request status|ConvertTo-Json -Depth 24) -notmatch $id)
        Set-Hotpl8Pause $dir 10 'manual'
        Assert (Request pause.release @{leaseId=$id}).ok
        Assert (Get-Hotpl8Pause $dir)
        Set-Hotpl8Pause $dir 0 'resume'
    }
    Check 'same dispatcher rereads policy and missing cache produces explicit error' {
        SaveFixture;Assert (Request readiness @{provider='codex'}).data.eligible
        $policy.codex|Add-Member NoteProperty disabled @('work') -Force;WriteFixture;Assert (-not (Request readiness @{provider='codex'}).data.eligible)
        Write-Hotpl8Text (Join-Path $dir 'status.json') 'null';Assert ((Request status).error.code -eq 'snapshot_invalid')
    }
}finally{
    $full=[IO.Path]::GetFullPath($dir)
    if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-agent-tests-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
"$script:passed passed; $script:failed failed"
if($script:failed){exit 1}
