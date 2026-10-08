# The dashboard the compiled reader draws for a fictional policy and status, as rows of text:
# what `hotpl8 watch` shows at that size and that moment, with nothing moving. The state is
# staged in a directory of its own, so no real state is read. A pause or a hold is read from
# its own file, as the collector leaves it, so it is staged under -Files by that file's name.
# Needs src/common.ps1 and src/native.ps1. A state the reader refuses stops the check with the
# reader's own words.
function Get-Hotpl8TestFrame($Status,$Policy,[datetimeoffset]$Now,[int]$Width=110,[int]$Height=200,[string]$View='watch',[string[]]$As=@(),[string]$Root='',[hashtable]$Files=@{}) {
    $source=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if(-not $Root){$Root=$source}
    $reader=Get-Hotpl8NativePath $source
    if(-not [IO.File]::Exists($reader)){throw 'Build the native reader first: scripts/build-native.ps1'}
    $state=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-frame-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($state)
    try{
        if($null -ne $Policy){Write-Hotpl8Text (Join-Path $state 'policy.json') ($Policy|ConvertTo-Json -Depth 32 -Compress) -NoBom}
        if($null -ne $Status){Write-Hotpl8Text (Join-Path $state 'status.json') ($Status|ConvertTo-Json -Depth 32 -Compress) -NoBom}
        foreach($name in $Files.Keys){Write-Hotpl8Text (Join-Path $state $name) ($Files[$name]|ConvertTo-Json -Depth 32 -Compress) -NoBom}
        $drawn=Invoke-Hotpl8NativeProcess $reader (@($View,'--root',$Root,'--state',$state,'--now',$Now.ToUniversalTime().ToString('o'),'--zone','0','--size',($Width.ToString()+'x'+$Height))+$As)
        if($drawn.exitCode -ne 0 -or $drawn.errors -ne ''){throw ($View+' drew no frame: '+$drawn.exitCode+' '+$drawn.errors+$drawn.output)}
        $lines=$drawn.output.Split("`n")
        if($lines.Count -lt 3 -or $lines[$lines.Count-1] -ne '' -or $lines[$lines.Count-2] -notmatch '^offset \d+$'){throw ($View+' drew no frame: '+$drawn.output)}
        $lines[0..($lines.Count-3)]
    }finally{Remove-Item -LiteralPath $state -Recurse -Force}
}
