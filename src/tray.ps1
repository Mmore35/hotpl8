# The tray's window and menu, and the record of which announcements were already made. What
# the window shows and what it may announce is worked out by the compiled program in one
# start (native/src/tray.rs): this file holds none of those rules.
. (Join-Path $PSScriptRoot 'native.ps1')
function Read-Hotpl8TrayModel([string]$Directory,[string]$CodeDirectory) {
    $answer=Invoke-Hotpl8NativeProcess (Get-Hotpl8NativePath $CodeDirectory) @('tray','--root',$CodeDirectory,'--state',$Directory)
    if($answer.exitCode -ne 0){throw $answer.errors.Trim()}
    return $answer.output|ConvertFrom-Json
}
function Select-Hotpl8NewAlerts($Candidates,$Previous,[datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
    $entries=@{};$deliver=@()
    foreach($c in @($Candidates)){
        if(-not $c){continue};$old=$Previous.($c.key)
        if(-not $old){$deliver+=@($c);$entries[$c.key]=$Now.ToString('o')}else{$entries[$c.key]=$old}
    }
    return @{deliver=$deliver;state=$entries}
}
# A smoke run opens nothing visible, announces nothing, and answers with the title it showed.
function Show-Hotpl8Tray([string]$Directory,[string]$CodeDirectory,[switch]$SmokeTest) {
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
                $model=Read-Hotpl8TrayModel $Directory $CodeDirectory
                $icon.Text=$model.title.Substring(0,[math]::Min(63,$model.title.Length));$box.Text=$model.details
                if(-not $SmokeTest -and $model.notify){
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
        if($SmokeTest){return $icon.Text}
    }finally{
        if($timer){$timer.Stop();$timer.Dispose()};if($icon){$icon.Visible=$false;$icon.Dispose()};if($form){$form.Dispose()}
        if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()
    }
}
