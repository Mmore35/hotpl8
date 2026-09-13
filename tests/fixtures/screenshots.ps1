# Fictional, fixed-time documentation data. Never read account homes or cached state here.
function Get-Hotpl8ScreenshotFixture([switch]$Operations) {
    $now = [datetimeoffset]::Parse('2026-09-12T12:00:00Z')
    $policy = @{
        mode = 'monitor'; prefer = @(1, 2); reserve = @(2)
        labels = @{ '1' = 'Everyday'; '2' = 'Reserve' }
        codex = @{
            slots = @(@{ id = 'work'; label = 'Work' }, @{ id = 'personal'; label = 'Personal' })
            defaultMeter = 'codex'; margin5h = 25; margin7d = 20; margin7dWork = 5
        }
    }
    $status = @{
        generatedAt = $now.AddSeconds(-42).ToString('o'); active = 1; hold = $null
        slots = @(
            @{ slot = 1; label = 'Everyday'; status = 'ok'; observedAt = $now.AddSeconds(-42).ToString('o'); active = $true; fresh = $true
               used5h = 38; used7d = 54; reset5h = $now.AddMinutes(83).ToString('o'); reset7d = $now.AddDays(2).AddHours(4).ToString('o') },
            @{ slot = 2; label = 'Reserve'; status = 'ok'; observedAt = $now.AddSeconds(-42).ToString('o'); active = $false; fresh = $true
               used5h = 8; used7d = 17; reset5h = $now.AddHours(4).ToString('o'); reset7d = $now.AddDays(5).ToString('o') }
        )
        providers = @{
            codex = @{
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
    if($Operations){
        $status.collector=@{startedAt=$now.AddSeconds(-45).ToString('o');completedAt=$now.AddSeconds(-42).ToString('o');status='ok'}
        $status.slots[0].observedAt=$now.AddSeconds(-42).ToString('o')
        $status.slots[0].forecast=Get-Hotpl8Forecast 54 $status.slots[0].reset7d $status.slots[0].observedAt 10080 $now
        $status.slots[1].cold=$true;$status.slots[1].used5h=0;$status.slots[1].reset5h=''
        $status.slots[1].warmOutcome=@{outcome='unconfirmed'}
        $status.slots[1].actionBlock='outside_work_hours'
        $status.providers.codex.slots[0].buckets.codex.forecast=Get-Hotpl8Forecast 41 $now.AddDays(3).ToString('o') $now.AddSeconds(-42).ToString('o') 10080 $now
        $status.recentActions=@(@{provider='claude';slot=2;kind='warm_outcome';reason='unconfirmed'})
    }
    return @{
        now = $now
        policy = ($policy | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
        status = ($status | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
    }
}
