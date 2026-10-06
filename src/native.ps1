# Hands display commands to the compiled reader when the release ships one that matches it.
# hotpl8.ps1 loads this before src/common.ps1, so it must stay self-contained: the fast path
# is only fast while it does not load the modules it replaces. That includes PowerShell's
# own: the first Join-Path, New-Object or Select-Object in a fresh Windows PowerShell loads a
# module and costs 50 to 80 ms, so this file and the hand-over in hotpl8.ps1 call .NET
# directly. ConvertFrom-Json is the one exception, and only a release pays for it.
# Every failure here means "PowerShell answers", never an error.
function Invoke-Hotpl8NativeProcess([string]$Path,[string[]]$Arguments,[int]$TimeoutMs=5000) {
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
        $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
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
# The binary's path, only when it exists and is executable and HOTPL8_NATIVE is not 0.
function Get-Hotpl8NativePath([string]$Root) {
    try{
        if($env:HOTPL8_NATIVE -eq '0'){return $null}
        $windows=$env:OS -eq 'Windows_NT'
        if(-not $windows -and -not $IsMacOS){return $null}
        $path=if($windows){[IO.Path]::Combine($Root,'bin','windows','hotpl8-native.exe')}else{[IO.Path]::Combine($Root,'bin','macos','hotpl8-native')}
        if(-not [IO.File]::Exists($path)){return $null}
        if(-not $windows -and -not ([IO.File]::GetUnixFileMode($path) -band [IO.UnixFileMode]::UserExecute)){return $null}
        return $path
    }catch{return $null}
}
# What every request tells the reader about its caller, or $null when this caller is one the
# reader does not follow. The reader checks it as part of answering, so a request costs one
# program start: a reader of another protocol or built from another commit declines.
function Get-Hotpl8NativeIdentity([string]$Root) {
    try{
        # Numbers and time arithmetic differ between the two PowerShell versions in use, and
        # the reader follows the one it is told. Before 7.5 JSON dates were read differently.
        $version=$PSVersionTable.PSVersion
        $shell=if($PSVersionTable.PSEdition -ne 'Core'){if($version.Major -eq 5 -and $version.Minor -eq 1){'desktop'}}
            elseif($version.Major -gt 7 -or ($version.Major -eq 7 -and $version.Minor -ge 5)){'core'}
        if(-not $shell){return $null}
        # PowerShell formats numbers and times, sorts and compares text by regional rules.
        # The reader knows the invariant and English ones.
        $culture=[Globalization.CultureInfo]::CurrentCulture
        if($culture.Name -ne '' -and $culture.TwoLetterISOLanguageName -cne 'en'){return $null}
        if($culture.NumberFormat.NumberDecimalSeparator -cne '.' -or $culture.NumberFormat.NegativeSign -cne '-'){return $null}
        if($culture.DateTimeFormat.TimeSeparator -cne ':' -or $culture.DateTimeFormat.Calendar -isnot [Globalization.GregorianCalendar]){return $null}
        $identity=@('--protocol','2','--shell',$shell)
        # A source checkout has no build identity; there the protocol alone decides.
        $buildFile=[IO.Path]::Combine($Root,'build-info.json')
        if([IO.File]::Exists($buildFile)){
            $build=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($buildFile)) -ErrorAction Stop
            if($build.sha -isnot [string] -or $build.sha -cnotmatch '\A[a-f0-9]{40}\z'){return $null}
            $identity+=@('--release',$build.sha)
        }
        return $identity
    }catch{return $null}
}
# The command's complete text, or $null when the PowerShell implementation must answer:
# no usable binary, a caller the reader does not follow, a declined request (exit 64), any
# other exit status, or cut-off output. $Arguments is the command followed by its own
# arguments; the caller's identity goes between them.
function Invoke-Hotpl8Native([string]$Root,[string[]]$Arguments) {
    $path=Get-Hotpl8NativePath $Root
    if(-not $path){return $null}
    $identity=Get-Hotpl8NativeIdentity $Root
    if(-not $identity){return $null}
    $own=if($Arguments.Count -gt 1){$Arguments[1..($Arguments.Count-1)]}
    $result=Invoke-Hotpl8NativeProcess $path (@($Arguments[0])+$identity+@($own))
    if(-not $result -or $result.exitCode -ne 0 -or -not $result.output.EndsWith("`n",[StringComparison]::Ordinal)){return $null}
    return $result.output.Substring(0,$result.output.Length-1)
}
