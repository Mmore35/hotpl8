#!/usr/bin/env bash
# tests/test-tick.sh — decision-logic tests for tick.ps1, using fixtures instead of live accounts.
#
# WHY: the interesting cases (stale usage, both subs low, the 7d gate, a DEAD
# CREDENTIAL) either cannot be produced on demand or would require waiting days. This
# runs the REAL tick.ps1 with an explicit cswap executable dependency set to a stub, so the
# decision logic under test is untouched. No live accounts, no quota, no switching.
#
# It has already earned its keep: it closed the `margin7d` gate check that was
# otherwise blocked until slot 2 reports a weekly window, and its regression cases
# pin the 2026-07-30 freshness bug (see § the 503s cases).
#
#   bash tests/test-tick.sh
#
set -u
for tool in dirname mktemp cp rm tr; do
    command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: missing $tool"; exit 2; }
done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$(mktemp -d)" || exit 2
[[ -n "$S" && -d "$S" ]] || exit 2
trap '[[ -n "$S" && -d "$S" ]] && rm -rf -- "$S"' EXIT
PASS=0; FAIL=0

# --- portability (2026-07-31) -------------------------------------------------
# This suite was pwsh+python3-only and therefore had NEVER run on Windows, where
# only `powershell` (5.1) and `python` exist. README § Windows mandates running it
# after ANY tick.ps1 change, so an unrunnable suite made that mandate a fiction.
PY_BIN="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
PS_BIN="$(command -v pwsh 2>/dev/null || command -v powershell 2>/dev/null || true)"
[ -n "$PY_BIN" ] || { echo "FATAL: no python3/python on PATH"; exit 2; }
[ -n "$PS_BIN" ] || { echo "FATAL: no pwsh/powershell on PATH"; exit 2; }

# Windows PowerShell and Windows python cannot read MSYS paths (/tmp/..., /c/...).
# Convert explicitly rather than relying on Git Bash's argument-mangling heuristic;
# a plain pass-through on macOS, where cygpath does not exist.
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

# Execute unmodified production files with an explicit binary dependency.
cp "$HERE/tick.ps1" "$S/tick.ps1"
cp -R "$HERE/src" "$S/src"
cp -R "$HERE/data" "$S/data"
# Seed from the TRACKED example, never from policy.json (2026-08-30). policy.json is
# gitignored per-machine config carrying this fleet's labels and reserve set, so seeding
# from it made every result depend on a file no other machine has and no commit records
# -- the tell was failure output printing this owner's live labels ("active slot 1
# (reserve)"). Same knobs, same values; only the labels differ.
cp "$HERE/tests/legacy-policy.json" "$S/policy.json" || exit 2

# The stub must be a REAL EXECUTABLE for this platform, and the reason changed on
# 2026-08-09. Original lesson (keep it): an extensionless #!/bin/bash file is not
# runnable by Windows PowerShell via `& $cswap` — it returns nothing, tick.ps1
# exits at once, and every case silently no-ops while still reporting a majority
# PASS. That is exactly what happened before 2026-07-31.
# New constraint: the warm path invokes cswap through Start-Process (for a hard
# timeout, so a wedged `claude` can never block an IgnoreNew scheduled task), and
# Start-Process cannot execute a .ps1 on EITHER platform. So: .cmd on Windows, a
# chmod +x shebang script elsewhere. Both are callable by `& $cswap` too, so the
# pre-existing list/switch cases go through the identical path they always did.
if command -v cygpath >/dev/null 2>&1; then
    STUB="$S/cswap-stub.cmd"
    cat > "$STUB" <<'EOF'
@echo off
if "%~1"=="switch" (>>"%CALLS%" echo %~2) & exit /b 0
if "%~1"=="run"    (>>"%RUNS%"  echo %~2) & exit /b %RUNRC%
type "%FIXTURE%"
exit /b 0
EOF
else
    STUB="$S/cswap-stub.sh"
    cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "switch" ]; then echo "$2" >> "$CALLS"; exit 0; fi
if [ "${1:-}" = "run" ];    then echo "$2" >> "$RUNS";  exit ${RUNRC:-0}; fi
cat "$FIXTURE"
exit 0
EOF
    chmod +x "$STUB"
fi

mk() {  # mk <active> <a1_5h> <a1_age> <a2_5h> <a2_age> [a1_7d] [a2_7d] [a1_status] [a2_status]
        # 7d: omit or "none".  status: omit or "ok" for a healthy slot.
"$PY_BIN" - "$@" > "$S/fixture.json" <<'PY'
import sys, json
from datetime import datetime, timezone, timedelta
act = int(sys.argv[1]); v = sys.argv[2:]
def g(i):
    return v[i] if len(v) > i else "none"
def acct(n, p5, age, p7, status):
    # A non-"ok" status is NOT just a string swap: json_output.py usage_fields()
    # returns (status, None) for every non-ok entry, so account_row emits
    # "usage": null AND omits usageAgeSeconds (it swaps in lastGood* fields).
    # Emitting live pct next to relogin_required would pin a shape cswap never sends.
    if status not in ("ok", "none", None, ""):
        return {"number": n, "email": f"a{n}@x", "active": n == act,
                "usageStatus": status, "usage": None}
    u = {"fiveHour": {"pct": float(p5), "resetsAt": "2026-07-30T18:00:00+00:00"}}
    if p7 not in ("none", None, ""):
        u["sevenDay"] = {"pct": float(p7),
                         "resetsAt": (datetime.now(timezone.utc) + timedelta(days=6)).isoformat()}
    return {"number": n, "email": f"a{n}@x", "active": n == act,
            "usageStatus": "ok", "usage": u, "usageAgeSeconds": float(age)}
print(json.dumps({"schemaVersion": 1, "activeAccountNumber": act, "accounts": [
    acct(1, v[0], v[1], g(4), g(6)),
    acct(2, v[2], v[3], g(5), g(7))]}))
PY
}

