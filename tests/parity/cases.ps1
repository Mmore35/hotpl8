# Parity cases for `hotpl8 status` and `hotpl8 explain`.
#
# A case is a set of state files, written as JSON text so both PowerShell versions and the
# compiled reader read the same bytes. Times are tokens relative to the instant the case
# runs at (see Expand-Hotpl8ParityText). Every name, label and reading here is fictional.
#
#   name     unique
#   files    file name -> JSON text, written into the state directory
#   preview  JSON text for -PreviewPolicy, written outside the state directory
#   macFiles file name -> JSON text that replaces the entry in `files` on macOS, where an
#            absolute path looks different
#   noBom    write the files without a byte order mark
#   expect   what the compiled reader must do when PowerShell answers:
#              'answer'   print the same answer (the default)
#              'decline'  leave the answer to PowerShell
#              'either'   decline, or print the same answer
#            A hash table sets it per mode: status, explain, status-json, explain-json,
#            and default.
#
# When PowerShell fails, the reader must decline; no case can ask for anything else.

function Edit-Hotpl8ParityText([string]$Text,[string]$Old,[string]$New) {
    $first=$Text.IndexOf($Old,[StringComparison]::Ordinal)
    if($first -lt 0 -or $Text.IndexOf($Old,$first+1,[StringComparison]::Ordinal) -ge 0){throw ('A parity case edit must match exactly once: '+$Old)}
    $Text.Remove($first,$Old.Length).Insert($first,$New)
}
function Join-Hotpl8ParityStatus([string[]]$Slots,[string[]]$CodexSlots,[string]$Extra='',[string]$CodexExtra='') {
    '{"generatedAt":"@t-42s@","active":1,"hold":null,"slots":['+($Slots -join ',')+'],"providers":{"codex":{"defaultMeter":"codex","recommendedSlot":"work","slots":['+($CodexSlots -join ',')+']'+$CodexExtra+'}}'+$Extra+'}'
}

