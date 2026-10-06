# Build the compiled reader for this platform into bin/. CI runs this before the suites and
# before packaging, so the file that was tested is the file that ships.
param([string[]]$Target,[string]$Sha)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$native=Join-Path $root 'native'
$windows=$env:OS -eq 'Windows_NT'
if(-not $windows -and -not $IsMacOS){throw 'The native reader is built for Windows and macOS.'}
foreach($tool in @('cargo','rustc')){
    if(-not (Get-Command $tool -ErrorAction SilentlyContinue)){throw 'Rust is required to build the native reader. Install it from https://rustup.rs and retry.'}
}
# The binary carries the commit it was built from and declines a release that names
# another one; src/native.ps1 sends the commit from the release's build-info.json.
if(-not $Sha){$Sha=$env:GITHUB_SHA}
if(-not $Sha -and (Get-Command git -ErrorAction SilentlyContinue)){
    # Outside a checkout git answers on the error stream, which Windows PowerShell raises.
    try{$head=& git -C $root rev-parse HEAD 2>$null}catch{$head=$null}
    if($head -and $LASTEXITCODE -eq 0){$Sha=([string]$head).Trim()}
}
if($Sha -and $Sha -cnotmatch '^[a-f0-9]{40}$'){throw 'Build identity must be a full commit SHA.'}
$name=if($windows){'hotpl8-native.exe'}else{'hotpl8-native'}
$output=Join-Path $root ($(if($windows){'bin/windows/'}else{'bin/macos/'})+$name)
$priorSha=$env:HOTPL8_BUILD_SHA;$priorFloor=$env:MACOSX_DEPLOYMENT_TARGET
Push-Location $native
try{
    $env:HOTPL8_BUILD_SHA=$Sha
    if(-not $Target){
        if($windows){
            $hostLine=@(& rustc -vV|Where-Object{$_ -like 'host: *'})
            if($LASTEXITCODE -ne 0 -or $hostLine.Count -ne 1){throw 'Could not read the Rust host target.'}
            $Target=@($hostLine[0].Substring(6).Trim())
        }else{$Target=@('aarch64-apple-darwin','x86_64-apple-darwin')}
    }
    if(-not $windows){$env:MACOSX_DEPLOYMENT_TARGET='11.0'}
    $built=@()
    foreach($triple in $Target){
        if($triple -cnotmatch '^[a-z0-9_]+(-[a-z0-9_]+)+$'){throw 'Invalid Rust target.'}
        if(Get-Command rustup -ErrorAction SilentlyContinue){
            & rustup target add $triple
            if($LASTEXITCODE -ne 0){throw ('Could not install the Rust target: '+$triple)}
        }
        & cargo build --release --locked --target $triple
        if($LASTEXITCODE -ne 0){throw ('Native build failed: '+$triple)}
        $built+=Join-Path $native ('target/'+$triple+'/release/'+$name)
    }
    [void][IO.Directory]::CreateDirectory((Split-Path $output -Parent))
    if($windows){
        if($built.Count -ne 1){throw 'Windows ships one architecture.'}
        [IO.File]::Copy($built[0],$output,$true)
    }else{
        # One file for Apple silicon and Intel. Joining invalidates the linker's signature,
        # and Apple silicon refuses unsigned code, so sign again without an identity.
        & /usr/bin/lipo -create -output $output @built
        if($LASTEXITCODE -ne 0){throw 'Could not join the Mac architectures.'}
        & /usr/bin/codesign --force --sign - $output
        if($LASTEXITCODE -ne 0){throw 'Could not sign the Mac binary.'}
        [IO.File]::SetUnixFileMode($output,[IO.UnixFileMode]'UserRead,UserWrite,UserExecute,GroupRead,GroupExecute,OtherRead,OtherExecute')
    }
    $identity=@(& $output self-check)
    $expected=if($Sha){$Sha}else{'unknown'}
    if($LASTEXITCODE -ne 0 -or $identity.Count -ne 1 -or $identity[0] -cnotmatch ('^hotpl8-native protocol=[0-9]+ sha='+$expected+'$')){throw 'The built native reader did not report the expected identity.'}
    $output
}finally{
    Pop-Location
    $env:HOTPL8_BUILD_SHA=$priorSha;$env:MACOSX_DEPLOYMENT_TARGET=$priorFloor
}
