# Offline stdio protocol tests: real PowerShell subprocesses, fictional state only.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
$script:passed = 0; $script:failed = 0
function Assert($Value) { if (-not $Value) { throw 'assertion failed' } }
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; 'PASS ' + $Name }
    catch { $script:failed++; 'FAIL ' + $Name + ': ' + $_.Exception.Message }
}
$dir = Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-mcp-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
$fixture = Join-Path $dir 'server.ps1'
$marker = Join-Path $dir 'marker.txt'
# The fixture dispatcher records live file content on every request. Transport
# tests must be independent of cached account selection and native executables.
$bootstrap = @'
param([string]$SourceRoot,[string]$Directory,[switch]$AllowAgentPause)
$ErrorActionPreference='Stop'
function Invoke-Hotpl8AgentRequest($Request,[string]$Directory,[bool]$AllowPause=$true) {
    if($Request.operation -eq 'doctor'){throw 'PRIVATE_EXCEPTION_AND_PATH'}
    $ok=$Request.operation -ne 'status'
    $errorData=if($ok){$null}else{@{code='fixture_unavailable';message='No observation.';retryable=$true}}
    $data=if($ok){@{marker=[IO.File]::ReadAllText((Join-Path $Directory 'marker.txt'));allowPause=$AllowPause;arguments=$Request.arguments}}else{$null}
    return [pscustomobject]@{apiVersion=1;ok=$ok;operation=$Request.operation;data=$data;error=$errorData;computedAt=[DateTime]::UtcNow.ToString('o')}
}
. (Join-Path $SourceRoot 'src/mcp.ps1')
Start-Hotpl8Mcp -Directory $Directory -AllowAgentPause:$AllowAgentPause
'@
[IO.File]::WriteAllText($fixture, $bootstrap)
[IO.File]::WriteAllText($marker, 'before')
function Start-TestMcp([switch]$AllowPause, [switch]$RealCli) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $all = @('-NoProfile','-ExecutionPolicy','Bypass','-File')
    if ($RealCli) { $all += @((Join-Path $root 'hotpl8.ps1'),'mcp','-StateDirectory',(Join-Path $dir 'empty')) }
    else { $all += @($fixture,'-SourceRoot',$root,'-Directory',$dir) }
    if ($AllowPause) { $all += '-AllowAgentPause' }
    $psi.Arguments = (@($all | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    # Reuse the UTF-8 JSON-lines process helper: .NET can flush a console BOM
    # during Process.Start, before any request is written.
    $proc = Start-CodexQuotaProcess $psi
    return $proc
}
function Send-McpLine($Proc, [string]$Line) {
    # MCP clients send UTF-8 without a preamble. The .NET Framework default
    # stdin writer inherits the console encoding and may inject a BOM in CI.
    $bytes = [Text.Encoding]::UTF8.GetBytes($Line + "`n")
    $Proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $Proc.StandardInput.BaseStream.Flush()
}
function Send-Mcp($Proc, $Message) {
    Send-McpLine $Proc (ConvertTo-Json -InputObject $Message -Compress -Depth 20)
}
function Read-Mcp($Proc) {
    # Bounds a hang, not response latency: a server cold start on a loaded hosted
    # runner measured 75s once the suites began running concurrently, and the
    # abandoned read then poisons the stream for every later request.
    $pending = $Proc.StandardOutput.ReadLineAsync()
    if (-not $pending.Wait(180000)) { throw 'MCP response timed out' }
    if ($null -eq $pending.Result) { throw ('Unexpected MCP EOF: ' + $Proc.StandardError.ReadToEnd()) }
    return (ConvertFrom-Json -InputObject $pending.Result)
}
function Request-Mcp($Proc, [string]$Method, $Params = @{}, $Id = 1) {
    Send-Mcp $Proc @{ jsonrpc = '2.0'; id = $Id; method = $Method; params = $Params }
    return (Read-Mcp $Proc)
}
function Initialize-Mcp($Proc, [string]$Version = '2025-11-25') {
    $r = Request-Mcp $Proc 'initialize' @{ protocolVersion = $Version; capabilities = @{}; clientInfo = @{ name = 'offline-fixture'; version = '1' } }
    Send-Mcp $Proc @{ jsonrpc = '2.0'; method = 'notifications/initialized' }
    return $r
}
function Stop-TestMcp($Proc) {
    $Proc.StandardInput.BaseStream.Close()
    if (-not $Proc.WaitForExit(180000)) { $Proc.Kill(); throw 'MCP did not exit on EOF' }
    $extra = $Proc.StandardOutput.ReadToEnd(); $errorText = $Proc.StandardError.ReadToEnd()
    Assert ($Proc.ExitCode -eq 0 -and -not $extra -and -not $errorText)
    $Proc.Dispose()
}
$processes = @()
try {
    $proc = Start-TestMcp; $processes += $proc
    Check 'tools unavailable until initialize and initialized notification complete' {
        Assert ((Request-Mcp $proc 'tools/list').error.code -eq -32600)
        Assert ((Request-Mcp $proc 'initialize' @{ protocolVersion = '2025-11-25'; capabilities = @(); clientInfo = @{ name = 'test'; version = '1' } }).error.code -eq -32602)
        $r = Request-Mcp $proc 'initialize' @{ protocolVersion = '2025-11-25'; capabilities = @{}; clientInfo = @{ name = 'test'; version = '1' } }
        Assert ($r.result.protocolVersion -eq '2025-11-25' -and $r.result.capabilities.tools -and -not $r.result.capabilities.resources)
        Assert ((Request-Mcp $proc 'tools/list').error.code -eq -32600)
        Send-Mcp $proc @{ jsonrpc = '2.0'; method = 'notifications/initialized' }
        Assert ((Request-Mcp $proc 'tools/list').result.tools.Count -eq 2)
    }
    Check 'schemas are constrained and default tools read-only' {
        $r = Request-Mcp $proc 'tools/list'
        $inspect = $r.result.tools | Where-Object name -eq 'hotpl8_inspect'
        $readiness = $r.result.tools | Where-Object name -eq 'hotpl8_readiness'
        Assert ($inspect.annotations.readOnlyHint -and -not $inspect.inputSchema.additionalProperties -and $inspect.inputSchema.required -contains 'view')
        Assert ($inspect.inputSchema.properties.view.enum.Count -eq 5 -and $inspect.outputSchema.required.Count -eq 6)
        Assert ($readiness.inputSchema.properties.provider.enum -contains 'codex' -and $readiness.inputSchema.properties.model.maxLength -eq 100)
        Assert ((Request-Mcp $proc 'tools/call' @{ name = 'hotpl8_pause_release'; arguments = @{ leaseId = [guid]::NewGuid().ToString() } }).error.code -eq -32602)
    }
    Check 'successful results carry matching structured JSON text and string IDs' {
        $r = Request-Mcp $proc 'tools/call' @{ name = 'hotpl8_inspect'; arguments = @{ view = 'capabilities' } } 'read-1'
        $textResult = $r.result.content[0].text | ConvertFrom-Json
        Assert ($r.id -ceq 'read-1' -and -not $r.result.isError -and $textResult.ok -and $textResult.operation -eq 'capabilities')
        Assert ($r.result.structuredContent.data.marker -eq 'before' -and -not $r.result.structuredContent.data.allowPause)
    }
    Check 'persistent process observes changed state on its next in-process call' {
        [IO.File]::WriteAllText($marker, 'after')
        $r = Request-Mcp $proc 'tools/call' @{ name = 'hotpl8_readiness'; arguments = @{ provider = 'codex'; model = 'fixture-model' } }
        Assert ($r.result.structuredContent.data.marker -eq 'after' -and $r.result.structuredContent.data.arguments.model -eq 'fixture-model')
    }
    Check 'operational failure is a tool error and unexpected exceptions are redacted' {
        $r = Request-Mcp $proc 'tools/call' @{ name = 'hotpl8_inspect'; arguments = @{ view = 'status' } }
        Assert ($r.result.isError -and $r.result.structuredContent.error.code -eq 'fixture_unavailable' -and -not $r.error)
        $r = Request-Mcp $proc 'tools/call' @{ name = 'hotpl8_inspect'; arguments = @{ view = 'doctor' } }
        Assert ($r.result.isError -and $r.result.structuredContent.error.code -eq 'internal_error')
        Assert (($r | ConvertTo-Json -Depth 20) -notmatch 'PRIVATE_EXCEPTION')
    }
    Check 'notifications never receive responses and ping IDs remain aligned' {
        Send-Mcp $proc @{ jsonrpc = '2.0'; method = 'unknown-notification' }
        Send-Mcp $proc @{ jsonrpc = '2.0'; method = 'tools/call'; params = @{ name = 'hotpl8_inspect'; arguments = @{ view = 'status' } } }
        Send-Mcp $proc @{ jsonrpc = '2.0'; method = 'ping'; params = @() }
        Assert ((Request-Mcp $proc 'ping' @{} 88).id -eq 88)
    }
    Check 'malformed JSON, batches, invalid IDs, params and unknown methods recover' {
        Send-McpLine $proc '{'
        Assert ((Read-Mcp $proc).error.code -eq -32700)
        Send-McpLine $proc '[{"jsonrpc":"2.0","id":1,"method":"ping"}]'
        Assert ((Read-Mcp $proc).error.code -eq -32600)
        Send-Mcp $proc @{ jsonrpc = '2.0'; id = $true; method = 'ping' }
        Assert ((Read-Mcp $proc).error.code -eq -32600)
        Send-Mcp $proc @{ jsonrpc = '2.0'; id = $null; method = 'ping' }
        Assert ((Read-Mcp $proc).error.code -eq -32600)
        Send-Mcp $proc @{ jsonrpc = 2; id = 1; method = 'ping' }
        Assert ((Read-Mcp $proc).error.code -eq -32600)
        Assert ((Request-Mcp $proc 'ping' @()).error.code -eq -32602)
        Assert ((Request-Mcp $proc 'ping' @{ _meta = @() }).error.code -eq -32602)
        Assert ((Request-Mcp $proc 'tools/call' @{ name = 'hotpl8_inspect'; arguments = @{ view = 'accounts'; surprise = 1 } }).error.code -eq -32602)
        Assert ((Request-Mcp $proc 'tools/call' @{ name = 'hotpl8_inspect'; arguments = @() }).error.code -eq -32602)
        Assert ((Request-Mcp $proc 'tools/call' @{ name = 'hotpl8_inspect'; arguments = @{ view = @('accounts') } }).error.code -eq -32602)
        Assert ((Request-Mcp $proc 'tools/list' @{ cursor = 'unsupported' }).error.code -eq -32602)
        Assert ((Request-Mcp $proc 'resources/list').error.code -eq -32601)
        Assert ((Request-Mcp $proc 'ping' @{} 99).id -eq 99)
    }
    Check 'oversized lines and multibyte UTF-8 recover without extra output' {
        Send-McpLine $proc ('x' * 65537)
        Assert ((Read-Mcp $proc).error.code -eq -32700)
        # Write raw UTF-8 because Windows PowerShell's redirected input writer
        # otherwise uses the console OEM encoding.
        $bytes = [Text.Encoding]::UTF8.GetBytes(('"' + ([string][char]0x00e9 * 33000) + '"' + "`n"))
        $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $proc.StandardInput.BaseStream.Flush()
        Assert ((Read-Mcp $proc).error.code -eq -32700)
        $invalid = [byte[]]@(255,10)
        $proc.StandardInput.BaseStream.Write($invalid, 0, $invalid.Length)
        $proc.StandardInput.BaseStream.Flush()
        Assert ((Read-Mcp $proc).error.code -eq -32700)
        Assert ((Request-Mcp $proc 'ping' @{} 100).id -eq 100)
    }
    Check 'repeat initialization is rejected and EOF exits cleanly' {
        Assert ((Request-Mcp $proc 'initialize').error.code -eq -32600)
        Stop-TestMcp $proc
    }
    $enabled = Start-TestMcp -AllowPause; $processes += $enabled
    Check 'older supported version negotiates and opt-in exposes bounded pause tools' {
        Assert ((Initialize-Mcp $enabled '2025-06-18').result.protocolVersion -eq '2025-06-18')
        $r = Request-Mcp $enabled 'tools/list'
        Assert ($r.result.tools.Count -eq 4)
        $acquire = $r.result.tools | Where-Object name -eq 'hotpl8_pause_acquire'
        Assert (-not $acquire.annotations.readOnlyHint -and $acquire.annotations.idempotentHint)
        Assert ($acquire.inputSchema.properties.minutes.minimum -eq 1 -and $acquire.inputSchema.properties.minutes.maximum -eq 1440)
        Assert ($acquire.inputSchema.properties.owner.maxLength -eq 80 -and $acquire.inputSchema.properties.leaseId.format -eq 'uuid')
        $id = [guid]::NewGuid().ToString()
        $r = Request-Mcp $enabled 'tools/call' @{ name = 'hotpl8_pause_acquire'; arguments = @{ leaseId = $id; owner = 'fixture-agent'; minutes = 10 } }
        Assert ($r.result.structuredContent.operation -eq 'pause.acquire' -and $r.result.structuredContent.data.allowPause)
        $r = Request-Mcp $enabled 'tools/call' @{ name = 'hotpl8_pause_release'; arguments = @{ leaseId = $id } }
        Assert ($r.result.structuredContent.operation -eq 'pause.release')
        Stop-TestMcp $enabled
    }
    $real = Start-TestMcp -RealCli; $processes += $real
    Check 'real CLI negotiates fallback and shared capabilities dispatch without state writes' {
        Assert ((Initialize-Mcp $real 'unsupported-version').result.protocolVersion -eq '2025-11-25')
        $r = Request-Mcp $real 'tools/call' @{ name = 'hotpl8_inspect'; arguments = @{ view = 'capabilities' } }
        Assert ($r.result.structuredContent.apiVersion -eq 1 -and $r.result.structuredContent.ok -and -not $r.result.isError)
        $r = Request-Mcp $real 'tools/call' @{ name = 'hotpl8_inspect'; arguments = @{ view = 'doctor' } }
        Assert ($r.result.structuredContent.ok)
        $r = Request-Mcp $real 'tools/call' @{ name = 'hotpl8_readiness'; arguments = @{ provider = 'codex'; model = 'bad/model' } }
        Assert ($r.result.isError -and $r.result.structuredContent.error.code -eq 'invalid_arguments')
        $r = Request-Mcp $real 'tools/call' @{ name = 'hotpl8_readiness'; arguments = @{ provider = @('codex') } }
        Assert ($r.result.isError -and $r.result.structuredContent.error.code -eq 'invalid_arguments')
        Assert (-not (Test-Path (Join-Path $dir 'empty')) -or @(Get-ChildItem (Join-Path $dir 'empty') -Force).Count -eq 0)
    }
    Check 'real persistent dispatcher observes newly created policy without restart' {
        [void][IO.Directory]::CreateDirectory((Join-Path $dir 'empty'))
        Copy-Item -LiteralPath (Join-Path $root 'policy.example.json') -Destination (Join-Path $dir 'empty/policy.json')
        $before = (Get-FileHash (Join-Path $dir 'empty/policy.json')).Hash
        $r = Request-Mcp $real 'tools/call' @{ name = 'hotpl8_inspect'; arguments = @{ view = 'doctor' } }
        Assert ($r.result.structuredContent.ok -and $r.result.structuredContent.data.policyPresent -and $r.result.structuredContent.data.policyValid)
        $r = Request-Mcp $real 'tools/call' @{ name = 'hotpl8_inspect'; arguments = @{ view = 'accounts' } }
        Assert ($r.result.structuredContent.ok -and $r.result.structuredContent.data.accounts.Count -eq 0)
        Assert ((Get-FileHash (Join-Path $dir 'empty/policy.json')).Hash -eq $before -and @(Get-ChildItem (Join-Path $dir 'empty') -Force).Count -eq 1)
        Stop-TestMcp $real
    }
    $realWriter = Start-TestMcp -RealCli -AllowPause; $processes += $realWriter
    Check 'real opt-in CLI acquires and releases a fixture lease through shared API' {
        $null = Initialize-Mcp $realWriter
        $leaseId = [guid]::NewGuid().ToString()
        $leaseArgs = @{ leaseId = $leaseId; owner = 'offline-agent'; minutes = 3 }
        $r = Request-Mcp $realWriter 'tools/call' @{ name = 'hotpl8_pause_acquire'; arguments = $leaseArgs }
        Assert ($r.result.structuredContent.ok -and -not $r.result.isError)
        $ledger = Get-Content -LiteralPath (Join-Path $dir 'empty/automation-leases.json') -Raw | ConvertFrom-Json
        Assert ($ledger.entries.Count -eq 1 -and $ledger.entries[0].leaseId -eq $leaseId -and -not $ledger.entries[0].releasedAt)
        $r = Request-Mcp $realWriter 'tools/call' @{ name = 'hotpl8_pause_release'; arguments = @{ leaseId = $leaseId } }
        Assert ($r.result.structuredContent.ok)
        $ledger = Get-Content -LiteralPath (Join-Path $dir 'empty/automation-leases.json') -Raw | ConvertFrom-Json
        Assert ($ledger.entries[0].releasedAt)
        Stop-TestMcp $realWriter
    }
} finally {
    foreach ($p in $processes) {
        try { if (-not $p.HasExited) { $p.Kill() }; $p.Dispose() } catch { }
    }
    # The test owns only this uniquely named temporary fixture directory.
    $resolved = [IO.Path]::GetFullPath($dir)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup escaped temp root.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
"MCP: $script:passed passed, $script:failed failed."
if ($script:failed) { exit 1 }
