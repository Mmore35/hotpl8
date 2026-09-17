# Stable installed launcher. Every child resolves one immutable release.
param([ValidateSet('hotpl8','tick','status-print','audit-codex','setup-codex')][string]$Entry='hotpl8', [Parameter(ValueFromRemainingArguments=$true)][object[]]$Forward)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$exe=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$config=Get-Content -LiteralPath (Join-Path $root 'delivery.json') -Raw -Encoding UTF8|ConvertFrom-Json
$env:HOTPL8_STATE_DIRECTORY=$config.stateDirectory
$env:HOTPL8_INSTALL_DIRECTORY=$root
# Legacy callers splat a hashtable into a compatibility shim without a param
# block. PowerShell preserves each named argument as '-Name:' plus its typed
# value. Native -File cannot bind a separate Boolean to a switch in Windows
# PowerShell 5.1: emit the flag for true and omit it for false instead.
$native=New-Object 'Collections.Generic.List[string]'
for($i=0;$i -lt $Forward.Count;$i++){
    $item=$Forward[$i]
    if($item -is [string] -and $item -match '^-[A-Za-z][A-Za-z0-9]*:$' -and $i+1 -lt $Forward.Count){
        $name=$item.TrimEnd(':');$i++;$value=$Forward[$i]
        if($value -is [bool] -or $value -is [Management.Automation.SwitchParameter]){
            if([bool]$value){$native.Add($name)}
        }else{$native.Add($name);$native.Add([string]$value)}
    }else{$native.Add([string]$item)}
}
$Forward=$native.ToArray()
$command=if($Forward.Count){$Forward[0]}else{'watch'}
if($command.StartsWith('-')){
    for($i=0;$i+1 -lt $Forward.Count;$i++){if($Forward[$i] -ieq '-Command'){$command=$Forward[$i+1];break}}
}
$code=0
do{
    $lease=$null
    try{
        # Long-lived display/native-client sessions use immutable code and do not
        # hold the maintenance exclusion. Short operations and ticks drain first.
        $display=($Entry -eq 'hotpl8' -and $command -in @('watch','nyan','codex','mcp','update','delivery','preview'))
        if(-not $display){
            try{$lease=[IO.File]::Open((Join-Path $root 'runtime.lock'),'OpenOrCreate','ReadWrite','ReadWrite')}
            catch{if($Entry -in @('tick','status-print')){exit 0};throw 'HotPl8 is updating; retry shortly.'}
        }
        $current=Get-Content -LiteralPath (Join-Path $root 'current.json') -Raw -Encoding UTF8|ConvertFrom-Json
        if($current.sha -notmatch '^[a-f0-9]{40}$' -or $current.release -cne ('releases/'+$current.sha)){throw 'Invalid installed release pointer.'}
        $script=Join-Path (Join-Path $root $current.release) ($Entry+'.ps1')
        & $exe -NoProfile -ExecutionPolicy Bypass -File $script @Forward
        $code=$LASTEXITCODE
    }finally{if($lease){$lease.Dispose()}}
}while($code -eq 75 -and $display)
exit $code
