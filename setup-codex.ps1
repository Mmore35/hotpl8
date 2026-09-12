# Explicit enrollment only. Native Codex retains all authentication ownership.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Slot,
    [Parameter(Mandatory=$true)][string]$AccountHome,
    [string]$Label,
    [string]$CodexExecutable,
    [string]$Model,
    [ValidateSet('codex','codex_bengalfox')][string]$Meter='codex',
    [string]$StateDirectory,
    [switch]$InstallHook,
    [switch]$InstallCommand
)

$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'config.ps1')
$StateDirectory=Resolve-Hotpl8StateDirectory $StateDirectory $PSScriptRoot
. (Join-Path $PSScriptRoot 'providers/claude.ps1')
. (Join-Path $PSScriptRoot 'providers/codex.ps1')
$policyPath=Join-Path $StateDirectory 'policy.json'
$policy=Read-Hotpl8Json $policyPath
if (-not $policy) { throw 'Create policy.json from policy.example.json first, or use {"codex":{"slots":[]}} for Codex-only operation.' }
$policyHash=(Get-FileHash -LiteralPath $policyPath -Algorithm SHA256).Hash
if($InstallCommand -and ($env:OS -ne 'Windows_NT' -or $StateDirectory -ne $PSScriptRoot)){throw 'Use install.ps1 for command installation with a custom state directory.'}
$homePath=[IO.Path]::GetFullPath($AccountHome)
$read=Read-CodexQuota $homePath $CodexExecutable 5000
if ($read.status -ne 'ok') { throw ('Native login is not ready: '+$read.status+'. Sign in with native Codex in this home first.') }
if (-not $read.standardTransport -or ($read.modelProvider -and $read.modelProvider -ne 'openai')) { throw 'Custom provider/endpoint needs separate validation; subscription setup stopped.' }
if (-not $policy.codex) {
    $policy | Add-Member NoteProperty codex ([pscustomobject]@{slots=@();prefer=@();reserve=@();order='soonest-reset';margin5h=25;margin7d=20;margin7dWork=5;defaultMeter=$Meter;modelMeters=[pscustomobject]@{}})
}
$existing=@($policy.codex.slots|Where-Object id -EQ $Slot)
if ($existing.Count -and [IO.Path]::GetFullPath([string]$existing[0].home) -ne $homePath) { throw 'That slot already names a different home. Edit the mapping deliberately; setup will not replace it.' }
if (-not $existing.Count) {
    $entry=[pscustomobject]@{id=$Slot;home=$homePath;label=$(if($Label){$Label}else{$Slot})}
    $policy.codex.slots=@($policy.codex.slots)+@($entry)
    $policy.codex.prefer=@($policy.codex.prefer)+@($Slot)
}
if ($Model) {
    # The caller supplies an explicit mapping after verifying the model's meter.
    if (-not $policy.codex.modelMeters) { $policy.codex | Add-Member NoteProperty modelMeters ([pscustomobject]@{}) -Force }
    $policy.codex.modelMeters | Add-Member NoteProperty $Model $Meter -Force
}
Assert-Hotpl8Policy $policy
Assert-CodexPolicy $policy.codex
# Validate the hook merge before changing either local file.
$hookPath=Join-Path $homePath 'hooks.json';$hooks=$null
if ($InstallHook) {
    $hooks=Read-Hotpl8Json $hookPath
    if ((Test-Path -LiteralPath $hookPath) -and -not $hooks) { throw 'Existing hooks.json is invalid; it was not overwritten.' }
    if (-not $hooks) { $hooks=[pscustomobject]@{hooks=[pscustomobject]@{}} }
    if (-not $hooks.hooks) { $hooks|Add-Member NoteProperty hooks ([pscustomobject]@{}) -Force }
    $hostExe=if($env:OS -eq 'Windows_NT'){'powershell'}else{'pwsh'}
    $command=$hostExe+' -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'status-print.ps1')+'" -Provider codex -StateDirectory "'+$StateDirectory+'"'
    $entries=@($hooks.hooks.SessionStart|Where-Object{$null -ne $_})
    $found=@($entries|ForEach-Object{$_.hooks}|Where-Object{$_.command -eq $command})
    if (-not $found.Count) {
        $entries+=@([pscustomobject]@{matcher='startup|resume|compact|clear';hooks=@([pscustomobject]@{type='command';command=$command;timeout=2})})
        $hooks.hooks|Add-Member NoteProperty SessionStart $entries -Force
    }
}
$lock=$null
try {
    $lock=[IO.File]::Open((Join-Path $StateDirectory 'tick.lock'),'OpenOrCreate','ReadWrite','None')
    if((Get-FileHash -LiteralPath $policyPath -Algorithm SHA256).Hash -ne $policyHash){throw 'Policy changed during enrollment; rerun setup rather than overwriting another edit.'}
    Write-Hotpl8Text $policyPath ($policy|ConvertTo-Json -Depth 24)
    if ($hooks) { Write-Hotpl8Text $hookPath ($hooks|ConvertTo-Json -Depth 32) -NoBom }
} finally { if($lock){$lock.Dispose()} }
if ($InstallCommand) {
    if ($env:OS -ne 'Windows_NT') { throw 'Global command installation is currently verified on Windows only.' }
    $userPath=[Environment]::GetEnvironmentVariable('Path','User')
    $parts=@($userPath -split ';'|Where-Object{$_})
    if ($parts -notcontains $PSScriptRoot) { [Environment]::SetEnvironmentVariable('Path',(($parts+@($PSScriptRoot))-join ';'),'User') }
}
'Enrolled Codex slot '+$Slot+'. Authentication stays in its native home.'
if ($InstallHook) { 'Hook registered. In native Codex, open /hooks and review/trust the HotPl8 SessionStart command.' }
if ($InstallCommand) { 'Open a new terminal for the hotpl8 command. Existing terminals can use .\hotpl8.ps1.' }
