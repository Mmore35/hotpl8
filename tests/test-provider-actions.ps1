# The control boundary PowerShell's writers share with the compiled program, on real files
# and locks with fictional state. What an action is authorized under is tested in the program.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/config.ps1')
. (Join-Path $root 'src/provider-actions.ps1')
$dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-actions-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
$passed=0
function Assert($Value,[string]$Message){if(-not $Value){throw $Message};$script:passed++}
function Reject([scriptblock]$Action,[string]$Code){try{& $Action;throw 'unexpected success'}catch{Assert ($_.Exception.Message -eq $Code) ('expected '+$Code+', got '+$_.Exception.Message)}}
try {
    Reject {Invoke-Hotpl8ControlWrite (Join-Path $dir 'missing/parent') {'should not run'} -TimeoutMs 20} 'action_state_unavailable'
    $script:ran=$false
    $result=Invoke-Hotpl8ControlWrite $dir {
        Reject {Invoke-Hotpl8ControlWrite $dir {$script:ran=$true} -TimeoutMs 20} 'action_control_busy'
        'written'
    }
    Assert ($result -eq 'written' -and -not $script:ran) 'a control write keeps every other writer out while it runs'
    Invoke-Hotpl8ControlWrite $dir {$script:ran=$true}
    Assert $script:ran 'the boundary is free once a write has ended'
    # The compiled program keeps writers out by holding the same file.
    $held=[IO.File]::Open((Join-Path $dir 'action-control.lock'),'OpenOrCreate','ReadWrite','None')
    try{Reject {Invoke-Hotpl8ControlWrite $dir {'should not run'} -TimeoutMs 20} 'action_control_busy'}finally{$held.Dispose()}
    'passed='+$passed+' failed=0'
} finally {
    $resolved=[IO.Path]::GetFullPath($dir)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $resolved -Leaf) -match '^hotpl8-actions-[a-f0-9]{32}$'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
