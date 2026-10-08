# The rules of HotPl8 are the compiled program's (native/). PowerShell holds no copy of them:
# each function here keeps the name and the answer its PowerShell body had, and asks the
# program for it. One question is one start of the program, about a tenth of a second, so a
# command asks for what it needs once. A refusal is thrown in the program's own words, and
# nothing here is answered by PowerShell in the program's place: a copy with no program it
# can start says so. docs/plans/rust-read-side.md lists the questions.
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'native.ps1')

# -Remembered is for an answer that depends on nothing but the release: it is asked once in
# a process. What is kept is the answer as it was written, read again for each caller, so
# no caller can change what the next one is given.
function Invoke-Hotpl8Rule([string]$Question,$Asked=@{},[switch]$Remembered) {
    # The file this function was read from says whose program answers. A release whose
    # validators are loaded into another release's process still asks its own.
    $root=Split-Path $PSScriptRoot -Parent
    $written=ConvertTo-Json -InputObject $Asked -Compress -Depth 32
    $key=$root+'|'+$Question+'|'+$written
    $line=$null
    if($Remembered -and $script:Hotpl8RuleAnswers -and $script:Hotpl8RuleAnswers.ContainsKey($key)){$line=$script:Hotpl8RuleAnswers[$key]}
    else{
        $arguments=@('rule',$Question,'--root',$root)
        # The program writes a number as the PowerShell that reads it would.
        if($PSVersionTable.PSEdition -eq 'Core'){$arguments+=@('--core')}
        $result=$null
        try{$result=Invoke-Hotpl8NativeProcess (Get-Hotpl8NativePath $root) $arguments -Asked $written}catch{$result=$null}
        if($result){$line=([string]$result.output).Trim()}
    }
    $answer=$null
    if($line){try{$answer=ConvertFrom-Hotpl8Json $line}catch{$answer=$null}}
    if($answer -isnot [pscustomobject] -or -not ($answer.PSObject.Properties['value'] -or $answer.PSObject.Properties['error'])){
        throw 'This copy has no compiled reader it can start, and this command is answered by it. A release ships one; in a checkout, build it with scripts/build-native.ps1.'
    }
    if($answer.PSObject.Properties['error']){throw [string]$answer.error}
    if($Remembered){
        # Ordinal, as a provider's name is: claude and Claude are two questions.
        if(-not $script:Hotpl8RuleAnswers){$script:Hotpl8RuleAnswers=[Collections.Hashtable]::new([StringComparer]::Ordinal)}
        $script:Hotpl8RuleAnswers[$key]=$line
    }
    # A list goes down the pipeline item by item, as the PowerShell functions wrote theirs.
    return $answer.value
}
function Get-Hotpl8RuleClock($Bound) {
    # The caller's clock when it brought one; otherwise the program reads the machine's.
    if($Bound.ContainsKey('Now')){return @{now=([datetimeoffset]$Bound['Now']).ToString('o')}}
    return @{}
}

function Assert-Hotpl8Policy($Policy) {
    # A list and an object of another kind are told apart here: written as JSON they are not.
    if (-not $Policy -or $Policy -is [array] -or $Policy -isnot [pscustomobject]) { throw 'Invalid policy: expected an object.' }
    $null=Invoke-Hotpl8Rule 'policy.check' @{policy=$Policy}
}
function Assert-CodexPolicy($Policy) {
    $null=Invoke-Hotpl8Rule 'codex.check' @{policy=$Policy}
}
function Get-Hotpl8Actions($Policy, [bool]$ObserveOnly) {
    $allowed=Invoke-Hotpl8Rule 'policy.actions' @{policy=$Policy;observeOnly=$ObserveOnly}
    return @{switching=[bool]$allowed.switching;warming=[bool]$allowed.warming;probing=[bool]$allowed.probing;continuing=[bool]$allowed.continuing}
}
function Get-Hotpl8Pause([string]$Directory, [datetimeoffset]$Now) {
    Invoke-Hotpl8Rule 'pause' (@{directory=$Directory}+(Get-Hotpl8RuleClock $PSBoundParameters))
}
# What the agents' pause leases come to. Writing one is src/leases.ps1.
function Get-Hotpl8LeasePause([string]$Directory, [datetimeoffset]$Now) {
    Invoke-Hotpl8Rule 'lease.pause' (@{directory=$Directory}+(Get-Hotpl8RuleClock $PSBoundParameters))
}

