# Optional per-user dependencies, installed only by an explicitly authorized setup operation.
function Initialize-Hotpl8OnboardingTools([string]$Directory) {
    $bin=Join-Path $Directory 'runtime/bin'
    if(Test-Path -LiteralPath $bin -PathType Container){
        $parts=@($env:PATH -split [regex]::Escape([string][IO.Path]::PathSeparator))
        if($bin -notin $parts){$env:PATH=$bin+[IO.Path]::PathSeparator+$env:PATH}
        $env:HOTPL8_NATIVE_BIN=$bin
    }
}
function Get-Hotpl8Download([string]$Url,[string]$Destination) {
    $uri=[uri]$Url
    if($uri.Scheme -ne 'https' -or $uri.Host -notin @('github.com','api.github.com','downloads.claude.ai')){throw 'Unapproved dependency download origin.'}
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination -TimeoutSec 180
}
function Install-Hotpl8NativeRelease([string]$Directory,[string]$Repository,[string]$Tag,[string]$Name) {
    $arch=if([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64'){'aarch64'}else{'x86_64'}
    $target=if($env:OS -eq 'Windows_NT'){$arch+'-pc-windows-msvc'}elseif($IsMacOS){$arch+'-apple-darwin'}else{throw 'Automatic dependency installation supports Windows and macOS.'}
    $extension=if($env:OS -eq 'Windows_NT'){'zip'}else{'tar.gz'}
    $assetName=$Name+'-'+$target+$(if($Name -eq 'codex' -and $env:OS -eq 'Windows_NT'){'.exe'}else{''})+'.'+$extension
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $release=Invoke-RestMethod -Uri ('https://api.github.com/repos/'+$Repository+'/releases/tags/'+$Tag) -Headers @{'User-Agent'='HotPl8-setup'} -TimeoutSec 30
    $asset=@($release.assets|Where-Object name -CEQ $assetName)
    if($asset.Count -ne 1 -or $asset[0].digest -notmatch '^sha256:[a-f0-9]{64}$' -or -not $asset[0].browser_download_url.StartsWith('https://github.com/'+$Repository+'/releases/download/'+$Tag+'/')){throw 'Verified dependency asset unavailable.'}
    $stage=New-Hotpl8PrivateDirectory (Join-Path $Directory ('runtime/download-'+[guid]::NewGuid().ToString('N')))
    try{
        $archive=Join-Path $stage ('package.'+$extension)
        Get-Hotpl8Download $asset[0].browser_download_url $archive
        if((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $asset[0].digest.Substring(7)){throw 'Dependency checksum mismatch.'}
        $unpack=New-Hotpl8PrivateDirectory (Join-Path $stage 'unpacked')
        if($extension -eq 'zip'){Expand-Archive -LiteralPath $archive -DestinationPath $unpack}
        else{
            $listing=& /usr/bin/tar -tzf $archive
            if($LASTEXITCODE -ne 0 -or @($listing|Where-Object {$_ -match '(^/|(^|/)\.\.(/|$))'}).Count){throw 'Invalid dependency archive.'}
            & /usr/bin/tar -xzf $archive -C $unpack
            if($LASTEXITCODE -ne 0){throw 'Dependency extraction failed.'}
        }
        $binaryName=$Name+$(if($env:OS -eq 'Windows_NT'){'.exe'}else{''})
        $binary=@(Get-ChildItem $unpack -Recurse -File|Where-Object {$_.Name -eq $binaryName -or $_.Name -eq ($Name+'-'+$target+$(if($env:OS -eq 'Windows_NT'){'.exe'}else{''}))})
        if($binary.Count -ne 1){throw 'Dependency executable missing or ambiguous.'}
        $bin=New-Hotpl8PrivateDirectory (Join-Path $Directory 'runtime/bin')
        $destination=Join-Path $bin $binaryName
        $prepared=Join-Path $stage $binaryName
        [IO.File]::Copy($binary[0].FullName,$prepared,$false)
        if($env:OS -ne 'Windows_NT'){[IO.File]::SetUnixFileMode($prepared,[IO.UnixFileMode]'UserRead,UserWrite,UserExecute')}
        Move-Hotpl8AtomicFile $prepared $destination
        return $destination
    }finally{Remove-Item -LiteralPath $stage -Recurse -Force}
}
function Install-Hotpl8OnboardingDependencies([string]$Directory,[string]$Provider) {
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $runtime=New-Hotpl8PrivateDirectory (Join-Path $Directory 'runtime')
    $bin=New-Hotpl8PrivateDirectory (Join-Path $runtime 'bin')
    $lock=$null
    try{
        $lock=[IO.File]::Open((Join-Path $runtime 'install.lock'),'OpenOrCreate','ReadWrite','None')
        Initialize-Hotpl8OnboardingTools $Directory
        $missing=@(Get-Hotpl8OnboardingDependencies $Provider)
        if('codex' -in $missing){$null=Install-Hotpl8NativeRelease $Directory 'openai/codex' 'rust-v0.155.1' 'codex'}
        if('claude' -in $missing){
            $arch=if([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64'){'arm64'}else{'x64'}
            $platform=if($env:OS -eq 'Windows_NT'){'win32-'+$arch}elseif($IsMacOS){'darwin-'+$arch}else{throw 'Automatic installation supports Windows and macOS.'}
            $version='2.1.281';$base='https://downloads.claude.ai/claude-code-releases/'+$version
            $manifest=Invoke-RestMethod -Uri ($base+'/manifest.json') -TimeoutSec 30
            $checksum=[string]$manifest.platforms.$platform.checksum
            if($checksum -notmatch '^[a-f0-9]{64}$'){throw 'Claude platform checksum unavailable.'}
            $name=if($env:OS -eq 'Windows_NT'){'claude.exe'}else{'claude'}
            $temp=Join-Path $runtime ('claude-'+[guid]::NewGuid().ToString('N')+$(if($env:OS -eq 'Windows_NT'){'.exe'}else{''}))
            try{
                Get-Hotpl8Download ($base+'/'+$platform+'/'+$name) $temp
                if((Get-FileHash $temp -Algorithm SHA256).Hash.ToLowerInvariant() -cne $checksum){throw 'Claude checksum mismatch.'}
                if($env:OS -eq 'Windows_NT'){
                    $signature=Get-AuthenticodeSignature $temp
                    if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Anthropic'){throw 'Claude publisher signature invalid.'}
                }else{
                    & /usr/bin/codesign --verify --strict $temp 2>$null
                    if($LASTEXITCODE -ne 0){throw 'Claude code signature invalid.'}
                    [IO.File]::SetUnixFileMode($temp,[IO.UnixFileMode]'UserRead,UserWrite,UserExecute')
                }
                Move-Hotpl8AtomicFile $temp (Join-Path $bin $name)
            }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp}}
        }
        if('claude-swap' -in $missing){
            $uv=(Get-Command uv -ErrorAction SilentlyContinue).Source
            if(-not $uv){$uv=Install-Hotpl8NativeRelease $Directory 'astral-sh/uv' '0.12.21' 'uv'}
            $psi=New-Hotpl8OnboardingProcess $uv @('tool','install','claude-swap==0.26.0','--upgrade','--force','--python','3.13','--managed-python','--default-index','https://pypi.org/simple','--no-config') '' claude
            $psi.EnvironmentVariables['UV_TOOL_DIR']=Join-Path $runtime 'uv-tools'
            $psi.EnvironmentVariables['UV_TOOL_BIN_DIR']=$bin
            $psi.EnvironmentVariables['UV_PYTHON_INSTALL_DIR']=Join-Path $runtime 'python'
            $result=Invoke-Hotpl8ProcessInfo $psi 180000
            if($result.exitCode -ne 0){throw 'Claude integration installation failed.'}
        }
        Initialize-Hotpl8OnboardingTools $Directory
        Write-Hotpl8Text (Join-Path $runtime 'installation.json') (@{schemaVersion=1;product='hotpl8-dependencies';installed=@($missing);pins=@{codex='0.155.1';claude='2.1.281';cswap='0.26.0'};installedAt=[datetimeoffset]::UtcNow.ToString('o')}|ConvertTo-Json) -NoBom
    }finally{if($lock){$lock.Dispose()}}
}