tick() {  # invoke the real tick against the current fixture; leaves calls/runs/status
    # warm-state.json MUST be cleared: it lives in $PSScriptRoot (= $S) and its
    # 20-minute floor would make every warm case after the first silently no-op.
    rm -f "$S/calls" "$S/runs" "$S/status.txt" "$S/warm-state.json"
    # Each scenario is an independent fleet. Persistence is tested separately.
    rm -f "$S/collector.json" "$S/warm-outcomes.json" "$S/attempt-budget.json"
    CSWAP_BIN="$(winpath "$STUB")" \
    FIXTURE="$(winpath "$S/fixture.json")" \
    CALLS="$(winpath "$S/calls")" \
    RUNS="$(winpath "$S/runs")" \
    RUNRC="${RUNRC:-0}" \
        "$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$(winpath "$S/tick.ps1")" -CswapExecutable "$(winpath "$STUB")" -CodexExecutable "$(winpath "$S/missing-codex.exe")" >/dev/null 2>&1
}

runw() {  # runw <name> <expected warmed slot or "none"> [substring required in status head]
    tick
    local wm; wm=$(cat "$S/runs" 2>/dev/null | tr -d '\r\n '); wm=${wm:-none}
    local head; head=$(head -1 "$S/status.txt" 2>/dev/null || true)
    local r="PASS"
    if [ ! -s "$S/status.txt" ]; then r="FAIL(no status.txt)"
    elif [ "$wm" != "$2" ]; then r="FAIL"
    elif [ $# -ge 3 ] && [ -n "${3:-}" ]; then
        case "$head" in *"$3"*) ;; *) r="FAIL(status text)";; esac
    fi
    case "$r" in PASS) PASS=$((PASS+1));; *) FAIL=$((FAIL+1));; esac
    printf '%-42s warm=%-5s want=%-5s  %s\n' "$1" "$wm" "$2" "$r"
}

run() {  # run <name> <expected switch target or "none"> [substring required in the status head]
    tick
    local sw; sw=$(cat "$S/calls" 2>/dev/null | tr -d '\r\n'); sw=${sw:-none}
    local head; head=$(head -1 "$S/status.txt" 2>/dev/null || true)
    local r="PASS"
    # LIVENESS FIRST. tick.ps1 is the sole writer of status.txt and always rewrites
    # it (tick.ps1:1-9,160), so a missing/empty file means the tick never ran at all.
    # Without this check a completely dead harness scores 5/8 and looks healthy.
    if [ ! -s "$S/status.txt" ]; then r="FAIL(no status.txt)"
    elif [ "$sw" != "$2" ]; then r="FAIL"
    elif [ $# -ge 3 ] && [ -n "${3:-}" ]; then
        # A leading '!' inverts the assertion: the text must be ABSENT. Needed to
        # pin that a self-healing status never triggers a re-login call to action.
        case "$3" in
            "!"*) case "$head" in *"${3#!}"*) r="FAIL(status text present)";; esac ;;
            *)    case "$head" in *"$3"*) ;; *) r="FAIL(status text)";; esac ;;
        esac
    fi
    case "$r" in PASS) PASS=$((PASS+1));; *) FAIL=$((FAIL+1));; esac
    printf '%-42s switch=%-5s want=%-5s  %s\n' "$1" "$sw" "$2" "$r"
    [ -n "$head" ] && printf '      %s\n' "$head"
}

echo "== core behaviour =="
# Every fixture below MUST carry a 7d figure for both slots (2026-08-30). Since the
# 2026-08-20 absent-7d flip (tick.ps1 Test-Ok), a slot with no weekly window is
# INELIGIBLE -- so a fixture that omits one no longer tests what its name says, it
# tests "nothing is eligible" and passes or fails for the wrong reason. Twelve cases
# here were left in that state when the flip was committed; see § the 7d gate.
mk 1 54 30 10 30 10 10 ; run "preference returns to work sub"      2
mk 1 54 30 76 30 10 10 ; run "anti-thrash declines marginal"       none
mk 2 95 30 95 30 10 10 ; run "both low -> no switch"               none

echo "== the 7d gate (otherwise blocked until slot 2 reports weekly) =="
# 96 => 4% headroom, under margin7dWork (5). This case used to read 95, which was
# exactly ON the work floor and so flipped to "eligible" the moment the per-tier
# margin landed on 2026-08-28 -- a boundary fixture pinning a rule by one point.
# The gate it tests still exists; it just sits lower for a work slot now, and the
# reserve's stricter floor is covered in § per-tier weekly margin.
mk 1 54 30 10 30 20 96  ; run "7d gate blocks an otherwise-fine sub" none
# EXPECTATION INVERTED 2026-08-30, and this is the whole point of the case -- do not
# "restore" it. Absent 7d was eligible until 2026-08-20, when the owner confirmed
# Anthropic had patched the missing weekly window and absent could only mean a failed
# read. tick.ps1 flipped that day; commit 937c5c0 shipped the flip touching README.md
# and tick.ps1 and NO test, so this case went on asserting the superseded rule -- its
# name already read as the new rule while its expectation encoded the old one. The
# reasoning for BOTH halves is in tick.ps1 Test-Ok; read it before touching this.
# Kept in step with ops-bot slots.tests.ps1 "null 7d is NOT usable".
mk 1 54 30 10 30 20 none; run "absent 7d = UNKNOWN -> ineligible"    none

