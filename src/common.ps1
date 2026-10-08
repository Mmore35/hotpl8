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
    return Invoke-Hotpl8ProcessInfo $psi $TimeoutMs
}
function Invoke-Hotpl8ProcessInfo($StartInfo,[int]$TimeoutMs=20000) {
    $proc=$null; $clock=[Diagnostics.Stopwatch]::StartNew()
    try {
        $proc=[Diagnostics.Process]::Start($StartInfo)
        if($StartInfo.RedirectStandardInput){$proc.StandardInput.Close()}
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
function Move-Hotpl8AtomicFile([string]$Source,[string]$Destination) {
    if ([IO.File]::Exists($Destination)) { [IO.File]::Replace($Source, $Destination, [NullString]::Value) }
    else { [IO.File]::Move($Source, $Destination) }
}
function Write-Hotpl8Text([string]$Path, [string]$Text, [switch]$NoBom) {
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $preserveTemp=$false
    try {
        [IO.File]::WriteAllText($temp, $Text, (New-Object Text.UTF8Encoding(-not $NoBom)))
        for($attempt=0;;$attempt++){
            try{
                Move-Hotpl8AtomicFile $temp $Path
                break
            }catch{
                $errorException=$_.Exception
                while($errorException.InnerException){$errorException=$errorException.InnerException}
                # Legacy viewers and third-party readers may omit FileShare.Delete.
                # ReplaceFile also reports 1175 when its delete phase is blocked;
                # Microsoft guarantees both original names survive that failure.
                # Retry these safe cases for at most one second. Never truncate.
                # 1176/1177 can leave a partially completed replacement: retain
                # its staging file for recovery instead of deleting the only copy.
                $ioCode=$errorException.HResult -band 65535
                $preserveTemp=$errorException -is [IO.IOException] -and $ioCode -in @(1176,1177)
                if($env:OS -ne 'Windows_NT' -or $errorException -isnot [IO.IOException] -or $ioCode -notin @(32,33,1175) -or $attempt -ge 40){
                    $_.Exception.Data['Hotpl8StateFile']=[IO.Path]::GetFileName($Path)
                    $_.Exception.Data['Hotpl8IoCode']=$errorException.HResult -band 65535
                    throw
                }
                Start-Sleep -Milliseconds 25
            }
        }
    } finally { if (-not $preserveTemp -and [IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Read-Hotpl8Json([string]$Path) {
    $stream=$null;$reader=$null
    try {
        # Atomic replacement needs delete sharing on Windows. Get-Content can
        # otherwise make a passive preview intermittently break its collector.
        $stream=[IO.File]::Open($Path,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
        $text=$reader.ReadToEnd()
    }
    catch { return $null }
    finally{if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
    # Parsing can be much slower than reading. Release the file first so the
    # collector never waits for dashboard JSON conversion to finish.
    try{return ConvertFrom-Hotpl8Json $text}catch{return $null}
}
function ConvertFrom-Hotpl8Json([string]$Text) {
    # Core PowerShell otherwise turns JSON timestamps into local DateTime values;
    # the Windows API contract requires their original strings and UTC suffixes.
    if($PSVersionTable.PSVersion -ge [version]'7.5'){return ConvertFrom-Json -InputObject $Text -DateKind String -ErrorAction Stop}
    return ConvertFrom-Json -InputObject $Text -ErrorAction Stop
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
function Copy-Hotpl8ProviderValue($Value) {
    # A wrapper plus the unary comma preserves empty and singleton arrays in
    # Windows PowerShell 5.1 without adding extended array properties.
    $json=ConvertTo-Json -InputObject ([pscustomobject]@{item=$Value}) -Depth 32
    $options=@{};if($PSVersionTable.PSVersion -ge [version]'7.5'){$options.DateKind='String'}
    $wrapper=ConvertFrom-Json -InputObject $json @options
    return ,$wrapper.item
}
function ConvertTo-NativeArgument([string]$Value) {
    # Windows CRT quoting, also understood by .NET's Unix Arguments parser.
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
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
                } else { $Process.Kill($true) }
            }
        }
    } catch { try { $Process.Kill() } catch { } }
    finally { $Process.Dispose() }
}

# Child PowerShell for tests and launchers: Windows PowerShell 5.1 where it exists, else pwsh.
# pwsh puts its own $PSHOME first on PATH. Under Homebrew that copy is a bare apphost that
# needs the DOTNET_ROOT its bin/ wrapper supplies and fails under launchd, so prefer any pwsh
# outside $PSHOME. An official package's $PSHOME pwsh runs standalone and remains the fallback.
function Get-Hotpl8PowerShell {
    if($env:OS -eq 'Windows_NT'){return (Get-Command powershell -CommandType Application | Select-Object -First 1).Source}
    $found=@(Get-Command pwsh -CommandType Application -All -ErrorAction Stop).Source
    $outside=@($found | Where-Object {[IO.Path]::GetDirectoryName($_) -ne $PSHOME.TrimEnd('/')})
    if($outside){$outside[0]}else{$found[0]}
}
# The user's home from the environment, so a test's isolated profile is honoured on every
# platform. USERPROFILE is Windows-only; HOME is the POSIX equivalent.
function Get-Hotpl8UserHome {
    if($env:USERPROFILE){return $env:USERPROFILE}
    if($env:HOME){return $env:HOME}
    throw 'Neither USERPROFILE nor HOME is set.'
}