function Get-Hotpl8ParityCases {
    $policy='{"schemaVersion":2,"mode":"monitor","prefer":[1,2],"reserve":[2],"capacity":{"1":{"weekly":1,"fiveHour":0.3},"2":{"weekly":5,"fiveHour":1.5}},"labels":{"1":"Everyday","2":"Reserve"},"codex":{"slots":[{"id":"work","label":"Work"},{"id":"personal","label":"Personal"}],"capacity":{"work":{"weekly":5,"fiveHour":1.5},"personal":{"weekly":1,"fiveHour":0.3}},"defaultMeter":"codex","margin5h":25,"margin7d":20,"margin7dWork":5}}'
    $one='{"slot":1,"label":"Everyday","status":"ok","observedAt":"@t-42s@","active":true,"fresh":true,"used5h":38,"used7d":54,"reset5h":"@t+83m@","reset7d":"@t+52h@"}'
    $two='{"slot":2,"label":"Reserve","status":"ok","observedAt":"@t-42s@","active":false,"fresh":true,"used5h":8,"used7d":17,"reset5h":"@t+4h@","reset7d":"@t+5d@"}'
    $work='{"id":"work","label":"Work","status":"ok","observedAt":"@t-42s@","buckets":{"codex":{"status":"observed","windows":{"300":{"usedPercent":26,"remainingPercent":74,"resetsAt":@u+2h@,"anchorState":"observed-active"},"10080":{"usedPercent":41,"remainingPercent":59,"resetsAt":@u+3d@,"anchorState":"observed-active"}}}}}'
    $personal='{"id":"personal","label":"Personal","status":"ok","observedAt":"@t-42s@","buckets":{"codex":{"status":"observed","windows":{"10080":{"usedPercent":89,"remainingPercent":11,"resetsAt":@u+18h@,"anchorState":"observed-active"}}}}}'
    $status=Join-Hotpl8ParityStatus @($one,$two) @($work,$personal)
    $collector='{"schemaVersion":1,"startedAt":"@t-45s@","completedAt":"@t-42s@","status":"ok","scheduled":true,"incompleteRuns":0,"runningSha":"0000000000000000000000000000000000000000","providers":{"claude":{"status":"ok","failures":0,"lastAttemptAt":"@t-44s@","lastSuccessAt":"@t-44s@","nextAttemptAt":"@t+16s@"},"codex":{"status":"ok","failures":0,"lastAttemptAt":"@t-43s@","lastSuccessAt":"@t-43s@","nextAttemptAt":"@t+257s@"}}}'
    $cases=New-Object Collections.ArrayList

    # The two fictional accounts per provider used for the documentation screenshots.
    [void]$cases.Add(@{name='plain';files=@{'policy.json'=$policy;'status.json'=$status}})

    $forecast='"forecast":{"observedAt":"@t-42s@","expectedUsed":57.1,"used":54,"pace":"behind","secondsToLimit":355680,"lastsToReset":true,"recentSecondsToLimit":null,"basis":"cycle-average","confidence":"estimate"}'
    $coldTwo='{"slot":2,"label":"Reserve","status":"ok","observedAt":"@t-42s@","active":false,"fresh":true,"cold":true,"used5h":0,"used7d":17,"reset5h":"","reset7d":"@t+5d@","warmOutcome":{"outcome":"unconfirmed"},"actionBlock":"outside_work_hours"}'
    $operations=Join-Hotpl8ParityStatus @((Edit-Hotpl8ParityText $one '"reset7d":"@t+52h@"}' ('"reset7d":"@t+52h@",'+$forecast+'}')),$coldTwo) @((Edit-Hotpl8ParityText $work '{"status":"observed",' '{"status":"observed","forecast":{"observedAt":"@t-42s@","expectedUsed":57.1,"used":41,"pace":"behind","secondsToLimit":497266,"lastsToReset":true,"recentSecondsToLimit":null,"basis":"cycle-average","confidence":"estimate"},'),$personal) (',"collector":{"startedAt":"@t-45s@","completedAt":"@t-42s@","status":"ok"},"recentActions":[{"provider":"claude","slot":2,"kind":"warm_outcome","reason":"unconfirmed"}]')
    [void]$cases.Add(@{name='operations';files=@{'policy.json'=$policy;'status.json'=$operations}})

    # The shape the collector really writes: every key it emits, in its order, with a
    # stored overview, decisions, plans, scoped windows and a separate collector file.
    $realPolicy=@'
{
  "codex": {
    "capacity": {
      "work": {"evidence": "Counted against the weekly allowance during one busy week.", "weekly": 5},
      "personal": {"evidence": "Smaller plan.", "weekly": 1}
    },
    "defaultMeter": "codex",
    "margin5h": 25,
    "margin7d": 20,
    "margin7dWork": 5,
    "modelMeters": {"example-model-large": "codex", "example-model-small": "codex_bengalfox"},
    "order": "prefer",
    "prefer": ["work", "personal"],
    "slots": [
      {"home": "C:\\Fictional\\codex-work", "id": "work", "label": "Work"},
      {"home": "C:\\Fictional\\codex-personal", "id": "personal", "label": "Personal"}
    ]
  },
  "critical": {"advantagePercent": 10, "drainToZero": false, "dwellSeconds": 60, "enabled": true, "enterPercent": 20, "exitPercent": 25, "floorPercent": 1, "pollSeconds": 60},
  "hysteresis": 10,
  "labels": {"1": "Everyday", "2": "Reserve"},
  "margin5h": 25,
  "margin7d": 20,
  "margin7dWork": 5,
  "maxUsageAgeS": 900,
  "mode": "automate",
  "order": "prefer",
  "pattern": "maintain",
  "prefer": [1, 2],
  "probeEnabled": true,
  "resetLeadMin": 10,
  "schemaVersion": 2,
  "switchEnabled": true,
  "warm": true,
  "warmFloorMin": 30,
  "warmMin7d": 20,
  "warmMin7dWork": 5,
  "warmPhaseWindowMin": 60,
  "weights": {"1": 1, "2": 5}
}
'@
    $realStatus=@'
{
  "active": 1,
  "verdict": "ok",
  "hold": null,
  "proposedSlot": null,
  "actions": {"continuing": true, "probing": true, "switching": true, "warming": true},
  "parkedReadable": [],
  "schemaVersion": 2,
  "generatedAt": "@t-42s@",
  "generationId": "11111111-2222-4333-8444-555555555555",
  "mode": "automate",
  "providers": {
    "codex": {
      "critical": {
        "codex": {"active": false, "basis": "normal policy", "coverage": "2/2", "floorPercent": 1, "pollSeconds": 300, "reason": "normal policy", "selected": "work", "selectedAt": "@t-3h@"},
        "codex_bengalfox": {"active": false, "basis": "normal policy", "coverage": "0/2", "floorPercent": 1, "pollSeconds": 300, "reason": "normal policy", "selected": null, "selectedAt": null}
      },
      "decisions": [
        {"accounts": [{"reason": "eligible", "reserve": false, "slot": "work"}, {"reason": "below_margin", "reserve": false, "slot": "personal"}], "meter": "codex", "policy": "prefer", "selected": "work"},
        {"accounts": [{"reason": "model_quota_unknown", "reserve": false, "slot": "work"}, {"reason": "model_quota_unknown", "reserve": false, "slot": "personal"}], "meter": "codex_bengalfox", "policy": "prefer", "selected": null}
      ],
      "defaultMeter": "codex",
      "elapsedMs": 1840,
      "hold": null,
      "observedAt": "@t-43s@",
      "recommendations": {"codex": "work", "codex_bengalfox": null},
      "recommendedSlot": "work",
      "slots": [
        {
          "buckets": {
            "codex": {
              "blockReason": null,
              "forecast": {"basis": "cycle-average", "confidence": "estimate", "expectedUsed": 57.1, "lastsToReset": true, "observedAt": "@t-43s@", "pace": "behind", "recentSecondsToLimit": null, "secondsToLimit": 497266, "used": 41},
              "meter": "codex",
              "status": "observed",
              "warm": "not_applicable",
              "windows": {
                "300": {"anchorState": "observed-active", "observedAt": "@t-43s@", "remainingPercent": 74, "resetsAt": @u+2h@, "usedPercent": 26},
                "10080": {"anchorState": "observed-active", "observedAt": "@t-43s@", "remainingPercent": 59, "resetsAt": @u+3d@, "usedPercent": 41}
              }
            }
          },
          "defaultModel": "example-model-large",
          "elapsedMs": 910,
          "id": "work",
          "label": "Work",
          "lastAttemptAt": "@t-43s@",
          "modelProvider": "example",
          "observedAt": "@t-43s@",
          "planType": "pro",
          "status": "ok",
          "streamKey": "codex-stream-work"
        },
        {
          "buckets": {
            "codex": {
              "blockReason": null,
              "forecast": null,
              "meter": "codex",
              "status": "observed",
              "warm": "not_applicable",
              "windows": {
                "300": {"anchorState": "observed-idle", "observedAt": "@t-43s@", "remainingPercent": 100, "resetsAt": @u+5h@, "usedPercent": 0},
                "10080": {"anchorState": "observed-active", "observedAt": "@t-43s@", "remainingPercent": 11, "resetsAt": @u+18h@, "usedPercent": 89}
              }
            }
          },
          "defaultModel": "example-model-large",
          "elapsedMs": 905,
          "id": "personal",
          "label": "Personal",
          "lastAttemptAt": "@t-43s@",
          "modelProvider": "example",
          "observedAt": "@t-43s@",
          "planType": "plus",
          "status": "ok",
          "streamKey": "codex-stream-personal"
        }
      ],
      "status": "ok",
      "warm": "not_applicable"
    }
  },
  "collector": {
    "completedAt": "@t-42s@",
    "incompleteRuns": 0,
    "providers": {
      "claude": {"failures": 0, "lastAttemptAt": "@t-44s@", "lastSuccessAt": "@t-44s@", "nextAttemptAt": "@t+16s@", "status": "ok"},
      "codex": {"failures": 0, "lastAttemptAt": "@t-43s@", "lastSuccessAt": "@t-43s@", "nextAttemptAt": "@t+257s@", "status": "ok"}
    },
    "runningSha": "0000000000000000000000000000000000000000",
    "scheduled": true,
    "schemaVersion": 1,
    "startedAt": "@t-45s@",
    "status": "ok"
  },
  "slots": [
    {
      "actionBlock": null,
      "active": true,
      "cold": false,
      "forecast": {"basis": "cycle-average", "confidence": "estimate", "expectedUsed": 57, "lastsToReset": true, "observedAt": "@t-44s@", "pace": "behind", "recentSecondsToLimit": null, "secondsToLimit": 355680, "used": 54},
      "fresh": true,
      "label": "Everyday",
      "lastGoodAt": "@t-44s@",
      "modelBlock": null,
      "observedAt": "@t-44s@",
      "plan": {"identityKey": "plan-one", "label": "Max 5x", "nextAttemptAt": "@t+6h@", "observedAt": "@t-10m@", "profile": "claude-max-5x", "sessionMultiplier": 5, "source": "native", "status": "detected"},
      "registered": true,
      "reset5h": "@f+83m@",
      "reset7d": "@f+52h@",
      "scoped": [
        null,
        {"aheadOfPace": false, "clock": "Mon 4:00 PM", "countdown": "2d 4h", "expectedPct": 45.0, "name": "example-scoped", "pct": 12.0, "resetsAt": "@z+52h@", "willLastToReset": true}
      ],
      "slot": 1,
      "status": "ok",
      "streamKey": "claude-stream-one",
      "used5h": 38,
      "used7d": 54,
      "warmOutcome": {"expiresAt": "@t+4h@", "id": "warm-one", "meter": "claude", "observedAt": "@t-1h@", "outcome": "confirmed", "provider": "claude", "resetAt": "@t+83m@", "schemaVersion": 1, "sentAt": "@t-1h@", "slot": "1"}
    },
    {
      "actionBlock": null,
      "active": false,
      "cold": false,
      "forecast": null,
      "fresh": true,
      "label": "Reserve",
      "lastGoodAt": "@t-44s@",
      "modelBlock": null,
      "observedAt": "@t-44s@",
      "plan": {"identityKey": "plan-two", "label": null, "nextAttemptAt": "@t+6h@", "observedAt": "@t-10m@", "profile": null, "sessionMultiplier": null, "source": "native", "status": "unknown"},
      "registered": true,
      "reset5h": "",
      "reset7d": "@f+5d@",
      "scoped": [],
      "slot": 2,
      "status": "ok",
      "streamKey": "claude-stream-two",
      "used5h": null,
      "used7d": 17,
      "warmOutcome": {"expiresAt": "@t+4h@", "id": "warm-two", "meter": "claude", "observedAt": "@t-2h@", "outcome": "unconfirmed", "provider": "claude", "resetAt": null, "schemaVersion": 1, "sentAt": "@t-2h@", "slot": "2"}
    }
  ],
  "decision": {
    "accounts": [{"rank": 1, "reason": "eligible", "slot": 1}, {"rank": 2, "reason": "window_unmeasured", "slot": 2}],
    "policy": "prefer",
    "proposed": null,
    "reason": "active account remains eligible",
    "selected": 1
  },
  "critical": {"active": false, "basis": "normal policy", "coverage": "1/1", "floorPercent": 1, "pollSeconds": 300, "reason": "normal policy", "selected": "1", "selectedAt": "@t-3h@"},
  "automationPause": null,
  "recentActions": [
    {"at": "@t-1h@", "id": "action-one", "kind": "warm_outcome", "provider": "claude", "reason": "confirmed", "slot": "1"}
  ],
  "shadow": [
    {"at": "@t-2m@", "reserve": false, "selected": 1, "stream": "claude"},
    {"at": "@t-2m@", "reserve": false, "selected": "work", "stream": "codex"},
    {"at": "@t-2m@", "reserve": false, "selected": null, "stream": "codex_bengalfox"}
  ],
  "providerOverview": {
    "claude": {
      "schemaVersion": 2,
      "capacity": {"laterRefillGainPercent": 6.25, "totalUnits": null},
      "immediate": {"accounts": [{"gross": 0.62, "slot": "1"}], "coverage": {"excluded": [{"reason": "unreadable", "slot": "2"}], "measured": 1}},
      "accounts": 2,
      "knownRemainingPercent": 64.5
    }
  }
}
'@
    [void]$cases.Add(@{name='collector shape';files=@{'policy.json'=$realPolicy;'status.json'=$realStatus;'collector.json'=$collector}})
    [void]$cases.Add(@{name='collector shape with Windows line ends and no byte order mark';noBom=$true;files=@{'policy.json'=$realPolicy.Replace("`r`n","`n").Replace("`n","`r`n");'status.json'=$realStatus.Replace("`r`n","`n").Replace("`n","`r`n")}})

    # Age.
    $old=$status.Replace('@t-42s@','@t-20m@')
    [void]$cases.Add(@{name='readings twenty minutes old';files=@{'policy.json'=$policy;'status.json'=$old;'collector.json'=$collector.Replace('@t-45s@','@t-21m@').Replace('@t-42s@','@t-20m@').Replace('@t-44s@','@t-20m@').Replace('@t-43s@','@t-20m@')}})
    [void]$cases.Add(@{name='readings from the future';files=@{'policy.json'=$policy;'status.json'=$status.Replace('@t-42s@','@t+2m@')}})
    [void]$cases.Add(@{name='readings at the age limit';files=@{'policy.json'=$policy;'status.json'=$status.Replace('@t-42s@','@t-900s@')}})
    [void]$cases.Add(@{name='readings one second past the age limit';files=@{'policy.json'=$policy;'status.json'=$status.Replace('@t-42s@','@t-901s@')}})
    [void]$cases.Add(@{name='one account stale';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @($one,$two.Replace('@t-42s@','@t-20m@')) @($work,$personal.Replace('@t-42s@','@t-20m@')))}})

    # Nothing collected yet.
    [void]$cases.Add(@{name='policy only';files=@{'policy.json'=$policy}})
    [void]$cases.Add(@{name='policy and collector only';files=@{'policy.json'=$policy;'collector.json'=$collector}})
    [void]$cases.Add(@{name='policy and pause only';files=@{'policy.json'=$policy;'automation-pause.json'='{"schemaVersion":1,"until":"@t+2h@","reason":"owner asked"}'}})
    [void]$cases.Add(@{name='status without a generation time';files=@{'policy.json'=$policy;'status.json'=(Edit-Hotpl8ParityText $status '{"generatedAt":"@t-42s@",' '{')}})

    # Collector health.
    $withCollector={param([string]$Text) @{'policy.json'=$policy;'status.json'=$status;'collector.json'=$Text}}
    [void]$cases.Add(@{name='collector running';files=(& $withCollector '{"schemaVersion":1,"startedAt":"@t-30s@","completedAt":null,"status":"running","providers":{}}')})
    [void]$cases.Add(@{name='collector stalled';files=(& $withCollector '{"schemaVersion":1,"startedAt":"@t-10m@","completedAt":"@t-30m@","status":"running","providers":{}}')})
    [void]$cases.Add(@{name='collector overdue';files=(& $withCollector '{"schemaVersion":1,"startedAt":"@t-21m@","completedAt":"@t-20m@","status":"ok","providers":{}}')})
    [void]$cases.Add(@{name='collector started in the future';files=(& $withCollector '{"schemaVersion":1,"startedAt":"@t+1m@","completedAt":"@t+2m@","status":"ok","providers":{}}')})
    [void]$cases.Add(@{name='collector without a start time';files=(& $withCollector '{"schemaVersion":1,"completedAt":"@t-42s@","status":"ok"}')})
    [void]$cases.Add(@{name='collector with one provider failing';files=(& $withCollector '{"schemaVersion":1,"startedAt":"@t-45s@","completedAt":"@t-42s@","status":"incomplete","providers":{"claude":{"status":"ok","lastSuccessAt":"@t-44s@"},"codex":{"status":"failed","failureCode":"timeout","failures":3}}}')})
    [void]$cases.Add(@{name='collector unable to write state';files=(& $withCollector '{"schemaVersion":1,"startedAt":"@t-45s@","completedAt":"@t-42s@","status":"incomplete","providers":{"claude":{"status":"ok","lastSuccessAt":"@t-44s@"},"codex":{"status":"failed","failureCode":"state_io_failed","failures":1}}}')})
    [void]$cases.Add(@{name='collector with stale provider success';files=(& $withCollector '{"schemaVersion":1,"startedAt":"@t-45s@","completedAt":"@t-42s@","status":"ok","providers":{"claude":{"status":"ok","lastSuccessAt":"@t-16m@"},"codex":{"status":"ok","lastSuccessAt":"@t-43s@"}}}')})
    [void]$cases.Add(@{name='stored collector newer than the collector file';files=@{'policy.json'=$policy;'status.json'=(Edit-Hotpl8ParityText $status '"hold":null,' '"hold":null,"collector":{"startedAt":"@t-45s@","completedAt":"@t-42s@","status":"ok"},');'collector.json'='{"schemaVersion":1,"startedAt":"@t-10m@","completedAt":"@t-9m@","status":"incomplete","providers":{}}'}})

    # Pauses.
    $withState={param([hashtable]$More) $files=@{'policy.json'=$policy;'status.json'=$status};foreach($key in $More.Keys){$files[$key]=$More[$key]};$files}
    [void]$cases.Add(@{name='manual pause';files=(& $withState @{'automation-pause.json'='{"schemaVersion":1,"until":"@t+2h@","reason":"owner asked"}'})})
    [void]$cases.Add(@{name='manual pause that ended';files=(& $withState @{'automation-pause.json'='{"schemaVersion":1,"until":"@t-1m@","reason":"owner asked"}'})})
    [void]$cases.Add(@{name='pause file without an end';files=(& $withState @{'automation-pause.json'='{"schemaVersion":1,"reason":"owner asked"}'})})
    [void]$cases.Add(@{name='pause reason with control characters';files=(& $withState @{'automation-pause.json'='{"schemaVersion":1,"until":"@t+2h@","reason":"line one\nline two\ttabbed\u007f"}'});expect=@{default='answer';explain='either';'explain-json'='answer'}})
    $lease='{"leaseId":"11111111-2222-4333-8444-555555555555","owner":"agent one","minutes":90,"acquiredAt":"@z-30m@","until":"@z+60m@","releasedAt":null,"retainUntil":"@z+25h@"}'
    $leaseTwo='{"leaseId":"22222222-2222-4333-8444-555555555555","owner":"agent two","minutes":240,"acquiredAt":"@t-60m@","until":"@t+180m@","releasedAt":null,"retainUntil":"@t+28h@"}'
    $released='{"leaseId":"33333333-2222-4333-8444-555555555555","owner":"agent three","minutes":60,"acquiredAt":"@z-30m@","until":"@z+30m@","releasedAt":"@z-10m@","retainUntil":"@z+24h@"}'
    $tombstone='{"leaseId":"44444444-2222-4333-8444-555555555555","owner":null,"minutes":null,"acquiredAt":null,"until":null,"releasedAt":"@z-2h@","retainUntil":"@z+22h@"}'
    [void]$cases.Add(@{name='one agent lease';files=(& $withState @{'automation-leases.json'=('{"schemaVersion":1,"entries":['+$lease+']}')})})
    [void]$cases.Add(@{name='several agent leases';files=(& $withState @{'automation-leases.json'=('{"schemaVersion":1,"entries":['+$lease+','+$leaseTwo+','+$released+','+$tombstone+']}')})})
    [void]$cases.Add(@{name='only released leases';files=(& $withState @{'automation-leases.json'=('{"schemaVersion":1,"entries":['+$released+','+$tombstone+']}')})})
    [void]$cases.Add(@{name='empty lease ledger';files=(& $withState @{'automation-leases.json'='{"schemaVersion":1,"entries":[]}'})})
    [void]$cases.Add(@{name='lease with the wrong end';files=(& $withState @{'automation-leases.json'=('{"schemaVersion":1,"entries":['+$lease.Replace('@z+60m@','@z+61m@')+']}')})})
    [void]$cases.Add(@{name='lease ledger with an extra field';files=(& $withState @{'automation-leases.json'=('{"schemaVersion":1,"entries":[],"note":"x"}')})})
    [void]$cases.Add(@{name='lease ledger that is not an object';files=(& $withState @{'automation-leases.json'='[]'});expect='either'})
    [void]$cases.Add(@{name='lease and manual pause, pause later';files=(& $withState @{'automation-leases.json'=('{"schemaVersion":1,"entries":['+$lease+']}');'automation-pause.json'='{"schemaVersion":1,"until":"@t+2h@","reason":"owner asked"}'})})
    [void]$cases.Add(@{name='lease and manual pause, lease later';files=(& $withState @{'automation-leases.json'=('{"schemaVersion":1,"entries":['+$leaseTwo+']}');'automation-pause.json'='{"schemaVersion":1,"until":"@t+2h@","reason":"owner asked"}'})})
    [void]$cases.Add(@{name='lease and a pause file without an end';files=(& $withState @{'automation-leases.json'=('{"schemaVersion":1,"entries":['+$lease+']}');'automation-pause.json'='{"schemaVersion":1}'})})

    # Policy forms.
    $automate=Edit-Hotpl8ParityText $policy '"mode":"monitor"' '"mode":"automate","switchEnabled":true,"warm":true,"probeEnabled":true'
    [void]$cases.Add(@{name='automatic selection';files=@{'policy.json'=$automate;'status.json'=$status}})
    [void]$cases.Add(@{name='automatic mode with selection off';files=@{'policy.json'=(Edit-Hotpl8ParityText $policy '"mode":"monitor"' '"mode":"automate","switchEnabled":false');'status.json'=$status}})
    [void]$cases.Add(@{name='automatic selection while paused';files=@{'policy.json'=$automate;'status.json'=$status;'automation-pause.json'='{"schemaVersion":1,"until":"@t+2h@","reason":"owner asked"}'}})
    [void]$cases.Add(@{name='policy without a version';files=@{'policy.json'='{"mode":"automate","prefer":[1,2],"reserve":[2],"labels":{"1":"Everyday","2":"Reserve"},"codex":{"slots":[{"id":"work","label":"Work"},{"id":"personal","label":"Personal"}]}}';'status.json'=$status}})
    [void]$cases.Add(@{name='policy version one';files=@{'policy.json'='{"schemaVersion":1,"mode":"automate","prefer":[2,1],"margin5h":30,"margin7d":10,"hysteresis":5,"codex":{"slots":[{"id":"work"},{"id":"personal"}],"margin7d":50}}';'status.json'=$status}})
    [void]$cases.Add(@{name='Claude only';files=@{'policy.json'='{"schemaVersion":2,"mode":"monitor","prefer":[1,2]}';'status.json'=$status}})
    [void]$cases.Add(@{name='Codex only';files=@{'policy.json'='{"schemaVersion":2,"mode":"monitor","codex":{"slots":[{"id":"work","label":"Work"},{"id":"personal","label":"Personal"}]}}';'status.json'=$status}})
    [void]$cases.Add(@{name='no providers configured';files=@{'policy.json'='{"schemaVersion":2,"mode":"monitor"}';'status.json'=$status}})
    [void]$cases.Add(@{name='one Codex account without capacity';files=@{'policy.json'='{"schemaVersion":2,"mode":"monitor","codex":{"slots":[{"id":"personal","label":"Personal"}]}}';'status.json'=$status}})
    [void]$cases.Add(@{name='Codex configured but never observed';files=@{'policy.json'=$policy;'status.json'=('{"generatedAt":"@t-42s@","active":1,"hold":null,"slots":['+$one+','+$two+']}')}})
    [void]$cases.Add(@{name='capacity profiles';files=@{'policy.json'=(Edit-Hotpl8ParityText (Edit-Hotpl8ParityText $policy '"capacity":{"1":{"weekly":1,"fiveHour":0.3},"2":{"weekly":5,"fiveHour":1.5}}' '"capacity":{"1":{"profile":"claude-pro"},"2":{"profile":"claude-max-5x"}}') '"capacity":{"work":{"weekly":5,"fiveHour":1.5},"personal":{"weekly":1,"fiveHour":0.3}}' '"capacity":{"work":{"profile":"codex-pro-5x"},"personal":{"profile":"codex-plus"}}');'status.json'=$status}})
    [void]$cases.Add(@{name='capacity profile of the other provider';files=@{'policy.json'=(Edit-Hotpl8ParityText $policy '"capacity":{"1":{"weekly":1,"fiveHour":0.3},"2":{"weekly":5,"fiveHour":1.5}}' '"capacity":{"1":{"profile":"codex-plus"},"2":{"weekly":5}}');'status.json'=$status}})
    [void]$cases.Add(@{name='no capacity settings';files=@{'policy.json'='{"schemaVersion":2,"mode":"monitor","prefer":[1,2],"reserve":[2],"codex":{"slots":[{"id":"work","label":"Work"},{"id":"personal","label":"Personal"}]}}';'status.json'=$status}})
    [void]$cases.Add(@{name='disabled accounts';files=@{'policy.json'=(Edit-Hotpl8ParityText (Edit-Hotpl8ParityText $policy '"reserve":[2],' '"reserve":[2],"disabled":[2],') '"defaultMeter":"codex",' '"defaultMeter":"codex","disabled":["personal"],');'status.json'=$status}})
    [void]$cases.Add(@{name='every account disabled';files=@{'policy.json'=(Edit-Hotpl8ParityText (Edit-Hotpl8ParityText $policy '"reserve":[2],' '"reserve":[2],"disabled":[1,2],') '"defaultMeter":"codex",' '"defaultMeter":"codex","disabled":["personal","work"],');'status.json'=$status}})
    [void]$cases.Add(@{name='account enrolled but not observed';files=@{'policy.json'=(Edit-Hotpl8ParityText (Edit-Hotpl8ParityText $policy '"prefer":[1,2]' '"prefer":[1,2,3]') '{"id":"personal","label":"Personal"}]' '{"id":"personal","label":"Personal"},{"id":"spare","label":"Spare"}]');'status.json'=$status}})
    [void]$cases.Add(@{name='display settings and history flags';files=@{'policy.json'=(Edit-Hotpl8ParityText $policy '"mode":"monitor",' '"mode":"monitor","historyEnabled":false,"notificationsEnabled":true,"display":{"reducedMotion":true,"noColor":false},"automation":{"dailyAttemptLimit":4,"warmExcluded":["claude:2","codex:work"],"schedule":{"start":"08:30","end":"18:00","days":[1,2,3,4,5]}},');'status.json'=$status}})

    $three=@'
{"schemaVersion":3,"mode":"automate","switchEnabled":true,"warm":false,"probeEnabled":true,
 "providers":{
  "claude":{"prefer":[1,2],"reserve":[2],"labels":{"1":"Everyday","2":"Reserve"},"capacity":{"1":{"weekly":1,"fiveHour":0.3},"2":{"weekly":5,"fiveHour":1.5}}},
  "codex":{"slots":[{"id":"work","label":"Work","home":"C:\\Fictional\\codex-work"},{"id":"personal","label":"Personal","home":"C:\\Fictional\\codex-personal"}],"prefer":["work","personal"],"capacity":{"work":{"weekly":5,"fiveHour":1.5},"personal":{"weekly":1,"fiveHour":0.3}},"margin7dWork":5}
 }}
