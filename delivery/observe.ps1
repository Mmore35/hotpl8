# Watch a candidate's compiled reader over simulated time beside its baseline's, and judge
# the scenario the agent wrote from the PR's claim. Offline, fictional state, no accounts.
# live_preview.py puts the candidate's reader at its release path under the source, as for
# the live preview, and finds the baseline release. Nothing but the two readers is started.
# The scenario format, the verdict rule and the exit codes are docs/observe-scenarios.md.
# Exit: 0 PASS, 10 FAIL, 1 the observation could not be made (an invalid scenario).
param([Parameter(Mandatory=$true)][string]$Candidate,
      [Parameter(Mandatory=$true)][string]$Baseline,
      [Parameter(Mandatory=$true)][string]$Scenario,
      [Parameter(Mandatory=$true)][string]$Report,
      [string]$CandidateSha = '',
      [string]$BaselineSha = '',
      [int]$Pr = 0)
$ErrorActionPreference = 'Stop'
# PowerShell names are not case-sensitive: $Report is the folder; the report itself is $summary.
$candidateRoot = [IO.Path]::GetFullPath($Candidate)
$baselineRoot = [IO.Path]::GetFullPath($Baseline)
$reportRoot = [IO.Path]::GetFullPath($Report)
# The fixture is the candidate's: a PR that changes the fixture changes both sides' input.
. (Join-Path $candidateRoot 'src/common.ps1')
. (Join-Path $candidateRoot 'tests/fixtures/screenshots.ps1')

$utf8 = New-Object Text.UTF8Encoding($false)
function Write-ObserveFile([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Stop-ObserveInvalid([string]$Message) {
    [Console]::Error.WriteLine('Invalid observe scenario: ' + $Message)
    exit 1
}
function Get-ObserveSpan([string]$Text) {
    # +5h, -20h, 90m, 1.5d, 0
    if ($Text -match '^\s*([+-]?)\s*(\d+(?:\.\d+)?)\s*([smhd]?)\s*$') {
        $value = [double]$Matches[2]
        if ($Matches[1] -eq '-') { $value = -$value }
        switch ($Matches[3]) {
            's' { return [timespan]::FromSeconds($value) }
            'm' { return [timespan]::FromMinutes($value) }
            'd' { return [timespan]::FromDays($value) }
            default { return [timespan]::FromHours($value) }
        }
    }
    Stop-ObserveInvalid ('not a time offset: ' + $Text)
}
# "@now-20h" is an ISO time, "@epoch+2h" Unix seconds, both against the fixture's own clock.
# $Now is the fixture's [datetimeoffset]; untyped, as PowerShell 7 will not leave a typed one out.
function Resolve-ObserveValue($Value, $Now) {
    if ($Value -is [string]) {
        if ($Value -match '^@now(.*)$') { return $Now.Add($(if ($Matches[1]) { Get-ObserveSpan $Matches[1] } else { [timespan]::Zero })).ToString('o') }
        if ($Value -match '^@epoch(.*)$') { return $Now.Add($(if ($Matches[1]) { Get-ObserveSpan $Matches[1] } else { [timespan]::Zero })).ToUnixTimeSeconds() }
        return $Value
    }
    if ($Value -is [array]) { return ,@($Value | ForEach-Object { Resolve-ObserveValue $_ $Now }) }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $copy[$property.Name] = Resolve-ObserveValue $property.Value $Now }
        return [pscustomobject]$copy
    }
    return $Value
}
function Get-ObserveMember($Node, [string]$Key) {
    if ($Node -is [Collections.IDictionary]) { return $Node[$Key] }
    if ($Node -is [array]) { return $Node[[int]$Key] }
    $property = $Node.PSObject.Properties[$Key]
    if ($property) { return $property.Value }
    return $null
}
function Set-ObserveMember($Node, [string]$Key, $Value, [bool]$Remove) {
    if ($Node -is [Collections.IDictionary]) { if ($Remove) { $Node.Remove($Key) } else { $Node[$Key] = $Value }; return }
    if ($Node -is [array]) {
        if ($Remove -or $Key -notmatch '^\d+$' -or [int]$Key -ge $Node.Count) { Stop-ObserveInvalid ('an array element is set by an existing index: ' + $Key) }
        $Node[[int]$Key] = $Value; return
    }
    if ($Remove) { $Node.PSObject.Properties.Remove($Key) } else { $Node | Add-Member -Force -NotePropertyName $Key -NotePropertyValue $Value }
}
# A dotted path into the JSON text a reader answered: slots.0.status
function Get-ObserveJson([string]$Text, [string]$Path) {
    try { $node = $Text | ConvertFrom-Json } catch { return '(not JSON)' }
    foreach ($key in $Path.Split('.')) {
        if ($null -eq $node) { return '(missing)' }
        if ($node -is [array]) {
            if ($key -notmatch '^\d+$' -or [int]$key -ge $node.Count) { return '(missing)' }
            $node = $node[[int]$key]
        } else {
            $property = $node.PSObject.Properties[$key]
            if (-not $property) { return '(missing)' }
            $node = $property.Value
        }
    }
    if ($null -eq $node) { return 'null' }
    if ($node -is [bool]) { return $node.ToString().ToLowerInvariant() }
    if ($node -is [string] -or $node -is [ValueType]) { return [string]$node }
    return ($node | ConvertTo-Json -Depth 20 -Compress)
}

