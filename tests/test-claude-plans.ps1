$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/config.ps1')
. (Join-Path $root 'src/providers/claude-plans.ps1')
$now=[datetimeoffset]::Parse('2026-09-14T12:00:00Z')
function Assert($value){if(-not $value){throw 'Plan detection assertion failed'}}
# A plan as the collector keeps it for an account it has just asked about.
$detected=[pscustomobject]@{status='detected';identityKey=(Get-Hotpl8Hash 'fictional@example.invalid|fictional-org');profile='claude-pro';label='Pro';sessionMultiplier=1;source='anthropic-oauth-profile';observedAt=$now.ToString('o');nextAttemptAt=$now.AddMinutes(15).ToString('o')}
$part=[pscustomobject]@{}
$auto=Get-Hotpl8AccountCapacity $part 1 claude '' $detected $now
Assert ($auto.profile -eq 'claude-pro' -and $null -eq $auto.weekly -and $null -eq $auto.fiveHour)
$part|Add-Member NoteProperty capacity @{ '1'=@{profile='claude-max-20x';weekly=7;fiveHour=2} }
$manual=Get-Hotpl8AccountCapacity $part 1 claude '' $detected $now
Assert ($manual.weekly -eq 7 -and $manual.fiveHour -eq 2 -and $manual.profile -eq 'claude-max-20x')
Assert (-not (Test-Hotpl8DetectedPlan $detected $now.AddHours(1)))
Assert (Test-Hotpl8DetectedPlan $detected $now.AddSeconds(901))
Assert (-not (Test-Hotpl8DetectedPlan $detected $now.AddSeconds(1201)))
Assert (-not (Test-Hotpl8DetectedPlan $detected $now.AddMinutes(-1)))
'PASS automatic profile preserves unknown conversions and explicit overrides'
