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

# A time as a run receipt or the updater's status holds it, or nothing when it cannot be read.
function ConvertTo-Hotpl8JobTime($Value) {try{return [datetimeoffset]$Value}catch{return $null}}

function Get-Hotpl8JobComponentStatus([string]$InstallDirectory,[datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
    $config=Read-Hotpl8Json (Join-Path $InstallDirectory 'delivery.json')
    if(-not $config.scheduledJobs){return}
    foreach($role in @('collector','updater')){
        $name=if($role -eq 'collector'){$config.scheduledJobs.collectorTask}else{'LocalDelivery-'+$config.product}
        if(-not $name){continue}
        $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        # Hosts publish their newest receipt as latest.json. Searching every run folder is
        # only for runs left by a host from before it, and takes seconds once they pile up.
        $runs=Join-Path $InstallDirectory ('job-runs/'+$role)
        $latest=Get-Item -LiteralPath (Join-Path $runs 'latest.json') -ErrorAction SilentlyContinue
        if(-not $latest){$latest=Get-ChildItem -LiteralPath $runs -Filter run.json -Recurse -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1}
        $receipt=if($latest){Read-Hotpl8Json $latest.FullName}else{$null}
        $valid=$task -and $task.Actions.Count -eq 1 -and $task.Actions[0].Execute -eq $config.scheduledJobs.host -and (Test-Path -LiteralPath $config.scheduledJobs.host)
        $row=[pscustomobject]@{component=('scheduled-'+$role);state=$(if(-not $valid){'error'}elseif(-not $task.Settings.Enabled){'disabled'}else{'current'});task=$name;nextLaunchHost=$config.scheduledJobs.host;observedHost=$receipt.host;execution=$receipt.status;observedAt=$receipt.completedAt;adoption='Next native wake; admitted work completes on its original host';outcomeAuthority=$(if($role -eq 'collector'){'collector.json; provider freshness remains separate'}else{'delivery-status.json'})}
        if($role -eq 'updater'){
            # Every check is stamped in delivery-status.json, whoever started it. A task that is
            # turned off while checks stamped after its own last run keep arriving is checked
            # from outside that task. An hour without one and it reads disabled again, so the day
            # the checks stop does not read like the days before it.
            $stamp=(Read-Hotpl8Json (Join-Path $InstallDirectory 'delivery-status.json')).lastCheck
            $check=ConvertTo-Hotpl8JobTime $stamp
            $age=if($check){[long][Math]::Floor(($Now-$check).TotalSeconds)}else{$null}
            if($row.state -eq 'disabled' -and $check -and $age -ge 0 -and $age -le 3600){
                # A run that left no completion is given the 540 seconds register.ps1 allows it;
                # a receipt that cannot be read shows nothing about where the check came from.
                $started=ConvertTo-Hotpl8JobTime $receipt.startedAt
                $ended=if(-not $latest){[datetimeoffset]::MinValue}elseif($receipt.completedAt){ConvertTo-Hotpl8JobTime $receipt.completedAt}elseif($started){$started.AddSeconds(540)}else{$null}
                if($ended -and $check -gt $ended){$row.state='external'}
            }
            $row|Add-Member NoteProperty lastCheck $stamp
            $row|Add-Member NoteProperty lastCheckAgeSeconds $age
        }
        $row
    }
}
