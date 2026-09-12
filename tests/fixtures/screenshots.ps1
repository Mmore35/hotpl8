# Fictional, fixed-time documentation data. Never read account homes or cached state here.
function Get-Hotpl8ScreenshotFixture {
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
            @{ slot = 1; label = 'Everyday'; status = 'ok'; active = $true; fresh = $true
               used5h = 38; used7d = 54; reset5h = $now.AddMinutes(83).ToString('o'); reset7d = $now.AddDays(2).AddHours(4).ToString('o') },
            @{ slot = 2; label = 'Reserve'; status = 'ok'; active = $false; fresh = $true
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
    return @{
        now = $now
        policy = ($policy | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
        status = ($status | ConvertTo-Json -Depth 16 | ConvertFrom-Json)
    }
}
