# Render documentation PNGs from the real dashboard frame and palette, with fictional data.
# Windows PowerShell 5.1 / Consolas. No native CLI, accounts, state, or network access.
param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/providers/codex.ps1')
. (Join-Path $root 'src/dashboard.ps1')
. (Join-Path $root 'tests/fixtures/screenshots.ps1')
if ($env:OS -ne 'Windows_NT') { throw 'Screenshot rendering requires Windows and Consolas.' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'docs/assets' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($output)
Add-Type -AssemblyName System.Drawing
$fixture = Get-Hotpl8ScreenshotFixture
$palette = Get-Hotpl8DashboardPalette

function Write-DashboardImage([string]$Name, $Status, $Policy, [int]$Columns, [int]$Rows, [int]$Offset=0,[switch]$Nyan) {
    $frame = @(Get-Hotpl8DashboardFrame $Status $Policy $fixture.now $Columns $Rows $Offset -Nyan:$Nyan -ReducedMotion)
    $font = New-Object Drawing.Font('Consolas', 18, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
    if ($font.Name -ne 'Consolas') { $font.Dispose(); throw 'Install Consolas to reproduce documentation images.' }
    $cellWidth = 11; $lineHeight = 24; $padding = 28; $titleHeight = 44
    $bitmap = New-Object Drawing.Bitmap(($Columns * $cellWidth + 2 * $padding), ($frame.Count * $lineHeight + 2 * $padding + $titleHeight))
    $bitmap.SetResolution(96, 96)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $brushes = @{}
    $format = [Drawing.StringFormat]::GenericTypographic.Clone()
    $format.FormatFlags = $format.FormatFlags -bor [Drawing.StringFormatFlags]::MeasureTrailingSpaces
    try {
        $graphics.Clear([Drawing.Color]::FromArgb(18, 23, 35))
        $graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        foreach ($tone in $palette.Keys) {
            $rgb = @($palette[$tone].Split(';') | ForEach-Object { [int]$_ })
            $brushes[$tone] = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb($rgb[0], $rgb[1], $rgb[2]))
        }
        $graphics.DrawString('HotPl8  /  fictional accounts', $font, $brushes.muted, [single]$padding, [single]$padding, $format)
        for ($row = 0; $row -lt $frame.Count; $row++) {
            # Position glyphs on the terminal cell grid, including wide graphemes.
            $column=0
            foreach($span in @(Get-Hotpl8RowSpans $frame[$row])){
                $fg=Get-Hotpl8Color $span.tone $palette
                if(-not $brushes.ContainsKey($fg)){$rgb=$fg.Split(';');$brushes[$fg]=New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb([int]$rgb[0],[int]$rgb[1],[int]$rgb[2]))}
                $elements=[Globalization.StringInfo]::GetTextElementEnumerator($span.text)
                while($elements.MoveNext()){
                    $glyph=[string]$elements.Current;$cells=Get-DashboardCells $glyph
                    if($span.background){
                        $bg=Get-Hotpl8Color $span.background $palette
                        if(-not $brushes.ContainsKey($bg)){$rgb=$bg.Split(';');$brushes[$bg]=New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb([int]$rgb[0],[int]$rgb[1],[int]$rgb[2]))}
                        $graphics.FillRectangle($brushes[$bg],[single]($padding+$column*$cellWidth),[single]($padding+$titleHeight+$row*$lineHeight),[single]($cells*$cellWidth),[single]$lineHeight)
                    }
                    $graphics.DrawString($glyph,$font,$brushes[$fg],[single]($padding+$column*$cellWidth),[single]($padding+$titleHeight+$row*$lineHeight),$format)
                    $column+=$cells
                }
            }
        }
        $path = Join-Path $output $Name
        $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
        $path
    } finally {
        foreach ($brush in $brushes.Values) { $brush.Dispose() }
        $format.Dispose(); $graphics.Dispose(); $bitmap.Dispose(); $font.Dispose()
    }
}

Write-DashboardImage 'dashboard.png' $fixture.status $fixture.policy 94 25
Write-DashboardImage 'details.png' $fixture.status $fixture.policy 94 34 999
$emptyPolicy = @{ mode = 'monitor'; prefer = @(); codex = @{ slots = @() } } | ConvertTo-Json -Depth 4 | ConvertFrom-Json
Write-DashboardImage 'first-run.png' $null $emptyPolicy 80 24
$operations=Get-Hotpl8ScreenshotFixture -Operations
Write-DashboardImage 'operations.png' $operations.status $operations.policy 110 50

Write-DashboardImage 'nyan.png' $fixture.status $fixture.policy 94 35 -Nyan

$healthy=Get-Hotpl8ScreenshotFixture
$healthy.policy.mode='automate'
$healthy.status.slots[0].used7d=10
$healthy.status.providers.codex.slots[0].buckets.codex.windows.'10080'.usedPercent=20
$healthy.status.providers.codex.slots[0].buckets.codex.windows.'10080'.remainingPercent=80
$healthy.policy|Add-Member NoteProperty switchEnabled $true
$healthy.policy.capacity.'1'.fiveHour=0.8
$healthy.policy.capacity.'2'.fiveHour=4
$healthy.policy.codex.capacity.work.fiveHour=4
$healthy.policy.codex.capacity.personal.fiveHour=0.8
Write-DashboardImage 'dashboard.png' $healthy.status $healthy.policy 94 25
Write-DashboardImage 'nyan.png' $healthy.status $healthy.policy 94 35 -Nyan
$critical=Get-Hotpl8ScreenshotFixture
$critical.policy.mode='automate'
$critical.policy.reserve=@()
$critical.policy|Add-Member NoteProperty critical @{enabled=$true}
foreach($slot in $critical.status.slots){$slot.used5h=94;$slot.used7d=94}
Write-DashboardImage 'critical.png' $critical.status $critical.policy 94 25
$unknown=Get-Hotpl8ScreenshotFixture
$unknown.policy.PSObject.Properties.Remove('capacity')
Write-DashboardImage 'unknown.png' $unknown.status $unknown.policy 79 24
Write-DashboardImage 'narrow.png' $healthy.status $healthy.policy 50 18
