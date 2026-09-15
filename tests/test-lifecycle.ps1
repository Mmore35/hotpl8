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
try{
    Check 'package is reproducible and contains only allowlisted source' {
        $zip=& (Join-Path $root 'scripts/package.ps1') -OutputDirectory (Join-Path $dir 'build')
        $hash=(Get-FileHash -LiteralPath $zip).Hash
        $again=& (Join-Path $root 'scripts/package.ps1') -OutputDirectory (Join-Path $dir 'build')
        Assert ((Get-FileHash -LiteralPath $again).Hash -eq $hash)
        $archive=[IO.Compression.ZipFile]::OpenRead($zip)
        try{
            $entries=@($archive.Entries|ForEach-Object FullName)
            Assert ($entries.Count -eq (@(Get-Hotpl8ReleaseFiles $root).Count+1))
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
        & (Join-Path $source 'uninstall.ps1') -InstallDirectory $retry|Out-Null
        Assert (Test-Path -LiteralPath $retryPolicy)
    }
    Check 'fresh archive installs without editing PATH or native homes' {
        & (Join-Path $source 'install.ps1') -InstallDirectory $install -StateDirectory $state -NoPath|Out-Null
        $p=Read-Hotpl8Json (Join-Path $state 'policy.json')
        Assert ($p.mode -eq 'monitor' -and -not $p.warm)
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
    Check 'uninstall keeps state and unrelated files' {
        $native=Join-Path $dir 'native account'
        [void][IO.Directory]::CreateDirectory($native)
        [IO.File]::WriteAllText((Join-Path $native 'auth.json'),'NATIVE_AUTH_SENTINEL')
        $p=Read-Hotpl8Json (Join-Path $state 'policy.json')
        $p.codex.slots=@([pscustomobject]@{id='main';home=$native})
        Write-Hotpl8Text (Join-Path $state 'policy.json') ($p|ConvertTo-Json -Depth 12)
        $command='powershell -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path (Join-Path $install 'app') 'status-print.ps1')+'" -Provider codex -StateDirectory "'+$state+'"'
        $hooks=@{hooks=@{SessionStart=@(@{matcher='startup';hooks=@(@{type='command';command=$command},@{type='command';command='echo unrelated'})});OtherEvent=@(@{command='keep'})}}
        Write-Hotpl8Text (Join-Path $native 'hooks.json') ($hooks|ConvertTo-Json -Depth 12) -NoBom
        [IO.File]::WriteAllText((Join-Path $install 'keep.txt'),'keep')
        $before=(Get-FileHash (Join-Path $state 'policy.json')).Hash
        & (Join-Path $source 'uninstall.ps1') -InstallDirectory $install|Out-Null
        Assert (-not (Test-Path -LiteralPath (Join-Path $install 'app')))
        Assert ((Get-FileHash (Join-Path $state 'policy.json')).Hash -eq $before)
        Assert (Test-Path -LiteralPath (Join-Path $install 'keep.txt'))
        Assert ([Environment]::GetEnvironmentVariable('Path','User') -ceq $pathBefore)
        Assert ([IO.File]::ReadAllText((Join-Path $native 'auth.json')) -ceq 'NATIVE_AUTH_SENTINEL')
        $after=Read-Hotpl8Json (Join-Path $native 'hooks.json')
        Assert (@($after.hooks.SessionStart[0].hooks).Count -eq 1)
        Assert ($after.hooks.SessionStart[0].hooks[0].command -eq 'echo unrelated')
        Assert ($after.hooks.OtherEvent[0].command -eq 'keep')
    }
}finally{
    $full=[IO.Path]::GetFullPath($dir)
    if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-install-test-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
'passed='+$script:passed+' failed='+$script:failed
if($script:failed){exit 1}
