# Installation ownership and file allowlists protect unrelated applications and native account homes.
# macOS reaches /tmp, /var and /etc through root-owned links in a root-owned directory no one
# else can write. Only an administrator can repoint those, unlike a link a user could place.
function Test-Hotpl8SystemLink($Item) {
    if($env:OS -eq 'Windows_NT' -or $Item.LinkType -ne 'SymbolicLink' -or $Item.User -ne 'root'){return $false}
    $parent=[IO.Path]::GetDirectoryName($Item.FullName.TrimEnd('/'))
    $open=[IO.UnixFileMode]'GroupWrite, OtherWrite'
    (Get-Item -LiteralPath $parent -Force).User -eq 'root' -and -not ([IO.File]::GetUnixFileMode($parent) -band $open)
}
function Assert-Hotpl8Path([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\','/')){throw 'A drive root cannot be an installation directory.'}
    $cursor=$full
    while($cursor){
        if(Test-Path -LiteralPath $cursor){
            $item=Get-Item -LiteralPath $cursor -Force
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and -not (Test-Hotpl8SystemLink $item)){throw 'Installation paths cannot traverse links or junctions.'}
        }
        $parent=Split-Path $cursor -Parent
        if($parent -eq $cursor){break};$cursor=$parent
    }
    return $full
}
function Get-Hotpl8ReleaseFiles([string]$Source,[string]$Platform,[switch]$RequirePlatformFiles) {
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
    # Compiled files exist for one platform per package and not at all in a plain source
    # checkout, so each is listed only when present. Packaging and installing require their
    # own platform's set.
    if($null -eq $manifest.platformFiles){return}
    if($manifest.platformFiles -isnot [pscustomobject]){throw 'Invalid release file manifest.'}
    foreach($group in $manifest.platformFiles.PSObject.Properties){
        if($group.Name -cnotin @('windows','macos')){throw 'Invalid release file manifest.'}
        foreach($relative in @($group.Value)){
            if($relative -isnot [string] -or $relative -notmatch '^[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)*$' -or $relative -match '(^|/)\.\.?(/|$)' -or -not $relative.StartsWith('bin/'+$group.Name+'/',[StringComparison]::Ordinal) -or $seen.ContainsKey($relative)){throw 'Invalid release file manifest.'}
            $seen[$relative]=$true
            if($Platform -and $group.Name -cne $Platform){continue}
            $full=Assert-Hotpl8Path (Join-Path $Source $relative)
            if(Test-Path -LiteralPath $full -PathType Leaf){$relative}
            elseif($RequirePlatformFiles){throw ('Missing native release file: '+$relative+'. Run scripts/build-native.ps1 first.')}
        }
    }
}
function Remove-Hotpl8App([string]$Path, [switch]$ValidateOnly) {
    $full=Assert-Hotpl8Path $Path
    if(-not (Test-Path -LiteralPath $full)){return}
    $allowed=@(Get-Hotpl8ReleaseFiles $full)+@('install-state.json','checksums.json','build-info.json')
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
# Whether the scheduler of an installation that keeps its release under app can start that
# release's compiled collector, with no PowerShell before it. rollback.ps1 puts the release
# kept under previous back under app and leaves the scheduler as it is, and a release from
# before the collector was compiled answers only to tick.ps1: the collector is named only
# when the release kept for a rollback has one too.
function Test-Hotpl8CompiledStart([string]$Directory) {
    . (Join-Path $PSScriptRoot 'native.ps1')
    $compiled={param([string]$Release) (Test-Path -LiteralPath (Join-Path $Release 'src/lane.ps1') -PathType Leaf) -and (Test-Path -LiteralPath (Get-Hotpl8NativePath $Release) -PathType Leaf)}
    $previous=Join-Path $Directory 'previous'
    return [bool]((& $compiled (Join-Path $Directory 'app')) -and (-not (Test-Path -LiteralPath $previous) -or (& $compiled $previous)))
}
# What launchd starts every minute for an ordinary Mac installation, as install-macos.ps1
# writes it when collection is first scheduled. $Shell is the PowerShell the collector uses
# for what it leaves to PowerShell: launchd gives a job no path to find one on.
function Get-Hotpl8MacCollectorStart([string]$Directory,[string]$State,[string]$Shell) {
    . (Join-Path $PSScriptRoot 'native.ps1')
    $app=Join-Path $Directory 'app'
    if(Test-Hotpl8CompiledStart $Directory){return @((Get-Hotpl8NativePath $app),'collect','--root',$app,'--state',$State,'--scheduled','--powershell',$Shell)}
    return @($Shell,'-NoProfile','-NonInteractive','-File',(Join-Path $app 'tick.ps1'),'-Scheduled','-StateDirectory',$State)
}
# Whether a launchd job is this installation's collector: its label, its state directory, and
# either start above. An update leaves the job as the installation first wrote it.
function Test-Hotpl8MacCollectorJob([xml]$Job,[string]$Label,[string]$Directory,[string]$State) {
    . (Join-Path $PSScriptRoot 'native.ps1')
    $words=@($Job.plist.dict.array.string);$app=Join-Path $Directory 'app'
    return [bool](($Job.plist.dict.string -contains $Label) -and ($words -contains $State) -and (($words -contains (Join-Path $app 'tick.ps1')) -or ($words -contains (Get-Hotpl8NativePath $app))))
}
# Separated from registration so the command line that actually collects unattended can be
# asserted and run by a test without creating, editing or deleting a real scheduled task.
function Get-Hotpl8TaskDefinition($Installation,[string]$Directory) {
    . (Join-Path $PSScriptRoot 'job-host.ps1')
    . (Join-Path $PSScriptRoot 'native.ps1')
    $hostExe=Install-Hotpl8JobHost $Directory
    $shell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $wake=@($shell,'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $Directory 'app/tick.ps1'),'-Scheduled','-StateDirectory',$Installation.stateDirectory)
    # An installation that updates itself keeps the compiled program beside its launcher, and
    # that copy wakes the release in force without starting PowerShell (native/src/door.rs).
    # It is named only when it is this release's own: an older copy does not know the word.
    try{
        $beside=Join-Path $Directory 'hotpl8-native.exe';$shipped=Get-Hotpl8NativePath (Split-Path $PSScriptRoot -Parent)
        if((Test-Path -LiteralPath (Join-Path $Directory 'current.json') -PathType Leaf) -and (Test-Path -LiteralPath $beside -PathType Leaf) -and (Test-Path -LiteralPath $shipped -PathType Leaf) -and (Get-FileHash -LiteralPath $beside -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $shipped -Algorithm SHA256).Hash){$wake=@($beside,'wake')}
    }catch{}
    # Every other installation keeps its release under app, and its task starts that release's
    # compiled collector as tick.ps1 would. Until the release kept for a rollback has one too,
    # the task keeps the start above, which every release answers to.
    if(Test-Hotpl8CompiledStart $Directory){
        $app=Join-Path $Directory 'app'
        $wake=@((Get-Hotpl8NativePath $app),'collect','--root',$app,'--state',$Installation.stateDirectory,'--scheduled')
    }
    $argv=@('225',(Join-Path $Directory 'job-runs/collector'),$Directory)+$wake
    [pscustomobject]@{
        name='HotPl8-'+$Installation.id
        description='HotPl8 owned installation '+$Installation.id
        execute=$hostExe
        arguments=(@($argv|ForEach-Object{ConvertTo-NativeArgument $_}) -join ' ')
        workingDirectory=$Directory
    }
}
function Register-Hotpl8Task($Installation,[string]$Directory) {
    $definition=Get-Hotpl8TaskDefinition $Installation $Directory
    $existing=Get-ScheduledTask -TaskName $definition.name -ErrorAction SilentlyContinue
    if($existing -and $existing.Description -ne $definition.description){throw 'Scheduled task ownership mismatch.'}
    $action=New-ScheduledTaskAction -Execute $definition.execute -Argument $definition.arguments -WorkingDirectory $definition.workingDirectory
    $trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 4) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $task=New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description $definition.description
    Register-ScheduledTask -TaskName $definition.name -InputObject $task -Force|Out-Null
}
# Automatic continue reaches Claude through one StopFailure hook in its user-level settings,
# which every account shares. HotPl8 owns exactly the hook whose args it recorded.
function Get-Hotpl8ClaudeSettingsPath {
    Join-Path $(if($env:CLAUDE_CONFIG_DIR){$env:CLAUDE_CONFIG_DIR}else{Join-Path (Get-Hotpl8UserHome) '.claude'}) 'settings.json'
}
# What the hook runs depends on how this copy was installed. A copy that is not an
# installation (source checkout, test, preview) gets a hook only when asked explicitly.
function Get-Hotpl8ContinueHookCommand([string]$CodeDirectory,[string]$StateDirectory,[switch]$Explicit) {
    $state=[IO.Path]::GetFullPath($StateDirectory);$shell=@('-NoProfile','-ExecutionPolicy','Bypass')
    $install=$env:HOTPL8_INSTALL_DIRECTORY
    if($install -and (Test-Path -LiteralPath (Join-Path $install 'current.json'))){
        $delivery=Read-Hotpl8Json (Join-Path $install 'delivery.json')
        $exe=if($env:OS -eq 'Windows_NT'){'powershell.exe'}else{[string]$delivery.powershell}
        if($exe -and $delivery.stateDirectory -and [IO.Path]::GetFullPath([string]$delivery.stateDirectory) -eq $state){
            # Finds the current release each time it runs, so an update never touches the hook.
            $quoted=@($install,(Join-Path $install 'current.json'),$state|ForEach-Object{"'"+([string]$_).Replace("'","''")+"'"})
            $script='& (Join-Path '+$quoted[0]+' ((Get-Content -LiteralPath '+$quoted[1]+" -Raw | ConvertFrom-Json).release + '/continue.ps1')) -Provider claude -StateDirectory "+$quoted[2]+'; exit $LASTEXITCODE'
            return [pscustomobject]@{command=$exe;args=$shell+@('-Command',$script)}
        }
    }
    $root=Split-Path $CodeDirectory -Parent
    $installation=Read-Hotpl8Json (Join-Path $root 'installation.json')
    $installed=$installation.product -eq 'hotpl8' -and $installation.stateDirectory -and [IO.Path]::GetFullPath([string]$installation.stateDirectory) -eq $state
    if(-not $installed -and -not $Explicit){return $null}
    $exe=if($env:OS -eq 'Windows_NT'){'powershell.exe'}else{Get-Hotpl8PowerShell}
    return [pscustomobject]@{command=$exe;args=$shell+@('-File',(Join-Path $CodeDirectory 'continue.ps1'),'-Provider','claude','-StateDirectory',$state)}
}
function Test-Hotpl8ContinueHook([string]$StateDirectory) {
    $recorded=(Read-Hotpl8Json (Join-Path $StateDirectory 'continue/hook.json')).args
    if(-not $recorded){return $false}
    $owned=ConvertTo-Json -InputObject @($recorded) -Compress
    foreach($entry in @((Read-Hotpl8Json (Get-Hotpl8ClaudeSettingsPath)).hooks.StopFailure)){
        foreach($hook in @($entry.hooks)){if($hook.args -and (ConvertTo-Json -InputObject @($hook.args) -Compress) -ceq $owned){return $true}}
    }
    return $false
}
# Present unless -Remove. Every other hook, event and setting is left exactly as it was:
# the file is not written when anything outside hooks.StopFailure would come out different.
function Set-Hotpl8ContinueHook([string]$CodeDirectory,[string]$StateDirectory,[switch]$Remove,[switch]$Explicit) {
    $path=Get-Hotpl8ClaudeSettingsPath
    if(-not (Test-Path -LiteralPath (Split-Path $path -Parent) -PathType Container)){return}
    $recordPath=Join-Path $StateDirectory 'continue/hook.json'
    $recorded=(Read-Hotpl8Json $recordPath).args
    $wanted=Get-Hotpl8ContinueHookCommand $CodeDirectory $StateDirectory -Explicit:$Explicit
    if(-not $Remove -and -not $wanted){return}
    $key={param($value) ConvertTo-Json -InputObject @($value) -Depth 64 -Compress}
    $owned=@();if($recorded){$owned+=@(& $key $recorded)};if($wanted){$owned+=@(& $key $wanted.args)}
    if(-not $owned.Count){return}
    $text='{}';$exists=Test-Path -LiteralPath $path
    if($exists){
        if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Claude settings file is a link; it was not changed.'}
        $text=[IO.File]::ReadAllText($path)
        # Core PowerShell before 7.5 rewrites JSON timestamps as it reads them.
        if($PSVersionTable.PSVersion.Major -ge 6 -and $PSVersionTable.PSVersion -lt [version]'7.5' -and $text -match '"\d{4}-\d{2}-\d{2}T\d{2}:'){throw 'Claude settings cannot be rewritten safely by this PowerShell version; the file was not changed.'}
    }
    $document=$null;try{$document=ConvertFrom-Hotpl8Json $text}catch{}
    $object=[System.Management.Automation.PSCustomObject]
    $existing=$document.hooks.StopFailure
    if($document -isnot $object -or ($null -ne $document.hooks -and $document.hooks -isnot $object) -or ($null -ne $existing -and $existing -isnot [array])){throw 'Claude settings file is not valid; it was not changed.'}
    $entries=@()
    foreach($entry in $existing){
        if($entry.hooks -isnot [array]){$entries+=,$entry;continue}
        $kept=@($entry.hooks|Where-Object{(& $key $_.args) -cnotin $owned})
        if($kept.Count -eq $entry.hooks.Count){$entries+=,$entry}
        elseif($kept.Count){$entry.hooks=$kept;$entries+=,$entry}
    }
    if(-not $Remove){
        $entries+=,[pscustomobject]@{matcher='rate_limit';hooks=@([pscustomobject]@{type='command';command=$wanted.command;args=@($wanted.args);asyncRewake=$true;timeout=21700})}
    }
    # Compared before the document is changed below; ConvertFrom-Json gave it fresh arrays.
    $before=if($null -eq $existing){'[]'}else{& $key (ConvertFrom-Hotpl8Json $text).hooks.StopFailure}
    if((& $key $entries) -cne $before){
        if(-not $entries.Count){
            $document.hooks.PSObject.Properties.Remove('StopFailure')
            if(-not @($document.hooks.PSObject.Properties).Count){$document.PSObject.Properties.Remove('hooks')}
        }
        else{
            if($null -eq $document.hooks){$document|Add-Member NoteProperty hooks ([pscustomobject]@{})}
            if($document.hooks.PSObject.Properties['StopFailure']){$document.hooks.StopFailure=$entries}
            else{$document.hooks|Add-Member NoteProperty StopFailure $entries}
        }
        $next=$document|ConvertTo-Json -Depth 64
        $rest={param([string]$json)
            $copy=ConvertFrom-Hotpl8Json $json
            if($copy.hooks -is $object){
                $copy.hooks.PSObject.Properties.Remove('StopFailure')
                if(-not @($copy.hooks.PSObject.Properties).Count){$copy.PSObject.Properties.Remove('hooks')}
            }
            ConvertTo-Json -InputObject $copy -Depth 64 -Compress
        }
        if((& $rest $next) -cne (& $rest $text)){throw 'Claude settings could not be rewritten without changing other settings; the file was not changed.'}
        if($exists -and [IO.File]::ReadAllText($path) -cne $text){throw 'Claude settings changed while being read; the file was not changed.'}
        Write-Hotpl8Text $path $next -NoBom
    }
    if($Remove){if(Test-Path -LiteralPath $recordPath){Remove-Item -LiteralPath $recordPath -Force}}
    elseif(-not $recorded -or (& $key $recorded) -cne (& $key $wanted.args)){
        [void][IO.Directory]::CreateDirectory((Split-Path $recordPath -Parent))
        Write-Hotpl8Text $recordPath ([pscustomobject]@{args=@($wanted.args)}|ConvertTo-Json) -NoBom
    }
}
