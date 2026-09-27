# Required native qualification. Never infer a Mac pass from skipped Windows tests.
$ErrorActionPreference='Stop'
if(-not $IsMacOS){throw 'This suite requires a native Mac.'}
$root=Split-Path $PSScriptRoot -Parent
& python (Join-Path $root 'tests/test_macos_delivery.py')
if($LASTEXITCODE -ne 0){throw 'Native delivery qualification failed.'}
foreach($name in @('test-provider-actions.ps1','test-delivery-policy.ps1','test-dashboard.ps1')){
    & (Join-Path $root ('tests/'+$name))
    if($LASTEXITCODE -ne 0){throw ('Native surface failed: '+$name)}
}
