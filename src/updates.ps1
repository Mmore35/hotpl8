function Get-Hotpl8Release([string]$Channel='stable', [string]$Version, [scriptblock]$Fetch) {
    if($Version -and $Version -notmatch '^v?[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$'){throw 'Invalid release version.'}
    $url='https://api.github.com/repos/Mmore35/hotpl8/releases'
    if($Version){$url+='/tags/'+$(if($Version.StartsWith('v')){$Version}else{'v'+$Version})}
    if($Fetch){$releases=& $Fetch $url}else{$releases=Invoke-RestMethod -Uri $url -Headers @{'User-Agent'='HotPl8';Accept='application/vnd.github+json'} -TimeoutSec 20}
    $release=@($releases|Where-Object {-not $_.draft -and ($Channel -eq 'preview' -or -not $_.prerelease)}|Sort-Object published_at -Descending|Select-Object -First 1)
    if(-not $release.Count){return $null}
    $r=$release[0]
    if($r.tag_name -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$'){throw 'Invalid remote release tag.'}
    $name='hotpl8-'+$r.tag_name.Substring(1)+'-windows.zip'
    $asset=@($r.assets|Where-Object name -EQ $name)
    if($asset.Count -ne 1){throw 'Release does not contain a Windows package.'}
    $expected='https://github.com/Mmore35/hotpl8/releases/download/'+$r.tag_name+'/'+$name
    if($asset[0].browser_download_url -cne $expected){throw 'Unexpected release asset origin.'}
    return [pscustomobject]@{version=$r.tag_name.Substring(1);tag=$r.tag_name;url=$expected;name=$name;notes=$r.html_url;prerelease=[bool]$r.prerelease}
}
function Expand-Hotpl8VerifiedArchive([string]$Archive,[string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.IO.Compression
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try{
        if($zip.Entries.Count -gt 1000){throw 'Oversized release manifest.'}
        $seen=@{};[long]$total=0
        foreach($e in $zip.Entries){
            if($e.FullName -notmatch '^[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)*$' -or $e.FullName -match '(^|/)\.\.?(/|$)' -or $seen.ContainsKey($e.FullName)){throw 'Unsafe archive entry.'}
            $seen[$e.FullName]=$true;$total+=$e.Length
            if($total -gt 52428800){throw 'Release exceeds extraction budget.'}
        }
    }finally{$zip.Dispose()}
    [IO.Compression.ZipFile]::ExtractToDirectory($Archive,$Destination)
}
function Install-Hotpl8Update($Release,[string]$InstallDirectory,[string]$SourceDigest) {
    if($env:OS -ne 'Windows_NT'){throw 'Use the macOS handoff plan; Windows updater only.'}
    if(-not $InstallDirectory){throw 'Pass -InstallDirectory for the owned installation to update.'}
    . (Join-Path $PSScriptRoot 'lifecycle.ps1')
    $InstallDirectory=Assert-Hotpl8Path $InstallDirectory
    $owned=Read-Hotpl8Json (Join-Path $InstallDirectory 'installation.json')
    if(-not $owned -or $owned.product -ne 'hotpl8' -or -not $owned.version){throw 'Update requires an existing owned installation.'}
    if(-not (Test-Hotpl8NewerVersion $Release.version $owned.version)){throw 'Selected release is not newer. Use the explicit rollback procedure for a downgrade.'}
    $commit=Get-Hotpl8ReleaseCommit $Release.tag
    if(-not $SourceDigest){$SourceDigest=$commit}
    if($SourceDigest -notmatch '^[a-f0-9]{40}$' -or $SourceDigest -cne $commit){throw 'Release tag does not match the selected source revision.'}
    $gh=Get-Command gh -ErrorAction SilentlyContinue
    if(-not $gh){throw 'Verified updates require GitHub CLI (gh attestation verify). Manual installation is also available.'}
    $temp=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-update-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($temp)
    try{
        $archive=Join-Path $temp $Release.name
        Invoke-WebRequest -UseBasicParsing -Uri $Release.url -OutFile $archive -TimeoutSec 120
        $args=@('attestation','verify',$archive,'--repo','Mmore35/hotpl8','--signer-workflow','Mmore35/hotpl8/.github/workflows/release.yml','--source-digest',$SourceDigest,'--source-ref',('refs/heads/main'),'--deny-self-hosted-runners')
        $verified=Invoke-Hotpl8Process $gh.Source $args 120000
        if($verified.exitCode -ne 0){throw 'Artifact provenance verification failed. Nothing installed.'}
        if((Get-Hotpl8ReleaseCommit $Release.tag) -cne $commit){throw 'Release tag moved during verification. Nothing installed.'}
        $stage=Join-Path $temp 'release'
        Expand-Hotpl8VerifiedArchive $archive $stage
        if((Get-Content (Join-Path $stage 'VERSION') -Raw).Trim() -ne $Release.version){throw 'Package version mismatch.'}
        # New installer runs out of the installation it replaces and keeps rollback.
        $ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $result=Invoke-Hotpl8Process $ps @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $stage 'install.ps1'),'-InstallDirectory',$InstallDirectory) 120000
        if($result.exitCode -ne 0){throw 'Update installation failed. Inspect the owned installation and rollback instructions.'}
        return $result.output
    }finally{
        $full=[IO.Path]::GetFullPath($temp);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        if((Split-Path $full -Parent) -eq $parent -and (Split-Path $full -Leaf) -match '^hotpl8-update-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
    }
}
function Test-Hotpl8NewerVersion([string]$Candidate,[string]$Current) {
    foreach($v in @($Candidate,$Current)){if($v -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$'){throw 'Invalid semantic version.'}}
    $a=$Candidate.Split('-',2);$b=$Current.Split('-',2)
    $cmp=([version]$a[0]).CompareTo([version]$b[0]);if($cmp -ne 0){return $cmp -gt 0}
    if($a.Count -eq 1){return $b.Count -gt 1};if($b.Count -eq 1){return $false}
    $left=$a[1].Split('.');$right=$b[1].Split('.')
    for($n=0;$n -lt [math]::Min($left.Count,$right.Count);$n++){
        if($left[$n] -ceq $right[$n]){continue}
        $ln=$left[$n] -match '^[0-9]+$';$rn=$right[$n] -match '^[0-9]+$'
        if($ln -and $rn){return [decimal]$left[$n] -gt [decimal]$right[$n]}
        if($ln -ne $rn){return -not $ln}
        return [string]::CompareOrdinal($left[$n],$right[$n]) -gt 0
    }
    return $left.Count -gt $right.Count
}
function Get-Hotpl8ReleaseCommit([string]$Tag,[scriptblock]$Fetch) {
    if($Tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$'){throw 'Invalid release tag.'}
    $url='https://api.github.com/repos/Mmore35/hotpl8/commits/'+$Tag
    $result=if($Fetch){& $Fetch $url}else{Invoke-RestMethod -Uri $url -Headers @{'User-Agent'='HotPl8';Accept='application/vnd.github+json'} -TimeoutSec 20}
    if($result.sha -notmatch '^[a-f0-9]{40}$'){throw 'Invalid release source revision.'}
    return [string]$result.sha
}
