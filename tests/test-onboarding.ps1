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
function Invoke-TestCli([string[]]$Arguments) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'hotpl8.ps1')) + $Arguments + @('-StateDirectory', $dir)
    $psi.Arguments = (@($all | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $proc = [Diagnostics.Process]::Start($psi)
    try {
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(15000)) { $proc.Kill(); throw 'CLI test timed out' }
        return @{ code = $proc.ExitCode; text = $stdout.Result + $stderr.Result }
    } finally { $proc.Dispose() }
}
try {
    Check 'fresh setup creates monitor policy and names the enrollment command' {
        $r = Invoke-TestCli @('init')
        Assert ($r.code -eq 0 -and $r.text.Contains('hotpl8 enroll'))
        $policy = Read-Hotpl8Json (Join-Path $dir 'policy.json')
        Assert ($policy.mode -eq 'monitor' -and -not $policy.prefer -and -not $policy.codex.slots)
    }
    Check 'doctor explains missing enrollment while retaining JSON contract' {
        $before = (Get-FileHash (Join-Path $dir 'policy.json')).Hash
        $r = Invoke-TestCli @('doctor')
        Assert ($r.code -eq 0 -and $r.text.Contains('NO ACCOUNTS') -and $r.text.Contains('hotpl8 enroll'))
        $json = Invoke-TestCli @('doctor', '-AsJson')
        $d = $json.text | ConvertFrom-Json
        Assert ($json.code -eq 0 -and $d.policyValid -and -not $d.codexConfigured)
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
} finally {
    $full = [IO.Path]::GetFullPath($dir)
    if ($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-onboarding-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
'passed=' + $script:passed + ' failed=' + $script:failed
if ($script:failed) { exit 1 }
