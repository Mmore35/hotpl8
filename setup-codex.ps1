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
. (Join-Path $PSScriptRoot 'src/common.ps1')
. (Join-Path $PSScriptRoot 'src/config.ps1')
$StateDirectory=Resolve-Hotpl8StateDirectory $StateDirectory $PSScriptRoot
. (Join-Path $PSScriptRoot 'src/providers/claude.ps1')
. (Join-Path $PSScriptRoot 'src/providers/codex.ps1')
$policyPath=Join-Path $StateDirectory 'policy.json'
$policy=Read-Hotpl8Json $policyPath
if (-not $policy) { throw 'Create policy.json from policy.example.json first, or use {"codex":{"slots":[]}} for Codex-only operation.' }
$policyHash=(Get-FileHash -LiteralPath $policyPath -Algorithm SHA256).Hash
$policyDocument=$policy
if($policy.schemaVersion -eq 3){
    Assert-Hotpl8Policy $policy
    $view=Get-Hotpl8ProviderView $null $policy 'codex'
    $policy=$view.policy
    if(-not $view.registration.configured){$policy.PSObject.Properties.Remove('codex')}
}

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
    # Enrollment is deliberate and bounded. Do not turn one subscription into two slots.
    $identityClock=[Diagnostics.Stopwatch]::StartNew()
    foreach($other in @($policy.codex.slots)){
        if(-not $other){continue}
        if($identityClock.ElapsedMilliseconds -ge 20000){throw 'Account verification budget reached. Existing policy is unchanged.'}
        $peer=Read-CodexQuota $other.home $CodexExecutable ([math]::Min(5000,20000-$identityClock.ElapsedMilliseconds))
        if($peer.status -ne 'ok'){throw 'Could not verify an existing account. Refresh native sign-in before enrolling another account.'}
        if($peer.identityKey -eq $read.identityKey){throw 'This subscription is already enrolled under another slot.'}
    }
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
$savedPolicy=$policy
if($policyDocument.schemaVersion -eq 3){
    $policyDocument.providers|Add-Member NoteProperty codex $policy.codex -Force
    Assert-Hotpl8Policy $policyDocument
    $savedPolicy=$policyDocument
}
$lock=$null
try {
    $lock=[IO.File]::Open((Join-Path $StateDirectory 'tick.lock'),'OpenOrCreate','ReadWrite','None')
    if((Get-FileHash -LiteralPath $policyPath -Algorithm SHA256).Hash -ne $policyHash){throw 'Policy changed during enrollment; rerun setup rather than overwriting another edit.'}
    Write-Hotpl8Text (Join-Path $StateDirectory 'policy.previous.json') ([IO.File]::ReadAllText($policyPath))
    Write-Hotpl8Text $policyPath ($savedPolicy|ConvertTo-Json -Depth 24)
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