echo "== freshness (regression: the 2026-07-30 bug) =="
# cswap polls a NON-ACTIVE candidate every 300-600s (poll_policy.py
# CANDIDATE_DEFAULT_INTERVAL_S / CANDIDATE_MAX_INTERVAL_S + 10% jitter). A 300s
# ceiling made the reserve permanently ineligible -- the script could never do its
# job. These two pin the fix at maxUsageAgeS=900.
mk 2 0 503 18 0  22 10  ; run "reserve at 503s is USABLE"           none
mk 1 0 503 18 0  22 10  ; run "can switch TO a 503s-old account"    2
mk 2 0 4000 18 4000 22 10 ; run "4000s really is stale -> hold"     none

echo "== dead credential vs spent quota (regression: the 2026-07-31 incident) =="
# A dead credential and an exhausted quota were indistinguishable: both make
# $anyEligible false, so status.txt said "BOTH LOW, no switch helps" -- i.e. "wait
# for the reset" -- when the only fix was a re-login. That cost ~2h of silent
# no-failover on 2026-07-31 and misdirected the diagnosis twice.
mk 2 0 0 91 30 none none relogin_required ok
run "dead slot 1 + spent slot 2 -> re-login"  none "NEEDS RE-LOGIN"
mk 2 0 0 10 30 none none relogin_required ok
run "dead reserve is flagged even when active is fine" none "NEEDS RE-LOGIN"
# token_expired is "retried automatically" (json_output.py:143) -- a transient the
# tick must NOT escalate into a human call to action.
mk 2 0 0 10 30 none none token_expired ok
run "token_expired is transient, not a re-login" none '!NEEDS RE-LOGIN'

echo "== warm: opening cold windows (plan 2026-08-09-cswap-warm) =="
# COLD is the case no live fixture could produce on demand: a window that has
# expired into nothing. Verified shape (W1/W2): fiveHour PRESENT, pct 0, resetsAt
# EMPTY. Note h5 computes to 100.0 for a cold slot -- the whole point of these
# cases is that a guard written against h5 would never fire.
mkc() {  # mkc <active> <c1> <p5_1> <age1> <p7_1> <c2> <p5_2> <age2> <p7_2>   (c = 1 -> cold)
"$PY_BIN" - "$@" > "$S/fixture.json" <<'PY'
import sys, json
from datetime import datetime, timezone, timedelta
act = int(sys.argv[1]); v = sys.argv[2:]
def acct(n, cold, p5, age, p7):
    five = {"pct": 0.0, "resetsAt": ""} if cold == "1" else \
           {"pct": float(p5), "resetsAt": "2026-08-09T18:00:00+00:00"}
    u = {"fiveHour": five}
    if p7 not in ("none", None, ""):
        u["sevenDay"] = {"pct": float(p7),
                         "resetsAt": (datetime.now(timezone.utc) + timedelta(days=6)).isoformat()}
    return {"number": n, "email": f"a{n}@x", "active": n == act,
            "usageStatus": "ok", "usage": u, "usageAgeSeconds": float(age)}
print(json.dumps({"schemaVersion": 1, "activeAccountNumber": act,
                  "accounts": [acct(1, v[0], v[1], v[2], v[3]),
                               acct(2, v[4], v[5], v[6], v[7])]}))
PY
}
pol() {  # pol <warm true|false> <pattern> [warmMin7d]
"$PY_BIN" - "$@" > "$S/policy.json" <<'PY'
import sys, json
print(json.dumps({"prefer": [1, 2], "margin5h": 25, "margin7d": 10, "hysteresis": 10,
    "maxUsageAgeS": 900, "warm": sys.argv[1] == "true", "pattern": sys.argv[2],
    "warmMin7d": float(sys.argv[3]) if len(sys.argv) > 3 else 20.0,
    "warmFloorMin": 20, "warmPhaseWindowMin": 15}))
PY
}

pol true maintain
mkc 2 1 0 30 50  0 40 30 50 ; runw "cold slot is warmed"                   1
mkc 2 0 40 30 50 0 40 30 50 ; runw "live window is never warmed"           none
# p7 is 7d USED, so 95 => 5% headroom, below warmMin7d=20. (Passing 5 here reads as
# "nearly empty" but means 95% headroom — the same used-vs-headroom inversion that
# status.txt prints deliberately. Cost one FAIL on 2026-08-09; keep the note.)
mkc 2 1 0 30 95  0 40 30 50 ; runw "7d below warmMin7d blocks the warm"    none
mkc 2 1 0 4000 50 0 40 30 50; runw "stale slot is never warmed"            none
pol false maintain
mkc 2 1 0 30 50  0 40 30 50 ; runw "warm:false is a hard off switch"       none
# A ping that FAILS must not be recorded as a warm. The first implementation
# swallowed the error and reported success forever -- the exact way a broken
# warmer on another machine would stay invisible.
pol true maintain
mkc 2 1 0 30 50  0 40 30 50
RUNRC=1 runw "a failed ping reports WARM FAILED"  1  "WARM FAILED"
# A dead credential yields usage:null, so fiveHour is absent entirely. That is NOT
# cold -- there is no window to open and the fix is a human, not a ping.
pol true maintain
mk 2 0 0 10 30 none none relogin_required ok
runw "dead credential is not 'cold'"                                       none
cp "$HERE/tests/legacy-policy.json" "$S/policy.json" || exit 2

