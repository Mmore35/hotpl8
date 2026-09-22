# refresh observes; tick applies policy. Authentication belongs to native provider tools.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('watch', 'nyan', 'status', 'refresh', 'tick', 'codex', 'doctor', 'version', 'help', 'init', 'enroll', 'setup', 'explain', 'accounts', 'pause', 'resume', 'capabilities', 'history', 'tray', 'update-check', 'update', 'agent', 'mcp', 'delivery', 'preview')]
    [string]$Command = 'watch',
    [string]$Slot,
    [string]$Model,
    [string]$StateDirectory,
    [string]$PreviewPolicy,
    [string]$CodexExecutable,
    [switch]$AsJson,
    [string]$AccountHome,
    [string]$Label,
    [string]$CapacityProfile,
    [Nullable[double]]$WeeklyCapacity,
    [Nullable[double]]$FiveHourCapacity,
    [switch]$ReducedMotion,
    [switch]$NoColor,
    [string]$Provider = 'codex',
    [switch]$MigratePolicy,
    [ValidateSet('list','rename','enable','disable','reserve','work','capacity','remove','clear','dismiss')][string]$Operation = 'list',
    [ValidateRange(1,10080)][int]$Minutes = 60,
    [switch]$Interactive,
    [switch]$Once,
    [ValidateSet('stable','preview')][string]$Channel = 'stable',
    [string]$ReleaseVersion,
    [string]$InstallDirectory,
    [string]$SourceDigest,
    [string]$RequestJson,
    [switch]$AllowAgentPause,
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$CodexArguments
)

