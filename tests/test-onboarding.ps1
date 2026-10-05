# Offline newcomer flow: policy creation, actionable guidance, and no false readiness.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/diagnostics.ps1')
$script:passed = 0; $script:failed = 0
function Assert($Value) { if (-not $Value) { throw 'assertion failed' } }
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; 'PASS ' + $Name }
    catch { $script:failed++; 'FAIL ' + $Name + ': ' + $_.Exception.Message }
}
$dir = Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-onboarding-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
# The continue command writes Claude's settings here, never in the real profile.
$claudeBefore = $env:CLAUDE_CONFIG_DIR; $env:CLAUDE_CONFIG_DIR = Join-Path $dir 'claude home'
function Invoke-TestCli([string[]]$Arguments) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'hotpl8.ps1')) + $Arguments + @('-StateDirectory', $dir)
    $psi.Arguments = (@($all | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $proc = [Diagnostics.Process]::Start($psi)
    try {
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        # Fresh isolated homes on hosted Windows incur first-use PowerShell/module
        # initialization (~23s in CI). This is a harness budget, not a provider timeout.
        if (-not $proc.WaitForExit(45000)) { $proc.Kill(); throw 'CLI test timed out' }
        return @{ code = $proc.ExitCode; text = $stdout.Result + $stderr.Result }
    } finally { $proc.Dispose() }
}
try {
    Check 'init creates the default policy and directs users to guided setup' {
        $r = Invoke-TestCli @('init')
        Assert ($r.code -eq 0 -and $r.text.Contains('hotpl8 setup') -and $r.text.Contains('automatic switching and continue on, warming off'))
        $policy = Read-Hotpl8Json (Join-Path $dir 'policy.json')
        Assert ($policy.mode -eq 'automate' -and $policy.switchEnabled -eq $true -and $policy.warm -eq $false -and $policy.probeEnabled -eq $false)
        Assert (-not $policy.prefer -and -not $policy.codex.slots)
    }
    Check 'doctor explains missing enrollment while retaining JSON contract' {
        $before = (Get-FileHash (Join-Path $dir 'policy.json')).Hash
        $r = Invoke-TestCli @('doctor')
        Assert ($r.code -eq 0 -and $r.text.Contains('NO ACCOUNTS') -and $r.text.Contains('hotpl8 setup'))
        $json = Invoke-TestCli @('doctor', '-AsJson')
        $d = $json.text | ConvertFrom-Json
        Assert ($json.code -eq 0 -and $d.policyValid -and -not $d.codexConfigured)
        Assert ($d.continue.enabled -eq $true -and $d.continue.hookPresent -eq $false -and $null -eq $d.continue.lastAt)
        Assert ((Get-FileHash (Join-Path $dir 'policy.json')).Hash -eq $before)
        Assert (@(Get-ChildItem $dir -File).Count -eq 1)
    }
    Check 'empty refresh fails with an enrollment action and creates no snapshot' {
        $r = Invoke-TestCli @('refresh')
        Assert ($r.code -ne 0 -and $r.text.Contains('No accounts enrolled'))
        Assert (-not (Test-Path (Join-Path $dir 'status.json')))
    }
    Check 'incomplete enroll exits without a native login prompt or policy change' {
        $before = (Get-FileHash (Join-Path $dir 'policy.json')).Hash
        $r = Invoke-TestCli @('enroll', '-Slot', 'main')
        Assert ($r.code -ne 0 -and $r.text.Contains('-AccountHome PATH'))
        Assert ((Get-FileHash (Join-Path $dir 'policy.json')).Hash -eq $before)
    }
    $report = @{
        version = 'fixture'; runtime = '5.1'; policyPresent = $true; policyValid = $true
        mode = 'monitor'; codexConfigured = $true; claudeConfigured = $false
        codexFound = $true; cswapFound = $false; collectorBusy = $false
        snapshotAgeSeconds = $null; snapshotFresh = $false
    }
    Check 'Codex-only guidance does not require optional Claude tools' {
        $text = (Format-Hotpl8Doctor $report) -join "`n"
        Assert ($text.Contains('NO READING') -and -not $text.Contains('CSWAP MISSING'))
        Assert ($text.Contains('Doctor is offline'))
    }
    Check 'missing dependency stale reading and busy collector have distinct next steps' {
        $report.codexFound = $false
        Assert (((Format-Hotpl8Doctor $report) -join "`n").Contains('CODEX MISSING'))
        $report.codexFound = $true; $report.snapshotAgeSeconds = 3600
        Assert (((Format-Hotpl8Doctor $report) -join "`n").Contains('STALE READING'))
        $report.collectorBusy = $true
        Assert (((Format-Hotpl8Doctor $report) -join "`n").Contains('COLLECTOR BUSY'))
    }
    Check 'a recent snapshot is not reported as proof of native authentication' {
        $report.collectorBusy = $false; $report.snapshotFresh = $true; $report.snapshotAgeSeconds = 5
        $text = (Format-Hotpl8Doctor $report) -join "`n"
        Assert ($text.Contains('per-account status') -and $text.Contains('native login and quota availability are checked by hotpl8 refresh'))
    }
    Check 'doctor reports automatic continue in one line' {
        $report.continue = @{ enabled = $true; hookPresent = $false; lastAt = $null }
        Assert (((Format-Hotpl8Doctor $report) -join "`n").Contains('Automatic continue: on | Claude hook absent | last sent never'))
        $report.continue = @{ enabled = $false; hookPresent = $true; lastAt = '2026-01-02T03:04:05.0000000+00:00' }
        Assert (((Format-Hotpl8Doctor $report) -join "`n").Contains('Automatic continue: off | Claude hook present | last sent 2026-01-02T03:04:05.0000000+00:00'))
    }
    Check 'guided setup CLI preserves policy and exposes offline capabilities' {
        $before=(Get-FileHash (Join-Path $dir 'policy.json')).Hash
        $r=Invoke-TestCli @('setup');Assert ($r.code -eq 0 -and $r.text.Contains('guided enrollment'))
        Assert ((Get-FileHash (Join-Path $dir 'policy.json')).Hash -eq $before)
        $r=Invoke-TestCli @('capabilities','-AsJson');$data=$r.text|ConvertFrom-Json
        Assert ($r.code -eq 0 -and $data.schemaVersion -eq 1 -and $data.providers.codex.freshAccounts -eq 0)
    }
    Check 'pause resume history and empty account list work through the public CLI' {
        Assert ((Invoke-TestCli @('pause','-Minutes','10')).code -eq 0)
        Assert ((Read-Hotpl8Json (Join-Path $dir 'automation-pause.json')).reason -eq 'pause')
        Assert ((Invoke-TestCli @('resume')).code -eq 0)
        $r=Invoke-TestCli @('history','-Operation','clear');Assert ($r.code -eq 0)
        $r=Invoke-TestCli @('accounts','-AsJson');Assert ($r.code -eq 0 -and ($r.text -replace '\s','') -eq '[]')
    }
    Check 'read-only explanation and tray view need no native process or observation' {
        $before=@(Get-ChildItem $dir -File).Count
        $r=Invoke-TestCli @('explain');Assert ($r.code -eq 0 -and $r.text.Contains('No observation'))
        $r=Invoke-TestCli @('tray','-Once');$m=$r.text|ConvertFrom-Json
        Assert ($r.code -eq 0 -and $m.title.Contains('HotPl8'))
        Assert (@(Get-ChildItem $dir -File).Count -eq $before)
    }
    Check 'continue shows its state and changes nothing until asked' {
        $before = (Get-FileHash (Join-Path $dir 'policy.json')).Hash
        $r = Invoke-TestCli @('continue')
        Assert ($r.code -eq 0 -and $r.text.Contains('Automatic continue: on') -and $r.text.Contains('Claude hook: absent'))
        Assert ((Invoke-TestCli @('init')).code -ne 0)
        Assert ((Get-FileHash (Join-Path $dir 'policy.json')).Hash -eq $before -and -not (Test-Path $env:CLAUDE_CONFIG_DIR))
    }
    Check 'continue disable and enable keep the policy and the Claude hook in step' {
        [void][IO.Directory]::CreateDirectory($env:CLAUDE_CONFIG_DIR)
        $settings = Join-Path $env:CLAUDE_CONFIG_DIR 'settings.json'
        $r = Invoke-TestCli @('continue', '-Operation', 'enable')
        Assert ($r.code -eq 0 -and $r.text.Contains('Automatic continue: on') -and $r.text.Contains('Claude hook: present'))
        $hook = (Read-Hotpl8Json $settings).hooks.StopFailure[0].hooks[0]
        Assert ($hook.asyncRewake -eq $true -and ($hook.args -join ' ').Contains('continue.ps1'))
        $r = Invoke-TestCli @('continue', '-Operation', 'disable')
        Assert ($r.code -eq 0 -and $r.text.Contains('off (automation.continue is false)') -and $r.text.Contains('Claude hook: absent'))
        $policy = Read-Hotpl8Json (Join-Path $dir 'policy.json')
        Assert ($policy.automation.continue -eq $false -and $policy.mode -eq 'automate' -and $policy.switchEnabled -eq $true -and $policy.warm -eq $false)
        Assert (-not (Read-Hotpl8Json $settings).hooks)
        $d = (Invoke-TestCli @('doctor', '-AsJson')).text | ConvertFrom-Json
        Assert ($d.continue.enabled -eq $false -and $d.continue.hookPresent -eq $false)
        $r = Invoke-TestCli @('continue', '-Operation', 'enable')
        Assert ($r.text.Contains('Claude hook: present') -and $null -eq (Read-Hotpl8Json (Join-Path $dir 'policy.json')).automation.continue)
    }
    Check 'continue leaves a monitor policy alone and freezes an older policy before changing it' {
        $path = Join-Path $dir 'policy.json'
        $monitor = Read-Hotpl8Json (Join-Path $root 'policy.example.json'); $monitor.mode = 'monitor'
        Write-Hotpl8Text $path ($monitor | ConvertTo-Json -Depth 24)
        $before = (Get-FileHash $path).Hash
        $r = Invoke-TestCli @('continue', '-Operation', 'enable')
        Assert ($r.code -eq 0 -and $r.text.Contains('off (monitor mode turns every action off)') -and $r.text.Contains('Claude hook: absent'))
        Assert ((Get-FileHash $path).Hash -eq $before)
        Copy-Item (Join-Path $root 'tests/legacy-policy.json') $path -Force
        $r = Invoke-TestCli @('continue', '-Operation', 'disable')
        $saved = Read-Hotpl8Json $path
        Assert ($r.code -eq 0 -and $saved.schemaVersion -eq 2 -and $saved.automation.continue -eq $false)
        Assert ($saved.mode -eq 'automate' -and $saved.switchEnabled -eq $true -and $saved.probeEnabled -eq $true -and $saved.warm -eq $true)
        [void][IO.Directory]::CreateDirectory((Join-Path $dir 'continue'))
        [IO.File]::WriteAllText((Join-Path $dir 'continue/fixture-conversation'), '')
        Assert ((Invoke-TestCli @('doctor')).text -match 'Automatic continue: off \| Claude hook absent \| last sent \d{4}-\d\d-\d\dT')
    }
} finally {
    $env:CLAUDE_CONFIG_DIR = $claudeBefore
    $full = [IO.Path]::GetFullPath($dir)
    if ($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-onboarding-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
'passed=' + $script:passed + ' failed=' + $script:failed
if ($script:failed) { exit 1 }