# --- The scenario -------------------------------------------------------------------------
try { $plan = [IO.File]::ReadAllText([IO.Path]::GetFullPath($Scenario)) | ConvertFrom-Json } catch { Stop-ObserveInvalid 'it is not JSON' }
if (-not ($plan.claim -is [string]) -or -not $plan.claim.Trim()) { Stop-ObserveInvalid 'claim: say in one line what the PR changes' }
$change = if ($plan.change) { [string]$plan.change } else { 'visible' }
if ($change -notin @('visible', 'none')) { Stop-ObserveInvalid 'change is "visible" or "none"' }
if ($change -eq 'none' -and -not ([string]$plan.reason).Trim()) { Stop-ObserveInvalid 'a "change": "none" scenario says why in "reason"' }
# Filtered first: @($null).Count is 1, so a scenario with no checks would otherwise have one.
if ($change -eq 'visible' -and @($plan.checks | Where-Object { $_ }).Count -eq 0) { Stop-ObserveInvalid 'a visible change needs at least one check' }

# Every surface, on both sides, at every step. A capture the scenario adds is named by its id.
$captures = New-Object Collections.Generic.List[object]
foreach ($size in '100x26', '80x24', '60x40') {
    foreach ($mode in 'plain', 'ansi') { $captures.Add([pscustomobject]@{ id = "watch-$size-$mode"; surface = 'watch'; size = $size; mode = $mode; at = 0; frozen = $false; offset = 0 }) }
}
foreach ($at in 0.5, 1.25) { $captures.Add([pscustomobject]@{ id = "watch-100x26-plain-at$at"; surface = 'watch'; size = '100x26'; mode = 'plain'; at = $at; frozen = $false; offset = 0 }) }
$captures.Add([pscustomobject]@{ id = 'watch-100x26-plain-frozen'; surface = 'watch'; size = '100x26'; mode = 'plain'; at = 0; frozen = $true; offset = 0 })
$captures.Add([pscustomobject]@{ id = 'watch-60x40-plain-frozen-offset3'; surface = 'watch'; size = '60x40'; mode = 'plain'; at = 0; frozen = $true; offset = 3 })
foreach ($surface in 'status', 'status-json', 'explain', 'tray') { $captures.Add([pscustomobject]@{ id = $surface; surface = $surface }) }
foreach ($extra in @($plan.captures | Where-Object { $_ })) {
    if (-not ([string]$extra.id -match '^[A-Za-z0-9_.-]+$') -or ($captures | Where-Object { $_.id -eq $extra.id })) { Stop-ObserveInvalid ('capture id missing or repeated: ' + $extra.id) }
    if ($extra.surface -notin @('watch', 'status', 'status-json', 'explain', 'tray')) { Stop-ObserveInvalid ('unknown surface: ' + $extra.surface) }
    if ($extra.surface -eq 'watch' -and -not ([string]$extra.size -match '^\d+x\d+$')) { Stop-ObserveInvalid ('a watch capture has a size such as 100x26: ' + $extra.id) }
    $captures.Add([pscustomobject]@{ id = [string]$extra.id; surface = [string]$extra.surface; size = [string]$extra.size
        mode = $(if ($extra.mode -eq 'ansi') { 'ansi' } else { 'plain' }); at = $(if ($null -ne $extra.at) { [double]$extra.at } else { 0 })
        frozen = [bool]$extra.frozen; offset = $(if ($extra.offset) { [int]$extra.offset } else { 0 }) })
}

