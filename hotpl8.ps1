# refresh observes; tick applies policy. Authentication belongs to native provider tools.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('watch', 'nyan', 'status', 'refresh', 'tick', 'codex', 'doctor', 'version', 'help', 'init', 'enroll', 'setup', 'add', 'explain', 'accounts', 'park', 'unpark', 'pause', 'resume', 'continue', 'capabilities', 'history', 'tray', 'update-check', 'update', 'agent', 'mcp', 'delivery', 'preview')]
    [string]$Command = 'watch',
    [string]$Slot,
    [string]$Model,
    [string]$StateDirectory,
    [string]$PreviewPolicy,
    [switch]$Live,
    [string]$TrustRevision,
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
    [switch]$AllowAgentOnboarding,
    [string]$OperationId,
    [ValidateSet('begin','status','choose_provider','choose_account','sign_in','install','retry','cancel','submit_code')][string]$OnboardingAction='begin',
    [string]$CandidateId,
    [switch]$NewAccount,
    [switch]$InstallDependencies,
    [switch]$DeviceCode,
    [switch]$Yes,
    [string]$SignInCode,
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$CodexArguments
)

$ErrorActionPreference = 'Stop'
try {
    # A plain version, status or explain request is answered by the compiled reader when this
    # release ships a matching one. These only read; refresh and tick never go there. Anything
    # else, including a reader that declines, continues below unchanged.
    # The Mac launcher adds its Codex binding to every request; none of the three reads it.
    $nativeAllowed=switch($Command){
        'version'{@('Command','AsJson','CodexExecutable')}
        {$_ -in 'status','explain'}{@('Command','AsJson','StateDirectory','PreviewPolicy','CodexExecutable')}
    }
    if($nativeAllowed -and -not @($PSBoundParameters.Keys|Where-Object{$_ -notin $nativeAllowed}).Count){
        # No Join-Path here: see the note on modules at the top of src/native.ps1.
        . ([IO.Path]::Combine($PSScriptRoot,'src','native.ps1'))
        $nativeArguments=@($Command,'--root',$PSScriptRoot)
        if($StateDirectory){$nativeArguments+=@('--state',$StateDirectory)}
        if($PreviewPolicy){$nativeArguments+=@('--policy',$PreviewPolicy)}
        if($AsJson){$nativeArguments+='-AsJson'}
        $nativeText=Invoke-Hotpl8Native $PSScriptRoot $nativeArguments
        # Text is one line per output object, as the PowerShell implementation writes it; JSON is one string.
        if($null -ne $nativeText){if($AsJson){$nativeText}else{$nativeText.Split("`n")};exit 0}
    }
    . (Join-Path $PSScriptRoot 'src/common.ps1')
    if(($Live -or $TrustRevision) -and $Command -ne 'preview'){throw 'Live and TrustRevision are preview-only.'}
    if($PreviewPolicy -and $Command -notin @('watch','nyan','status','explain')){throw 'PreviewPolicy is display-only.'}
    . (Join-Path $PSScriptRoot 'src/config.ps1')
    . (Join-Path $PSScriptRoot 'src/diagnostics.ps1')
    . (Join-Path $PSScriptRoot 'src/providers/claude.ps1')
    . (Join-Path $PSScriptRoot 'src/providers/codex.ps1')
    . (Join-Path $PSScriptRoot 'src/insights.ps1')
    . (Join-Path $PSScriptRoot 'src/management.ps1')
    . (Join-Path $PSScriptRoot 'src/onboarding.ps1')
    . (Join-Path $PSScriptRoot 'src/onboarding-install.ps1')
    $StateDirectory = Resolve-Hotpl8StateDirectory $StateDirectory $PSScriptRoot
    Initialize-Hotpl8OnboardingTools $StateDirectory

    if($Command -in @('agent','mcp')){
        . (Join-Path $PSScriptRoot 'src/agent-api.ps1')
        [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
        [Console]::InputEncoding=New-Object Text.UTF8Encoding($false)
        if($Command -eq 'mcp'){
            . (Join-Path $PSScriptRoot 'src/mcp.ps1')
            Start-Hotpl8Mcp $StateDirectory -AllowAgentPause:$AllowAgentPause -AllowAgentOnboarding:$AllowAgentOnboarding
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
        'hotpl8 [watch|setup|add|status|refresh|tick|doctor|version|init|enroll|codex]'
        'setup: connect your first account; add: connect another account. Native sign-in only when needed.'
        'setup/add -AsJson: durable agent onboarding. See docs/onboarding.md.'
        'watch: cached dashboard; Space freezes the view only.'
        'refresh: collect quotas without switching, warming, or recovery prompts.'
        'tick: collect and apply actions enabled by policy; monitor mode prevents actions.'
        'status -AsJson: local cached snapshot (may contain private labels).'
        'doctor -AsJson: redacted offline diagnostics; no login or quota calls.'
        'init: create the default policy if none exists: automatic switching and continue on, warming off.'
        'enroll -Slot main -AccountHome PATH: enroll an already signed-in native Codex home.'
        'codex [-Slot ID] [-Model ID] [native arguments]; resume requires -Slot.'
        'All commands accept -StateDirectory PATH. See docs/usage.md.'
        'setup [-Interactive]: guided enrollment for either provider.'
        'accounts -Provider REGISTERED_ID [-Slot ID -Operation rename|enable|disable|reserve|work -Label NAME]'
        'park [-Yes]: set aside accounts that lost their plan or have been unreadable for a week; asks once.'
        'park -Provider ID -Slot SLOT: set one account aside. unpark [-Provider ID -Slot SLOT]: bring one back with its settings.'
        'explain [-AsJson]: recorded selection reasons. capabilities [-AsJson]: offline readiness.'
        'pause [-Minutes 60] / resume: persistent automation pause; collection continues.'
        'continue [-Operation enable|disable]: automatic continue after a usage limit; shows whether it is on.'
        'history [-Operation clear]: inspect retention or delete local usage history.'
        'tray [-Once]: optional Windows tray; -Once prints its view model without opening a window.'
        'update-check [-Channel preview] [-Operation dismiss] / update -InstallDirectory PATH'
        'agent [-RequestJson JSON]: versioned local agent request; stdin JSON is also accepted.'
        'delivery: installed, desired and previous commit; update: follow tested main when enrolled.'
        'preview pr NUMBER: download CI images. Add -Live -TrustRevision FULL_SHA to execute that reviewed PR dashboard with demo accounts.'
        'mcp [-AllowAgentPause]: local stdio MCP; read tools only unless pause writes are enabled.'
        exit 0
    }
    if($Command -in @('setup','add')){
        $chosenProvider=if($PSBoundParameters.ContainsKey('Provider')){$Provider}else{''}
        if($AsJson){
            Invoke-Hotpl8Onboarding $StateDirectory $OnboardingAction $OperationId $chosenProvider $CandidateId -NewAccount:($NewAccount -or $Command -eq 'add') -AllowInstall:$InstallDependencies -DeviceCode:$DeviceCode -Code $SignInCode|ConvertTo-Json -Depth 16
        }elseif($Interactive -or -not [Console]::IsInputRedirected){
            . (Join-Path $PSScriptRoot 'src/onboarding-ui.ps1')
            Show-Hotpl8Onboarding $StateDirectory $chosenProvider -NewAccount:($NewAccount -or $Command -eq 'add') -AllowInstall:$InstallDependencies
        }else{
            'Use hotpl8 setup -Interactive for guided enrollment, or setup -AsJson for an agent.'
            'No account paths or slot numbers are needed. See docs/onboarding.md.'
        }
        exit 0
    }
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
            if($Live -or $TrustRevision){
                if(-not $Live -or $TrustRevision -cnotmatch '^[0-9a-f]{40}$'){throw 'Live preview requires -Live -TrustRevision FULL_SHA. This executes trusted PR code locally.'}
                $forward+=@('--trust-revision',$TrustRevision)
            }
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
        'Created the default policy: automatic switching and continue on, warming off. Next: hotpl8 setup'
        'HotPl8 connects your native account and reads usage automatically.'
        exit 0
    }
    if ($Command -eq 'doctor') {
        $report = Get-Hotpl8Doctor $StateDirectory
        if ($AsJson) { $report | ConvertTo-Json -Depth 5 }
        else {
            $doctorPolicy=Read-Hotpl8Json (Join-Path $StateDirectory 'policy.json')
            $parkAdvice=@();if($report.policyValid){try{$parkAdvice=@(Get-Hotpl8ParkCandidates (Read-Hotpl8Json (Join-Path $StateDirectory 'status.json')) $doctorPolicy)}catch{}}
            Format-Hotpl8Doctor $report $parkAdvice | ForEach-Object {ConvertTo-Hotpl8SafeText $_}
        }
        # Preserve the JSON/exit contract; human output describes readiness separately.
        if (-not $report.policyValid) { exit 1 }
        exit 0
    }

    $policy = Read-Hotpl8Json $(if($PreviewPolicy){$PreviewPolicy}else{Join-Path $StateDirectory 'policy.json'})
    if (-not $policy -and $Command -eq 'watch' -and -not [Console]::IsInputRedirected) {
        . (Join-Path $PSScriptRoot 'src/onboarding-ui.ps1')
        Show-Hotpl8Onboarding $StateDirectory '';exit 0
    }
    if (-not $policy) { throw 'No valid policy.json. Run hotpl8 setup or see docs/install.md.' }
    Assert-Hotpl8Policy $policy
    if($Command -in @('pause','resume')){
        $duration=if($Command -eq 'resume'){0}else{$Minutes}
        Set-Hotpl8Pause $StateDirectory $duration $Command
        if($duration){'Automation paused for '+$duration+' minutes. Collection continues.'}
        elseif(Get-Hotpl8Pause $StateDirectory){'Manual pause cleared. Agent pauses or invalid pause state still block automation.'}
        else{'Automation resumed under the existing policy.'}
        exit 0
    }
    if($Command -eq 'continue'){
        if($Operation -notin @('list','enable','disable')){throw 'Continue supports list, enable or disable.'}
        . (Join-Path $PSScriptRoot 'src/lifecycle.ps1')
        if($Operation -ne 'list'){
            $path=Join-Path $StateDirectory 'policy.json';$hash=(Get-FileHash $path -Algorithm SHA256).Hash
            # Read after hashing so concurrent edits are rejected when committing.
            $policy=Read-Hotpl8Json $path
            if(($Operation -eq 'disable') -ne ($policy.automation.continue -eq $false)){
                $policy=ConvertTo-Hotpl8PolicyV2 $policy
                if($Operation -eq 'enable'){$policy.automation.PSObject.Properties.Remove('continue')}
                else{
                    if(-not $policy.automation){$policy|Add-Member NoteProperty automation ([pscustomobject]@{}) -Force}
                    $policy.automation|Add-Member NoteProperty continue $false -Force
                }
                Save-Hotpl8Policy $StateDirectory $policy $hash
            }
        }
        $on=(Get-Hotpl8Actions $policy $false).continuing
        if($Operation -ne 'list'){
            # Asked for explicitly, so a copy that is not an installation gets its hook too.
            $hookLock=[IO.File]::Open((Join-Path $StateDirectory 'tick.lock'),'OpenOrCreate','ReadWrite','None')
            try{Set-Hotpl8ContinueHook $PSScriptRoot $StateDirectory -Explicit -Remove:(-not $on)}finally{$hookLock.Dispose()}
        }
        'Automatic continue: '+$(if($on){'on'}elseif($policy.mode -eq 'monitor'){'off (monitor mode turns every action off)'}else{'off (automation.continue is false)'})
        'Claude hook: '+$(if(Test-Hotpl8ContinueHook $StateDirectory){'present'}else{'absent'})
        exit 0
    }
    if($Command -eq 'accounts'){
        if($Operation -eq 'list'){
            $rows=@(Get-Hotpl8ProviderAccounts $policy)
            # Parked accounts are absent everywhere else; this list keeps them findable.
            $rows+=@(Read-Hotpl8Parked $StateDirectory|ForEach-Object {[pscustomobject]@{provider=$_.provider;slot=$_.slot;label=$_.label;capacity=$_.capacity;disabled=[bool]$_.disabled;reserve=[bool]$_.reserve;parked=$true;reason=$_.reason;parkedAt=$_.parkedAt}})
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
    if($Command -in @('park','unpark') -and ($CodexArguments -or $Model)){throw 'park and unpark accept -Provider, -Slot, -Yes and -AsJson.'}
    if($Command -eq 'park'){
        $status=Read-Hotpl8Snapshot $StateDirectory
        if($Slot){
            $owner=if($PSBoundParameters.ContainsKey('Provider')){$Provider}else{Resolve-Hotpl8ParkProvider @(Get-Hotpl8ProviderAccounts $policy) $Slot}
            Format-Hotpl8Parked @(Invoke-Hotpl8Park $StateDirectory $owner $Slot 'manual' $null $status)|ForEach-Object {ConvertTo-Hotpl8SafeText $_}
            exit 0
        }
        if(-not $status -or -not (Test-Hotpl8FreshTimestamp $status.generatedAt)){
            if($AsJson){[pscustomobject]@{stale=$true;candidates=@()}|ConvertTo-Json -Depth 6;exit 0}
            'Readings are stale, so HotPl8 cannot tell which accounts are gone. Run hotpl8 refresh, then hotpl8 park.'
            'To set one account aside anyway: hotpl8 park -Provider ID -Slot SLOT'
            exit 0
        }
        $candidates=@($status.parkCandidates|Where-Object {$_})
        if($AsJson){[pscustomobject]@{stale=$false;candidates=@($candidates|Select-Object provider,slot,label,reason,days,lastReadingAt,planType)}|ConvertTo-Json -Depth 6;exit 0}
        if(-not $candidates.Count){'Nothing to park. Every enrolled account is readable, or has been unreadable for less than a week.';exit 0}
        Format-Hotpl8ParkCandidates $candidates|ForEach-Object {ConvertTo-Hotpl8SafeText $_}
        $one=($candidates.Count -eq 1)
        if(-not $Yes){
            if([Console]::IsInputRedirected){'No changes made. To park '+$(if($one){'it'}else{'them'})+': hotpl8 park -Yes';exit 0}
            $question='Park '+$candidates.Count+' account'+$(if(-not $one){'s'})+'? '+$(if($one){'It disappears from HotPl8 until you unpark it.'}else{'They disappear from HotPl8 until you unpark them.'})+' [Y/n]'
            if(-not (Read-Hotpl8ParkAnswer $question $true)){'No changes made.';exit 0}
        }
        $parkedNow=@(foreach($candidate in $candidates){Invoke-Hotpl8Park $StateDirectory $candidate.provider $candidate.slot $candidate.reason $candidate.lastReadingAt $status})
        Format-Hotpl8Parked $parkedNow|ForEach-Object {ConvertTo-Hotpl8SafeText $_}
        exit 0
    }
    if($Command -eq 'unpark'){
        $parked=@(Read-Hotpl8Parked $StateDirectory -Strict)
        if($AsJson -and -not $Slot){ConvertTo-Json -InputObject @($parked|Select-Object provider,slot,label,reason,parkedAt,lastReadingAt) -Depth 6;exit 0}
        if(-not $parked.Count){'No parked accounts.';exit 0}
        $choice=$null
        if($Slot){
            $matching=@($parked|Where-Object {$_.slot -ceq $Slot -and (-not $PSBoundParameters.ContainsKey('Provider') -or $_.provider -ceq $Provider)})
            if($matching.Count -ne 1){throw 'No single parked account matches. Run hotpl8 unpark to list them, then add -Provider.'}
            $choice=$matching[0]
        }else{
            for($i=0;$i -lt $parked.Count;$i++){
                $since='';try{$since=' since '+[datetimeoffset]::Parse([string]$parked[$i].parkedAt).ToLocalTime().ToString('MMM d',[Globalization.CultureInfo]::InvariantCulture)}catch{}
                $why=switch([string]$parked[$i].reason){'dormant'{'it stopped reading'}'canceled'{'its plan ended'}default{'set aside by hand'}}
                ConvertTo-Hotpl8SafeText ('  '+($i+1)+'. '+(Get-Hotpl8ParkName $parked[$i])+'    parked'+$since+', '+$why)
            }
            if($parked.Count -gt 1 -and ($Yes -or [Console]::IsInputRedirected)){'No changes made. Choose one: hotpl8 unpark -Provider ID -Slot SLOT';exit 0}
            if(-not $Yes -and [Console]::IsInputRedirected){'No changes made. To restore it: hotpl8 unpark -Yes';exit 0}
            if($parked.Count -eq 1){
                if($Yes -or (Read-Hotpl8ParkAnswer ('Unpark '+(ConvertTo-Hotpl8SafeText (Get-Hotpl8ParkName $parked[0]))+'? [Y/n]') $true)){$choice=$parked[0]}
            }else{
                [Console]::Out.Write('Which one? [1-'+$parked.Count+', blank cancels] ')
                $picked=0;if([int]::TryParse(([string][Console]::In.ReadLine()).Trim(),[ref]$picked) -and $picked -ge 1 -and $picked -le $parked.Count){$choice=$parked[$picked-1]}
            }
            if(-not $choice){'No changes made.';exit 0}
        }
        $name=ConvertTo-Hotpl8SafeText (Get-Hotpl8ParkName $choice)
        $result=Invoke-Hotpl8Unpark $StateDirectory $choice.provider $choice.slot $CodexExecutable
        if($result.needsSignIn){
            $name+' still needs sign-in, so it would come back unreadable.'
            'Sign in first: hotpl8 add -Provider '+$choice.provider
            if($Yes -or [Console]::IsInputRedirected -or -not (Read-Hotpl8ParkAnswer 'Unpark anyway? [y/N]' $false)){'It stays parked.';exit 0}
            $result=Invoke-Hotpl8Unpark $StateDirectory $choice.provider $choice.slot $CodexExecutable -Force
        }
        $result.messages|ForEach-Object {ConvertTo-Hotpl8SafeText ([string]$_)}
        if($result.enrolled){'Unparked '+$name+'. The next refresh reads it again.'}else{$name+' is still parked.'}
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
        Add-Hotpl8RegisteredAccount $StateDirectory $Provider $Slot $AccountHome $Label $CodexExecutable -MigratePolicy:$MigratePolicy -KeepLabel:([bool]$Label)
        'Next: hotpl8 refresh, then hotpl8 to open the dashboard.'
        exit 0
    }
    if ($AccountHome -or $Label) { throw '-AccountHome and -Label are enrollment options. Use hotpl8 enroll.' }

    if ($Command -in @('watch','nyan')) {
        if(-not @(Get-Hotpl8ProviderAccounts $policy).Count -and @(Read-Hotpl8Parked $StateDirectory).Count){
            # Guided setup is for a first account; these already exist.
            'Every account is parked. Bring one back with hotpl8 unpark, or connect another with hotpl8 add.'
            exit 0
        }
        if(-not @(Get-Hotpl8ProviderAccounts $policy).Count -and -not [Console]::IsInputRedirected){
            . (Join-Path $PSScriptRoot 'src/onboarding-ui.ps1')
            Show-Hotpl8Onboarding $StateDirectory '';exit 0
        }
        # Nyan is a presentation flag on the installed dashboard. Keep both
        # modes here so every application update reaches both views together.
        . (Join-Path $PSScriptRoot 'src/dashboard.ps1')
        Show-Hotpl8Dashboard $StateDirectory -Nyan:($Command -eq 'nyan') -ReducedMotion:$ReducedMotion -NoColor:$NoColor -PolicyOverride $(if($PreviewPolicy){$policy})
        exit 0
    }
    if ($Command -in @('refresh', 'tick')) {
        if (-not @(Get-Hotpl8ProviderAccounts $policy).Count) {
            if(@(Read-Hotpl8Parked $StateDirectory).Count){throw 'Every account is parked. Run hotpl8 unpark to bring one back, or hotpl8 add to connect another.'}
            throw 'No accounts enrolled. Run hotpl8 setup to connect your first account.'
        }
        & (Join-Path $PSScriptRoot 'tick.ps1') -StateDirectory $StateDirectory -CodexExecutable $CodexExecutable -ObserveOnly:($Command -eq 'refresh') -Strict
        if ($LASTEXITCODE -ne 0) {
            throw 'Collection incomplete. Run hotpl8 doctor; inspect local events.jsonl. Old data is not a fresh result.'
        }
        $Command = 'status'
    }

    # One clock reading per request: every line of an answer describes the same instant.
    $now=[datetimeoffset]::UtcNow
    $status = Read-Hotpl8Snapshot $StateDirectory $(if($PreviewPolicy){$policy}) -SkipDisplay:($Command -eq 'codex') -Now $now
    if($Command -eq 'explain'){
        if($status){$status|Add-Member NoteProperty automationPause (Get-Hotpl8Pause $StateDirectory $now) -Force}
        if($AsJson){[pscustomobject]@{generatedAt=$status.generatedAt;claude=$status.decision;codex=$status.providers.codex.decisions;pause=$status.automationPause;providerOverview=$status.providerOverview}|ConvertTo-Json -Depth 16}
        else{Format-Hotpl8Explanation $status $now|ForEach-Object {ConvertTo-Hotpl8SafeText $_}}
        exit 0
    }
    if ($Command -eq 'status') {
        if (-not $status -or -not $status.generatedAt) { 'No cached status. Run hotpl8 refresh.'; exit 0 }
        if ($AsJson) { $status | ConvertTo-Json -Depth 24; exit 0 }
        Format-Hotpl8Status $status $policy $StateDirectory $now
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
