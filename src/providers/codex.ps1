# Native Codex owns login and refresh. Ordinary collection never exports tokens.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'provider-observation.ps1')
function Invoke-CodexRpc($Process, $Clock, [int]$TimeoutMs, [int]$Id, [string]$Method, $Params) {
    $request = @{ id = $Id; method = $Method }
    if ($null -ne $Params) { $request.params = $Params }
    $Process.StandardInput.WriteLine(($request | ConvertTo-Json -Depth 8 -Compress))
    $Process.StandardInput.Flush()
    while ($Clock.ElapsedMilliseconds -lt $TimeoutMs) {
        $lineTask = $Process.StandardOutput.ReadLineAsync()
        $left = [Math]::Max(1, $TimeoutMs - [int]$Clock.ElapsedMilliseconds)
        if (-not $lineTask.Wait($left)) { throw 'timeout' }
        $line = $lineTask.Result
        if ($null -eq $line) { throw 'process_exited' }
        if ($line.Length -gt 1048576) { throw 'response_too_large' }
        try { $message = $line.TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop }
        catch { throw 'invalid_json' }
        if ($null -eq $message.id -or [string]$message.id -ne [string]$Id) { continue }
        if ($message.error) {
            # Never expose a server's free-text error, which may contain credentials.
            switch ([string]$message.error.code) {
                '-32600' { throw 'authentication_required' }
                '401' { throw 'authentication_required' }
                '403' { throw 'access_denied' }
                '429' { throw 'rate_limited' }
                default { throw 'rpc_failed' }
            }
        }
        if (-not $message.PSObject.Properties['result']) { throw 'invalid_response' }
        return $message.result
    }
    throw 'timeout'
}
# Plan names change faster than releases. Pass a well-formed name through rather
# than hide a real plan as unknown; anything else stays unknown.
function ConvertTo-Hotpl8CodexPlanType($Value) {
    if($Value -is [string] -and $Value -cmatch '^[a-z][a-z0-9_]{0,23}$'){return $Value}
    return 'unknown'
}
# A healthy native read takes 2-4 s; app-server startup alone can pass 5 s on a
# CPU-saturated machine, where a tighter bound reported every account unavailable.
function Get-CodexReadBudgetMs { 12000 }
function Read-CodexQuota([string]$AccountHome, [string]$Executable, [int]$TimeoutMs = (Get-CodexReadBudgetMs), [string]$WorkingDirectory, [switch]$IncludeAccessToken, [switch]$RefreshToken, [switch]$IdentityOnly) {
    $homeLock = $null
    $proc = $null; $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not [IO.Path]::IsPathRooted($AccountHome) -or -not (Test-Path -LiteralPath $AccountHome -PathType Container)) { throw 'home_missing' }
        $lockPath = Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-codex-' + (Get-Hotpl8Hash ([IO.Path]::GetFullPath($AccountHome).ToLowerInvariant())) + '.lock')
        try { $homeLock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') } catch { throw 'home_busy' }
        $exe = Resolve-CodexExecutable $Executable
        if (-not $WorkingDirectory) { $WorkingDirectory = $AccountHome }
        $psi = New-CodexProcessInfo $exe $AccountHome @('app-server','--stdio') $WorkingDirectory
        foreach ($key in @('CODEX_ACCESS_TOKEN','CODEX_API_KEY','OPENAI_API_KEY','CODEX_SQLITE_HOME')) { $psi.EnvironmentVariables.Remove($key) }
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
        $proc = Start-CodexQuotaProcess $psi
        [void]$proc.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
        $null = Invoke-CodexRpc $proc $clock $TimeoutMs 1 'initialize' @{ clientInfo = @{ name = 'hotpl8'; version = '0.1' }; capabilities = @{ experimentalApi = $true } }
        $proc.StandardInput.WriteLine('{"method":"initialized"}'); $proc.StandardInput.Flush()
        $account = Invoke-CodexRpc $proc $clock $TimeoutMs 2 'account/read' @{ refreshToken = [bool]$RefreshToken }
        if ($account.account.type -ne 'chatgpt') { throw 'subscription_login_required' }
        $quota = if(-not $IdentityOnly){Invoke-CodexRpc $proc $clock $TimeoutMs 3 'account/rateLimits/read' $null}else{$null}
        $config = Invoke-CodexRpc $proc $clock $TimeoutMs 4 'config/read' @{ includeLayers = $false; cwd = $WorkingDirectory }
        # Email is never returned. This private identity key only invalidates old anchors
        # if the normal native login changes; it is omitted from public status.
        $workspace = [string]$config.config.forced_chatgpt_workspace_id
        # Native account/read omits workspace identity. Read only that identity from
        # the native auth file when present. Only the opt-in T3 broker receives an
        # access token over its private pipe, while this home's lock is still held.
        $nativeAuth = Read-Hotpl8Json (Join-Path $AccountHome 'auth.json')
        if ($nativeAuth.tokens.account_id) { $workspace += '|' + [string]$nativeAuth.tokens.account_id }
        $identity = Get-Hotpl8Hash ([string]$account.account.email + '|' + $workspace)
        $standardTransport = -not $config.config.model_providers.openai.base_url
        if ($config.config.chatgpt_base_url -and [string]$config.config.chatgpt_base_url -notmatch '^https://chatgpt\.com/backend-api/?$') { $standardTransport = $false }
        $result = [pscustomobject]@{ status = 'ok'; quota = $quota; identityKey = $identity; planType = (ConvertTo-Hotpl8CodexPlanType $account.account.planType); model = [string]$config.config.model; modelProvider = [string]$config.config.model_provider; standardTransport = $standardTransport; elapsedMs = $clock.ElapsedMilliseconds }
        if($IdentityOnly){
            $verified=[bool]($account.account.email -and $nativeAuth.tokens.account_id)
            $result|Add-Member NoteProperty identityVerified $verified
            if($verified){$result.identityKey=Get-Hotpl8Hash (([string]$account.account.email).Trim().ToLowerInvariant()+'|'+[string]$nativeAuth.tokens.account_id)}
        }
        if($IncludeAccessToken){
            if(-not $nativeAuth.tokens.access_token -or -not $nativeAuth.tokens.account_id){throw 'subscription_login_required'}
            $result|Add-Member NoteProperty auth ([pscustomobject]@{accessToken=[string]$nativeAuth.tokens.access_token;chatgptAccountId=[string]$nativeAuth.tokens.account_id})
        }
        $nativeAuth=$null
        return $result
    } catch {
        $known = @('home_busy','timeout','home_missing','codex_missing','native_codex_required','process_exited','response_too_large','invalid_json','invalid_response','authentication_required','access_denied','rate_limited','rpc_failed','subscription_login_required')
        $reason = [string]$_.Exception.Message
        if ($known -notcontains $reason) { $reason = 'transport_failed' }
        return [pscustomobject]@{ status = $reason; elapsedMs = $clock.ElapsedMilliseconds }
    } finally { Stop-Hotpl8Process $proc; if ($homeLock) { $homeLock.Dispose() } }
}

