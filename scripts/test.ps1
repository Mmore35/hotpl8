# Run offline suites in separate Windows PowerShell processes with isolated user directories.
# The default width is capped deliberately. A concurrent run can never finish sooner
# than its longest suite (the 235 s bash tick regression), and every other suite
# together is about as long again, so four at a time already hides all of them --
# while 16 at a time on a 16-core machine oversubscribes the CPU enough to break the
# Codex suite's real-time budgets (a 401 fixture that cannot start inside 3 s is
# classified as a timeout). Raise -Parallel only if you also accept that risk.
param([switch]$SkipClaude,[int]$Parallel=[Math]::Min(4,[Environment]::ProcessorCount))
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
if($env:OS -ne 'Windows_NT'){throw 'Full suite currently requires Windows PowerShell 5.1.'}
$ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$bash=Join-Path $env:ProgramFiles 'Git/bin/bash.exe'
if(-not $SkipClaude -and -not (Test-Path -LiteralPath $bash)){throw 'Install Git Bash to run the Claude regression suite.'}
if(-not $SkipClaude -and -not (Get-Command python -ErrorAction SilentlyContinue)){throw 'Python is required for Claude fixture generation.'}
$Parallel=[Math]::Max(1,$Parallel)
$failures=@()
# Suites already isolate everything they touch: a temporary HOME/APPDATA/CODEX_HOME
# per child, per-suite fixture directories, no ports, no named pipes, no scheduler
# and no shared state file. Only the console is shared, so whenever more than one runs
# at a time each suite's output is captured and printed whole, in list order. At
# -Parallel 1 nothing is redirected and the run streams live exactly as it always has.
function Start-IsolatedSuite([string]$Name,[string]$Executable,[string[]]$Arguments,[bool]$Capture){
    $homeDir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-suite-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($homeDir)
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$Executable
    $psi.Arguments=(@($Arguments|ForEach-Object{ConvertTo-NativeArgument $_}) -join ' ')
    $psi.UseShellExecute=$false;$psi.WorkingDirectory=$root
    # Child-only environment; the real account directories and parent environment are unchanged.
    foreach($key in @('HOME','USERPROFILE')){$psi.EnvironmentVariables[$key]=$homeDir}
    foreach($key in @('LOCALAPPDATA','APPDATA')){$psi.EnvironmentVariables[$key]=(Join-Path $homeDir $key);[void][IO.Directory]::CreateDirectory($psi.EnvironmentVariables[$key])}
    $psi.EnvironmentVariables['CODEX_HOME']=Join-Path $homeDir '.codex'
    $psi.EnvironmentVariables['PSModuleAnalysisCachePath']=Join-Path $homeDir 'ModuleAnalysisCache'
    foreach($key in @('HOTPL8_STATE_DIRECTORY','OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','CLAUDE_CODE_OAUTH_TOKEN','ANTHROPIC_API_KEY')){$psi.EnvironmentVariables.Remove($key)}
    $psi.RedirectStandardOutput=$Capture;$psi.RedirectStandardError=$Capture
    # Nothing owns this suite's temp home until it is handed back, so a failure to
    # start has to remove it here.
    try{$proc=[Diagnostics.Process]::Start($psi)}catch{Remove-Item -LiteralPath $homeDir -Recurse -Force -ErrorAction SilentlyContinue;throw}
    # Start draining both pipes BEFORE anything waits on the process: a suite that
    # fills the pipe buffer with nobody reading it blocks until the run times out.
    $out=$null;$err=$null
    if($Capture){$out=$proc.StandardOutput.ReadToEndAsync();$err=$proc.StandardError.ReadToEndAsync()}
    return [pscustomobject]@{name=$Name;proc=$proc;homeDir=$homeDir;out=$out;err=$err}
}
function Complete-IsolatedSuite($Suite){
    try{
        $Suite.proc.WaitForExit()
        if($Suite.out){
            $text=$Suite.out.Result
            $errorText=$Suite.err.Result
            if($text){[Console]::Out.Write($text)}
            if($errorText){[Console]::Error.Write($errorText)}
        }
        return $Suite.proc.ExitCode
    }finally{
        if($Suite.proc){$Suite.proc.Dispose()}
        $full=[IO.Path]::GetFullPath($Suite.homeDir)
        if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-suite-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
    }
}
# Weights are measured seconds, used ONLY to decide what starts first; they are a
# scheduling hint and are allowed to drift. A concurrent run can never finish sooner
# than its longest suite, so the long poles have to be in flight from the start --
# leaving the 4-minute Claude regression until last made a 16-way run barely faster
# than a serial one.
$work=@()
foreach($suite in @(@('tests/test-codex.ps1',70),@('tests/test-provider-core.ps1',2),@('tests/test-provider-registration.ps1',2),@('tests/test-dashboard.ps1',27),@('tests/test-overview.ps1',7),@('tests/test-capacity.ps1',13),@('tests/test-claude-plans.ps1',1),@('tests/test-audit-codex.ps1',1),@('tests/test-safety.ps1',18),@('tests/test-lifecycle.ps1',25),@('tests/test-job-host.ps1',10),@('tests/test-onboarding.ps1',10),@('tests/test-operations.ps1',3),@('tests/test-tray.ps1',2),@('tests/test-agent-api.ps1',6),@('tests/test-leases.ps1',4),@('tests/test-mcp.ps1',4),@('tests/test-t3-routing.ps1',15))){
    $work+=[pscustomobject]@{name=$suite[0];weight=$suite[1];executable=$ps;arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root $suite[0]))}
}
if(-not (Get-Command node -ErrorAction SilentlyContinue)){throw 'Node 22+ is required for the optional T3 integration tests.'}
$work+=[pscustomobject]@{name='tests/test-t3-codex.mjs';weight=1;executable=(Get-Command node).Source;arguments=@('--test',(Join-Path $root 'tests/test-t3-codex.mjs'))}
if(Get-Command python -ErrorAction SilentlyContinue){
    $work+=[pscustomobject]@{name='tests/test_delivery.py';weight=8;executable=(Get-Command python).Source;arguments=@((Join-Path $root 'tests/test_delivery.py'))}
}
if(-not $SkipClaude){
    $work+=[pscustomobject]@{name='tests/test_claude_plan.py';weight=1;executable=(Get-Command python).Source;arguments=@((Join-Path $root 'tests/test_claude_plan.py'))}
    # The child already runs in $root, so the suite's own relative path resolves.
    $work+=[pscustomobject]@{name='tests/test-tick.sh';weight=235;executable=$bash;arguments=@('--login','tests/test-tick.sh')}
}
$capture=$Parallel -gt 1
# Serial runs keep the declaration order they have always reported in.
if($capture){$work=@($work|Sort-Object -Property weight -Descending)}
$started=@();$handled=0
try{
    for($i=0;$i -lt $work.Count;$i++){
        # In flight = started - completed, so start ahead of the completion cursor
        # only up to the requested width.
        while($started.Count -lt $work.Count -and ($started.Count - $i) -lt $Parallel){
            $item=$work[$started.Count]
            $started+=Start-IsolatedSuite $item.name $item.executable $item.arguments $capture
        }
        '[{0}/{1}] {2}' -f ($i+1),$work.Count,$started[$i].name
        # From here this suite cleans up after itself, whether or not it exits well.
        $handled=$i+1
        $code=Complete-IsolatedSuite $started[$i]
        if($code -ne 0){$failures+=$started[$i].name}
    }
}finally{
    # Anything still in flight owns a temp home that only completion removes. Errors
    # here would replace whatever is already unwinding, so they are dropped.
    for($j=$handled;$j -lt $started.Count;$j++){try{[void](Complete-IsolatedSuite $started[$j])}catch{}}
}
if($failures){throw ('Failed suites: '+($failures -join ', '))}
'All requested offline suites passed.'
