# Real file/lock boundaries with fictional state; no native account operations.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/config.ps1')
. (Join-Path $root 'src/providers/claude.ps1')
$dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-actions-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
$passed=0
function Assert($Value,[string]$Message){if(-not $Value){throw $Message};$script:passed++}
function Save($Name,$Value){Write-Hotpl8Text (Join-Path $dir $Name) ($Value|ConvertTo-Json -Depth 12)}
function Reject([scriptblock]$Action,[string]$Code){try{& $Action;throw 'unexpected success'}catch{Assert ($_.Exception.Message -eq $Code) ('expected '+$Code+', got '+$_.Exception.Message)}}
try {
    Save 'policy.json' @{schemaVersion=2;mode='automate';prefer=@(1);switchEnabled=$true;warm=$true;probeEnabled=$true}
    $generation=Get-Hotpl8ControlGeneration $dir
    $script:admitted=$false
    Invoke-Hotpl8ControlWrite $dir {Save 'automation-pause.json' @{until=[datetimeoffset]::UtcNow.AddMinutes(2).ToString('o')}}
    Reject {Invoke-Hotpl8ActionAuthorization $dir $generation {$script:admitted=$true}} 'action_state_changed'
    Assert (-not $script:admitted) 'control change before authorization must prevent admission'
    [IO.File]::Delete((Join-Path $dir 'automation-pause.json'))
    $generation=Get-Hotpl8ControlGeneration $dir
    $result=Invoke-Hotpl8ActionAuthorization $dir $generation {
        Reject {Invoke-Hotpl8ControlWrite $dir {$script:admitted=$true} -TimeoutMs 20} 'action_control_busy'
        'admitted'
    }
    Assert ($result -eq 'admitted' -and -not $script:admitted) 'authorization excludes concurrent control writers'
    Invoke-Hotpl8ControlWrite $dir {Save 'hold.json' @{until=[datetimeoffset]::UtcNow.AddMinutes(2).ToString('o')}}
    Assert ($result -eq 'admitted') 'later hold cannot retract an already admitted native operation'
    Reject {Invoke-Hotpl8ActionAuthorization $dir $generation {'should not run'}} 'action_state_changed'
    Assert ((Get-Hotpl8ControlGeneration $dir) -cne $generation) 'later hold invalidates next operation generation'
    $policy=Read-Hotpl8Json (Join-Path $dir 'policy.json')
    $base=[pscustomobject]@{intent='warm';actionSlot='1';actionEligible=$true;bindingKnown=$true;previousId='1'}
    $context=Get-Hotpl8ProviderActionContext $policy $dir $base
    Assert ($context.hold -and $context.actionEnabled -and -not $context.paused) 'rotation hold leaves separately enabled warming available'
    Save 'automation-pause.json' @{until=[datetimeoffset]::UtcNow.AddMinutes(2).ToString('o')}
    $context=Get-Hotpl8ProviderActionContext $policy $dir $base
    Assert ($context.paused -and $context.hold) 'common context combines pause and hold without conflating them'
    Write-Hotpl8Text (Join-Path $dir 'automation-pause.json') '{broken'
    Assert ((Get-Hotpl8ProviderActionContext $policy $dir $base).safetyInvalid) 'malformed pause fails closed for actions'
    $refresh=[pscustomobject]@{intent='refresh';bindingKnown=$true;identityKnown=$true;previousId='1'}
    Assert (-not (Get-Hotpl8ProviderActionContext $policy $dir $refresh).safetyInvalid) 'same-account refresh is independent of rotation control corruption'
    [IO.File]::Delete((Join-Path $dir 'automation-pause.json'))
    $before=@(Get-ChildItem -LiteralPath $dir -File|ForEach-Object { $_.Name+':'+(Get-FileHash -LiteralPath $_.FullName).Hash }) -join '|'
    $null=Get-Hotpl8ProviderActionContext $policy $dir $base
    $after=@(Get-ChildItem -LiteralPath $dir -File|ForEach-Object { $_.Name+':'+(Get-FileHash -LiteralPath $_.FullName).Hash }) -join '|'
    Assert ($before -ceq $after) 'building decision context is read-only'
    'passed='+$passed+' failed=0'
} finally {
    $resolved=[IO.Path]::GetFullPath($dir)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $resolved -Leaf) -match '^hotpl8-actions-[a-f0-9]{32}$'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
