$root = Split-Path $PSScriptRoot -Parent
# Offline acceptance tests. No live accounts or OpenAI requests.
$ErrorActionPreference = 'Stop'
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/providers/claude.ps1')
. (Join-Path $root 'src/providers/codex.ps1')
$script:passed = 0; $script:failed = 0
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; 'PASS ' + $Name }
    catch { $script:failed++; 'FAIL ' + $Name + ': ' + $_.Exception.Message }
}
function Assert($Value, [string]$Message = 'assertion failed') { if (-not $Value) { throw $Message } }
function Copy-Value($Value) { return $Value | ConvertTo-Json -Depth 24 | ConvertFrom-Json }
$now = [datetimeoffset]::UtcNow
function Fixture($Used = 10, $Duration = 10080, $Reset = ($now.ToUnixTimeSeconds() + 3600)) {
    return Copy-Value @{ rateLimits = @{ limitId = 'codex'; primary = @{ usedPercent = $Used; windowDurationMins = $Duration; resetsAt = $Reset }; secondary = $null; spendControlReached = $false; rateLimitReachedType = $null } }
}
function Make-Slot([string]$Id, [double]$Used = 10, [long]$Reset = ($now.ToUnixTimeSeconds() + 3600)) {
    $b = ConvertTo-CodexBuckets (Fixture $Used 10080 $Reset) $null $now
    $b.codex.windows.'10080'.anchorState = 'observed-active'
    return [pscustomobject]@{ id = $Id; label = $Id; status = 'ok'; observedAt = $now.ToString('o'); buckets = $b; defaultModel = 'fixture-model'; modelProvider = 'openai' }
}
$dir = Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
$oldScenario = $env:HOTPL8_TEST_SCENARIO; $oldLaunch = $env:HOTPL8_TEST_LAUNCH
$clearedEnv = @{}
foreach ($key in @('OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','CODEX_SQLITE_HOME','OPENAI_BASE_URL')) { $clearedEnv[$key] = [Environment]::GetEnvironmentVariable($key); [Environment]::SetEnvironmentVariable($key,$null) }
try {
    $homeA = Join-Path $dir 'home A'; $homeB = Join-Path $dir 'home B'
    New-Item -ItemType Directory -Path $homeA,$homeB | Out-Null
    $policy = Copy-Value @{ slots = @(@{ id='a'; home=$homeA },@{ id='b'; home=$homeB }); prefer=@('a','b'); reserve=@(); order='soonest-reset'; margin5h=25; margin7d=20; margin7dWork=5; defaultMeter='codex'; modelMeters=@{ 'fixture-model'='codex' } }
    Check 'confirmed anchor survives immediate refresh but not a moved reset' {
        $q=Fixture; $old=ConvertTo-CodexBuckets $q $null $now.AddMinutes(-1)
        $confirmed=ConvertTo-CodexBuckets $q $old $now
        Assert ($confirmed.codex.windows.'10080'.anchorState -eq 'observed-active')
        $again=ConvertTo-CodexBuckets $q $confirmed $now.AddSeconds(1)
        Assert ($again.codex.windows.'10080'.anchorState -eq 'observed-active')
        $q.rateLimits.primary.resetsAt+=300
        Assert ((ConvertTo-CodexBuckets $q $confirmed $now.AddSeconds(1)).codex.windows.'10080'.anchorState -eq 'unconfirmed')
    }
    Check 'degraded weekly headroom outranks previous reset lead' {
        $a=Make-Slot a 94 ($now.ToUnixTimeSeconds()+3600)
        $b=Make-Slot b 84 ($now.ToUnixTimeSeconds()+7200)
        Assert ((Select-CodexSlot @($a,$b) $policy codex a $null $now) -eq 'b')
    }
    Check 'preference ordering is not overridden by reset lead' {
        $p=Copy-Value $policy; $p.order='prefer'; $p.prefer=@('b','a')
        $a=Make-Slot a 10 ($now.ToUnixTimeSeconds()+3600)
        $b=Make-Slot b 10 ($now.ToUnixTimeSeconds()+7200)
        Assert ((Select-CodexSlot @($a,$b) $p codex a $null $now) -eq 'b')
    }
    Check 'weekly-only shape has no fabricated 5h' { $b=ConvertTo-CodexBuckets (Fixture) $null $now; Assert ($b.codex.status -eq 'observed'); Assert ($null -eq $b.codex.windows.'300') }
    Check 'separate additional meter retained' { $q=Fixture; $spark=Copy-Value $q.rateLimits; $spark.limitId='codex_bengalfox'; $spark.primary.windowDurationMins=300; $q | Add-Member NoteProperty rateLimitsByLimitId ([pscustomobject]@{ codex=$q.rateLimits; codex_bengalfox=$spark }); $b=ConvertTo-CodexBuckets $q $null $now; Assert ($b.codex_bengalfox.windows.'300'.remainingPercent -eq 90) }
    Check 'explicit secondary null is valid' { Assert ((ConvertTo-CodexBuckets (Fixture) $null $now).codex.status -eq 'observed') }
    Check 'missing secondary is unsupported' { $q=Fixture; $q.rateLimits.PSObject.Properties.Remove('secondary'); Assert ((ConvertTo-CodexBuckets $q $null $now).codex.status -eq 'unsupported') }
    Check 'swapped primary/secondary have equal meaning' { $q=Fixture; $q.rateLimits.secondary=$q.rateLimits.primary; $q.rateLimits.primary=$null; Assert ((ConvertTo-CodexBuckets $q $null $now).codex.windows.'10080'.usedPercent -eq 10) }
    foreach ($value in @(-1,101,'10',$true,[double]::NaN,[double]::PositiveInfinity)) {
        $bad=$value
        Check ('invalid percentage rejected: '+[string]$bad) { $q=Fixture; $q.rateLimits.primary.usedPercent=$bad; Assert ((ConvertTo-CodexBuckets $q $null $now).codex.status -eq 'unsupported') }
    }
    Check 'unknown duration rejected' { Assert ((ConvertTo-CodexBuckets (Fixture 10 60) $null $now).codex.status -eq 'unsupported') }
    Check 'duplicate duration rejected' { $q=Fixture; $q.rateLimits.secondary=Copy-Value $q.rateLimits.primary; Assert ((ConvertTo-CodexBuckets $q $null $now).codex.status -eq 'unsupported') }
    Check 'both null windows rejected' { $q=Fixture; $q.rateLimits.primary=$null; Assert ((ConvertTo-CodexBuckets $q $null $now).codex.status -eq 'unsupported') }
    Check 'blocked despite quota headroom' { $q=Fixture; $q.rateLimits.spendControlReached=$true; Assert ((ConvertTo-CodexBuckets $q $null $now).codex.status -eq 'blocked') }
    Check 'unknown spend constraint not ignored' { $q=Fixture; $q.rateLimits.spendControlReached=$null; Assert ((ConvertTo-CodexBuckets $q $null $now).codex.status -eq 'constraint_unknown') }
    Check 'server reached type blocks' { $q=Fixture; $q.rateLimits.rateLimitReachedType='workspace_owner_usage_limit_reached'; Assert ((ConvertTo-CodexBuckets $q $null $now).codex.status -eq 'blocked') }
    Check 'observed bucket carries no block reason' { Assert ($null -eq (ConvertTo-CodexBuckets (Fixture) $null $now).codex.blockReason) }
    Check 'exhausted quota with future reset is quota_exhausted' { $q=Fixture 100; $q.rateLimits.rateLimitReachedType='rate_limit_reached'; $b=ConvertTo-CodexBuckets $q $null $now; Assert ($b.codex.status -eq 'blocked'); Assert ($b.codex.blockReason -eq 'quota_exhausted') }
    Check 'spend control block is restricted' { $q=Fixture 100; $q.rateLimits.rateLimitReachedType='rate_limit_reached'; $q.rateLimits.spendControlReached=$true; $b=ConvertTo-CodexBuckets $q $null $now; Assert ($b.codex.status -eq 'blocked'); Assert ($b.codex.blockReason -eq 'restricted') }
    Check 'workspace owner limit is restricted' { $q=Fixture 100; $q.rateLimits.rateLimitReachedType='workspace_owner_usage_limit_reached'; $b=ConvertTo-CodexBuckets $q $null $now; Assert ($b.codex.status -eq 'blocked'); Assert ($b.codex.blockReason -eq 'restricted') }
    Check 'allowed=false is restricted even when exhausted' { $q=Fixture 100; $q.rateLimits.rateLimitReachedType='rate_limit_reached'; $q.rateLimits | Add-Member NoteProperty allowed $false; $b=ConvertTo-CodexBuckets $q $null $now; Assert ($b.codex.status -eq 'blocked'); Assert ($b.codex.blockReason -eq 'restricted') }
    Check 'reached type without a full window is restricted' { $q=Fixture 90; $q.rateLimits.rateLimitReachedType='rate_limit_reached'; $b=ConvertTo-CodexBuckets $q $null $now; Assert ($b.codex.status -eq 'blocked'); Assert ($b.codex.blockReason -eq 'restricted') }
    Check 'reached type with a past reset is restricted' { $q=Fixture 100 10080 ($now.ToUnixTimeSeconds()-1); $q.rateLimits.rateLimitReachedType='rate_limit_reached'; $b=ConvertTo-CodexBuckets $q $null $now; Assert ($b.codex.status -eq 'blocked'); Assert ($b.codex.blockReason -eq 'restricted') }
    Check 'reached type with a null reset is restricted' { $q=Fixture 100 10080 $null; $q.rateLimits.rateLimitReachedType='rate_limit_reached'; $b=ConvertTo-CodexBuckets $q $null $now; Assert ($b.codex.status -eq 'blocked'); Assert ($b.codex.blockReason -eq 'restricted') }
    Check 'quota_exhausted slot is never eligible or selected' {
        $q=Fixture 100; $q.rateLimits.rateLimitReachedType='rate_limit_reached'
        $b=ConvertTo-CodexBuckets $q $null $now; $b.codex.windows.'10080'.anchorState='observed-active'
        $s=[pscustomobject]@{ id='a'; label='a'; status='ok'; observedAt=$now.ToString('o'); buckets=$b; defaultModel='fixture-model'; modelProvider='openai' }
        Assert ((Get-CodexEligibility $s $policy codex $now) -ne 'eligible')
        Assert ((Select-CodexSlot @($s,(Make-Slot b)) $policy codex a $null $now) -eq 'b')
        Assert ($null -eq (Select-CodexSlot @($s) $policy codex a @{until=$now.AddHours(1)} $now))
    }
    Check 'missing reset differs from explicit null' { $q=Fixture; $q.rateLimits.primary.PSObject.Properties.Remove('resetsAt'); Assert ((ConvertTo-CodexBuckets $q $null $now).codex.status -eq 'unsupported'); $q=Fixture; $q.rateLimits.primary.resetsAt=$null; Assert ((ConvertTo-CodexBuckets $q $null $now).codex.status -eq 'observed') }
    Check 'fractional reset rejected' { $q=Fixture; $q.rateLimits.primary.resetsAt=12.5; Assert ((ConvertTo-CodexBuckets $q $null $now).codex.status -eq 'unsupported') }
    Check 'unrelated bucket never borrowed' { $q=Fixture; $q | Add-Member NoteProperty rateLimitsByLimitId ([pscustomobject]@{}); Assert ($null -eq (ConvertTo-CodexBuckets $q $null $now).codex) }
    Check 'used stationary reset needs separated evidence' { $q=Fixture; $b=ConvertTo-CodexBuckets $q $null $now; $next=ConvertTo-CodexBuckets $q $b ($now.AddSeconds(60)); Assert ($next.codex.windows.'10080'.anchorState -eq 'observed-active') }
    Check 'sliding reset is not active' { $q=Fixture 0; $b=ConvertTo-CodexBuckets $q $null $now; $q.rateLimits.primary.resetsAt+=60; $next=ConvertTo-CodexBuckets $q $b ($now.AddSeconds(60)); Assert ($next.codex.windows.'10080'.anchorState -eq 'unconfirmed') }
    Check 'quota reads never claim warming success' { $b=ConvertTo-CodexBuckets (Fixture 0 300) $null $now; Assert ($b.codex.warm -eq 'unmeasured') }
    Check 'soonest verified weekly reset wins' { $a=Make-Slot a 10 ($now.ToUnixTimeSeconds()+4000); $b=Make-Slot b 10 ($now.ToUnixTimeSeconds()+2000); Assert ((Select-CodexSlot @($a,$b) $policy codex '' $null $now) -eq 'b') }
    Check 'exhausted earliest-reset slot cannot win' { $a=Make-Slot a 100 ($now.ToUnixTimeSeconds()+500); $b=Make-Slot b; Assert ((Select-CodexSlot @($a,$b) $policy codex '' $null $now) -eq 'b') }
    Check 'reserve kept after work slots' { $p=Copy-Value $policy; $p.reserve=@('b'); $a=Make-Slot a; $b=Make-Slot b 10 ($now.ToUnixTimeSeconds()+1000); Assert ((Select-CodexSlot @($a,$b) $p codex '' $null $now) -eq 'a') }
    Check 'reserve weekly margin and work margin differ' { $p=Copy-Value $policy; $p.reserve=@('b'); Assert ((Get-CodexEligibility (Make-Slot a 90) $p codex $now) -eq 'eligible'); Assert ((Get-CodexEligibility (Make-Slot b 90) $p codex $now) -eq 'below_margin') }
    Check 'expired observation cannot grant refill' { Assert ((Get-CodexEligibility (Make-Slot a 0 ($now.ToUnixTimeSeconds()-1)) $policy codex $now) -eq 'reset_unconfirmed') }
    Check 'stale data ineligible' { $s=Make-Slot a; $s.observedAt=$now.AddSeconds(-901).ToString('o'); Assert ((Get-CodexEligibility $s $policy codex $now) -eq 'stale') }
    Check 'freshness exact boundary valid' { $s=Make-Slot a; $s.observedAt=$now.AddSeconds(-900).ToString('o'); Assert ((Get-CodexEligibility $s $policy codex $now) -eq 'eligible') }
    Check 'future timestamp rejected' { $s=Make-Slot a; $s.observedAt=$now.AddSeconds(60).ToString('o'); Assert ((Get-CodexEligibility $s $policy codex $now) -eq 'stale') }
    Check 'read failure does not use old success' { $s=Make-Slot a; $s.status='timeout'; Assert ((Get-CodexEligibility $s $policy codex $now) -eq 'timeout') }
    Check 'hold preserves eligible previous choice' { Assert ((Select-CodexSlot @((Make-Slot a),(Make-Slot b)) $policy codex b @{until=$now.AddHours(1)} $now) -eq 'b') }
    Check 'hold cannot make exhausted slot eligible' { Assert ($null -eq (Select-CodexSlot @((Make-Slot a),(Make-Slot b 100)) $policy codex b @{until=$now.AddHours(1)} $now)) }
    Check 'lead rule avoids near-reset oscillation' { $a=Make-Slot a 10 ($now.ToUnixTimeSeconds()+2000); $b=Make-Slot b 10 ($now.ToUnixTimeSeconds()+1800); Assert ((Select-CodexSlot @($a,$b) $policy codex a $null $now) -eq 'a') }
    Check 'ties follow explicit preference' { Assert ((Select-CodexSlot @((Make-Slot b),(Make-Slot a)) $policy codex '' $null $now) -eq 'a') }
    Check 'invalid duplicate homes rejected' { $p=Copy-Value $policy; $p.slots[1].home=$homeA; $threw=$false; try { Assert-CodexPolicy $p } catch { $threw=$true }; Assert $threw }
    Check 'invalid policy margins rejected' { $p=Copy-Value $policy; $p.margin5h='25'; $threw=$false; try { Assert-CodexPolicy $p } catch { $threw=$true }; Assert $threw }
    Check 'atomic replacement works repeatedly' { $path=Join-Path $dir 'atomic.txt'; Write-Hotpl8Text $path 'one'; Write-Hotpl8Text $path 'two'; Assert ([IO.File]::ReadAllText($path) -eq 'two') }
    Check 'locked file retains complete snapshot' { $path=Join-Path $dir 'locked.txt'; Write-Hotpl8Text $path 'old'; $lock=[IO.File]::Open($path,'Open','Read','None'); try { try { Write-Hotpl8Text $path 'new' } catch { } } finally { $lock.Dispose() }; Assert ([IO.File]::ReadAllText($path) -eq 'old') }
    $fake = Join-Path $dir 'fake codex.exe'
    Add-Type -Path (Join-Path $root 'tests/fake-codex.cs') -ReferencedAssemblies System.Web.Extensions -OutputAssembly $fake -OutputType ConsoleApplication
    # Diagnose the offline executable before interpreting transport failures as
    # product regressions. Only synthetic fixture stderr is safe to expose here.
    $smokeInfo=New-CodexProcessInfo $fake $homeA @('app-server') $dir
    $smokeInfo.RedirectStandardInput=$true;$smokeInfo.RedirectStandardOutput=$true;$smokeInfo.RedirectStandardError=$true
    $smokeInfo.CreateNoWindow=$true
    $smokeInfo.EnvironmentVariables['HOTPL8_TEST_SCENARIO']='ok'
    $smoke=$null
    try{
        $smoke=Start-CodexQuotaProcess $smokeInfo
        $smokeOut=$smoke.StandardOutput.ReadToEndAsync();$smokeError=$smoke.StandardError.ReadToEndAsync()
        $smoke.StandardInput.WriteLine('{"id":1,"method":"initialize"}');$smoke.StandardInput.Close()
        if(-not $smoke.WaitForExit(10000)){throw 'Offline fixture startup timed out.'}
        if($smoke.ExitCode -ne 0){throw ('Offline fixture startup failed ('+$smoke.ExitCode+'): '+$smokeError.Result)}
        Assert (($smokeOut.Result|ConvertFrom-Json).id -eq 1) 'Offline fixture produced no initialization response.'
    }finally{Stop-Hotpl8Process $smoke}
    Check 'UTF-8 console cannot add a pipe BOM or corrupt a Unicode home' {
        $original=[Console]::InputEncoding
        $unicodeHome=Join-Path $dir ('home-'+[char]0x00e9)
        [void][IO.Directory]::CreateDirectory($unicodeHome)
        try{
            [Console]::InputEncoding=[Text.Encoding]::UTF8
            $env:HOTPL8_TEST_SCENARIO='ok'
            $r=Read-CodexQuota $unicodeHome $fake 5000
            Assert ($r.status -eq 'ok') $r.status
            Assert ([Console]::InputEncoding.GetPreamble().Length -eq 3) 'Console encoding was not restored.'
        }finally{[Console]::InputEncoding=$original}
    }
    foreach ($scenario in @('ok','notify','stderr')) {
        $env:HOTPL8_TEST_SCENARIO=$scenario
        Check ('native transport '+$scenario) { $r=Read-CodexQuota $homeA $fake 3000; Assert ($r.status -eq 'ok') $r.status; Assert ($r.model -eq 'fixture-model'); Assert (-not ($r | ConvertTo-Json -Depth 12).Contains('@example.invalid')) }
    }
    foreach ($pair in @(@('noauth','subscription_login_required'),@('401','authentication_required'),@('403','access_denied'),@('429','rate_limited'),@('invalid','invalid_json'),@('exit','process_exited'),@('hang','timeout'),@('partial','timeout'))) {
        $env:HOTPL8_TEST_SCENARIO=$pair[0]
        Check ('transport failure '+$pair[0]) {
            # Error classification needs time to start the fixture on a busy host.
            # Only deliberately stalled processes test the short timeout contract.
            $budget=if($pair[1] -eq 'timeout'){500}else{3000}
            $r=Read-CodexQuota $homeA $fake $budget
            Assert ($r.status -eq $pair[1]) $r.status
            Assert ($r.elapsedMs -lt ($budget+2000))
            Assert (-not ($r | ConvertTo-Json).Contains('SECRET_DO_NOT_LOG'))
        }
    }
    $env:HOTPL8_TEST_SCENARIO='ok'
    Check 'collection includes two independent configured homes' { $c=Invoke-CodexCollection $policy $dir $fake $null $null; Assert ($c.slots.Count -eq 2); Assert ($c.recommendedSlot -eq 'a'); Assert (-not ($c | ConvertTo-Json -Depth 20).Contains('identityKey')) }
    Check 'custom transport and provider cannot earn a subscription recommendation' {
        foreach($scenario in @('custom-endpoint','custom-provider')) {
            $env:HOTPL8_TEST_SCENARIO=$scenario
            try {
                $c=Invoke-CodexCollection $policy $dir $fake $null $null
                Assert ($null -eq $c.recommendedSlot)
                Assert (@($c.slots|Where-Object status -EQ unsupported_configuration).Count -eq 2)
            } finally { $env:HOTPL8_TEST_SCENARIO='ok' }
        }
    }
    Check 'last-good snapshot keeps its age on read failure' { $first=Read-Hotpl8Json (Join-Path $dir 'codex-state.json'); $env:HOTPL8_TEST_SCENARIO='401'; $c=Invoke-CodexCollection $policy $dir $fake $null $null; Assert (($c.slots | Where-Object id -EQ a).observedAt -eq $first.slots.a.lastSuccessAt) ('age changed: ' + ($c.slots | Where-Object id -EQ a).observedAt + ' vs ' + $first.slots.a.lastSuccessAt); Assert ($null -eq $c.recommendedSlot) ('recommended ' + $c.recommendedSlot) }
    $env:HOTPL8_TEST_SCENARIO='ok'
    $status=[pscustomobject]@{observedAt=$now.ToString('o');recommendations=[pscustomobject]@{codex='a'};slots=@((Make-Slot a),(Make-Slot b))}
    Check 'cached display rejects stale and newly exhausted recommendations without rewriting data' {
        $s=Copy-Value $status; $s|Add-Member NoteProperty recommendedSlot a; $s|Add-Member NoteProperty defaultMeter codex
        $s.slots[0].observedAt=$now.AddHours(-1).ToString('o')
        $text=(Format-CodexStatus $s $policy $now)-join "`n"
        Assert ($text.Contains('next launch = unavailable')); Assert ($text.Contains('stale'))
        Assert ($s.recommendedSlot -eq 'a'); Assert ($s.slots[0].status -eq 'ok')
        $s.slots[0]=Make-Slot a 100
        Assert (((Format-CodexStatus $s $policy $now)-join "`n").Contains('next launch = unavailable'))
        $s.slots[0]=Make-Slot a
        Assert (((Format-CodexStatus $s $policy $now)-join "`n").Contains('next launch = a'))
    }
    Check 'automatic launch chooses recommended account' { $p=Get-CodexLaunchPlan $policy $status '' '' @() $now; Assert ($p.slot.id -eq 'a'); Assert $p.automatic }
    Check 'stale automatic launch rejected' { $s=Copy-Value $status; $s.observedAt=$now.AddHours(-1).ToString('o'); $threw=$false; try { Get-CodexLaunchPlan $policy $s '' '' @() $now | Out-Null } catch { $threw=$true }; Assert $threw }
    Check 'explicit launch works without cached recommendation' { $p=Get-CodexLaunchPlan $policy $null b '' @() $now; Assert ($p.slot.id -eq 'b'); Assert (-not $p.automatic) }
    Check 'resume requires owning slot' { $threw=$false; try { Get-CodexLaunchPlan $policy $status '' '' @('resume','abc') $now | Out-Null } catch { $threw=$true }; Assert $threw }
    Check 'resume explicit owner retained' { $p=Get-CodexLaunchPlan $policy $status b '' @('resume','abc') $now; Assert ($p.slot.id -eq 'b'); Assert ($p.arguments[0] -eq 'resume') }
    Check 'unknown model cannot borrow default meter' { $threw=$false; try { Get-CodexLaunchPlan $policy $status '' unknown @() $now | Out-Null } catch { $threw=$true }; Assert $threw }
    Check 'API auth override detected without printing secret' { $env:OPENAI_API_KEY='SECRET_DO_NOT_LOG'; try { $threw=$false; try { Get-CodexLaunchPlan $policy $status '' '' @() $now | Out-Null } catch { $threw=$true; Assert (-not $_.Exception.Message.Contains('SECRET_DO_NOT_LOG')) }; Assert $threw } finally { $env:OPENAI_API_KEY=$null } }
    Check 'native config override cannot bypass quota choice' { $threw=$false; try { Get-CodexLaunchPlan $policy $status a '' @('--config=model_provider="other"') $now | Out-Null } catch { $threw=$true }; Assert $threw }
    Check 'native argument quoting and child home preserved' {
        $env:HOTPL8_TEST_LAUNCH=Join-Path $dir 'launch.json'
        $argsToTest=@('a b','a"b','C:\ends with slash\','', '$literal', 'x&y', 'semi;colon', 'Unicode: Ω中')
        $p=Get-CodexLaunchPlan $policy $status b '' $argsToTest $now
        $original=$env:CODEX_HOME
        $code=Invoke-Hotpl8Codex $p $dir $fake $homeA
        $record=Read-Hotpl8Json $env:HOTPL8_TEST_LAUNCH
        Assert ($code -eq 7); Assert ($record.home -eq $homeB); Assert ($record.cwd -eq $homeA); Assert ($env:CODEX_HOME -eq $original)
        $actual=@($record.args | Select-Object -Skip 2)
        Assert ($actual.Count -eq $argsToTest.Count) ('argument count '+$actual.Count)
        for ($i=0; $i -lt $actual.Count; $i++) { Assert ($actual[$i] -ceq $argsToTest[$i]) ('argument '+$i) }
    }
    Check 'pure Codex hook is bounded and does not collect' {
        $payload=@{ generatedAt=$now.ToString('o'); active=0; slots=@(); providers=@{ codex=$status } }
        Write-Hotpl8Text (Join-Path $dir 'policy.json') (@{codex=$policy}|ConvertTo-Json -Depth 12)
        Write-Hotpl8Text (Join-Path $dir 'status.json') ($payload|ConvertTo-Json -Depth 24)
        $env:HOTPL8_SLOT='a'; $env:HOTPL8_METER='codex'; $env:HOTPL8_STATE_DIRECTORY=$dir
        $out=& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'status-print.ps1') -Provider codex -StateDirectory $dir
        $obj=$out|ConvertFrom-Json
        Assert ($obj.hookSpecificOutput.hookEventName -eq 'SessionStart'); Assert ($out.Length -lt 4000)
        $savedHome=$env:CODEX_HOME
        try {
            $env:HOTPL8_SLOT=$null; $env:HOTPL8_METER=$null; $env:CODEX_HOME=$homeA
            $direct=& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'status-print.ps1') -Provider codex -StateDirectory $dir
            $directObj=$direct|ConvertFrom-Json
            Assert ($directObj.hookSpecificOutput.additionalContext.Contains('"boundSlot":"a"'))
        } finally { $env:CODEX_HOME=$savedHome }
        $env:HOTPL8_SLOT=$null; $env:HOTPL8_METER=$null; $env:HOTPL8_STATE_DIRECTORY=$null
    }
    Check 'real tick publishes Codex without cswap' {
        $p=@{codex=$policy}; Write-Hotpl8Text (Join-Path $dir 'policy.json') ($p|ConvertTo-Json -Depth 12)
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tick.ps1') -StateDirectory $dir -CswapExecutable (Join-Path $dir 'absent.exe') -CodexExecutable $fake
        $actual=Read-Hotpl8Json (Join-Path $dir 'status.json')
        Assert ($actual.providers.codex.slots.Count -eq 2); Assert ($actual.schemaVersion -eq 2); Assert ($actual.slots.Count -eq 0)
        Assert (([IO.File]::ReadAllText((Join-Path $dir 'status.js'))).StartsWith('window.CSWAP = '))
    }
    Check 'per-home lock prevents overlapping native readers' {
        $lockPath=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-codex-'+(Get-Hotpl8Hash ([IO.Path]::GetFullPath($homeA).ToLowerInvariant()))+'.lock')
        $lock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')
        try { $r=Read-CodexQuota $homeA $fake 1000;Assert ($r.status -eq 'home_busy') } finally { $lock.Dispose() }
    }
    Check 'same subscription in two homes is not double capacity' {
        $env:HOTPL8_TEST_SCENARIO='same-account'
        try { $c=Invoke-CodexCollection $policy $dir $fake $null $null;Assert ($null -eq $c.recommendedSlot);Assert (@($c.slots|Where-Object status -EQ duplicate_subscription).Count -eq 2) } finally {$env:HOTPL8_TEST_SCENARIO='ok'}
    }
    Check 'setup preserves Claude policy and unrelated hooks; repeat is idempotent' {
        $configDir=Join-Path $dir 'setup';New-Item -ItemType Directory $configDir|Out-Null
        Write-Hotpl8Text (Join-Path $configDir 'policy.json') '{"prefer":[3,2,1],"warm":true}'
        Write-Hotpl8Text (Join-Path $homeA 'hooks.json') '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo existing"}]}]}}'
        $setupArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'setup-codex.ps1'),'-Slot','a','-AccountHome',$homeA,'-StateDirectory',$configDir,'-CodexExecutable',$fake,'-Model','fixture-model','-InstallHook')
        & powershell @setupArgs | Out-Null;Assert ($LASTEXITCODE -eq 0)
        & powershell @setupArgs | Out-Null;Assert ($LASTEXITCODE -eq 0)
        $p=Read-Hotpl8Json (Join-Path $configDir 'policy.json');$h=Read-Hotpl8Json (Join-Path $homeA 'hooks.json')
        Assert ($p.prefer.Count -eq 3);Assert $p.warm;Assert ($p.codex.slots.Count -eq 1);Assert ($h.hooks.Stop[0].hooks[0].command -eq 'echo existing');Assert ($h.hooks.SessionStart.Count -eq 1);Assert ([IO.File]::ReadAllBytes((Join-Path $homeA 'hooks.json'))[0] -eq 123)
    }
    Check 'enroll command validates the native home and preserves monitoring on repeat' {
        $enrollment=Join-Path $dir 'cli enrollment';New-Item -ItemType Directory $enrollment|Out-Null
        Copy-Item (Join-Path $root 'policy.example.json') (Join-Path $enrollment 'policy.json')
        $arguments=@('enroll','-Slot','main','-AccountHome',$homeA,'-Label','Everyday','-StateDirectory',$enrollment,'-CodexExecutable',$fake)
        foreach($attempt in 1..2){
            $out=& (Join-Path $root 'hotpl8.cmd') @arguments
            Assert ($LASTEXITCODE -eq 0) ($out -join ' ')
            Assert (($out -join ' ').Contains('Next: hotpl8 refresh'))
        }
        $saved=Read-Hotpl8Json (Join-Path $enrollment 'policy.json')
        Assert ($saved.codex.slots.Count -eq 1 -and $saved.codex.slots[0].home -eq $homeA)
        Assert ($saved.codex.slots[0].label -eq 'Everyday' -and $saved.mode -eq 'monitor' -and -not $saved.warm)
        Assert (-not (Test-Path (Join-Path $enrollment 'auth.json')))
    }
    Check 'automatic native launch rechecks the real binding' {
        $c=Invoke-CodexCollection $policy $dir $fake $null $null
        $p=Get-CodexLaunchPlan $policy $c '' '' @('test') ([datetimeoffset]::UtcNow)
        $env:HOTPL8_TEST_LAUNCH=Join-Path $dir 'auto-launch.json'
        Assert ((Invoke-Hotpl8Codex $p $dir $fake $homeA) -eq 7)
        $record=Read-Hotpl8Json $env:HOTPL8_TEST_LAUNCH; Assert ($record.home -eq $p.slot.home)
    }
    Check 'Windows command shim launches the selected home and preserves exit code' {
        $env:HOTPL8_TEST_LAUNCH=Join-Path $dir 'cmd-launch.json'
        & (Join-Path $root 'hotpl8.cmd') codex -Slot a -StateDirectory $dir -CodexExecutable $fake exec --json 'fixture prompt'
        Assert ($LASTEXITCODE -eq 7)
        $record=Read-Hotpl8Json $env:HOTPL8_TEST_LAUNCH
        Assert ($record.home -eq $homeA); Assert ($record.cwd -eq (Get-Location).Path)
        Assert (($record.args -join '|') -eq '--model|fixture-model|exec|--json|fixture prompt')
    }
    Check 'binding changed since collection prevents automatic dispatch' {
        $c=Invoke-CodexCollection $policy $dir $fake $null $null
        $p=Get-CodexLaunchPlan $policy $c '' '' @('test') ([datetimeoffset]::UtcNow)
        $state=Read-Hotpl8Json (Join-Path $dir 'codex-state.json');$state.slots.($p.slot.id).identityKey='different'
        Write-Hotpl8Text (Join-Path $dir 'codex-state.json') ($state|ConvertTo-Json -Depth 24)
        $threw=$false;try{Invoke-Hotpl8Codex $p $dir $fake $homeA|Out-Null}catch{$threw=$true};Assert $threw
    }
    Check 'remote endpoint override rejected by launcher' { $threw=$false;try{Get-CodexLaunchPlan $policy $status a '' @('--remote=ws://other') $now|Out-Null}catch{$threw=$true};Assert $threw }
    Check 'five-hour and weekly guards both apply' {
        $q=Fixture 10 300;$q.rateLimits.secondary=(Fixture 99).rateLimits.primary
        $slot=Make-Slot a;$slot.buckets=ConvertTo-CodexBuckets $q $null $now
        Assert ((Get-CodexEligibility $slot $policy codex $now) -eq 'below_margin')
    }
    Check 'quota observation history contains no private identity' {
        $history=Get-Content -LiteralPath (Join-Path $dir 'codex-observations.jsonl') -Raw -Encoding UTF8
        Assert ($history.Contains('observedAt'));Assert (-not $history.Contains('identityKey'));Assert (-not $history.Contains('@example.invalid'))
    }
    Check 'empty Codex section contributes nothing' {
        $empty=Join-Path $dir 'empty-section';New-Item -ItemType Directory $empty|Out-Null
        Write-Hotpl8Text (Join-Path $empty 'policy.json') '{"codex":{}}'
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tick.ps1') -StateDirectory $empty -CodexExecutable $fake
        Assert (-not (Test-Path -LiteralPath (Join-Path $empty 'status.json')))
    }
    Check 'PowerShell -File entrypoints resolve default state directory' {
        $entry=Join-Path $dir 'entry';New-Item -ItemType Directory -Path $entry|Out-Null
        Copy-Item (Join-Path $root 'src') $entry -Recurse
        foreach($name in @('hotpl8.ps1','setup-codex.ps1','VERSION')) {Copy-Item (Join-Path $root $name) $entry}
        Write-Hotpl8Text (Join-Path $entry 'policy.json') '{"prefer":[3,2,1],"warm":true}'
        $output=& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $entry 'hotpl8.ps1') status
        Assert ($LASTEXITCODE -eq 0);Assert ($output -like '*No cached status*')
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $entry 'setup-codex.ps1') -Slot a -AccountHome $homeA -CodexExecutable $fake | Out-Null
        Assert ($LASTEXITCODE -eq 0);Assert ((Read-Hotpl8Json (Join-Path $entry 'policy.json')).codex.slots.Count -eq 1)
    }
    Check 'collection budget is bounded and unpolled homes get the next turn' {
        $budgetDir=Join-Path $dir 'budget';New-Item -ItemType Directory $budgetDir|Out-Null
        $large=Copy-Value $policy;$large.slots=@();$large.prefer=@()
        foreach($n in 0..5){$h=Join-Path $dir ('budget-home-'+$n);New-Item -ItemType Directory $h|Out-Null;$id='s'+$n;$large.slots+=@([pscustomobject]@{id=$id;home=$h});$large.prefer+=@($id)}
        $env:HOTPL8_TEST_SCENARIO='hang'
        try {
            $clock=[Diagnostics.Stopwatch]::StartNew();$first=Invoke-CodexCollection $large $budgetDir $fake $null $null
            Assert ($clock.ElapsedMilliseconds -lt 25000) ('collection elapsed '+$clock.ElapsedMilliseconds)
            $unpolled=@($first.slots|Where-Object status -EQ collection_budget|ForEach-Object{$_.id});Assert ($unpolled.Count -gt 0)
            $second=Invoke-CodexCollection $large $budgetDir $fake $first $null
            foreach($id in $unpolled){Assert (($second.slots|Where-Object id -EQ $id).status -ne 'collection_budget') ('starved '+$id)}
        } finally {$env:HOTPL8_TEST_SCENARIO='ok'}
    }
    Check 'out-of-range Unix reset is unsupported' {
        foreach($reset in @(1e100,253402300800)){ $q=Fixture;$q.rateLimits.primary.resetsAt=$reset;Assert ((ConvertTo-CodexBuckets $q $null $now).codex.status -eq 'unsupported') }
    }
    Check 'removing Codex configuration restores Claude-only operation' {
        $rollback=Join-Path $dir 'rollback';New-Item -ItemType Directory $rollback|Out-Null
        $stub=Join-Path $rollback 'cswap.cmd'
        [IO.File]::WriteAllText($stub,"@echo off`r`ntype `"%HOTPL8_TEST_CLAUDE_FIXTURE%`"`r`nexit /b 0`r`n")
        $env:HOTPL8_TEST_CLAUDE_FIXTURE=Join-Path $rollback 'claude.json'
        $u=@{pct=10;resetsAt=$now.AddHours(2).ToString('o')}
        $fixture=@{activeAccountNumber=1;accounts=@(@{number=1;active=$true;usageStatus='ok';usageAgeSeconds=0;usage=@{fiveHour=$u;sevenDay=$u}})}
        Write-Hotpl8Text $env:HOTPL8_TEST_CLAUDE_FIXTURE ($fixture|ConvertTo-Json -Depth 10)
        $p=[pscustomobject]@{prefer=@(1);margin5h=25;margin7d=20;hysteresis=10;warm=$false;codex=$policy}
        Write-Hotpl8Text (Join-Path $rollback 'policy.json') ($p|ConvertTo-Json -Depth 12)
        $tickArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'tick.ps1'),'-StateDirectory',$rollback,'-CswapExecutable',$stub,'-CodexExecutable',$fake)
        & powershell @tickArgs|Out-Null
        $before=Read-Hotpl8Json (Join-Path $rollback 'status.json');Assert ($before.providers.codex.slots.Count -eq 2)
        $historyHash=(Get-FileHash -LiteralPath (Join-Path $rollback 'codex-observations.jsonl')).Hash
        $p.PSObject.Properties.Remove('codex');Write-Hotpl8Text (Join-Path $rollback 'policy.json') ($p|ConvertTo-Json -Depth 12)
        & powershell @tickArgs|Out-Null
        $after=Read-Hotpl8Json (Join-Path $rollback 'status.json')
        Assert ($null -eq $after.providers);Assert ($after.active -eq $before.active);Assert ($after.slots[0].used5h -eq $before.slots[0].used5h)
        Assert ((Get-FileHash -LiteralPath (Join-Path $rollback 'codex-observations.jsonl')).Hash -eq $historyHash)
        $env:HOTPL8_TEST_CLAUDE_FIXTURE=$null
    }
    Check 'missing policy means no writes or process' { $empty=Join-Path $dir 'empty'; New-Item -ItemType Directory $empty|Out-Null; & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tick.ps1') -StateDirectory $empty -CodexExecutable $fake; Assert (@(Get-ChildItem -LiteralPath $empty).Count -eq 0) }
    Check 'tick lock prevents overlapping collection' {
        $before=(Get-FileHash -LiteralPath (Join-Path $dir 'status.json')).Hash
        $lock=[IO.File]::Open((Join-Path $dir 'tick.lock'),'OpenOrCreate','ReadWrite','None')
        try { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tick.ps1') -StateDirectory $dir -CodexExecutable $fake } finally { $lock.Dispose() }
        Assert ((Get-FileHash -LiteralPath (Join-Path $dir 'status.json')).Hash -eq $before)
    }
} finally {
    $env:HOTPL8_TEST_SCENARIO=$oldScenario; $env:HOTPL8_TEST_LAUNCH=$oldLaunch
    foreach ($key in $clearedEnv.Keys) { [Environment]::SetEnvironmentVariable($key,$clearedEnv[$key]) }
    $resolved=[IO.Path]::GetFullPath($dir)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $resolved -Leaf) -like 'hotpl8-test-*') { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
'passed=' + $script:passed + ' failed=' + $script:failed
if ($script:failed) { exit 1 }
