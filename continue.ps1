# continue.ps1 - after a usage-limit failure, wait until HotPl8 has an account ready, then
# ask the host to continue the same conversation.
#
# Exit 2 = continue now ("Automated message: continue." on stderr). Exit 0 = stand down.
# Claude runs this as its StopFailure hook (hook JSON on stdin); the Codex bridge runs it
# with -Conversation. Both wait on the one readiness rule below, read from status.json.
# -Held: the continue for this failure was decided before and could not be delivered then,
# so the host asks again. -After is the time of the failure in both cases.
# Every error path stands down: a missed continue is harmless, a wrong one is not.
param([string]$Provider = 'claude', [string]$StateDirectory, [string]$Conversation, [string]$Slot, [string]$After, [string[]]$WatchPid, [int]$PollSeconds = 5, [switch]$Held)
$ErrorActionPreference = 'Stop'
# A terminal session has its owner in front of it; only hosted conversations are continued.
if (-not $Conversation -and $env:CLAUDE_CODE_ENTRYPOINT -eq 'cli') { exit 0 }
try {
    . (Join-Path $PSScriptRoot 'src/common.ps1')
    . (Join-Path $PSScriptRoot 'src/config.ps1')
    $StateDirectory = Resolve-Hotpl8StateDirectory $StateDirectory $PSScriptRoot
    $statusPath = Join-Path $StateDirectory 'status.json'
    function Complete-Hotpl8Continue([bool]$Send) {
        Write-Hotpl8Event $StateDirectory $(if ($Send) { 'continue_sent' } else { 'continue_skipped' })
        if ($Send) { [Console]::Error.Write('Automated message: continue.'); exit 2 }
        exit 0
    }
    function Test-Hotpl8Continuing {
        $policy = Read-Hotpl8Json (Join-Path $StateDirectory 'policy.json')
        if (-not $policy) { return $false }
        Assert-Hotpl8Policy $policy
        return [bool](Get-Hotpl8Actions $policy $false).continuing
    }
    function Read-Hotpl8ContinueState {
        # The same provider view as status-print.ps1, so version 3 policies read alike.
        $status = Read-Hotpl8Json $statusPath
        if (-not $status) { throw 'status unavailable' }
        $view = Get-Hotpl8ProviderView $status (Read-Hotpl8Json (Join-Path $StateDirectory 'policy.json')) $Provider
        $claude = $view.driver.provider -eq 'claude'
        $rows = @{}
        foreach ($row in @($(if ($claude) { $view.snapshot.slots } else { $view.snapshot.providers.codex.slots }))) {
            if ($row) { $rows[[string]$(if ($claude) { $row.slot } else { $row.id })] = $row.observedAt }
        }
        return @{ selected = [string]$status.providerOverview.$Provider.selected; active = $(if ($claude) { [string]$view.snapshot.active }); claude = $claude; observed = $rows }
    }
    $transcript = $null; $size = -1
    if (-not $Conversation) {
        # Hosts send this as UTF-8; the console's own encoding would misread a path outside ASCII.
        $hook = (New-Object IO.StreamReader([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
        $Conversation = [string]$hook.session_id
        $transcript = [string]$hook.transcript_path
        if ($transcript -and (Test-Path -LiteralPath $transcript)) { $size = (Get-Item -LiteralPath $transcript).Length }
        if ($env:CLAUDE_PID) {
            $WatchPid = @($env:CLAUDE_PID)
            $process = Get-Process -Id ([int]$env:CLAUDE_PID)
            $parent = if ($process.Parent) { $process.Parent.Id } else { (Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$env:CLAUDE_PID)).ParentProcessId }
            if ($parent) { $WatchPid += @([string]$parent) }
        }
        $Slot = (Read-Hotpl8ContinueState).active
    }
    if ($Conversation -cnotmatch '^[A-Za-z0-9-]{1,128}$') { exit 0 }
    $limited = if ($After) { [datetimeoffset]::Parse($After) } else { [datetimeoffset]::UtcNow }
    $watched = @($WatchPid | Where-Object { $_ } | ForEach-Object { [int]$_ })
    if (-not (Test-Hotpl8Continuing)) { Complete-Hotpl8Continue $false }
    # One automatic continue per conversation every ten minutes: a continue that
    # fails again must not become a loop. A held continue was never delivered, so
    # the record of its own earlier decision does not count against it.
    $markers = Join-Path $StateDirectory 'continue'
    $marker = Join-Path $markers $Conversation
    [void][IO.Directory]::CreateDirectory($markers)
    foreach ($old in @(Get-ChildItem -LiteralPath $markers -File | Where-Object { $_.Name -cmatch '^[A-Za-z0-9-]+$' })) {
        if (-not $Held -and $old.Name -ceq $Conversation -and $old.LastWriteTimeUtc -gt [datetime]::UtcNow.AddMinutes(-10)) { Complete-Hotpl8Continue $false }
        if ($old.LastWriteTimeUtc -lt [datetime]::UtcNow.AddDays(-1)) { Remove-Item -LiteralPath $old.FullName -Force }
    }
    $deadline = $limited.UtcDateTime.AddHours(6); $written = $null; $state = $null
    while ($true) {
        # Nobody left to continue for: the host is gone, the conversation moved on, or it has been too long.
        foreach ($id in $watched) { if (-not (Get-Process -Id $id -ErrorAction SilentlyContinue)) { Complete-Hotpl8Continue $false } }
        if ($size -ge 0 -and (Get-Item -LiteralPath $transcript).Length -ne $size) { Complete-Hotpl8Continue $false }
        if ([datetime]::UtcNow -gt $deadline) { Complete-Hotpl8Continue $false }
        $stamp = (Get-Item -LiteralPath $statusPath).LastWriteTimeUtc
        if ($stamp -ne $written) { $written = $stamp; $state = Read-Hotpl8ContinueState }
        # Ready: an account is selected and (for Claude) already in use, it is either a
        # different account or the same one read again after the limit, and automation is not
        # paused. The pause is the compiled program's to answer, so it is asked last and only
        # when everything else holds: a wait asks nothing.
        $ready = $state.selected -and (-not $state.claude -or $state.selected -eq $state.active)
        if ($ready -and $state.selected -eq $Slot) {
            $observed = $state.observed[$Slot]
            $ready = $observed -and [datetimeoffset]::Parse([string]$observed) -gt $limited
        }
        if ($ready) { $ready = -not (Get-Hotpl8Pause $StateDirectory) }
        if ($ready) {
            if (-not (Test-Hotpl8Continuing)) { Complete-Hotpl8Continue $false }
            [IO.File]::WriteAllText($marker, '')
            Complete-Hotpl8Continue $true
        }
        Start-Sleep -Seconds $PollSeconds
    }
} catch { exit 0 }
