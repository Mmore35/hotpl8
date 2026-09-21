# Import is inert. Compilation stages an immutable GUI host in this installation.
function Install-Hotpl8JobHost([string]$InstallDirectory) {
    $source=Join-Path $PSScriptRoot 'jobs'
    $provenance=Get-Content -LiteralPath (Join-Path $source 'provenance.json') -Raw|ConvertFrom-Json
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
        $processText=[IO.File]::ReadAllText((Join-Path $source 'process.cs')).Replace("`r`n","`n")
        $importDigest=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($processText)))).Replace('-','').ToLowerInvariant()
        if($importDigest -ne $provenance.files.'process.cs'){throw 'Containment source provenance mismatch.'}
        $text=$processText+[IO.File]::ReadAllText((Join-Path $source 'finite-host.cs')).Replace("`r`n","`n")
        $digest=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','').ToLowerInvariant()
    }finally{$sha.Dispose()}
    $dir=Join-Path $InstallDirectory ('launchers/'+$digest)
    $null=New-Item -ItemType Directory -Path $dir -Force
    $exe=Join-Path $dir 'finite-host.exe'
    $lease=[IO.File]::Open((Join-Path $dir 'build.lock'),'OpenOrCreate','ReadWrite','None')
    try{
        $manifest=Join-Path $dir 'host.json'
        if(Test-Path -LiteralPath $manifest){
            $record=Get-Content -LiteralPath $manifest -Raw|ConvertFrom-Json
            if((Get-FileHash -LiteralPath $exe).Hash -ne $record.sha256){throw 'Installed host changed.'}
        }else{
            $stage=Join-Path $dir ('stage-'+[guid]::NewGuid().ToString('N')+'.exe')
            Add-Type -Path @((Join-Path $source 'process.cs'),(Join-Path $source 'finite-host.cs')) -ReferencedAssemblies @('System.dll','System.Core.dll','System.Web.Extensions.dll') -OutputAssembly $stage -OutputType WindowsApplication
            Move-Item -LiteralPath $stage -Destination $exe -Force
            @{schemaVersion=1;sourceDigest=$digest;sha256=(Get-FileHash -LiteralPath $exe).Hash}|ConvertTo-Json|Set-Content -LiteralPath $manifest -Encoding UTF8
        }
    }finally{$lease.Dispose()}
    return $exe
}

function Get-Hotpl8JobComponentStatus([string]$InstallDirectory) {
    $config=Read-Hotpl8Json (Join-Path $InstallDirectory 'delivery.json')
    if(-not $config.scheduledJobs){return}
    foreach($role in @('collector','updater')){
        $name=if($role -eq 'collector'){$config.scheduledJobs.collectorTask}else{'LocalDelivery-'+$config.product}
        if(-not $name){continue}
        $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        $latest=Get-ChildItem -LiteralPath (Join-Path $InstallDirectory ('job-runs/'+$role)) -Filter run.json -Recurse -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
        $receipt=if($latest){Read-Hotpl8Json $latest.FullName}else{$null}
        $valid=$task -and $task.Actions.Count -eq 1 -and $task.Actions[0].Execute -eq $config.scheduledJobs.host -and (Test-Path -LiteralPath $config.scheduledJobs.host)
        [pscustomobject]@{component=('scheduled-'+$role);state=$(if($valid){'current'}else{'error'});task=$name;nextLaunchHost=$config.scheduledJobs.host;observedHost=$receipt.host;execution=$receipt.status;observedAt=$receipt.completedAt;adoption='Next native wake; admitted work completes on its original host';outcomeAuthority=$(if($role -eq 'collector'){'collector.json; provider freshness remains separate'}else{'delivery-status.json'})}
    }
}