echo "== order: soonest-reset (shortest-expiry-first drain) =="
# Quota in a window expiring in 20 minutes is worth more RIGHT NOW than the same
# quota expiring in four hours, because only one of them is about to vanish. These
# need per-account reset times, which mk/mkc cannot express (both hardcode one).
mkr() {  # mkr <active> <r1_min|cold> <p5_1> <r2_min|cold> <p5_2>   (r = minutes until reset)
"$PY_BIN" - "$@" > "$S/fixture.json" <<'PY'
import sys, json
from datetime import datetime, timezone, timedelta
act = int(sys.argv[1]); v = sys.argv[2:]
now = datetime.now(timezone.utc)
def acct(n, r, p5):
    five = {"pct": 0.0, "resetsAt": ""} if r == "cold" else \
           {"pct": float(p5), "resetsAt": (now + timedelta(minutes=float(r))).isoformat()}
    # A healthy weekly window on BOTH slots is mandatory, not scenery (2026-08-30):
    # this section is about 5h reset ORDER, and since the absent-7d flip a fixture
    # without one makes every slot ineligible -- which turned the three want=2 cases
    # red and, worse, made the four want=none cases pass vacuously. A section that
    # asserts nothing while printing all-green is the failure mode to avoid here.
    return {"number": n, "email": f"a{n}@x", "active": n == act, "usageStatus": "ok",
            "usage": {"fiveHour": five,
                      "sevenDay": {"pct": 10.0,
                                   "resetsAt": (now + timedelta(days=6)).isoformat()}},
            "usageAgeSeconds": 30.0}
print(json.dumps({"schemaVersion": 1, "activeAccountNumber": act,
                  "accounts": [acct(1, v[0], v[1]), acct(2, v[2], v[3])]}))
PY
}
ord() {  # ord <order> [reserve json array] [resetLeadMin]
"$PY_BIN" - "$@" > "$S/policy.json" <<'PY'
import sys, json
print(json.dumps({"prefer": [1, 2], "margin5h": 25, "margin7d": 10, "hysteresis": 10,
    "maxUsageAgeS": 900, "warm": False, "order": sys.argv[1],
    "reserve": json.loads(sys.argv[2]) if len(sys.argv) > 2 else [],
    "resetLeadMin": float(sys.argv[3]) if len(sys.argv) > 3 else 10.0}))
PY
}

# prefer=[1,2]: slot 1 is nominally first, so a switch to 2 can ONLY come from expiry.
ord soonest-reset '[]'
mkr 1 240 30 20 60 ; run "takes over the sooner-expiring slot"   2
mkr 1 20 60 240 30 ; run "stays put when active expires first"   none
mkr 1 240 30 235 30; run "lead below resetLeadMin -> no switch"  none
mkr 1 240 30 cold 0; run "COLD sorts last (not perishing)"       none
# The band that protects a HEADROOM ordering would block exactly the takeover this
# ordering exists to make: 30% headroom is over margin5h but under margin5h+hysteresis.
mkr 1 240 90 20 70 ; run "expiring slot taken despite thin headroom" 2
# Reserve is last whatever its reset says -- and leaving it is never lead-gated.
ord soonest-reset '[2]'
mkr 1 240 30 20 60 ; run "reserve not taken though it expires first" none
ord soonest-reset '[1]'
mkr 1 20 60 240 30 ; run "leaving the reserve ignores the lead rule" 2
cp "$HERE/tests/legacy-policy.json" "$S/policy.json" || exit 2

echo "== warm: pattern -> offsets (fleet-shape portability) =="
# Offsets are pure: (pattern, prefer, weights) -> slot:minute. Testing the function
# directly rather than through a tick keeps these independent of wall-clock time,
# which is what lets them assert fleet shapes nobody here owns (Max20x, N=5, N=1).
cp "$HERE/src/providers/claude.ps1" "$S/funcs.ps1" || exit 2
cat > "$S/offsets.ps1" <<'EOF'
. (Join-Path $PSScriptRoot 'funcs.ps1')
$spec = Get-Content (Join-Path $PSScriptRoot 'spec.json') -Raw | ConvertFrom-Json
$off = Get-WarmOffsets $spec.policy @($spec.prefer | ForEach-Object { [int]$_ })
if ($null -eq $off) { Write-Output 'null'; exit 0 }
Write-Output ((($off.Keys | Sort-Object) | ForEach-Object { "$_=$($off[$_])" }) -join ' ')
EOF
offs() {  # offs <name> <expected> <spec json>
    printf '%s' "$3" > "$S/spec.json"
    local got; got=$("$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$(winpath "$S/offsets.ps1")" 2>&1 | tr -d '\r' | tail -1)
    local r="PASS"; [ "$got" = "$2" ] || r="FAIL"
    case "$r" in PASS) PASS=$((PASS+1));; *) FAIL=$((FAIL+1));; esac
    printf '%-42s %-24s want=%-24s %s\n' "$1" "$got" "$2" "$r"
}

offs "maintain = no phasing"        "null" \
     '{"prefer":[3,2,1],"policy":{"pattern":"maintain"}}'
offs "N=1 degrades to maintain"     "null" \
     '{"prefer":[1],"policy":{"pattern":"even"}}'
offs "even, N=3 -> 0/100/200"       "1=200 2=100 3=0" \
     '{"prefer":[3,2,1],"policy":{"pattern":"even"}}'
offs "even, N=5 -> hourly"          "1=240 2=180 3=120 4=60 5=0" \
     '{"prefer":[5,4,3,2,1],"policy":{"pattern":"even"}}'
