# Claude adapter. Historical incident comments and behavior retained from tick.ps1.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'provider-observation.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'provider-actions.ps1')
. (Join-Path $PSScriptRoot 'claude-plans.ps1')
function Get-ClaudeModelBlock($Scopes,$Policy,[int]$Slot,[datetimeoffset]$Now=[datetimeoffset]::UtcNow,$ObservedAt=$null) {
    if(-not @($Policy.claudeModels|Where-Object {$_}).Count){return $null}
    $stamp=if($ObservedAt){$ObservedAt}else{$Now.ToString('o')}
    $windows=@(foreach($model in @($Policy.claudeModels|Where-Object {$_})){
        $matches=@($Scopes|Where-Object name -CEQ $model);$scope=if($matches.Count -eq 1){$matches[0]}else{$null}
        [pscustomobject]@{name=[string]$model;scope=[string]$model;role='scoped';state=$(if($scope){'observed'}else{'unknown'});required=$true;usedPercent=$scope.pct;resetAt=$scope.resetsAt;observedAt=$stamp;resetConfirmed=[bool]$scope.resetsAt;resetRequired=$true}
    })
    $decision=Get-Hotpl8ProviderDecision @(@{id=[string]$Slot;status='ok';observedAt=$stamp;windows=$windows}) $Policy @{intent='observe';eligibilityOnly=$true} $Now
    $reason=$decision.accounts[0].reason
    if($reason -eq 'eligible'){return $null}
    if($reason -eq 'below_margin'){return 'model_below_margin'}
    if($reason -eq 'reset_unconfirmed'){return 'model_reset_unconfirmed'}
    return 'model_quota_unknown'
}
function Test-Ok($e, $m, $margin7d) {
    # Compatibility for already-evaluated headroom. Raw native observations use
    # ConvertTo-Hotpl8ClaudeObservation so original timestamps remain authoritative.
    $now=[datetimeoffset]::UtcNow
    $windows=@(foreach($shape in @(@('300','short','h5'),@('10080','weekly','h7'))){
        [pscustomobject]@{name=$shape[0];scope='';role=$shape[1];state='observed';required=$true;usedPercent=$(if(Test-Hotpl8Number $e.($shape[2])){100-[double]$e.($shape[2])}else{$null});resetAt=$null;observedAt=$now.ToString('o');resetConfirmed=$false}
    })
    $account=@{id='headroom';status=$(if($e.fresh){'ok'}else{'stale'});observedAt=$now.ToString('o');windows=$windows;blockedReason=$(if($e.modelBlocked){'model_quota_unknown'}else{$null})}
    $decision=Get-Hotpl8ProviderDecision @($account) @{margin5h=$m;margin7d=$margin7d} @{intent='observe';eligibilityOnly=$true} $now
    return $decision.accounts[0].eligible
}
function Get-Margin7dFor($policy, $n) {
    Get-Hotpl8ProviderMargin $policy @{reserve=([string]$n -in @($policy.reserve|ForEach-Object {[string]$_}))} @{role='weekly'}
}

function Get-Hold($dir) {
    # A long unattended job that drives switching itself needs the tick to stop
    # switching underneath it. The obvious shape -- flip a durable "disabled" flag,
    # clear it when the job finishes -- is WRONG, and the reason is worth stating:
    # the failure that matters is the job dying BEFORE it can undo the flag, and a
    # cleanup step only executes on the one path where nothing went wrong. Crash,
    # rate limit, machine freeze, power button: every one of them skips the undo and
    # strands rotation off, silently, with nothing left running that could notice.
    #
    # So the hold is a LEASE. It carries its own expiry and lapses with nobody
    # present. Recovery requires no job, no cleanup step and no human.
    #
    # Fails OPEN on every ambiguity -- absent file, unreadable file, malformed JSON,
    # missing or unparseable `until`, already expired. A corrupt hold.json must never
    # be able to mean "held forever", because that is precisely the trap this shape
    # exists to remove.
    $p = Join-Path $dir 'hold.json'
    if (-not (Test-Path $p)) { return $null }
    try {
        # -Raw, always: line-mode Get-Content hands ConvertFrom-Json an array and
        # 5.1 will silently make something unhelpful of it.
        # Only `until` and `reason` are read. Unknown keys are ignored on purpose,
        # so a holder can carry its own fields (scope, owner, whatever it needs its
        # OTHER consumers to see) in the same file without this script growing a
        # dependency on them.
        $h = Get-Content $p -Raw | ConvertFrom-Json
        if (-not $h.until) { return $null }
        $u = [datetimeoffset]::Parse([string]$h.until)
        if ($u -le [datetimeoffset]::UtcNow) { return $null }   # lapsed -> normal service
        $r = if ($h.reason) { [string]$h.reason } else { 'hold' }
        return @{ until = $u; reason = $r }
    } catch { return $null }
}

function Get-ResetEpoch($a) {
    # Unix seconds of this account's 5h reset, or $null when the slot is COLD.
    if (-not $a.usage.fiveHour -or [string]::IsNullOrWhiteSpace([string]$a.usage.fiveHour.resetsAt)) { return $null }
    try { return ([datetimeoffset]::Parse([string]$a.usage.fiveHour.resetsAt)).ToUnixTimeSeconds() } catch { return $null }
}

function Get-RankedOrder($policy, $prefer, $acc, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    $decision=Get-ClaudeProviderDecision $policy $prefer $acc 0 $Now
    return @($decision.allRanked|ForEach-Object {[int]$_})
}

