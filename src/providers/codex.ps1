# Native Codex quota observations. No token copying, token refresh, or inference.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'selection.ps1')
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
function Read-CodexQuota([string]$AccountHome, [string]$Executable, [int]$TimeoutMs = 5000, [string]$WorkingDirectory) {
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
        [void]$proc.StandardError.ReadToEndAsync()
        $null = Invoke-CodexRpc $proc $clock $TimeoutMs 1 'initialize' @{ clientInfo = @{ name = 'hotpl8'; version = '0.1' }; capabilities = @{ experimentalApi = $true } }
        $proc.StandardInput.WriteLine('{"method":"initialized"}'); $proc.StandardInput.Flush()
        $account = Invoke-CodexRpc $proc $clock $TimeoutMs 2 'account/read' @{ refreshToken = $false }
        if ($account.account.type -ne 'chatgpt') { throw 'subscription_login_required' }
        $quota = Invoke-CodexRpc $proc $clock $TimeoutMs 3 'account/rateLimits/read' $null
        $config = Invoke-CodexRpc $proc $clock $TimeoutMs 4 'config/read' @{ includeLayers = $false; cwd = $WorkingDirectory }
        # Email is never returned. This private identity key only invalidates old anchors
        # if the normal native login changes; it is omitted from public status.
        $workspace = [string]$config.config.forced_chatgpt_workspace_id
        # Native account/read omits workspace identity. Read only that identity from
        # the native auth file when present; never return or persist its token fields.
        $nativeAuth = Read-Hotpl8Json (Join-Path $AccountHome 'auth.json')
        if ($nativeAuth.tokens.account_id) { $workspace += '|' + [string]$nativeAuth.tokens.account_id }
        $nativeAuth = $null
        $identity = Get-Hotpl8Hash ([string]$account.account.email + '|' + $workspace)
        $standardTransport = -not $config.config.model_providers.openai.base_url
        if ($config.config.chatgpt_base_url -and [string]$config.config.chatgpt_base_url -notmatch '^https://chatgpt\.com/backend-api/?$') { $standardTransport = $false }
        return [pscustomobject]@{ status = 'ok'; quota = $quota; identityKey = $identity; planType = $(if([string]$account.account.planType -in @('free','plus','pro','team','business','enterprise','edu')){[string]$account.account.planType}else{'unknown'}); model = [string]$config.config.model; modelProvider = [string]$config.config.model_provider; standardTransport = $standardTransport; elapsedMs = $clock.ElapsedMilliseconds }
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
        $result[$id] = [pscustomobject]@{ meter = $id; status = $state; windows = [pscustomobject]$windows; warm = $(if ($windows.Contains('300')) { 'unmeasured' } else { 'not applicable: no five-hour window' }) }
    }
    return [pscustomobject]$result
}
function Get-CodexMargin($Policy, [string]$SlotId, [string]$Duration) {
    if ($Duration -eq '300') { if ($null -ne $Policy.margin5h) { return [double]$Policy.margin5h }; return 25.0 }
    if (@($Policy.reserve) -notcontains $SlotId -and $null -ne $Policy.margin7dWork) { return [double]$Policy.margin7dWork }
    if ($null -ne $Policy.margin7d) { return [double]$Policy.margin7d }
    return 20.0
}
function Get-CodexEligibility($Slot, $Policy, [string]$Meter, [datetimeoffset]$Now, [bool]$Emergency=$false) {
    if($Slot.id -in @($Policy.disabled)){return 'disabled'}
    if ($Slot.status -ne 'ok') { return [string]$Slot.status }
    try { $age = ($Now - [datetimeoffset]::Parse($Slot.observedAt)).TotalSeconds } catch { return 'unknown' }
    if ($age -lt -5 -or $age -gt 900) { return 'stale' }
    $b = $Slot.buckets.$Meter
    if (-not $b -or $b.status -ne 'observed') { if ($b) { return [string]$b.status }; return 'meter_unknown' }
    # A supported native shape can explicitly omit either window. Evaluate all real ones.
    $count = 0
    foreach ($w in $b.windows.PSObject.Properties) {
        $count++
        # A window we read before its own reset, whose reset has now passed,
        # refilled; only an anchor that was already expired when we read it
        # stays unconfirmed.
        $resolved = Resolve-Hotpl8Window $w.Value.usedPercent $w.Value.resetsAt $w.Value.observedAt $Now -Unix
        if ($resolved.rolledOver) { continue }
        if ($null -ne $w.Value.resetsAt -and $w.Value.resetsAt -le $Now.ToUnixTimeSeconds()) { return 'reset_unconfirmed' }
        $margin=Get-CodexMargin $Policy $Slot.id $w.Name
        if($Emergency -and $Policy.critical.enabled -eq $true -and $Slot.id -notin @($Policy.reserve)){$margin=if($Policy.critical.drainToZero){0}else{Get-Hotpl8CriticalSetting $Policy 'floorPercent' 1}}
        if (-not (Test-Hotpl8Number $w.Value.remainingPercent) -or $w.Value.remainingPercent -gt 100 -or $w.Value.remainingPercent -le 0 -or $w.Value.remainingPercent -lt $margin) { return 'below_margin' }
    }
    if ($count -eq 0) { return 'unknown' }
    return 'eligible'
}
function Select-CodexSlot($Slots, $Policy, [string]$Meter, [string]$PreviousId, $Hold, [datetimeoffset]$Now, $CriticalState=$null) {
    $snapshot=[pscustomobject]@{providers=[pscustomobject]@{codex=[pscustomobject]@{slots=$Slots}}}
    $accounts=@(Get-Hotpl8CapacityAccounts $snapshot $Policy 'codex' $Now $Meter)
    $critical=Get-Hotpl8CriticalDecision $accounts $Policy $PreviousId $CriticalState $Now
    if($critical.active -and $critical.ranked.Count){if($Hold){if($PreviousId -in $critical.ranked){return $PreviousId};return $null};return $critical.selected}
    $rows = @(); $index = 0
    $preferred = @($Policy.prefer)
    foreach ($slot in @($Slots)) {
        if ((Get-CodexEligibility $slot $Policy $Meter $Now) -ne 'eligible') { continue }
        $idx = [array]::IndexOf($preferred, [string]$slot.id)
        if ($idx -lt 0) { $idx = $preferred.Count + $index }; $index++
        $tier = if (@($Policy.reserve) -contains $slot.id) { 1 } else { 0 }
        $week = $slot.buckets.$Meter.windows.'10080'
        $degraded = 0; $key = [double]$idx; $reset = $null
        $window = $slot.buckets.$Meter.windows.'300'
        if (-not $window) { $window = $week }
        if ($window -and $window.anchorState -eq 'observed-active') { $reset = $window.resetsAt }
        if ($Policy.order -eq 'soonest-reset') { $key = [double]::MaxValue; if ($null -ne $reset) { $key = [double]$reset } }
        if($Policy.order -in @('weekly-expiry','balanced')){
            $weekReset=if($week -and $week.anchorState -eq 'observed-active' -and $week.resetsAt){[datetimeoffset]::FromUnixTimeSeconds($week.resetsAt).ToString('o')}else{$null}
            $key=Get-Hotpl8SelectionKey $Policy.order $slot.buckets.$Meter.windows.'300'.remainingPercent $week.remainingPercent $weekReset $Now
        }
        $preferredWeek = if ($null -ne $Policy.margin7d) { [double]$Policy.margin7d } else { 20 }
        if ($week -and $week.remainingPercent -lt $preferredWeek) { $degraded = 1; $key = -$week.remainingPercent }
        $rows += [pscustomobject]@{ id = $slot.id; tier = $tier; degraded = $degraded; key = $key; idx = $idx; reset = $reset; slot = $slot }
    }
    $ordered = @($rows | Sort-Object tier,degraded,key,idx)
    if ($ordered.Count -eq 0) { return $null }
    $best = $ordered[0]
    $prior = @($ordered | Where-Object id -EQ $PreviousId | Select-Object -First 1)
    if ($Hold) { if ($prior.Count) { return $prior[0].id }; return $null }
    if ($prior.Count -and $best.id -ne $PreviousId -and $best.tier -ge $prior[0].tier -and $best.degraded -ge $prior[0].degraded) {
        $lead = if ($null -ne $Policy.resetLeadMin) { [double]$Policy.resetLeadMin * 60 } else { 600 }
        # Reset hysteresis only arbitrates reset ordering. Degraded accounts rank
        # by weekly headroom, and prefer ordering must honor its own preference.
        if ($Policy.order -eq 'soonest-reset' -and $best.degraded -eq 0 -and $prior[0].degraded -eq 0 -and $null -ne $best.reset -and $null -ne $prior[0].reset -and ($prior[0].reset - $best.reset) -lt $lead) { return $PreviousId }
        if ($Policy.order -ne 'soonest-reset') {
            $band = if ($null -ne $Policy.hysteresis) { [double]$Policy.hysteresis } else { 10 }
            $short = $best.slot.buckets.$Meter.windows.'300'
            if ($short -and $short.remainingPercent -lt ((Get-CodexMargin $Policy $best.id '300') + $band)) { return $PreviousId }
        }
    }
    return $best.id
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
    foreach($entry in $Policy.modelMeters.PSObject.Properties){if($entry.Name -notmatch '^[a-zA-Z0-9_.-]{1,100}$' -or $entry.Value -notin @('codex','codex_bengalfox')){throw 'invalid_model_meter'}}
    if($null -ne $Policy.resetLeadMin -and (-not (Test-Hotpl8Number $Policy.resetLeadMin) -or $Policy.resetLeadMin -lt 0 -or $Policy.resetLeadMin -gt 604800)){throw 'invalid_reset_lead'}
    foreach($id in @($Policy.disabled)){if($id -and -not $ids.ContainsKey([string]$id)){throw 'invalid_disabled_slot'}}
}
function Invoke-CodexCollection($Policy, [string]$StateDirectory, [string]$Executable, $Previous, [scriptblock]$Reader) {
    Assert-CodexPolicy $Policy
    $statePath = Join-Path $StateDirectory 'codex-state.json'
    $state = Read-Hotpl8Json $statePath
    $nextState = [ordered]@{}
    $clock = [Diagnostics.Stopwatch]::StartNew(); $now = [datetimeoffset]::UtcNow
    $slots = @(); $configured = @($Policy.slots)
    # Oldest-attempt first ensures a slow large fleet cannot starve its last slots.
    $queue = @($configured | Sort-Object @{ Expression = { $s = $state.slots.([string]$_.id); if ($s.lastAttemptAt) { $s.lastAttemptAt } else { '' } } })
    foreach ($slot in $queue) {
        $id = [string]$slot.id; $old = $state.slots.$id
        $binding = Get-Hotpl8Hash ([IO.Path]::GetFullPath([string]$slot.home))
        if ($old -and $old.binding -ne $binding) { $old = $null }
        $read = $null
        if ($id -in @($Policy.disabled)) { $read = [pscustomobject]@{ status = 'disabled'; elapsedMs = 0 } }
        elseif ($clock.ElapsedMilliseconds -ge 20000) { $read = [pscustomobject]@{ status = 'collection_budget'; elapsedMs = 0 } }
        elseif ($old.retryAfter -and [datetimeoffset]::Parse($old.retryAfter) -gt $now) { $read = [pscustomobject]@{ status = 'backoff'; elapsedMs = 0 } }
        else {
            $budget = [Math]::Min(5000, 20000 - [int]$clock.ElapsedMilliseconds)
            if ($Reader) { $read = & $Reader $slot.home $Executable $budget }
            else { $read = Read-CodexQuota $slot.home $Executable $budget }
        }
        if (-not $read) { $read = [pscustomobject]@{ status = 'transport_failed'; elapsedMs = 0 } }
        # Collection and dispatch must agree about what the observed subscription
        # can serve. A custom endpoint/provider is not a native subscription slot.
        if ($read.status -eq 'ok' -and (-not $read.standardTransport -or ($read.modelProvider -and $read.modelProvider -ne 'openai'))) { $read.status = 'unsupported_configuration' }
        $observed = [datetimeoffset]::UtcNow
        $buckets = $old.buckets; $lastSuccess = $old.lastSuccessAt; $identity = $old.identityKey
        if ($read.status -eq 'ok') {
            $priorBuckets = if ($identity -and $identity -eq $read.identityKey) { $old.buckets } else { $null }
            $buckets = ConvertTo-CodexBuckets $read.quota $priorBuckets $observed
            $lastSuccess = $observed.ToString('o'); $identity = $read.identityKey
        }
        $attempt = if ($read.status -in @('collection_budget','backoff')) { $old.lastAttemptAt } else { $observed.ToString('o') }
        $retry = if ($read.status -eq 'rate_limited') { $observed.AddMinutes(5).ToString('o') } elseif ($read.status -eq 'backoff') { $old.retryAfter } else { $null }
        $nextState[$id] = [pscustomobject]@{ binding = $binding; identityKey = $identity; lastAttemptAt = $attempt; lastSuccessAt = $lastSuccess; buckets = $buckets; retryAfter = $retry }
        $slots += [pscustomobject]@{ id = $id; label = $(if ($slot.label) { [string]$slot.label } else { $id }); status = [string]$read.status; observedAt = $lastSuccess; lastAttemptAt = $attempt; elapsedMs = $read.elapsedMs; buckets = $buckets; planType = $read.planType; defaultModel = [string]$read.model; modelProvider = [string]$read.modelProvider }
        # Status uses a separate local stream pseudonym, never the login-binding key.
        $slots[-1]|Add-Member NoteProperty streamKey (Get-Hotpl8Hash ($StateDirectory+'|usage|'+$identity)) -Force
    }
    # Two homes signed into the same subscription are not two capacity slots.
    $identities = @{}
    foreach ($slot in $slots) {
        $identity = $nextState.([string]$slot.id).identityKey
        if ($slot.status -eq 'ok' -and $identity) {
            if ($identities.ContainsKey($identity)) { $slot.status = 'duplicate_subscription'; $identities[$identity].status = 'duplicate_subscription' }
            else { $identities[$identity] = $slot }
        }
    }
    $hold = Get-Hold $StateDirectory
    $recommendations = [ordered]@{}
    $criticalStates=[ordered]@{}
    foreach ($meter in @('codex','codex_bengalfox')) {
        $priorId = $Previous.recommendations.$meter
        $recommendations[$meter] = Select-CodexSlot $slots $Policy $meter $priorId $hold ([datetimeoffset]::UtcNow) $Previous.critical.$meter
        $criticalAccounts=@(Get-Hotpl8CapacityAccounts ([pscustomobject]@{providers=@{codex=@{slots=$slots}}}) $Policy 'codex' $now $meter)
        $criticalStates[$meter]=Get-Hotpl8CriticalDecision $criticalAccounts $Policy $priorId $Previous.critical.$meter $now
        $criticalStates[$meter].selected=$recommendations[$meter]
        if($recommendations[$meter] -ne $Previous.recommendations.$meter){$criticalStates[$meter].selectedAt=$now.ToString('o')}
    }
    $default = if ($Policy.defaultMeter) { [string]$Policy.defaultMeter } else { 'codex' }
    $result = [pscustomobject]@{ status = 'observed'; observedAt = [datetimeoffset]::UtcNow.ToString('o'); defaultMeter = $default; recommendations = [pscustomobject]$recommendations; recommendedSlot = $recommendations[$default]; slots = @($slots); warm = 'unmeasured: automatic Codex warming unavailable'; hold = $(if ($hold) { @{ until = $hold.until.ToString('o'); reason = $hold.reason } } else { $null }); elapsedMs = $clock.ElapsedMilliseconds }
    $decisions=@(foreach($meter in @('codex','codex_bengalfox')){[pscustomobject]@{meter=$meter;selected=$recommendations[$meter];policy=$Policy.order;accounts=@(foreach($slot in $slots){[pscustomobject]@{slot=$slot.id;reason=(Get-CodexEligibility $slot $Policy $meter $now ([bool]$criticalStates[$meter].active));reserve=($slot.id -in @($Policy.reserve))}})}})
    $result|Add-Member NoteProperty critical ([pscustomobject]$criticalStates) -Force
    $result|Add-Member NoteProperty decisions $decisions -Force
    Write-Hotpl8Text $statePath (([pscustomobject]@{ schemaVersion = 1; slots = [pscustomobject]$nextState }) | ConvertTo-Json -Depth 24)
    # Quota-only history supports reset experiments and scheduled-soak auditing.
    # This runs under tick.lock; it never issues inference or stores native auth.
    try {
        $historyPath = Join-Path $StateDirectory 'codex-observations.jsonl'
        if ((Test-Path -LiteralPath $historyPath) -and (Get-Item -LiteralPath $historyPath).Length -gt 4194304) {
            $tail = @(Get-Content -LiteralPath $historyPath -Encoding UTF8 -Tail 256)
            while ($tail.Count -gt 1 -and [Text.Encoding]::UTF8.GetByteCount(($tail -join "`n")) -gt 2097152) { $tail = @($tail | Select-Object -Skip 1) }
            Write-Hotpl8Text $historyPath (($tail -join "`n") + "`n")
        }
        [IO.File]::AppendAllText($historyPath, (($result | ConvertTo-Json -Depth 24 -Compress) + "`n"), (New-Object Text.UTF8Encoding($false)))
    } catch { }
    return $result
}
function Format-CodexStatus($Codex, $Policy, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    $chosen = if ($Codex.recommendedSlot) { [string]$Codex.recommendedSlot } else { 'unavailable' }
    $criticalAccounts=@(Get-Hotpl8CapacityAccounts ([pscustomobject]@{providers=@{codex=$Codex}}) $Policy 'codex' $Now $Codex.defaultMeter)
    $critical=Get-Hotpl8CriticalDecision $criticalAccounts $Policy $chosen $Codex.critical.($Codex.defaultMeter) $Now
    $reasons = @{}
    foreach ($slot in @($Codex.slots)) {
        $reason = [string]$slot.status
        if ($reason -eq 'ok') {
            try {
                $age = ($Now - [datetimeoffset]::Parse($slot.observedAt)).TotalSeconds
                if ($age -lt -5 -or $age -gt 900) { $reason = 'stale' }
            } catch { $reason = 'unknown' }
            if ($reason -eq 'ok' -and $Policy) { $reason = Get-CodexEligibility $slot $Policy $Codex.defaultMeter $Now $critical.active }
        }
        $reasons[[string]$slot.id] = $reason
    }
    # A cached selection is a historical decision. Recheck admission at display
    # time without polling or rewriting the snapshot, including per-slot age.
    if (-not $reasons.ContainsKey($chosen) -or $reasons[$chosen] -notin @('ok','eligible')) { $chosen = 'unavailable' }
    'Codex: next launch = ' + $chosen + ' | ' + [string]$Codex.status + ' | observed ' + [string]$Codex.observedAt
    foreach ($slot in @($Codex.slots)) {
        '  ' + $slot.label + ' [' + $slot.id + '] ' + $reasons[[string]$slot.id] + ' | quota observed ' + $slot.observedAt
        foreach ($bucket in $slot.buckets.PSObject.Properties) {
            $parts = @()
            foreach ($window in $bucket.Value.windows.PSObject.Properties) {
                $w = $window.Value
                $reset = if ($null -ne $w.resetsAt) { [datetimeoffset]::FromUnixTimeSeconds([long]$w.resetsAt).ToLocalTime().ToString('MM-dd HH:mm zzz') } else { 'unknown' }
                $durationLabel = if ($window.Name -eq '300') { '5h' } else { '7d' }
                $parts += $durationLabel + ' ' + $w.remainingPercent + '% remaining; reset ' + $reset + ' (' + $w.anchorState + ')'
            }
            '    ' + $bucket.Name + ': ' + $bucket.Value.status + ' | ' + ($parts -join ' | ') + ' | warm: ' + $bucket.Value.warm
        }
    }
}
# Native launch decisions use cached quotas, followed by native login/config validation.
function Get-CodexLaunchPlan($Policy, $Status, [string]$SlotId, [string]$Model, [string[]]$Arguments, [datetimeoffset]$Now) {
    Assert-CodexPolicy $Policy
    foreach ($key in @('OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','CODEX_SQLITE_HOME','OPENAI_BASE_URL')) {
        if ([Environment]::GetEnvironmentVariable($key)) { throw ('Conflicting environment setting: ' + $key + '. Use native Codex directly for an explicitly different authentication mode.') }
    }
    foreach ($arg in @($Arguments)) {
        if ($arg -match '^(--config|--profile|--oss|--local-provider|--model|--cd|--remote|--remote-auth-token-env|--ignore-user-config)(=|$)' -or $arg -match '^-[cpmC]' -or $arg -in @('login','logout','app-server','mcp','mcp-server','app','agents','cloud','remote-control','exec-server','plugin','debug','sandbox','completion','doctor','features','update','apply','queue','archive','delete','unarchive','migrate-rollouts')) {
            throw 'Use HotPl8 -Model for model selection. Config/profile/auth/workdir overrides require native Codex directly; they cannot be verified against a subscription recommendation.'
        }
    }
    if (@($Arguments) -contains 'resume' -or @($Arguments) -contains 'fork') {
        if (-not $SlotId) { throw 'Resume/fork requires -Slot naming the home that owns the conversation.' }
    }
    $explicit = -not [string]::IsNullOrWhiteSpace($SlotId)
    $meter = $null
    if ($Model) {
        $meter = [string]$Policy.modelMeters.$Model
        if (-not $meter) { throw 'Model quota meter is not verified in codex.modelMeters.' }
    } else { $meter = if ($Policy.defaultMeter) { [string]$Policy.defaultMeter } else { 'codex' } }
    if (-not $explicit) {
        try { $age = ($Now - [datetimeoffset]::Parse($Status.observedAt)).TotalSeconds } catch { throw 'No current Codex status. Run hotpl8 refresh first or choose -Slot.' }
        if ($age -lt -5 -or $age -gt 900) { throw 'Codex status is stale. Refresh it or choose -Slot.' }
        $SlotId = [string]$Status.recommendations.$meter
        if (-not $SlotId) { throw 'No eligible subscription for this meter.' }
    }
    $matches = @($Policy.slots | Where-Object id -EQ $SlotId)
    if ($matches.Count -ne 1) { throw 'Unknown or duplicate Codex slot.' }
    $slot = $matches[0]
    if($slot.id -in @($Policy.disabled)){throw 'This Codex slot is disabled. Enable it before launch.'}
    $criticalAccounts=@(Get-Hotpl8CapacityAccounts ([pscustomobject]@{providers=@{codex=$Status}}) $Policy 'codex' $Now $meter)
    $critical=Get-Hotpl8CriticalDecision $criticalAccounts $Policy $SlotId $Status.critical.$meter $Now
    $observed = @($Status.slots | Where-Object id -EQ $SlotId | Select-Object -First 1)
    if (-not $explicit -and ($observed.Count -ne 1 -or (Get-CodexEligibility $observed[0] $Policy $meter $Now $critical.active) -ne 'eligible')) { throw 'Recommended slot is no longer eligible.' }
    if (-not $Model -and $observed.Count) { $Model = [string]$observed[0].defaultModel }
    if (-not $explicit -and (-not $Model -or [string]$Policy.modelMeters.$Model -ne $meter)) { throw 'Default model quota mapping is unverified. Configure codex.modelMeters or launch an explicit -Slot.' }
    return [pscustomobject]@{ policy = $Policy; slot = $slot; model = $Model; meter = $meter; automatic = (-not $explicit); emergency=[bool]$critical.active; arguments = @($Arguments) }
}
function Invoke-Hotpl8Codex($Plan, [string]$StateDirectory, [string]$Executable, [string]$WorkingDirectory) {
    $exe = Resolve-CodexExecutable $Executable
    $read = Read-CodexQuota $Plan.slot.home $exe 5000 $WorkingDirectory
    if ($read.status -ne 'ok') { throw ('Native subscription validation failed: ' + $read.status) }
    if (-not $read.standardTransport) { throw 'This home overrides the OpenAI endpoint. Subscription routing is unavailable for that configuration.' }
    if ($read.modelProvider -and $read.modelProvider -ne 'openai') { throw 'This home uses a custom model provider. Its billing cannot be represented as this subscription.' }
    if ($Plan.automatic) {
        $state = Read-Hotpl8Json (Join-Path $StateDirectory 'codex-state.json')
        $prior = $state.slots.([string]$Plan.slot.id)
        if (-not $prior -or $prior.identityKey -ne $read.identityKey -or $prior.binding -ne (Get-Hotpl8Hash ([IO.Path]::GetFullPath([string]$Plan.slot.home)))) { throw 'Account binding changed since collection. Refresh HotPl8 before automatic launch.' }
        $now = [datetimeoffset]::UtcNow
        $current = [pscustomobject]@{ id = $Plan.slot.id; status = 'ok'; observedAt = $now.ToString('o'); buckets = (ConvertTo-CodexBuckets $read.quota $null $now) }
        if ((Get-CodexEligibility $current $Plan.policy $Plan.meter $now ([bool]$Plan.emergency)) -ne 'eligible') { throw 'Quota changed before launch; the selected subscription is no longer eligible.' }
    }
    $arguments = @()
    if ($Plan.model) { $arguments += @('--model', [string]$Plan.model) }
    $arguments += @($Plan.arguments)
    $psi = New-CodexProcessInfo $exe $Plan.slot.home $arguments $WorkingDirectory
    $psi.EnvironmentVariables['HOTPL8_SLOT'] = [string]$Plan.slot.id
    $psi.EnvironmentVariables['HOTPL8_STATE_DIRECTORY'] = $StateDirectory
    $psi.EnvironmentVariables['HOTPL8_METER'] = [string]$Plan.meter
    $proc = $null
    try {
        # Inherited terminal handles; no cmd.exe or global environment mutation.
        $proc = [Diagnostics.Process]::Start($psi)
        $proc.WaitForExit()
        return $proc.ExitCode
    } finally { if ($proc) { $proc.Dispose() } }
}
