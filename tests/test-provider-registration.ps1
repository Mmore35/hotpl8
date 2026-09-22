# Isolated registry/normalization conformance only. This foundation is not yet
# connected to production collection, enrollment, UI, API or T3 migration. A
# descriptor appearing here does NOT establish the full third-provider contract.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/provider-registry.ps1')
$script:passed=0;$script:failed=0
function Assert($Value,[string]$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check($Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message}}
function Reject([scriptblock]$Body){$rejected=$false;try{& $Body|Out-Null}catch{$rejected=$true};Assert $rejected 'expected rejection'}
function Json($Value){ConvertTo-Json -InputObject $Value -Depth 32 -Compress}
$catalog=@(Get-Hotpl8ProviderCatalog)
$before=Json $catalog
$lab=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-provider-catalog-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($lab)
function Write-Definition($Definition,[string]$Name='fictional.json'){
    [IO.File]::WriteAllText((Join-Path $lab $Name),(Json $Definition))
}
try{
    Check 'shipped definitions are validated data with fixed reviewed drivers' {
        Assert ($catalog.Count -eq 2)
        Assert ((Get-Hotpl8ProviderDefinition claude $catalog).driver -ceq 'claude-cswap')
        Assert ((Get-Hotpl8ProviderDefinition codex $catalog).driver -ceq 'codex-app-server')
        foreach($definition in $catalog){Assert-Hotpl8ProviderDefinition $definition}
        Assert ((Get-Hotpl8ProviderDriver 'claude-cswap').healthyPollSeconds -eq 60)
        Assert ((Get-Hotpl8ProviderDriver 'codex-app-server').healthyPollSeconds -eq 300)
        Assert ((Get-Hotpl8ProviderDefinition claude $catalog).integrations.t3 -ceq 'claudeAgent')
        Assert ((Get-Hotpl8ProviderDefinition codex $catalog).integrations.t3 -ceq 'codex')
    }
    Check 'catalog returns independent definitions and driver capability objects' {
        $copy=Get-Hotpl8ProviderDefinition codex $catalog;$copy.name='changed'
        $copy.capabilities.t3Rollover=$false
        Assert ((Get-Hotpl8ProviderDefinition codex $catalog).name -eq 'Codex')
        Assert (Get-Hotpl8ProviderDefinition codex $catalog).capabilities.t3Rollover
        $driver=Get-Hotpl8ProviderDriver 'codex-app-server';$driver.capabilities.warming=$true
        Assert (-not (Get-Hotpl8ProviderDriver 'codex-app-server').capabilities.warming)
    }
    Check 'unknown drivers and executable paths cannot register code' {
        foreach($id in @('unknown','Codex-App-Server','../adapter.ps1','powershell -Command bad')){Reject {Get-Hotpl8ProviderDriver $id}}
        foreach($id in @('CODEX','../codex','absent')){Reject {Get-Hotpl8ProviderDefinition $id $catalog}}
        $d=Get-Hotpl8ProviderDefinition codex $catalog
        $d|Add-Member NoteProperty command 'anything';Reject {Assert-Hotpl8ProviderDefinition $d}
        $d.PSObject.Properties.Remove('command');$d|Add-Member NoteProperty driverOptions ([pscustomobject]@{module='anything'})
        Reject {Assert-Hotpl8ProviderDefinition $d}
    }
    Check 'definitions cannot grant unsupported native capabilities' {
        $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.capabilities.warming=$true
        Reject {Assert-Hotpl8ProviderDefinition $d}
        $d=Get-Hotpl8ProviderDefinition claude $catalog;$d.capabilities.t3Rollover=$true
        Reject {Assert-Hotpl8ProviderDefinition $d}
        $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.capabilities.t3Rollover=$false
        Assert-Hotpl8ProviderDefinition $d
        $d.capabilities.observation='true';Reject {Assert-Hotpl8ProviderDefinition $d}
    }
    Check 'legacy IDs cannot be reassigned to a different native protocol' {
        $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.id='claude'
        Reject {Assert-Hotpl8ProviderDefinition $d}
        $d=Get-Hotpl8ProviderDefinition claude $catalog;$d.id='codex'
        Reject {Assert-Hotpl8ProviderDefinition $d}
    }
    Check 'meter and model constraints cannot escape a driver contract' {
        foreach($meters in @(@('codex','codex'),@('unverified'))){
            $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.meters=$meters
            Reject {Assert-Hotpl8ProviderDefinition $d}
        }
        $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.defaultMeter='unknown'
        Reject {Assert-Hotpl8ProviderDefinition $d}
        $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.modelMeters=[pscustomobject]@{'fictional-model'='unknown'}
        Reject {Assert-Hotpl8ProviderDefinition $d}
        $d.modelMeters=[pscustomobject]@{'bad/name'='codex'};Reject {Assert-Hotpl8ProviderDefinition $d}
        $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.meters='codex';Reject {Assert-Hotpl8ProviderDefinition $d}
    }
    Check 'native window applicability cannot be weakened or invented in a definition' {
        $d=Get-Hotpl8ProviderDefinition claude $catalog;$d.windows[0].required=$false
        Reject {Assert-Hotpl8ProviderDefinition $d}
        $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.windows[0].minutes=301
        Reject {Assert-Hotpl8ProviderDefinition $d}
        $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.windows=@($d.windows[0])
        Reject {Assert-Hotpl8ProviderDefinition $d}
        $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.windows=@($d.windows[0],$d.windows[0])
        Reject {Assert-Hotpl8ProviderDefinition $d}
    }
    Check 'descriptor numbers and versions require bounded numeric values' {
        foreach($value in @('1',2,$true,$null)){
            $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.schemaVersion=$value
            Reject {Assert-Hotpl8ProviderDefinition $d}
        }
        foreach($value in @(-1,101,'25',$true,[double]::NaN,[double]::PositiveInfinity)){
            $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.policyDefaults.margin5h=$value
            Reject {Assert-Hotpl8ProviderDefinition $d}
        }
        $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.policyDefaults|Add-Member NoteProperty warm $true
        Reject {Assert-Hotpl8ProviderDefinition $d}
    }
    Check 'display and host metadata cannot carry unsafe values or claim another protocol' {
        foreach($id in @('Bad','../bad','bad/id','bad_id','')){
            $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.id=$id;Reject {Assert-Hotpl8ProviderDefinition $d}
        }
        $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.name="bad`nname";Reject {Assert-Hotpl8ProviderDefinition $d}
        $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.display.order=0.5;Reject {Assert-Hotpl8ProviderDefinition $d}
        $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.integrations.t3='claude';Reject {Assert-Hotpl8ProviderDefinition $d}
        $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.integrations.PSObject.Properties.Remove('t3')
        Reject {Assert-Hotpl8ProviderDefinition $d}
    }
    Check 'a third descriptor registers through the same known driver without executable fields' {
        $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.id='fictional';$d.name='Fictional';$d.display.order=30
        Write-Definition $d
        $third=@(Get-Hotpl8ProviderCatalog $lab)
        Assert ($third.Count -eq 1 -and $third[0].id -ceq 'fictional')
        Assert ((Get-Hotpl8ProviderDriver $third[0].driver).provider -ceq 'codex')
        $p='{"schemaVersion":3,"mode":"monitor","providers":{"fictional":{"slots":[],"margin7d":40}}}'|ConvertFrom-Json
        $r=@(Get-Hotpl8ConfiguredProviders $p $third)
        Assert ($r.Count -eq 1 -and $r[0].id -ceq 'fictional' -and $r[0].driver -ceq 'codex-app-server')
        Assert ($r[0].policy.margin7d -eq 40 -and -not $r[0].isLegacy)
        Assert ($r[0].controls.mode -eq 'monitor' -and -not $r[0].controls.switchEnabled)
    }
    Check 'catalog filenames bind provider identity and malformed JSON fails closed' {
        $d=Get-Hotpl8ProviderDefinition codex $catalog
        Write-Definition $d;Reject {Get-Hotpl8ProviderCatalog $lab}
        [IO.File]::WriteAllText((Join-Path $lab 'fictional.json'),'{bad')
        Reject {Get-Hotpl8ProviderCatalog $lab}
        [IO.File]::WriteAllText((Join-Path $lab 'fictional.json'),(' '*131073))
        Reject {Get-Hotpl8ProviderCatalog $lab}
        Reject {Get-Hotpl8ProviderCatalog (Join-Path $lab 'missing')}
    }
    Check 'unsupported policy versions are rejected before legacy classification' {
        foreach($version in @('3','2',0,4,99,$true,$null,@(3))){
            $p=[pscustomobject]@{schemaVersion=$version;prefer=@()}
            Reject {Get-Hotpl8ConfiguredProviders $p $catalog}
        }
        Reject {Get-Hotpl8ConfiguredProviders @{} $catalog}
    }
    Check 'legacy policies retain every original value without applying descriptor defaults' {
        foreach($version in @(0,1,2)){
            $p='{"prefer":[1],"margin7d":44,"codex":{"slots":[],"margin7d":37}}'|ConvertFrom-Json
            if($version){$p|Add-Member NoteProperty schemaVersion $version;$p|Add-Member NoteProperty mode 'monitor'}
            $snapshot=Json $p;$records=@(Get-Hotpl8ConfiguredProviders $p $catalog)
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
        $records=@(Get-Hotpl8ConfiguredProviders $p $catalog)
        foreach($r in $records){Assert (-not $r.controls.PSObject.Properties['switchEnabled']);Assert (-not $r.controls.PSObject.Properties['mode'])}
        $codex=@($records|Where-Object id -CEQ codex)[0]
        Assert (-not $codex.policy.PSObject.Properties['schemaVersion'] -and -not $codex.policy.PSObject.Properties['mode'])
    }
    Check 'v3 defaults never invent a lower work-account weekly floor' {
        $p='{"schemaVersion":3,"mode":"monitor","providers":{"codex":{"slots":[],"margin7d":44},"claude":{"prefer":[1],"margin7d":39}}}'|ConvertFrom-Json
        $records=@(Get-Hotpl8ConfiguredProviders $p $catalog)
        foreach($r in $records){Assert (-not $r.policy.PSObject.Properties['margin7dWork']);Assert ($r.policy.order -eq 'prefer')}
        Assert (@($records|Where-Object id -CEQ codex)[0].policy.margin7d -eq 44)
        Assert (@($records|Where-Object id -CEQ claude)[0].policy.margin7d -eq 39)
        $p.providers.codex|Add-Member NoteProperty margin7dWork 5
        Assert (@(Get-Hotpl8ConfiguredProviders $p $catalog|Where-Object id -CEQ codex)[0].policy.margin7dWork -eq 5)
    }
    Check 'normalization preserves empty and singleton arrays and does not alias policy data' {
        $p='{"schemaVersion":3,"mode":"monitor","providers":{"codex":{"slots":[],"prefer":["one"]}}}'|ConvertFrom-Json
        $snapshot=Json $p;$r=@(Get-Hotpl8ConfiguredProviders $p $catalog)[0]
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
            $p=$json|ConvertFrom-Json;Reject {Get-Hotpl8ConfiguredProviders $p $catalog}
        }
        $p='{"schemaVersion":2,"codex":[]}'|ConvertFrom-Json;Reject {Get-Hotpl8ConfiguredProviders $p $catalog}
    }
    Check 'descriptor defaults for model mappings merge without widening supported meters' {
        $d=Get-Hotpl8ProviderDefinition codex $catalog;$d.id='fictional';$d.meters=@('codex')
        $d.modelMeters=[pscustomobject]@{'fictional-default'='codex'}
        $p='{"schemaVersion":3,"providers":{"fictional":{"slots":[],"modelMeters":{"fictional-explicit":"codex"}}}}'|ConvertFrom-Json
        $r=@(Get-Hotpl8ConfiguredProviders $p @($d))[0]
        Assert ($r.policy.modelMeters.'fictional-default' -eq 'codex' -and $r.policy.modelMeters.'fictional-explicit' -eq 'codex')
        $p.providers.fictional.modelMeters.'fictional-explicit'='codex_bengalfox';Reject {Get-Hotpl8ConfiguredProviders $p @($d)}
        $p.providers.fictional.modelMeters=[pscustomobject]@{}
        $p.providers.fictional|Add-Member NoteProperty defaultMeter 'codex_bengalfox';Reject {Get-Hotpl8ConfiguredProviders $p @($d)}
    }
    Check 'configured membership and optional unconfigured inventory remain distinct' {
        $p='{"schemaVersion":3,"mode":"monitor","providers":{}}'|ConvertFrom-Json
        Assert (@(Get-Hotpl8ConfiguredProviders $p $catalog).Count -eq 0)
        $all=@(Get-Hotpl8ConfiguredProviders $p $catalog -IncludeUnconfigured)
        Assert ($all.Count -eq 2 -and @($all|Where-Object configured).Count -eq 0)
        foreach($r in $all){Assert ($null -eq $r.policy)}
        $p='{"prefer":[]}'|ConvertFrom-Json
        Reject {Get-Hotpl8ConfiguredProviders $p @($catalog|Where-Object id -CEQ codex)}
        Reject {Get-Hotpl8ConfiguredProviders $p @($catalog[0],$catalog[0])}
    }
    Check 'registry reads do not modify the source catalog' {
        Assert ((Json $catalog) -ceq $before)
        Assert ((Json @(Get-Hotpl8ProviderCatalog)) -ceq $before)
    }
}finally{
    $full=[IO.Path]::GetFullPath($lab)
    if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-provider-catalog-[a-f0-9]{32}$'){
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
'Provider registry: '+$script:passed+' passed, '+$script:failed+' failed.'
if($script:failed){exit 1}