# -Provider asks for the driver a registered provider is read through, in the one start.
function Get-Hotpl8ProviderDriver([string]$Id,[string]$Provider) {
    if($Provider){return (Invoke-Hotpl8Rule 'provider.driver' @{provider=$Provider} -Remembered)}
    return (Invoke-Hotpl8Rule 'provider.driver' @{id=$Id} -Remembered)
}
function Get-Hotpl8ProviderCatalog {
    Invoke-Hotpl8Rule 'provider.catalog' -Remembered
}
function Get-Hotpl8ProviderDefinition([string]$Id) {
    return (Invoke-Hotpl8Rule 'provider.definition' @{id=$Id} -Remembered)
}
function Get-Hotpl8ConfiguredProviders($Policy,[switch]$IncludeUnconfigured) {
    if($Policy -isnot [pscustomobject]){throw 'Provider configuration requires a policy object.'}
    Invoke-Hotpl8Rule 'provider.configured' @{policy=$Policy;includeUnconfigured=[bool]$IncludeUnconfigured}
}
function Get-Hotpl8ConfiguredProvider($Policy,[string]$Provider,[switch]$IncludeUnconfigured) {
    return (Invoke-Hotpl8Rule 'provider.one' @{policy=$Policy;provider=$Provider;includeUnconfigured=[bool]$IncludeUnconfigured})
}
function Get-Hotpl8ProviderStateDirectory([string]$Directory,[string]$Provider) {
    return (Invoke-Hotpl8Rule 'provider.state' @{directory=$Directory;provider=$Provider})
}
function Get-Hotpl8ProviderView($Snapshot,$Policy,[string]$Provider) {
    return (Invoke-Hotpl8Rule 'provider.view' @{snapshot=$Snapshot;policy=$Policy;provider=$Provider})
}
function Get-Hotpl8ProviderAccounts($Policy) {
    Invoke-Hotpl8Rule 'provider.accounts' @{policy=$Policy}
}
function Get-Hotpl8CapacityCatalog {
    return (Invoke-Hotpl8Rule 'capacity.catalog' -Remembered)
}

function Test-Hotpl8FreshTimestamp($Timestamp,[datetimeoffset]$Now) {
    return [bool](Invoke-Hotpl8Rule 'fresh' (@{timestamp=$Timestamp}+(Get-Hotpl8RuleClock $PSBoundParameters)))
}
# The snapshot as every reader lays it out, or nothing when there is none to read.
function Read-Hotpl8Snapshot([string]$Directory,$PolicyOverride=$null,[datetimeoffset]$Now) {
    # Whether a policy was brought is PowerShell's to say: an empty list is none, and written
    # as JSON it is not always a list.
    $brought=if($PolicyOverride){$PolicyOverride}else{$null}
    return (Invoke-Hotpl8Rule 'snapshot' (@{directory=$Directory;policy=$brought}+(Get-Hotpl8RuleClock $PSBoundParameters)))
}
function Get-Hotpl8HistoryStores($Policy,[string]$Directory) {
    Invoke-Hotpl8Rule 'history' @{policy=$Policy;directory=$Directory}
}
function Get-Hotpl8ParkCandidates($Snapshot,$Policy,[datetimeoffset]$Now) {
    Invoke-Hotpl8Rule 'park.candidates' (@{snapshot=$Snapshot;policy=$Policy}+(Get-Hotpl8RuleClock $PSBoundParameters))
}
function Format-Hotpl8ParkReason($Candidate) {
    return [string](Invoke-Hotpl8Rule 'park.reason' @{candidate=$Candidate})
}

