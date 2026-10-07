$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/lifecycle.ps1')
$script:passed=0;$script:failed=0
function Assert($Value){if(-not $Value){throw 'assertion failed'}}
function Check([string]$Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message}}
$dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-install-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
$install=Join-Path $dir 'application with spaces';$state=Join-Path $dir 'state'
$pathBefore=[Environment]::GetEnvironmentVariable('Path','User')
# Installed collectors and uninstalls below look for Claude's settings here, never in the real
# profile. The directory does not exist until the automatic continue checks create it.
$claude=Join-Path $dir 'claude home';$claudeBefore=$env:CLAUDE_CONFIG_DIR;$installBefore=$env:HOTPL8_INSTALL_DIRECTORY
$env:CLAUDE_CONFIG_DIR=$claude;$env:HOTPL8_INSTALL_DIRECTORY=$null
try{
    Check 'package is reproducible and contains only allowlisted source' {
        $zip=& (Join-Path $root 'scripts/package.ps1') -OutputDirectory (Join-Path $dir 'build')
        $hash=(Get-FileHash -LiteralPath $zip).Hash
        $again=& (Join-Path $root 'scripts/package.ps1') -OutputDirectory (Join-Path $dir 'build')
        Assert ((Get-FileHash -LiteralPath $again).Hash -eq $hash)
        $archive=[IO.Compression.ZipFile]::OpenRead($zip)
        try{
            $entries=@($archive.Entries|ForEach-Object FullName)
            Assert ($entries.Count -eq (@(Get-Hotpl8ReleaseFiles $root -Platform windows).Count+1))
            Assert ('policy.json' -notin $entries -and 'auth.json' -notin $entries -and 'checksums.json' -in $entries)
        }finally{$archive.Dispose()}
        [IO.Compression.ZipFile]::ExtractToDirectory($zip,(Join-Path $dir 'release'))
    }
    $source=Join-Path $dir 'release'
    Check 'failed first installation preserves state and can be retried' {
        $retry=Join-Path $dir 'retry installation';$retryState=Join-Path $dir 'retry state'
        [void][IO.Directory]::CreateDirectory($retryState)
        $retryPolicy=Join-Path $retryState 'policy.json'
        [IO.File]::WriteAllText($retryPolicy,'{"schemaVersion":99}')
        $before=(Get-FileHash -LiteralPath $retryPolicy).Hash
        $threw=$false
        try{& (Join-Path $source 'install.ps1') -InstallDirectory $retry -StateDirectory $retryState -NoPath|Out-Null}catch{$threw=$true}
        Assert $threw
        Assert ((Get-FileHash -LiteralPath $retryPolicy).Hash -eq $before)
        Assert (-not (Test-Path -LiteralPath (Join-Path $retry 'app')))
        $identity=(Read-Hotpl8Json (Join-Path $retry 'installation.json')).id
        Assert ($identity -match '^[a-f0-9]{12}$')
        [IO.File]::Copy((Join-Path $source 'policy.example.json'),$retryPolicy,$true)
        & (Join-Path $source 'install.ps1') -InstallDirectory $retry -StateDirectory $retryState -NoPath|Out-Null
        Assert ((Read-Hotpl8Json (Join-Path $retry 'installation.json')).id -eq $identity)
        Assert (Test-Path -LiteralPath (Join-Path $retry 'app/hotpl8.ps1'))
        $native=Join-Path $dir 'legacy native account';[void][IO.Directory]::CreateDirectory($native)
        $p=Read-Hotpl8Json $retryPolicy;$p.codex.slots=@([pscustomobject]@{id='legacy';home=$native})
        Write-Hotpl8Text $retryPolicy ($p|ConvertTo-Json -Depth 12)
        $command='powershell -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $retry 'app/status-print.ps1')+'" -Provider codex -StateDirectory "'+$retryState+'"'
        $hooks=@{hooks=@{SessionStart=@(@{hooks=@(@{type='command';command=$command},@{type='command';command='echo retained'})})}}
        Write-Hotpl8Text (Join-Path $native 'hooks.json') ($hooks|ConvertTo-Json -Depth 8) -NoBom
        & (Join-Path $source 'uninstall.ps1') -InstallDirectory $retry|Out-Null
        Assert (Test-Path -LiteralPath $retryPolicy)
        $hooks=Read-Hotpl8Json (Join-Path $native 'hooks.json')
        Assert (@($hooks.hooks.SessionStart[0].hooks).Count -eq 1 -and $hooks.hooks.SessionStart[0].hooks[0].command -ceq 'echo retained')
    }
    Check 'fresh archive installs without editing PATH or native homes' {
        & (Join-Path $source 'install.ps1') -InstallDirectory $install -StateDirectory $state -NoPath|Out-Null
        $p=Read-Hotpl8Json (Join-Path $state 'policy.json')
        # Switching and automatic continue start on; warming is the one that waits to be asked for.
        Assert ($p.mode -eq 'automate' -and $p.switchEnabled -eq $true -and -not $p.warm -and $null -eq $p.automation.continue)
        Assert (Test-Path -LiteralPath (Join-Path $install 'app/hotpl8.ps1'))
        Assert ([Environment]::GetEnvironmentVariable('Path','User') -ceq $pathBefore)
    }
    Check 'repeat install preserves modified policy and owns only one install' {
        $p=Read-Hotpl8Json (Join-Path $state 'policy.json');$p.labels|Add-Member NoteProperty '1' 'keep-me'
        Write-Hotpl8Text (Join-Path $state 'policy.json') ($p|ConvertTo-Json -Depth 12)
        $before=(Get-FileHash (Join-Path $state 'policy.json')).Hash
        $identity=(Read-Hotpl8Json (Join-Path $install 'installation.json')).id
        & (Join-Path $source 'install.ps1') -InstallDirectory $install -StateDirectory $state -NoPath|Out-Null
        Assert ((Get-FileHash (Join-Path $state 'policy.json')).Hash -eq $before)
        Assert ((Read-Hotpl8Json (Join-Path $install 'installation.json')).id -eq $identity)
        Assert (Test-Path -LiteralPath (Join-Path $install 'previous/VERSION'))
    }
    Check 'installed command resolves external state binding' {
        $output=& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $install 'app/hotpl8.ps1') doctor -AsJson
        Assert ($LASTEXITCODE -eq 0)
        $d=$output|ConvertFrom-Json
        Assert $d.policyValid
        Assert (-not (Test-Path -LiteralPath (Join-Path $install 'app/policy.json')))
    }
    Check 'the scheduled collector command line runs the installed tick' {
        # Unattended collection happens only through this command line, and
        # `powershell.exe -File` exits 0 on an unknown parameter, so a broken one is
        # silent. Assert the definition, then run it and require the output it exists
        # to produce. Nothing here registers, edits or deletes a scheduled task.
        $installation=Read-Hotpl8Json (Join-Path $install 'installation.json')
        $definition=Get-Hotpl8TaskDefinition $installation $install
        Assert ($definition.name -ceq ('HotPl8-'+$installation.id))
        Assert ($definition.description -ceq ('HotPl8 owned installation '+$installation.id))
        Assert ((Test-Path -LiteralPath $definition.execute -PathType Leaf) -and $definition.workingDirectory -ceq $install)
        # The installed path carries a space, so its quoting is part of the assertion.
        Assert ($definition.arguments.Contains(' -File "'+(Join-Path $install 'app/tick.ps1')+'" -Scheduled -StateDirectory '+(ConvertTo-NativeArgument $state)))
        $policyPath=Join-Path $state 'policy.json';$original=[IO.File]::ReadAllBytes($policyPath);$homeBefore=$env:USERPROFILE
        try{
            # A preferred slot makes the tick collect. The backoff marker keeps that
            # collection away from cswap, so no account or credential home is touched.
            $env:USERPROFILE=Join-Path $dir 'user home';[void][IO.Directory]::CreateDirectory($env:USERPROFILE)
            $p=Read-Hotpl8Json $policyPath;$p.prefer=@(1)
            Write-Hotpl8Text $policyPath ($p|ConvertTo-Json -Depth 12)
            $now=[datetimeoffset]::UtcNow
            Write-Hotpl8Text (Join-Path $state 'collector.json') (@{schemaVersion=1;providers=@{claude=@{lastAttemptAt=$now.ToString('o');failures=1;nextAttemptAt=$now.AddMinutes(30).ToString('o');status='unavailable'}}}|ConvertTo-Json -Depth 8)
            Remove-Item -LiteralPath (Join-Path $state 'status.txt') -Force -ErrorAction SilentlyContinue
            $proc=Start-Process -FilePath $definition.execute -ArgumentList $definition.arguments -WorkingDirectory $definition.workingDirectory -WindowStyle Hidden -Wait -PassThru
            Assert ($proc.ExitCode -eq 0)
            Assert (Test-Path -LiteralPath (Join-Path $state 'status.txt'))
            $status=Read-Hotpl8Json (Join-Path $state 'status.json')
            Assert ($status.collector.scheduled -eq $true -and $status.claudeError -eq 'backoff')
        }finally{
            $env:USERPROFILE=$homeBefore
            [IO.File]::WriteAllBytes($policyPath,$original)
            foreach($name in @('status.txt','status.js','status.json','collector.json')){Remove-Item -LiteralPath (Join-Path $state $name) -Force -ErrorAction SilentlyContinue}
        }
    }
    Check 'an installation that updates itself is woken by the compiled program beside its launcher' {
        # As delivery/setup.py and an activation lay one out: releases, the pointer to the one
        # in force, and the compiled program beside the launcher. No task is registered here.
        $sha='b'*40;$managed=Join-Path $dir 'managed installation';$inForce=Join-Path $managed ('releases/'+$sha)
        [void][IO.Directory]::CreateDirectory((Join-Path $managed 'releases'))
        Copy-Item -LiteralPath (Join-Path $install 'app') -Destination $inForce -Recurse
        $installation=Read-Hotpl8Json (Join-Path $install 'installation.json')
        Write-Hotpl8Text (Join-Path $managed 'delivery.json') (@{stateDirectory=$state}|ConvertTo-Json) -NoBom
        $point={param($Release) Write-Hotpl8Text (Join-Path $managed 'current.json') ([ordered]@{protocol=1;sha=$sha;release=$Release}|ConvertTo-Json) -NoBom}
        & $point ('releases/'+$sha)
        $beside=Join-Path $managed 'hotpl8-native.exe'
        # Until this release's own copy is beside the launcher, the task keeps the start that
        # every release understands.
        $slow=' -File "'+(Join-Path $managed 'app/tick.ps1')+'" -Scheduled -StateDirectory '+(ConvertTo-NativeArgument $state)
        Assert ((Get-Hotpl8TaskDefinition $installation $managed).arguments.EndsWith($slow))
        [IO.File]::WriteAllText($beside,'the copy of another release')
        Assert ((Get-Hotpl8TaskDefinition $installation $managed).arguments.EndsWith($slow))
        [IO.File]::Copy((Join-Path $root 'bin/windows/hotpl8-native.exe'),$beside,$true)
        $definition=Get-Hotpl8TaskDefinition $installation $managed
        Assert ($definition.arguments.EndsWith(' '+(ConvertTo-NativeArgument $managed)+' '+(ConvertTo-NativeArgument $beside)+' wake'))
        Assert ($definition.name -ceq ('HotPl8-'+$installation.id) -and $definition.workingDirectory -ceq $managed -and (Test-Path -LiteralPath $definition.execute -PathType Leaf))
        $policyPath=Join-Path $state 'policy.json';$original=[IO.File]::ReadAllBytes($policyPath);$homeBefore=$env:USERPROFILE
        $text=Join-Path $state 'status.txt'
        try{
            # As in the check above: collection is due, and the backoff marker keeps it from cswap.
            $env:USERPROFILE=Join-Path $dir 'user home';[void][IO.Directory]::CreateDirectory($env:USERPROFILE)
            $p=Read-Hotpl8Json $policyPath;$p.prefer=@(1)
            Write-Hotpl8Text $policyPath ($p|ConvertTo-Json -Depth 12)
            $now=[datetimeoffset]::UtcNow
            Write-Hotpl8Text (Join-Path $state 'collector.json') (@{schemaVersion=1;providers=@{claude=@{lastAttemptAt=$now.ToString('o');failures=1;nextAttemptAt=$now.AddMinutes(30).ToString('o');status='unavailable'}}}|ConvertTo-Json -Depth 8)
            Remove-Item -LiteralPath $text -Force -ErrorAction SilentlyContinue
            $proc=Start-Process -FilePath $definition.execute -ArgumentList $definition.arguments -WorkingDirectory $definition.workingDirectory -WindowStyle Hidden -Wait -PassThru
            Assert ($proc.ExitCode -eq 0)
            Assert (Test-Path -LiteralPath $text)
            $status=Read-Hotpl8Json (Join-Path $state 'status.json')
            Assert ($status.collector.scheduled -eq $true -and $status.claudeError -eq 'backoff')
            # A wake during an update is not a failure, and collects nothing.
            Remove-Item -LiteralPath $text -Force
            $update=[IO.File]::Open((Join-Path $managed 'runtime.lock'),'OpenOrCreate','ReadWrite','None')
            try{& $beside wake;$code=$LASTEXITCODE}finally{$update.Dispose()}
            Assert ($code -eq 0 -and -not (Test-Path -LiteralPath $text))
            # A rollback can put a release from before the compiled collector back in force.
            # Its collector is its tick.ps1, started as delivery/launch.ps1 started it.
            Remove-Item -LiteralPath (Join-Path $inForce 'src/lane.ps1') -Force
            $seen=Join-Path $dir 'older tick.txt'
            $older='param([switch]$Scheduled,[string]$StateDirectory)'+"`r`n"+'[IO.File]::WriteAllText('''+$seen+''',(@([string]$Scheduled,$StateDirectory,$env:HOTPL8_STATE_DIRECTORY,$env:HOTPL8_INSTALL_DIRECTORY) -join ''|''))'+"`r`n"+'exit 7'+"`r`n"
            Write-Hotpl8Text (Join-Path $inForce 'tick.ps1') $older
            & $beside wake
            Assert ($LASTEXITCODE -eq 7 -and [IO.File]::ReadAllText($seen) -ieq (@('True',$state,$state,$managed) -join '|'))
            Assert (-not (Test-Path -LiteralPath $text))
            # An installation that cannot name its release is one.
            & $point 'releases/other'
            & $beside wake
            Assert ($LASTEXITCODE -eq 1)
        }finally{
            $env:USERPROFILE=$homeBefore
            [IO.File]::WriteAllBytes($policyPath,$original)
            foreach($name in @('status.txt','status.js','status.json','collector.json')){Remove-Item -LiteralPath (Join-Path $state $name) -Force -ErrorAction SilentlyContinue}
        }
    }
    # Automatic continue. Only the fixture Claude settings are read or written from here on.
    $settings=Join-Path $claude 'settings.json';$app=Join-Path $install 'app'
    $ownHook=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $app 'continue.ps1'),'-Provider','claude','-StateDirectory',[IO.Path]::GetFullPath($state)) -join '|'
    Check 'continue hook needs a Claude directory and an installation that owns the state' {
        $copy=Join-Path $dir 'plain copy/code';[void][IO.Directory]::CreateDirectory($copy)
        Set-Hotpl8ContinueHook $app $state
        Assert (-not (Test-Path -LiteralPath $claude))
        [void][IO.Directory]::CreateDirectory($claude)
        Set-Hotpl8ContinueHook $copy $state
        Set-Hotpl8ContinueHook $app (Join-Path $dir 'another state')
        Set-Hotpl8ContinueHook $app $state -Remove
        Assert (-not (Test-Path -LiteralPath $settings) -and -not (Test-Path -LiteralPath (Join-Path $state 'continue')) -and -not (Test-Hotpl8ContinueHook $state))
        $explicit=Get-Hotpl8ContinueHookCommand $copy $state -Explicit
        Assert ($explicit.args[4] -ceq (Join-Path $copy 'continue.ps1'))
        Set-Hotpl8ContinueHook $app $state
        $after=Read-Hotpl8Json $settings
        Assert (@($after.PSObject.Properties).Count -eq 1 -and $after.hooks.StopFailure.Count -eq 1 -and (Test-Hotpl8ContinueHook $state))
        Set-Hotpl8ContinueHook $app $state -Remove
        Assert (([IO.File]::ReadAllText($settings) -replace '\s','') -ceq '{}')
    }
    Check 'continue hook is added once and every other Claude setting survives' {
        # Shapes a JSON round trip can damage: empty and one-item lists, nesting, null, a
        # timestamp-looking string, and text outside ASCII.
        $fixture='{"model":"fixture-model","emptyList":[],"single":["only"],"nested":{"deep":{"value":1,"list":[[],[1]],"none":null,"flag":false}},'+
            '"stamp":"2026-01-02T03:04:05Z","words":"caf\u00e9 \u732b <tag> & ''quote''","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo before"}]}],'+
            '"StopFailure":[{"matcher":"rate_limit","hooks":[{"type":"command","command":"echo foreign"}]},{"hooks":[]}]}}'
        Write-Hotpl8Text $settings $fixture -NoBom
        Set-Hotpl8ContinueHook $app $state
        $after=Read-Hotpl8Json $settings
        Assert ($after.model -ceq 'fixture-model' -and $after.emptyList -is [array] -and $after.emptyList.Count -eq 0)
        Assert ($after.single -is [array] -and $after.single.Count -eq 1 -and $after.single[0] -ceq 'only')
        Assert ($after.nested.deep.value -eq 1 -and $after.nested.deep.list.Count -eq 2 -and $after.nested.deep.list[0].Count -eq 0 -and $after.nested.deep.list[1][0] -eq 1)
        Assert ($after.nested.deep.PSObject.Properties['none'] -and $null -eq $after.nested.deep.none -and $after.nested.deep.flag -eq $false)
        Assert ($after.stamp -is [string] -and $after.stamp -ceq '2026-01-02T03:04:05Z')
        Assert ($after.words -ceq ('caf'+[char]0xe9+' '+[char]0x732b+" <tag> & 'quote'"))
        Assert ($after.hooks.PreToolUse[0].matcher -ceq 'Bash' -and $after.hooks.PreToolUse[0].hooks[0].command -ceq 'echo before')
        Assert ($after.hooks.StopFailure.Count -eq 3 -and $after.hooks.StopFailure[0].hooks[0].command -ceq 'echo foreign' -and $after.hooks.StopFailure[1].hooks.Count -eq 0)
        $entry=$after.hooks.StopFailure[2];$hook=$entry.hooks[0]
        Assert ($entry.matcher -ceq 'rate_limit' -and $entry.hooks.Count -eq 1 -and $hook.type -ceq 'command' -and $hook.asyncRewake -eq $true -and $hook.timeout -eq 21700)
        Assert ($hook.command -ceq 'powershell.exe' -and ($hook.args -join '|') -ceq $ownHook)
        Assert (Test-Hotpl8ContinueHook $state)
        $hash=(Get-FileHash -LiteralPath $settings).Hash
        Set-Hotpl8ContinueHook $app $state
        Assert ((Get-FileHash -LiteralPath $settings).Hash -eq $hash)
        Set-Hotpl8ContinueHook $app $state -Remove
        $after=Read-Hotpl8Json $settings
        Assert ($after.hooks.StopFailure.Count -eq 2 -and $after.hooks.StopFailure[0].hooks[0].command -ceq 'echo foreign' -and $after.hooks.PreToolUse[0].hooks[0].command -ceq 'echo before')
        Assert ($after.words -ceq ('caf'+[char]0xe9+' '+[char]0x732b+" <tag> & 'quote'") -and $after.emptyList.Count -eq 0 -and $after.stamp -ceq '2026-01-02T03:04:05Z')
        Assert (-not (Test-Path -LiteralPath (Join-Path $state 'continue/hook.json')) -and -not (Test-Hotpl8ContinueHook $state))
    }
    Check 'a Claude settings file that cannot be rewritten safely is refused and left alone' {
        foreach($bad in @('not json','[]','{"hooks":[]}','{"hooks":{"StopFailure":{}}}')){
            Write-Hotpl8Text $settings $bad -NoBom;$before=(Get-FileHash -LiteralPath $settings).Hash;$threw=$false
            try{Set-Hotpl8ContinueHook $app $state}catch{$threw=$true}
            Assert ($threw -and (Get-FileHash -LiteralPath $settings).Hash -eq $before -and -not (Test-Hotpl8ContinueHook $state))
        }
        Remove-Item -LiteralPath $settings -Force
    }
    Check 'a managed installation gets a hook that finds its current release through awkward paths' {
        $managed=Join-Path $dir "managed o'install dir";$managedState=Join-Path $dir "managed o'state dir"
        $release=Join-Path $managed 'releases/fixture';[void][IO.Directory]::CreateDirectory($release);[void][IO.Directory]::CreateDirectory($managedState)
        Write-Hotpl8Text (Join-Path $managed 'current.json') '{"protocol":1,"sha":"fixture","release":"releases/fixture"}' -NoBom
        Write-Hotpl8Text (Join-Path $managed 'delivery.json') (@{stateDirectory=$managedState}|ConvertTo-Json) -NoBom
        Write-Hotpl8Text (Join-Path $release 'continue.ps1') ('param([string]$Provider,[string]$StateDirectory)'+"`n"+'[IO.File]::WriteAllText((Join-Path $StateDirectory "ran.txt"),$Provider);exit 2')
        $env:HOTPL8_INSTALL_DIRECTORY=$managed
        try{
            $hook=Get-Hotpl8ContinueHookCommand $release $managedState
            Assert ($hook.command -ceq 'powershell.exe' -and $hook.args[3] -ceq '-Command' -and $hook.args.Count -eq 5)
            # Run exactly what Claude would run: it must reach the release named by current.json.
            $shellArgs=@($hook.args)
            & $hook.command $shellArgs|Out-Null
            Assert ($LASTEXITCODE -eq 2 -and [IO.File]::ReadAllText((Join-Path $managedState 'ran.txt')) -ceq 'claude')
            # Another state directory is not this installation's to hook.
            Assert ($null -eq (Get-Hotpl8ContinueHookCommand $release $state))
        }finally{$env:HOTPL8_INSTALL_DIRECTORY=$null}
    }
    Check 'the collector keeps the Claude hook in step with policy and survives a broken settings file' {
        $policyPath=Join-Path $state 'policy.json';$original=[IO.File]::ReadAllBytes($policyPath)
        # One collection through the given copy. The backoff marker keeps it away from cswap.
        $collect={param([string]$Code,[bool]$Continue,[switch]$ObserveOnly)
            $p=Read-Hotpl8Json (Join-Path $source 'policy.example.json');$p.prefer=@(1)
            if(-not $Continue){$p.automation|Add-Member NoteProperty continue $false}
            Write-Hotpl8Text $policyPath ($p|ConvertTo-Json -Depth 12)
            $now=[datetimeoffset]::UtcNow
            Write-Hotpl8Text (Join-Path $state 'collector.json') (@{schemaVersion=1;providers=@{claude=@{lastAttemptAt=$now.ToString('o');failures=1;nextAttemptAt=$now.AddMinutes(30).ToString('o');status='unavailable'}}}|ConvertTo-Json -Depth 8)
            Remove-Item -LiteralPath (Join-Path $state 'status.json') -Force -ErrorAction SilentlyContinue
            $extra=@();if($ObserveOnly){$extra=@('-ObserveOnly')}
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Code 'tick.ps1') -Scheduled -StateDirectory $state @extra|Out-Null
            Assert ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $state 'status.json')))
        }
        try{
            & $collect $source $true
            Assert (-not (Test-Path -LiteralPath $settings))
            & $collect $app $true -ObserveOnly
            Assert (-not (Test-Path -LiteralPath $settings))
            & $collect $app $true
            Assert ((Test-Hotpl8ContinueHook $state) -and ((Read-Hotpl8Json $settings).hooks.StopFailure[0].hooks[0].args -join '|') -ceq $ownHook)
            & $collect $app $false -ObserveOnly
            Assert (Test-Hotpl8ContinueHook $state)
            & $collect $app $false
            Assert (-not (Test-Hotpl8ContinueHook $state) -and -not (Read-Hotpl8Json $settings).hooks)
            Write-Hotpl8Text $settings 'not json' -NoBom
            & $collect $app $true
            Assert ([IO.File]::ReadAllText($settings) -ceq 'not json')
            Assert ((Get-Content -LiteralPath (Join-Path $state 'events.jsonl') -Raw) -match '"continue_hook_failed"')
        }finally{
            [IO.File]::WriteAllBytes($policyPath,$original)
            foreach($name in @('status.txt','status.js','status.json','collector.json','events.jsonl')){Remove-Item -LiteralPath (Join-Path $state $name) -Force -ErrorAction SilentlyContinue}
            Remove-Item -LiteralPath $settings -Force -ErrorAction SilentlyContinue
        }
    }
    Check 'one installed dashboard update reaches watch and nyan through the same launcher' {
        $renderer=Join-Path $source 'src/dashboard.ps1';$checksums=Join-Path $source 'checksums.json'
        $original=[IO.File]::ReadAllBytes($renderer);$originalHashes=[IO.File]::ReadAllBytes($checksums)
        try{
            # Simulate a later shared-dashboard update in a fixture release.
            Add-Content -LiteralPath $renderer -Encoding UTF8 -Value "`nfunction New-DashboardTitleRow { New-DashboardRow 'SHARED UPDATE PROBE' text }"
            $hashes=Read-Hotpl8Json $checksums
            $hashes.'src/dashboard.ps1'=(Get-FileHash $renderer -Algorithm SHA256).Hash
            Write-Hotpl8Text $checksums ($hashes|ConvertTo-Json -Depth 4) -NoBom
            & (Join-Path $source 'install.ps1') -InstallDirectory $install -NoPath|Out-Null
            foreach($mode in @('watch','nyan')){
                $output=& (Join-Path $install 'hotpl8.cmd') $mode -ReducedMotion
                Assert ($LASTEXITCODE -eq 0 -and ($output -join "`n").Contains('SHARED UPDATE PROBE'))
            }
            foreach($asset in @('src/presentation.ps1','data/nyan-frames.json')){
                Assert ((Get-FileHash (Join-Path $install ('app/'+$asset))).Hash -eq (Get-FileHash (Join-Path $source $asset)).Hash)
            }
        }finally{
            [IO.File]::WriteAllBytes($renderer,$original);[IO.File]::WriteAllBytes($checksums,$originalHashes)
            & (Join-Path $source 'install.ps1') -InstallDirectory $install -NoPath|Out-Null
        }
    }
    Check 'tampered archive refuses upgrade before changing installed code' {
        $path=Join-Path $source 'VERSION';$original=[IO.File]::ReadAllText($path)
        [IO.File]::WriteAllText($path,'99.0.0')
        $threw=$false
        try{& (Join-Path $source 'install.ps1') -InstallDirectory $install -NoPath|Out-Null}catch{$threw=$true}
        finally{[IO.File]::WriteAllText($path,$original)}
        Assert $threw
        Assert ((Get-Content (Join-Path $install 'app/VERSION') -Raw).Trim() -ne '99.0.0')
    }
    Check 'held collector lock prevents update without changing app or policy' {
        $appBefore=(Get-FileHash (Join-Path $install 'app/VERSION')).Hash
        $policyBefore=(Get-FileHash (Join-Path $state 'policy.json')).Hash
        $lock=[IO.File]::Open((Join-Path $state 'tick.lock'),'OpenOrCreate','ReadWrite','None')
        $rejected=$false
        try{try{& (Join-Path $source 'install.ps1') -InstallDirectory $install -NoPath|Out-Null}catch{$rejected=$true}}finally{$lock.Dispose()}
        Assert ($rejected -and (Get-FileHash (Join-Path $install 'app/VERSION')).Hash -eq $appBefore)
        Assert ((Get-FileHash (Join-Path $state 'policy.json')).Hash -eq $policyBefore)
    }
    Check 'incompatible previous reader blocks rollback before removing current app' {
        $reader=Join-Path $install 'previous/src/config.ps1';$original=[IO.File]::ReadAllText($reader)
        $before=(Get-FileHash (Join-Path $install 'app/VERSION')).Hash
        [IO.File]::WriteAllText($reader,'function Assert-Hotpl8Policy($Policy) { if($Policy.schemaVersion -gt 1){throw "unsupported schema"} }')
        $rejected=$false
        try{try{& (Join-Path $source 'rollback.ps1') -InstallDirectory $install|Out-Null}catch{$rejected=$true}}finally{[IO.File]::WriteAllText($reader,$original)}
        Assert ($rejected -and (Get-FileHash (Join-Path $install 'app/VERSION')).Hash -eq $before)
        Assert (Test-Path -LiteralPath (Join-Path $install 'previous/VERSION'))
    }
    Check 'rollback restores previous code and preserves state' {
        $before=(Get-FileHash (Join-Path $state 'policy.json')).Hash
        [IO.File]::WriteAllText((Join-Path $install 'app/VERSION'),'0.2.0-test')
        & (Join-Path $source 'rollback.ps1') -InstallDirectory $install|Out-Null
        Assert ((Get-FileHash (Join-Path $state 'policy.json')).Hash -eq $before)
        Assert (Test-Path -LiteralPath (Join-Path $install 'app/VERSION'))
        Assert (-not (Test-Path -LiteralPath (Join-Path $install 'previous')))
        Assert ((Get-Content (Join-Path $install 'app/VERSION') -Raw).Trim() -ne '0.2.0-test')
    }
    Check 'unrelated destination and drive-root deletion refused' {
        $foreign=Join-Path $dir 'foreign';[void][IO.Directory]::CreateDirectory($foreign)
        [IO.File]::WriteAllText((Join-Path $foreign 'keep.txt'),'keep')
        $threw=$false;try{& (Join-Path $source 'install.ps1') -InstallDirectory $foreign -NoPath|Out-Null}catch{$threw=$true}
        Assert $threw;Assert (Test-Path -LiteralPath (Join-Path $foreign 'keep.txt'))
        $threw=$false;try{$null=Assert-Hotpl8Path ([IO.Path]::GetPathRoot($dir))}catch{$threw=$true};Assert $threw
    }
    Check 'installation paths refuse user links but accept root-owned system links' {
        $target=Join-Path $dir 'link-target';[void][IO.Directory]::CreateDirectory($target)
        $link=Join-Path $dir 'user-link'
        # Windows needs Developer Mode or elevation to create a link; the reparse check still applies.
        $made=$true;try{$null=New-Item -ItemType SymbolicLink -Path $link -Target $target}catch{$made=$false}
        if($made){$threw=$false;try{$null=Assert-Hotpl8Path (Join-Path $link 'app')}catch{$threw=$true};Assert $threw}
        # macOS temp and /var sit behind root-owned links in /; they must not block installation.
        if($env:OS -ne 'Windows_NT' -and (Get-Item -LiteralPath '/var' -Force).LinkType -eq 'SymbolicLink'){$null=Assert-Hotpl8Path '/var/hotpl8-example/app'}
    }
    Check 'managed delivery uninstall refuses before any mutation' {
        $marker=Join-Path $install 'installation.json';$original=[IO.File]::ReadAllText($marker)
        $managed=Read-Hotpl8Json $marker;$managed|Add-Member NoteProperty managedBy 'local-delivery' -Force
        Write-Hotpl8Text $marker ($managed|ConvertTo-Json -Depth 12)
        Write-Hotpl8Text (Join-Path $state 'delivery-owner.json') '{"fixture":"OWNERSHIP_SENTINEL"}'
        $before=@(Get-ChildItem -LiteralPath $install,$state -File -Recurse|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash}) -join "`n"
        $reason=''
        try{
            try{& (Join-Path $source 'uninstall.ps1') -InstallDirectory $install|Out-Null}catch{$reason=$_.Exception.Message}
            $after=@(Get-ChildItem -LiteralPath $install,$state -File -Recurse|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash}) -join "`n"
            Assert ($reason -match 'Local Delivery' -and $before -ceq $after)
        }finally{[IO.File]::WriteAllText($marker,$original)}
    }
    Check 'invalid policy prevents uninstall before hooks or installed files change' {
        $path=Join-Path $state 'policy.json';$original=[IO.File]::ReadAllText($path)
        Write-Hotpl8Text $path '{"schemaVersion":99}'
        $before=@(Get-ChildItem -LiteralPath $install,$state -File -Recurse|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash}) -join "`n"
        $rejected=$false
        try{
            try{& (Join-Path $source 'uninstall.ps1') -InstallDirectory $install|Out-Null}catch{$rejected=$true}
            $after=@(Get-ChildItem -LiteralPath $install,$state -File -Recurse|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash}) -join "`n"
            Assert ($rejected -and $before -ceq $after)
        }finally{[IO.File]::WriteAllText($path,$original)}
    }
    Check 'v3 uninstall removes owned canonical and registered hooks while preserving native data' {
        $native=Join-Path $dir 'native account'
        [void][IO.Directory]::CreateDirectory($native)
        [IO.File]::WriteAllText((Join-Path $native 'auth.json'),'NATIVE_AUTH_SENTINEL')
        $aliasHome=Join-Path $dir 'registered native account';[void][IO.Directory]::CreateDirectory($aliasHome)
        [IO.File]::WriteAllText((Join-Path $aliasHome 'auth.json'),'ALIAS_AUTH_SENTINEL')
        [IO.File]::WriteAllText((Join-Path $aliasHome 'conversation.json'),'CONVERSATION_SENTINEL')
        $definition=Read-Hotpl8Json (Join-Path $source 'data/providers/codex.json');$definition.id='fictional';$definition.name='Fictional'
        foreach($package in @($source,(Join-Path $install 'app'))){
            Write-Hotpl8Text (Join-Path $package 'data/providers/fictional.json') ($definition|ConvertTo-Json -Depth 12)
            $manifest=Read-Hotpl8Json (Join-Path $package 'release-files.json');$manifest.files+=@('data/providers/fictional.json')
            Write-Hotpl8Text (Join-Path $package 'release-files.json') ($manifest|ConvertTo-Json -Depth 4)
        }
        $p=[pscustomobject]@{schemaVersion=3;mode='monitor';providers=[pscustomobject]@{codex=[pscustomobject]@{slots=@([pscustomobject]@{id='main';home=$native})};fictional=[pscustomobject]@{slots=@([pscustomobject]@{id='alias';home=$aliasHome})}}}
        Write-Hotpl8Text (Join-Path $state 'policy.json') ($p|ConvertTo-Json -Depth 12)
        $command='powershell -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path (Join-Path $install 'app') 'status-print.ps1')+'" -Provider codex -StateDirectory "'+$state+'"'
        $hooks=@{hooks=@{SessionStart=@(@{matcher='startup';hooks=@(@{type='command';command=$command},@{type='command';command='echo unrelated'})});OtherEvent=@(@{command='keep'})}}
        Write-Hotpl8Text (Join-Path $native 'hooks.json') ($hooks|ConvertTo-Json -Depth 12) -NoBom
        $aliasCommand=$command.Replace('-Provider codex ','-Provider fictional ')
        $foreignCommand=$aliasCommand.Replace($install,(Join-Path $dir 'other installation'))
        $aliasHooks=@{hooks=@{SessionStart=@(@{matcher='startup';hooks=@(@{type='command';command=$aliasCommand},@{type='command';command=$command},@{type='command';command=$foreignCommand},@{type='command';command='echo alias unrelated'})});OtherEvent=@(@{command='alias keep'})}}
        Write-Hotpl8Text (Join-Path $aliasHome 'hooks.json') ($aliasHooks|ConvertTo-Json -Depth 12) -NoBom
        [IO.File]::WriteAllText((Join-Path $install 'keep.txt'),'keep')
        Write-Hotpl8Text $settings '{"hooks":{"StopFailure":[{"hooks":[{"type":"command","command":"echo foreign"}]}]}}' -NoBom
        Set-Hotpl8ContinueHook $app $state
        Assert (Test-Hotpl8ContinueHook $state)
        $before=(Get-FileHash (Join-Path $state 'policy.json')).Hash
        & (Join-Path $source 'uninstall.ps1') -InstallDirectory $install|Out-Null
        $claudeAfter=Read-Hotpl8Json $settings
        Assert ($claudeAfter.hooks.StopFailure.Count -eq 1 -and $claudeAfter.hooks.StopFailure[0].hooks[0].command -ceq 'echo foreign')
        Assert (-not (Test-Path -LiteralPath (Join-Path $state 'continue/hook.json')))
        Assert (-not (Test-Path -LiteralPath (Join-Path $install 'app')))
        Assert ((Get-FileHash (Join-Path $state 'policy.json')).Hash -eq $before)
        Assert (Test-Path -LiteralPath (Join-Path $install 'keep.txt'))
        Assert ([Environment]::GetEnvironmentVariable('Path','User') -ceq $pathBefore)
        Assert ([IO.File]::ReadAllText((Join-Path $native 'auth.json')) -ceq 'NATIVE_AUTH_SENTINEL')
        $after=Read-Hotpl8Json (Join-Path $native 'hooks.json')
        Assert (@($after.hooks.SessionStart[0].hooks).Count -eq 1)
        Assert ($after.hooks.SessionStart[0].hooks[0].command -eq 'echo unrelated')
        Assert ($after.hooks.OtherEvent[0].command -eq 'keep')
        Assert ([IO.File]::ReadAllText((Join-Path $aliasHome 'auth.json')) -ceq 'ALIAS_AUTH_SENTINEL')
        Assert ([IO.File]::ReadAllText((Join-Path $aliasHome 'conversation.json')) -ceq 'CONVERSATION_SENTINEL')
        $after=Read-Hotpl8Json (Join-Path $aliasHome 'hooks.json')
        Assert (@($after.hooks.SessionStart[0].hooks).Count -eq 3)
        Assert ($command -cin @($after.hooks.SessionStart[0].hooks.command) -and $foreignCommand -cin @($after.hooks.SessionStart[0].hooks.command))
        Assert ($after.hooks.OtherEvent[0].command -eq 'alias keep')
        Assert ((Read-Hotpl8Json (Join-Path $state 'delivery-owner.json')).fixture -ceq 'OWNERSHIP_SENTINEL')
    }
}finally{
    $env:CLAUDE_CONFIG_DIR=$claudeBefore;$env:HOTPL8_INSTALL_DIRECTORY=$installBefore
    $full=[IO.Path]::GetFullPath($dir)
    if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-install-test-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
'passed='+$script:passed+' failed='+$script:failed
if($script:failed){exit 1}
