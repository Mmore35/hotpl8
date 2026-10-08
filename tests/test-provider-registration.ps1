# Registry conformance and a descriptor-only third provider through an isolated
# product package. Native reads are synthetic; no live homes or credentials.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($name in @('common','config','management')){. (Join-Path $root ('src/'+$name+'.ps1'))}
$script:passed=0;$script:failed=0
function Assert($Value,[string]$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check($Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message}}
function Reject([scriptblock]$Body){$rejected=$false;try{& $Body|Out-Null}catch{$rejected=$true};Assert $rejected 'expected rejection'}
function Json($Value){ConvertTo-Json -InputObject $Value -Depth 32 -Compress}
$catalog=@(Get-Hotpl8ProviderCatalog)
$before=Json $catalog
$lab=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-provider-catalog-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($lab)
try{
    Check 'shipped definitions are validated data with fixed reviewed drivers' {
        Assert ($catalog.Count -ge 2)
        Assert ((Get-Hotpl8ProviderDefinition claude).driver -ceq 'claude-cswap')
        Assert ((Get-Hotpl8ProviderDefinition codex).driver -ceq 'codex-app-server')
        Assert ((Get-Hotpl8ProviderDriver 'claude-cswap').healthyPollSeconds -eq 60)
        Assert ((Get-Hotpl8ProviderDriver 'codex-app-server').healthyPollSeconds -eq 300)
        Assert ((Get-Hotpl8ProviderDefinition claude).integrations.t3 -ceq 'claudeAgent')
        Assert ((Get-Hotpl8ProviderDefinition codex).integrations.t3 -ceq 'codex')
    }
    Check 'catalog returns independent definitions and driver capability objects' {
        $copy=Get-Hotpl8ProviderDefinition codex;$copy.name='changed'
        $copy.capabilities.t3Rollover=$false
        Assert ((Get-Hotpl8ProviderDefinition codex).name -eq 'Codex')
        Assert (Get-Hotpl8ProviderDefinition codex).capabilities.t3Rollover
        $driver=Get-Hotpl8ProviderDriver 'codex-app-server';$driver.capabilities.warming=$true
        Assert (-not (Get-Hotpl8ProviderDriver 'codex-app-server').capabilities.warming)
    }
    Check 'unknown drivers and providers are refused' {
        foreach($id in @('unknown','Codex-App-Server','../adapter.ps1','powershell -Command bad')){Reject {Get-Hotpl8ProviderDriver $id}}
        foreach($id in @('CODEX','../codex','absent')){Reject {Get-Hotpl8ProviderDefinition $id}}
    }
    Check 'unsupported policy versions are rejected before legacy classification' {
        foreach($version in @('3','2',0,4,99,$true,$null,@(3))){
            $p=[pscustomobject]@{schemaVersion=$version;prefer=@()}
            Reject {Get-Hotpl8ConfiguredProviders $p}
        }
        Reject {Get-Hotpl8ConfiguredProviders @{}}
    }
    Check 'legacy policies retain every original value without applying descriptor defaults' {
        foreach($version in @(0,1,2)){
            $p='{"prefer":[1],"margin7d":44,"codex":{"slots":[],"margin7d":37}}'|ConvertFrom-Json
            if($version){$p|Add-Member NoteProperty schemaVersion $version;$p|Add-Member NoteProperty mode 'monitor'}
            $snapshot=Json $p;$records=@(Get-Hotpl8ConfiguredProviders $p)
            $claude=@($records|Where-Object id -CEQ claude)[0];$codex=@($records|Where-Object id -CEQ codex)[0]
            Assert ((Json $claude.policy) -ceq $snapshot)
            Assert ((Json $codex.policy) -ceq (Json $p.codex))
            Assert ($claude.isLegacy -and $codex.isLegacy)
            Assert (-not $claude.policy.PSObject.Properties['order'] -and -not $codex.policy.PSObject.Properties['margin7dWork'])
            Assert ((Json $p) -ceq $snapshot)
        }
    }
    Check 'missing legacy action flags remain missing and root controls are not injected into native policy' {
        $p='{"prefer":[1],"codex":{"slots":[]}}'|ConvertFrom-Json
        $records=@(Get-Hotpl8ConfiguredProviders $p)
        foreach($r in $records){Assert (-not $r.controls.PSObject.Properties['switchEnabled']);Assert (-not $r.controls.PSObject.Properties['mode'])}
        $codex=@($records|Where-Object id -CEQ codex)[0]
        Assert (-not $codex.policy.PSObject.Properties['schemaVersion'] -and -not $codex.policy.PSObject.Properties['mode'])
    }
    Check 'v3 defaults never invent a lower work-account weekly floor' {
        $p='{"schemaVersion":3,"mode":"monitor","providers":{"codex":{"slots":[],"margin7d":44},"claude":{"prefer":[1],"margin7d":39}}}'|ConvertFrom-Json
        $records=@(Get-Hotpl8ConfiguredProviders $p)
        foreach($r in $records){Assert (-not $r.policy.PSObject.Properties['margin7dWork']);Assert ($r.policy.order -eq 'prefer')}
        Assert (@($records|Where-Object id -CEQ codex)[0].policy.margin7d -eq 44)
        Assert (@($records|Where-Object id -CEQ claude)[0].policy.margin7d -eq 39)
        $p.providers.codex|Add-Member NoteProperty margin7dWork 5
        Assert (@(Get-Hotpl8ConfiguredProviders $p|Where-Object id -CEQ codex)[0].policy.margin7dWork -eq 5)
    }
    Check 'normalization preserves empty and singleton arrays and does not alias policy data' {
        $p='{"schemaVersion":3,"mode":"monitor","providers":{"codex":{"slots":[],"prefer":["one"]}}}'|ConvertFrom-Json
        $snapshot=Json $p;$r=@(Get-Hotpl8ConfiguredProviders $p)[0]
        Assert ($r.policy.slots -is [array] -and $r.policy.slots.Count -eq 0)
        Assert ($r.policy.prefer -is [array] -and $r.policy.prefer.Count -eq 1 -and $r.policy.prefer[0] -ceq 'one')
        Assert ((Json $r.policy.slots) -ceq '[]')
        $r.policy.prefer[0]='changed';Assert ((Json $p) -ceq $snapshot)
    }
    Check 'v3 maps reject unknown providers mixed legacy ownership and malformed parts' {
        foreach($json in @(
            '{"schemaVersion":3,"providers":{"unknown":{}}}',
            '{"schemaVersion":3,"providers":{"Codex":{}}}',
            '{"schemaVersion":3,"providers":{ "codex":[]}}',
            '{"schemaVersion":3,"providers":[],"mode":"monitor"}',
            '{"schemaVersion":3,"providers":{},"prefer":[]}',
            '{"schemaVersion":3,"providers":{},"codex":{}}',
            '{"schemaVersion":3,"providers":{},"capacity":{}}',
            '{"schemaVersion":2,"providers":{}}')){
            $p=$json|ConvertFrom-Json;Reject {Get-Hotpl8ConfiguredProviders $p}
        }
        $p='{"schemaVersion":2,"codex":[]}'|ConvertFrom-Json;Reject {Get-Hotpl8ConfiguredProviders $p}
    }
    Check 'configured membership and optional unconfigured inventory remain distinct' {
        $p='{"schemaVersion":3,"mode":"monitor","providers":{}}'|ConvertFrom-Json
        Assert (@(Get-Hotpl8ConfiguredProviders $p).Count -eq 0)
        $all=@(Get-Hotpl8ConfiguredProviders $p -IncludeUnconfigured)
        Assert ($all.Count -eq 2 -and @($all|Where-Object configured).Count -eq 0)
        foreach($r in $all){Assert ($null -eq $r.policy)}
    }
    Check 'registry reads do not modify the source catalog' {
        Assert ((Json $catalog) -ceq $before)
        Assert ((Json @(Get-Hotpl8ProviderCatalog)) -ceq $before)
    }
    Check 'a move to version 3 gives the selection the policy its weekly floors are worked out of' {
        # The floor worked out of each of these policies is held by the recorded rule cases.
        $shared='"mode":"automate","switchEnabled":false,"warm":false,"probeEnabled":false,"prefer":[1],'
        $rest='"hysteresis":0,"order":"prefer","margin5h":0,"schemaVersion":2}'
        foreach($case in @(
            @{name='omitted reserve';reserve=@(1);view='"reserve":[1],"resetLeadMin":10,"margin7d":20,'},
            @{name='explicit zero reserve';reserve=@(1);margin7d=0;view='"reserve":[1],"margin7d":0,"resetLeadMin":10,'},
            @{name='work override';reserve=@();margin7dWork=5;view='"reserve":[],"margin7dWork":5,"resetLeadMin":10,"margin7d":20,'},
            @{name='zero work override';reserve=@();margin7dWork=0;view='"reserve":[],"margin7dWork":0,"resetLeadMin":10,"margin7d":20,'},
            @{name='reserve ignores work override';reserve=@(1);margin7dWork=5;view='"reserve":[1],"margin7dWork":5,"resetLeadMin":10,"margin7d":20,'}
        )){
            $legacy=[pscustomobject]@{schemaVersion=2;mode='automate';prefer=@(1);reserve=$case.reserve}
            foreach($key in @('margin7d','margin7dWork')){if($case.ContainsKey($key)){$legacy|Add-Member NoteProperty $key $case[$key]}}
            Assert-Hotpl8Policy $legacy
            $original=Json $legacy
            $migrated=ConvertTo-Hotpl8PolicyV3 $legacy;Assert-Hotpl8Policy $migrated
            $view=Get-Hotpl8ProviderView $null $migrated claude
            Assert ((Json $view.policy) -ceq ('{'+$shared+$case.view+$rest)) ($case.name+': '+(Json $view.policy))
            Assert ((Json $legacy) -ceq $original) ($case.name+': migration mutated source policy')
        }
    }
    Check 'descriptor and enrollment only reaches collector CLI UI API MCP controls and diagnostics' {
        $package=Join-Path $lab 'package';[void][IO.Directory]::CreateDirectory($package)
        $manifest=Get-Content (Join-Path $root 'release-files.json') -Raw|ConvertFrom-Json
        $files=@($manifest.files)+@($manifest.platformFiles.windows)
        foreach($file in @($files|Select-Object -Unique)){
            $target=Join-Path $package $file;[void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
            [IO.File]::Copy((Join-Path $root $file),$target,$true)
        }
        $d=Get-Hotpl8ProviderDefinition codex;$d.id='fictional';$d.name='Fictional';$d.display.order=30
        [IO.File]::WriteAllText((Join-Path $package 'data/providers/fictional.json'),(Json $d))
        $probe=Join-Path $lab 'exercise-package.ps1'
        $probeText=@'
param([string]$Package)
$ErrorActionPreference='Stop'
foreach($name in @('common','config','diagnostics','management','agent-api','mcp','native','tray','collection')){. (Join-Path $Package ('src/'+$name+'.ps1'))}
function Assert($Value,[string]$Message){if(-not $Value){throw $Message}}
# The dashboard as the package's compiled reader draws it from a state directory.
function Shown([string]$Directory){
    $drawn=Invoke-Hotpl8NativeProcess (Get-Hotpl8NativePath $Package) @('watch','--root',$Package,'--state',$Directory,'--size','110x200')
    Assert ($drawn.exitCode -eq 0 -and $drawn.errors -eq '') ('dashboard not drawn: '+$drawn.exitCode+' '+$drawn.errors)
    $drawn.output
}
function Reject([scriptblock]$Body,[string]$Message){$rejected=$false;try{& $Body|Out-Null}catch{$rejected=$true};Assert $rejected $Message}
function Request([string]$Operation,$Arguments=@{}){Invoke-Hotpl8AgentRequest ([pscustomobject]@{apiVersion=1;operation=$Operation;arguments=[pscustomobject]$Arguments}) $state}
function Hash-State { @((Get-ChildItem -LiteralPath $state -File -Recurse|Sort-Object FullName|ForEach-Object {(Get-FileHash -LiteralPath $_.FullName).Hash})) -join ':' }
$state=Join-Path (Split-Path $Package -Parent) 'state';[void][IO.Directory]::CreateDirectory($state)
$homePath=Join-Path (Split-Path $Package -Parent) 'fictional-native-home';[void][IO.Directory]::CreateDirectory($homePath)
$policyPath=Join-Path $state 'policy.json'
Write-Hotpl8Text $policyPath '{"schemaVersion":2,"mode":"monitor","prefer":[],"codex":{"slots":[]}}'
$old=(Get-FileHash $policyPath).Hash
$preview=Add-Hotpl8RegisteredAccount $state 'fictional' 'one' $homePath 'PRIVATE-FIXTURE-LABEL'
Assert ($preview.operation -eq 'policy-migration-preview' -and (Get-FileHash $policyPath).Hash -eq $old) 'preview must not write policy'
function Read-CodexQuota {param($AccountHome,$Executable,$TimeoutMs) [pscustomobject]@{status='ok';identityKey='fictional-only';standardTransport=$true;modelProvider='openai'}}
Add-Hotpl8RegisteredAccount $state 'fictional' 'one' $homePath 'PRIVATE-FIXTURE-LABEL' -MigratePolicy|Out-Null
$policy=Read-Hotpl8Json $policyPath
Assert ($policy.schemaVersion -eq 3 -and $policy.providers.fictional.slots[0].id -eq 'one') 'registered enrollment missing'
Assert ($policy.mode -eq 'monitor' -and -not $policy.switchEnabled) 'migration enabled actions'
$enrolled=(Get-FileHash $policyPath).Hash
Add-Hotpl8RegisteredAccount $state 'fictional' 'one' $homePath 'PRIVATE-FIXTURE-LABEL'|Out-Null
Assert ((Get-FileHash $policyPath).Hash -eq $enrolled) 'repeated enrollment changed policy'
Assert-Hotpl8Policy $policy
$sameHome=Copy-Hotpl8ProviderValue $policy
$sameHome.providers.codex.slots=@([pscustomobject]@{id='other';home=$homePath})
Reject {Assert-Hotpl8Policy $sameHome} 'same home accepted under two provider IDs'
$anotherHome=Join-Path (Split-Path $Package -Parent) 'another-fictional-home';[void][IO.Directory]::CreateDirectory($anotherHome)
Reject {Add-Hotpl8RegisteredAccount $state codex other $anotherHome ''} 'same subscription enrolled under two provider IDs'
Assert ((Get-FileHash $policyPath).Hash -eq $enrolled) 'failed enrollment changed policy'
$claudeAlias=Get-Hotpl8ProviderDefinition claude;$claudeAlias.id='fictional-claude';$claudeAlias.name='Fictional Claude'
Write-Hotpl8Text (Join-Path $Package 'data/providers/fictional-claude.json') ($claudeAlias|ConvertTo-Json -Depth 12)
$twoOwners=Copy-Hotpl8ProviderValue $policy
$twoOwners.providers.claude.prefer=@(1)
$twoOwners.providers|Add-Member NoteProperty 'fictional-claude' ([pscustomobject]@{prefer=@(2)})
Reject {Assert-Hotpl8Policy $twoOwners} 'two global activation owners accepted'
# A program that answers as Codex does, with one fictional account.
$codex=Join-Path (Split-Path $Package -Parent) 'fake codex.exe'
Add-Type -Path (Join-Path $Package 'tests/fake-codex.cs') -ReferencedAssemblies System.Web.Extensions -OutputAssembly $codex -OutputType ConsoleApplication
& (Join-Path $Package 'tick.ps1') -StateDirectory $state -ObserveOnly -CodexExecutable $codex -Strict
Assert ($LASTEXITCODE -eq 0) ('generic collector failed: '+$(if(Test-Path -LiteralPath (Join-Path $state 'events.jsonl')){[IO.File]::ReadAllText((Join-Path $state 'events.jsonl'))}))
$snapshot=Read-Hotpl8Snapshot $state
Assert ($snapshot.providers.fictional.slots[0].status -eq 'ok' -and $snapshot.providers.fictional.recommendedSlot -eq 'one') 'generic collection or selection missing'
Assert ($snapshot.collector.providers.fictional.status -eq 'ok') 'provider scheduling not keyed by registration'
Assert (Test-Path -LiteralPath (Join-Path $state 'providers/fictional/codex-state.json')) 'native cache namespace missing'
Assert (-not (Test-Path -LiteralPath (Join-Path $state 'codex-state.json'))) 'alias overwrote canonical native cache'
Assert ($snapshot.providerOverview.fictional.accounts -eq 1 -and $snapshot.providerOverview.fictional.selected -eq 'one') 'overview omitted registered provider'
$before=Hash-State
$readiness=Request readiness @{provider='fictional'}
Assert ($readiness.ok -and $readiness.data.provider -eq 'fictional' -and $readiness.data.eligible -and $readiness.data.selectedSlot -eq 'one') 'API readiness omitted registration'
$status=Request status
Assert ($status.ok -and $status.data.providers.fictional.eligible) 'API status omitted registration'
Assert (($status|ConvertTo-Json -Depth 32) -notmatch 'PRIVATE-FIXTURE-LABEL|fictional-native-home|identityKey|accessToken') 'private data leaked into API'
$shown=Shown $state
Assert ($shown -cmatch 'FICTIONAL  /  1 subscription' -and $shown -cmatch 'NEXT LAUNCH') 'dashboard omitted registered account'
$tools=@(Get-Hotpl8McpTools $false)
Assert ('fictional' -in @($tools|Where-Object name -EQ hotpl8_readiness)[0].inputSchema.properties.provider.enum) 'MCP schema omitted registration'
$tray=Read-Hotpl8TrayModel $state $Package
Assert ($tray.details -match 'Fictional' -or $tray.details -match 'FICTIONAL') 'tray omitted registration'
$doctor=Get-Hotpl8Doctor $state
Assert ($doctor.policyValid -and $doctor.providers.fictional.configured) 'diagnostics omitted registration'
$capabilities=Get-Hotpl8Capabilities $state
Assert ($capabilities.providers.fictional.driver -eq 'codex-app-server') 'capability dispatch missing'
$replay=Invoke-Hotpl8Replay @($snapshot) $policy
Assert (@($replay.decisions|Where-Object stream -Like 'fictional/*').Count -eq 8) 'replay omitted registered provider'
$ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$cli=Invoke-Hotpl8Process $ps @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Package 'hotpl8.ps1'),'accounts','-StateDirectory',$state,'-Provider','fictional','-AsJson') 90000
Assert ($cli.exitCode -eq 0 -and ($cli.output|ConvertFrom-Json).provider -contains 'fictional') 'real CLI rejected registered provider'
$doctorCli=Invoke-Hotpl8Process $ps @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Package 'hotpl8.ps1'),'doctor','-StateDirectory',$state) 90000
Assert ($doctorCli.exitCode -eq 0 -and $doctorCli.output -match 'Fictional: enrolled' -and $doctorCli.output -notmatch 'NO ACCOUNTS') 'CLI doctor lost alias-only installation'
$statusCli=Invoke-Hotpl8Process $ps @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Package 'hotpl8.ps1'),'status','-StateDirectory',$state) 90000
Assert ($statusCli.exitCode -eq 0 -and $statusCli.output -match 'PRIVATE-FIXTURE-LABEL') 'CLI status omitted registered slot details'
Assert ((Hash-State) -eq $before) 'cached readers wrote state'
$aliasState=Get-Hotpl8ProviderStateDirectory $state fictional
$orphanState=Join-Path $state 'providers/unregistered';[void][IO.Directory]::CreateDirectory($orphanState)
Write-Hotpl8Text (Join-Path $state 'usage-history.json') '{"schemaVersion":1,"samples":[{"key":"a"},{"key":"b"}]}'
Write-Hotpl8Text (Join-Path $aliasState 'usage-history.json') '{"schemaVersion":1,"samples":[{"key":"c"},{"key":"d"},{"key":"e"}]}'
Write-Hotpl8Text (Join-Path $orphanState 'usage-history.json') '{"schemaVersion":1,"samples":[{"key":"retained"}]}'
$historyCli=Invoke-Hotpl8Process $ps @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Package 'hotpl8.ps1'),'history','-StateDirectory',$state) 90000
$history=$historyCli.output|ConvertFrom-Json
Assert ($historyCli.exitCode -eq 0 -and $history.samples -eq 5 -and $history.stores.Count -eq 2) 'history omitted alias or double-counted canonical store'
$clearCli=Invoke-Hotpl8Process $ps @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Package 'hotpl8.ps1'),'history','-Operation','clear','-StateDirectory',$state) 90000
Assert ($clearCli.exitCode -eq 0 -and @((Read-Hotpl8Json (Join-Path $aliasState 'usage-history.json')).samples).Count -eq 0 -and @((Read-Hotpl8Json (Join-Path $state 'usage-history.json')).samples).Count -eq 0) 'history clear missed configured stores'
Assert (@((Read-Hotpl8Json (Join-Path $orphanState 'usage-history.json')).samples).Count -eq 1) 'history clear deleted unregistered residual state'
$narrow=Get-Hotpl8ProviderDefinition fictional;$narrow.meters=@('codex')
Write-Hotpl8Text (Join-Path $Package 'data/providers/fictional.json') ($narrow|ConvertTo-Json -Depth 12)
$narrowReplay=Invoke-Hotpl8Replay @($snapshot) $policy
Assert (@($narrowReplay.decisions|Where-Object stream -Like 'fictional/*').Count -eq 4 -and @($narrowReplay.summary|Where-Object stream -Like 'fictional/codex_bengalfox/*').Count -eq 0) 'replay invented unsupported registered meter'
$at=[datetimeoffset]::UtcNow
# Two events as the collector records them, one under the native family's name.
$activityPath=Join-Path $aliasState 'activity.json';$recorded=@()
if(Test-Path -LiteralPath $activityPath){$recorded=@((Read-Hotpl8Json $activityPath).events|Where-Object {$_})}
foreach($entry in @(@('codex',-2),@('fictional',-1))){$recorded+=[pscustomobject]@{id=[guid]::NewGuid().ToString('N');at=$at.AddSeconds($entry[1]).ToString('o');provider=$entry[0];slot='one';kind='recommendation';reason='fixture'}}
Write-Hotpl8Text $activityPath ([pscustomobject]@{events=$recorded;schemaVersion=1}|ConvertTo-Json -Depth 4)
& (Join-Path $Package 'tick.ps1') -StateDirectory $state -ObserveOnly -CodexExecutable $codex -Strict
Assert ($LASTEXITCODE -eq 0) 'collection with recorded activity failed'
$snapshot=Read-Hotpl8Snapshot $state
Assert (@($snapshot.recentActions|Where-Object provider -CEQ fictional).Count -ge 2) 'native or registered activity event omitted'
$shown=Shown $state
Assert ($shown -cmatch 'RECENT' -and $shown -cmatch 'fictional next' -and $shown -cnotmatch 'codex next') 'activity mislabeled registered provider'
# The same state with the account signed out, in a directory of its own.
$failedState=Join-Path (Split-Path $Package -Parent) 'failed-state';[void][IO.Directory]::CreateDirectory($failedState)
[IO.File]::Copy($policyPath,(Join-Path $failedState 'policy.json'))
$failedSnapshot=Read-Hotpl8Json (Join-Path $state 'status.json');$failedSnapshot.providers.fictional.slots[0].status='authentication_required'
Write-Hotpl8Text (Join-Path $failedState 'status.json') ($failedSnapshot|ConvertTo-Json -Depth 32 -Compress)
$failedRows=Shown $failedState
Assert ($failedRows -cmatch 'AUTHENTICATION REQUIRED' -and $failedRows -notmatch 'account unavailable') 'a later registered provider must show its failed account on its own row'
Assert (@($snapshot.shadow|Where-Object stream -Like 'fictional/codex_bengalfox/*').Count -eq 0) 'shadow comparison invented unsupported registered meter'
Set-Hotpl8Pause $state 5 'fixture'
$paused=Request readiness @{provider='fictional'}
Assert ($paused.data.automationPaused -and $paused.data.eligible) 'pause lost or explicit admission blocked'
Write-Hotpl8Text (Join-Path $state 'hold.json') (@{until=[datetimeoffset]::UtcNow.AddMinutes(5).ToString('o')}|ConvertTo-Json)
Assert (Request readiness @{provider='fictional'}).data.selectionHeld 'shared hold not observed'
$policy=Set-Hotpl8Account $policy fictional one disable ''
Save-Hotpl8Policy $state $policy (Get-FileHash $policyPath).Hash
Assert (-not (Request readiness @{provider='fictional'}).data.eligible) 'registered disable ignored'
$policy=Set-Hotpl8Account $policy fictional one enable ''
$policy=Set-Hotpl8Account $policy fictional one rename 'RENAMED'
$policy=Set-Hotpl8Account $policy fictional one reserve ''
Assert ($policy.schemaVersion -eq 3 -and $policy.providers.fictional.slots[0].label -eq 'RENAMED' -and $policy.providers.fictional.reserve -contains 'one') 'v3 account edits lost data'
$policy=Set-Hotpl8Account $policy fictional one remove ''
Save-Hotpl8Policy $state $policy (Get-FileHash $policyPath).Hash
Assert (@(Get-Hotpl8ProviderAccounts $policy|Where-Object provider -CEQ fictional).Count -eq 0) 'registered removal failed'
$manual=Read-Hotpl8Json (Join-Path $state 'policy.previous.json')
$manual.providers.fictional|Add-Member NoteProperty disabled @() -Force
$manual.providers.codex.slots=@([pscustomobject]@{id='other';home=$anotherHome})
$manual.providers.codex|Add-Member NoteProperty prefer @('other') -Force
Save-Hotpl8Policy $state $manual (Get-FileHash $policyPath).Hash
& (Join-Path $Package 'tick.ps1') -StateDirectory $state -ObserveOnly -CodexExecutable $codex
$duplicates=Read-Hotpl8Snapshot $state
Assert ($duplicates.providers.codex.slots[0].status -eq 'duplicate_subscription' -and $duplicates.providers.fictional.slots[0].status -eq 'duplicate_subscription') 'manual cross-provider duplicate escaped collector quarantine'
Assert (-not $duplicates.providers.codex.recommendedSlot -and -not $duplicates.providers.fictional.recommendedSlot) 'duplicate subscription retained a recommendation'
Write-Output 'ISOLATED THIRD PROVIDER PASSED'
'@
        [IO.File]::WriteAllText($probe,$probeText,(New-Object Text.UTF8Encoding($true)))
        $ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $output=& $ps -NoProfile -ExecutionPolicy Bypass -File $probe -Package $package 2>&1
        Assert ($LASTEXITCODE -eq 0 -and ($output -join "`n") -match 'ISOLATED THIRD PROVIDER PASSED') ($output -join "`n")
    }
}finally{
    $full=[IO.Path]::GetFullPath($lab)
    if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-provider-catalog-[a-f0-9]{32}$'){
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
'Provider registry: '+$script:passed+' passed, '+$script:failed+' failed.'
if($script:failed){exit 1}
