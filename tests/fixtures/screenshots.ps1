# Fictional, fixed-time documentation data. Never read account homes or cached state here.
function Get-Hotpl8ScreenshotFixture([switch]$Operations,[switch]$TwoAccounts,[switch]$FixedClock) {
    $now = [datetimeoffset]::Parse('2026-09-12T12:00:00Z')
    # A plan read long ago is not shown, and a preview launcher already installed moves this
    # fixture's other times forward but not this one. So a plan is read by the real clock,
    # unless the frame is drawn at the fixture's own: then ask for -FixedClock.
    $planRead = $(if($FixedClock){$now}else{[datetimeoffset]::UtcNow}).AddMinutes(-10).ToString('o')
    $policy = @{
        schemaVersion = 2; mode = 'monitor'; prefer = @(1, 2, 3); reserve = @(2)
        capacity=@{'1'=@{weekly=1;fiveHour=0.3};'2'=@{weekly=5;fiveHour=1.5};'3'=@{weekly=10;fiveHour=$null}}
        labels = @{ '1' = 'Everyday'; '2' = 'Reserve'; '3' = 'Studio' }
        codex = @{
            slots = @(@{ id = 'work'; label = 'Work' }, @{ id = 'personal'; label = 'Personal' })
            capacity=@{work=@{weekly=5;fiveHour=1.5};personal=@{weekly=1;fiveHour=0.3}}
            defaultMeter = 'codex'; margin5h = 25; margin7d = 20; margin7dWork = 5
        }
    }
    $status = @{
        generatedAt = $now.AddSeconds(-42).ToString('o'); active = 1; hold = $null
        slots = @(
            @{ slot = 1; label = 'Everyday'; status = 'ok'; observedAt = $now.AddSeconds(-42).ToString('o'); active = $true; fresh = $true
               used5h = 38; used7d = 54; reset5h = $now.AddMinutes(83).ToString('o'); reset7d = $now.AddDays(2).AddHours(4).ToString('o')
               plan = @{ status = 'detected'; profile = 'claude-pro'; label = 'Pro'; observedAt = $planRead } },
            @{ slot = 2; label = 'Reserve'; status = 'ok'; observedAt = $now.AddSeconds(-42).ToString('o'); active = $false; fresh = $true
               used5h = 8; used7d = 17; reset5h = $now.AddHours(4).ToString('o'); reset7d = $now.AddDays(5).ToString('o')
               plan = @{ status = 'detected'; profile = 'claude-max-5x'; label = 'Max'; observedAt = $planRead } },
            # A verified Ultra account, which has no five-hour limit. Its reset5h is not shown:
            # a preview launcher already installed parses that time on every account it is given.
            @{ slot = 3; label = 'Studio'; status = 'ok'; observedAt = $now.AddSeconds(-42).ToString('o'); active = $false; fresh = $true
               used5h = $null; limit5h = 'none'; used7d = 31; reset5h = $now.AddHours(5).ToString('o'); reset7d = $now.AddDays(4).ToString('o')
               plan = @{ status = 'detected'; profile = 'claude-max-20x'; label = 'Ultra'; observedAt = $planRead } }
        )
        providers = @{
            codex = @{
                capacity=@{work=@{weekly=5;fiveHour=1.5};personal=@{weekly=1;fiveHour=0.3}}
            defaultMeter = 'codex'; recommendedSlot = 'work'
                slots = @(
                    @{ id = 'work'; label = 'Work'; status = 'ok'; observedAt = $now.AddSeconds(-42).ToString('o')
                       buckets = @{ codex = @{ status = 'observed'; windows = @{
                           '300' = @{ usedPercent = 26; remainingPercent = 74; resetsAt = $now.AddHours(2).ToUnixTimeSeconds(); anchorState = 'observed-active' }
                           '10080' = @{ usedPercent = 41; remainingPercent = 59; resetsAt = $now.AddDays(3).ToUnixTimeSeconds(); anchorState = 'observed-active' }
                       } } } },
                    @{ id = 'personal'; label = 'Personal'; status = 'ok'; observedAt = $now.AddSeconds(-42).ToString('o')
                       buckets = @{ codex = @{ status = 'observed'; windows = @{
                           '10080' = @{ usedPercent = 89; remainingPercent = 11; resetsAt = $now.AddHours(18).ToUnixTimeSeconds(); anchorState = 'observed-active' }
                       } } } }
                )
            }
        }
    }
    if($TwoAccounts){
        $status.slots=@($status.slots[0],$status.slots[1]);$policy.prefer=@(1,2)
        foreach($slot in $status.slots){$slot.Remove('plan')}
        $policy.capacity.Remove('3');$policy.labels.Remove('3')
    }
    if($Operations){
        $status.collector=@{startedAt=$now.AddSeconds(-45).ToString('o');completedAt=$now.AddSeconds(-42).ToString('o');status='ok'}
        $status.slots[0].observedAt=$now.AddSeconds(-42).ToString('o')
        # The estimates the collector gives these two readings at this fixture's time.
        $status.slots[0].forecast=[pscustomobject]@{observedAt=$status.slots[0].observedAt;expectedUsed=69;used=54;pace='behind';secondsToLimit=355698;lastsToReset=$true;recentSecondsToLimit=$null;basis='cycle-average';confidence='estimate'}
        $status.slots[1].cold=$true;$status.slots[1].used5h=0;$status.slots[1].reset5h=''
        $status.slots[1].warmOutcome=@{outcome='unconfirmed'}
        $status.slots[1].actionBlock='outside_work_hours'
        $status.providers.codex.slots[0].buckets.codex.forecast=[pscustomobject]@{observedAt=$now.AddSeconds(-42).ToString('o');expectedUsed=57.1d;used=41;pace='behind';secondsToLimit=497266;lastsToReset=$true;recentSecondsToLimit=$null;basis='cycle-average';confidence='estimate'}
        $status.recentActions=@(@{provider='claude';slot=2;kind='warm_outcome';reason='unconfirmed'})
    }
    return @{
        now = $now
        policy = ($policy | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
        status = ($status | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
    }
}
