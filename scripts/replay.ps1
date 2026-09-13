# Explicit read-only trace comparison. Input is an array of status snapshots.
param([Parameter(Mandatory=$true)][string]$Trace,[Parameter(Mandatory=$true)][string]$PolicyPath)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/config.ps1')
. (Join-Path $root 'src/insights.ps1')
. (Join-Path $root 'src/providers/claude.ps1')
. (Join-Path $root 'src/providers/codex.ps1')
. (Join-Path $root 'src/replay.ps1')
$policy=Read-Hotpl8Json $PolicyPath;Assert-Hotpl8Policy $policy
if($policy.codex){Assert-CodexPolicy $policy.codex}
if((Get-Item -LiteralPath $Trace).Length -gt 16777216){throw 'Trace exceeds 16 MB. Split it into bounded comparisons.'}
$frames=Read-Hotpl8Json $Trace
if(-not $frames -or @($frames).Count -gt 10000){throw 'Trace must contain 1 to 10000 snapshots.'}
Invoke-Hotpl8Replay @($frames) $policy|ConvertTo-Json -Depth 16
