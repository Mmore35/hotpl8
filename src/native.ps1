# Hands display commands to the compiled reader when the release ships one that matches it.
# hotpl8.ps1 loads this before src/common.ps1, so it must stay self-contained: the fast path
# is only fast while it does not load the modules it replaces. Every failure here means
# "PowerShell answers", never an error.
function Invoke-Hotpl8NativeProcess([string]$Path,[string[]]$Arguments,[int]$TimeoutMs=5000) {
    $process=$null
    try{
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$Path
        # Windows CRT quoting, also understood by .NET's Unix Arguments parser.
        $info.Arguments=(@($Arguments|ForEach-Object{
            if($_.Length -gt 0 -and $_ -notmatch '[\s"]'){$_}
            else{'"'+[regex]::Replace([regex]::Replace($_,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'}
        }) -join ' ')
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $info.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
        $process=[Diagnostics.Process]::Start($info)
        # Drain both pipes before waiting; diagnostics from the reader are not shown.
        $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($TimeoutMs)){
            try{$process.Kill()}catch{$null=$_}
            return $null
        }
        $process.WaitForExit()
        $null=$errors.Result
        return [pscustomobject]@{exitCode=$process.ExitCode;output=$output.Result}
    }catch{return $null}
    finally{if($process){$process.Dispose()}}
}
# The binary's path, only when it exists, is executable, reports this protocol and was built
# from the same commit as the release around it, and HOTPL8_NATIVE is not 0.
function Get-Hotpl8NativePath([string]$Root) {
    try{
        if($env:HOTPL8_NATIVE -eq '0'){return $null}
        $windows=$env:OS -eq 'Windows_NT'
        if(-not $windows -and -not $IsMacOS){return $null}
        $path=Join-Path $Root $(if($windows){'bin/windows/hotpl8-native.exe'}else{'bin/macos/hotpl8-native'})
        if(-not [IO.File]::Exists($path)){return $null}
        if(-not $windows -and -not ([IO.File]::GetUnixFileMode($path) -band [IO.UnixFileMode]::UserExecute)){return $null}
        # A source checkout has no build identity; there the protocol alone decides.
        $sha='(?:[a-f0-9]{40}|unknown)'
        $buildFile=Join-Path $Root 'build-info.json'
        if([IO.File]::Exists($buildFile)){
            $build=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($buildFile)) -ErrorAction Stop
            if($build.sha -isnot [string] -or $build.sha -cnotmatch '\A[a-f0-9]{40}\z'){return $null}
            $sha=$build.sha
        }
        $check=Invoke-Hotpl8NativeProcess $path @('self-check')
        if(-not $check -or $check.exitCode -ne 0 -or $check.output -cnotmatch ('\Ahotpl8-native protocol=1 sha='+$sha+'\n\z')){return $null}
        return $path
    }catch{return $null}
}
# The command's complete text, or $null when the PowerShell implementation must answer:
# no usable binary, a declined input (exit 64), any other exit status, or cut-off output.
function Invoke-Hotpl8Native([string]$Root,[string[]]$Arguments) {
    $path=Get-Hotpl8NativePath $Root
    if(-not $path){return $null}
    $result=Invoke-Hotpl8NativeProcess $path $Arguments
    if(-not $result -or $result.exitCode -ne 0 -or -not $result.output.EndsWith("`n",[StringComparison]::Ordinal)){return $null}
    return $result.output.Substring(0,$result.output.Length-1)
}
