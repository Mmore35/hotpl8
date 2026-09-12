# Small shared file/process primitives. No authentication ownership.
function ConvertTo-Hotpl8SafeText([string]$Value) {
    return [regex]::Replace($Value, '[\x00-\x1f\x7f]', '')
}
function Invoke-Hotpl8Process([string]$Executable, [string[]]$Arguments, [int]$TimeoutMs=20000) {
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$Executable
    $psi.Arguments=(@($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    if ([IO.Path]::GetExtension($Executable) -in @('.cmd','.bat')) {
        # Batch shims accept only fixed cswap verbs and numeric slots.
        if ($Executable -match '["%&|<>!^\r\n]' -or ($Arguments -join ' ') -notmatch '^(list --json|switch [0-9]+|run [0-9]+ -- claude --model haiku --strict-mcp-config -p \.)$') { throw 'unsupported_batch_arguments' }
        $psi.FileName=Join-Path $env:SystemRoot 'System32/cmd.exe'
        $psi.Arguments='/d /s /c ""'+$Executable+'" '+($Arguments -join ' ')+'"'
    }
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $proc=$null; $clock=[Diagnostics.Stopwatch]::StartNew()
    try {
        $proc=[Diagnostics.Process]::Start($psi)
        $out=New-Object Text.StringBuilder
        $streams=@(
            @{reader=$proc.StandardOutput; buffer=(New-Object char[] 4096); task=$null; done=$false; keep=$true; count=0},
            @{reader=$proc.StandardError; buffer=(New-Object char[] 4096); task=$null; done=$false; keep=$false; count=0}
        )
        while ($true) {
            if ($clock.ElapsedMilliseconds -gt $TimeoutMs) { throw 'process_timeout' }
            foreach ($s in $streams) {
                if ($s.done) { continue }
                if (-not $s.task) { $s.task=$s.reader.ReadAsync($s.buffer,0,$s.buffer.Length) }
                if ($s.task.IsCompleted) {
                    $n=$s.task.GetAwaiter().GetResult(); $s.task=$null
                    if ($n -eq 0) { $s.done=$true; continue }
                    $s.count+=$n
                    if ($s.count -gt 1048576) { throw 'process_output_limit' }
                    if ($s.keep) { [void]$out.Append($s.buffer,0,$n) }
                }
            }
            if ($streams[0].done -and $streams[1].done -and $proc.HasExited) { break }
            Start-Sleep -Milliseconds 5
        }
        return [pscustomobject]@{exitCode=$proc.ExitCode; output=$out.ToString()}
    } finally { Stop-Hotpl8Process $proc }
}
function Write-Hotpl8Text([string]$Path, [string]$Text, [switch]$NoBom) {
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, $Text, (New-Object Text.UTF8Encoding(-not $NoBom)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Read-Hotpl8Json([string]$Path) {
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { return $null }
}
function Test-Hotpl8Number($Value) {
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string]) { return $false }
    try { $v = [double]$Value; return -not ([double]::IsNaN($v) -or [double]::IsInfinity($v)) }
    catch { return $false }
}
function Get-Hotpl8Hash([string]$Value) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
}
function ConvertTo-NativeArgument([string]$Value) {
    # Windows CRT quoting, also understood by .NET's Unix Arguments parser.
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Resolve-CodexExecutable([string]$Explicit) {
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) { throw 'codex_missing' }
        if ([IO.Path]::GetExtension($Explicit) -in @('.cmd','.bat','.ps1')) { throw 'native_codex_required' }
        return [IO.Path]::GetFullPath($Explicit)
    }
    $commands = @(Get-Command codex.exe,codex -All -ErrorAction SilentlyContinue)
    foreach ($c in $commands) {
        if ($c.Source -and [IO.Path]::GetExtension($c.Source) -eq '.exe') { return $c.Source }
    }
    # Resolve the native binary beside the npm shim, without a versioned Node path
    # or cmd.exe re-parsing user arguments. Only the installed package is searched.
    $bases = @($commands | Where-Object Source | ForEach-Object { Split-Path $_.Source -Parent })
    $bases += @('/usr/local/lib', '/opt/homebrew/lib')
    foreach ($b in @($bases | Select-Object -Unique)) {
        $package = Join-Path $b 'node_modules/@openai/codex'
        if (-not (Test-Path -LiteralPath $package)) { continue }
        $name = if ($env:OS -eq 'Windows_NT') { 'codex.exe' } else { 'codex' }
        $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'aarch64' } else { 'x86_64' }
        $found = @(Get-ChildItem -LiteralPath $package -Recurse -File -Filter $name -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match $arch })
        if ($found.Count -eq 1) { return $found[0].FullName }
    }
    if ($env:OS -ne 'Windows_NT') {
        foreach ($c in $commands) {
            if ($c.Source -and [IO.Path]::GetExtension($c.Source) -eq '') { return $c.Source }
        }
    }
    throw 'codex_missing'
}
function New-CodexProcessInfo([string]$Executable, [string]$AccountHome, [string[]]$Arguments, [string]$WorkingDirectory) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $psi.Arguments = (@($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['CODEX_HOME'] = $AccountHome
    # No process-global environment changes. Native authentication owns this home.
    return $psi
}
function Start-CodexQuotaProcess($StartInfo) {
    # JSON-lines stdin is UTF-8 without a BOM, independent of the terminal locale.
    # .NET Framework lacks StandardInputEncoding and constructs the pipe writer
    # from Console.InputEncoding, flushing its preamble during Process.Start.
    # Limit the compatibility override to construction and always restore it.
    $utf8=New-Object Text.UTF8Encoding($false)
    if($StartInfo.PSObject.Properties['StandardInputEncoding']){
        $StartInfo.StandardInputEncoding=$utf8
        return [Diagnostics.Process]::Start($StartInfo)
    }
    $original=[Console]::InputEncoding
    try{[Console]::InputEncoding=$utf8;return [Diagnostics.Process]::Start($StartInfo)}
    finally{[Console]::InputEncoding=$original}
}
function Stop-Hotpl8Process($Process) {
    if (-not $Process) { return }
    try {
        if (-not $Process.HasExited) {
            try { $Process.StandardInput.Close() } catch { }
            if (-not $Process.WaitForExit(300)) {
                if ($env:OS -eq 'Windows_NT') {
                    $killer = New-Object Diagnostics.ProcessStartInfo
                    $killer.FileName = Join-Path $env:SystemRoot 'System32/taskkill.exe'
                    $killer.Arguments = '/PID ' + $Process.Id + ' /T /F'
                    $killer.UseShellExecute = $false; $killer.CreateNoWindow = $true
                    $killer.RedirectStandardOutput = $true; $killer.RedirectStandardError = $true
                    $k = [Diagnostics.Process]::Start($killer)
                    [void]$k.StandardOutput.ReadToEndAsync(); [void]$k.StandardError.ReadToEndAsync()
                    [void]$k.WaitForExit(1000); $k.Dispose()
                } else { $Process.Kill() }
            }
        }
    } catch { try { $Process.Kill() } catch { } }
    finally { $Process.Dispose() }
}
