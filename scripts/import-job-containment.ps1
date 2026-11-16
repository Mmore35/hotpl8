# Explicit source refresh; never downloads or enrolls a job.
param([Parameter(Mandatory)][string]$SourceRoot,[Parameter(Mandatory)][string]$Revision)
$ErrorActionPreference='Stop'
if($Revision -notmatch '^[a-f0-9]{40}$'){throw 'Pin a complete reviewed upstream revision.'}
$body=@(& git -C $SourceRoot show ($Revision+':src/jobs/process.cs'))
if($LASTEXITCODE -ne 0){throw 'Could not read pinned containment source.'}
$text=($body -join "`n")+"`n"
$destination=Join-Path (Split-Path $PSScriptRoot -Parent) 'src/jobs'
[IO.File]::WriteAllText((Join-Path $destination 'process.cs'),$text,[Text.UTF8Encoding]::new($false))
$sha=[Security.Cryptography.SHA256]::Create()
try{$digest=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
# Windows PowerShell 5.1 writes this file with a byte-order mark and its own JSON spacing, and
# PowerShell 7 as it is committed; the values are the same. Keep the committed layout.
@{schemaVersion=1;sourceRepository='https://github.com/Mmore35/hotpl8';sourceRevision=$Revision;sourcePath='src/jobs/process.cs';hashNormalization='UTF-8 LF';files=@{'process.cs'=$digest}}|ConvertTo-Json -Depth 3|Set-Content -LiteralPath (Join-Path $destination 'provenance.json') -Encoding UTF8
