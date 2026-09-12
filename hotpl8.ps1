# refresh observes; tick applies policy. Authentication belongs to native provider tools.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('watch', 'status', 'refresh', 'tick', 'codex', 'doctor', 'version', 'help', 'init', 'enroll')]
    [string]$Command = 'watch',
    [string]$Slot,
    [string]$Model,
    [string]$StateDirectory,
    [string]$CodexExecutable,
    [switch]$AsJson,
    [string]$AccountHome,
    [string]$Label,
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$CodexArguments
)

$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot 'src/common.ps1')
    . (Join-Path $PSScriptRoot 'src/config.ps1')
    . (Join-Path $PSScriptRoot 'src/diagnostics.ps1')
    . (Join-Path $PSScriptRoot 'src/providers/claude.ps1')
    . (Join-Path $PSScriptRoot 'src/providers/codex.ps1')
    $StateDirectory = Resolve-Hotpl8StateDirectory $StateDirectory $PSScriptRoot

    # These commands do not need an existing policy or a provider observation.
    if ($Command -eq 'version') {
        (Get-Content (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
        exit 0
    }
    if ($Command -eq 'help') {
        'hotpl8 [watch|status|refresh|tick|doctor|version|init|enroll|codex]'
        'watch: cached dashboard; Space freezes the view only.'
        'refresh: collect quotas without switching, warming, or recovery prompts.'
        'tick: collect and apply actions enabled by policy; monitor mode prevents actions.'
        'status -AsJson: local cached snapshot (may contain private labels).'
        'doctor -AsJson: redacted offline diagnostics; no login or quota calls.'
        'init: create a monitoring-only policy if none exists.'
        'enroll -Slot main -AccountHome PATH: enroll an already signed-in native Codex home.'
        'codex [-Slot ID] [-Model ID] [native arguments]; resume requires -Slot.'
        'All commands accept -StateDirectory PATH. See docs/usage.md.'
        exit 0
    }
    if ($Command -eq 'init') {
        [void][IO.Directory]::CreateDirectory($StateDirectory)
        $path = Join-Path $StateDirectory 'policy.json'
        if (Test-Path -LiteralPath $path) {
            throw 'policy.json already exists; it was not overwritten.'
        }
        [IO.File]::Copy((Join-Path $PSScriptRoot 'policy.example.json'), $path, $false)
        'Created a monitoring policy. Next: hotpl8 enroll -Slot main -AccountHome PATH'
        'Use the home you signed into with native Codex. For Claude, see docs/install.md.'
        exit 0
    }
    if ($Command -eq 'doctor') {
        $report = Get-Hotpl8Doctor $StateDirectory
        if ($AsJson) { $report | ConvertTo-Json -Depth 5 }
        else { Format-Hotpl8Doctor $report }
        # Preserve the JSON/exit contract; human output describes readiness separately.
        if (-not $report.policyValid) { exit 1 }
        exit 0
    }

    $policy = Read-Hotpl8Json (Join-Path $StateDirectory 'policy.json')
    if (-not $policy) { throw 'No valid policy.json. Run hotpl8 init or see docs/install.md.' }
    Assert-Hotpl8Policy $policy

    if ($Command -eq 'enroll') {
        if (-not $Slot -or -not $AccountHome) {
            throw 'Use hotpl8 enroll -Slot main -AccountHome PATH. Sign into that home with native Codex first.'
        }
        if ($CodexArguments -or $Model -or $AsJson) {
            throw 'Enrollment accepts -Slot, -AccountHome, and optional -Label; see hotpl8 help.'
        }
        & (Join-Path $PSScriptRoot 'setup-codex.ps1') -Slot $Slot -AccountHome $AccountHome -Label $Label -StateDirectory $StateDirectory -CodexExecutable $CodexExecutable
        'Next: hotpl8 refresh, then hotpl8 to open the dashboard.'
        exit 0
    }
    if ($AccountHome -or $Label) { throw '-AccountHome and -Label are enrollment options. Use hotpl8 enroll.' }

    if ($Command -eq 'watch') {
        . (Join-Path $PSScriptRoot 'src/dashboard.ps1')
        Show-Hotpl8Dashboard $StateDirectory
        exit 0
    }
    if ($Command -in @('refresh', 'tick')) {
        if (-not $policy.prefer -and -not $policy.codex.slots) {
            throw 'No accounts enrolled. Run hotpl8 enroll -Slot main -AccountHome PATH; Claude setup is in docs/install.md.'
        }
        & (Join-Path $PSScriptRoot 'tick.ps1') -StateDirectory $StateDirectory -CodexExecutable $CodexExecutable -ObserveOnly:($Command -eq 'refresh') -Strict
        if ($LASTEXITCODE -ne 0) {
            throw 'Collection incomplete. Run hotpl8 doctor; inspect local events.jsonl. Old data is not a fresh result.'
        }
        $Command = 'status'
    }

    $status = Read-Hotpl8Json (Join-Path $StateDirectory 'status.json')
    if ($Command -eq 'status') {
        if (-not $status) { 'No cached status. Run hotpl8 refresh.'; exit 0 }
        if ($AsJson) { $status | ConvertTo-Json -Depth 24; exit 0 }
        'HotPl8 | generated ' + (ConvertTo-Hotpl8SafeText $status.generatedAt)
        $age = ([datetimeoffset]::UtcNow - [datetimeoffset]::Parse($status.generatedAt)).TotalSeconds
        if ($age -gt 900 -or $age -lt -5) { 'STALE: refresh before relying on these readings.' }
        ConvertTo-Hotpl8SafeText ('Claude: active slot ' + $status.active + ' | ' + $status.verdict)
        foreach ($account in @($status.slots)) {
            $fiveHour = if ($null -eq $account.used5h) { 'unknown' } else { [string](100 - $account.used5h) + '% remaining' }
            $weekly = if ($null -eq $account.used7d) { 'unknown' } else { [string](100 - $account.used7d) + '% remaining' }
            ConvertTo-Hotpl8SafeText ('  ' + $account.label + ' [' + $account.slot + '] 5h ' + $fiveHour + ' | 7d ' + $weekly + ' | ' + $account.status)
        }
        if ($status.providers.codex) {
            Format-CodexStatus $status.providers.codex $policy.codex | ForEach-Object { ConvertTo-Hotpl8SafeText $_ }
        } else {
            'Codex: not configured or no observation yet.'
        }
        exit 0
    }

    if (-not $policy.codex) { throw 'No Codex slots configured.' }
    $plan = Get-CodexLaunchPlan $policy.codex $status.providers.codex $Slot $Model $CodexArguments ([datetimeoffset]::UtcNow)
    exit (Invoke-Hotpl8Codex $plan $StateDirectory $CodexExecutable (Get-Location).Path)
} catch {
    [Console]::Error.WriteLine('HotPl8: ' + (ConvertTo-Hotpl8SafeText $_.Exception.Message))
    exit 1
}
