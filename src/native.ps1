# version, status, explain, what the tray shows, the dashboard (watch and nyan) and a Codex
# launch are the compiled reader's: PowerShell holds no implementation of them and hands each
# request to the reader this copy ships (native/, built by scripts/build-native.ps1). hotpl8.ps1 loads
# this before src/common.ps1, so it must stay self-contained: a plain request is only fast
# while it loads nothing it has no use for.
# That includes PowerShell's own modules: the first Join-Path, New-Object or Select-Object in
# a fresh Windows PowerShell loads one and costs 50 to 80 ms, so this file and the hand-over
# in hotpl8.ps1 call .NET directly.
# -Attended gives the reader this terminal as it is, keys and screen, and collects nothing.
# -Asked is the whole of what the program reads, and without it the program reads nothing.
function Invoke-Hotpl8NativeProcess([string]$Path,[string[]]$Arguments,[switch]$Attended,[string]$Asked) {
    $process=$null
    try{
        $info=[Diagnostics.ProcessStartInfo]::new()
        $info.FileName=$Path
        # Windows CRT quoting, also understood by .NET's Unix Arguments parser.
        $info.Arguments=(@($Arguments|ForEach-Object{
            if($_.Length -gt 0 -and $_ -notmatch '[\s"]'){$_}
            else{'"'+[regex]::Replace([regex]::Replace($_,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'}
        }) -join ' ')
        $info.UseShellExecute=$false
        if($Attended){
            $process=[Diagnostics.Process]::Start($info)
            $process.WaitForExit()
            return [pscustomobject]@{exitCode=$process.ExitCode;output='';errors=''}
        }
        $info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $info.RedirectStandardInput=$PSBoundParameters.ContainsKey('Asked')
        $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
        $process=[Diagnostics.Process]::Start($info)
        # Drain both pipes before waiting: a reader blocked on a full pipe never exits.
        $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
        if($info.RedirectStandardInput){
            # Written as bytes: the writer a process is given encodes as the console does. A
            # program that ended without reading says so by how it ended.
            try{
                $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Asked)
                $process.StandardInput.BaseStream.Write($bytes,0,$bytes.Length);$process.StandardInput.BaseStream.Flush()
            }catch{}
            try{$process.StandardInput.Close()}catch{}
        }
        $process.WaitForExit()
        return [pscustomobject]@{exitCode=$process.ExitCode;output=$output.Result;errors=$errors.Result}
    }finally{if($process){$process.Dispose()}}
}
# Where this copy keeps the reader for the platform it runs on.
function Get-Hotpl8NativePath([string]$Root) {
    if($env:OS -eq 'Windows_NT'){return [IO.Path]::Combine($Root,'bin','windows','hotpl8-native.exe')}
    return [IO.Path]::Combine($Root,'bin',$(if($IsMacOS){'macos'}else{'linux'}),'hotpl8-native')
}
# Ends the command as the reader ends it: its answer and exit 0, or its refusal in its own
# words and exit 1. Nothing here throws, because a request can arrive before src/common.ps1,
# which the entry needs to report an error of its own.
function Exit-Hotpl8Native([string]$Root,[string]$Command,[string]$StateDirectory,[string]$PreviewPolicy,[bool]$AsJson) {
    $arguments=@($Command,'--root',$Root)
    if($StateDirectory){$arguments+=@('--state',$StateDirectory)}
    if($PreviewPolicy){$arguments+=@('--policy',$PreviewPolicy)}
    if($AsJson){$arguments+='-AsJson'}
    $result=$null
    try{$result=Invoke-Hotpl8NativeProcess (Get-Hotpl8NativePath $Root) $arguments}catch{$result=$null}
    if(-not $result){
        [Console]::Error.WriteLine('HotPl8: This copy has no compiled reader it can start, and this command is answered by it. A release ships one; in a checkout, build it with scripts/build-native.ps1.')
        exit 1
    }
    if($result.exitCode -ne 0){
        [Console]::Error.Write($result.errors.Replace("`n",[Environment]::NewLine))
        exit 1
    }
    $text=$result.output
    if($text.EndsWith("`n",[StringComparison]::Ordinal)){$text=$text.Substring(0,$text.Length-1)}
    # Text is one line per output object, as every other command writes it; JSON is one
    # string, with the line ends ConvertTo-Json gave it here.
    if($AsJson){$text.Replace("`n",[Environment]::NewLine)}else{$text.Split("`n")}
    exit 0
}
# Ends watch or nyan as the reader ends it. Someone at a terminal is shown the dashboard
# until a key closes it; anything else is given one frame of it as text, like any answer.
function Exit-Hotpl8NativeDashboard([string]$Root,[string]$Command,[string]$StateDirectory,[string]$PreviewPolicy,[bool]$ReducedMotion,[bool]$NoColor) {
    if([Console]::IsOutputRedirected -or [Console]::IsInputRedirected){Exit-Hotpl8Native $Root $Command $StateDirectory $PreviewPolicy $false}
    $arguments=@($Command,'--root',$Root)
    if($StateDirectory){$arguments+=@('--state',$StateDirectory)}
    if($PreviewPolicy){$arguments+=@('--policy',$PreviewPolicy)}
    if($ReducedMotion){$arguments+='--reduced-motion'}
    if($NoColor){$arguments+='--no-color'}
    $result=$null
    try{$result=Invoke-Hotpl8NativeProcess (Get-Hotpl8NativePath $Root) $arguments -Attended}catch{$result=$null}
    if(-not $result){
        [Console]::Error.WriteLine('HotPl8: This copy has no compiled reader it can start, and the dashboard is drawn by it. A release ships one; in a checkout, build it with scripts/build-native.ps1.')
        exit 1
    }
    # 75: another release took this one's place while the dashboard was open. An installation
    # that updates itself opens that release's from its launcher. Any other runs its entry
    # again, as it is on disk now.
    if($result.exitCode -ne 75 -or $env:HOTPL8_INSTALL_DIRECTORY){exit $result.exitCode}
    $again=@('-NoProfile','-ExecutionPolicy','Bypass','-File',[IO.Path]::Combine($Root,'hotpl8.ps1'),$Command)
    if($StateDirectory){$again+=@('-StateDirectory',$StateDirectory)}
    if($PreviewPolicy){$again+=@('-PreviewPolicy',$PreviewPolicy)}
    if($ReducedMotion){$again+='-ReducedMotion'}
    if($NoColor){$again+='-NoColor'}
    $result=$null
    try{$result=Invoke-Hotpl8NativeProcess ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) $again -Attended}catch{$result=$null}
    if($result){exit $result.exitCode}
    exit 1
}
# Ends codex as Codex ends it. The reader chooses the account, reads its home and starts
# Codex on this terminal, in the directory this session is in. The words after -- are
# Codex's, as they were written.
function Exit-Hotpl8NativeCodex([string]$Root,[string]$StateDirectory,[string]$CodexExecutable,[string]$Provider,[string]$Slot,[string]$Model,[string]$Directory,[string[]]$Words) {
    $arguments=@('codex','--root',$Root,'--provider',$Provider,'--directory',$Directory)
    if($StateDirectory){$arguments+=@('--state',$StateDirectory)}
    if($CodexExecutable){$arguments+=@('--codex',$CodexExecutable)}
    if($Slot){$arguments+=@('--slot',$Slot)}
    if($Model){$arguments+=@('--model',$Model)}
    $arguments+='--'
    if($Words){$arguments+=$Words}
    $result=$null
    try{$result=Invoke-Hotpl8NativeProcess (Get-Hotpl8NativePath $Root) $arguments -Attended}catch{$result=$null}
    if(-not $result){
        [Console]::Error.WriteLine('HotPl8: This copy has no compiled reader it can start, and Codex is launched by it. A release ships one; in a checkout, build it with scripts/build-native.ps1.')
        exit 1
    }
    exit $result.exitCode
}
