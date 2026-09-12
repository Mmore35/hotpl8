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

function Write-DashboardImage([string]$Name, $Status, $Policy, [int]$Columns, [int]$Rows) {
    $frame = @(Get-Hotpl8DashboardFrame $Status $Policy $fixture.now $Columns $Rows)
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
            $elements = [Globalization.StringInfo]::GetTextElementEnumerator($frame[$row].text)
            $column = 0
            while ($elements.MoveNext()) {
                $glyph = [string]$elements.Current
                $graphics.DrawString($glyph, $font, $brushes[$frame[$row].tone], [single]($padding + $column * $cellWidth), [single]($padding + $titleHeight + $row * $lineHeight), $format)
                $column += Get-DashboardCells $glyph
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

Write-DashboardImage 'dashboard.png' $fixture.status $fixture.policy 94 42
$emptyPolicy = @{ mode = 'monitor'; prefer = @(); codex = @{ slots = @() } } | ConvertTo-Json -Depth 4 | ConvertFrom-Json
Write-DashboardImage 'first-run.png' $null $emptyPolicy 80 24