'@
    $threeMac=$three.Replace('C:\\Fictional\\','/opt/fictional/')
    [void]$cases.Add(@{name='policy version three';files=@{'policy.json'=$three;'status.json'=$status};macFiles=@{'policy.json'=$threeMac}})
    [void]$cases.Add(@{name='policy version three with one provider';files=@{'policy.json'='{"schemaVersion":3,"mode":"monitor","providers":{"claude":{"prefer":[1,2],"claudeModels":["example-scoped"]}}}';'status.json'=$status}})
    [void]$cases.Add(@{name='policy version three with no providers';files=@{'policy.json'='{"schemaVersion":3,"mode":"monitor","providers":{}}';'status.json'=$status}})

    # Reader policy.
    [void]$cases.Add(@{name='preview policy';files=@{'policy.json'=$policy;'status.json'=$status};preview=$automate})
    [void]$cases.Add(@{name='preview policy without a stored policy';files=@{'status.json'=$status};preview=$policy})
    [void]$cases.Add(@{name='preview policy that is invalid';files=@{'policy.json'=$policy;'status.json'=$status};preview='{"schemaVersion":2,"mode":"sometimes"}'})

    # Selection.
    $hold=Edit-Hotpl8ParityText $status '"hold":null,' '"hold":{"slot":1,"until":"@t+3h@","reason":"owner pinned"},'
    [void]$cases.Add(@{name='rotation held';files=@{'policy.json'=$automate;'status.json'=$hold}})
    [void]$cases.Add(@{name='rotation hold that ended';files=@{'policy.json'=$automate;'status.json'=$hold.Replace('@t+3h@','@t-3h@')}})
    [void]$cases.Add(@{name='Codex selection held';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @($one,$two) @($work,$personal) '' ',"hold":{"slot":"personal","until":"@t+3h@"}')}})
    [void]$cases.Add(@{name='active account below its margin';files=@{'policy.json'=$automate;'status.json'=(Join-Hotpl8ParityStatus @($one.Replace('"used5h":38','"used5h":91'),$two) @($work,$personal))}})
    [void]$cases.Add(@{name='every account below its margin';files=@{'policy.json'=$automate;'status.json'=(Join-Hotpl8ParityStatus @($one.Replace('"used5h":38','"used5h":91'),$two.Replace('"used7d":17','"used7d":97')) @($work.Replace('"usedPercent":26,"remainingPercent":74','"usedPercent":90,"remainingPercent":10'),$personal.Replace('"usedPercent":89,"remainingPercent":11','"usedPercent":99,"remainingPercent":1')))}})
    [void]$cases.Add(@{name='no active account';files=@{'policy.json'=$automate;'status.json'=$status.Replace('"active":1,','"active":0,')}})
    [void]$cases.Add(@{name='active account not enrolled';files=@{'policy.json'=$automate;'status.json'=$status.Replace('"active":1,','"active":7,')}})
    foreach($order in @('soonest-reset','weekly-expiry','balanced')){
        $ordered=Edit-Hotpl8ParityText (Edit-Hotpl8ParityText $automate '"reserve":[2],' ('"order":"'+$order+'",')) '"defaultMeter":"codex",' ('"defaultMeter":"codex","order":"'+$order+'",')
        [void]$cases.Add(@{name=('order '+$order);files=@{'policy.json'=$ordered;'status.json'=$status}})
        [void]$cases.Add(@{name=('order '+$order+' with the second account active');files=@{'policy.json'=$ordered;'status.json'=$status.Replace('"active":1,','"active":2,').Replace('"recommendedSlot":"work"','"recommendedSlot":"personal"')}})
    }
    [void]$cases.Add(@{name='weekly allowance nearly spent';files=@{'policy.json'=$automate;'status.json'=(Join-Hotpl8ParityStatus @($one.Replace('"used7d":54','"used7d":88'),$two.Replace('"used7d":17','"used7d":86')) @($work,$personal))}})

    # Critical allowance.
    $critical=Edit-Hotpl8ParityText (Edit-Hotpl8ParityText $automate '"reserve":[2],' '"critical":{"enabled":true},') '"defaultMeter":"codex",' '"defaultMeter":"codex","critical":{"enabled":true,"enterPercent":30,"exitPercent":40,"floorPercent":2,"dwellSeconds":120,"advantagePercent":15,"pollSeconds":90},'
    $low=Join-Hotpl8ParityStatus @($one.Replace('"used5h":38','"used5h":85'),$two.Replace('"used7d":17','"used7d":92')) @($work.Replace('"usedPercent":26,"remainingPercent":74','"usedPercent":78,"remainingPercent":22'),$personal)
    [void]$cases.Add(@{name='critical allowance';files=@{'policy.json'=$critical;'status.json'=$low}})
    [void]$cases.Add(@{name='critical allowance with stored state';files=@{'policy.json'=$critical;'status.json'=(Join-Hotpl8ParityStatus @($one.Replace('"used5h":38','"used5h":85'),$two.Replace('"used7d":17','"used7d":92')) @($work.Replace('"usedPercent":26,"remainingPercent":74','"usedPercent":78,"remainingPercent":22'),$personal) ',"critical":{"active":true,"selected":"2","selectedAt":"@t-30s@","reason":"largest remaining allowance","basis":"usable capacity","pollSeconds":60}' ',"critical":{"codex":{"active":true,"selected":"personal","selectedAt":"@t-10m@","reason":"largest remaining allowance","basis":"usable capacity","pollSeconds":90}}')}})
    [void]$cases.Add(@{name='critical allowance drained to zero';files=@{'policy.json'=$critical.Replace('"critical":{"enabled":true},','"critical":{"enabled":true,"drainToZero":true},');'status.json'=$low}})
    [void]$cases.Add(@{name='critical setting off while low';files=@{'policy.json'=$critical.Replace('"critical":{"enabled":true},','"critical":{"enabled":false},');'status.json'=$low}})

    # Scoped model limits.
    $models=Edit-Hotpl8ParityText $automate '"reserve":[2],' '"reserve":[2],"claudeModels":["example-scoped","example-other"],'
    $scopedOne=Edit-Hotpl8ParityText $one '"reset7d":"@t+52h@"}' '"reset7d":"@t+52h@","scoped":[{"name":"example-scoped","pct":40,"resetsAt":"@z+52h@"},{"name":"example-other","pct":12.5,"resetsAt":"@z+30h@"}]}'
    $scopedTwo=Edit-Hotpl8ParityText $two '"reset7d":"@t+5d@"}' '"reset7d":"@t+5d@","scoped":[{"name":"example-scoped","pct":99,"resetsAt":"@z+5d@"},null,{"name":"example-other","pct":0,"resetsAt":null}]}'
    [void]$cases.Add(@{name='scoped model limits';files=@{'policy.json'=$models;'status.json'=(Join-Hotpl8ParityStatus @($scopedOne,$scopedTwo) @($work,$personal))}})
    [void]$cases.Add(@{name='scoped model limits not observed';files=@{'policy.json'=$models;'status.json'=$status}})
    [void]$cases.Add(@{name='scoped model limits with capacity';files=@{'policy.json'=(Edit-Hotpl8ParityText $models '"capacity":{"1":{"weekly":1,"fiveHour":0.3},' '"capacity":{"1":{"weekly":1,"fiveHour":0.3,"scoped":{"example-scoped":0.5,"example-other":0.25}},');'status.json'=(Join-Hotpl8ParityStatus @($scopedOne,$scopedTwo) @($work,$personal))}})

    # Account states.
    [void]$cases.Add(@{name='account needs sign-in';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @($one,'{"slot":2,"label":"Reserve","status":"relogin_required","observedAt":"@t-42s@","active":false,"fresh":false,"lastGoodAt":"@t-10d@"}') @($work,'{"id":"personal","label":"Personal","status":"authentication_required","observedAt":"@t-9d@"}'))}})
    [void]$cases.Add(@{name='account signed out recently';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @($one,'{"slot":2,"label":"Reserve","status":"no_credentials","observedAt":"@t-42s@","active":false,"fresh":false,"lastGoodAt":"@t-2d@"}') @($work,'{"id":"personal","label":"Personal","status":"subscription_login_required","observedAt":"@t-3d@"}'))}})
    [void]$cases.Add(@{name='Codex plan ended';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @($one,$two) @($work,(Edit-Hotpl8ParityText $personal '"status":"ok",' '"status":"ok","planType":"free",')))}})
    [void]$cases.Add(@{name='same subscription enrolled twice';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @((Edit-Hotpl8ParityText $one '"status":"ok",' '"status":"ok","streamKey":"same",'),(Edit-Hotpl8ParityText $two '"status":"ok",' '"status":"duplicate_subscription","streamKey":"same",')) @((Edit-Hotpl8ParityText $work '"status":"ok",' '"status":"ok","streamKey":"same",'),(Edit-Hotpl8ParityText $personal '"status":"ok",' '"status":"ok","streamKey":"same",')))}})
    [void]$cases.Add(@{name='same slot observed twice';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @($one,$one,$two) @($work,$work,$personal))}})
    [void]$cases.Add(@{name='Codex account blocked until its reset';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @($one,$two) @($work,'{"id":"personal","label":"Personal","status":"ok","observedAt":"@t-42s@","buckets":{"codex":{"status":"blocked","blockReason":"quota_exhausted","windows":{"10080":{"usedPercent":100,"remainingPercent":0,"resetsAt":@u+18h@,"anchorState":"observed-active"}}}}}'))}})
    [void]$cases.Add(@{name='Codex account blocked without a reason';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @($one,$two) @($work,'{"id":"personal","label":"Personal","status":"ok","observedAt":"@t-42s@","buckets":{"codex":{"status":"blocked","windows":{"10080":{"usedPercent":100,"remainingPercent":0,"resetsAt":@u+18h@,"anchorState":"inferred"}}}}}'))}})
    [void]$cases.Add(@{name='Codex meter missing';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @($one,$two) @($work,'{"id":"personal","label":"Personal","status":"ok","observedAt":"@t-42s@","buckets":{}}'))}})
    [void]$cases.Add(@{name='Codex windows that do not add up';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @($one,$two) @($work.Replace('"usedPercent":26,"remainingPercent":74','"usedPercent":26,"remainingPercent":70'),$personal))}})
    [void]$cases.Add(@{name='Codex window with an unknown name';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @($one,$two) @($work,(Edit-Hotpl8ParityText $personal '"windows":{' '"windows":{"1440":{"usedPercent":5,"remainingPercent":95,"resetsAt":@u+6h@,"anchorState":"observed-active"},')))}})
    [void]$cases.Add(@{name='windows that already reset';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @($one.Replace('@t+83m@','@t-10s@'),$two.Replace('@t+5d@','@t-20s@')) @($work.Replace('@u+2h@','@u-5s@'),$personal.Replace('@u+18h@','@u-30s@')))}})
    [void]$cases.Add(@{name='windows that reset before the reading';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @($one.Replace('@t+83m@','@t-60s@'),$two.Replace('@t+5d@','@t-90s@')) @($work.Replace('@u+2h@','@u-70s@'),$personal.Replace('@u+18h@','@u-80s@')))}})
    [void]$cases.Add(@{name='readings without usage';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @($one.Replace('"used5h":38,"used7d":54','"used5h":null,"used7d":null'),'{"slot":2,"label":"Reserve","status":"ok","observedAt":"@t-42s@","active":false,"fresh":true}') @('{"id":"work","label":"Work","status":"ok","observedAt":"@t-42s@","buckets":{"codex":{"status":"observed","windows":{}}}}',$personal))}})
    [void]$cases.Add(@{name='readings without reset times';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @($one.Replace('"reset5h":"@t+83m@","reset7d":"@t+52h@"','"reset5h":null,"reset7d":null'),$two.Replace(',"reset5h":"@t+4h@","reset7d":"@t+5d@"','')) @($work.Replace('"resetsAt":@u+2h@,',''),$personal.Replace('@u+18h@','null')))}})
    [void]$cases.Add(@{name='account marked not fresh';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @($one.Replace('"fresh":true','"fresh":false'),$two) @($work,$personal))}})
    [void]$cases.Add(@{name='fully used';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @($one.Replace('"used5h":38,"used7d":54','"used5h":100,"used7d":100'),$two.Replace('"used5h":8,"used7d":17','"used5h":0,"used7d":0')) @($work.Replace('"usedPercent":26,"remainingPercent":74','"usedPercent":100,"remainingPercent":0'),$personal))}})

    # Numbers. PowerShell 5.1 reads a fraction as a decimal and PowerShell 7 as a double.
    $fractions=Join-Hotpl8ParityStatus @($one.Replace('"used5h":38,"used7d":54','"used5h":38.5,"used7d":54.25'),$two.Replace('"used5h":8,"used7d":17','"used5h":8.0,"used7d":17.125')) @($work.Replace('"usedPercent":26,"remainingPercent":74','"usedPercent":26.4,"remainingPercent":73.6').Replace('"usedPercent":41,"remainingPercent":59','"usedPercent":41.05,"remainingPercent":58.95'),$personal.Replace('"usedPercent":89,"remainingPercent":11','"usedPercent":88.9,"remainingPercent":11.1'))
    [void]$cases.Add(@{name='fractional readings';files=@{'policy.json'=$policy;'status.json'=$fractions}})
    [void]$cases.Add(@{name='fractional readings and automatic selection';files=@{'policy.json'=$critical;'status.json'=$fractions}})
    $fine=Edit-Hotpl8ParityText (Edit-Hotpl8ParityText $policy '"capacity":{"1":{"weekly":1,"fiveHour":0.3},"2":{"weekly":5,"fiveHour":1.5}}' '"capacity":{"1":{"weekly":1.25,"fiveHour":0.333},"2":{"weekly":3.0,"fiveHour":0.7}},"margin5h":12.5,"margin7d":7.75') '"margin5h":25,"margin7d":20,"margin7dWork":5}}' '"margin5h":22.5,"margin7d":17.25,"margin7dWork":2.5,"hysteresis":3.5}}'
    [void]$cases.Add(@{name='fractional settings';files=@{'policy.json'=$fine;'status.json'=$status}})
    [void]$cases.Add(@{name='fractional settings and readings';files=@{'policy.json'=(Edit-Hotpl8ParityText $fine '"mode":"monitor"' '"mode":"automate","switchEnabled":true');'status.json'=$fractions}})
    [void]$cases.Add(@{name='thirds';files=@{'policy.json'=(Edit-Hotpl8ParityText $policy '"capacity":{"1":{"weekly":1,"fiveHour":0.3},"2":{"weekly":5,"fiveHour":1.5}}' '"capacity":{"1":{"weekly":3,"fiveHour":1},"2":{"weekly":3,"fiveHour":1}}');'status.json'=(Join-Hotpl8ParityStatus @($one.Replace('"used5h":38,"used7d":54','"used5h":33,"used7d":67'),$two.Replace('"used5h":8,"used7d":17','"used5h":66,"used7d":34')) @($work,$personal))}})
    [void]$cases.Add(@{name='forecast hours';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @((Edit-Hotpl8ParityText $one '"reset7d":"@t+52h@"}' '"reset7d":"@t+52h@","forecast":{"pace":"ahead","secondsToLimit":7200,"lastsToReset":false}}'),(Edit-Hotpl8ParityText $two '"reset7d":"@t+5d@"}' '"reset7d":"@t+5d@","forecast":{"pace":"on pace","secondsToLimit":123456.5,"lastsToReset":true}}')) @($work,$personal))}})
    [void]$cases.Add(@{name='forecast without a time to limit';files=@{'policy.json'=$policy;'status.json'=(Join-Hotpl8ParityStatus @((Edit-Hotpl8ParityText $one '"reset7d":"@t+52h@"}' '"reset7d":"@t+52h@","forecast":{"pace":"behind","secondsToLimit":null,"lastsToReset":true}}'),$two) @($work,$personal))}})
    [void]$cases.Add(@{name='large whole numbers';files=@{'policy.json'=$policy;'status.json'=(Edit-Hotpl8ParityText $status '"hold":null,' '"hold":null,"sequence":4294967296,"small":-2147483648,"edge":2147483648,')}})

    [void]$cases.Add(@{name='Codex margin beyond one hundred';files=@{'policy.json'=$policy.Replace('"margin5h":25','"margin5h":250');'status.json'=$status}})

    # Explain.
    $decided=Edit-Hotpl8ParityText $status '"hold":null,' '"hold":null,"decision":{"reason":"active account remains eligible","policy":"prefer","accounts":[{"slot":1,"reason":"eligible","rank":1},{"slot":2,"reason":"reserve","rank":2}]},"critical":{"active":true,"reason":"largest remaining allowance","basis":"usable capacity","pollSeconds":60},'
    $decided=Edit-Hotpl8ParityText $decided '"recommendedSlot":"work",' '"recommendedSlot":"work","critical":{"codex":{"active":true,"reason":"retained to avoid churn","basis":"binding-window percentage; capacity unknown","pollSeconds":90},"codex_bengalfox":{"active":false}},"decisions":[{"meter":"codex","selected":"work","policy":"prefer","accounts":[{"slot":"work","reason":"eligible","reserve":false},{"slot":"personal","reason":"below_margin","reserve":true}]},{"meter":"codex_bengalfox","selected":null,"policy":"prefer","accounts":[]}],'
    [void]$cases.Add(@{name='stored decisions';files=@{'policy.json'=$policy;'status.json'=$decided}})
    [void]$cases.Add(@{name='stored decisions for another provider';files=@{'policy.json'=$policy;'status.json'=(Edit-Hotpl8ParityText $status '"providers":{' '"providers":{"example":{"decision":{"reason":"only account","policy":"prefer","accounts":[{"slot":"a","reason":"eligible","rank":1}]},"decisions":[{"meter":"m","selected":null,"policy":"prefer","accounts":[{"slot":"a","reason":"eligible","reserve":false}]}]},')}})

    # Errors PowerShell reports. The reader must leave each to PowerShell.
    [void]$cases.Add(@{name='no policy';files=@{'status.json'=$status}})
    [void]$cases.Add(@{name='policy with an unknown field';files=@{'policy.json'=(Edit-Hotpl8ParityText $policy '"mode":"monitor",' '"mode":"monitor","colour":"blue",');'status.json'=$status}})
    [void]$cases.Add(@{name='policy with an unknown mode';files=@{'policy.json'=$policy.Replace('"mode":"monitor"','"mode":"sometimes"');'status.json'=$status}})
    [void]$cases.Add(@{name='policy with a margin out of range';files=@{'policy.json'=(Edit-Hotpl8ParityText $policy '"mode":"monitor",' '"mode":"monitor","margin5h":250,');'status.json'=$status}})
    [void]$cases.Add(@{name='policy with a repeated account';files=@{'policy.json'=$policy.Replace('"prefer":[1,2]','"prefer":[1,1]');'status.json'=$status}})
    [void]$cases.Add(@{name='policy with a reserve that is not enrolled';files=@{'policy.json'=$policy.Replace('"reserve":[2]','"reserve":[3]');'status.json'=$status}})
    [void]$cases.Add(@{name='policy version four';files=@{'policy.json'=$policy.Replace('"schemaVersion":2','"schemaVersion":4');'status.json'=$status}})
    [void]$cases.Add(@{name='policy version one with newer settings';files=@{'policy.json'=$policy.Replace('"schemaVersion":2','"schemaVersion":1');'status.json'=$status}})
    [void]$cases.Add(@{name='policy with an unknown capacity profile';files=@{'policy.json'=$policy.Replace('"1":{"weekly":1,"fiveHour":0.3}','"1":{"profile":"claude-mega"}');'status.json'=$status}})
    [void]$cases.Add(@{name='policy with critical exit below entry';files=@{'policy.json'=(Edit-Hotpl8ParityText $policy '"reserve":[2],' '"reserve":[2],"critical":{"enabled":true,"enterPercent":30,"exitPercent":20},');'status.json'=$status}})
    [void]$cases.Add(@{name='policy version three with a version two field';files=@{'policy.json'='{"schemaVersion":3,"mode":"monitor","prefer":[1],"providers":{}}';'status.json'=$status}})
    [void]$cases.Add(@{name='policy version three with an unknown provider';files=@{'policy.json'='{"schemaVersion":3,"mode":"monitor","providers":{"example":{}}}';'status.json'=$status}})
    [void]$cases.Add(@{name='policy version three with one home enrolled twice';files=@{'policy.json'=$three.Replace('codex-personal','codex-work');'status.json'=$status};macFiles=@{'policy.json'=$threeMac.Replace('codex-personal','codex-work')}})
    [void]$cases.Add(@{name='policy that is an array';files=@{'policy.json'='[]';'status.json'=$status}})
    [void]$cases.Add(@{name='policy that is not JSON';files=@{'policy.json'='{"schemaVersion":2,';'status.json'=$status}})
    [void]$cases.Add(@{name='empty policy file';files=@{'policy.json'='';'status.json'=$status}})
    [void]$cases.Add(@{name='generation time that is not a time';files=@{'policy.json'=$policy;'status.json'=$status.Replace('{"generatedAt":"@t-42s@"','{"generatedAt":"soon"')};expect=@{default='either'}})
    [void]$cases.Add(@{name='text where a percentage belongs';files=@{'policy.json'=$policy;'status.json'=$status.Replace('"used5h":38','"used5h":"38"')}})
    [void]$cases.Add(@{name='usage that is an object';files=@{'policy.json'=$policy;'status.json'=$status.Replace('"used7d":54','"used7d":{"value":54}')}})

    # Input PowerShell answers from but the reader does not model. It must decline.
    $decline={param([string]$Name,[string]$Text,[string]$PolicyText=$policy) [void]$cases.Add(@{name=$Name;files=@{'policy.json'=$PolicyText;'status.json'=$Text};expect='decline'})}
    & $decline 'time in a regional form' $status.Replace('{"generatedAt":"@t-42s@"','{"generatedAt":"9/12/2026 11:59:18 AM +00:00"')
    & $decline 'time without an offset' ($status.Replace('"observedAt":"@t-42s@","active":true','"observedAt":"2026-09-12T11:59:18","active":true'))
    & $decline 'time without seconds' ($status.Replace('"observedAt":"@t-42s@","active":true','"observedAt":"2026-09-12T11:59Z","active":true'))
    & $decline 'number with an exponent' ($status.Replace('"used5h":38','"used5h":3.8e1'))
    & $decline 'negative zero' ($status.Replace('"used5h":38','"used5h":-0.0'))
    & $decline 'number beyond 64 bits' ($status.Replace('"used5h":38','"used5h":18446744073709551616'))
    & $decline 'number with more digits than a decimal holds' ($status.Replace('"used5h":38','"used5h":38.00000000000000000000000000001'))
    & $decline 'repeated property name' ($status.Replace('"active":1,','"active":1,"Active":2,'))
    & $decline 'property name outside ASCII' ($status.Replace('"active":1,',('"active":1,"caf'+[char]0xe9+'":2,')))
    & $decline 'empty property name' ($status.Replace('"active":1,','"active":1,"":2,'))
    & $decline 'old Microsoft date text' ($status.Replace('"label":"Everyday"','"label":"\/Date(1791000000000)\/"'))
    & $decline 'comment in a state file' ($status.Replace('{"generatedAt"','{/* note */"generatedAt"'))
    & $decline 'trailing comma' ($status.Replace('"hold":null,"slots"','"hold":null,"slots"').Replace(']}}}',']}},}'))
    & $decline 'single quoted text' ($status.Replace('"label":"Everyday"',"`"label`":'Everyday'"))
    & $decline 'array where the provider object belongs' ($status.Replace('"providers":{"codex":{','"providers":{"codex":[{').Replace(']}}}',']}]}}'))
    return $cases.ToArray()
}
