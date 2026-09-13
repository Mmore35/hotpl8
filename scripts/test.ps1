# Run offline suites in separate Windows PowerShell processes with isolated user directories.
param([switch]$SkipClaude)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
if($env:OS -ne 'Windows_NT'){throw 'Full suite currently requires Windows PowerShell 5.1.'}
$ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$bash=Join-Path $env:ProgramFiles 'Git/bin/bash.exe'
if(-not $SkipClaude -and -not (Test-Path -LiteralPath $bash)){throw 'Install Git Bash to run the Claude regression suite.'}
if(-not $SkipClaude -and -not (Get-Command python -ErrorAction SilentlyContinue)){throw 'Python is required for Claude fixture generation.'}
$failures=@()
function Invoke-IsolatedSuite([string]$Executable,[string[]]$Arguments){
    $homeDir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-suite-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($homeDir)
    $proc=$null
    try{
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
        $proc=[Diagnostics.Process]::Start($psi);$proc.WaitForExit()
        return $proc.ExitCode
    }finally{
        if($proc){$proc.Dispose()}
        $full=[IO.Path]::GetFullPath($homeDir)
        if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-suite-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
    }
}
foreach($suite in @('tests/test-codex.ps1','tests/test-dashboard.ps1','tests/test-audit-codex.ps1','tests/test-safety.ps1','tests/test-lifecycle.ps1','tests/test-onboarding.ps1','tests/test-operations.ps1','tests/test-tray.ps1')){
    $code=Invoke-IsolatedSuite $ps @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root $suite))
    if($code -ne 0){$failures+=$suite}
}
if(-not $SkipClaude){
    Push-Location $root
    try{$code=Invoke-IsolatedSuite $bash @('--login','tests/test-tick.sh');if($code -ne 0){$failures+='tests/test-tick.sh'}}finally{Pop-Location}
}
if($failures){throw ('Failed suites: '+($failures -join ', '))}
'All requested offline suites passed.'
