# version, status, explain and what the tray shows are the compiled reader's: PowerShell
# holds no implementation of them and hands each request to the reader this copy ships
# (native/, built by scripts/build-native.ps1). hotpl8.ps1 loads this before src/common.ps1,
# so it must stay self-contained: a plain request is only fast while it loads nothing it has
# no use for.
# That includes PowerShell's own modules: the first Join-Path, New-Object or Select-Object in
# a fresh Windows PowerShell loads one and costs 50 to 80 ms, so this file and the hand-over
# in hotpl8.ps1 call .NET directly.
function Invoke-Hotpl8NativeProcess([string]$Path,[string[]]$Arguments) {
    $process=$null
    try{
        $info=[Diagnostics.ProcessStartInfo]::new()
        $info.FileName=$Path
        # Windows CRT quoting, also understood by .NET's Unix Arguments parser.
        $info.Arguments=(@($Arguments|ForEach-Object{
            if($_.Length -gt 0 -and $_ -notmatch '[\s"]'){$_}
            else{'"'+[regex]::Replace([regex]::Replace($_,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'}
        }) -join ' ')
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
        $process=[Diagnostics.Process]::Start($info)
        # Drain both pipes before waiting: a reader blocked on a full pipe never exits.
        $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
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
