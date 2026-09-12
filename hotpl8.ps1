# refresh observes; tick applies policy. Authentication belongs to native provider tools.
[CmdletBinding(PositionalBinding=$false)]
param(
 [Parameter(Position=0)][ValidateSet('watch','status','refresh','tick','codex','doctor','version','help','init')][string]$Command='watch',
 [string]$Slot,[string]$Model,[string]$StateDirectory,[string]$CodexExecutable,[switch]$AsJson,
 [Parameter(Position=1,ValueFromRemainingArguments=$true)][string[]]$CodexArguments
)
$ErrorActionPreference='Stop'
try{
 . (Join-Path $PSScriptRoot 'common.ps1')
 . (Join-Path $PSScriptRoot 'config.ps1')
 . (Join-Path $PSScriptRoot 'diagnostics.ps1')
 . (Join-Path $PSScriptRoot 'providers/claude.ps1')
 . (Join-Path $PSScriptRoot 'providers/codex.ps1')
 $StateDirectory=Resolve-Hotpl8StateDirectory $StateDirectory $PSScriptRoot
 if($Command -eq 'version'){(Get-Content (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim();exit 0}
 if($Command -eq 'help'){
  'hotpl8 [watch|status|refresh|tick|doctor|version|init|codex]'
  'watch: cached dashboard; Space freezes the view only.'
  'refresh: collect quotas without switching, warming, or recovery prompts.'
  'tick: collect and apply actions enabled by policy; monitor mode prevents actions.'
  'status -AsJson: local cached snapshot (may contain private labels).'
  'doctor -AsJson: redacted offline diagnostics; no login or quota calls.'
  'init: create a monitoring-only policy if none exists.'
  'codex [-Slot ID] [-Model ID] [native arguments]; resume requires -Slot.'
  'All commands accept -StateDirectory PATH. See docs/usage.md.'
  exit 0
 }
 if($Command -eq 'init'){
  [void][IO.Directory]::CreateDirectory($StateDirectory)
  $path=Join-Path $StateDirectory 'policy.json'
  if(Test-Path -LiteralPath $path){throw 'policy.json already exists; it was not overwritten.'}
  [IO.File]::Copy((Join-Path $PSScriptRoot 'policy.example.json'),$path,$false)
  'Created a monitoring policy. Enroll native accounts using docs/install.md.'
  exit 0
 }
 if($Command -eq 'doctor'){
  $d=Get-Hotpl8Doctor $StateDirectory
  if($AsJson){$d|ConvertTo-Json -Depth 5}else{$d|Format-List}
  if(-not $d.policyValid){exit 1};exit 0
 }
 $policy=Read-Hotpl8Json (Join-Path $StateDirectory 'policy.json')
 if(-not $policy){throw 'No valid policy.json. Run hotpl8 init or see docs/install.md.'}
 Assert-Hotpl8Policy $policy
 if($Command -eq 'watch'){
  . (Join-Path $PSScriptRoot 'dashboard.ps1')
  Show-Hotpl8Dashboard $StateDirectory
  exit 0
 }
 if($Command -in @('refresh','tick')){
  & (Join-Path $PSScriptRoot 'tick.ps1') -StateDirectory $StateDirectory -CodexExecutable $CodexExecutable -ObserveOnly:($Command -eq 'refresh') -Strict
  if($LASTEXITCODE -ne 0){throw 'Collection incomplete. Run hotpl8 doctor; inspect local events.jsonl. Old data is not a fresh result.'}
  $Command='status'
 }
 $status=Read-Hotpl8Json (Join-Path $StateDirectory 'status.json')
 if($Command -eq 'status'){
  if(-not $status){'No cached status. Run hotpl8 refresh.';exit 0}
  if($AsJson){$status|ConvertTo-Json -Depth 24;exit 0}
  'HotPl8 | generated '+(ConvertTo-Hotpl8SafeText $status.generatedAt)
  $age=([datetimeoffset]::UtcNow-[datetimeoffset]::Parse($status.generatedAt)).TotalSeconds
  if($age -gt 900 -or $age -lt -5){'STALE: refresh before relying on these readings.'}
  ConvertTo-Hotpl8SafeText ('Claude: active slot '+$status.active+' | '+$status.verdict)
  foreach($s in @($status.slots)){
   $five=if($null -eq $s.used5h){'unknown'}else{[string](100-$s.used5h)+'% remaining'}
   $week=if($null -eq $s.used7d){'unknown'}else{[string](100-$s.used7d)+'% remaining'}
   ConvertTo-Hotpl8SafeText ('  '+$s.label+' ['+$s.slot+'] 5h '+$five+' | 7d '+$week+' | '+$s.status)
  }
  if($status.providers.codex){Format-CodexStatus $status.providers.codex $policy.codex|ForEach-Object{ConvertTo-Hotpl8SafeText $_}}
  else{'Codex: not configured or no observation yet.'}
  exit 0
 }
 if(-not $policy.codex){throw 'No Codex slots configured.'}
 $plan=Get-CodexLaunchPlan $policy.codex $status.providers.codex $Slot $Model $CodexArguments ([datetimeoffset]::UtcNow)
 exit (Invoke-Hotpl8Codex $plan $StateDirectory $CodexExecutable (Get-Location).Path)
}catch{
 [Console]::Error.WriteLine('HotPl8: '+(ConvertTo-Hotpl8SafeText $_.Exception.Message))
 exit 1
}
