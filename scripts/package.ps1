# Build only manifest-listed files. No working-copy state or credentials enter an archive.
param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'common.ps1')
. (Join-Path $root 'lifecycle.ps1')
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root 'dist'}
$output=Assert-Hotpl8Path $OutputDirectory
[void][IO.Directory]::CreateDirectory($output)
$version=(Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
if($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$'){throw 'Invalid version'}
$files=@(Get-Hotpl8ReleaseFiles $root)
$stage=Join-Path $output ('package-'+[guid]::NewGuid().ToString('N'))
$zip=Join-Path $output ('hotpl8-'+$version+'-windows.zip')
[void][IO.Directory]::CreateDirectory($stage)
try{
    $hashes=[ordered]@{}
    foreach($file in $files){
        $target=Join-Path $stage $file
        [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
        [IO.File]::Copy((Join-Path $root $file),$target,$false)
        $hashes[$file]=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    Write-Hotpl8Text (Join-Path $stage 'checksums.json') ($hashes|ConvertTo-Json -Depth 4) -NoBom
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.IO.Compression
    # A stable order and timestamp make repeated builds from identical bytes reproducible.
    $stream=[IO.File]::Open($zip,'Create','ReadWrite','None')
    $archive=$null
    try{
        $archive=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
        foreach($file in @($files+@('checksums.json')|Sort-Object)){
            $entry=$archive.CreateEntry($file,[IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime=[datetimeoffset]::Parse('2000-01-01T00:00:00Z')
            $from=[IO.File]::OpenRead((Join-Path $stage $file));$to=$entry.Open()
            try{$from.CopyTo($to)}finally{$from.Dispose();$to.Dispose()}
        }
    }finally{if($archive){$archive.Dispose()};$stream.Dispose()}
    $digest=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Hotpl8Text (Join-Path $output 'SHA256SUMS') ($digest+'  '+[IO.Path]::GetFileName($zip)+[Environment]::NewLine) -NoBom
    $zip
}finally{
    $resolved=Assert-Hotpl8Path $stage
    if((Split-Path $resolved -Parent) -ne $output -or (Split-Path $resolved -Leaf) -notmatch '^package-[a-f0-9]{32}$'){throw 'Invalid package stage'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
