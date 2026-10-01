# Required native qualification. Never infer a Mac pass from skipped Windows tests.
$ErrorActionPreference='Stop'
if(-not $IsMacOS){throw 'This suite requires a native Mac.'}
$root=Split-Path $PSScriptRoot -Parent
& python (Join-Path $root 'tests/test_macos_delivery.py')
if($LASTEXITCODE -ne 0){throw 'Native delivery qualification failed.'}
foreach($name in @('test-bootstrap.ps1','test-onboarding.ps1','test-agent-api.ps1','test-mcp.ps1','test-install-macos.ps1','test-onboarding-flow.ps1','test-onboarding-native.ps1','test-provider-actions.ps1','test-delivery-policy.ps1','test-dashboard.ps1')){
    & (Join-Path $root ('tests/'+$name))
    if($LASTEXITCODE -ne 0){throw ('Native surface failed: '+$name)}
}
