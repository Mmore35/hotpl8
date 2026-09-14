# Exercise Windows Forms initialization, timer and disposal with no visible UI.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($name in @('common','config','insights','management','tray')){. (Join-Path $root ('src/'+$name+'.ps1'))}
$dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-tray-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
try{
    Write-Hotpl8Text (Join-Path $dir 'policy.json') '{"schemaVersion":2,"mode":"monitor","notificationsEnabled":false}'
    # Cold assembly loading varies with runner disk/antivirus; measure the ready
    # message loop separately from that one-time platform startup cost.
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $clock=[Diagnostics.Stopwatch]::StartNew()
    Show-Hotpl8Tray $dir $root -SmokeTest
    if($clock.ElapsedMilliseconds -gt 30000){throw 'Tray initialization/message-loop exceeded the 30-second smoke-test budget.'}
    'Tray initialized and ticked in '+$clock.ElapsedMilliseconds+'ms (assemblies preloaded).'
    if(@(Get-ChildItem -LiteralPath $dir -File).Count -ne 1){throw 'Smoke view wrote operational state.'}
    # A second run proves that icon, timer and singleton ownership were released.
    Show-Hotpl8Tray $dir $root -SmokeTest
    'PASS hidden tray initialization message loop and disposal'
    'passed=1 failed=0'
}finally{
    $full=[IO.Path]::GetFullPath($dir);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if((Split-Path $full -Parent) -eq $temp -and (Split-Path $full -Leaf) -match '^hotpl8-tray-test-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
