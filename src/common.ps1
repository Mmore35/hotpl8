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
    try{return $text|ConvertFrom-Json -ErrorAction Stop}catch{return $null}
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

function Test-Hotpl8FreshTimestamp($Timestamp,[datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
    try{$age=($Now-[datetimeoffset]::Parse([string]$Timestamp)).TotalSeconds;return ($age -ge -5 -and $age -le 900)}catch{return $false}
}
function Resolve-Hotpl8Window($Used,$ResetAt,$ObservedAt,[datetimeoffset]$Now=[datetimeoffset]::UtcNow,[switch]$Unix) {
    # One rule for every elapsed reset, shared by both providers.
    #
    # observedAt < resetAt <= now: the provider itself told us this window ends
    # at a time that has since passed, so the window rolled over. cswap reports
    # exactly that state once it can be read again (pct=0 with an empty
    # resetsAt; verified 2026-08-09, see providers/claude.ps1) -- the refill is
    # the reported outcome arriving ahead of the next collector read, not a guess.
    #
    # resetAt <= observedAt: the payload handed us an anchor that was already
    # expired when we read it. That is genuinely suspect and keeps the
    # conservative unconfirmed handling.
    #
    # A missing or unreadable observation time leaves the reading alone too:
    # over-promising quota is worse than waiting one collector cycle. The
    # ordering test subsumes the dashboard's -5s clock-skew allowance -- an
    # observation stamped ahead of our clock can never satisfy
    # observedAt < resetAt <= now, so it never rolls over. A clock running
    # fast is bounded instead by the freshness ceiling, which expires the
    # reading and hands the account to the existing stale path.
    #
    # The same caution covers the reading itself. Rolling over replaces $Used
    # with a full window, so a missing or out-of-range percentage must never
    # be promoted to '100% free': callers gate on the returned used value, and
    # a literal would pass that gate on data the rest of hotpl8 calls unusable.
    $result=@{used=$Used;resetAt=$ResetAt;rolledOver=$false}
    if($null -eq $ResetAt -or [string]$ResetAt -eq ''){return $result}
    $at=$null
    try{$at=if($Unix){[datetimeoffset]::FromUnixTimeSeconds([long]$ResetAt)}else{[datetimeoffset]::Parse([string]$ResetAt)}}catch{return $result}
    if($at -gt $Now){return $result}
    if(-not (Test-Hotpl8Number $Used) -or [double]$Used -lt 0 -or [double]$Used -gt 100){return $result}
    $observed=$null
    try{if($ObservedAt){$observed=[datetimeoffset]::Parse([string]$ObservedAt)}}catch{}
    if($null -eq $observed -or $observed -ge $at){return $result}
    return @{used=0.0;resetAt=$null;rolledOver=$true}
}
