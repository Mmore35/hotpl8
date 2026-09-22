# Fixed-clock fictional inputs only. No native process, credential or state access.
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/provider-decision.ps1')
$script:passed=0;$script:failed=0
$now=[datetimeoffset]::Parse('2026-09-22T00:00:00Z')
function Copy-Value($Value){$Value|ConvertTo-Json -Depth 30|ConvertFrom-Json}
function Assert($Value,[string]$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check([string]$Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message}}
function Policy {Copy-Value @{prefer=@('a','b');reserve=@();order='prefer';margin5h=25;margin7d=20;margin7dWork=5;hysteresis=10;resetLeadMin=10;maxUsageAgeS=900}}
function Account([string]$Id='a',[double]$Short=90,[double]$Week=90,[int]$ResetMinutes=120){
    Copy-Value @{id=$Id;status='ok';observedAt=$now.ToString('o');windows=@(
        @{name='300';scope='fixture';role='short';state='observed';required=$true;usedPercent=(100-$Short);resetAt=$now.AddMinutes($ResetMinutes).ToString('o');observedAt=$now.ToString('o');resetConfirmed=$true},
        @{name='10080';scope='fixture';role='weekly';state='observed';required=$true;usedPercent=(100-$Week);resetAt=$now.AddDays(3).ToString('o');observedAt=$now.ToString('o');resetConfirmed=$true})}
}
function Context([string]$Intent='admit',[string]$Previous=''){
    Copy-Value @{intent=$Intent;previousId=$Previous;bindingKnown=[bool]$Previous;identityKnown=[bool]$Previous;scopes=@('fixture');mode='automate';switching=$true;paused=$false;hold=$false}
}
function Decide($Accounts,$Policy=(Policy),$Context=(Context)){Get-Hotpl8ProviderDecision $Accounts $Policy $Context $now}
Check 'healthy preference and explicit recommendation are independent from a known binding' {
    $d=Decide @((Account a),(Account b)) (Policy) (Context admit b)
    Assert ($d.proposedSlot -eq 'a' -and $d.targetSlot -eq 'a' -and $d.actionPermitted)
}
Check 'equivalent input decisions do not depend on provider labels' {
    $a=Account;$p=Policy;$c=Context
    $a|Add-Member NoteProperty provider 'claude';$first=Decide @($a) $p $c
    $a.provider='fictional-third-provider';$second=Decide @($a) $p $c
    Assert (($first|ConvertTo-Json -Depth 30 -Compress) -ceq ($second|ConvertTo-Json -Depth 30 -Compress))
}
Check 'degraded headroom improves despite later short reset' {
    $p=Policy;$p.order='soonest-reset'
    Assert ((Decide @((Account a 90 6 60),(Account b 90 16 120)) $p (Context admit a)).targetSlot -eq 'b')
}
Check 'return from reserve bypasses healthy-peer headroom hysteresis' {
    $p=Policy;$p.reserve=@('a')
    Assert ((Decide @((Account a),(Account b 30)) $p (Context admit a)).targetSlot -eq 'b')
}
Check 'equal degraded headroom retains actual current account' {
    Assert ((Decide @((Account a 90 15),(Account b 90 15)) (Policy) (Context admit b)).targetSlot -eq 'b')
}
Check 'healthy work outranks degraded work and any healthy reserve' {
    $p=Policy;$p.reserve=@('c')
    Assert ((Decide @((Account a 90 15),(Account b),(Account c)) $p).targetSlot -eq 'b')
}
Check 'healthy-peer preference band still avoids churn' {
    Assert ((Decide @((Account a 30),(Account b)) (Policy) (Context admit b)).targetSlot -eq 'b')
}
Check 'healthy-peer reset lead still avoids churn at boundary' {
    $p=Policy;$p.order='soonest-reset'
    Assert ((Decide @((Account a 90 90 115),(Account b 90 90 120)) $p (Context admit b)).targetSlot -eq 'b')
    Assert ((Decide @((Account a 90 90 110),(Account b 90 90 120)) $p (Context admit b)).targetSlot -eq 'a')
}
Check 'ineligible current account cannot impose hysteresis' {
    Assert ((Decide @((Account a 26),(Account b 0)) (Policy) (Context admit b)).targetSlot -eq 'a')
}
Check 'weekly expiry and balanced use the shared selection key' {
    $a=Account a 90 90;$b=Account b 90 90;$a.windows[1].resetAt=$now.AddDays(6).ToString('o');$b.windows[1].resetAt=$now.AddDays(1).ToString('o')
    foreach($order in @('weekly-expiry','balanced')){$p=Policy;$p.order=$order;Assert ((Decide @($a,$b) $p).targetSlot -eq 'b')}
}
Check 'small account permutations retain deterministic ties' {
    $p=Policy;$p.prefer=@()
    foreach($ids in @(@('a','b','c'),@('c','a','b'),@('b','c','a'))){$accounts=@(foreach($id in $ids){Account $id});Assert ((Decide $accounts $p).targetSlot -eq 'a')}
}
Check 'zero quota stays ineligible with zero margins' {
    $p=Policy;$p.margin5h=0;$p.margin7dWork=0
    Assert (-not (Decide @((Account a 0 90)) $p).accounts[0].eligible)
}
Check 'exact freshness ceiling allowed, older and future observations rejected' {
    foreach($case in @(@(900,$true),@(901,$false),@(-5,$true),@(-6,$false))){$a=Account;$a.observedAt=$now.AddSeconds(-$case[0]).ToString('o');Assert ((Decide @($a)).accounts[0].eligible -eq $case[1])}
}
Check 'missing and invalid observations fail closed' {
    foreach($value in @($null,'nonsense')){$a=Account;$a.observedAt=$value;Assert ((Decide @($a)).accounts[0].reason -eq 'stale')}
}
Check 'fresh account timestamp cannot launder stale or missing window evidence' {
    foreach($stamp in @($now.AddSeconds(-901).ToString('o'),$now.AddSeconds(6).ToString('o'),$null,'invalid')){$a=Account;$a.windows[0].observedAt=$stamp;Assert ((Decide @($a)).accounts[0].reason -eq 'window_stale')}
}
Check 'malformed normalized window metadata fails closed' {
    foreach($case in @(@('role','invented'),@('name',''),@('name',7),@('scope',7),@('required','false'),@('required',$null),@('state','invented'),@('resetConfirmed','true'))){$a=Account;$a.windows[0].($case[0])=$case[1];Assert (-not (Decide @($a)).accounts[0].eligible)}
}
Check 'elapsed-after-observation reset restores quota but not next expiry' {
    $a=Account a 0;$a.windows[0].resetAt=$now.AddSeconds(-1).ToString('o');$a.windows[0].observedAt=$now.AddMinutes(-5).ToString('o')
    $d=Decide @($a);Assert ($d.accounts[0].eligible -and $d.accounts[0].shortRemaining -eq 100 -and -not $d.accounts[0].resetAt)
}
Check 'expired-on-arrival reset grants no refill' {
    $a=Account;$a.windows[0].resetAt=$now.AddSeconds(-1).ToString('o');Assert ((Decide @($a)).accounts[0].reason -eq 'reset_unconfirmed')
}
Check 'missing or malformed percentages cannot be refilled' {
    foreach($bad in @($null,-1,101,'0',$true)){$a=Account;$a.windows[0].usedPercent=$bad;$a.windows[0].resetAt=$now.AddSeconds(-1).ToString('o');$a.windows[0].observedAt=$now.AddMinutes(-5).ToString('o');Assert (-not (Decide @($a)).accounts[0].eligible)}
}
Check 'observed null reset permits quota but cannot rank a known expiry' {
    $a=Account;$a.windows[0].resetAt=$null;$a.windows[0].resetConfirmed=$false
    $d=Decide @($a);Assert ($d.accounts[0].eligible -and -not $d.accounts[0].resetAt)
}
Check 'unconfirmed future reset does not rank as confirmed expiry' {
    $p=Policy;$p.order='soonest-reset';$a=Account a 90 90 10;$a.windows[0].resetConfirmed=$false
    Assert ((Decide @($a,(Account b)) $p).targetSlot -eq 'b')
}
Check 'mixed time zone offsets rank the earliest instant across windows' {
    $a=Account;$a.windows[0].resetAt='2026-09-22T01:00:00-05:00'
    $second=Copy-Value $a.windows[0];$second.name='other-short';$second.resetAt='2026-09-22T03:00:00+00:00';$a.windows+= $second
    Assert ([datetimeoffset]::Parse((Decide @($a)).accounts[0].resetAt) -eq $now.AddHours(3))
}
Check 'confirmed non-applicability differs from missing required window' {
    $a=Account;$a.windows[1].state='not_applicable';$a.windows[1].required=$false
    $d=Decide @($a);Assert ($d.accounts[0].eligible -and -not $d.accounts[0].degraded)
    $a.windows[1].required=$true;Assert ((Decide @($a)).accounts[0].reason -eq 'window_required')
    $a.windows[1].state='unknown';Assert ((Decide @($a)).accounts[0].reason -eq 'window_unknown')
}
Check 'unknown requested model scope and duplicate windows are rejected' {
    $a=Account;$c=Context;$c.scopes=@('missing');Assert ((Decide @($a) (Policy) $c).accounts[0].reason -eq 'model_quota_unknown')
    $a.windows+=Copy-Value $a.windows[0];Assert ((Decide @($a)).accounts[0].reason -eq 'duplicate_window')
}
Check 'not-applicable windows cannot satisfy a required model scope' {
    $a=Account;foreach($w in $a.windows){$w.state='not_applicable';$w.required=$false}
    Assert ((Decide @($a)).accounts[0].reason -eq 'model_quota_unknown')
}
Check 'every active scope must pass quota constraints' {
    $a=Account;$w=Copy-Value $a.windows[0];$w.scope='child';$w.usedPercent=100;$a.windows+= $w
    $c=Context;Assert ((Decide @($a) (Policy) $c).accounts[0].eligible)
    $c.scopes=@('fixture','child');Assert (-not (Decide @($a) (Policy) $c).accounts[0].eligible)
}
Check 'duplicate slots and identities exclude all copies' {
    $a=Account;$b=Account
    Assert (@((Decide @($a,$b)).accounts|Where-Object eligible).Count -eq 0)
    $b.id='b';$a|Add-Member NoteProperty identityKey 'same';$b|Add-Member NoteProperty identityKey 'same'
    Assert (@((Decide @($a,$b)).accounts|Where-Object eligible).Count -eq 0)
}
Check 'disabled and rebound accounts never authorize action' {
    foreach($field in @('enabled','identityValid','bindingValid')){$a=Account;$a|Add-Member NoteProperty $field $false;Assert (-not (Decide @($a)).actionPermitted)}
}
Check 'observe returns proposal but permits no action' {
    $d=Decide @((Account)) (Policy) (Context observe);Assert ($d.proposedSlot -eq 'a' -and -not $d.actionPermitted -and -not $d.requiresNativeValidation)
}
Check 'paused monitor explicit launch remains allowed' {
    $c=Context;$c.mode='monitor';$c.paused=$true;$c.switching=$false
    Assert ((Decide @((Account)) (Policy) $c).actionPermitted)
}
Check 'unknown held admission defers instead of borrowing recommendation' {
    $c=Context;$c.hold=$true;$c.previousId='a'
    $d=Decide @((Account)) (Policy) $c;Assert (-not $d.actionPermitted -and $d.suppressionReason -eq 'binding_unknown')
}
Check 'hold retains actual eligible binding and cannot bless an empty one' {
    $c=Context admit b;$c.hold=$true
    Assert ((Decide @((Account a),(Account b)) (Policy) $c).targetSlot -eq 'b')
    $d=Decide @((Account a),(Account b 0)) (Policy) $c;Assert (-not $d.actionPermitted -and -not $d.targetSlot)
}
Check 'manual pin can establish held binding without automatic quota approval' {
    $c=Context;$c.hold=$true;$c|Add-Member NoteProperty pin 'a'
    $d=Decide @((Account a 0)) (Policy) $c;Assert ($d.actionPermitted -and $d.manual -and -not $d.accounts[0].eligible -and $d.requiresNativeValidation)
}
Check 'autonomous rebinding obeys each common control' {
    foreach($case in @(@('mode','monitor','monitor_only'),@('paused',$true,'automation_paused'),@('switching',$false,'switching_disabled'),@('hold',$true,'selection_held'))){$c=Context rebind b;$c.($case[0])=$case[1];$d=Decide @((Account a),(Account b)) (Policy) $c;Assert (-not $d.actionPermitted -and $d.suppressionReason -eq $case[2])}
}
Check 'unknown autonomous binding and invalid safety state fail closed' {
    Assert ((Decide @((Account)) (Policy) (Context rebind)).suppressionReason -eq 'binding_unknown')
    $c=Context;$c|Add-Member NoteProperty safetyInvalid $true;Assert ((Decide @((Account)) (Policy) $c).suppressionReason -eq 'safety_state_invalid')
}
Check 'control delivery remains independent from quota and action controls' {
    $c=Context control a;$c.paused=$true;$c.hold=$true;$c.mode='monitor';$c|Add-Member NoteProperty safetyInvalid $true
    Assert ((Decide @((Account a 0)) (Policy) $c).actionPermitted)
}
Check 'native refresh is identity-pinned while held paused and exhausted' {
    $c=Context refresh a;$c.hold=$true;$c.paused=$true;$c.mode='monitor'
    $d=Decide @((Account a 0)) (Policy) $c;Assert ($d.actionPermitted -and $d.targetSlot -eq 'a')
    $stale=Account;$stale.observedAt=$now.AddHours(-1).ToString('o');Assert ((Decide @($stale) (Policy) $c).actionPermitted)
    $disabled=Account;$disabled|Add-Member NoteProperty enabled $false;Assert (-not (Decide @($disabled) (Policy) $c).actionPermitted)
    $c.identityKnown=$false;Assert ((Decide @((Account)) (Policy) $c).suppressionReason -eq 'binding_unknown')
}
Check 'warm and probe ignore rotation hold but obey pause and action budget' {
    foreach($intent in @('warm','probe')){$c=Context $intent;$c.hold=$true;$c|Add-Member NoteProperty actionEnabled $true;$c|Add-Member NoteProperty actionSlot 'a';$c|Add-Member NoteProperty actionEligible $true;Assert ((Decide @((Account)) (Policy) $c).actionPermitted);$c.paused=$true;Assert (-not (Decide @((Account)) (Policy) $c).actionPermitted);$c.paused=$false;$c|Add-Member NoteProperty actionBlock 'daily_attempt_limit';Assert ((Decide @((Account)) (Policy) $c).suppressionReason -eq 'daily_attempt_limit')}
}
Check 'warming target is explicit and independent of an unavailable held active account' {
    $c=Context warm a;$c.hold=$true;$c|Add-Member NoteProperty actionEnabled $true;$c|Add-Member NoteProperty actionSlot 'b';$c|Add-Member NoteProperty actionEligible $true
    $d=Decide @((Account a 0),(Account b)) (Policy) $c;Assert ($d.actionPermitted -and $d.targetSlot -eq 'b')
    $c.actionSlot=$null;Assert ((Decide @((Account)) (Policy) $c).suppressionReason -eq 'action_target_unknown')
}
Check 'recovery probe targets stale quarantined account without admitting it for work' {
    $a=Account;$a.status='relogin_required';$a.windows=@();$a.observedAt=$now.AddDays(-1).ToString('o')
    $c=Context probe b;$c|Add-Member NoteProperty actionEnabled $true;$c|Add-Member NoteProperty actionSlot 'a';$c|Add-Member NoteProperty actionEligible $true
    $d=Decide @($a,(Account b)) (Policy) $c
    Assert ($d.actionPermitted -and $d.targetSlot -eq 'a' -and -not $d.accounts[0].eligible -and $d.proposedSlot -eq 'b')
}
Check 'emergency request cannot relax floors without enabled critical policy' {
    $c=Context;$c|Add-Member NoteProperty emergency $true
    $p=Policy;$d=Decide @((Account a 10 10)) $p $c
    Assert (-not $d.accounts[0].eligible -and $d.accounts[0].reason -eq 'below_margin' -and -not $d.critical.active)
    $p|Add-Member NoteProperty critical @{enabled=$false};$d=Decide @((Account a 10 10)) $p $c
    Assert (-not $d.accounts[0].eligible -and $d.accounts[0].reason -eq 'below_margin' -and -not $d.critical.active)
}
Check 'enabled emergency eligibility request does not itself activate critical mode' {
    $c=Context;$c|Add-Member NoteProperty emergency $true
    $p=Policy;$p|Add-Member NoteProperty critical @{enabled=$true}
    $d=Decide @((Account a 10 10),(Account b)) $p $c
    Assert ($d.accounts[0].eligible -and -not $d.critical.active)
}
Check 'enabled emergency request preserves reserve floors and rejects zero quota' {
    $c=Context;$c|Add-Member NoteProperty emergency $true
    $p=Policy;$p.reserve=@('a');$p|Add-Member NoteProperty critical @{enabled=$true;drainToZero=$true}
    $d=Decide @((Account a 10 10),(Account b)) $p $c
    Assert (-not $d.accounts[0].eligible -and $d.accounts[0].reason -eq 'below_margin')
    $p.reserve=@();$d=Decide @((Account a 0 10),(Account b)) $p $c
    Assert (-not $d.accounts[0].eligible -and $d.accounts[0].reason -eq 'below_margin')
}
Check 'critical selection uses per-scope dwell and keeps reserve out' {
    $p=Policy;$p|Add-Member NoteProperty critical @{enabled=$true;dwellSeconds=60;advantagePercent=10};$p.reserve=@('c')
    $accounts=@((Account a 10 10),(Account b 19 19),(Account c))
    $c=Context admit a;$c|Add-Member NoteProperty criticalState @{active=$true;selected='a';selectedAt=$now.AddSeconds(-10).ToString('o')}
    $d=Decide $accounts $p $c;Assert ($d.critical.active -and $d.proposedSlot -eq 'a')
    $c.criticalState.selectedAt=$now.AddSeconds(-61).ToString('o');Assert ((Decide $accounts $p $c).proposedSlot -eq 'b')
    $other=Context admit b;$other|Add-Member NoteProperty criticalState @{active=$true;selected='b';selectedAt=$now.AddSeconds(-10).ToString('o')}
    Assert ((Decide $accounts $p $other).proposedSlot -eq 'b')
}
Check 'invalid capacity evidence falls back to measured percentages' {
    foreach($gross in @(-1,'10',[double]::NaN,[double]::PositiveInfinity)){
        $p=Policy;$p|Add-Member NoteProperty critical @{enabled=$true}
        $a=Account a 10 10;$a|Add-Member NoteProperty capacity @{scaled=$true;gross=$gross}
        $b=Account b 19 19;$b|Add-Member NoteProperty capacity @{scaled=$true;gross=1}
        $d=Decide @($a,$b) $p;Assert ($d.proposedSlot -eq 'b' -and -not $d.accounts[0].scaled -and $d.critical.basis -like 'binding-window*')
    }
}
Check 'decisions do not mutate supplied observations policy or state' {
    $a=Account;$p=Policy;$c=Context;$before=@($a,$p,$c)|ConvertTo-Json -Depth 30 -Compress
    $null=Decide @($a) $p $c
    Assert ($before -ceq (@($a,$p,$c)|ConvertTo-Json -Depth 30 -Compress))
}
'Provider core: '+$script:passed+' passed, '+$script:failed+' failed'
if($script:failed){exit 1}