$fixtureCommand = Get-Command Get-Hotpl8ScreenshotFixture
$fixtureSwitches = @{ FixedClock = $true }
foreach ($name in 'Operations', 'TwoAccounts') {
    $wanted = $plan.fixture -and $plan.fixture.PSObject.Properties[$name.Substring(0,1).ToLowerInvariant() + $name.Substring(1)] -and [bool]$plan.fixture.($name.Substring(0,1).ToLowerInvariant() + $name.Substring(1))
    if ($wanted) {
        if (-not $fixtureCommand.Parameters.ContainsKey($name)) { Stop-ObserveInvalid ('this candidate''s fixture has no ' + $name) }
        $fixtureSwitches[$name] = $true
    }
}
$fixture = Get-Hotpl8ScreenshotFixture @fixtureSwitches
$fixtureNow = [datetimeoffset]$fixture.now
foreach ($patch in @($plan.patches | Where-Object { $_ })) {
    if ($patch.file -notin @('status', 'policy')) { Stop-ObserveInvalid 'a patch names its file: "status" or "policy"' }
    if (-not ([string]$patch.path)) { Stop-ObserveInvalid 'a patch names its path, such as slots.0.used5h' }
    $keys = ([string]$patch.path).Split('.')
    $node = $fixture.($patch.file)
    for ($i = 0; $i -lt $keys.Count - 1; $i++) {
        $node = Get-ObserveMember $node $keys[$i]
        if ($null -eq $node) { Stop-ObserveInvalid ('no such place in the fixture: ' + $patch.path) }
    }
    $remove = $patch.PSObject.Properties['remove'] -and [bool]$patch.remove
    Set-ObserveMember $node $keys[-1] $(if ($remove) { $null } else { Resolve-ObserveValue $patch.value $fixtureNow }) $remove
}
$policyText = $fixture.policy | ConvertTo-Json -Depth 30
$statusText = $fixture.status | ConvertTo-Json -Depth 30

