# The dashboard is drawn by the compiled reader, and what a frame says is checked beside the
# code that draws it (native/src). This checks what only a started program shows: that the
# frame it sends a terminal is the frame it prints, in colours the documentation images can
# read back, and, on Windows, a dashboard open on a console of its own. On a Mac the open
# dashboard is tests/test_live_preview.py's. Offline, with fictional accounts.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/native.ps1')
. (Join-Path $root 'tests/fixtures/screenshots.ps1')
. (Join-Path $root 'tests/fixtures/terminal.ps1')
$windows=$env:OS -eq 'Windows_NT'
$reader=Get-Hotpl8NativePath $root
if(-not [IO.File]::Exists($reader)){throw 'Build the native reader first: scripts/build-native.ps1'}
$lab=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-dashboard-test-'+[guid]::NewGuid().ToString('N'))
$names=@('HOTPL8_INSTALL_DIRECTORY','HOTPL8_STATE_DIRECTORY','NO_COLOR','HOTPL8_REDUCED_MOTION')
$prior=@{};foreach($name in $names){$prior[$name]=[Environment]::GetEnvironmentVariable($name)}
$script:passed=0;$script:failed=0
function Assert($Value,[string]$Message='assertion failed'){if(-not $Value){throw $Message}}
function Check([string]$Name,[scriptblock]$Body){try{& $Body;$script:passed++;'PASS '+$Name}catch{$script:failed++;'FAIL '+$Name+': '+$_.Exception.Message}}
function New-State([string]$Name,$Fixture) {
    $state=Join-Path $lab $Name
    [void][IO.Directory]::CreateDirectory($state)
    Write-Hotpl8Text (Join-Path $state 'policy.json') ($Fixture.policy|ConvertTo-Json -Depth 20 -Compress) -NoBom
    Write-Hotpl8Text (Join-Path $state 'status.json') ($Fixture.status|ConvertTo-Json -Depth 20 -Compress) -NoBom
    $state
}
# The rows of one frame, without the line that says where it settled.
function Get-Frame([string]$State,$Fixture,[string]$View,[string[]]$As) {
    $drawn=Invoke-Hotpl8NativeProcess $reader (@($View,'--root',$root,'--state',$State,'--now',$Fixture.now.ToString('o'),'--zone','0','--size','100x40')+$As)
    Assert ($drawn.exitCode -eq 0 -and $drawn.errors -eq '') ($View+' '+($As -join ' ')+': '+$drawn.exitCode+' '+$drawn.errors)
    $lines=$drawn.output.Split("`n")
    Assert ($lines.Count -gt 3 -and $lines[$lines.Count-1] -eq '' -and $lines[$lines.Count-2] -match '^offset \d+$') ($View+' drew no frame: '+$drawn.output)
    ,@($lines[0..($lines.Count-3)])
}
try{
    foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$null)}
    [void][IO.Directory]::CreateDirectory($lab)
    Check 'the decoder of the documentation images reads both colour forms and refuses any other sequence' {
        $esc=[string][char]27
        $parts=@(ConvertFrom-Hotpl8TestAnsiRow ($esc+'[38;2;1;2;3m'+$esc+'[48;5;234m'+'A'+$esc+'[38;5;196mB'+$esc+'[K'))
        Assert ($parts.Count -eq 2 -and $parts[0].text -eq 'A' -and $parts[0].foreground -eq '1;2;3' -and $parts[0].background -eq '28;28;28')
        Assert ($parts[1].text -eq 'B' -and $parts[1].foreground -eq '255;0;0' -and $parts[1].background -eq '28;28;28')
        foreach($other in @('[35mtext','[38;5;7mtext','[38;2;1;2mtext')){
            $refused=$false
            try{$null=ConvertFrom-Hotpl8TestAnsiRow ($esc+$other)}catch{$refused=$true}
            Assert $refused $other
        }
    }
    Check 'the frame a terminal is sent is the frame that is printed, in colours the decoder reads' {
        $fixture=Get-Hotpl8ScreenshotFixture -Operations
        $state=New-State 'fixed' $fixture
        $esc=[string][char]27
        $frames=@{}
        foreach($view in @('watch','nyan')){
            foreach($colours in @('true','indexed')){
                $printed=Get-Frame $state $fixture $view @('--colours',$colours)
                $sent=Get-Frame $state $fixture $view @('--colours',$colours,'--ansi')
                $name=$view+' in '+$colours
                Assert ($sent.Count -eq $printed.Count -and $printed.Count -le 40) ($name+': '+$sent.Count+' rows sent, '+$printed.Count+' printed')
                $painted=@{}
                for($row=0;$row -lt $sent.Count;$row++){
                    # Each row names both its colours first and clears what is left of its line.
                    Assert ($sent[$row] -cmatch ('^'+$esc+'\[38;[0-9;]+m'+$esc+'\[48;[0-9;]+m') -and $sent[$row].EndsWith($esc+'[K',[StringComparison]::Ordinal)) ($name+' row '+$row)
                    $cells=@(ConvertFrom-Hotpl8TestAnsiRow $sent[$row])
                    Assert ((($cells|ForEach-Object{$_.text}) -join '') -ceq $printed[$row]) ($name+' row '+$row+': '+$printed[$row])
                    foreach($cell in $cells){$painted[$cell.foreground]=1;$painted[$cell.background]=1}
                }
                Assert (($printed[1] -match 'hotpl8\s+\S\s+nyan') -eq ($view -eq 'nyan')) ($name+': '+$printed[1])
                # The cat brings its own colours to a frame that otherwise has a handful.
                Assert ($painted.Count -ge $(if($view -eq 'nyan'){12}else{5})) ($name+': '+$painted.Count+' colours')
                $frames[$name]=$sent -join "`n"
            }
        }
        Assert (@($frames.Values|Select-Object -Unique).Count -eq 4) 'two of the four frames are one frame'
    }
    if($windows){
        Check 'an open dashboard moves, freezes on what it had read, scrolls and leaves the console as it found it' {
            # Read a moment ago, so the title says so rather than that the reading is stale.
            $fixture=Get-Hotpl8ScreenshotFixture
            $now=[datetimeoffset]::UtcNow;$later=$now-$fixture.now
            $fixture.status.generatedAt=$now.AddSeconds(-42).ToString('o')
            foreach($slot in $fixture.status.slots){
                $slot.observedAt=$now.AddSeconds(-42).ToString('o')
                foreach($key in @('reset5h','reset7d')){$slot.$key=([datetimeoffset]::Parse($slot.$key)+$later).ToString('o')}
            }
            foreach($slot in $fixture.status.providers.codex.slots){
                $slot.observedAt=$now.AddSeconds(-42).ToString('o')
                foreach($window in $slot.buckets.codex.windows.PSObject.Properties){$window.Value.resetsAt=[long]($window.Value.resetsAt+$later.TotalSeconds)}
            }
            $state=New-State 'open' $fixture
            # What the collector writes next: the first account has used nearly all of its week.
            $fixture.status.slots[0].used7d=97
            $next=Join-Path $lab 'next-status.json'
            Write-Hotpl8Text $next ($fixture.status|ConvertTo-Json -Depth 20 -Compress) -NoBom
            $words=Join-Path $lab 'words.txt';$report=Join-Path $lab 'seen.json'
            [IO.File]::WriteAllText($words,('user nyan -StateDirectory "'+$state+'"'))
            $asked=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'fixtures/console.ps1'),'-Program',$reader,'-ArgumentsFile',$words,
                '-Status',(Join-Path $state 'status.json'),'-NextStatus',$next,'-Changed',' 3%','-Report',$report)
            # A console of its own, with no window: no other console is read or written.
            $driver=Start-Process (Get-Process -Id $PID).Path -WindowStyle Hidden -PassThru -ArgumentList @($asked|ForEach-Object{'"'+$_+'"'})
            try{
                if(-not $driver.WaitForExit(90000)){$driver.Kill();throw 'The console was not left.'}
            }finally{$driver.Dispose()}
            Assert ([IO.File]::Exists($report)) 'The console recorded nothing.'
            $seen=[IO.File]::ReadAllText($report)|ConvertFrom-Json
            Assert (-not $seen.error) ([string]$seen.error)
            Assert ($seen.opened -match 'hotpl8\s+\S\s+nyan' -and $seen.opened.Contains('Everyday') -and $seen.opened.Contains('read ') -and -not $seen.opened.Contains('THE SCREEN BEFORE')) ('opened: '+$seen.opened)
            # Only an installed release names the window it is shown in.
            Assert ($seen.during.title -ceq $seen.before.title -and $seen.during.modes -cne $seen.before.modes) ('during: '+($seen.during|ConvertTo-Json -Compress))
            Assert ($seen.moved -cne $seen.opened) 'nothing moved'
            Assert ($seen.frozen.Contains('FROZEN')) ('frozen: '+$seen.frozen)
            # The frozen frame is the one read before the state changed, and it is at rest.
            Assert ($seen.held.Contains('FROZEN') -and $seen.held.Contains(' 46%') -and -not $seen.held.Contains(' 3%')) ('held: '+$seen.held)
            Assert ($seen.heldLater -ceq $seen.held) 'a frozen dashboard moved'
            Assert ($seen.scrolled -cne $seen.held -and $seen.scrolled.Contains('FROZEN')) ('scrolled: '+$seen.scrolled)
            Assert ($seen.returned -ceq $seen.held) ('returned: '+$seen.returned)
            Assert ($seen.resumed.Contains(' 3%') -and -not $seen.resumed.Contains(' 46%') -and -not $seen.resumed.Contains('FROZEN')) ('resumed: '+$seen.resumed)
            Assert ($seen.openAfterOtherKeys -and $seen.closedInTime -and $seen.exit -eq 0) ('closed: '+$seen.openAfterOtherKeys+' '+$seen.closedInTime+' '+$seen.exit)
            Assert ($seen.closed.Contains('THE SCREEN BEFORE') -and $seen.closed -notmatch 'hotpl8\s+\S\s+nyan') ('closed: '+$seen.closed)
            Assert ($seen.after.modes -ceq $seen.before.modes -and $seen.after.title -ceq $seen.before.title -and $seen.after.cursor -eq $seen.before.cursor) ('after: '+($seen.after|ConvertTo-Json -Compress)+' before: '+($seen.before|ConvertTo-Json -Compress))
        }
    }
}finally{
    foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$prior[$name])}
    $full=[IO.Path]::GetFullPath($lab)
    if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-dashboard-test-[a-f0-9]{32}$' -and (Test-Path -LiteralPath $full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
'passed='+$script:passed+' failed='+$script:failed
if($script:failed){exit 1}
