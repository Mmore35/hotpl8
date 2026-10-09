# Where this copy keeps its state. A policy is validated by the compiled program, which
# rules.ps1 asks: Assert-Hotpl8Policy is defined there.
. (Join-Path $PSScriptRoot 'rules.ps1')
function Resolve-Hotpl8StateDirectory([string]$Explicit, [string]$CodeDirectory) {
    if ($Explicit) { return [IO.Path]::GetFullPath($Explicit) }
    if ($env:HOTPL8_STATE_DIRECTORY) { return [IO.Path]::GetFullPath($env:HOTPL8_STATE_DIRECTORY) }
    $installed = Read-Hotpl8Json (Join-Path $CodeDirectory 'install-state.json')
    if ($installed.stateDirectory) { return [IO.Path]::GetFullPath([string]$installed.stateDirectory) }
    # A source checkout is portable, including existing installations.
    return $CodeDirectory
}
