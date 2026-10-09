# Native Codex owns login and refresh. An account's limits and identity are read by the
# compiled program, and its policy is validated there: rules.ps1 asks, and defines
# Read-CodexQuota and Assert-CodexPolicy. What is left here is the conversation sign-in holds.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'rules.ps1')
function Invoke-CodexRpc($Process, $Clock, [int]$TimeoutMs, [int]$Id, [string]$Method, $Params) {
    $request = @{ id = $Id; method = $Method }
    if ($null -ne $Params) { $request.params = $Params }
    $Process.StandardInput.WriteLine(($request | ConvertTo-Json -Depth 8 -Compress))
    $Process.StandardInput.Flush()
    while ($Clock.ElapsedMilliseconds -lt $TimeoutMs) {
        $lineTask = $Process.StandardOutput.ReadLineAsync()
        $left = [Math]::Max(1, $TimeoutMs - [int]$Clock.ElapsedMilliseconds)
        if (-not $lineTask.Wait($left)) { throw 'timeout' }
        $line = $lineTask.Result
        if ($null -eq $line) { throw 'process_exited' }
        if ($line.Length -gt 1048576) { throw 'response_too_large' }
        try { $message = $line.TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop }
        catch { throw 'invalid_json' }
        if ($null -eq $message.id -or [string]$message.id -ne [string]$Id) { continue }
        if ($message.error) {
            # Never expose a server's free-text error, which may contain credentials.
            switch ([string]$message.error.code) {
                '-32600' { throw 'authentication_required' }
                '401' { throw 'authentication_required' }
                '403' { throw 'access_denied' }
                '429' { throw 'rate_limited' }
                default { throw 'rpc_failed' }
            }
        }
        if (-not $message.PSObject.Properties['result']) { throw 'invalid_response' }
        return $message.result
    }
    throw 'timeout'
}

