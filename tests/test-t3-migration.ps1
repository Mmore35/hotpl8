# Isolated settings/launcher fixtures. No native auth, inference or live T3 writes.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/t3-delivery.ps1')
. (Join-Path $root 'src/t3-migration.ps1')
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-transition-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$passed=0
function Assert($Condition,[string]$Why){if(-not $Condition){throw $Why};$script:passed++}
function Reject([scriptblock]$Body,[string]$Pattern){try{& $Body;throw 'unexpected success'}catch{Assert ($_.Exception.Message -match $Pattern) ('expected '+$Pattern+', got '+$_.Exception.Message)}}
function Save([string]$Path,$Value){Write-Hotpl8Text $Path ($Value|ConvertTo-Json -Depth 50) -NoBom}
function Clone($Value){$Value|ConvertTo-Json -Depth 50|ConvertFrom-Json}
$ps=(Get-Command powershell).Source
function Setup([string]$Op,[string]$Directory,[string[]]$More=@()){
    Write-Host ('fixture setup '+$Op+' '+(Split-Path $Directory -Leaf))
    $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'setup-t3.ps1'),'-Operation',$Op,'-StateDirectory',$fixtureRoot,'-SettingsPath',$script:settingsPath,'-IntegrationDirectory',$Directory,'-CodexExecutable',$script:exe)+$More
    $savedPreference=$ErrorActionPreference
    try{$ErrorActionPreference='Continue';$output=& $ps @arguments 2>&1}finally{$ErrorActionPreference=$savedPreference}
    if($LASTEXITCODE -ne 0){throw ('setup '+$Op+' failed: '+($output|Out-String))}
    $output
}
try{
    $settingsPath=Join-Path $fixtureRoot 'settings.json';$fixtureHome=Join-Path $fixtureRoot 'shared'
    [void][IO.Directory]::CreateDirectory($fixtureHome)
    [IO.File]::WriteAllText((Join-Path $fixtureHome 'auth.json'),'auth-sentinel')
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'threads.db'),'conversation-sentinel')
    $exe=Join-Path $fixtureRoot 'fake-codex.exe'
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 't3-fake-codex.cs'))) -ReferencedAssemblies System.Web.Extensions -OutputAssembly $exe -OutputType ConsoleApplication
    Save (Join-Path $fixtureRoot 'policy.json') @{schemaVersion=2;mode='monitor';prefer=@();codex=@{slots=@(@{id='a';home=$fixtureHome;label='fixture'});prefer=@('a');reserve=@();defaultMeter='codex';modelMeters=@{'fixture-model'='codex'};margin7d=20;margin7dWork=5}}
    $original=Clone @{unrelated='preserve';defaultModelSelection=@{instanceId='codex';model='fixture-model';options=@(@{id='reasoningEffort';value='high'})};providerInstances=@{codex=@{driver='codex';displayName='Codex';enabled=$true;config=@{binaryPath='codex';homePath=$fixtureHome;shadowHomePath='';launchArgs=''}}}}
    Save $settingsPath $original
    $legacy=Join-Path $fixtureRoot 't3-codex'
    $null=Setup install $legacy @('-TargetProviderId','hotpl8-codex','-MakeDefault')
    $legacySettings=Read-Hotpl8Json $settingsPath
    $oldReceipt=[IO.File]::ReadAllText((Join-Path $legacy 'receipt.json'))
    $oldLauncher=(Get-FileHash (Join-Path $legacy 'hotpl8-codex.exe')).Hash
    $settingsBefore=[IO.File]::ReadAllText($settingsPath)
    $plan=(Setup transition $legacy @('-PlanOnly'))|ConvertFrom-Json
    Assert ($plan.integrationDirectory -eq ($legacy+'-ordinary') -and $plan.retainedProviderIds -contains 'hotpl8-codex') 'plan chooses separate owned path and retains alias'
    Assert (-not (Test-Path ($legacy+'-ordinary')) -and [IO.File]::ReadAllText($settingsPath) -ceq $settingsBefore) 'dry run creates no integration and changes no settings'
    $null=Setup transition $legacy
    $ordinary=$legacy+'-ordinary';$after=Read-Hotpl8Json $settingsPath
    Assert ($after.providerInstances.codex.config.binaryPath -eq (Join-Path $ordinary 'hotpl8-codex.exe')) 'ordinary entry becomes managed'
    Assert (($after.providerInstances.'hotpl8-codex'|ConvertTo-Json -Depth 30) -ceq ($legacySettings.providerInstances.'hotpl8-codex'|ConvertTo-Json -Depth 30)) 'legacy provider remains unchanged'
    Assert ([IO.File]::ReadAllText((Join-Path $legacy 'receipt.json')) -ceq $oldReceipt -and (Get-FileHash (Join-Path $legacy 'hotpl8-codex.exe')).Hash -eq $oldLauncher) 'legacy receipt and launcher remain independently owned'
    Assert (($after.defaultModelSelection|ConvertTo-Json -Depth 20) -ceq ($legacySettings.defaultModelSelection|ConvertTo-Json -Depth 20)) 'transition preserves existing default model and options'
    Assert ($after.providerInstances.codex.config.homePath -eq $fixtureHome -and $after.providerInstances.codex.displayName -eq 'Codex' -and $after.unrelated -eq 'preserve') 'home normal label and unrelated settings survive'
    $retry=(Setup transition $legacy)|ConvertFrom-Json
    Assert ($retry.state -eq 'ordinary-managed/legacy-retained' -and $retry.threadMigration -eq 'none') 'transition retry is idempotent and does not claim thread migration'
    $null=Setup transition $legacy @('-MakeDefault')
    $defaults=Read-Hotpl8Json $settingsPath
    Assert ($defaults.defaultModelSelection.instanceId -eq 'codex' -and $defaults.defaultModelSelection.options[0].value -eq 'high') 'explicit MakeDefault moves future picker default preserving model options'
    Assert ($defaults.textGenerationModelSelection.instanceId -eq 'codex' -and $defaults.providerInstances.PSObject.Properties['hotpl8-codex']) 'explicit helper default transition keeps legacy provider operational'
    $null=Setup transition $legacy @('-MakeDefault')
    $null=Setup remove $ordinary
    $removed=Read-Hotpl8Json $settingsPath
    Assert (($removed|ConvertTo-Json -Depth 50) -ceq ($legacySettings|ConvertTo-Json -Depth 50)) 'ordinary removal restores exact prior settings and retained alias after repeated defaults'
    $null=Setup remove $ordinary
    $null=Setup transition $legacy
    Assert ((Read-Hotpl8Json $settingsPath).providerInstances.codex.config.binaryPath -eq (Join-Path $ordinary 'hotpl8-codex.exe')) 'reinstall uses retained launcher without duplicating entries'
    $null=Setup remove $ordinary
    $staging=Read-Hotpl8Json (Join-Path $ordinary 'receipt.json');$staging.phase='staging';$staging|Add-Member NoteProperty stagingSettingsDigest (Get-Hotpl8Hash ([IO.File]::ReadAllText($settingsPath))) -Force
    Save (Join-Path $ordinary 'receipt.json') $staging
    $null=Setup transition $legacy
    Assert ((Read-Hotpl8Json (Join-Path $ordinary 'receipt.json')).phase -eq 'installed') 'interrupted staging retries only under original settings digest'
    Assert ([IO.File]::ReadAllText((Join-Path $fixtureRoot 'threads.db')) -eq 'conversation-sentinel' -and [IO.File]::ReadAllText((Join-Path $fixtureHome 'auth.json')) -eq 'auth-sentinel') 'no conversation or authentication writes'
    $changed=Read-Hotpl8Json $settingsPath;$changed.providerInstances.codex.displayName='My Codex';Save $settingsPath $changed
    Reject {Get-Hotpl8T3TransitionPlan $settingsPath $legacy} 'ownership changed'
    $changed.providerInstances.codex.displayName='Codex';Save $settingsPath $changed

    # Host detection is exercised against synthetic process inventories only.
    $savedProfile=$env:USERPROFILE
    try{
        $env:USERPROFILE=$fixtureRoot;$default=Join-Path $fixtureRoot '.t3/userdata/settings.json'
        Reject {Assert-Hotpl8T3HostStopped $default @([pscustomobject]@{Name='T3 Code.exe';ProcessId=9901;CommandLine='desktop'})} 'Close the complete T3 host'
        Reject {Assert-Hotpl8T3HostStopped $default @([pscustomobject]@{Name='node.exe';ProcessId=9902;CommandLine='node C:\fixture\t3code\apps\server\dist\bin.mjs'})} 'Close the complete T3 host'
    }finally{$env:USERPROFILE=$savedProfile}
    Reject {Assert-Hotpl8T3HostStopped $settingsPath @([pscustomobject]@{Name='node.exe';ProcessId=9903;CommandLine=('node C:\fixture\server.asar --data-dir "'+$fixtureRoot+'"')})} 'Close the complete T3 host'
    Reject {Assert-Hotpl8T3HostStopped $settingsPath @([pscustomobject]@{Name='node.exe';ProcessId=9905;CommandLine=('node C:/fixture/t3.mjs serve --data-dir "'+$fixtureRoot.Replace('\','/')+'"')})} 'Close the complete T3 host'
    Save (Join-Path $fixtureRoot 'server-runtime.json') @{version=1;pid=9904}
    Reject {Assert-Hotpl8T3HostStopped $settingsPath @([pscustomobject]@{Name='node.exe';ProcessId=9904;CommandLine=$null})} 'Close the complete T3 host'
    Assert-Hotpl8T3HostStopped $settingsPath @();$passed++
    [IO.File]::Delete((Join-Path $fixtureRoot 'server-runtime.json'))

    # Crash before/after settings replacement: only this target's settings patch
    # is retained in the journal; lost acknowledgement does not reapply changes.
    $txPath=Join-Path $fixtureRoot 'transaction-settings.json';$txReceiptPath=Join-Path $fixtureRoot 'transaction-receipt.json'
    Save $txPath $original;$before=[IO.File]::ReadAllText($txPath)
    $next=Clone $original;$next.providerInstances.codex.config.binaryPath='fixture-managed.exe'
    $receipt=Clone @{settingsPath=$txPath;targetProviderId='codex';originalInstance=$original.providerInstances.codex;installedInstance=$next.providerInstances.codex}
    $held=[IO.File]::Open(($txPath+'.hotpl8.lock'),'OpenOrCreate','ReadWrite','None')
    try{
        Reject {Invoke-Hotpl8T3SettingsTransaction $txPath $before $next $txReceiptPath $receipt 'install'} 'settings setup is busy'
        Assert ([IO.File]::ReadAllText($txPath) -ceq $before -and -not (Test-Path $txReceiptPath)) 'shared settings lock blocks another owner before settings or receipt mutation'
    }finally{$held.Dispose()}
    Invoke-Hotpl8T3SettingsTransaction $txPath $before $next $txReceiptPath $receipt 'install'
    $committed=[IO.File]::ReadAllText($txPath);$journal=Read-Hotpl8Json $txReceiptPath
    Assert ($journal.phase -eq 'installed') 'transaction records installed phase after settings commit'
    $journal.phase='prepared';Save $txReceiptPath $journal
    Complete-Hotpl8T3SettingsTransaction $txPath $txReceiptPath $journal
    Assert ([IO.File]::ReadAllText($txPath) -ceq $committed -and (Read-Hotpl8Json $txReceiptPath).phase -eq 'installed') 'lost commit response is recovered without another settings mutation'
    $journal.phase='prepared';Save $txReceiptPath $journal;[IO.File]::WriteAllText($txPath,$before)
    Complete-Hotpl8T3SettingsTransaction $txPath $txReceiptPath $journal
    Assert ([IO.File]::ReadAllText($txPath) -ceq $committed) 'prepared before-settings crash completes exact planned patch'
    $journal.phase='prepared';Save $txReceiptPath $journal;$conflict=Clone $original;$conflict.unrelated='user edit';Save $txPath $conflict
    $conflictText=[IO.File]::ReadAllText($txPath)
    Reject {Complete-Hotpl8T3SettingsTransaction $txPath $txReceiptPath $journal} 'conflicts with current settings'
    Assert ([IO.File]::ReadAllText($txPath) -ceq $conflictText) 'conflicting settings are preserved for reconciliation'
    Reject {Invoke-Hotpl8T3SettingsTransaction $txPath $before $next $txReceiptPath $receipt 'install'} 'settings changed concurrently'
    $conflict.providerInstances.codex.config.shadowHomePath='custom';Save $txPath $conflict
    Reject {Get-Hotpl8T3TransitionPlan $txPath (Join-Path $fixtureRoot 'fresh')} 'custom launch arguments or shadow home'
    $badDirectory=Join-Path $fixtureRoot 'bad-receipt';[void][IO.Directory]::CreateDirectory($badDirectory)
    [IO.File]::WriteAllText((Join-Path $badDirectory 'receipt.json'),'{broken')
    Reject {Get-Hotpl8T3TransitionPlan $settingsPath $badDirectory} 'receipt is unreadable'
    Assert ([IO.File]::ReadAllText((Join-Path $badDirectory 'receipt.json')) -eq '{broken') 'unreadable receipt is retained rather than adopted'
    [IO.File]::WriteAllText($txPath,$before);$journal.phase='prepared'
    $journal.transaction.changes[0].key='someone-else'
    Save $txReceiptPath $journal
    Reject {Complete-Hotpl8T3SettingsTransaction $txPath $txReceiptPath $journal} 'Invalid T3 transaction provider ownership'
    Assert ([IO.File]::ReadAllText($txPath) -ceq $before) 'recovery cannot mutate a different provider'

    # Reapplying helper defaults retains the first install's absent-field backup.
    $legacyPolicy=Read-Hotpl8Json (Join-Path $fixtureRoot 'policy.json')
    Save (Join-Path $fixtureRoot 'policy.json') @{schemaVersion=3;mode='monitor';providers=@{codex=$legacyPolicy.codex}}
    $settingsPath=Join-Path $fixtureRoot 'defaults-settings.json';Save $settingsPath $original
    $defaultsDirectory=Join-Path $fixtureRoot 'defaults-integration'
    $null=Setup install $defaultsDirectory @('-MakeDefault')
    $null=Setup defaults $defaultsDirectory
    $null=Setup defaults $defaultsDirectory
    $null=Setup remove $defaultsDirectory
    $restored=Read-Hotpl8Json $settingsPath
    Assert (-not $restored.PSObject.Properties['textGenerationModelSelection']) 'v3 repeated defaults removal restores originally absent helper override'
    Assert (($restored|ConvertTo-Json -Depth 50) -ceq ($original|ConvertTo-Json -Depth 50)) 'in-place uninstall preserves original model options without resurrecting aliases'
    'T3 gradual transition: '+$passed+' passed'
}finally{
    # Only this test's verified absolute temporary root is eligible for removal.
    $resolved=[IO.Path]::GetFullPath($fixtureRoot)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'hotpl8-transition-*'){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}
}
