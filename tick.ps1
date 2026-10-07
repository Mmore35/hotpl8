# One wake of the collector. The collector is the compiled program (native/src/wake.rs); this
# file starts it for whoever names tick.ps1, with the parameters it has always taken.
# Scheduled collection is quiet; interactive callers can request nonzero failure exits.
param([string]$StateDirectory,[string]$CswapExecutable,[string]$CodexExecutable,[switch]$ObserveOnly,[switch]$Strict,[switch]$Scheduled)
$ErrorActionPreference='Stop'
. ([IO.Path]::Combine($PSScriptRoot,'src','native.ps1'))
$arguments=@('collect','--root',$PSScriptRoot)
if($StateDirectory){$arguments+=@('--state',$StateDirectory)}
if($CswapExecutable){$arguments+=@('--cswap',$CswapExecutable)}
if($CodexExecutable){$arguments+=@('--codex',$CodexExecutable)}
# Off Windows, what the collector leaves to PowerShell runs in the one that started this file.
if($env:OS -ne 'Windows_NT'){$arguments+=@('--powershell',[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)}
if($Scheduled){$arguments+='--scheduled'}
if($ObserveOnly){$arguments+='--observe-only'}
if($Strict){$arguments+='--strict'}
$result=$null
try{$result=Invoke-Hotpl8NativeProcess (Get-Hotpl8NativePath $PSScriptRoot) $arguments}catch{$result=$null}
if(-not $result){
    [Console]::Error.WriteLine('HotPl8: This copy has no compiled collector it can start. A release ships one; in a checkout, build it with scripts/build-native.ps1.')
    if($Strict){exit 1}
    exit 0
}
if($result.errors){[Console]::Error.Write($result.errors.Replace("`n",[Environment]::NewLine))}
# One line per account action, as the collector printed them.
$text=$result.output
if($text.EndsWith("`n",[StringComparison]::Ordinal)){$text=$text.Substring(0,$text.Length-1)}
if($text){$text.Split("`n")}
exit $result.exitCode
