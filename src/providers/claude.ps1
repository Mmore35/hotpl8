# Claude adapter. Historical incident comments and behavior retained from tick.ps1.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'warming.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'forecast.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'selection.ps1')
function Test-Ok($e, $m, $margin7d) {
    if ($null -eq $e) { return $false }
    if ($e.modelBlocked) { return $false }
    if (-not $e.fresh) { return $false }          # stale/unknown usage is never eligible
    if ($null -eq $e.h5) { return $false }
    if ($e.h5 -lt $m) { return $false }
    # 7d absent => UNKNOWN, and unknown is ineligible. THIS RULE FLIPPED ON 2026-08-20;
    # read both halves before changing it back.
    #
    # Until then the opposite was correct: slot 2 genuinely had NO 7-day ceiling --
    # confirmed by the owner 2026-08-14 against Claude's own UI, where slots 1 and 3
    # showed theirs and slot 2 showed none anywhere -- so absent was a fact about the
    # account, not a gap in our reading, and failing closed would have demoted the one
    # account most worth draining. That was written up as a bug and reverted; see
    # me/deep-dive/CSWAP-OPERATING-RULES.md, "SECOND BUG ... RESOLVED -- NOT A BUG".
    #
    # On 2026-08-20 the owner confirmed Anthropic patched that glitch and slot 2 gained a
    # weekly window. Verified the same day against `cswap list --json`: all three accounts
    # report a real sevenDay pct and resetsAt. Absent therefore no longer describes any
    # account he owns -- it can only mean the reading failed -- and spending an unknown
    # weekly budget optimistically is how the fleet lands on an exhausted account.
    #
    # The `fresh` check above does NOT already cover this: fresh means the usage blob is
    # recent, not that both windows are present in it.
    # Kept deliberately in step with ops-bot's slots.ps1 Test-SlotUsable, which made the
    # same flip on the same day -- two engines, one rule.
    if ($null -eq $e.h7) { return $false }
    if ($e.h7 -lt $margin7d) { return $false }
    return $true
}

function Get-Margin7dFor($policy, $n) {
    # The weekly buffer is RESERVE-ONLY as of 2026-08-28. Work slots drain to
    # `margin7dWork` (5 => 95% used); the reserve keeps `margin7d` (20 => 80%).
    #
    # The buffer exists to leave capacity for coming back to. The fleet already
    # holds that on ONE slot -- `reserve`, which is what the label means -- so
    # applying the same 20% to every slot reserves the same thing three times.
    # Measured 2026-08-27: slots 2 and 3 sat at 88%/84% weekly with 28% of the
    # week's budget refused, slot 3 idle with 64% of its 5h window free, while
    # slot 1 (reserve) had 78% of its week untouched. A 7d window is
    # use-it-or-lose-it against a fixed calendar reset -- unspent quota
    # evaporates, it does not bank -- so that 28% was pure loss.
    #
    # `margin7d` is the FALLBACK when `margin7dWork` is absent, deliberately: an
    # older policy.json (or another machine's, this file is shared via
    # personal-sync) then behaves exactly as it did before this change rather
    # than silently inheriting a laxer ceiling it never opted into.
    #
    # NOT the same as burn-sweep's 80% ceiling, and that divergence is intended.
    # burn-sweep spends while the owner is AWAY, where capacity-on-return is the
    # whole question; the tick serves him at the keyboard, where a buffer he is
    # sitting next to is dead weight. Two actors, two ceilings. burn-sweep never
    # reads this file.
    $base = if ($null -ne $policy.margin7d) { [double]$policy.margin7d } else { 20.0 }
    $reserve = @(); if ($policy.reserve) { $reserve = @($policy.reserve | ForEach-Object { [int]$_ }) }
    if ($reserve -contains [int]$n) { return $base }
    if ($null -ne $policy.margin7dWork) { return [double]$policy.margin7dWork }
    return $base
}

function Get-WarmMin7dFor($policy, $n) {
    # Mirrors Get-Margin7dFor, and MUST: warming opens a cold 5h window so quota
    # accrues, so a slot the tick will now select but will not pre-warm is
    # eligible-but-cold -- selectable on paper, nothing accruing in practice,
    # which buys exactly none of the capacity this change exists to recover.
    # `status.txt` showing `[cold - 7d guard]` on a work slot is the tell that
    # these two drifted apart.
    $base = if ($null -ne $policy.warmMin7d) { [double]$policy.warmMin7d } else { 20.0 }
    $reserve = @(); if ($policy.reserve) { $reserve = @($policy.reserve | ForEach-Object { [int]$_ }) }
    if ($reserve -contains [int]$n) { return $base }
    if ($null -ne $policy.warmMin7dWork) { return [double]$policy.warmMin7dWork }
    return $base
}

function Get-StaleQuarantineS($policy) {
    # 6h. cswap's poll bounds (poll_policy.py, verified UNCHANGED 0.24.1 -> 0.25.0):
    # MIN_INTERVAL_S 180 floor, CANDIDATE_MAX/EXHAUSTED 600, and the widest legitimate
    # backoff is POST_429_MAX_INTERVAL_S = 1800. Take the 1800 ceiling, not the 600
    # one: 6h is still 12 consecutive missed polls, and a slot that has missed twelve
    # is stuck, not retrying. Sizing this against 600 would have looked 3x safer than
    # it is.
    if ($null -ne $policy.staleQuarantineS) { return [double]$policy.staleQuarantineS }
    return 21600.0
}

function Test-QuarantineStale($a, $staleS) {
    # A "needs a human" verdict that cswap itself has stopped re-testing.
    #
    # WHY THIS EXISTS (2026-08-31). cswap quarantines a slot after ONE
    # invalid_grant (usage_store.py AUTH_DEAD_STRIKES = 1) and `_row_eligible`
    # short-circuits on that strike BEFORE any scheduling gate, so the slot is
    # never fetched again. Every path that lifts the quarantine
    # (`clear_dead_token`) is an add/re-login/slot-reuse/transfer path -- the
    # switch-and-backup path is NOT among them. So cswap can capture a working
    # credential for a slot and go on reporting it dead indefinitely.
    #
    # Measured here: slot 1 sat relogin_required for 64.8h with nextPollAt and
    # backoffUntil both 64.8h in the PAST and lastAttemptAt frozen, while the
    # account itself answered fine. The fleet ran slots 2 and 3 to 91%/83% of
    # their 5h windows with a healthy slot at 8% held out of rotation.
    #
    # cswap >= 0.25.0 fixes the mechanism (a strike condemns a credential
    # GENERATION via struckFingerprint, not the slot) but explicitly cannot heal a
    # row struck by an older version -- its own token_dead docstring: "A row struck
    # before fingerprints were recorded binds unconditionally." So this detector
    # earns its keep even on a current cswap, and always will on a fleet that
    # predates it.
    #
    # The signal is cswap's PUBLIC contract, deliberately: json_output.py emits
    # lastGoodUsage / lastGoodFetchedAt / lastGoodAgeSeconds for a null-usage row.
    # Reading its private cache/usage.json for authDeadStrikes would be far more
    # direct and was rejected -- that is another tool's internal cache, free to be
    # reshaped in any release, and a tick that parses it breaks silently.
    #
    # ABSENT lastGoodAgeSeconds => FALSE, so an older cswap that does not emit the
    # field behaves exactly as this script did before. Never guess staleness.
    if ($null -eq $a) { return $false }
    if ($null -eq $a.lastGoodAgeSeconds) { return $false }
    return ([double]$a.lastGoodAgeSeconds -gt $staleS)
}

