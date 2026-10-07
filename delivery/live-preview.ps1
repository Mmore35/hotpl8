# Real candidate dashboard with disposable fictional state. No provider actions.
# live_preview.py puts a candidate's compiled reader at its release path under the source.
param([Parameter(Mandatory=$true)][string]$SourceDirectory,
      [Parameter(Mandatory=$true)][string]$StateDirectory,
      [Parameter(Mandatory=$true)][string]$PrUrl,
      [Parameter(Mandatory=$true)][string]$Revision)
$ErrorActionPreference = 'Stop'
$source = [IO.Path]::GetFullPath($SourceDirectory)
. (Join-Path $source 'src/common.ps1')
. (Join-Path $source 'src/providers/codex.ps1')
. (Join-Path $source 'src/dashboard.ps1')
. (Join-Path $source 'tests/fixtures/screenshots.ps1')
$fixture = Get-Hotpl8ScreenshotFixture
$now = [datetimeoffset]::UtcNow
$delta = $now - $fixture.now
$fixture.status.generatedAt = $now.AddSeconds(-42).ToString('o')
foreach($slot in $fixture.status.slots){
    $slot.label = 'Demo ' + $slot.label
    $fixture.policy.labels.([string]$slot.slot) = $slot.label
    $slot.observedAt = $now.AddSeconds(-42).ToString('o')
    foreach($key in @('reset5h','reset7d')){
        $slot.$key = ([datetimeoffset]::Parse($slot.$key) + $delta).ToString('o')
    }
}
foreach($slot in $fixture.status.providers.codex.slots){
    $slot.label = 'Demo ' + $slot.label
    $slot.observedAt = $now.AddSeconds(-42).ToString('o')
    foreach($window in $slot.buckets.codex.windows.PSObject.Properties){
        $window.Value.resetsAt = [long]($window.Value.resetsAt + $delta.TotalSeconds)
    }
}
foreach($slot in $fixture.policy.codex.slots){ $slot.label = 'Demo ' + $slot.label }
$state = [IO.Path]::GetFullPath($StateDirectory)
$code = 0
try {
    Write-Hotpl8Text (Join-Path $state 'policy.json') ($fixture.policy | ConvertTo-Json -Depth 20)
    Write-Hotpl8Text (Join-Path $state 'status.json') ($fixture.status | ConvertTo-Json -Depth 20)
    [Console]::Title = $PrUrl + ' / ' + $Revision.Substring(0,12) + ' / DEMO'
    # A candidate's compiled reader is asked for the dashboard first, in the words a user
    # types after `hotpl8`. One that has no dashboard answers 64 before it prints anything,
    # and the candidate's PowerShell dashboard runs.
    $compiled = $false
    $reader = Join-Path $source $(if ($env:OS -eq 'Windows_NT') { 'bin/windows/hotpl8-native.exe' } else { 'bin/macos/hotpl8-native' })
    if ([IO.File]::Exists($reader)) {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $reader
        $info.Arguments = (@('user', 'nyan', '-StateDirectory', $state) | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
        # The terminal is inherited, not piped; only diagnostics are collected.
        $info.UseShellExecute = $false
        $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($info)
        try {
            $diagnostics = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            if ($process.ExitCode -ne 64) {
                # A compiled dashboard that fails is shown failing, not replaced.
                $compiled = $true
                $code = $process.ExitCode
                if ($code -ne 0) { [Console]::Error.WriteLine(('Candidate reader exited with ' + $code + '. ' + $diagnostics.Result).Trim()) }
            }
        } finally { $process.Dispose() }
    }
    if (-not $compiled) { Show-Hotpl8Dashboard $state -Nyan }
} finally {
    # Python owns the temporary session and cleans it on success or failure.
    [Console]::WriteLine('Preview ended: ' + $PrUrl + ' / ' + $Revision)
}
exit $code
