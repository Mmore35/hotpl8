# Stable installed launcher. Every child resolves one immutable release.
param([ValidateSet('hotpl8','tick','status-print','audit-codex','setup-codex')][string]$Entry='hotpl8', [Parameter(ValueFromRemainingArguments=$true)][object[]]$Forward)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$exe=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$config=Get-Content -LiteralPath (Join-Path $root 'delivery.json') -Raw -Encoding UTF8|ConvertFrom-Json
$env:HOTPL8_STATE_DIRECTORY=$config.stateDirectory
$env:HOTPL8_INSTALL_DIRECTORY=$root
$code=0
do{
    $lease=$null
    try{
        # Long-lived display/native-client sessions use immutable code and do not
        # hold the maintenance exclusion. Short operations and ticks drain first.
        $display=($Entry -eq 'hotpl8' -and (-not $Forward.Count -or $Forward[0] -in @('watch','nyan','codex','mcp','update','delivery','preview')))
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