function Get-Proj($a) {
    if($a.usageStatus -ne 'ok' -or $null -eq $a.usageAgeSeconds){return $null}
    $now=[datetimeoffset]::UtcNow
    $f=Get-Hotpl8Forecast $a.usage.sevenDay.pct $a.usage.sevenDay.resetsAt $now.AddSeconds(-[double]$a.usageAgeSeconds).ToString('o') 10080 $now
    if($f){return @{rate=$(if($f.secondsToLimit -gt 0){(100-$f.used)*86400/$f.secondsToLimit}else{0});toExh=$f.secondsToLimit/86400}}

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

# ---- credential generations: identity without ever logging a token ----------
# WHY THIS EXISTS (2026-09-05, me/deep-dive/CSWAP-CREDS-DIE-2026-09-05.md).
# Slots 2 and 3 both died on `invalid_grant` with the struck token still sitting
# in their backups and NO successor generation anywhere on disk -- not in the
# backup, its .prev, the session profile, or `cswap unclaimed`. A token that
# vanishes without a successor was REVOKED, not consumed: refresh tokens are
# single-use, and replaying a superseded generation makes the server revoke the
# whole lineage (RFC 9700 reuse detection; cswap issue #164 records it for this
# tool). Every route to that needs TWO uncoordinated holders of one token.
#
# Nothing logged which holder POSTed the fatal grant -- that is the one thing
# the investigation could not measure, so these two helpers exist to make the
# next one measurable. They record a GENERATION, never a secret.

function Get-SlugEmail([string]$email) {
    # Mirrors cswap session.py slugify_email: ASCII alnum plus . _ - survive,
    # everything else becomes '_'. Must stay in step with cswap or the cleanup
    # below would clear a path cswap never writes -- a silent no-op, which is
    # the failure mode that let this bug live for weeks in the first place.
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $email.ToCharArray()) {
        $keep = ([int][char]$ch -lt 128) -and
                ([char]::IsLetterOrDigit($ch) -or $ch -eq '.' -or $ch -eq '_' -or $ch -eq '-')
        if ($keep) { [void]$sb.Append($ch) } else { [void]$sb.Append('_') }
    }
    return $sb.ToString()
}

function Get-CredMark([string]$path, [bool]$b64) {
    # A short NON-SECRET marker for one credential generation: the refresh
    # token's sha256 prefix + the access token's expiry. The prefix is exactly
    # what cswap condemns a dead generation by (usage_store.py
    # struckFingerprint), so a tick line and a cswap quarantine line can be put
    # side by side without either ever holding token material.
    #
    # '-' (absent) and '?' (present but unreadable) are DIFFERENT facts and both
    # are load-bearing: "no second copy exists" is the state this script now
    # maintains, and it must never be confused with "could not check".
    if ([string]::IsNullOrWhiteSpace($path)) { return '-' }
    if (-not (Test-Path $path))              { return '-' }
    try {
        $txt = Get-Content -Path $path -Raw -ErrorAction Stop
        if ($b64) {
            $txt = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($txt.Trim()))
        }
        $o = ($txt | ConvertFrom-Json).claudeAiOauth
        if (-not $o -or [string]::IsNullOrWhiteSpace([string]$o.refreshToken)) { return '?' }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try   { $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$o.refreshToken)) }
        finally { $sha.Dispose() }
        $fp = -join ($h[0..5] | ForEach-Object { $_.ToString('x2') })
        $exp = '?'
        if ($o.expiresAt) {
            try {
                $exp = ([datetimeoffset]::FromUnixTimeMilliseconds([int64]$o.expiresAt)
                       ).UtcDateTime.ToString('MM-dd HH:mm')
            } catch { $exp = '?' }
        }
        return "$fp@$exp"
    } catch { return '?' }
}

function Save-TickState($path, $warmMap, $probeMap) {
    # The ONLY writer of warm-state.json. Always writes BOTH maps: the warmer and
    # the probe each have a floor stored here, and a partial write would erase the
    # other's -- which fails silently, as that actor simply firing every tick.
    # Best-effort like the rest of this state: a lost stamp costs one extra ping,
    # never a wrong decision.
    try { Write-Hotpl8Text $path (@{ lastWarm = $warmMap; lastProbe = $probeMap } | ConvertTo-Json -Depth 4) } catch { }
}