$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot 'src/common.ps1')
    if($PreviewPolicy -and $Command -notin @('watch','nyan','status','explain')){throw 'PreviewPolicy is display-only.'}
    . (Join-Path $PSScriptRoot 'src/config.ps1')
    . (Join-Path $PSScriptRoot 'src/diagnostics.ps1')
    . (Join-Path $PSScriptRoot 'src/providers/claude.ps1')
    . (Join-Path $PSScriptRoot 'src/providers/codex.ps1')
    . (Join-Path $PSScriptRoot 'src/insights.ps1')
    . (Join-Path $PSScriptRoot 'src/management.ps1')
    $StateDirectory = Resolve-Hotpl8StateDirectory $StateDirectory $PSScriptRoot

    if($Command -in @('agent','mcp')){
        . (Join-Path $PSScriptRoot 'src/agent-api.ps1')
        [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
        [Console]::InputEncoding=New-Object Text.UTF8Encoding($false)
        if($Command -eq 'mcp'){
            . (Join-Path $PSScriptRoot 'src/mcp.ps1')
            Start-Hotpl8Mcp $StateDirectory -AllowAgentPause:$AllowAgentPause
            exit 0
        }
        if(-not $PSBoundParameters.ContainsKey('RequestJson')){
            # Bound memory before parsing. UTF-8 byte size is checked by the shared handler.
            $buffer=New-Object Text.StringBuilder
            while($buffer.Length -le 65536){$character=[Console]::In.Read();if($character -lt 0){break};[void]$buffer.Append([char]$character)}
            $RequestJson=$buffer.ToString()
        }
        $response=Invoke-Hotpl8AgentJson $RequestJson $StateDirectory
        [Console]::WriteLine(($response|ConvertTo-Json -Depth 24 -Compress))
        if($response.ok){exit 0}else{exit 1}
    }

    # These commands do not need an existing policy or a provider observation.
    if ($Command -eq 'version') {
        $version=(Get-Content (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
        $build=Read-Hotpl8Json (Join-Path $PSScriptRoot 'build-info.json')
        if($AsJson){[pscustomobject]@{version=$version;build=$build}|ConvertTo-Json -Depth 4}
        elseif($build.sha){$version+' main '+$build.sha.Substring(0,12)}else{$version}
        exit 0
    }
    if ($Command -eq 'help') {
        'nyan: dashboard with animated Nyan Cat; -ReducedMotion / -NoColor supported.'
        'accounts -Operation capacity -Provider claude -Slot 1 -CapacityProfile claude-pro -WeeklyCapacity 1 -FiveHourCapacity 0.1 (supply calibrated values). '
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
        'setup [-Interactive]: guided, monitoring-first enrollment for either provider.'
        'accounts -Provider REGISTERED_ID [-Slot ID -Operation rename|enable|disable|reserve|work -Label NAME]'
        'explain [-AsJson]: recorded selection reasons. capabilities [-AsJson]: offline readiness.'
        'pause [-Minutes 60] / resume: persistent automation pause; collection continues.'
        'history [-Operation clear]: inspect retention or delete local usage history.'
        'tray [-Once]: optional Windows tray; -Once prints its view model without opening a window.'
        'update-check [-Channel preview] [-Operation dismiss] / update -InstallDirectory PATH'
        'agent [-RequestJson JSON]: versioned local agent request; stdin JSON is also accepted.'
        'delivery: installed, desired and previous commit; update: follow tested main when enrolled.'
        'preview pr NUMBER: download inert CI dashboard images for an exact PR revision.'
        'mcp [-AllowAgentPause]: local stdio MCP; read tools only unless pause writes are enabled.'
        exit 0
    }
    if($Command -eq 'setup'){Invoke-Hotpl8Setup $StateDirectory $PSScriptRoot -Interactive:$Interactive;exit 0}
    if($Command -eq 'capabilities'){
        $report=Get-Hotpl8Capabilities $StateDirectory
        if($AsJson){$report|ConvertTo-Json -Depth 8}else{$report|ConvertTo-Json -Depth 8}
        exit 0
    }
    if($Command -in @('delivery','preview') -or ($Command -eq 'update' -and $env:HOTPL8_INSTALL_DIRECTORY)){
        $managed=if($InstallDirectory){$InstallDirectory}else{$env:HOTPL8_INSTALL_DIRECTORY}
        if(-not $managed){throw 'This command requires a Local Delivery installation. See docs/delivery.md.'}
        $registration=Read-Hotpl8Json (Join-Path $managed 'delivery.json')
        $runner=Join-Path $managed 'delivery.py'
        $verb=if($Command -eq 'delivery'){'status'}else{$Command}
        $forward=@($runner,$verb)
        if($Command -eq 'preview'){
            if($CodexArguments.Count -ne 2 -or $CodexArguments[0] -ne 'pr' -or $CodexArguments[1] -notmatch '^[1-9][0-9]*$'){throw 'Use hotpl8 preview pr NUMBER.'}
            $forward+=@($CodexArguments[1])
        }
        & $registration.python @forward
        exit $LASTEXITCODE
    }
    if($Command -in @('update-check','update')){
        . (Join-Path $PSScriptRoot 'src/updates.ps1')
        $release=Get-Hotpl8Release $Channel $ReleaseVersion
        if(-not $release){'No release available in this channel.';exit 0}
        if($Command -eq 'update-check'){
            $current=(Get-Content (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
            $release|Add-Member NoteProperty currentVersion $current
            $release|Add-Member NoteProperty newer (Test-Hotpl8NewerVersion $release.version $current)
            $path=Join-Path $StateDirectory 'update-state.json'
            if($Operation -eq 'dismiss'){
                [void][IO.Directory]::CreateDirectory($StateDirectory)
                Write-Hotpl8Text $path (@{dismissedTag=$release.tag}|ConvertTo-Json)
            }
            $release|Add-Member NoteProperty dismissed ((Read-Hotpl8Json $path).dismissedTag -eq $release.tag)
            $release|ConvertTo-Json -Depth 5;exit 0
        }
        Install-Hotpl8Update $release $InstallDirectory $SourceDigest
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

    $policy = Read-Hotpl8Json $(if($PreviewPolicy){$PreviewPolicy}else{Join-Path $StateDirectory 'policy.json'})
    if (-not $policy) { throw 'No valid policy.json. Run hotpl8 init or see docs/install.md.' }
    Assert-Hotpl8Policy $policy
    if($Command -in @('pause','resume')){
        $duration=if($Command -eq 'resume'){0}else{$Minutes}
        Set-Hotpl8Pause $StateDirectory $duration $Command
        if($duration){'Automation paused for '+$duration+' minutes. Collection continues.'}
        elseif(Get-Hotpl8Pause $StateDirectory){'Manual pause cleared. Agent pauses or invalid pause state still block automation.'}
        else{'Automation resumed under the existing policy.'}
        exit 0
    }
    if($Command -eq 'accounts'){
        if($Operation -eq 'list'){
            $rows=@(Get-Hotpl8ProviderAccounts $policy)
            if($AsJson){ConvertTo-Json -InputObject $rows -Depth 6}else{$rows}
        }else{
            if(-not $Slot -or $Operation -notin @('rename','enable','disable','reserve','work','capacity','remove') -or ($Operation -eq 'rename' -and -not $Label)){throw 'Account changes require -Slot and a supported operation; rename also requires -Label.'}
            $path=Join-Path $StateDirectory 'policy.json';$hash=(Get-FileHash $path -Algorithm SHA256).Hash
            # Read after hashing so concurrent edits are rejected when committing.
            $policy=Read-Hotpl8Json $path
            $next=if($Operation -eq 'capacity'){Set-Hotpl8CapacityProfile $policy $Provider $Slot $CapacityProfile $WeeklyCapacity $FiveHourCapacity}else{Set-Hotpl8Account $policy $Provider $Slot $Operation $Label}
            Save-Hotpl8Policy $StateDirectory $next $hash
            'Account policy updated. The next refresh updates cached decisions.'
        }
        exit 0
    }
    if($Command -eq 'history'){
        if($Operation -notin @('list','clear')){throw 'History supports list or clear.'}
        if($Operation -eq 'clear'){
            $historyLock=$null
            try{
                $historyLock=[IO.File]::Open((Join-Path $StateDirectory 'tick.lock'),'OpenOrCreate','ReadWrite','None')
                $currentPolicy=Read-Hotpl8Json (Join-Path $StateDirectory 'policy.json');Assert-Hotpl8Policy $currentPolicy
                foreach($store in @(Get-Hotpl8HistoryStores $currentPolicy $StateDirectory)){
                    $historyPath=Join-Path $store.directory 'usage-history.json'
                    if(Test-Path -LiteralPath $historyPath){Write-Hotpl8Text $historyPath '{"schemaVersion":1,"samples":[]}'}
                }
            }finally{if($historyLock){$historyLock.Dispose()}}
            'Usage history cleared for configured provider stores. Set historyEnabled to false to stop recording. Unregistered provider history is retained.'
        }else{
            $stores=@(Get-Hotpl8HistoryStores $policy $StateDirectory);$total=0;foreach($store in $stores){$total+=$store.samples}
            [pscustomobject]@{enabled=($policy.historyEnabled -eq $true);samples=$total;retentionDays=14;maximumSamples=(4096*$stores.Count);maximumSamplesPerStore=4096;stores=@($stores|Select-Object providers,samples)}|ConvertTo-Json -Depth 5
        }
        exit 0
    }
    if($Command -eq 'tray'){
        . (Join-Path $PSScriptRoot 'src/tray.ps1')
        if($Once){Show-Hotpl8Tray $StateDirectory $PSScriptRoot -Once|ConvertTo-Json -Depth 8}else{Show-Hotpl8Tray $StateDirectory $PSScriptRoot}
        exit 0
    }

    if ($Command -eq 'enroll') {
        if(-not $Slot -or $CodexArguments -or $Model -or $AsJson){throw 'Enrollment requires -Slot, driver-specific -AccountHome, and optional -Label.'}
        $enrollmentDriver=Get-Hotpl8ProviderDriver (Get-Hotpl8ProviderDefinition $Provider).driver
        if($enrollmentDriver.slotKind -eq 'native-home' -and -not $AccountHome){throw 'Enrollment requires -Slot ID -AccountHome PATH for an existing native account home.'}
        Add-Hotpl8RegisteredAccount $StateDirectory $Provider $Slot $AccountHome $Label $CodexExecutable -MigratePolicy:$MigratePolicy
        'Next: hotpl8 refresh, then hotpl8 to open the dashboard.'
        exit 0
    }
    if ($AccountHome -or $Label) { throw '-AccountHome and -Label are enrollment options. Use hotpl8 enroll.' }

    if ($Command -in @('watch','nyan')) {
        # Nyan is a presentation flag on the installed dashboard. Keep both
        # modes here so every application update reaches both views together.
        . (Join-Path $PSScriptRoot 'src/dashboard.ps1')
        Show-Hotpl8Dashboard $StateDirectory -Nyan:($Command -eq 'nyan') -ReducedMotion:$ReducedMotion -NoColor:$NoColor -PolicyOverride $(if($PreviewPolicy){$policy})
        exit 0
    }
    if ($Command -in @('refresh', 'tick')) {
        if (-not @(Get-Hotpl8ProviderAccounts $policy).Count) {
            throw 'No accounts enrolled. Run hotpl8 enroll -Slot main -AccountHome PATH; Claude setup is in docs/install.md.'
        }
        & (Join-Path $PSScriptRoot 'tick.ps1') -StateDirectory $StateDirectory -CodexExecutable $CodexExecutable -ObserveOnly:($Command -eq 'refresh') -Strict
        if ($LASTEXITCODE -ne 0) {
            throw 'Collection incomplete. Run hotpl8 doctor; inspect local events.jsonl. Old data is not a fresh result.'
        }
        $Command = 'status'
    }

    $status = Read-Hotpl8Snapshot $StateDirectory $(if($PreviewPolicy){$policy})
    if($Command -eq 'explain'){
        if($status){$status|Add-Member NoteProperty automationPause (Get-Hotpl8Pause $StateDirectory) -Force}
        if($AsJson){[pscustomobject]@{generatedAt=$status.generatedAt;claude=$status.decision;codex=$status.providers.codex.decisions;pause=$status.automationPause;providerOverview=$status.providerOverview}|ConvertTo-Json -Depth 16}
        else{Format-Hotpl8Explanation $status|ForEach-Object {ConvertTo-Hotpl8SafeText $_}}
        exit 0
    }
    if ($Command -eq 'status') {
        if (-not $status -or -not $status.generatedAt) { 'No cached status. Run hotpl8 refresh.'; exit 0 }
        if ($AsJson) { $status | ConvertTo-Json -Depth 24; exit 0 }
        Format-Hotpl8Overview $status.providerOverview | ForEach-Object {ConvertTo-Hotpl8SafeText $_}
        'HotPl8 | generated ' + (ConvertTo-Hotpl8SafeText $status.generatedAt)
        if($status.collector){Get-Hotpl8Health $status.collector}
        $pause=Get-Hotpl8Pause $StateDirectory
        if($pause){'AUTOMATION PAUSED: '+(ConvertTo-Hotpl8SafeText $pause.reason)}
        $age = ([datetimeoffset]::UtcNow - [datetimeoffset]::Parse($status.generatedAt)).TotalSeconds
        if ($age -gt 900 -or $age -lt -5) { 'STALE: refresh before relying on these readings.' }
        foreach($registration in @(Get-Hotpl8ConfiguredProviders $policy)){
            $view=Get-Hotpl8ProviderView $status $policy $registration.id
            if($view.provider -eq 'claude'){
                ConvertTo-Hotpl8SafeText ($registration.name+': active slot '+$view.snapshot.active+' | '+$view.snapshot.verdict)
                foreach($account in @($view.snapshot.slots)){
                    $fiveHour=if($null -eq $account.used5h){'unknown'}else{[string](100-$account.used5h)+'% remaining'}
                    $weekly=if($null -eq $account.used7d){'unknown'}else{[string](100-$account.used7d)+'% remaining'}
                    ConvertTo-Hotpl8SafeText ('  '+$account.label+' ['+$account.slot+'] 5h '+$fiveHour+' | 7d '+$weekly+' | '+$account.status)
                    if($account.warmOutcome){'    warm: '+$account.warmOutcome.outcome}
                    if((Test-Hotpl8FreshTimestamp $account.observedAt) -and $account.forecast){'    '+(Format-Hotpl8Forecast $account.forecast)}
                }
            }elseif($view.snapshot.providers.codex){
                Format-CodexStatus $view.snapshot.providers.codex $view.policy.codex|ForEach-Object {ConvertTo-Hotpl8SafeText ($_ -replace '^Codex', $registration.name)}
            }else{$registration.name+': not configured or no observation yet.'}
        }
        exit 0
    }

    $launchControls=Get-Hotpl8ControlSnapshot $StateDirectory
    $policy=$launchControls.policy;Assert-Hotpl8Policy $policy
    $view=Get-Hotpl8ProviderView $status $policy $Provider
    if(-not $view.registration.definition.capabilities.nativeLaunch -or $view.provider -ne 'codex'){throw 'Native launch is not supported by this registered driver.'}
    if(-not $view.policy.codex.slots){throw 'No native account homes configured.'}
    $context=Get-Hotpl8ProviderActionContext $policy $StateDirectory ([pscustomobject]@{intent='admit';bindingKnown=$false})
    $plan=Get-CodexLaunchPlan $view.policy.codex $view.snapshot.providers.codex $Slot $Model $CodexArguments ([datetimeoffset]::UtcNow) $context
    $launchState=Get-Hotpl8ProviderStateDirectory $StateDirectory $Provider
    exit (Invoke-Hotpl8Codex $plan $launchState $CodexExecutable (Get-Location).Path -ControlDirectory $StateDirectory -ProviderId $Provider)
} catch {
    [Console]::Error.WriteLine('HotPl8: ' + (ConvertTo-Hotpl8SafeText $_.Exception.Message))
    exit 1
}
