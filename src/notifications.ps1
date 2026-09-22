# Pure notification candidates; a single optional desktop consumer delivers them.
function Get-Hotpl8NativeAlerts($Snapshot,$Policy,[datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
    if($Policy.notificationsEnabled -ne $true -or -not (Test-Hotpl8WorkTime $Policy.automation.schedule $Now)){return}
    $health=Get-Hotpl8Health $Snapshot.collector $Now
    $repeated=$Snapshot.collector.incompleteRuns -ge 2
    if($health -in @('collector stalled','collector overdue') -or ($health -eq 'provider checks incomplete' -and $repeated)){
        [pscustomobject]@{key='collector';title='HotPl8 needs attention';text=$health+'. Run hotpl8 doctor.'}
    }
    foreach($s in @($Snapshot.slots)){
        if($s.status -in @('relogin_required','no_credentials')){[pscustomobject]@{key=('claude/'+$s.slot+'/auth');title='Claude sign-in needed';text=('Slot '+$s.slot+' needs native sign-in.')}}
        if($s.fresh -and (Test-Hotpl8FreshTimestamp $s.observedAt $Now) -and $s.forecast -and -not $s.forecast.lastsToReset){
            # Identity and window duration identify the stream; recovery rearms it.
            [pscustomobject]@{key=('claude/'+$s.streamKey+'/weekly');title='Claude weekly quota may run out';text=(Format-Hotpl8Forecast $s.forecast)}
        }
    }
    foreach($s in @($Snapshot.providers.codex.slots)){
        if($s.status -in @('authentication_required','subscription_login_required')){[pscustomobject]@{key=('codex/'+$s.id+'/auth');title='Codex sign-in needed';text=('Slot '+$s.id+' needs native sign-in.')}}
        foreach($b in $s.buckets.PSObject.Properties){if($s.status -eq 'ok' -and (Test-Hotpl8FreshTimestamp $s.observedAt $Now) -and $b.Value.forecast -and -not $b.Value.forecast.lastsToReset){
            [pscustomobject]@{key=('codex/'+$s.streamKey+'/'+$b.Name+'/weekly');title='Codex weekly quota may run out';text=(Format-Hotpl8Forecast $b.Value.forecast)}
        }}
    }
    if(Test-Hotpl8FreshTimestamp $Snapshot.generatedAt $Now){
        $accounts=@($Snapshot.decision.accounts|Where-Object {$_})
        if($accounts.Count -and -not @($accounts|Where-Object {$_.reason -like 'eligible_*'}).Count){
            [pscustomobject]@{key='claude/no-eligible';title='No eligible Claude account';text='Run hotpl8 explain for the recorded reasons.'}
        }
        foreach($d in @($Snapshot.providers.codex.decisions)){
            if($d.meter -eq $Snapshot.providers.codex.defaultMeter -and @($d.accounts).Count -and -not @($d.accounts|Where-Object reason -EQ eligible).Count){
                [pscustomobject]@{key=('codex/'+$d.meter+'/no-eligible');title='No eligible Codex account';text='Run hotpl8 explain before the next launch.'}
            }
        }
    }
}
function Get-Hotpl8Alerts($Snapshot,$Policy,[datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
    $seen=@{}
    foreach($r in @(Get-Hotpl8ConfiguredProviders $Policy)){
        $v=Get-Hotpl8ProviderView $Snapshot $Policy $r.id
        foreach($alert in @(Get-Hotpl8NativeAlerts $v.snapshot $v.policy $Now)){
            if($alert.key -like ($v.provider+'/*')){
                $alert.key=$r.id+$alert.key.Substring($v.provider.Length)
                $alert.title=$alert.title -replace ('(?i)^'+[regex]::Escape($v.provider)), $r.name
            }
            if(-not $seen.ContainsKey($alert.key)){$seen[$alert.key]=$true;$alert}
        }
    }
}
function Select-Hotpl8NewAlerts($Candidates,$Previous,[datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
    $entries=@{};$deliver=@()
    foreach($c in @($Candidates)){
        if(-not $c){continue};$old=$Previous.($c.key)
        if(-not $old){$deliver+=@($c);$entries[$c.key]=$Now.ToString('o')}else{$entries[$c.key]=$old}
    }
    return @{deliver=$deliver;state=$entries}
}