offs "synced -> all together"       "1=0 2=0 3=0" \
     '{"prefer":[3,2,1],"policy":{"pattern":"synced"}}'
# The target shape: N=4 g=2 => two pairs 2.5h apart => 2h burst / 30m gap.
offs "clustered g2, N=4 -> 0/0/150/150" "1=150 2=150 3=0 4=0" \
     '{"prefer":[4,3,2,1],"policy":{"pattern":"clustered","warmGroup":2}}'
offs "clustered g1 == even"         "1=200 2=100 3=0" \
     '{"prefer":[3,2,1],"policy":{"pattern":"clustered","warmGroup":1}}'
# THE MIXED-FLEET CASE. A Max20x beside a Pro must hold the floor ~20x longer, so
# the Pro's window opens at minute 290, NOT at the even-spacing answer of 150.
# This is the assertion that makes the system correct for someone else's fleet.
offs "mixed weights are proportional, not even" "1=0 2=290" \
     '{"prefer":[1,2],"policy":{"pattern":"even","weights":{"1":20,"2":1}}}'
offs "absent weights default to 1"  "1=150 2=0" \
     '{"prefer":[2,1],"policy":{"pattern":"even","weights":{"2":1}}}'

echo "== hold: the self-expiring lease =="
# WHY A LEASE RATHER THAN A FLAG, since every case below only makes sense given it:
# the failure that matters is the holding job dying BEFORE it can clear a durable
# "disabled" flag, and a cleanup step only executes on the one path where nothing
# went wrong. So the hold carries its own expiry and every ambiguity FAILS OPEN.
# The three "fails OPEN" cases are the load-bearing ones -- if any of them ever
# inverts, a corrupt file silently strands rotation off for good, which is the exact
# trap this design exists to remove.
cp "$HERE/tests/legacy-policy.json" "$S/policy.json" || exit 2
hold() {  # hold <minutes from now, may be negative> [reason]   |   hold raw <literal json>
    if [ "$1" = "raw" ]; then printf '%s' "$2" > "$S/hold.json"; return; fi
    "$PY_BIN" - "$1" "${2:-batch job}" > "$S/hold.json" <<'PY'
import sys, json
from datetime import datetime, timezone, timedelta
u = datetime.now(timezone.utc) + timedelta(minutes=float(sys.argv[1]))
print(json.dumps({"until": u.isoformat().replace("+00:00", "Z"), "reason": sys.argv[2]}))
PY
}
nohold() { rm -f "$S/hold.json"; }   # tick() does NOT clear hold.json -- it is input, not output

nohold
mk 1 54 30 10 30 10 10 ; run "no hold -> switches normally"           2
hold 120
mk 1 54 30 10 30 10 10 ; run "active hold suppresses the switch"      none  "HELD"
mk 1 54 30 10 30 10 10 ; run "hold names the switch it suppressed"    none  "suppressed -> slot 2"
# A hold must never claim a suppression that never happened, or the status line
# stops being evidence of anything.
mk 1 54 30 76 30 10 10 ; run "held with nothing to suppress"          none  "!suppressed"
hold -1
mk 1 54 30 10 30 10 10 ; run "expired lease rotates again, unattended" 2    "!HELD"
hold raw '{"until": "not a timestamp", "reason": "x"}'
mk 1 54 30 10 30 10 10 ; run "unparseable until fails OPEN"           2     "!HELD"
hold raw '{oh no'
mk 1 54 30 10 30 10 10 ; run "malformed json fails OPEN"              2     "!HELD"
hold raw '{"reason": "no until field"}'
mk 1 54 30 10 30 10 10 ; run "missing until fails OPEN"               2     "!HELD"
# The hold suppresses the SWITCH ONLY. Warming goes through `cswap run`, which is
# terminal-scoped and never moves the global active account -- so it is safe under a
# hold and valuable during one: it is what leaves an open window for when you come
# back. If this regresses, an overnight job ends with every window dead.
pol true maintain
hold 120
mkc 2 1 0 30 50  0 40 30 50 ; runw "warming still runs under a hold"       1
cp "$HERE/tests/legacy-policy.json" "$S/policy.json" || exit 2
nohold

