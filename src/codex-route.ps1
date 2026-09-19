# Internal anonymous-pipe endpoint. Its success response is sensitive; never log it.
param([Parameter(Mandatory=$true)][string]$StateDirectory,[Parameter(Mandatory=$true)][string]$Executable)
$ErrorActionPreference='Stop'
[Console]::InputEncoding=New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
try{
    . (Join-Path $PSScriptRoot 'common.ps1')
    . (Join-Path $PSScriptRoot 'config.ps1')
    . (Join-Path $PSScriptRoot 'providers/claude.ps1')
    . (Join-Path $PSScriptRoot 'providers/codex.ps1')
    . (Join-Path $PSScriptRoot 'codex-routing.ps1')
    $line=[Console]::ReadLine()
    if(-not $line -or $line.Length -gt 16384){throw 'routing_invalid_request'}
    $request=$line|ConvertFrom-Json
    $result=Get-Hotpl8CodexRoute $request $StateDirectory $Executable
    [Console]::WriteLine(($result|ConvertTo-Json -Depth 12 -Compress))
}catch{
    $code=[string]$_.Exception.Message
    if($code -notin @('routing_environment_conflict','routing_invalid_request','routing_model_unknown','routing_duplicate_identity','routing_stale','routing_unavailable','routing_binding_changed','routing_refresh_failed','routing_auth_unavailable')){$code='routing_failed'}
    [Console]::WriteLine((@{error=$code}|ConvertTo-Json -Compress))
    exit 1
}
