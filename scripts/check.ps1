# Offline checks for parse errors, data validity, private paths, and broken local Markdown links.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/config.ps1')
. (Join-Path $root 'src/providers/codex.ps1')
$files=@(Get-ChildItem -LiteralPath $root -Recurse -File|Where-Object{$_.FullName -notmatch '[\\/](dist|artifacts|\.git)[\\/]'})
$failures=@()
foreach($file in $files){
    if($file.Extension -eq '.ps1'){
        $tokens=$null;$errors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        if($errors){$failures+=('PowerShell parse: '+$file.Name)}
    }
    if($file.Extension -eq '.json'){
        try{$null=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8|ConvertFrom-Json}catch{$failures+=('Invalid JSON: '+$file.Name)}
    }
    if($file.Extension -in @('.md','.ps1','.sh','.py','.json','.yml','.vbs')){
        $text=[IO.File]::ReadAllText($file.FullName)
        if($text -match '(?i)(/Users/[a-z][a-z0-9_-]+/|[A-Z]:\\Users\\[a-z][a-z0-9_-]+\\|[a-z0-9._%+-]+@(?:gmail|outlook|hotmail)\.com)'){$failures+=('Private data/path candidate: '+$file.Name)}
        if($file.Extension -eq '.md'){
            foreach($match in [regex]::Matches($text,'\[[^\]]+\]\(([^)]+)\)')){
                $link=$match.Groups[1].Value.Split('#')[0]
                if($link -and $link -notmatch '^(https?://|mailto:)'){
                    if(-not (Test-Path -LiteralPath (Join-Path $file.DirectoryName $link))){$failures+=('Broken link: '+$file.Name+' -> '+$link)}
                }
            }
        }
    }
}
foreach($path in @((Join-Path $root 'policy.example.json'))+@(Get-ChildItem (Join-Path $root 'examples') -Filter '*.json'|ForEach-Object FullName)){
    $policy=Read-Hotpl8Json $path
    Assert-Hotpl8Policy $policy
    if($policy.codex){Assert-CodexPolicy $policy.codex}
}
if((Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue) -or (Get-Module -ListAvailable PSScriptAnalyzer)){
    $findings=@(Invoke-ScriptAnalyzer -Path $root -Recurse -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1'))
    if($findings){$findings|Format-Table RuleName,ScriptName,Line;throw 'Static analyzer findings.'}
}else{'PSScriptAnalyzer not installed locally; CI installs the pinned analyzer.'}
if($failures){$failures|ForEach-Object{[Console]::Error.WriteLine($_)};exit 1}
'Static, JSON, example-policy, privacy, and local-link checks passed.'
