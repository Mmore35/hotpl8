param([string]$ReleaseDirectory,[string]$StateDirectory,[string]$InstallDirectory,[switch]$RecordOwner)
$ErrorActionPreference='Stop'
. (Join-Path $ReleaseDirectory 'src/common.ps1')
. (Join-Path $ReleaseDirectory 'src/config.ps1')
. (Join-Path $ReleaseDirectory 'src/providers/codex.ps1')
. (Join-Path $ReleaseDirectory 'src/delivery-policy.ps1')
$policy=Read-Hotpl8Json (Join-Path $StateDirectory 'policy.json')
Assert-Hotpl8Policy $policy
if($policy.codex){Assert-CodexPolicy $policy.codex}
if($RecordOwner){Set-Hotpl8DeliveryOwner $InstallDirectory $StateDirectory}
# No provider process, quota poll, credential read, prompt, or state migration.
