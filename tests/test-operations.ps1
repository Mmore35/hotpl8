# Offline contracts for persistent automation, estimates, replay and desktop delivery.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($file in @('common','config','diagnostics','insights','management','collection','updates','tray')){. (Join-Path $root ('src/'+$file+'.ps1'))}
. (Join-Path $root 'src/providers/claude.ps1')
. (Join-Path $root 'src/providers/codex.ps1')
. (Join-Path $PSScriptRoot 'fixtures/screenshots.ps1')
$script:passed=0;$script:failed=0
function Assert($Value,[string]$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check([string]$Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message+' at '+$_.InvocationInfo.ScriptLineNumber}}
function Clone($Value){$Value|ConvertTo-Json -Depth 24|ConvertFrom-Json}
function Reject([scriptblock]$Body){$rejected=$false;try{& $Body|Out-Null}catch{$rejected=$true};Assert $rejected 'expected rejection'}
$dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-operations-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
$now=[datetimeoffset]::Parse('2026-09-13T12:00:00Z')
try{
    Check 'one provider storage failure does not mark the other provider unhealthy' {
        # As the collector records a read that worked beside one it could not write down.
        $at=$now.ToString('o')
        $c=[pscustomobject]@{startedAt=$at;completedAt=$at;status='incomplete';providers=[pscustomobject]@{
            claude=[pscustomobject]@{lastAttemptAt=$at;lastSuccessAt=$at;failures=0;nextAttemptAt=$now.AddMinutes(5).ToString('o');status='ok'}
            codex=[pscustomobject]@{lastAttemptAt=$at;lastSuccessAt=$null;failures=1;nextAttemptAt=$now.AddMinutes(1).ToString('o');status='unavailable';failureCode='state_io_failed'}}}
        Assert ((Get-Hotpl8Health $c $now claude) -eq 'recent collection completed')
        Assert ((Get-Hotpl8Health $c $now codex) -eq 'local state write failed; retrying')
        Assert ((Get-Hotpl8Health $c $now) -eq 'local state write failed; retrying')
    }
    Check 'completed snapshot outranks its older collector started marker' {
        $p=Read-Hotpl8Json (Join-Path $root 'policy.example.json')
        $started=$now.AddSeconds(-2).ToString('o');$done=$now.ToString('o')
        Write-Hotpl8Text (Join-Path $dir 'status.json') (@{generatedAt=$done;slots=@();collector=@{startedAt=$started;completedAt=$done;status='ok'}}|ConvertTo-Json -Depth 5)
        Write-Hotpl8Text (Join-Path $dir 'collector.json') (@{startedAt=$started;completedAt=$now.AddMinutes(-1).ToString('o');status='ok'}|ConvertTo-Json)
        $s=Read-Hotpl8Snapshot $dir $p
        Assert ($s.collector.completedAt -eq $done)
        Write-Hotpl8Text (Join-Path $dir 'collector.json') (@{startedAt=$now.AddSeconds(1).ToString('o');completedAt=$done;status='ok'}|ConvertTo-Json)
        $s=Read-Hotpl8Snapshot $dir $p
        Assert ($s.collector.startedAt -eq $now.AddSeconds(1).ToString('o')) 'a genuinely newer in-progress collection stays visible'
    }
    Check 'work hours handle Sunday and overnight day ownership' {
        $s=[pscustomobject]@{days=@(0);start='10:00';end='14:00';timeZone='UTC'}
        Assert (Test-Hotpl8WorkTime $s $now)
        Assert (-not (Test-Hotpl8WorkTime $s $now.AddHours(2)))
        $s.start='22:00';$s.end='02:00'
        Assert (Test-Hotpl8WorkTime $s $now.AddHours(13))
        Assert (-not (Test-Hotpl8WorkTime $s $now.AddHours(-11)))
        Assert-Hotpl8AutomationPolicy (Clone @{automation=@{schedule=$s}})
    }
    Check 'invalid work days time zone and budgets fail validation' {
        foreach($a in @(@{dailyAttemptLimit=0},@{dailyAttemptLimit='12'},@{schedule=@{days=@(0);start='25:00';end='12:00'}},@{schedule=@{days=@(0,0);start='10:00';end='12:00'}},@{schedule=@{days=@(0);start='10:00';end='12:00';timeZone='not-a-time-zone'}})){
            Reject {Assert-Hotpl8AutomationPolicy (Clone @{automation=$a})}
        }
    }
    Check 'persistent pause is read back until it is resumed' {
        Set-Hotpl8Pause $dir 60 'test pause'
        Assert ((Get-Hotpl8Pause $dir).reason -ceq 'test pause')
        Set-Hotpl8Pause $dir 0 'resumed';Assert ($null -eq (Get-Hotpl8Pause $dir))
    }
    Check 'malformed pause fails closed' {
        Write-Hotpl8Text (Join-Path $dir 'automation-pause.json') '{'
        Assert ((Get-Hotpl8Pause $dir).invalid)
        Set-Hotpl8Pause $dir 0 'resumed'
    }
    Check 'policy migration preserves explicit monitor preferences and legacy defaults' {
        $p=ConvertTo-Hotpl8PolicyV2 (Clone @{schemaVersion=1;mode='monitor';switchEnabled=$true;probeEnabled=$true})
        Assert ($p.schemaVersion -eq 2 -and $p.switchEnabled -and $p.probeEnabled -and -not (Get-Hotpl8Actions $p $false).switching)
        $p=ConvertTo-Hotpl8PolicyV2 (Clone @{prefer=@(1);warm=$true})
        Assert ((Get-Hotpl8Actions $p $false).switching -and (Get-Hotpl8Actions $p $false).probing)
    }
    Check 'new controls cannot bypass validation through a legacy policy or null model entry' {
        Reject {Assert-Hotpl8Policy (Clone @{mode='automate';claudeModels=@('opus')})}
        Reject {Assert-Hotpl8Policy (Clone @{schemaVersion=2;mode='automate';claudeModels=@($null)})}
        Reject {Assert-Hotpl8Policy (Clone @{order='balanced'})}
    }
    Check 'account edits preserve unrelated policy and fail on unknown slots' {
        $p=Clone @{schemaVersion=1;mode='monitor';prefer=@(1);labels=@{'1'='old'};warm=$false}
        $p=Set-Hotpl8Account $p claude 1 rename new
        $p=Set-Hotpl8Account $p claude 1 disable ''
        $p=Set-Hotpl8Account $p claude 1 reserve ''
        Assert ($p.labels.'1' -eq 'new' -and 1 -in $p.disabled -and 1 -in $p.reserve -and -not $p.warm)
        Assert-Hotpl8Policy $p
        Reject {Set-Hotpl8Account $p claude 9 disable ''}
    }
    Check 'policy save rejects concurrent edits and keeps a compatible backup' {
        $p=Clone @{schemaVersion=1;mode='monitor'}
        Write-Hotpl8Text (Join-Path $dir 'policy.json') ($p|ConvertTo-Json)
        $hash=(Get-FileHash (Join-Path $dir 'policy.json')).Hash
        Save-Hotpl8Policy $dir (ConvertTo-Hotpl8PolicyV2 $p) $hash
        Assert ((Read-Hotpl8Json (Join-Path $dir 'policy.previous.json')).schemaVersion -eq 1)
        Reject {Save-Hotpl8Policy $dir $p $hash}
        Assert ((Read-Hotpl8Json (Join-Path $dir 'policy.json')).schemaVersion -eq 2)
    }
    Check 'health distinguishes collecting stalled overdue and partial collection' {
        $s=Clone @{startedAt=$now.ToString('o')}
        Assert ((Get-Hotpl8Health $s $now) -eq 'collecting')
        Assert ((Get-Hotpl8Health $s $now.AddMinutes(5)) -eq 'collector stalled')
        $s|Add-Member NoteProperty completedAt $now.AddSeconds(1).ToString('o');$s|Add-Member NoteProperty status 'incomplete'
        Assert ((Get-Hotpl8Health $s $now.AddMinutes(1)) -eq 'provider checks incomplete')
        Assert ((Get-Hotpl8Health $s $now.AddMinutes(16)) -eq 'collector overdue')
    }
    Check 'a stalled first collection is visible before any status snapshot exists' {
        $first=Join-Path $dir 'first-collection';[void][IO.Directory]::CreateDirectory($first)
        Write-Hotpl8Text (Join-Path $first 'collector.json') (@{schemaVersion=1;startedAt=$now.AddMinutes(-10).ToString('o')}|ConvertTo-Json)
        $s=Read-Hotpl8Snapshot $first
        Assert ($null -eq $s.generatedAt -and (Get-Hotpl8Health $s.collector $now) -eq 'collector stalled')
        Assert (-not (Test-Path -LiteralPath (Join-Path $first 'status.json')))
    }
    Check 'a native launch read skips only the reader-side display summaries' {
        $launch=Join-Path $dir 'launch-read';[void][IO.Directory]::CreateDirectory($launch)
        $f=Get-Hotpl8ScreenshotFixture
        # The collector publishes its own overview in status.json; a launch read leaves it as stored.
        $f.status|Add-Member NoteProperty providerOverview ([pscustomobject]@{stored='collector copy'}) -Force
        Write-Hotpl8Text (Join-Path $launch 'policy.json') ($f.policy|ConvertTo-Json -Depth 24)
        Write-Hotpl8Text (Join-Path $launch 'status.json') ($f.status|ConvertTo-Json -Depth 24)
        $full=Read-Hotpl8Snapshot $launch;$lean=Read-Hotpl8Snapshot $launch -SkipDisplay
        Assert ($full.providerOverview.codex -and -not $full.providerOverview.stored -and $full.PSObject.Properties['parkCandidates']) 'default read recomputes the overview and adds park advice'
        Assert ($lean.providerOverview.stored -ceq 'collector copy' -and -not $lean.PSObject.Properties['parkCandidates']) 'launch read keeps the stored snapshot and computes no display summary'
        foreach($snapshot in @($full,$lean)){foreach($name in @('providerOverview','parkCandidates')){if($snapshot.PSObject.Properties[$name]){$snapshot.PSObject.Properties.Remove($name)}}}
        Assert ($full.providers.codex -and ($full|ConvertTo-Json -Depth 24) -ceq ($lean|ConvertTo-Json -Depth 24)) 'everything a launch reads is unchanged'
    }
    Check 'weekly-expiry and balanced ranking have distinct defined objectives' {
        $early=$now.AddDays(1).ToString('o');$late=$now.AddDays(5).ToString('o')
        Assert ((Get-Hotpl8SelectionKey weekly-expiry 50 20 $early $now) -lt (Get-Hotpl8SelectionKey weekly-expiry 90 90 $late $now))
        Assert ((Get-Hotpl8SelectionKey balanced 50 80 $early $now) -lt (Get-Hotpl8SelectionKey balanced 90 90 $late $now))
        Assert ((Get-Hotpl8SelectionKey weekly-expiry 100 100 '' $now) -eq [double]::MaxValue)
    }
    Check 'shadow replay respects Codex disabled and reserve eligibility in every strategy' {
        $f=Get-Hotpl8ScreenshotFixture
        $f.policy.codex|Add-Member NoteProperty disabled @('work')
        $r=Invoke-Hotpl8Replay @($f.status) $f.policy
        Assert (@($r.decisions|Where-Object {$_.stream -like 'codex/*' -and $_.selected -eq 'work'}).Count -eq 0)
        Assert (@($r.decisions|Where-Object {-not $_.selected -and $_.reserve}).Count -eq 0)
        Assert ($r.frames -eq 1 -and $r.limitation.Contains('does not measure quota savings'))
    }
    Check 'replay holds expire at the frame clock and malformed holds do not strand selection' {
        $p=Clone @{prefer=@(2,1);reserve=@();margin5h=25;margin7d=20;hysteresis=0}
        $s=Clone @{generatedAt=$now.ToString('o');active=1;slots=@(foreach($id in @(1,2)){@{slot=$id;status='ok';fresh=$true;observedAt=$now.ToString('o');used5h=10;used7d=10;reset5h=$now.AddHours(2).ToString('o');reset7d=$now.AddDays(3).ToString('o')}})}
        foreach($until in @($now.AddSeconds(-1).ToString('o'),'invalid',$null)){
            $s|Add-Member NoteProperty hold @{until=$until} -Force
            $r=Invoke-Hotpl8Replay @($s) $p
            Assert (@($r.decisions|Where-Object stream -EQ 'claude/prefer')[0].selected -eq 2) 'expired/invalid hold suppressed selection'
        }
        $s.hold.until=$now.AddMinutes(5).ToString('o')
        Assert (@((Invoke-Hotpl8Replay @($s) $p).decisions|Where-Object stream -EQ 'claude/prefer')[0].selected -eq 1) 'active hold did not retain eligible current account'
    }
    Check 'history inventory counts the canonical shared store once' {
        $p=Clone @{prefer=@(1);codex=@{slots=@(@{id='one';home='C:\fixture'})}}
        Write-Hotpl8Text (Join-Path $dir 'usage-history.json') '{"schemaVersion":1,"samples":[{"key":"claude/x"},{"key":"codex/y"}]}'
        $stores=@(Get-Hotpl8HistoryStores $p $dir)
        Assert ($stores.Count -eq 1 -and $stores[0].samples -eq 2 -and $stores[0].providers.Count -eq 2)
    }
    Check 'disabled Codex homes are not polled and explicit launch cannot bypass disabling' {
        $p=Clone @{slots=@(@{id='off';home=(Join-Path $dir 'off')},@{id='on';home=(Join-Path $dir 'on')});disabled=@('off');prefer=@('off','on')}
        $script:quotaReads=0
        $reader={param($homePath,$executable,$budget) $script:quotaReads++;return @{status='home_missing';elapsedMs=0}}
        $s=Invoke-CodexCollection $p $dir '' $null $reader
        Assert ($script:quotaReads -eq 1 -and ($s.slots|Where-Object id -EQ off).status -eq 'disabled')
        Reject {Get-CodexLaunchPlan $p $s off '' @() $now}
    }
    Check 'explanations show recorded reasons and warn on stale snapshots' {
        $s=Clone @{generatedAt=$now.AddHours(-1).ToString('o');decision=@{policy='balanced';reason='switch held';accounts=@(@{slot=2;reason='model_below_margin';rank=1})}}
        $text=(Format-Hotpl8Explanation $s $now)-join ' '
        Assert ($text.Contains('STALE') -and $text.Contains('model_below_margin') -and $text.Contains('switch held'))
        $alias=Clone @{generatedAt=$now.ToString('o');providers=@{fictional=@{decision=@{policy='prefer';reason='switch held';accounts=@(@{slot=2;reason='scoped_margin';rank=1})}}};providerOverview=@{}}
        $text=(Format-Hotpl8Explanation $alias $now)-join ' '
        Assert ($text.Contains('fictional: switch held') -and $text.Contains('scoped_margin')) 'numeric-driver alias lost recorded decision details'
    }
    Check 'notifications are opt-in and quiet-hour aware' {
        $s=Clone @{collector=@{startedAt=$now.AddHours(-1).ToString('o')}}
        Assert (@(Get-Hotpl8Alerts $s (Clone @{notificationsEnabled=$false}) $now).Count -eq 0)
        $p=Clone @{notificationsEnabled=$true;automation=@{schedule=@{days=@(1);start='09:00';end='17:00';timeZone='UTC'}}}
        Assert (@(Get-Hotpl8Alerts $s $p $now).Count -eq 0)
    }
    Check 'notifications survive restarts without reset-drift duplicates and rearm on recovery' {
        $c=Clone @{key='codex/opaque/codex/weekly';title='Quota';text='estimate'}
        $first=Select-Hotpl8NewAlerts @($c) $null $now
        $saved=Clone $first.state
        Assert ($first.deliver.Count -eq 1 -and (Select-Hotpl8NewAlerts @($c) $saved $now.AddMinutes(5)).deliver.Count -eq 0)
        $recovered=Select-Hotpl8NewAlerts @() $saved $now
        Assert ((Select-Hotpl8NewAlerts @($c) (Clone $recovered.state) $now).deliver.Count -eq 1)
    }
    Check 'stale forecasts cannot emit depletion alerts' {
        $s=Clone @{slots=@(@{slot=1;fresh=$true;observedAt=$now.AddHours(-1).ToString('o');forecast=@{lastsToReset=$false}})}
        Assert (@(Get-Hotpl8Alerts $s (Clone @{notificationsEnabled=$true}) $now).Count -eq 0)
    }
    Check 'tray model is read-only and has the same decision explanation' {
        $f=Get-Hotpl8ScreenshotFixture;$before=$f.status|ConvertTo-Json -Depth 24
        $m=Get-Hotpl8TrayModel $f.status $f.policy $f.now
        Assert ($m.details.Contains('Managed host sessions require their own confirmed routing evidence') -and ($f.status|ConvertTo-Json -Depth 24) -eq $before)
    }
    Check 'release checks choose stable versus preview and enforce asset origin' {
        $stable=Clone @{tag_name='v1.0.0';prerelease=$false;draft=$false;published_at='2026-09-01';html_url='https://github.com/Mmore35/hotpl8/releases/tag/v1.0.0';assets=@(@{name='hotpl8-1.0.0-windows.zip';browser_download_url='https://github.com/Mmore35/hotpl8/releases/download/v1.0.0/hotpl8-1.0.0-windows.zip'})}
        $preview=Clone $stable;$preview.tag_name='v1.1.0-rc.1';$preview.prerelease=$true;$preview.published_at='2026-09-02';$preview.assets[0].name='hotpl8-1.1.0-rc.1-windows.zip';$preview.assets[0].browser_download_url='https://github.com/Mmore35/hotpl8/releases/download/v1.1.0-rc.1/hotpl8-1.1.0-rc.1-windows.zip'
        $fetch={param($url) @($stable,$preview)}
        Assert ((Get-Hotpl8Release stable '' $fetch).version -eq '1.0.0')
        Assert ((Get-Hotpl8Release preview '' $fetch).version -eq '1.1.0-rc.1')
        $preview.assets[0].browser_download_url='https://example.invalid/package.zip'
        Reject {Get-Hotpl8Release preview '' $fetch}
        Reject {Get-Hotpl8Release stable '../bad' $fetch}
    }
    Check 'release commit resolution rejects malformed source identity' {
        Assert ((Get-Hotpl8ReleaseCommit v1.0.0 {param($url) @{sha=('a'*40)}}) -eq ('a'*40))
        Reject {Get-Hotpl8ReleaseCommit v1.0.0 {param($url) @{sha='main'}}}
    }
    Check 'semantic update ordering handles stable and numbered previews' {
        Assert (Test-Hotpl8NewerVersion '0.2.0' '0.2.0-rc.10')
        Assert (Test-Hotpl8NewerVersion '0.2.0-rc.10' '0.2.0-rc.2')
        Assert (-not (Test-Hotpl8NewerVersion '0.2.0-rc.1' '0.2.0'))
        Assert (-not (Test-Hotpl8NewerVersion '0.1.0' '0.2.0'))
        Assert (-not (Test-Hotpl8NewerVersion '0.2.0' '0.2.0'))
    }
    Check 'archive traversal is rejected before any extraction' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        Add-Type -AssemblyName System.IO.Compression
        $path=Join-Path $dir 'bad.zip';$zip=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create)
        try{$null=$zip.CreateEntry('../outside.txt')}finally{$zip.Dispose()}
        $dest=Join-Path $dir 'extracted';Reject {Expand-Hotpl8VerifiedArchive $path $dest}
        Assert (-not (Test-Path -LiteralPath $dest))
    }
    Check 'failed download and rejected provenance never invoke the installer' {
        $ownedPath=Join-Path $dir 'owned';[void][IO.Directory]::CreateDirectory($ownedPath)
        Write-Hotpl8Text (Join-Path $ownedPath 'installation.json') '{"product":"hotpl8","version":"0.1.0"}'
        function Get-Hotpl8ReleaseCommit { return ('a'*40) }
        function Get-Command {
            [CmdletBinding()]param([string]$Name)
            if($Name -eq 'gh'){return [pscustomobject]@{Source='fixture-gh.exe'}}
            Microsoft.PowerShell.Core\Get-Command $Name
        }
        function Invoke-WebRequest {
            param($Uri,$OutFile,$TimeoutSec,[switch]$UseBasicParsing)
            if($script:downloadFails){throw 'fixture interrupted download'}
            [IO.File]::WriteAllText($OutFile,'fixture bytes')
        }
        function Invoke-Hotpl8Process {
            param($Executable,$Arguments,$TimeoutMs)
            $script:updateCalls++
            Assert ($Arguments[0] -eq 'attestation' -and '--source-digest' -in $Arguments -and '--deny-self-hosted-runners' -in $Arguments)
            return @{exitCode=1;output=''}
        }
        # Command resolution, download and verifier are injected; no network/process runs.
        $release=Clone @{version='0.2.0';tag='v0.2.0';name='hotpl8-0.2.0-windows.zip';url='https://example.invalid/fixture.zip'}
        $script:updateCalls=0;$script:downloadFails=$true
        Reject {Install-Hotpl8Update $release $ownedPath ''}
        Assert ($script:updateCalls -eq 0)
        $script:downloadFails=$false
        Reject {Install-Hotpl8Update $release $ownedPath ''}
        Assert ($script:updateCalls -eq 1)
        Assert (@(Get-ChildItem -LiteralPath $ownedPath -File).Count -eq 1)
    }
    Check 'new modules are present in the release manifest' {
        $manifest=Read-Hotpl8Json (Join-Path $root 'release-files.json')
        foreach($file in Get-ChildItem (Join-Path $root 'src') -Filter '*.ps1'){Assert (('src/'+$file.Name) -in $manifest.files) $file.Name}
    }
}finally{
    $full=[IO.Path]::GetFullPath($dir);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if((Split-Path $full -Parent) -eq $temp -and (Split-Path $full -Leaf) -match '^hotpl8-operations-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
'passed='+$script:passed+' failed='+$script:failed
if($script:failed){exit 1}
