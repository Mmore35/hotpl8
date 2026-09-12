# Installation ownership and file allowlists protect unrelated applications and native account homes.
function Assert-Hotpl8Path([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\','/')){throw 'A drive root cannot be an installation directory.'}
    $cursor=$full
    while($cursor){
        if(Test-Path -LiteralPath $cursor){
            if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Installation paths cannot traverse links or junctions.'}
        }
        $parent=Split-Path $cursor -Parent
        if($parent -eq $cursor){break};$cursor=$parent
    }
    return $full
}
function Get-Hotpl8ReleaseFiles([string]$Source) {
    $manifest=Read-Hotpl8Json (Join-Path $Source 'release-files.json')
    if(-not $manifest -or $manifest.schemaVersion -ne 1 -or -not $manifest.files){throw 'Missing release file manifest.'}
    $seen=@{}
    foreach($relative in $manifest.files){
        if($relative -isnot [string] -or $relative -notmatch '^[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)*$' -or $relative -match '(^|/)\.\.?(/|$)' -or $seen.ContainsKey($relative)){throw 'Invalid release file manifest.'}
        $seen[$relative]=$true
        $full=Assert-Hotpl8Path (Join-Path $Source $relative)
        if(-not (Test-Path -LiteralPath $full -PathType Leaf)){throw ('Missing release file: '+$relative)}
        $relative
    }
}
function Remove-Hotpl8App([string]$Path, [switch]$ValidateOnly) {
    $full=Assert-Hotpl8Path $Path
    if(-not (Test-Path -LiteralPath $full)){return}
    $allowed=@(Get-Hotpl8ReleaseFiles $full)+@('install-state.json','checksums.json')
    foreach($item in Get-ChildItem -LiteralPath $full -Recurse -Force){
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Refusing to remove an application containing links.'}
        if(-not $item.PSIsContainer){
            $relative=$item.FullName.Substring($full.Length+1).Replace('\','/')
            if($relative -notin $allowed){throw ('Unrecognized file in application directory: '+$relative)}
        }
    }
    if($ValidateOnly){return}
    # Full absolute path was validated, and every file was checked against the owned manifest.
    Remove-Item -LiteralPath $full -Recurse -Force
}
function Set-Hotpl8UserPath([string]$Directory,[bool]$Add) {
    $parts=@([Environment]::GetEnvironmentVariable('Path','User') -split ';'|Where-Object{$_})
    $parts=@($parts|Where-Object{$_.TrimEnd('\','/') -ine $Directory.TrimEnd('\','/')})
    if($Add){$parts+=@($Directory)}
    [Environment]::SetEnvironmentVariable('Path',($parts -join ';'),'User')
}
function Register-Hotpl8Task($Installation,[string]$Directory) {
    $name='HotPl8-'+$Installation.id
    $description='HotPl8 owned installation '+$Installation.id
    $existing=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if($existing -and $existing.Description -ne $description){throw 'Scheduled task ownership mismatch.'}
    $hostExe=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $arguments='-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File '+(ConvertTo-NativeArgument (Join-Path $Directory 'app/tick.ps1'))+' -StateDirectory '+(ConvertTo-NativeArgument $Installation.stateDirectory)
    $action=New-ScheduledTaskAction -Execute $hostExe -Argument $arguments -WorkingDirectory $Directory
    $trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 4) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $task=New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description $description
    Register-ScheduledTask -TaskName $name -InputObject $task -Force|Out-Null
}