function Get-CswapReadTimeoutMs {
    # How long `cswap list --json` may run before this script kills it. The read
    # renews any stored token that has expired, and that grant is single-use:
    # killing cswap after its request left but before the reply is saved retires
    # the slot's only token. So this must outlast the longest road cswap takes to
    # a saved reply. A renewal waits up to 10 s for the slot lock and then for the
    # reply (10 s through 0.26.0, 30 s where oauth.OAUTH_REFRESH_TIMEOUT_S exists).
    # When the first one gets no reply, cswap asks for usage with the expired
    # token (5 s), is refused and renews once more: 10+30 + 5 + 10+30 = 85 s.
    # The old 20 s sat inside the first of those waits.
    return 90000
}

function Resolve-CswapExecutable([string]$CswapExecutable) {
    # Resolve cswap explicitly. A launchd agent's PATH excludes ~/.local/bin.
    # Probe common installation locations without requiring a particular
    # workstation layout; explicit executable bindings always take precedence.
    $cswap = $CswapExecutable
    if(-not $cswap -and $env:HOTPL8_NATIVE_BIN){
        $owned=Join-Path $env:HOTPL8_NATIVE_BIN $(if($env:OS -eq 'Windows_NT'){'cswap.exe'}else{'cswap'})
        if(Test-Path -LiteralPath $owned -PathType Leaf){$cswap=$owned}
    }
    if (-not $cswap) { foreach ($c in @((Join-Path $HOME '.local/bin/cswap'), '/usr/local/bin/cswap')) {
        if (Test-Path $c) { $cswap = $c; break }
    }
    }
    if (-not $cswap) { $cswap = (Get-Command cswap -ErrorAction SilentlyContinue).Source }
    # Windows last-resort: pip drops cswap.exe in Python's Scripts dir, which a
    # Scheduled Task's environment does not reliably carry on PATH. Resolve by GLOB
    # and never pin a Python version: upgrading Python must not strand the
    # collector on a removed executable path.
    if (-not $cswap -and $env:LOCALAPPDATA) {
        $cswap = (Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python*\Scripts\cswap.exe') -ErrorAction SilentlyContinue |
                  Sort-Object FullName -Descending | Select-Object -First 1).FullName
    }
    if (-not $cswap -and $env:APPDATA) {
        $cswap = (Get-ChildItem -Path (Join-Path $env:APPDATA 'Python\Python*\Scripts\cswap.exe') -ErrorAction SilentlyContinue |
                  Sort-Object FullName -Descending | Select-Object -First 1).FullName
    }
    return $cswap
}
function Get-ClaudeProviderDecision($Policy,$Prefer,$Accounts,[int]$Active,[datetimeoffset]$Now,$CriticalState=$null,$Context=$null) {
    # Legacy Claude omitted these fields as zero. Registered views already carry
    # descriptor defaults; preserve explicit values without mutating either input.
    $decisionPolicy=@{}
    if($Policy -is [Collections.IDictionary]){foreach($key in $Policy.Keys){$decisionPolicy[$key]=$Policy[$key]}}
    else{foreach($property in $Policy.PSObject.Properties){$decisionPolicy[$property.Name]=$property.Value}}
    foreach($key in @('margin5h','hysteresis')){if($null -eq $decisionPolicy[$key]){$decisionPolicy[$key]=0}}
    $observations=@(foreach($id in $Prefer){ConvertTo-Hotpl8ClaudeEntryObservation $id $Accounts[[int]$id] $Policy $Now -ForWarm:($Context.intent -eq 'warm' -and [string]$id -ceq [string]$Context.actionSlot)})
    $slots=@(foreach($id in $Prefer){$e=$Accounts[[int]$id];[pscustomobject]@{slot=$id;status=$(if($e.fresh -and -not $e.modelBlocked){'ok'}else{'unavailable'});fresh=[bool]$e.fresh;observedAt=$(if($e.observedAt){$e.observedAt}else{$Now.ToString('o')});used5h=$(if(Test-Hotpl8Number $e.h5){100-$e.h5}else{$null});used7d=$(if(Test-Hotpl8Number $e.h7){100-$e.h7}else{$null});reset5h=$e.obj.usage.fiveHour.resetsAt;reset7d=$e.obj.usage.sevenDay.resetsAt;scoped=$e.obj.usage.scoped}})
    $capacity=@(Get-Hotpl8CapacityAccounts ([pscustomobject]@{slots=$slots}) $Policy 'claude' $Now)
    $observations=@(Add-Hotpl8ObservationCapacity $observations $capacity)
    if(-not $Context){$Context=@{intent='observe';previousId=[string]$Active;bindingKnown=($Active -gt 0);criticalState=$CriticalState}}
    Get-Hotpl8ProviderDecision $observations $decisionPolicy $Context $Now
}
function Get-ClaudeSelection($policy, $prefer, $acc, [int]$active, [datetimeoffset]$Now = [datetimeoffset]::UtcNow, $CriticalState=$null) {
    $decision=Get-ClaudeProviderDecision $policy $prefer $acc $active $Now $CriticalState
    $target=if($decision.proposedSlot -and $decision.proposedSlot -ne [string]$active){[int]$decision.proposedSlot}else{$null}
    return @{target=$target;activeOk=(@($decision.accounts|Where-Object {$_.id -eq [string]$active -and $_.eligible}).Count -eq 1);ranked=@($(if($decision.critical.active){$decision.ranked}else{$decision.allRanked})|ForEach-Object {[int]$_});critical=$decision.critical;decision=$decision}
}
