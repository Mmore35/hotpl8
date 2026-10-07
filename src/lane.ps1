# What the compiled collector still asks PowerShell for: reading Codex accounts, keeping
# Claude's continue hook as the policy says, and closing an account addition the collector
# has now observed. The collector starts a lane only when it has that work, and reads one
# line of JSON back: what the lane produced, or the failure it met.
param([ValidateSet('codex','continue','onboarding')][string]$Lane,[string]$StateDirectory,[string]$Provider,[string]$CodexExecutable,[switch]$Remove)
$ErrorActionPreference='Stop'
$answer=$null
try{
    . (Join-Path $PSScriptRoot 'common.ps1')
    . (Join-Path $PSScriptRoot 'config.ps1')
    . (Join-Path $PSScriptRoot 'collection.ps1')
    $code=Split-Path $PSScriptRoot -Parent
    switch -CaseSensitive ($Lane) {
        'codex' {
            # Get-Hold is the installation's hold, and lives with the Claude adapter.
            . (Join-Path $PSScriptRoot 'providers/claude.ps1')
            . (Join-Path $PSScriptRoot 'providers/codex.ps1')
            $policy=Read-Hotpl8Json (Join-Path $StateDirectory 'policy.json')
            $registration=@(Get-Hotpl8ConfiguredProviders $policy|Where-Object {$_.id -ceq $Provider -and $_.driver -ceq 'codex-app-server'})
            if($registration.Count -ne 1){throw 'Unsupported collection driver.'}
            $old=(Read-Hotpl8Json (Join-Path $StateDirectory 'status.json')).providers.$Provider
            $state=Get-Hotpl8ProviderStateDirectory $StateDirectory $Provider
            $answer=@{payload=(Invoke-CodexCollection $registration[0].policy $state $CodexExecutable $old $null -ControlDirectory $StateDirectory)}
        }
        'continue' {
            . (Join-Path $PSScriptRoot 'lifecycle.ps1')
            Set-Hotpl8ContinueHook $code $StateDirectory -Remove:$Remove
            $answer=@{done=$true}
        }
        'onboarding' {
            . (Join-Path $PSScriptRoot 'onboarding.ps1')
            Complete-Hotpl8ObservedOnboarding $StateDirectory
            $answer=@{done=$true}
        }
        default {throw 'Unknown lane.'}
    }
}catch{
    # The collector decides what a failure is called and what is recorded of it. Its words
    # go no further than the collector, which compares them with the few it knows.
    $failure=@{code='unexpected_collection_error';said=[string]$_.Exception.Message}
    if(Get-Command Get-Hotpl8FailureCode -ErrorAction SilentlyContinue){$failure.code=Get-Hotpl8FailureCode $_}
    $stateFile=$_.Exception.Data['Hotpl8StateFile']
    if($stateFile){$failure.stateFile=[string]$stateFile;$failure.ioCode=[int]$_.Exception.Data['Hotpl8IoCode']}
    $source=[string]$_.InvocationInfo.ScriptName
    if($source){$failure.source=[IO.Path]::GetFileName($source);$failure.line=[int]$_.InvocationInfo.ScriptLineNumber}
    $answer=@{failure=$failure}
}
# Bytes, not text: a redirected Windows PowerShell would otherwise write the console's code page.
$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($answer|ConvertTo-Json -Depth 24 -Compress)+"`n")
$out=[Console]::OpenStandardOutput()
$out.Write($bytes,0,$bytes.Length);$out.Flush()
exit 0