function ConvertTo-CodexBuckets($Quota, $PreviousBuckets, [datetimeoffset]$Now) {
    $result = [ordered]@{}
    if (-not $Quota) { return [pscustomobject]$result }
    $map = $Quota.rateLimitsByLimitId
    if ($null -eq $map) {
        if ($Quota.rateLimits.limitId) { $map = [pscustomobject]@{ ([string]$Quota.rateLimits.limitId) = $Quota.rateLimits } }
        else { return [pscustomobject]$result }
    }
    if ($map -isnot [pscustomobject]) { return [pscustomobject]$result }
    foreach ($entry in $map.PSObject.Properties) {
        $id = $entry.Name; $row = $entry.Value
        if ($id -notmatch '^[a-zA-Z0-9_-]{1,80}$') { continue }
        $bucket = [ordered]@{ meter = $id; status = 'unsupported'; windows = [pscustomobject]@{}; warm = 'unmeasured' }
        $result[$id] = [pscustomobject]$bucket
        if ($id -notin @('codex','codex_bengalfox') -or $row.limitId -ne $id) { continue }
        if (-not $row.PSObject.Properties['primary'] -or -not $row.PSObject.Properties['secondary']) { continue }
        $windows = [ordered]@{}; $valid = $true
        foreach ($key in @('primary','secondary')) {
            $w = $row.$key
            if ($null -eq $w) { continue }
            if (-not (Test-Hotpl8Number $w.windowDurationMins) -or $w.windowDurationMins -notin @(300,10080)) { $valid = $false; break }
            $duration = [string]$w.windowDurationMins
            if ($windows.Contains($duration) -or -not (Test-Hotpl8Number $w.usedPercent) -or $w.usedPercent -lt 0 -or $w.usedPercent -gt 100) { $valid = $false; break }
            if (-not $w.PSObject.Properties['resetsAt']) { $valid = $false; break }
            if ($null -ne $w.resetsAt -and (-not (Test-Hotpl8Number $w.resetsAt) -or $w.resetsAt -le 0 -or [Math]::Floor($w.resetsAt) -ne $w.resetsAt)) { $valid = $false; break }
            try { if ($null -ne $w.resetsAt) { $null = [datetimeoffset]::FromUnixTimeSeconds([long]$w.resetsAt) } } catch { $valid = $false; break }
            $anchor = 'unconfirmed'
            $old = $PreviousBuckets.$id.windows.$duration
            # Collection stamps observedAt with this same instant, so an elapsed
            # reset here is always the payload-stale half of the rollover rule
            # (Resolve-Hotpl8Window): expired, never refilled. The rollover half
            # belongs to the readers below, which compare against an older read.
            if ($null -ne $w.resetsAt -and $w.resetsAt -le $Now.ToUnixTimeSeconds()) { $anchor = 'expired' }
            elseif ($old -and $null -ne $old.resetsAt -and $w.usedPercent -gt 0 -and $old.usedPercent -gt 0 -and [Math]::Abs($old.resetsAt - $w.resetsAt) -le 5) {
                # A fast manual refresh must retain evidence already established by
                # separated observations. A changed/unused/expired reset still clears it.
                try {
                    $age = ($Now - [datetimeoffset]::Parse($old.observedAt)).TotalSeconds
                    if ($age -ge 30 -or ($age -ge 0 -and $old.anchorState -eq 'observed-active')) { $anchor = 'observed-active' }
                } catch { }
            }
            $windows[$duration] = [pscustomobject]@{ usedPercent = [double]$w.usedPercent; remainingPercent = 100.0 - [double]$w.usedPercent; resetsAt = $w.resetsAt; anchorState = $anchor; observedAt = $Now.ToString('o') }
        }
        # No weekly-only inference from a truncated/malformed response.
        if (-not $valid -or $windows.Count -eq 0) { continue }
        $state = 'observed'
        if ($row.spendControlReached -eq $true -or $null -ne $row.rateLimitReachedType) { $state = 'blocked' }
        if ($null -eq $row.spendControlReached) { $state = 'constraint_unknown' }
        if (($null -ne $row.spendControlReached -and $row.spendControlReached -isnot [bool]) -or ($row.PSObject.Properties['allowed'] -and $row.allowed -isnot [bool])) { $state = 'unsupported' }
        if ($row.PSObject.Properties['allowed'] -and $row.allowed -eq $false) { $state = 'blocked' }
        # Keep why a block exists: plain quota exhaustion with a pending reset is
        # the only block a reset is known to clear. Status itself is unchanged.
        $reason = $null
        if ($state -eq 'blocked') {
            $reason = 'restricted'
            $exhausted = @($windows.Values | Where-Object { $_.usedPercent -eq 100 -and $null -ne $_.resetsAt -and $_.resetsAt -gt $Now.ToUnixTimeSeconds() }).Count -gt 0
            if ($row.rateLimitReachedType -eq 'rate_limit_reached' -and $row.spendControlReached -eq $false -and -not ($row.PSObject.Properties['allowed'] -and $row.allowed -eq $false) -and $exhausted) { $reason = 'quota_exhausted' }
        }
        $result[$id] = [pscustomobject]@{ meter = $id; status = $state; blockReason = $reason; windows = [pscustomobject]$windows; warm = $(if ($windows.Contains('300')) { 'unmeasured' } else { 'not applicable: no five-hour window' }) }
    }
    return [pscustomobject]$result
}
function Get-CodexMargin($Policy, [string]$SlotId, [string]$Duration) {
    Get-Hotpl8ProviderMargin $Policy @{reserve=($SlotId -in @($Policy.reserve))} @{role=$(if($Duration -eq '300'){'short'}else{'weekly'})}
}
function Test-CodexWindowRolledOver($Window, [datetimeoffset]$Now) {
    # One answer to 'did this window's own reset elapse after we read it',
    # so eligibility, ranking and the agent API cannot disagree about it.
    if (-not $Window) { return $false }
    return (Resolve-Hotpl8Window $Window.usedPercent $Window.resetsAt $Window.observedAt $Now -Unix).rolledOver
}
function Get-CodexEligibility($Slot, $Policy, [string]$Meter, [datetimeoffset]$Now, [bool]$Emergency=$false) {
    $account=ConvertTo-Hotpl8CodexObservation $Slot $Meter
    $decision=Get-Hotpl8ProviderDecision @($account) $Policy @{intent='observe';scopes=@($Meter);eligibilityOnly=$true;emergency=$Emergency} $Now
    $reason=$decision.accounts[0].reason
    # Public compatibility codes; the shared decision keeps its detailed reason.
    if($reason -in @('window_unknown','model_quota_unknown')){return 'unknown'}
    if($reason -eq 'window_stale'){return 'stale'}
    return $reason
}
function Select-CodexSlot($Slots, $Policy, [string]$Meter, [string]$PreviousId, $Hold, [datetimeoffset]$Now, $CriticalState=$null) {
    $observations=@(foreach($slot in @($Slots)){ConvertTo-Hotpl8CodexObservation $slot $Meter})
    $capacity=@(Get-Hotpl8CapacityAccounts ([pscustomobject]@{providers=@{codex=@{slots=$Slots}}}) $Policy 'codex' $Now $Meter)
    $observations=@(Add-Hotpl8ObservationCapacity $observations $capacity)
    $decision=Get-Hotpl8ProviderDecision $observations $Policy @{intent='observe';scopes=@($Meter);previousId=$PreviousId;bindingKnown=[bool]$PreviousId;hold=[bool]$Hold;criticalState=$CriticalState} $Now
    return $decision.targetSlot
}
function Assert-CodexPolicy($Policy) {
    Assert-Hotpl8CapacityPolicy $Policy
    Assert-Hotpl8CriticalPolicy $Policy
    foreach($field in $Policy.PSObject.Properties){if($field.Name -notin @('slots','prefer','reserve','disabled','order','defaultMeter','modelMeters','margin5h','margin7d','margin7dWork','hysteresis','resetLeadMin','capacity','critical')){throw 'invalid_codex_field'}}
    $ids = @{}; $homes = @{}
    foreach ($slot in @($Policy.slots)) {
        if (-not $slot -or [string]$slot.id -notmatch '^[a-zA-Z0-9_-]{1,40}$') { throw 'invalid_slot' }
        $path = [string]$slot.home
        if (-not [IO.Path]::IsPathRooted($path)) { throw 'invalid_home' }
        $path = [IO.Path]::GetFullPath($path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        if ($ids.ContainsKey([string]$slot.id) -or $homes.ContainsKey($path)) { throw 'duplicate_slot_or_home' }
        $ids[[string]$slot.id] = $true; $homes[$path] = $true
        if ([string]$slot.label -match '[\x00-\x1f\x7f]' -or ([string]$slot.label).Length -gt 80) { throw 'invalid_label' }
    }
    foreach ($name in @('prefer','reserve','disabled')) {
        $seen = @{}
        foreach ($id in @($Policy.$name)) { if (-not $id) { continue }; if (-not $ids.ContainsKey([string]$id) -or $seen.ContainsKey([string]$id)) { throw 'invalid_preference' }; $seen[[string]$id] = $true }
    }
    foreach ($key in @('margin5h','margin7d','margin7dWork','hysteresis')) {
        if ($null -ne $Policy.$key -and (-not (Test-Hotpl8Number $Policy.$key) -or $Policy.$key -lt 0 -or $Policy.$key -gt 100)) { throw 'invalid_margin' }
    }
    if ($Policy.defaultMeter -and $Policy.defaultMeter -notin @('codex','codex_bengalfox')) { throw 'invalid_meter' }
    if ($Policy.order -and $Policy.order -notin @('prefer','soonest-reset','weekly-expiry','balanced')) { throw 'invalid_order' }
    # Legacy maps are inert compatibility data; native owns model availability.
    if($Policy.PSObject.Properties['modelMeters'] -and $Policy.modelMeters -isnot [pscustomobject]){throw 'invalid_model_meter'}
    if($null -ne $Policy.resetLeadMin -and (-not (Test-Hotpl8Number $Policy.resetLeadMin) -or $Policy.resetLeadMin -lt 0 -or $Policy.resetLeadMin -gt 604800)){throw 'invalid_reset_lead'}
    foreach($id in @($Policy.disabled)){if($id -and -not $ids.ContainsKey([string]$id)){throw 'invalid_disabled_slot'}}
}