echo "== per-tier weekly margin (2026-08-28) =="
# The 20% weekly buffer exists to leave capacity to come BACK to. The fleet already
# holds that on one slot -- `reserve`, which is what the label means -- so applying
# the same 20% to every slot reserved the same thing three times. Measured
# 2026-08-27: slots 2 and 3 sat at 88%/84% weekly with 28% of the week's budget
# refused, slot 3 idle with 64% of its 5h window free, while the reserve had 78% of
# its week untouched. A 7d window is use-it-or-lose-it against a fixed calendar
# reset, so that 28% was not saved -- it was going to evaporate.
pt() {  # pt <reserve json array> [margin7dWork|"absent"]
"$PY_BIN" - "$@" > "$S/policy.json" <<'PY'
import sys, json
p = {"prefer": [1, 2], "margin5h": 25, "margin7d": 20, "hysteresis": 10,
     "maxUsageAgeS": 900, "warm": False, "order": "soonest-reset",
     "reserve": json.loads(sys.argv[1])}
if len(sys.argv) > 2 and sys.argv[2] != "absent":
    p["margin7dWork"] = float(sys.argv[2])
print(json.dumps(p))
PY
}
# slot 1 = reserve, spent on its 5h; slot 2 = work, 88% through its week.
pt '[1]' 5
mk 1 90 30 10 30 22 88 ; run "work slot past 80% weekly is taken"       2
# Identical numbers with margin7dWork ABSENT. An older policy.json -- or another
# machine's, this file ships via personal-sync -- must keep the pre-2026-08-28 rule
# rather than silently inherit a laxer ceiling it never opted into.
pt '[1]' absent
mk 1 90 30 10 30 22 88 ; run "no margin7dWork -> old rule still holds"  none
# The reserve is NOT released. Slot 1 is the reserve at 88% weekly with a fresh 5h
# window; slot 2 is spent on 5h. Nothing may serve -- that is the buffer working.
pt '[1]' 5
mk 2 10 30 90 30 88 50 ; run "reserve past 80% weekly stays blocked"    none  "no headroom"
# Degraded slots rank by MOST WEEKLY HEADROOM, not by reset time: down there the week
# is the binding constraint, and ranking two nearly-spent slots by 5h reset can hand
# you the one with 12% of its week over the one with 16%.
# active=3 is deliberate -- it is not in `prefer`, so the active slot reads as unknown,
# every slot becomes a candidate, and the switch lands on ranked[0]. That is the only
# way to observe the ORDER here rather than a single slot's eligibility.
pt '[]' 5
mk 3 10 30 10 30 84 88 ; run "degraded: most weekly headroom wins"      1
mk 3 10 30 10 30 88 84 ; run "degraded: ...and again, reversed"         2
# A healthy slot outranks a degraded one even though `prefer` lists the degraded one
# first -- otherwise the release would quietly start spending a nearly-spent week
# ahead of a full one.
mk 3 10 30 10 30 88 10 ; run "healthy outranks degraded despite prefer" 2

# The warm floor MUST move with the margin. A slot the tick will now select but will
# never pre-warm is eligible-but-cold: selectable on paper, nothing accruing in
# practice, which buys none of the capacity this whole change exists to recover.
ptw() {  # ptw <reserve json array>
"$PY_BIN" - "$@" > "$S/policy.json" <<'PY'
import sys, json
print(json.dumps({"prefer": [1, 2], "margin5h": 25, "margin7d": 20, "margin7dWork": 5,
    "maxUsageAgeS": 900, "warm": True, "pattern": "maintain", "warmMin7d": 20,
    "warmMin7dWork": 5, "warmFloorMin": 20, "warmPhaseWindowMin": 15,
    "reserve": json.loads(sys.argv[1])}))
PY
}
# p7=95 => 5% headroom: exactly at warmMin7dWork, far under warmMin7d.
ptw '[2]'
mkc 2 1 0 30 95  0 40 30 50 ; runw "work slot at 95% weekly is warmed"     1
ptw '[1]'
mkc 2 1 0 30 95  0 40 30 50 ; runw "reserve at 95% weekly is not warmed"   none
cp "$HERE/tests/legacy-policy.json" "$S/policy.json" || exit 2

echo "== stale quarantine: a verdict cswap stopped re-testing (2026-08-31, F24) =="
# cswap quarantines a slot after ONE invalid_grant and then never fetches it again
# (AUTH_DEAD_STRIKES=1; _row_eligible short-circuits on the strike before any
# scheduling gate). No switch/backup path clears the strike -- only add/re-login --
# so a slot can be HEALTHY and reported dead indefinitely. Measured 2026-08-31:
# slot 1 sat relogin_required for 64.8h with nextPollAt AND backoffUntil both 64.8h
# in the past, while the account answered fine and the fleet ran the other two to
# 91%/83% of their 5h windows.
#
# The signal is cswap's PUBLIC shape for a null-usage row (json_output.py:203-207):
# lastGoodUsage / lastGoodFetchedAt / lastGoodAgeSeconds. Pinning that shape here is
# the point -- reading its private cache/usage.json instead was rejected as coupling
# to another tool's internals.
mkq() {  # mkq <active> <a1_status> <a1_lastGoodAgeS|none> <a2_5h> <a2_7d>
"$PY_BIN" - "$@" > "$S/fixture.json" <<'PY'
import sys, json
from datetime import datetime, timezone, timedelta
act, st, age, p5, p7 = sys.argv[1:6]
act = int(act)
now = datetime.now(timezone.utc)
# Slot 1: the quarantined one. usage is null and usageAgeSeconds is ABSENT -- the
# real shape cswap emits for a non-ok row; it swaps in lastGood* instead.
a1 = {"number": 1, "email": "a1@x", "active": act == 1,
      "usageStatus": st, "usage": None}
if age not in ("none", "", None):
    a1["lastGoodAgeSeconds"] = float(age)
    a1["lastGoodFetchedAt"] = (now - timedelta(seconds=float(age))).isoformat()
    a1["lastGoodUsage"] = {"fiveHour": {"pct": 0.0, "resetsAt": ""},
                           "sevenDay": {"pct": 23.0, "resetsAt": ""}}
a2 = {"number": 2, "email": "a2@x", "active": act == 2, "usageStatus": "ok",
      "usage": {"fiveHour": {"pct": float(p5), "resetsAt": "2026-08-31T18:00:00+00:00"},
                "sevenDay": {"pct": float(p7),
                             "resetsAt": (now + timedelta(days=6)).isoformat()}},
      "usageAgeSeconds": 30.0}
print(json.dumps({"schemaVersion": 1, "activeAccountNumber": act, "accounts": [a1, a2]}))
PY
}
sq() {  # sq <staleQuarantineS|absent>
"$PY_BIN" - "$@" > "$S/policy.json" <<'PY'
import sys, json
p = {"prefer": [1, 2], "margin5h": 25, "margin7d": 20, "margin7dWork": 5,
     "hysteresis": 10, "maxUsageAgeS": 900, "warm": False, "reserve": []}
if sys.argv[1] != "absent":
    p["staleQuarantineS"] = float(sys.argv[1])
print(json.dumps(p))
PY
}

