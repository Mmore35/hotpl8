# Diagnostic fields are allowlisted; native credentials and provider output are never exported.
function Write-Hotpl8Event([string]$Directory, [string]$Code) {
    try {
        $path = Join-Path $Directory 'events.jsonl'
        if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 262144) {
            [IO.File]::Copy($path, $path+'.1', $true)
            [IO.File]::WriteAllText($path, '')
        }
        $row = @{ at=[datetimeoffset]::UtcNow.ToString('o'); code=$Code } | ConvertTo-Json -Compress
        [IO.File]::AppendAllText($path, $row+[Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    } catch { }
}
function Get-Hotpl8Doctor([string]$StateDirectory) {
    $policy = Read-Hotpl8Json (Join-Path $StateDirectory 'policy.json')
    $valid = $false
    try { Assert-Hotpl8Policy $policy; if ($policy.codex.slots) { Assert-CodexPolicy $policy.codex }; $valid=$true } catch { }
    $status = Read-Hotpl8Json (Join-Path $StateDirectory 'status.json')
    $age = $null
    try { $age=[Math]::Round(([datetimeoffset]::UtcNow-[datetimeoffset]::Parse($status.generatedAt)).TotalSeconds) } catch { }
    $codexFound=$false
    try { $null=Resolve-CodexExecutable ''; $codexFound=$true } catch { }
    $cswapFound=$false
    try { $cswapFound=[bool](Resolve-CswapExecutable '') } catch { }
    $locked=$false; $lock=$null
    # Do not create a lock or any other file during a doctor read.
    if (Test-Path -LiteralPath (Join-Path $StateDirectory 'tick.lock')) {
        try { $lock=[IO.File]::Open((Join-Path $StateDirectory 'tick.lock'),'Open','ReadWrite','None') }
        catch { $locked=$true }
        finally { if($lock){$lock.Dispose()} }
    }
    return [pscustomobject]@{
        version=(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
        runtime=$PSVersionTable.PSVersion.ToString()
        policyPresent=(Test-Path -LiteralPath (Join-Path $StateDirectory 'policy.json'))
        policyValid=$valid
        mode=$(if($policy.mode){$policy.mode}else{'legacy'})
        claudeConfigured=[bool]$policy.prefer
        codexConfigured=[bool]$policy.codex.slots
        cswapFound=$cswapFound
        codexFound=$codexFound
        snapshotAgeSeconds=$age
        snapshotFresh=($null -ne $age -and $age -ge -5 -and $age -le 900)
        collectorBusy=$locked
    }
}
