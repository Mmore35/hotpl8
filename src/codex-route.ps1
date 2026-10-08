# Internal anonymous-pipe endpoint, kept at the path an installed entry looks for. The account
# is chosen by the compiled program this copy ships (native/src/route.rs): this passes it the
# one line asked and answers with its one line. A success response is sensitive; never log it.
param([Parameter(Mandatory=$true)][string]$StateDirectory,[Parameter(Mandatory=$true)][string]$Executable)
$ErrorActionPreference='Stop'
[Console]::InputEncoding=New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$result=$null
try{
    . ([IO.Path]::Combine($PSScriptRoot,'native.ps1'))
    $root=[IO.Path]::GetDirectoryName($PSScriptRoot)
    $line=[Console]::ReadLine()
    $result=Invoke-Hotpl8NativeProcess (Get-Hotpl8NativePath $root) @('route','--root',$root,'--state',$StateDirectory,'--codex',$Executable) -Asked ([string]$line+"`n")
}catch{$result=$null}
# The program names every refusal itself. With no answer there was no program to ask.
if(-not $result -or -not $result.output){[Console]::WriteLine('{"error":"routing_failed"}');exit 1}
[Console]::Out.Write($result.output)
exit $result.exitCode