# Recently checked: cswap is still trying, so "re-login" is the honest instruction.
sq absent
mkq 2 relogin_required 300 10 10
run "recently-checked dead slot still says re-login"  none "NEEDS RE-LOGIN"
# 65h unchecked: cswap has stopped asking. Saying "-> cswap add" here is the
# instruction that cost 2.7 days.
mkq 2 relogin_required 234000 10 10
run "unchecked 65h reports QUARANTINE STALE"          none "QUARANTINE STALE"
mkq 2 relogin_required 234000 10 10
run "...and does NOT tell you to re-login"            none "!NEEDS RE-LOGIN"
# The 6h default, pinned from both sides.
mkq 2 relogin_required 21599 10 10
run "just under the 6h default is not stale"          none "NEEDS RE-LOGIN"
mkq 2 relogin_required 21601 10 10
run "just over the 6h default is stale"               none "QUARANTINE STALE"
# An explicit knob overrides the default.
sq 3600
mkq 2 relogin_required 7200 10 10
run "explicit staleQuarantineS is honored"            none "QUARANTINE STALE"
# ABSENT lastGoodAgeSeconds must behave exactly as before this change -- an older
# cswap does not emit the field, and staleness is never guessed.
sq absent
mkq 2 relogin_required none 10 10
run "absent lastGoodAgeSeconds -> unchanged behaviour" none "NEEDS RE-LOGIN"
# no_credentials rides the same rule; it is in $needsHuman too.
mkq 2 no_credentials 234000 10 10
run "no_credentials goes stale the same way"          none "QUARANTINE STALE"
# THE LOAD-BEARING ONE: this changes the MESSAGE, never the eligibility maths. A
# stale-quarantined slot is still unusable -- cswap reports no live usage for it, so
# there is nothing to switch to. If this ever inverts, the tick starts selecting a
# slot it cannot measure, which is strictly worse than the bug being fixed.
mkq 2 relogin_required 234000 95 10
run "a stale-quarantined slot is still NOT selected"  none "QUARANTINE STALE"
cp "$HERE/tests/legacy-policy.json" "$S/policy.json" || exit 2

echo "== probe: ACT on a stale quarantine, don't just report it (2026-09-06) =="
# The section above proves the tick SAYS the right thing about a stale quarantine.
# This one proves it DOES something. Measured cost of report-only: slot 2 sat dead
# for 28h while every tick printed QUARANTINE STALE, and was revived by accident
# when the cswap TUI switched onto it. A strike binds to the credential GENERATION
# (cswap usage_store.py token_dead), so any ping that refreshes clears it.
#
# The probe pings via `cswap run` -- terminal-scoped, never moves the active
# account. THAT is the invariant these cases exist to pin: a switch-based probe is
# what dropped the fleet onto a dead credential on 2026-09-05.

# tick() deletes warm-state.json every call, which is right for independent cases
# and wrong for the floor: the floor is only observable across TWO ticks. This
# variant keeps the state so the second tick sees the first one's stamp.
tick_keep() {
    rm -f "$S/calls" "$S/runs" "$S/status.txt"
    CSWAP_BIN="$(winpath "$STUB")" \
    FIXTURE="$(winpath "$S/fixture.json")" \
    CALLS="$(winpath "$S/calls")" \
    RUNS="$(winpath "$S/runs")" \
    RUNRC="${RUNRC:-0}" \
        "$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$(winpath "$S/tick.ps1")" -CswapExecutable "$(winpath "$STUB")" -CodexExecutable "$(winpath "$S/missing-codex.exe")" >/dev/null 2>&1
}

runp() {  # runp <name> <expected pinged slot or "none"> <expected switch or "none"> [keep]
    if [ "${4:-}" = "keep" ]; then tick_keep; else tick; fi
    local pg; pg=$(cat "$S/runs" 2>/dev/null | tr -d '\r\n '); pg=${pg:-none}
    local sw; sw=$(cat "$S/calls" 2>/dev/null | tr -d '\r\n'); sw=${sw:-none}
    local r="PASS"
    if [ ! -s "$S/status.txt" ]; then r="FAIL(no status.txt)"
    elif [ "$pg" != "$2" ]; then r="FAIL(probe)"
    elif [ "$sw" != "$3" ]; then r="FAIL(SWITCHED - probe must never switch)"
    fi
    case "$r" in PASS) PASS=$((PASS+1));; *) FAIL=$((FAIL+1));; esac
    printf '%-42s ping=%-5s want=%-5s sw=%-5s  %s\n' "$1" "$pg" "$2" "$sw" "$r"
}

# Two quarantined slots, for the one-per-tick bound. Same null-usage shape as mkq.
mkq2() {  # mkq2 <active> <a1_ageS> <a2_ageS>
"$PY_BIN" - "$@" > "$S/fixture.json" <<'PY'
import sys, json
from datetime import datetime, timezone, timedelta
act, a1age, a2age = int(sys.argv[1]), sys.argv[2], sys.argv[3]
now = datetime.now(timezone.utc)
def dead(n, age):
    a = {"number": n, "email": "a%d@x" % n, "active": act == n,
         "usageStatus": "relogin_required", "usage": None}
    a["lastGoodAgeSeconds"] = float(age)
    a["lastGoodFetchedAt"] = (now - timedelta(seconds=float(age))).isoformat()
    a["lastGoodUsage"] = {"fiveHour": {"pct": 0.0, "resetsAt": ""},
                          "sevenDay": {"pct": 23.0, "resetsAt": ""}}
    return a
print(json.dumps({"schemaVersion": 1, "activeAccountNumber": act,
                  "accounts": [dead(1, a1age), dead(2, a2age)]}))
PY
}