# The program looks where a person's own command would: HOTPL8_NATIVE_BIN, then the PATH
# and the usual installation places. Nothing when cswap is not found.
function Resolve-CswapExecutable([string]$CswapExecutable) {
    return (Invoke-Hotpl8Rule 'cswap.find' @{explicit=$CswapExecutable})
}
# How long `cswap list --json` may run before it is ended; native/src/cswap.rs says why.
function Get-CswapReadTimeoutMs {
    return [int](Invoke-Hotpl8Rule 'cswap.timeout' -Remembered)
}
# Refused by name: codex_missing, or native_codex_required for a script in its place.
function Resolve-CodexExecutable([string]$Explicit) {
    return [string](Invoke-Hotpl8Rule 'codex.find' @{explicit=$Explicit})
}
function Get-CodexReadBudgetMs {
    return [int](Invoke-Hotpl8Rule 'codex.budget' -Remembered)
}
# One account's limits and identity, read by the program from native Codex. Native Codex
# owns login and refresh, and no sign-in leaves the program: there is no token to ask for.
# A read that fails is an answer too, {status=<the failure's name>}.
function Read-CodexQuota([string]$AccountHome, [string]$Executable, [int]$TimeoutMs, [string]$WorkingDirectory, [switch]$IdentityOnly) {
    $asked=@{home=$AccountHome;executable=$Executable;workingDirectory=$WorkingDirectory;identityOnly=[bool]$IdentityOnly}
    # Unsaid, the time a read may take is the program's own budget.
    if($PSBoundParameters.ContainsKey('TimeoutMs')){$asked.timeoutMs=$TimeoutMs}
    return (Invoke-Hotpl8Rule 'codex.read' $asked)
}

# The program reports everything but what only this process knows: the PowerShell it runs
# in, and whether Claude's own settings file holds the continue hook.
function Get-Hotpl8Doctor([string]$StateDirectory) {
    $facts=Invoke-Hotpl8Rule 'doctor' @{directory=$StateDirectory}
    $continue=$null
    if($facts.continue){try{
        . (Join-Path $PSScriptRoot 'lifecycle.ps1')
        $continue=[pscustomobject]@{enabled=[bool]$facts.continue.enabled;hookPresent=(Test-Hotpl8ContinueHook $StateDirectory);lastAt=$facts.continue.lastAt}
    }catch{$continue=$null}}
    $report=[ordered]@{}
    foreach($member in $facts.PSObject.Properties){
        $report[$member.Name]=$member.Value
        if($member.Name -ceq 'version'){$report['runtime']=$PSVersionTable.PSVersion.ToString()}
    }
    # A whole number of seconds comes back from JSON as an integer; it was never one.
    if($null -ne $report['snapshotAgeSeconds']){$report['snapshotAgeSeconds']=[double]$report['snapshotAgeSeconds']}
    $report['continue']=$continue
    return [pscustomobject]$report
}
function Get-Hotpl8Capabilities([string]$Directory) {
    $found=Invoke-Hotpl8Rule 'capabilities' @{directory=$Directory}
    $report=[ordered]@{}
    foreach($member in $found.PSObject.Properties){
        $report[$member.Name]=$member.Value
        if($member.Name -ceq 'platform'){$report['runtime']=$PSVersionTable.PSVersion.ToString()}
    }
    return [pscustomobject]$report
}
# One line in events.jsonl: the time and a code, nothing else. Never a reason to stop.
function Write-Hotpl8Event([string]$Directory, [string]$Code) {
    try{$null=Invoke-Hotpl8Rule 'event' @{directory=$Directory;code=$Code}}catch{}
}
function Invoke-Hotpl8Replay($Frames,$Policy) {
    return (Invoke-Hotpl8Rule 'replay' @{frames=@($Frames);policy=$Policy})
}
