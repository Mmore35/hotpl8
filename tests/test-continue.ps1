$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/config.ps1')
. (Join-Path $root 'src/management.ps1')
$script:passed=0;$script:failed=0
function Assert($Value){if(-not $Value){throw 'assertion failed'}}
function Check([string]$Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message}}
$dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-continue-test-'+[guid]::NewGuid().ToString('N'))
$state=Join-Path $dir 'state with spaces'
[void][IO.Directory]::CreateDirectory($state)
$running=@()
function Stamp([int]$Seconds){[datetimeoffset]::UtcNow.AddSeconds($Seconds).ToString('o')}
function Set-Policy($Changes=@{}){
    $p=Read-Hotpl8Json (Join-Path $root 'policy.example.json')
    $p.mode='automate';$p.switchEnabled=$true;$p.prefer=@(1,2)
    foreach($key in $Changes.Keys){$p|Add-Member NoteProperty $key $Changes[$key] -Force}
    Write-Hotpl8Text (Join-Path $state 'policy.json') ($p|ConvertTo-Json -Depth 12)
}
# A Claude snapshot: which account is in use, which one HotPl8 selected, and when each was read.
function Set-Claude($Active,$Selected,[int]$Read1=-600,[int]$Read2=-600){
    $s=@{schemaVersion=2;active=$Active;slots=@(@{slot=1;observedAt=(Stamp $Read1)},@{slot=2;observedAt=(Stamp $Read2)});providerOverview=@{claude=@{selected=$Selected}}}
    Write-Hotpl8Text (Join-Path $state 'status.json') ($s|ConvertTo-Json -Depth 8)
}
function Set-Codex($Selected,[int]$ReadA=-600){
    $s=@{schemaVersion=2;active=0;slots=@();providers=@{codex=@{slots=@(@{id='a';observedAt=(Stamp $ReadA)},@{id='b';observedAt=(Stamp -600)})}};providerOverview=@{codex=@{selected=$Selected}}}
    Write-Hotpl8Text (Join-Path $state 'status.json') ($s|ConvertTo-Json -Depth 8)
}
function Start-Waiter([string[]]$Arguments,[string]$InputText='',[string]$Entrypoint=''){
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Get-Hotpl8PowerShell
    $all=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'continue.ps1'),'-StateDirectory',$state,'-PollSeconds','1')+$Arguments
    $info.Arguments=($all|ForEach-Object {ConvertTo-NativeArgument $_}) -join ' '
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true;$info.RedirectStandardError=$true;$info.RedirectStandardOutput=$true
    # The suite may itself run inside a hosted or terminal session; neither may leak in.
    foreach($name in @('CLAUDE_CODE_ENTRYPOINT','CLAUDE_PID','HOTPL8_STATE_DIRECTORY')){$info.EnvironmentVariables.Remove($name)}
    if($Entrypoint){$info.EnvironmentVariables['CLAUDE_CODE_ENTRYPOINT']=$Entrypoint}
    $process=[Diagnostics.Process]::Start($info)
    # As a host sends it: UTF-8 without a signature, whatever encoding this console uses.
    $stdin=$process.StandardInput.BaseStream
    if($InputText){$bytes=(New-Object Text.UTF8Encoding $false).GetBytes($InputText);$stdin.Write($bytes,0,$bytes.Length)}
    $stdin.Close()
    $script:running+=@($process)
    return $process
}
# Generous limits: a loaded machine can take most of a minute to start one PowerShell.
function Complete-Waiter($Process,[int]$Seconds=120){
    if(-not $Process.WaitForExit($Seconds*1000)){$Process.Kill();throw 'the waiter did not finish'}
    return [pscustomobject]@{code=$Process.ExitCode;text=$Process.StandardError.ReadToEnd()}
}
function Invoke-Waiter([string[]]$Arguments,[string]$InputText='',[string]$Entrypoint=''){Complete-Waiter (Start-Waiter $Arguments $InputText $Entrypoint)}
function Assert-Waiting($Process,[int]$Seconds=3){Assert (-not $Process.WaitForExit($Seconds*1000))}
function Get-Events{@(Get-Content -LiteralPath (Join-Path $state 'events.jsonl') -ErrorAction SilentlyContinue|ForEach-Object {($_|ConvertFrom-Json).code})}
function New-Hook([string]$Session){
    # A folder name outside ASCII: the waiter must still find the transcript it was given.
    $folder=Join-Path $dir ('transcripts '+[char]0xE9);[void][IO.Directory]::CreateDirectory($folder)
    $transcript=Join-Path $folder ($Session+'.jsonl')
    [IO.File]::WriteAllText($transcript,'fixture')
    return @{transcript=$transcript;json=(@{session_id=$Session;transcript_path=$transcript;hook_event_name='StopFailure'}|ConvertTo-Json -Compress)}
}
# The hook reads which account is in use as it starts, so the fixture may only change
# once it has: the waiter creates its record directory right after that read.
function Start-HookWaiter($Hook){
    $records=Join-Path $state 'continue'
    if(Test-Path -LiteralPath $records){Remove-Item -LiteralPath $records -Recurse -Force}
    $process=Start-Waiter @() $Hook.json 'sdk-ts'
    for($i=0;$i -lt 1200 -and -not (Test-Path -LiteralPath $records);$i++){Start-Sleep -Milliseconds 100}
    Assert (Test-Path -LiteralPath $records)
    return $process
}
try{
    Set-Policy
    Check 'a different account selected and in use continues at once' {
        Set-Claude 2 2
        $r=Invoke-Waiter @('-Conversation','thread-one','-Slot','1','-After',(Stamp 0))
        Assert ($r.code -eq 2 -and $r.text -ceq 'Automated message: continue.')
        Assert (Test-Path -LiteralPath (Join-Path $state 'continue/thread-one'))
        Assert ('continue_sent' -in (Get-Events))
    }
    Check 'a second continue for the same conversation within ten minutes stands down' {
        $r=Invoke-Waiter @('-Conversation','thread-one','-Slot','1','-After',(Stamp 0))
        Assert ($r.code -eq 0 -and -not $r.text -and 'continue_skipped' -in (Get-Events))
    }
    Check 'a held continue is asked for again within those ten minutes, and counts from then' {
        $r=Invoke-Waiter @('-Conversation','thread-one','-Slot','1','-After',(Stamp 0),'-Held')
        Assert ($r.code -eq 2 -and $r.text -ceq 'Automated message: continue.')
        Assert ((Invoke-Waiter @('-Conversation','thread-one','-Slot','1','-After',(Stamp 0))).code -eq 0)
    }
    Check 'a held continue still obeys the setting, monitor mode and a pause' {
        $skipped=@(Get-Events|Where-Object {$_ -eq 'continue_skipped'}).Count
        Set-Policy @{automation=[pscustomobject]@{continue=$false}}
        Assert ((Invoke-Waiter @('-Conversation','thread-one','-Slot','1','-After',(Stamp 0),'-Held')).code -eq 0)
        Set-Policy @{mode='monitor'}
        Assert ((Invoke-Waiter @('-Conversation','thread-one','-Slot','1','-After',(Stamp 0),'-Held')).code -eq 0)
        Assert (@(Get-Events|Where-Object {$_ -eq 'continue_skipped'}).Count -eq $skipped+2)
        Set-Policy
        Set-Hotpl8Pause $state 60 'pause'
        $p=Start-Waiter @('-Conversation','thread-one','-Slot','1','-After',(Stamp 0),'-Held')
        Assert-Waiting $p
        Set-Hotpl8Pause $state 0 'resume'
        Assert ((Complete-Waiter $p).code -eq 2)
    }
    Check 'a failure more than six hours old is not continued, held or not' {
        Assert ((Invoke-Waiter @('-Conversation','thread-late','-Slot','1','-After',(Stamp -21700))).code -eq 0)
        Assert ((Invoke-Waiter @('-Conversation','thread-late','-Slot','1','-After',(Stamp -21700),'-Held')).code -eq 0)
        Assert (-not (Test-Path -LiteralPath (Join-Path $state 'continue/thread-late')))
        Assert ((Invoke-Waiter @('-Conversation','thread-late','-Slot','1','-After',(Stamp -21000),'-Held')).code -eq 2)
    }
    Check 'old continue records are removed and never the hook record' {
        $old=Join-Path $state 'continue/thread-old';[IO.File]::WriteAllText($old,'')
        [IO.File]::SetLastWriteTimeUtc($old,[datetime]::UtcNow.AddDays(-2))
        $record=Join-Path $state 'continue/hook.json';[IO.File]::WriteAllText($record,'{}')
        [IO.File]::SetLastWriteTimeUtc($record,[datetime]::UtcNow.AddDays(-2))
        Assert ((Invoke-Waiter @('-Conversation','thread-sweep','-Slot','1','-After',(Stamp 0))).code -eq 2)
        Assert (-not (Test-Path -LiteralPath $old) -and (Test-Path -LiteralPath $record))
    }
    Check 'the same account waits for a reading newer than the limit' {
        Set-Claude 1 1
        $p=Start-Waiter @('-Conversation','thread-same','-Slot','1','-After',(Stamp 0))
        Assert-Waiting $p
        Set-Claude 1 1 -Read1 30
        Assert ((Complete-Waiter $p).code -eq 2)
    }
    Check 'a selected Claude account that is not in use yet keeps waiting' {
        Set-Claude 1 2
        $p=Start-Waiter @('-Conversation','thread-pending','-Slot','1','-After',(Stamp 0))
        Assert-Waiting $p
        Set-Claude 2 2
        Assert ((Complete-Waiter $p).code -eq 2)
    }
    Check 'no selected account keeps waiting' {
        Set-Claude 1 $null
        $p=Start-Waiter @('-Conversation','thread-none','-Slot','1','-After',(Stamp 0))
        Assert-Waiting $p
        Set-Claude 2 2
        Assert ((Complete-Waiter $p).code -eq 2)
    }
    Check 'an automation pause holds the continue until it clears' {
        Set-Claude 2 2
        Set-Hotpl8Pause $state 60 'pause'
        $p=Start-Waiter @('-Conversation','thread-paused','-Slot','1','-After',(Stamp 0))
        Assert-Waiting $p
        Set-Hotpl8Pause $state 0 'resume'
        Assert ((Complete-Waiter $p).code -eq 2)
    }
    Check 'turning the setting off or using monitor mode stands down' {
        Set-Claude 2 2
        Set-Policy @{automation=[pscustomobject]@{continue=$false}}
        Assert ((Invoke-Waiter @('-Conversation','thread-off','-Slot','1')).code -eq 0)
        Set-Policy @{mode='monitor'}
        Assert ((Invoke-Waiter @('-Conversation','thread-monitor','-Slot','1')).code -eq 0)
        Assert (-not (Test-Path -LiteralPath (Join-Path $state 'continue/thread-off')) -and -not (Test-Path -LiteralPath (Join-Path $state 'continue/thread-monitor')))
        Set-Policy
    }
    Check 'the setting is read again at the moment of continuing' {
        Set-Claude 1 1
        $p=Start-Waiter @('-Conversation','thread-recheck','-Slot','1','-After',(Stamp 0))
        Assert-Waiting $p
        Set-Policy @{automation=[pscustomobject]@{continue=$false}}
        Set-Claude 2 2
        Assert ((Complete-Waiter $p).code -eq 0)
        Assert (-not (Test-Path -LiteralPath (Join-Path $state 'continue/thread-recheck')))
        Set-Policy
    }
    Check 'a watched process that is gone stands down' {
        Set-Claude 1 1
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=Get-Hotpl8PowerShell;$info.Arguments='-NoProfile -Command "Start-Sleep -Seconds 120"';$info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $watched=[Diagnostics.Process]::Start($info);$script:running+=@($watched)
        $p=Start-Waiter @('-Conversation','thread-watch','-Slot','1','-After',(Stamp 0),'-WatchPid',[string]$watched.Id)
        Assert-Waiting $p
        $watched.Kill()
        Assert ((Complete-Waiter $p).code -eq 0)
    }
    Check 'the Claude hook continues its own conversation once the new account is in use' {
        Set-Claude 1 2
        $hook=New-Hook 'session-hook'
        $p=Start-HookWaiter $hook
        Assert-Waiting $p
        Set-Claude 2 2
        $r=Complete-Waiter $p
        Assert ($r.code -eq 2 -and $r.text -ceq 'Automated message: continue.')
        Assert (Test-Path -LiteralPath (Join-Path $state 'continue/session-hook'))
    }
    Check 'a conversation that moved on is left alone' {
        Set-Claude 1 2
        $hook=New-Hook 'session-moved'
        $p=Start-HookWaiter $hook
        Assert-Waiting $p
        # Keep writing: the waiter compares against the size it saw when it started.
        for($i=0;$i -lt 40 -and -not $p.WaitForExit(1000);$i++){[IO.File]::AppendAllText($hook.transcript,'the owner wrote again')}
        Assert ((Complete-Waiter $p).code -eq 0)
        Assert (-not (Test-Path -LiteralPath (Join-Path $state 'continue/session-moved')))
    }
    Check 'a terminal session is never continued' {
        Set-Claude 2 2
        $before=@(Get-Events).Count
        Assert ((Invoke-Waiter @() (New-Hook 'session-terminal').json 'cli').code -eq 0)
        Assert (@(Get-Events).Count -eq $before -and -not (Test-Path -LiteralPath (Join-Path $state 'continue/session-terminal')))
    }
    Check 'unsafe conversation names and unreadable hook input stand down' {
        Set-Claude 2 2
        foreach($name in @('../thread','thread one','hook.json','thread;x')){Assert ((Invoke-Waiter @('-Conversation',$name,'-Slot','1')).code -eq 0)}
        Assert ((Invoke-Waiter @() 'not json' 'sdk-ts').code -eq 0)
        Assert ((Invoke-Waiter @() '{"session_id":"..\\outside"}' 'sdk-ts').code -eq 0)
        Assert (@(Get-ChildItem -LiteralPath $dir -Recurse -File|Where-Object Name -Match 'outside|thread;x').Count -eq 0)
    }
    Check 'unreadable status or policy stands down' {
        [IO.File]::WriteAllText((Join-Path $state 'status.json'),'{not json')
        Assert ((Invoke-Waiter @('-Conversation','thread-bad-status','-Slot','1')).code -eq 0)
        Remove-Item -LiteralPath (Join-Path $state 'status.json')
        Assert ((Invoke-Waiter @('-Conversation','thread-no-status','-Slot','1')).code -eq 0)
        Set-Claude 2 2
        [IO.File]::WriteAllText((Join-Path $state 'policy.json'),'{not json')
        Assert ((Invoke-Waiter @('-Conversation','thread-bad-policy','-Slot','1')).code -eq 0)
        [IO.File]::WriteAllText((Join-Path $state 'policy.json'),'{"schemaVersion":99}')
        Assert ((Invoke-Waiter @('-Conversation','thread-invalid-policy','-Slot','1')).code -eq 0)
        Set-Policy
    }
    Check 'Codex uses the same rule with account names' {
        Set-Codex 'a'
        $p=Start-Waiter @('-Provider','codex','-Conversation','codex-thread','-Slot','a','-After',(Stamp 0))
        Assert-Waiting $p
        Set-Codex 'b'
        Assert ((Complete-Waiter $p).code -eq 2)
        Set-Codex 'a' -ReadA 30
        Assert ((Invoke-Waiter @('-Provider','codex','-Conversation','codex-same','-Slot','a','-After',(Stamp 0))).code -eq 2)
    }
    Check 'a version 3 policy reads the same way' {
        $p=ConvertTo-Hotpl8PolicyV3 (Read-Hotpl8Json (Join-Path $state 'policy.json'))
        Assert ($p.schemaVersion -eq 3)
        Write-Hotpl8Text (Join-Path $state 'policy.json') ($p|ConvertTo-Json -Depth 12)
        Set-Claude 1 1
        $w=Start-Waiter @('-Conversation','thread-v3','-Slot','1','-After',(Stamp 0))
        Assert-Waiting $w
        Set-Claude 2 2
        Assert ((Complete-Waiter $w).code -eq 2)
        $p.automation|Add-Member NoteProperty continue $false -Force
        Write-Hotpl8Text (Join-Path $state 'policy.json') ($p|ConvertTo-Json -Depth 12)
        Assert ((Invoke-Waiter @('-Conversation','thread-v3-off','-Slot','1')).code -eq 0)
    }
}finally{
    foreach($process in $running){try{if(-not $process.HasExited){$process.Kill()}}catch{}}
    $full=[IO.Path]::GetFullPath($dir)
    if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-continue-test-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
'passed='+$script:passed+' failed='+$script:failed
if($script:failed){exit 1}