$steps = New-Object Collections.Generic.List[object]
foreach ($step in @($(if ($plan.steps) { $plan.steps } else { @([pscustomobject]@{ name = 'start'; at = '0' }) }))) {
    if (-not ([string]$step.name -match '^[A-Za-z0-9_.+-]+$') -or ($steps | Where-Object { $_.name -eq $step.name })) { Stop-ObserveInvalid ('step name missing or repeated: ' + $step.name) }
    $at = $fixtureNow.Add($(if ($null -ne $step.at) { Get-ObserveSpan ([string]$step.at) } else { [timespan]::Zero }))
    $steps.Add([pscustomobject]@{ name = [string]$step.name; now = $at.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') })
}
function ConvertTo-ObserveExpected($Value) {
    if ($Value -is [bool]) { return $(if ($Value) { 'present' } else { 'absent' }) }
    return [string]$Value
}
$checks = @($plan.checks | Where-Object { $_ })
foreach ($check in $checks) {
    if (-not ($steps | Where-Object { $_.name -eq $check.step })) { Stop-ObserveInvalid ('a check names a step that is not in the timeline: ' + $check.step) }
    if (-not ($captures | Where-Object { $_.id -eq $check.capture })) { Stop-ObserveInvalid ('a check names a capture that is not taken: ' + $check.capture) }
    $kinds = @('text', 'match', 'json' | Where-Object { $check.PSObject.Properties[$_] })
    if ($kinds.Count -ne 1) { Stop-ObserveInvalid 'a check tests one of text, match or json' }
    if ($null -eq $check.candidate -or $null -eq $check.baseline) { Stop-ObserveInvalid 'a check declares what it expects of both the candidate and the baseline' }
}
# A check that expects the same of both sides cannot show the change, so it is no evidence for it.
if ($change -eq 'visible' -and -not @($checks | Where-Object { (ConvertTo-ObserveExpected $_.candidate) -cne (ConvertTo-ObserveExpected $_.baseline) }).Count) {
    Stop-ObserveInvalid 'a visible change needs a check that expects something different of the candidate and the baseline'
}

# --- Running a reader ---------------------------------------------------------------------
$lab = Join-Path $reportRoot 'lab'
$state = Join-Path $lab 'state'
$home_ = Join-Path $lab 'home'
foreach ($directory in $state, $home_, (Join-Path $home_ 'AppData/Local'), (Join-Path $home_ 'AppData/Roaming'), (Join-Path $home_ 'Temp')) { [void][IO.Directory]::CreateDirectory($directory) }
# Only these two programs run; none of them is pointed at real state or a real account home.
foreach ($key in 'HOTPL8_INSTALL_DIRECTORY', 'HOTPL8_REDUCED_MOTION', 'NO_COLOR', 'GH_TOKEN', 'GITHUB_TOKEN', 'OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'CODEX_HOME', 'CLAUDE_CONFIG_DIR') {
    [Environment]::SetEnvironmentVariable($key, $null)
}
$env:HOTPL8_STATE_DIRECTORY = $state
$env:USERPROFILE = $home_; $env:HOME = $home_
$env:LOCALAPPDATA = Join-Path $home_ 'AppData/Local'; $env:APPDATA = Join-Path $home_ 'AppData/Roaming'
$env:TEMP = Join-Path $home_ 'Temp'; $env:TMP = $env:TEMP
$platform = if ($env:OS -eq 'Windows_NT') { 'windows' } else { 'macos' }
$readerName = 'bin/' + $platform + '/hotpl8-native' + $(if ($platform -eq 'windows') { '.exe' } else { '' })
$sides = [ordered]@{ candidate = $candidateRoot; baseline = $baselineRoot }

function Get-ObserveArguments($Capture, [string]$Root, [string]$Now) {
    $arguments = @(switch ($Capture.surface) {
        'watch' { @('watch') }
        'status-json' { @('status') }
        default { @($Capture.surface) }
    })
    $arguments += @('--root', $Root, '--state', $state, '--now', $Now, '--zone', '0')
    if ($Capture.surface -eq 'watch') {
        $arguments += @('--size', $Capture.size, '--at', ([string]$Capture.at), "--$($Capture.mode)")
        if ($Capture.frozen) { $arguments += '--frozen' }
        if ($Capture.offset) { $arguments += @('--offset', [string]$Capture.offset) }
    }
    if ($Capture.surface -eq 'status-json') { $arguments += '-AsJson' }
    return $arguments
}
function Format-ObserveArgument([string]$Word) {
    if ($Word -and $Word -notmatch '[\s"]') { return $Word }
    return '"' + ($Word -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}
# The lab's and the release's own paths are written as <lab> and <root>, so the two sides
# compare and no user path is kept.
function Hide-ObservePaths([string]$Text, [string]$Root) {
    foreach ($pair in @(@($lab, '<lab>'), @($Root, '<root>'))) {
        foreach ($form in @($pair[0], $pair[0].Replace('\', '/'), $pair[0].Replace('\', '\\'))) {
            $Text = [regex]::Replace($Text, [regex]::Escape($form), $pair[1].Replace('$', '$$'), 'IgnoreCase')
        }
    }
    return $Text
}
function Invoke-ObserveReader([string]$Root, $Capture, [string]$Now) {
    $reader = Join-Path $Root $readerName
    if (-not [IO.File]::Exists($reader)) { return [pscustomobject]@{ exit = $null; output = ''; problem = 'ships no compiled reader for this system' } }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $reader
    $info.Arguments = ((Get-ObserveArguments $Capture $Root $Now) | ForEach-Object { Format-ObserveArgument $_ }) -join ' '
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.RedirectStandardInput = $true
    $info.StandardOutputEncoding = $utf8; $info.StandardErrorEncoding = $utf8
    $info.WorkingDirectory = $lab
    try { $process = [Diagnostics.Process]::Start($info) } catch { return [pscustomobject]@{ exit = $null; output = ''; problem = 'did not start: ' + $_.Exception.Message } }
    try {
        $process.StandardInput.Close()
        $out = $process.StandardOutput.ReadToEndAsync(); $err = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill() } catch {}
            return [pscustomobject]@{ exit = $null; output = ''; problem = 'did not answer within 30 s' }
        }
        $process.WaitForExit()
        $output = Hide-ObservePaths $out.Result $Root
        $problem = $null
        if ($process.ExitCode -ne 0) { $problem = ('exit ' + $process.ExitCode + ': ' + (Hide-ObservePaths $err.Result $Root)).Trim() }
        elseif (-not $output.Trim()) { $problem = 'answered nothing' }
        return [pscustomobject]@{ exit = $process.ExitCode; output = $output; problem = $problem }
    } finally { $process.Dispose() }
}

# --- Observing ----------------------------------------------------------------------------
$seen = @{}
$problems = New-Object Collections.Generic.List[string]
$wrote = New-Object Collections.Generic.List[string]
foreach ($step in $steps) {
    foreach ($side in $sides.Keys) {
        # Each side starts from the same fresh input, at the same path.
        foreach ($file in [IO.Directory]::GetFiles($state)) { [IO.File]::Delete($file) }
        Write-ObserveFile (Join-Path $state 'policy.json') $policyText
        Write-ObserveFile (Join-Path $state 'status.json') $statusText
        foreach ($capture in $captures) {
            $result = Invoke-ObserveReader $sides[$side] $capture $step.now
            $seen["$side|$($step.name)|$($capture.id)"] = $result
            $extension = if ($capture.surface -in @('status-json', 'tray')) { '.json' } else { '.txt' }
            Write-ObserveFile (Join-Path $reportRoot "frames/$side/$($step.name)/$($capture.id)$extension") $result.output
            if ($result.problem) { $problems.Add("$side at $($step.name), $($capture.id): $($result.problem)") }
        }
        $left = @([IO.Directory]::GetFiles($state) | ForEach-Object { [IO.Path]::GetFileName($_) } | Where-Object { $_ -notin @('policy.json', 'status.json') })
        if ($left) { $wrote.Add("$side at $($step.name) wrote " + ($left -join ', ')) }
    }
}

function Get-ObserveResult($Check, [string]$Side) {
    $result = $seen["$Side|$($Check.step)|$($Check.capture)"]
    if ($result.problem) { return '(no answer)' }
    if ($Check.PSObject.Properties['text']) { return $(if ($result.output.Contains([string]$Check.text)) { 'present' } else { 'absent' }) }
    if ($Check.PSObject.Properties['match']) { return $(if ($result.output -match [string]$Check.match) { 'present' } else { 'absent' }) }
    return Get-ObserveJson $result.output ([string]$Check.json)
}
$checkResults = @()
foreach ($check in $checks) {
    $kind = @('text', 'match', 'json' | Where-Object { $check.PSObject.Properties[$_] })[0]
    $observed = [ordered]@{ candidate = Get-ObserveResult $check 'candidate'; baseline = Get-ObserveResult $check 'baseline' }
    $expected = [ordered]@{ candidate = ConvertTo-ObserveExpected $check.candidate; baseline = ConvertTo-ObserveExpected $check.baseline }
    if ($kind -ne 'json') {
        foreach ($side in 'candidate', 'baseline') { if ($expected[$side] -notin @('present', 'absent')) { Stop-ObserveInvalid ('a text or match check expects present or absent, not ' + $expected[$side]) } }
    }
    $checkResults += [pscustomobject][ordered]@{
        name = $(if ($check.name) { [string]$check.name } else { "$($check.step) $($check.capture) $kind" })
        step = [string]$check.step; capture = [string]$check.capture; test = [ordered]@{ kind = $kind; value = [string]$check.$kind }
        expected = $expected; observed = $observed
        met = ($observed.candidate -ceq $expected.candidate -and $observed.baseline -ceq $expected.baseline)
    }
}
$differences = @()
foreach ($step in $steps) {
    foreach ($capture in $captures) {
        if ($seen["candidate|$($step.name)|$($capture.id)"].output -cne $seen["baseline|$($step.name)|$($capture.id)"].output) { $differences += "$($step.name) $($capture.id)" }
    }
}
$failed = @($checkResults | Where-Object { -not $_.met })
$reasons = @()
if ($problems.Count) { $reasons += 'not every surface answered on both sides' }
if ($failed.Count) { $reasons += ("{0} of {1} checks not met" -f $failed.Count, $checkResults.Count) }
if ($change -eq 'none' -and $differences.Count) { $reasons += ("{0} captures differ from the baseline, and none should" -f $differences.Count) }
$verdict = if ($reasons.Count) { 'FAIL' } else { 'PASS' }

# --- The report ---------------------------------------------------------------------------
$notObserved = @('real key input (Space, arrows, Q) in a live terminal', 'a real terminal resize while open',
    'restoring the terminal on exit', 'the collector, scheduled wakes and provider tools (observe runs the reader only)')
if ($platform -eq 'windows') { $notObserved += 'macOS (Mac CI covers it)' } else { $notObserved += 'Windows (Windows CI covers it)' }
$copy = Join-Path $reportRoot 'scenario.json'
if ([IO.Path]::GetFullPath($Scenario) -ne $copy) { Write-ObserveFile $copy ([IO.File]::ReadAllText([IO.Path]::GetFullPath($Scenario))) }
$summary = [ordered]@{
    verdict = $verdict; reasons = $reasons; pr = $Pr; claim = [string]$plan.claim; change = $change; reason = [string]$plan.reason
    candidate = [ordered]@{ sha = $CandidateSha; reader = 'candidate/' + $readerName }
    baseline = [ordered]@{ sha = $BaselineSha; reader = 'baseline/' + $readerName }
    platform = $platform; fixtureNow = $fixtureNow.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    steps = $steps.ToArray(); captures = @($captures | ForEach-Object { $_.id })
    checks = @($checkResults); problems = $problems.ToArray(); differences = @($differences); stateWrites = $wrote.ToArray()
    scenario = 'scenario.json'; frames = 'frames/<side>/<step>/<capture>'; lab = 'lab/state'
    notObserved = $notObserved
}
Write-ObserveFile (Join-Path $reportRoot 'report.json') ($summary | ConvertTo-Json -Depth 10)
$short = { param($sha) if ($sha.Length -ge 7) { $sha.Substring(0, 7) } else { $sha } }
$md = New-Object Text.StringBuilder
[void]$md.AppendLine("## Observed run: $verdict")
[void]$md.AppendLine('')
[void]$md.AppendLine("Claim: $($plan.claim)")
[void]$md.AppendLine('')
[void]$md.AppendLine(('Candidate `{0}` against baseline `{1}` on {2}; {3} steps from the fixture''s {4}; {5} captures per side per step.' -f (& $short $CandidateSha), (& $short $BaselineSha), $platform, $steps.Count, $summary.fixtureNow, $captures.Count))
if ($reasons) { [void]$md.AppendLine(''); [void]$md.AppendLine('Why: ' + ($reasons -join '; ') + '.') }
[void]$md.AppendLine('')
if ($checkResults.Count) {
    [void]$md.AppendLine('| Check | Step | Candidate (expected) | Baseline (expected) | Met |')
    [void]$md.AppendLine('|---|---|---|---|---|')
    foreach ($c in $checkResults) {
        $cell = { param($o, $e) if ($o -ceq $e) { $o } else { "$o ($e)" } }
        [void]$md.AppendLine(('| {0} | {1} | {2} | {3} | {4} |' -f ($c.name -replace '\|', '/'), $c.step, (& $cell $c.observed.candidate $c.expected.candidate), (& $cell $c.observed.baseline $c.expected.baseline), $(if ($c.met) { 'yes' } else { '**no**' })))
    }
} else {
    [void]$md.AppendLine("No visible change claimed: $($plan.reason)")
}
[void]$md.AppendLine('')
[void]$md.AppendLine(('Health: {0}. Captures differing from the baseline: {1}.' -f $(if ($problems.Count) { "$($problems.Count) problems" } else { 'every surface answered on both sides with exit 0' }), $(if ($differences.Count) { $differences.Count } else { 'none' })))
foreach ($p in $problems | Select-Object -First 10) { [void]$md.AppendLine("- $p") }
if ($change -eq 'none') { foreach ($d in $differences | Select-Object -First 10) { [void]$md.AppendLine("- differs: $d") } }
[void]$md.AppendLine('')
[void]$md.AppendLine('Not observed: ' + ($notObserved -join '; ') + '.')
Write-ObserveFile (Join-Path $reportRoot 'report.md') $md.ToString()
[Console]::WriteLine("Observed: $verdict" + $(if ($reasons) { ' (' + ($reasons -join '; ') + ')' } else { '' }))
[Console]::WriteLine('Report: ' + (Join-Path $reportRoot 'report.md'))
exit $(if ($verdict -eq 'PASS') { 0 } else { 10 })
