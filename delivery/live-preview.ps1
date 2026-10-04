# Real candidate dashboard with disposable fictional state. No provider actions.
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
# Demonstrate newly recognized plans without requiring a configured capacity.
$fixture.policy.codex.PSObject.Properties.Remove('capacity')
foreach($slot in $fixture.status.providers.codex.slots){$slot|Add-Member NoteProperty planType 'new_plan' -Force}
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
try {
    Write-Hotpl8Text (Join-Path $state 'policy.json') ($fixture.policy | ConvertTo-Json -Depth 20)
    Write-Hotpl8Text (Join-Path $state 'status.json') ($fixture.status | ConvertTo-Json -Depth 20)
    [Console]::Title = $PrUrl + ' / ' + $Revision.Substring(0,12) + ' / DEMO'
    Show-Hotpl8Dashboard $state -Nyan
} finally {
    # Python owns the temporary session and cleans it on success or failure.
    [Console]::WriteLine('Preview ended: ' + $PrUrl + ' / ' + $Revision)
}