function Invoke-SlotPing($cswap, $n, $email, $root, $kind) {
    # ONE terminal-scoped ping at a slot, and the only place this script hands a
    # slot's credential to a live Claude Code. Shared by the WARMER (open a cold
    # 5h window so quota accrues) and the PROBE (re-test a slot cswap has stopped
    # re-testing). Both want identical mechanics and identical cleanup; the only
    # difference is why, which travels as $kind into the audit line.
    #
    # `cswap run` is terminal-scoped and NEVER moves the global active account.
    # That is the property both callers depend on -- for the probe it is the whole
    # safety argument, because a SWITCH-based probe is what put the fleet onto a
    # dead credential on 2026-09-05.
    #
    # Returns $true only on a real exit 0.

    # --strict-mcp-config is LOAD-BEARING, not tidiness: the session profile's
    # .claude.json carries 6 MCP servers (playwright, chrome-devtools, github,
    # supabase, context7, paypal). Without it every ping would spawn all six,
    # browsers included, every time a window turns over.
    # `--no-share` was tried and DROPPED 2026-08-09: measured identical cost
    # (cache_read 15642 both ways) and it did not actually remove CLAUDE.md,
    # settings.json or the MCP list from the profile. It bought nothing while
    # mutating a profile that interactive `cswap run` also uses.
    #
    # Do NOT pass `--require-session`. Tried and reverted 2026-09-05: on an
    # account that is already the default login, `cswap run` takes a same-account
    # fast path so it will "never create a second credential copy" (cswap
    # session.py) -- which is the outcome we want. That flag turns the safe fast
    # path into a refusal.
    #
    # Record the generation on both sides of the ping (see Get-CredMark), then
    # guarantee only ONE copy of that token survives. Paths mirror cswap's own
    # layout: the backup .enc is keyed by the RAW email, the profile by the slug.
    $encPath  = Join-Path $HOME ".claude-swap-backup/credentials/.creds-$n-$email.enc"
    $profPath = Join-Path $HOME ".claude-swap-backup/sessions/$n-$(Get-SlugEmail $email)/.credentials.json"
    $preEnc   = Get-CredMark $encPath  $true
    $preProf  = Get-CredMark $profPath $false

    # A FAILED ping must never look like a successful one. The first version
    # swallowed the exception and recorded the warm anyway, so on any platform
    # where Start-Process behaves differently the tick would log "warmed slot N",
    # stamp the state, and never have sent anything -- a broken warmer that
    # reports success forever. This file is SHARED with the Mac via
    # personal-sync, so that is not hypothetical.
    # Diagnostics.Process, NOT Start-Process: on Windows PowerShell 5.1
    # `Start-Process -PassThru` leaves ExitCode EMPTY even after the process
    # has exited (verified 2026-08-09: `cmd /c exit 7` -> HasExited True,
    # ExitCode blank, still blank after Refresh()). With no readable exit code
    # a failed ping is indistinguishable from a successful one, which is the
    # whole thing this block exists to detect.
    # ReadToEndAsync BEFORE WaitForExit is required, not stylistic: both pipes
    # are redirected, and waiting without draining them deadlocks the moment
    # the child writes more than the pipe buffer.
    $ok = $false
    try {
        $result=Invoke-Hotpl8Process $cswap @('run',[string]$n,'--','claude','--model','haiku','--strict-mcp-config','-p','.') 90000
        $ok=$result.exitCode -eq 0
    } catch { }

    # THE FIX (2026-09-05). Leaving the profile's credential on disk is what
    # gives an IDLE slot two uncoordinated holders of one single-use refresh
    # token: the backup, which cswap serializes behind its per-slot consume
    # lock, and this file, which a live Claude Code reads under no lock at
    # all. Only one of them can redeem a generation; a replay of the other
    # revokes the whole lineage, and an idle slot -- unlike the active one --
    # has no live copy to resync from, so the snapshot is dead until re-login
    # (README, incident 2026-07-31).
    #
    # Deleting it is cswap's OWN supported path, not a hack:
    # _invalidate_session_credentials does exactly this, and its docstring is
    # the contract -- "The next `cswap run` fails the reuse check and
    # re-bootstraps from backup", merging .claude.json so the profile's
    # projects and history survive. So this costs the profile nothing and
    # shrinks the two-holder window from PERMANENT to the seconds the ping
    # runs. Unconditional, including after a FAILED ping: a ping that died
    # mid-flight is exactly when a stale second copy is most likely to be
    # left behind.
    $cleared = 'absent'
    if (Test-Path $profPath) {
        try { Remove-Item -LiteralPath $profPath -Force -ErrorAction Stop; $cleared = 'cleared' }
        catch { $cleared = 'CLEAR-FAILED' }
    }

    # One line per ping. This is the record whose ABSENCE stopped the
    # 2026-09-05 diagnosis at "some holder POSTed it": nothing anywhere
    # logged a token's identity, so the fatal replay could not be attributed.
    # A slot that dies from here on leaves the generation it died on, and
    # what the ping did to it, in this file. prof-before is the load-bearing
    # column -- with the cleanup above in force it should always read '-',
    # and a fingerprint there means a second copy survived a previous tick.
    # Best-effort by construction: instrumentation must never fail a tick.
    try {
        $auditLine = '{0} slot {1} kind={2} ok={3} enc {4} -> {5} prof-before={6} prof={7}' -f
            ([datetimeoffset]::UtcNow.ToString('o')), $n, $kind, $ok, $preEnc,
            (Get-CredMark $encPath $true), $preProf, $cleared
        $auditPath=Join-Path $root 'cred-audit.log'
        if((Test-Path -LiteralPath $auditPath) -and (Get-Item -LiteralPath $auditPath).Length -gt 262144){
            [IO.File]::Copy($auditPath,$auditPath+'.1',$true)
            [IO.File]::WriteAllText($auditPath,'')
        }
        Add-Content -Path $auditPath `
                    -Value $auditLine -Encoding utf8 -ErrorAction Stop
    } catch { }

    return $ok
}

# ---- warm: phase model ----------------------------------------------------
# The 5h window is a fixed-length cycle, so a "phase" is just a minute offset into
# it. Anchoring to the Unix epoch (not to process start, not to a stored value)
# makes every machine and every tick agree without shared state -- the same
# reasoning that lets each desktop decide switching for itself.
$script:W_MIN = 300

function Get-CycleMinute {
    return [int][Math]::Floor([datetimeoffset]::UtcNow.ToUnixTimeSeconds() / 60.0) % $script:W_MIN
}

function Get-WarmOffsets($policy, $prefer) {
    # pattern + prefer + weights -> slot:offset. NEVER stored: a new subscription is
    # adopted by appending to `prefer`, and every offset recomputes on the next tick.
    # $null return = maintain mode (no phasing; open a cold window immediately).
    $pattern = if ($policy.pattern) { [string]$policy.pattern } else { 'maintain' }
    if ($pattern -eq 'maintain') { return $null }
    $n = @($prefer).Count
    if ($n -le 1) { return $null }          # N=1: phasing is meaningless, degrade to maintain

    # Weights are RELATIVE. All-equal collapses proportional phasing to even
    # spacing, so the uniform fleet needs no configuration and there is one code path.
    $w = @{}
    foreach ($s in $prefer) {
        $v = 1.0
        if ($policy.weights) {
            $p = $policy.weights."$s"
            if ($null -ne $p) { try { $v = [double]$p } catch { $v = 1.0 } }
        }
        if ($v -le 0) { $v = 1.0 }
        $w[[int]$s] = $v
    }

    $g = 1
    if     ($pattern -eq 'synced')    { $g = $n }
    elseif ($pattern -eq 'clustered') { $g = if ($null -ne $policy.warmGroup) { [int]$policy.warmGroup } else { 2 } }
    if ($g -lt 1) { $g = 1 }
    if ($g -gt $n) { $g = $n }

    # Cluster the prefer list; a cluster's weight is the sum of its members', so a
    # cluster holds the floor for as long as its combined quota lasts.
    $clusters = @(); $cw = @()
    for ($i = 0; $i -lt $n; $i += $g) {
        $end = [Math]::Min($i + $g - 1, $n - 1)
        $members = @($prefer[$i..$end])
        $sum = 0.0; foreach ($m in $members) { $sum += $w[[int]$m] }
        $clusters += ,$members; $cw += $sum
    }
    $total = 0.0; foreach ($x in $cw) { $total += $x }
    if ($total -le 0) { return $null }

    $off = @{}; $acc = 0.0
    for ($k = 0; $k -lt $clusters.Count; $k++) {
        # Round to the 10-minute grid: W10 says windows snap DOWN to :00/:10/:20...,
        # so finer targets are unrepresentable and pretending otherwise invents precision.
        $o = [int]([Math]::Round(($script:W_MIN * $acc / $total) / 10.0) * 10) % $script:W_MIN
        foreach ($m in $clusters[$k]) { $off[[int]$m] = $o }
        $acc += $cw[$k]
    }
    return $off
}

function Test-AtPhase($offset, $windowMin) {
    # True for the [offset, offset+windowMin) arc only -- deliberately NOT symmetric.
    # W10: the window start snaps DOWN to the 10-min grid, so firing just AFTER the
    # offset lands exactly on it, while firing just before would snap a full 10
    # minutes early. A one-sided test converts the snapping from a rounding error
    # into free precision.
    $d = (Get-CycleMinute) - [int]$offset
    if ($d -lt 0) { $d += $script:W_MIN }
    return $d -lt [int]$windowMin
}

function Get-ResetEpoch($a) {
    # Unix seconds of this account's 5h reset, or $null when the slot is COLD.
    if (-not $a.usage.fiveHour -or [string]::IsNullOrWhiteSpace([string]$a.usage.fiveHour.resetsAt)) { return $null }
    try { return ([datetimeoffset]::Parse([string]$a.usage.fiveHour.resetsAt)).ToUnixTimeSeconds() } catch { return $null }
}

function Get-RankedOrder($policy, $prefer, $acc, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    # Drain order. `prefer` is the fallback; `order: soonest-reset` re-sorts by which
    # window PERISHES FIRST -- quota in a window that expires in 20 minutes is worth
    # more right now than the same quota in one that expires in four hours, because
    # only one of them is about to vanish. Classic shortest-expiry-first.
    #
    # A COLD slot sorts LAST, deliberately: it has no expiry at all, so its quota is
    # not perishing and spending it now would waste a window that could have been
    # started later.
    #
    # `reserve` slots are ALWAYS last regardless of ordering -- the personal sub stays
    # the last resort no matter how attractive its reset time looks.
    #
    # DEGRADED slots -- those past the preferred weekly ceiling (`margin7d`, 80% used)
    # but still eligible under the work margin -- sort after every healthy slot, and
    # among themselves by MOST WEEKLY HEADROOM FIRST rather than by reset time.
    # Deliberately a different key: down there the week is the binding constraint, not
    # the 5h window, so "which of these has the most week left" is the only question
    # that matters. Ranking two nearly-spent slots by 5h reset can hand you the one
    # with 12% of its week over the one with 16%, which is backwards.
    # Healthy fleets never reach this branch, so `soonest-reset` behaviour is unchanged.
    $order   = if ($policy.order) { [string]$policy.order } else { 'prefer' }
    $reserve = @(); if ($policy.reserve) { $reserve = @($policy.reserve | ForEach-Object { [int]$_ }) }
    $pref7d  = if ($null -ne $policy.margin7d) { [double]$policy.margin7d } else { 20.0 }
    $rows = @()
    for ($i = 0; $i -lt @($prefer).Count; $i++) {
        $n = [int]$prefer[$i]
        $e = $acc[$n]
        $key = [double]$i
        if ($order -eq 'soonest-reset') {
            $key = [double]::MaxValue
            if ($e) { $r = Get-ResetEpoch $e.obj; if ($null -ne $r) { $key = [double]$r } }
        }
        # h7 null => not judged degraded. Test-Ok already rejects it outright, so
        if($order -in @('weekly-expiry','balanced') -and $e){$key=Get-Hotpl8SelectionKey $order $e.h5 $e.h7 $e.obj.usage.sevenDay.resetsAt $Now}
        # there is nothing to order and inventing a rank would only obscure that.
        $deg = 0
        if ($e -and $null -ne $e.h7 -and [double]$e.h7 -lt $pref7d) {
            $deg = 1
            # Negated so DESCENDING headroom falls out of the same ascending sort.
            # Safe to overwrite $key: the `deg` column above keeps the two groups from
            # ever interleaving, so the healthy ordering cannot be perturbed by this.
            $key = -([double]$e.h7)
        }
        $rows += [pscustomobject]@{
            n = $n; tier = $(if ($reserve -contains $n) { 1 } else { 0 })
            deg = $deg; key = $key; idx = $i }
    }
    return @($rows | Sort-Object tier, deg, key, idx | ForEach-Object { $_.n })
}

function Get-PhaseOffsetOf($a) {
    # A live window's phase = its start (resetsAt - 5h) as a cycle minute.
    if (-not $a.usage.fiveHour -or [string]::IsNullOrWhiteSpace([string]$a.usage.fiveHour.resetsAt)) { return $null }
    try {
        $r = [datetimeoffset]::Parse([string]$a.usage.fiveHour.resetsAt)
        return [int][Math]::Floor($r.ToUnixTimeSeconds() / 60.0) % $script:W_MIN
    } catch { return $null }
}

function Resolve-CswapExecutable([string]$CswapExecutable) {
    # Resolve cswap explicitly. A launchd agent's PATH excludes ~/.local/bin.
    # This file is SHARED between the Mac and Windows via personal-sync, so every
    # branch below must be inert on the other OS (Test-Path on a foreign path is
    # simply $false — no platform check needed).
    $cswap = $CswapExecutable
    if (-not $cswap) { foreach ($c in @((Join-Path $HOME '.local/bin/cswap'), '/usr/local/bin/cswap')) {
        if (Test-Path $c) { $cswap = $c; break }
    }
    }
    if (-not $cswap) { $cswap = (Get-Command cswap -ErrorAction SilentlyContinue).Source }
    # Windows last-resort: pip drops cswap.exe in Python's Scripts dir, which a
    # Scheduled Task's environment does not reliably carry on PATH. Resolve by GLOB
    # and never pin a version — a hardcoded Python313 path is precisely the
    # "versioned path silently kills the timer" trap that
    # scripts/register-freshener.ps1's macOS branch was rewritten to avoid.
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
function Get-ClaudeSelection($policy, $prefer, $acc, [int]$active, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    $orderMode=if($policy.order){$policy.order}else{'prefer'}
    $m5=[double]$policy.margin5h; $hy=[double]$policy.hysteresis
    $soonest   = ($orderMode -eq 'soonest-reset')
    $leadMin   = if ($null -ne $policy.resetLeadMin) { [double]$policy.resetLeadMin } else { 10.0 }
    $ranked   = Get-RankedOrder $policy $prefer $acc $Now
    $activeOk = Test-Ok $acc[$active] $m5 (Get-Margin7dFor $policy $active)
    $rankIdx  = [array]::IndexOf($ranked, $active)

    if ($activeOk -and $rankIdx -ge 0) {
        # Active is still serving. Only a BETTER-RANKED account may take over.
        $candidates = if ($rankIdx -gt 0) { $ranked[0..($rankIdx - 1)] } else { @() }
        # The hysteresis band exists because HEADROOM hovers near a margin and would
        # flip-flop. Under a resetsAt ordering that failure mode cannot occur: a
        # reset time is monotonic and two slots' relative order cannot change until
        # one of them actually resets. So the band is not merely unnecessary there,
        # it is HARMFUL -- it would block a takeover of a slot whose quota is about
        # to expire, which is the entire point of the ordering. Replaced by a
        # minimum lead time, which guards the only real risk (sub-second resetsAt
        # jitter, W11, flapping two near-simultaneous slots).
        $band = if ($soonest) { $m5 } else { $m5 + $hy }
    } else {
        # Active is spent (or unknown): take the first account that can serve at all.
        $candidates = $ranked
        $band = $m5
    }

    $target = $null
    foreach ($n in $candidates) {
        if (-not (Test-Ok $acc[$n] $band (Get-Margin7dFor $policy $n))) { continue }
        if ($soonest -and $activeOk) {
            # TIER ESCAPE. Leaving the reserve for a work sub is never subject to the
            # lead requirement: the reserve exists to be abandoned as soon as anything
            # else can serve. Without this, equal reset times would strand you on the
            # personal sub indefinitely -- the exact outcome `reserve` exists to prevent.
            $tierN = 0; $tierA = 0
            if ($policy.reserve) {
                $res = @($policy.reserve | ForEach-Object { [int]$_ })
                if ($res -contains [int]$n)      { $tierN = 1 }
                if ($res -contains [int]$active) { $tierA = 1 }
            }
            if ($tierN -ge $tierA) {
                $rn = Get-ResetEpoch $acc[$n].obj
                $ra = if ($acc[$active]) { Get-ResetEpoch $acc[$active].obj } else { $null }
                # No lead is measurable (either side cold) => fall back to rank order.
                if ($null -ne $rn -and $null -ne $ra -and (($ra - $rn) / 60.0) -lt $leadMin) { continue }
            }
        }
        $target = $n; break
    }

    return @{ranked=@($ranked);target=$target;activeOk=$activeOk}
}

function Invoke-ClaudeTick($policy, [string]$StateDirectory, [string]$CswapExecutable, [switch]$ObserveOnly) {
    if (-not $policy.prefer) { return $null }
    $actions=Get-Hotpl8Actions $policy ([bool]$ObserveOnly)
    if(Get-Hotpl8Pause $StateDirectory){$actions.switching=$false;$actions.warming=$false;$actions.probing=$false}
    $cswap=Resolve-CswapExecutable $CswapExecutable
    if (-not $cswap) { throw 'claude_missing' }
    $read=Invoke-Hotpl8Process $cswap @('list','--json') 20000
    if ($read.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($read.output)) { throw 'claude_read_failed' }
    $data=$read.output | ConvertFrom-Json
    if ($null -ne $data.schemaVersion -and $data.schemaVersion -ne 1) { throw 'claude_schema_unsupported' }
    if (-not $data.accounts) { throw 'claude_no_accounts' }

    $m5 = [double]$policy.margin5h
    $hy = [double]$policy.hysteresis
    $maxAge = if ($null -ne $policy.maxUsageAgeS) { [double]$policy.maxUsageAgeS } else { 900.0 }
    $prefer = @($policy.prefer | ForEach-Object { [int]$_ })

    $acc = @{}
    foreach ($a in $data.accounts) {
        # An opt-out or malformed reading cannot authorize automated use.
        $valid=$true
        foreach($w in @($a.usage.fiveHour,$a.usage.sevenDay)) {
            if($w -and (-not (Test-Hotpl8Number $w.pct) -or $w.pct -lt 0 -or $w.pct -gt 100)) { $valid=$false }
        }
        if($a.disabled -eq $true -or $a.enabled -eq $false -or [int]$a.number -in @($policy.disabled)) { $valid=$false }
        if($null -ne $a.usageAgeSeconds -and (-not (Test-Hotpl8Number $a.usageAgeSeconds) -or $a.usageAgeSeconds -lt 0)) { $valid=$false }
        if(-not $valid) { $a.usage=$null; $a.usageStatus='unsupported_or_disabled' }
        $h5 = $null; $h7 = $null
        if ($a.usage.fiveHour) { $h5 = 100.0 - [double]$a.usage.fiveHour.pct }
        if ($a.usage.sevenDay) { $h7 = 100.0 - [double]$a.usage.sevenDay.pct }
        # COLD = no 5h window exists at all. Verified 2026-08-09 (W1/W2): an expired
        # window leaves `fiveHour` PRESENT with pct=0 and an EMPTY resetsAt, and stays
        # that way indefinitely -- it does not auto-chain. Detecting this via $h5 is
        # the trap: a cold slot computes h5 = 100.0, which is not null, so an
        # h5-based guard would never fire. A null `usage` (dead credential) is NOT
        # cold -- there is nothing to warm and the fix is a human, not a ping.
        $cold = $false
        if ($a.usage.fiveHour) {
            $cold = [string]::IsNullOrWhiteSpace([string]$a.usage.fiveHour.resetsAt)
        }
        # FRESHNESS: cswap serves last-good data for up to an HOUR on poll failure
        # (usage_store.py TRUST_MAX_AGE_S=3600), so pct alone is not safe to decide on.
        #
        # The ceiling MUST sit above cswap's own candidate poll cadence, or the
        # reserve account is permanently ineligible and this whole script cannot do
        # its job. poll_policy.py: CANDIDATE_DEFAULT_INTERVAL_S=300,
        # CANDIDATE_MAX_INTERVAL_S=600, JITTER_FRAC=0.1 => an idle candidate legitimately
        # reaches ~660s. 900s clears that with margin while staying far below
        # TRUST_MAX_AGE_S=3600, which is the real "polling is dead" signal.
        # (Observed 2026-07-30: an inactive account at 503s with 100% headroom was
        # wrongly rejected by a 300s ceiling.)
        $fresh = ($a.usageStatus -eq 'ok') -and ($null -ne $a.usageAgeSeconds) -and ([double]$a.usageAgeSeconds -le $maxAge)
        $acc[[int]$a.number] = @{ n = [int]$a.number; h5 = $h5; h7 = $h7; fresh = $fresh; cold = $cold; obj = $a }
        $entry=$acc[[int]$a.number]
        $entry.identity=Get-Hotpl8Hash ([string]$a.email)
        $entry.observedAt=[datetimeoffset]::UtcNow.AddSeconds(-[double]$a.usageAgeSeconds).ToString('o')
        $entry.modelBlocked=$false; $entry.modelReason=$null
        foreach($model in @($policy.claudeModels|Where-Object {$_})){
            $scope=@($a.usage.scoped|Where-Object name -EQ $model)
            if($scope.Count -ne 1 -or -not (Test-Hotpl8Number $scope[0].pct) -or $scope[0].pct -lt 0 -or $scope[0].pct -gt 100){$entry.modelBlocked=$true;$entry.modelReason='model_quota_unknown';break}
            try{$scopeReset=[datetimeoffset]::Parse($scope[0].resetsAt);if($scopeReset -le [datetimeoffset]::UtcNow){throw 'expired'}}catch{$entry.modelBlocked=$true;$entry.modelReason='model_reset_unconfirmed';break}
            if(100-[double]$scope[0].pct -lt (Get-Margin7dFor $policy ([int]$a.number)) -or $scope[0].pct -ge 100){$entry.modelBlocked=$true;$entry.modelReason='model_below_margin';break}
        }
    }

    $outcomes=Read-Hotpl8WarmOutcomes $StateDirectory
    foreach($n in $prefer){
        $e=$acc[$n];$key='claude:'+ $n
        if($e -and $outcomes.$key){
            $priorOutcome=$outcomes.$key.outcome
            $updated=Update-Hotpl8WarmOutcome $outcomes.$key $e.identity $e.observedAt $e.obj.usage.fiveHour.resetsAt $e.fresh
            $outcomes|Add-Member NoteProperty $key $updated -Force
            if($updated.outcome -ne $priorOutcome -and (Get-Command Add-Hotpl8ActionEvent -ErrorAction SilentlyContinue)){Add-Hotpl8ActionEvent $StateDirectory 'claude' ([string]$n) 'warm_outcome' $updated.outcome}
        }
    }
    if(@($outcomes.PSObject.Properties).Count){Save-Hotpl8WarmOutcomes $StateDirectory $outcomes}

    $orderMode = if ($policy.order) { [string]$policy.order } else { 'prefer' }
    $active=[int]$data.activeAccountNumber
    $selection=Get-ClaudeSelection $policy $prefer $acc $active
    $ranked=@($selection.ranked);$target=$selection.target

    # A hold suppresses the SWITCH ONLY, and is deliberately not an early return.
    # Ranking, eligibility, status and warming all still run, so status.txt keeps
    # telling the truth about the fleet while the hold is in force, and cold windows
    # keep accruing quota -- warming uses `cswap run <n>`, which is terminal-scoped
    # and never moves the global active account, so it is safe under a hold and
    # valuable during one (it is what leaves you an open window when you come back).
    #
    # Disabling the scheduled task would stop all of that instead, and would remove
    # the only component still running that could heal the state afterwards. Never
    # switch the watchdog off; teach it to stand down.
    $hold       = Get-Hold $StateDirectory
    $heldSwitch = ($null -ne $hold) -and ($null -ne $target) -and ($target -ne $active)

    $switched = $false
    if ($actions.switching -and $null -ne $target -and $target -ne $active -and $null -eq $hold) {
        $switchResult=Invoke-Hotpl8Process $cswap @('switch',[string]$target) 20000
        if ($switchResult.exitCode -eq 0) {
            $switched = $true; $active = $target
            if(Get-Command Add-Hotpl8ActionEvent -ErrorAction SilentlyContinue){Add-Hotpl8ActionEvent $StateDirectory 'claude' ([string]$target) 'switch' 'native_switch_succeeded'}
        }
        else { throw 'claude_switch_failed' }
    }

    # Eligibility is computed BEFORE warming, and deliberately so: warming does not
    # make a slot usable for ~3 minutes (W9), so "can anything serve me right now?"
    # must be answered from the pre-warm world or the self-healing override below
    # would read its own ping as rescue.
    $needsHuman   = @('relogin_required', 'no_credentials')
    $broken       = @($prefer | Where-Object { $acc[$_] -and $needsHuman -contains [string]$acc[$_].obj.usageStatus })
    # Of the broken slots, the ones whose verdict cswap has stopped re-testing.
    # Partitioned rather than filtered: a fleet can hold one genuinely dead slot and
    # one stale-quarantined slot at the same time, and they need OPPOSITE actions --
    # collapsing them is the same mistake the 2026-07-31 incident cost 2h to learn.
    $staleS       = Get-StaleQuarantineS $policy
    $stuck        = @($broken | Where-Object { Test-QuarantineStale $acc[$_].obj $staleS })
    $reallyBroken = @($broken | Where-Object { $stuck -notcontains $_ })
    $anyFresh     = @($prefer | Where-Object { $acc[$_] -and $acc[$_].fresh }).Count -gt 0
    $anyEligible  = @($prefer | Where-Object { Test-Ok $acc[$_] $m5 (Get-Margin7dFor $policy $_) }).Count -gt 0

    # ---- warm: open cold windows so quota accrues instead of sitting dead ----
    # A spent window expires into NOTHING and stays there until something touches it
    # (W1). One minimal request costs ~1% of a window (W4) and buys the other 99%.
    $warmed     = @()
    $warmFailed = @()
    $offsets    = $null
    # The weekly warm floor is now PER SLOT (Get-WarmMin7dFor), so there is no single
    # $wMin7d to hoist any more -- both consumers below resolve it from the slot they
    # are already looping over. The status line still names WHY a cold slot was left
    # cold, which is what the old hoist existed for: "[cold]" alone repeats the mistake
    # the stale-vs-dead-credential split was made to fix -- one symptom, several
    # causes, opposite responses.
    $wWindow = if ($null -ne $policy.warmPhaseWindowMin) { [int]$policy.warmPhaseWindowMin } else { 15 }

    # Hoisted ABOVE the warm block on 2026-09-06 because there are now TWO writers
    # to this file (the warmer's lastWarm and the probe's lastProbe) and the probe
    # runs even when `warm` is off. Both maps are loaded once here and every save
    # writes BOTH -- a save that wrote only its own map would silently erase the
    # other's floor, and the visible symptom would be the other actor firing every
    # tick forever. Save-TickState is the only writer for exactly that reason.
    $statePath = Join-Path $StateDirectory 'warm-state.json'
    $state  = @{}   # lastWarm  : slot -> ISO8601 of last warm ping
    $pstate = @{}   # lastProbe : slot -> ISO8601 of last stale-quarantine probe
    if (Test-Path $statePath) {
        try {
            $sj = Get-Content $statePath -Raw | ConvertFrom-Json
            if ($sj.lastWarm)  { foreach ($p in $sj.lastWarm.PSObject.Properties)  { $state[$p.Name]  = [string]$p.Value } }
            if ($sj.lastProbe) { foreach ($p in $sj.lastProbe.PSObject.Properties) { $pstate[$p.Name] = [string]$p.Value } }
        } catch { $state = @{}; $pstate = @{} }
    }

    if ($actions.warming) {
        $wFloor  = if ($null -ne $policy.warmFloorMin)        { [double]$policy.warmFloorMin }        else { 20.0 }
        $offsets = Get-WarmOffsets $policy $prefer

        foreach ($n in $prefer) {
            $e = $acc[$n]
            if (-not $e)          { continue }
            if (-not $e.fresh)    { continue }   # never act on stale usage (new-5)
            if (-not $e.cold)     { continue }   # window already live -- nothing to open
            # Do NOT add a "never warm the active slot" guard here. It was tried on
            # 2026-09-05 and is wrong twice over. The tick's normal flow is to switch
            # TO a cold slot and then open its window, so such a guard skips the
            # commonest warm (it turned 3 suite cases red). And the case it means to
            # protect is already handled inside cswap: `run` takes a same-account
            # fast path that launches plain claude on the default login precisely so
            # it will "never create a second credential copy for the account that is
            # already the active default login" (session.py). Warming the ACTIVE slot
            # is therefore the safe case -- it creates no second copy at all.
            #
            # For the same reason, do not pass `--require-session`: that flag turns
            # that safe fast path into a REFUSAL. It exists for wrappers that need
            # session isolation guaranteed; warming needs the window opened, and the
            # fast path is the outcome we want. Measured 2026-09-05: slot 1 is warmed
            # constantly, is healthy, and has NO session-profile credential, while
            # slot 3 -- warmed while idle -- had one and died.
            # Weekly guard: 5h warming cannot help a spent WEEKLY budget, and the ping
            # itself costs weekly quota. Observed 2026-08-09: slot 1 sat at 97% 7d.
            if ($null -ne $e.h7 -and $e.h7 -lt (Get-WarmMin7dFor $policy $n)) { continue }
            # Anti-double-ping (W9): usage takes ~3 min to surface while maxUsageAgeS
            # allows 15-min-old data, so without this a cold slot is pinged 2-3 times.
            # Compared with a tolerance, never equality -- resetsAt jitters sub-second (W11).
            $last = $state["$n"]
            if ($last) {
                try {
                    if ((([datetimeoffset]::UtcNow - [datetimeoffset]::Parse($last)).TotalMinutes) -lt $wFloor) { continue }
                } catch { }
            }
            # PHASE + SELF-HEALING, in one condition. Hold a cold slot back to hit its
            # target offset ONLY while something else can still serve. The moment
            # nothing is eligible, phase is abandoned and we warm immediately:
            # a system that leaves you blocked to protect a schedule has failed.
            # Corollary (the whole self-healing story): >5h away puts every slot cold
            # with nothing eligible... except each slot reaches its own offset first,
            # so a sleep re-phases the fleet exactly, at zero cost.
            if ($offsets -and $null -ne $offsets[[int]$n] -and $anyEligible) {
                if (-not (Test-AtPhase $offsets[[int]$n] $wWindow)) { continue }
            }

            # Bounded, and ONE slot per tick: a ping takes ~6s but must never be able
            # to wedge the timer (the task is registered IgnoreNew). Remaining cold
            # slots are picked up by the next tick 5 minutes later, which is far
            # inside the 5h window this is protecting.
            if($e.modelBlocked -or (Get-Hotpl8ActionBlock $policy $StateDirectory 'claude' ([string]$n) 'warm')){continue}
            $outcomeKey='claude:'+ $n
            if(Test-Hotpl8WarmPending $outcomes.$outcomeKey $e.identity){continue}
            Add-Hotpl8Attempt $StateDirectory 'claude' ([string]$n)
            # Persist before dispatch. A crash cannot cause an immediate duplicate prompt.
            $outcome=New-Hotpl8WarmOutcome 'claude' ([string]$n) $e.identity 'fiveHour' $true
            $outcome.outcome='requested'
            $outcomes|Add-Member NoteProperty $outcomeKey $outcome -Force
            Save-Hotpl8WarmOutcomes $StateDirectory $outcomes
            $ok = Invoke-SlotPing $cswap $n ([string]$e.obj.email) $StateDirectory 'warm'
            $outcome.outcome=if($ok){'sent'}else{'failed'}
            $outcomes|Add-Member NoteProperty $outcomeKey $outcome -Force
            Save-Hotpl8WarmOutcomes $StateDirectory $outcomes
            if(Get-Command Add-Hotpl8ActionEvent -ErrorAction SilentlyContinue){Add-Hotpl8ActionEvent $StateDirectory 'claude' ([string]$n) 'warm_attempt' $outcome.outcome}

            # Stamped either way: a slot that fails to warm must back off to $wFloor,
            # not be retried every 5 minutes forever. But only a REAL ping counts as a
            # warm; a failure is reported as a failure, because a dead warm mechanism
            # is a call to action and silence is how it would stay dead.
            if ($ok) { $warmed += $n } else { $warmFailed += $n }
            $state["$n"] = [datetimeoffset]::UtcNow.ToString('o')
            Save-TickState $statePath $state $pstate
            break
        }
    }

    # ---- probe: re-test a slot cswap has stopped re-testing ------------------
    # $stuck means "cswap struck this slot once and has not asked again" (see
    # Test-QuarantineStale). Until 2026-09-06 that was REPORTED and nothing more,
    # and the remedy the report names -- "verify with cswap list" -- is a manual
    # step for a human who may not be at the keyboard for days. Measured cost of
    # that gap: slot 2 sat dead for 28h while every tick printed QUARANTINE STALE,
    # and it was revived only by accident, when the cswap TUI happened to switch
    # onto it.
    #
    # That accident is also the mechanism. A strike binds to the credential
    # GENERATION, not to the slot (cswap usage_store.py `token_dead`), so anything
    # that writes a fresh generation clears it. A ping does exactly that.
    #
    # `cswap run`, NEVER `cswap switch`. The ping is terminal-scoped and does not
    # move the global active account, so a probe cannot drop the owner onto a dead
    # credential mid-session. That is not a nicety: a switch-based probe is
    # precisely what broke the fleet on 2026-09-05.
    #
    # hotpl8 never POSTs a token itself. It asks cswap to run, and cswap's consume
    # gate freshens under its own per-slot lock, adopting a newer generation if one
    # exists rather than blindly replaying ours. Replaying a superseded generation
    # is how an entire token family gets revoked (cswap issue #164), so delegating
    # is the point, not an implementation detail.
    #
    # Runs even when `warm` is off: a dead slot is not a cold slot, and it can
    # never reach the warmer anyway (a null-usage row has no fiveHour, so $cold is
    # false -- suite case "dead credential is not 'cold'").
    $probed  = @()
    $revived = @()
    foreach ($n in $stuck) {
        if (-not $actions.probing) { break }
        $e = $acc[$n]
        if (-not $e) { continue }
        # No new knob and no flag: the floor IS the staleness that defined $stuck.
        # A slot is probed at most once per $staleS, so a genuinely dead slot costs
        # 4 pings a day rather than one every 5 minutes.
        $last = $pstate["$n"]
        if ($last) {
            try {
                if ((([datetimeoffset]::UtcNow - [datetimeoffset]::Parse($last)).TotalSeconds) -lt $staleS) { continue }
            } catch { }
        }
        if(Get-Hotpl8ActionBlock $policy $StateDirectory 'claude' ([string]$n) 'probe'){continue}
        Add-Hotpl8Attempt $StateDirectory 'claude' ([string]$n)
        $pok = Invoke-SlotPing $cswap $n ([string]$e.obj.email) $StateDirectory 'probe'
        if(Get-Command Add-Hotpl8ActionEvent -ErrorAction SilentlyContinue){Add-Hotpl8ActionEvent $StateDirectory 'claude' ([string]$n) 'recovery_probe' $(if($pok){'sent'}else{'failed'})}
        $probed += $n
        if ($pok) { $revived += $n }
        $pstate["$n"] = [datetimeoffset]::UtcNow.ToString('o')
        Save-TickState $statePath $state $pstate
        break   # ONE per tick, for the same reason the warmer takes one
    }

    # ---- status.txt (the only thing sessions ever read) ----
    # A dead CREDENTIAL and a spent QUOTA both make an account ineligible, but they
    # need opposite responses: one needs YOU, the other needs TIME. Collapsing them
    # into one verdict cost ~2h of silent no-failover on 2026-07-31 — status.txt said
    # "BOTH LOW, no switch helps" (i.e. wait for the reset) while the real fix was a
    # re-login, and it misdirected the diagnosis twice.
    # The split is per json_output.py:135-165: token_expired is "retried
    # automatically" (:143) and foreign_credential is repaired by "a switch" (:147),
    # so both self-heal and must NOT raise a call to action. relogin_required (:34;
    # switcher.py:167 "log in with Claude Code, then run: cswap add") and
    # no_credentials cannot recover without a human.
    #
    # ...UNLESS the verdict itself has gone stale, which is a THIRD state and the
    # 2026-08-31 finding (F24). "Needs a human" is cswap's answer, and cswap stops
    # re-asking it after one invalid_grant; a slot can therefore be healthy and
    # still reported dead forever. Printing "-> cswap add" at that point names a
    # remedy that does not apply and hides the one that does, which is exactly how
    # a working subscription stayed out of the fleet for 2.7 days. See
    # Test-QuarantineStale for the mechanism and the evidence.
    # ($needsHuman/$broken/$stuck/$reallyBroken/$anyFresh/$anyEligible are computed
    #  above the warm block, which needs $anyEligible for its self-healing override.)

    $verdict = ''
    $calls = @()
    if ($reallyBroken.Count -gt 0) { $calls += "slot $($reallyBroken -join '+') NEEDS RE-LOGIN -> cswap add" }
    # Deliberately does NOT say "re-login": that is the instruction that wasted the
    # 2.7 days. Say what is actually true (cswap has stopped checking) and name the
    # cheap test that settles it.
    if ($stuck.Count -gt 0) {
        $hrs = [int](($staleS) / 3600)
        $calls += "slot $($stuck -join '+') QUARANTINE STALE (>${hrs}h unchecked) -> verify with 'cswap list'; if it answers, the strike is stale, not the account"
    }
    if ($calls.Count -gt 0)     { $verdict = ' · ' + ($calls -join ' · ') }
    elseif (-not $anyFresh)     { $verdict = " · usage STALE (>$([int]($maxAge/60))m), holding" }
    elseif (-not $anyEligible)  { $verdict = ' · no headroom on any slot' }
    # A hold is a STATE, not an action, but it is reported every tick anyway: the
    # you may walk back in mid-lease, and "why is nothing rotating?" must be
    # answerable from status.txt alone rather than by finding a JSON file nobody
    # mentioned. Local time, because that is the clock you are reading it on.
    if ($hold) {
        $verdict += " · HELD by $($hold.reason) until $($hold.until.ToLocalTime().ToString('HH:mm'))"
        # Naming the suppressed target keeps the hold honest -- it shows exactly what
        # the tick WOULD have done, so the hold can never quietly hide a rotation the
        # fleet needed.
        if ($heldSwitch)        { $verdict += " (suppressed -> slot $target)" }
    }
    # A switch is an ACTION and is appended, never hidden behind a condition.
    if ($switched)              { $verdict += " · switched -> slot $active" }
    # Warming is an ACTION and is reported for the same reason a switch is: silence
    # about something that happened is how a rotted timer stays invisible.
    if ($warmed.Count -gt 0)     { $verdict += " · warm request sent to slot $($warmed -join '+'); window unconfirmed" }
    if ($warmFailed.Count -gt 0) { $verdict += " · WARM FAILED slot $($warmFailed -join '+') -> check cswap run" }
    # A probe is an ACTION, reported for the same reason a switch and a warm are.
    # REVIVED is the loud one: it means a slot cswap had written off is serving
    # again, with no human involved -- the outcome the probe exists to produce, and
    # the one that must never be inferred from a slot quietly changing colour.
    if ($revived.Count -gt 0)    { $verdict += " · probe REVIVED slot $($revived -join '+')" }
    elseif ($probed.Count -gt 0) { $verdict += " · probed slot $($probed -join '+') (still dead)" }

    $lab = ''
    if ($policy.labels) { $lab = [string]$policy.labels."$active" }
    $head = "cswap {0}{1} · active slot {2}{3}" -f (Get-Date -Format 'HH:mm'), $verdict, $active,
            $(if ($lab) { " ($lab)" } else { '' })

    $lines = @($head)
    foreach ($n in $prefer) {
        $e = $acc[$n]
        if (-not $e) { $lines += ("  slot {0}  not registered" -f $n); continue }
        $l = if ($policy.labels) { [string]$policy.labels."$n" } else { '' }
        $five = if ($null -ne $e.h5) { "5h {0:N0}%" -f (100.0 - $e.h5) } else { "5h unknown" }
        if ($null -ne $e.h7) {
            $p = Get-Proj $e.obj
            $seven = if ($p) {
                "7d {0:N0}% -> {1:N0}%/day, exhausts in ~{2:N1}d" -f (100.0 - $e.h7), $p.rate, $p.toExh
            } else { "7d {0:N0}%" -f (100.0 - $e.h7) }
        } else {
            $seven = "7d not reported"
        }
        # Never print a bare [stale] again: it read identically for a slot whose data
        # was merely old and one whose credential was dead, which is the ambiguity
        # this whole block exists to remove. Name the actual reason.
        $st = [string]$e.obj.usageStatus
        $flag = ''
        # A stale quarantine must not read as "re-login" on the per-slot line either,
        # or the detail rows quietly contradict the verdict line above them.
        if ($needsHuman -contains $st -and (Test-QuarantineStale $e.obj $staleS)) {
            $flag = "  [$st - UNCHECKED $([int]([double]$e.obj.lastGoodAgeSeconds / 3600))h, verdict may be stale]"
        }
        elseif ($needsHuman -contains $st)  { $flag = "  [$st - re-login]" }
        elseif ($st -and $st -ne 'ok')  { $flag = "  [$st]" }
        elseif (-not $e.fresh)          { $flag = "  [stale $([int]$e.obj.usageAgeSeconds)s]" }
        # "5h 0%" reads as a pristine full window; cold means there is NO window and
        # nothing is accruing. Opposite meanings, identical digits -- name it.
        elseif ($e.cold) {
            # Name the blocker. A slot that is cold BY POLICY (weekly guard, warming
            # off) and one that is cold because the warmer is broken look identical
            # otherwise -- and only one of them needs you.
            if (-not $policy.warm)                          { $flag = '  [cold - warming off]' }
            elseif ($null -ne $e.h7 -and $e.h7 -lt (Get-WarmMin7dFor $policy $n)) { $flag = '  [cold - 7d guard]' }
            # Under a phasing pattern a cold slot is deliberately HELD until its
            # offset, which can be hours -- reporting that as "next tick" would be a
            # plain lie, and the kind that makes a healthy system look broken.
            elseif ($offsets -and $null -ne $offsets[[int]$n] -and
                    -not (Test-AtPhase $offsets[[int]$n] $wWindow)) {
                $flag = '  [cold - held for phase]'
            }
            else                                            { $flag = '  [cold - warming next tick]' }
        }
        # Scoped quotas constrain selection when explicitly named in claudeModels.
        $scoped = $e.obj.usage.scoped
        if ($scoped -and @($scoped).Count -gt 0) {
            $sc = @($scoped | ForEach-Object { "{0} {1:N0}%" -f $_.name, $_.pct }) -join ', '
            $scopeNote=if($policy.claudeModels){'SCOPED CONSTRAINTS: '+$e.modelReason}else{'SCOPED WINDOWS NOT RANKED ON'}
            $lines += ("  slot {0}  [{1}: {2}]" -f $n, $scopeNote, $sc)
        }
        $lines += ("  slot {0}{1}  {2}  {3}{4}" -f $n, $(if ($l) { " ($l)" } else { '' }), $five, $seven, $flag)
    }

    # Pattern + drift, so an out-of-phase fleet is visible rather than silent. Phase
    # drift is EXPECTED during heavy work (the override abandons phase to keep you
    # unblocked) and re-converges on the next idle stretch -- so this line is
    # information, never a call to action.
    if ($actions.warming) {
        $pat = if ($policy.pattern) { [string]$policy.pattern } else { 'maintain' }
        if ($pat -eq 'clustered') {
            $pat += "(g{0})" -f $(if ($null -ne $policy.warmGroup) { [int]$policy.warmGroup } else { 2 })
        }
        $note = ''
        if ($offsets) {
            $offBy = @()
            foreach ($n in $prefer) {
                $e = $acc[$n]; if (-not $e) { continue }
                $cur = Get-PhaseOffsetOf $e.obj
                if ($null -eq $cur) { continue }          # cold: no phase to judge yet
                $d = [Math]::Abs($cur - [int]$offsets[[int]$n])
                if ($d -gt ($script:W_MIN / 2)) { $d = $script:W_MIN - $d }
                if ($d -gt 10) { $offBy += "$n" }         # 10 = the grid quantum (W10)
            }
            $note = if ($offBy.Count -eq 0) { ' · in phase' } else { " · slot $($offBy -join '+') off-phase" }
        }
        $lines += ("  pattern {0} · order {1}{2}" -f $pat, $orderMode, $note)
    }

    # Publication belongs to the shared tick.

    # ---- status.json / status.js (the briefing's instrument strip) ----
    # ADDITIVE. status.txt above is untouched and remains the only thing sessions
    # read; this block exists because status.txt is a RENDERED string and carries
    # no reset timestamps, which is exactly what a gauge needs. The structured
    # data is already in hand here, so emitting it costs one pass and no network.
    # External status consumers use this structured summary.
    # status.js is the same payload as a script assignment, because a file:// page
    # can load <script src> but cannot fetch() a local file.
    # Wrapped in its own try/catch: a briefing feature must NEVER be able to break
    # the rotation. Failure here is silent and status.txt is already written.
    try {
        $slots = @()
        foreach ($n in $prefer) {
            $e = $acc[$n]
            if (-not $e) {
                $slots += [pscustomobject]@{ slot = [int]$n; registered = $false }
                continue
            }
            $u = $e.obj.usage
            $f = $null; $s = $null
            if ($u) { $f = $u.fiveHour; $s = $u.sevenDay }
            $slots += [pscustomobject]@{
                slot       = [int]$n
                label      = $(if ($policy.labels) { [string]$policy.labels."$n" } else { '' })
                registered = $true
                active     = ([int]$n -eq [int]$active)
                cold       = [bool]$e.cold
                fresh      = [bool]$e.fresh
                observedAt = $e.observedAt
                streamKey = Get-Hotpl8Hash ($StateDirectory+'|usage|'+$e.identity)
                scoped = @($e.obj.usage.scoped)
                warmOutcome = $outcomes.('claude:'+ $n) | Select-Object schemaVersion,id,provider,slot,meter,sentAt,expiresAt,outcome,observedAt,resetAt
                actionBlock = Get-Hotpl8ActionBlock $policy $StateDirectory 'claude' ([string]$n) 'warm'
                modelBlock = $e.modelReason
                status     = [string]$e.obj.usageStatus
                used5h     = $(if ($f -and $null -ne $f.pct) { [double]$f.pct } else { $null })
                reset5h    = $(if ($f) { [string]$f.resetsAt } else { '' })
                used7d     = $(if ($s -and $null -ne $s.pct) { [double]$s.pct } else { $null })
                reset7d    = $(if ($s) { [string]$s.resetsAt } else { '' })
            }
        }
        # `hold` is emitted as the tick's OWN reading of the lease, never echoed from
        # hold.json: a job that writes that file needs to confirm the tick actually
        # honoured it, and a field copied from the input it is meant to verify would
        # confirm nothing. null here means "not held" for any reason -- absent,
        # expired or malformed -- which is exactly the question a caller is asking.
        $payload = [pscustomobject]@{
            generatedAt = (Get-Date).ToString('o')
            active      = [int]$active
            verdict     = $verdict.Trim(' ·')
            hold        = $(if ($hold) {
                                [pscustomobject]@{
                                    until  = $hold.until.ToString('o')
                                    reason = $hold.reason
                                }
                            } else { $null })
            slots       = $slots
        }
    } catch { }

    $action = $null
    if ($switched -or $warmed.Count -gt 0 -or $warmFailed.Count -gt 0) {
        $action = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $verdict.Trim(' ·')
    }
    $payload | Add-Member NoteProperty proposedSlot $target -Force
    $payload | Add-Member NoteProperty actions $actions -Force
    $reasons=@(foreach($n in $prefer){$e=$acc[$n];[pscustomobject]@{slot=$n;rank=([array]::IndexOf($ranked,$n)+1);reason=$(if(-not $e){'not_observed'}elseif(-not $e.fresh){'stale_or_unavailable'}elseif($e.modelBlocked){$e.modelReason}elseif(-not (Test-Ok $e $m5 (Get-Margin7dFor $policy $n))){'below_margin_or_unknown'}elseif($n -in @($policy.reserve)){'eligible_reserve'}else{'eligible_work'})}})
    $payload|Add-Member NoteProperty decision ([pscustomobject]@{policy=$orderMode;selected=$active;proposed=$target;reason=$(if($hold){'switch held'}elseif(-not $actions.switching){'switching disabled'}elseif($switched){'switched to higher ranked eligible account'}else{'retained current account'});accounts=$reasons}) -Force
    return @{ lines = $lines; payload = $payload; action = $action }
}
