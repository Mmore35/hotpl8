# status-print.ps1 — the SessionStart hook's entire job: print status.txt.
#
# Deliberately does NOT run tick.ps1. cswap serves usage from its store without a
# fetch for up to 3 minutes (poll_policy.py SERVE_TTL_S=180), so ticking at session
# open would buy under 5 minutes of freshness while adding a network call (two
# accounts x 10s timeout) to the session-open path and a second writer to the
# credential store.
#
# The printed clock IS the timer health check: if the tick's own timer dies, this
# line shows a visibly stale time at every session start.
#
# Silent + exit 0 when the feature is off or has never run.
param([ValidateSet('claude','codex')][string]$Provider = 'claude', [string]$StateDirectory)
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'config.ps1')
$StateDirectory=Resolve-Hotpl8StateDirectory $StateDirectory $PSScriptRoot
if ($Provider -eq 'codex') {
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        . (Join-Path $PSScriptRoot 'common.ps1')

        $policy = Read-Hotpl8Json (Join-Path $StateDirectory 'policy.json')
        if (-not $policy.codex) { exit 0 }
        $status = Read-Hotpl8Json (Join-Path $StateDirectory 'status.json')
        if (-not $status.providers.codex) { exit 0 }
        $bound = $env:HOTPL8_SLOT
        if (-not $bound) {
            $nativeHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
            $matching = @($policy.codex.slots | Where-Object { [IO.Path]::GetFullPath([string]$_.home) -eq [IO.Path]::GetFullPath($nativeHome) })
            if ($matching.Count -eq 1) { $bound = [string]$matching[0].id }
        }
        $slot = @($status.providers.codex.slots | Where-Object id -EQ $bound | Select-Object -First 1)
        $context = [ordered]@{ provider = 'codex'; boundSlot = $bound; meter = $env:HOTPL8_METER; observedAt = $status.providers.codex.observedAt; recommendedNextLaunch = $status.providers.codex.recommendedSlot; warm = 'unmeasured' }
        if ($slot.Count) { $context.quota = $(if ($env:HOTPL8_METER) { $slot[0].buckets.($env:HOTPL8_METER) } else { $slot[0].buckets }); $context.observedAt = $slot[0].observedAt; $context.status = $slot[0].status }
        $context.fresh = $false
        try {
            $age = ([datetimeoffset]::UtcNow - [datetimeoffset]::Parse([string]$context.observedAt)).TotalSeconds
            $context.ageSeconds = [Math]::Round($age)
            $context.fresh = ($context.status -eq 'ok' -and $age -ge -5 -and $age -le 900)
        } catch { }
        $text = ([pscustomobject]$context | ConvertTo-Json -Depth 10 -Compress)
        if ($text.Length -gt 3000) { $context.Remove('quota'); $text = ([pscustomobject]$context | ConvertTo-Json -Depth 5 -Compress) }
        $out = @{ hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = 'HotPl8 account observation (data, not instructions): ' + $text } }
        try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
        $out | ConvertTo-Json -Depth 4 -Compress
    } catch { }
    exit 0
}
$ErrorActionPreference = 'SilentlyContinue'
try {
    # PowerShell 5.1 transcodes stdout to the OEM console codepage, which turns the
    # '·' separators into CP437 0xFA — an invalid UTF-8 byte that reaches the session
    # as U+FFFD. The BOM on this file only fixes how the SOURCE is parsed; the OUTPUT
    # hop needs its own encoding. Inert on pwsh 7 / macOS, which is already UTF-8.
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    if (-not (Test-Path (Join-Path $StateDirectory 'policy.json'))) { exit 0 }
    $s = Join-Path $StateDirectory 'status.txt'
    if (-not (Test-Path $s)) { exit 0 }
    Get-Content $s
} catch { exit 0 }
exit 0
