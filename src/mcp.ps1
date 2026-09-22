# Local, dependency-free MCP transport. All product operations use the shared API.
. (Join-Path $PSScriptRoot 'provider-registry.ps1')
function Test-Hotpl8McpObject($Value) {
    return ($null -ne $Value -and ($Value -is [System.Management.Automation.PSCustomObject] -or $Value -is [System.Collections.IDictionary]))
}

function Test-Hotpl8McpFields($Value, [string[]]$Allowed, [string[]]$Required = @()) {
    if (-not (Test-Hotpl8McpObject $Value)) { return $false }
    $names = if ($Value -is [System.Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
    foreach ($name in $names) { if ($name -cnotin $Allowed) { return $false } }
    foreach ($name in $Required) { if ($name -cnotin $names) { return $false } }
    return $true
}

function Get-Hotpl8McpTools([bool]$AllowPause) {
    $outputSchema = @{
        type = 'object'; additionalProperties = $false
        required = @('apiVersion','ok','operation','data','error','computedAt')
        properties = @{
            apiVersion = @{ type = 'integer'; const = 1 }; ok = @{ type = 'boolean' }
            operation = @{ type = @('string','null') }; data = @{ type = @('object','null') }
            error = @{ type = @('object','null'); additionalProperties = $false; required = @('code','message','retryable'); properties = @{
                code = @{ type = 'string' }; message = @{ type = 'string' }; retryable = @{ type = 'boolean' }
            } }
            computedAt = @{ type = 'string'; format = 'date-time' }
        }
    }
    $readAnnotations = @{ readOnlyHint = $true; destructiveHint = $false; idempotentHint = $true; openWorldHint = $false }
    @{
        name = 'hotpl8_inspect'; description = 'Inspect redacted local cached state. Does not collect quota or contact providers.'
        inputSchema = @{ type = 'object'; additionalProperties = $false; required = @('view'); properties = @{
            view = @{ type = 'string'; enum = @('status','explain','capabilities','doctor','accounts') }
        } }; outputSchema = $outputSchema; annotations = $readAnnotations
    }
    @{
        name = 'hotpl8_readiness'; description = 'Check current cached account eligibility. Does not reserve capacity, launch work, or validate native authentication. Model mapping depends on the registered native driver.'
        inputSchema = @{ type = 'object'; additionalProperties = $false; required = @('provider'); properties = @{
            provider = @{ type = 'string'; enum = @(Get-Hotpl8ProviderCatalog|ForEach-Object id) }; model = @{ type = 'string'; minLength = 1; maxLength = 100; pattern = '^[a-zA-Z0-9_.-]{1,100}$' }
        } }; outputSchema = $outputSchema; annotations = $readAnnotations
    }
    if ($AllowPause) {
        $leaseSchema = @{ type = 'string'; format = 'uuid'; pattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' }
        $writeAnnotations = @{ readOnlyHint = $false; destructiveHint = $false; idempotentHint = $true; openWorldHint = $false }
        @{
            name = 'hotpl8_pause_acquire'; description = 'Pause automation using a caller-generated UUID persisted before this call. Retrying the same parameters does not extend expiry. Existing work continues.'
            inputSchema = @{ type = 'object'; additionalProperties = $false; required = @('leaseId','owner','minutes'); properties = @{
                leaseId = $leaseSchema; owner = @{ type = 'string'; minLength = 1; maxLength = 80; pattern = '^[^\u0000-\u001f\u007f]+$' }
                minutes = @{ type = 'integer'; minimum = 1; maximum = 1440 }
            } }; outputSchema = $outputSchema; annotations = $writeAnnotations
        }
        @{
            name = 'hotpl8_pause_release'; description = 'Release only the supplied pause UUID. Repeat-safe; other agent and manual pauses remain effective.'
            inputSchema = @{ type = 'object'; additionalProperties = $false; required = @('leaseId'); properties = @{ leaseId = $leaseSchema } }
            outputSchema = $outputSchema; annotations = $writeAnnotations
        }
    }
}

function Write-Hotpl8McpMessage($Writer, $Message) {
    $Writer.WriteLine((ConvertTo-Json -InputObject $Message -Depth 40 -Compress))
    $Writer.Flush()
}

function Write-Hotpl8McpError($Writer, $Id, [int]$Code, [string]$Message) {
    Write-Hotpl8McpMessage $Writer @{ jsonrpc = '2.0'; id = $Id; error = @{ code = $Code; message = $Message } }
}

function Read-Hotpl8McpLine($Stream) {
    # Read bytes, not ReadLine(): oversized input must not allocate an unbounded
    # string. Discard through the next newline so the following request recovers.
    $buffer = New-Object byte[] 65536
    $count = 0; $oversized = $false
    while ($true) {
        $next = $Stream.ReadByte()
        if ($next -eq -1) {
            if ($count -eq 0 -and -not $oversized) { return $null }
            break
        }
        if ($next -eq 10) { break }
        if ($count -lt $buffer.Length) { $buffer[$count] = [byte]$next; $count++ } else { $oversized = $true }
    }
    if ($oversized) { return @{ error = 'Request exceeds 64 KiB.' } }
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        return @{ text = $encoding.GetString($buffer, 0, $count) }
    } catch { return @{ error = 'Invalid UTF-8.' } }
}

function Start-Hotpl8Mcp([string]$Directory, [switch]$AllowAgentPause) {
    $stream = [Console]::OpenStandardInput()
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = New-Object IO.StreamWriter([Console]::OpenStandardOutput(), $encoding)
    $writer.NewLine = "`n"
    $initialized = $false; $initializing = $false
    $tools = @(Get-Hotpl8McpTools ([bool]$AllowAgentPause))
    try {
        while ($true) {
            $line = Read-Hotpl8McpLine $stream
            if ($null -eq $line) { break }
            if ($line.error) { Write-Hotpl8McpError $writer $null -32700 $line.error; continue }
            try { $request = ConvertFrom-Json -InputObject $line.text -ErrorAction Stop }
            catch { Write-Hotpl8McpError $writer $null -32700 'Parse error.'; continue }
            if (-not (Test-Hotpl8McpObject $request)) { Write-Hotpl8McpError $writer $null -32600 'Invalid request.'; continue }
            $hasId = @($request.PSObject.Properties.Name) -ccontains 'id'
            $id = $request.id
            $validId = (-not $hasId -or $id -is [string] -or $id -is [int] -or $id -is [long] -or $id -is [decimal] -or ($id -is [double] -and -not [double]::IsNaN($id) -and -not [double]::IsInfinity($id)))
            if (-not $validId) { Write-Hotpl8McpError $writer $null -32600 'Invalid request ID.'; continue }
            if ($request.jsonrpc -isnot [string] -or $request.jsonrpc -cne '2.0' -or $request.method -isnot [string] -or -not $request.method -or -not (Test-Hotpl8McpFields $request @('jsonrpc','id','method','params') @('jsonrpc','method'))) {
                Write-Hotpl8McpError $writer $null -32600 'Invalid request.'; continue
            }
            $hasParams = @($request.PSObject.Properties.Name) -ccontains 'params'
            $params = if ($hasParams) { $request.params } else { [pscustomobject]@{} }
            # Notifications never receive responses, including unknown methods.
            if (-not $hasId) {
                if ($request.method -ceq 'notifications/initialized' -and $initializing -and (Test-Hotpl8McpFields $params @('_meta'))) { $initialized = $true; $initializing = $false }
                continue
            }
            if (-not (Test-Hotpl8McpObject $params) -or (@($params.PSObject.Properties.Name) -ccontains '_meta' -and -not (Test-Hotpl8McpObject $params._meta))) { Write-Hotpl8McpError $writer $id -32602 'Invalid params.'; continue }
            $result = $null
            if ($request.method -ceq 'initialize') {
                if ($initialized -or $initializing) { Write-Hotpl8McpError $writer $id -32600 'Already initialized.'; continue }
                if (-not (Test-Hotpl8McpFields $params @('protocolVersion','capabilities','clientInfo','_meta') @('protocolVersion','capabilities','clientInfo')) -or
                    $params.protocolVersion -isnot [string] -or -not (Test-Hotpl8McpObject $params.capabilities) -or
                    -not (Test-Hotpl8McpObject $params.clientInfo) -or $params.clientInfo.name -isnot [string] -or $params.clientInfo.version -isnot [string]) {
                    Write-Hotpl8McpError $writer $id -32602 'Invalid initialize params.'; continue
                }
                $version = if ($params.protocolVersion -cin @('2025-11-25','2025-06-18')) { $params.protocolVersion } else { '2025-11-25' }
                $result = @{ protocolVersion = $version; capabilities = @{ tools = @{} }; serverInfo = @{ name = 'hotpl8'; version = '1' } }
                $initializing = $true
            } elseif ($request.method -ceq 'ping') {
                if (-not (Test-Hotpl8McpFields $params @('_meta'))) { Write-Hotpl8McpError $writer $id -32602 'Invalid ping params.'; continue }
                $result = @{}
            } elseif ($request.method -cin @('tools/list','tools/call')) {
                if (-not $initialized) { Write-Hotpl8McpError $writer $id -32600 'Initialization is not complete.'; continue }
                if ($request.method -ceq 'tools/list') {
                    if (-not (Test-Hotpl8McpFields $params @('_meta'))) { Write-Hotpl8McpError $writer $id -32602 'Invalid tools/list params.'; continue }
                    $result = @{ tools = $tools }
                } else {
                    if (-not (Test-Hotpl8McpFields $params @('name','arguments','_meta') @('name')) -or $params.name -isnot [string]) { Write-Hotpl8McpError $writer $id -32602 'Invalid tools/call params.'; continue }
                    if ($params.name -cnotin @($tools | ForEach-Object { $_.name })) { Write-Hotpl8McpError $writer $id -32602 'Unknown or disabled tool.'; continue }
                    $arguments = if (@($params.PSObject.Properties.Name) -ccontains 'arguments') { $params.arguments } else { [pscustomobject]@{} }
                    if (-not (Test-Hotpl8McpObject $arguments)) { Write-Hotpl8McpError $writer $id -32602 'Tool arguments must be an object.'; continue }
                    $operation = switch -CaseSensitive ($params.name) {
                        'hotpl8_inspect' { $arguments.view }
                        'hotpl8_readiness' { 'readiness' }
                        'hotpl8_pause_acquire' { 'pause.acquire' }
                        'hotpl8_pause_release' { 'pause.release' }
                    }
                    if ($params.name -ceq 'hotpl8_inspect') {
                        if (-not (Test-Hotpl8McpFields $arguments @('view') @('view')) -or $arguments.view -isnot [string] -or $arguments.view -cnotin @('status','explain','capabilities','doctor','accounts')) {
                            Write-Hotpl8McpError $writer $id -32602 'Invalid inspect view.'; continue
                        }
                        $arguments = [pscustomobject]@{}
                    }
                    try {
                        $envelope = Invoke-Hotpl8AgentRequest -Request ([pscustomobject]@{ apiVersion = 1; operation = $operation; arguments = $arguments }) -Directory $Directory -AllowPause ([bool]$AllowAgentPause)
                    } catch {
                        # Do not leak exception paths, provider output, or lease capabilities.
                        $envelope = [pscustomobject]@{ apiVersion = 1; ok = $false; operation = $operation; data = $null; error = @{ code = 'internal_error'; message = 'The operation could not be completed.'; retryable = $false }; computedAt = [DateTime]::UtcNow.ToString('o') }
                    }
                    $result = @{ content = @(@{ type = 'text'; text = (ConvertTo-Json -InputObject $envelope -Depth 40 -Compress) }); structuredContent = $envelope; isError = (-not $envelope.ok) }
                }
            } else { Write-Hotpl8McpError $writer $id -32601 'Method not found.'; continue }
            Write-Hotpl8McpMessage $writer @{ jsonrpc = '2.0'; id = $id; result = $result }
        }
    } finally { $writer.Flush(); $writer.Dispose(); $stream.Dispose() }
}
