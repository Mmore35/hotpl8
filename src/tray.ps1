. (Join-Path $PSScriptRoot 'notifications.ps1')
function Get-Hotpl8TrayModel($Snapshot,$Policy,[datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
    $details=@(Format-Hotpl8Explanation $Snapshot $Now)
    foreach($s in @($Snapshot.slots)){if($s){
        $fresh=$s.fresh -and (Test-Hotpl8FreshTimestamp $s.observedAt $Now)
        $details+=('Claude '+$s.label+': '+$s.status+$(if(-not $fresh){' / stale'}else{''}))
        $details+=('  5h used: '+$(if($null -eq $s.used5h){'unknown'}else{[string]$s.used5h+'%'})+'; weekly used: '+$(if($null -eq $s.used7d){'unknown'}else{[string]$s.used7d+'%'}))
        if($fresh -and $s.forecast){$details+='  '+(Format-Hotpl8Forecast $s.forecast)}
        if($s.warmOutcome){$details+='  warm: '+$s.warmOutcome.outcome}
        if($s.actionBlock){$details+='  warming: '+$s.actionBlock}
    }}
    foreach($s in @($Snapshot.providers.codex.slots)){
        $fresh=$s.status -eq 'ok' -and (Test-Hotpl8FreshTimestamp $s.observedAt $Now)
        $details+=('Codex '+$s.label+': '+$s.status+$(if(-not $fresh){' / stale'}else{''}))
        foreach($b in $s.buckets.PSObject.Properties){
            foreach($w in $b.Value.windows.PSObject.Properties){$details+=('  '+$b.Name+' '+$w.Name+'m: '+$w.Value.usedPercent+'% used; reset '+$w.Value.anchorState)}
            if($fresh -and $b.Value.forecast){$details+='  '+(Format-Hotpl8Forecast $b.Value.forecast)}
        }
    }
    $details=@($details|ForEach-Object {ConvertTo-Hotpl8SafeText $_})
    return [pscustomobject]@{title='HotPl8 - '+(Get-Hotpl8Health $Snapshot.collector $Now);details=($details -join [Environment]::NewLine);alerts=@(Get-Hotpl8Alerts $Snapshot $Policy $Now)}
}
function Show-Hotpl8Tray([string]$Directory,[string]$CodeDirectory,[switch]$Once,[switch]$SmokeTest) {
    $snapshot=Read-Hotpl8Snapshot $Directory;$policy=Read-Hotpl8Json (Join-Path $Directory 'policy.json')
    if($Once){return Get-Hotpl8TrayModel $snapshot $policy}
    if($env:OS -ne 'Windows_NT'){throw 'Native Mac menu-bar delivery is tracked in docs/plans/macos-handoff.md.'}
    $mutex=New-Object Threading.Mutex($false,('Local\HotPl8Tray-'+(Get-Hotpl8Hash ([IO.Path]::GetFullPath($Directory).ToLowerInvariant()))))
    $owned=$false;$icon=$null;$timer=$null;$form=$null
    try{
        try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){throw 'The tray is already running for this state directory.'}
        Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
        [Windows.Forms.Application]::EnableVisualStyles()
        $context=New-Object Windows.Forms.ApplicationContext
        $icon=New-Object Windows.Forms.NotifyIcon;$icon.Icon=[Drawing.SystemIcons]::Information;$icon.Text='HotPl8';$icon.Visible=(-not $SmokeTest)
        $form=New-Object Windows.Forms.Form;$form.Text='HotPl8';$form.Width=800;$form.Height=550
        $box=New-Object Windows.Forms.TextBox;$box.Multiline=$true;$box.ReadOnly=$true;$box.ScrollBars='Both';$box.Dock='Fill';$form.Controls.Add($box)
        $menu=New-Object Windows.Forms.ContextMenuStrip
        $open=$menu.Items.Add('Accounts and decisions');$open.add_Click({$form.Show();$form.Activate()})
        $dashboard=$menu.Items.Add('Open terminal dashboard');$dashboard.add_Click({
            $ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
            $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $CodeDirectory 'hotpl8.ps1'),'watch','-StateDirectory',$Directory)
            Start-Process -FilePath $ps -ArgumentList (@($args|ForEach-Object {ConvertTo-NativeArgument $_}) -join ' ') -WindowStyle Normal
        })
        $pause=$menu.Items.Add('Pause automation for one hour');$pause.add_Click({try{Set-Hotpl8Pause $Directory 60 'tray pause'}catch{$box.Text=$_.Exception.Message;$form.Show()}})
        $resume=$menu.Items.Add('Resume automation');$resume.add_Click({try{Set-Hotpl8Pause $Directory 0 'resumed'}catch{$box.Text=$_.Exception.Message;$form.Show()}})
        $quit=$menu.Items.Add('Quit tray (collector keeps running)');$quit.add_Click({$context.ExitThread()})
        $icon.ContextMenuStrip=$menu;$icon.add_DoubleClick({$form.Show();$form.Activate()})
        $form.add_FormClosing({param($sender,$eventArgs) if($eventArgs.CloseReason -eq 'UserClosing'){$eventArgs.Cancel=$true;$sender.Hide()}})
        $refresh={
            try{
                $s=Read-Hotpl8Snapshot $Directory;$p=Read-Hotpl8Json (Join-Path $Directory 'policy.json')
                $model=Get-Hotpl8TrayModel $s $p
                $icon.Text=$model.title.Substring(0,[math]::Min(63,$model.title.Length));$box.Text=$model.details
                if(-not $SmokeTest -and $p.notificationsEnabled -eq $true -and (Test-Hotpl8WorkTime $p.automation.schedule)){
                    $path=Join-Path $Directory 'notification-state.json'
                    $new=Select-Hotpl8NewAlerts $model.alerts (Read-Hotpl8Json $path)
                    foreach($alert in $new.deliver){$icon.ShowBalloonTip(5000,$alert.title,$alert.text,[Windows.Forms.ToolTipIcon]::Warning)}
                    Write-Hotpl8Text $path ($new.state|ConvertTo-Json)
                }
            }catch{$icon.Text='HotPl8 - view unavailable'}
        }
        & $refresh
        $timer=New-Object Windows.Forms.Timer;$timer.Interval=$(if($SmokeTest){250}else{5000})
        $timer.add_Tick({& $refresh;if($SmokeTest){$context.ExitThread()}});$timer.Start()
        [Windows.Forms.Application]::Run($context)
    }finally{
        if($timer){$timer.Stop();$timer.Dispose()};if($icon){$icon.Visible=$false;$icon.Dispose()};if($form){$form.Dispose()}
        if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()
    }
}