# A slot cswap stopped re-testing gets pinged -- and warm is FALSE in sq's policy,
# so this also pins that the probe is independent of the warmer.
sq absent
mkq 2 relogin_required 234000 10 10
runp "stale-quarantined slot is probed"        1    none
# THE LOAD-BEARING CASE. If the probe ever reaches for `cswap switch`, it
# reintroduces the 2026-09-05 incident: the fleet parked on a dead credential.
runp "...and the probe NEVER switches"         1    none
# Still-being-retried: cswap has not given up, so there is nothing stale to re-test
# and a ping would just spend quota.
mkq 2 relogin_required 300 10 10
runp "recently-checked dead slot is NOT probed" none none
# The floor is the same staleness that defined $stuck -- no new knob. Second tick in
# a row must not re-ping, or a dead slot is pinged every 5 minutes forever.
sq absent
mkq 2 relogin_required 234000 10 10
runp "first tick probes"                       1    none
runp "second tick respects the floor"          none none keep
# Bounded like the warmer: a ping can take up to 90s and the task is IgnoreNew, so
# three dead slots must not be able to wedge the 5-minute timer.
rm -f "$S/warm-state.json"
mkq2 1 234000 234000
runp "at most one probe per tick"              1    none

echo "== tripwire: per-model (scoped) weekly windows are surfaced, not ranked on =="
# cswap emits usage.scoped (per-model weekly limits); every ranking decision here
# reads only fiveHour/sevenDay. This fleet is Pro and emits none, so the tripwire
# only has to make one VISIBLE the day it appears -- ranking on it would be building
# for a case that has never occurred.
mksc() {  # mksc <active> <a1_5h> <a1_7d> <scoped_name> <scoped_pct>
"$PY_BIN" - "$@" > "$S/fixture.json" <<'PY'
import sys, json
from datetime import datetime, timezone, timedelta
act, p5, p7, sname, spct = sys.argv[1:6]
act = int(act); now = datetime.now(timezone.utc)
def acct(n, scoped):
    u = {"fiveHour": {"pct": float(p5), "resetsAt": (now + timedelta(hours=2)).isoformat()},
         "sevenDay": {"pct": float(p7), "resetsAt": (now + timedelta(days=6)).isoformat()}}
    if scoped:
        u["scoped"] = [{"name": sname, "pct": float(spct),
                        "resetsAt": (now + timedelta(days=3)).isoformat()}]
    return {"number": n, "email": "a%d@x" % n, "active": act == n,
            "usageStatus": "ok", "usage": u, "usageAgeSeconds": 30.0}
print(json.dumps({"schemaVersion": 1, "activeAccountNumber": act,
                  "accounts": [acct(1, True), acct(2, False)]}))
PY
}
cp "$HERE/tests/legacy-policy.json" "$S/policy.json" || exit 2

# Assert on status.txt only. Whether these fixtures also switch is irrelevant to
# the tripwire and asserting it would pin unrelated ranking behaviour into this
# section -- a test that fails for a reason its name does not mention.
grepstat() {  # grepstat <name> <pattern> <want present|absent>
    tick
    local r
    if [ ! -s "$S/status.txt" ]; then r="FAIL(no status.txt)"
    elif grep -q "$2" "$S/status.txt" 2>/dev/null; then
        if [ "$3" = "present" ]; then r="PASS"; else r="FAIL(present, want absent)"; fi
    else
        if [ "$3" = "absent" ]; then r="PASS"; else r="FAIL(absent, want present)"; fi
    fi
    case "$r" in PASS) PASS=$((PASS+1));; *) FAIL=$((FAIL+1));; esac
    printf '%-42s %s\n' "$1" "$r"
}

mksc 1 10 10 Opus 97
grepstat "a scoped window is surfaced"        "SCOPED WINDOWS NOT RANKED ON" present
grepstat "...naming the model and its pct"    "Opus 97%"                     present
# A fleet with no scoped windows must print nothing extra -- the tripwire is silent
# until the day it matters, or it becomes noise nobody reads.
mkc 2 1 0 30 50  0 40 30 50
grepstat "no scoped windows -> no tripwire"   "SCOPED WINDOWS"               absent
cp "$HERE/tests/legacy-policy.json" "$S/policy.json" || exit 2

echo "== mixed providers: Codex must not interrupt Claude warming =="
pol true maintain
"$PY_BIN" - "$(winpath "$S")" <<'PY'
import pathlib,sys,json
root=pathlib.Path(sys.argv[1]);p=root/'policy.json'
obj=json.loads(p.read_text());obj['codex']={'slots':[{'id':'test','home':str(root)}],'prefer':['test']}
p.write_text(json.dumps(obj))
PY
mkc 2 1 0 30 50  0 40 30 50
runw "Codex missing: Claude still warms" 1
grepstat "Codex missing is a scoped status" "codex_missing" present
"$PY_BIN" - "$(winpath "$S/policy.json")" <<'PY'
import pathlib,sys,json
p=pathlib.Path(sys.argv[1]);obj=json.loads(p.read_text());obj['codex']['slots'][0]['id']='invalid/slot';p.write_text(json.dumps(obj))
PY
runw "Codex invalid policy: Claude still warms" 1

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
