# Render documentation PNGs from the frames the compiled reader draws, with fictional data.
# Windows PowerShell 5.1 / Consolas. No provider CLI, accounts, state, or network access.
param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/native.ps1')
. (Join-Path $root 'tests/fixtures/screenshots.ps1')
. (Join-Path $root 'tests/fixtures/terminal.ps1')
if ($env:OS -ne 'Windows_NT') { throw 'Screenshot rendering requires Windows and Consolas.' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'docs/assets' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($output)
Add-Type -AssemblyName System.Drawing
$fixture = Get-Hotpl8ScreenshotFixture
$reader = Get-Hotpl8NativePath $root
if (-not [IO.File]::Exists($reader)) { throw 'Build the compiled reader first: scripts/build-native.ps1' }
# The reader draws a state it reads from disk. Each image stages its fictional one here.
$staging = Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-screenshots-' + [guid]::NewGuid().ToString('N'))

# The frame as the reader writes it to a terminal, decoded into the cells it colours. The
# fixture's clock and UTC stand in for this machine's, so every machine draws the same frame.
function Get-DashboardCells($Status, $Policy, [int]$Columns, [int]$Rows, [int]$Offset, [bool]$Nyan, [bool]$TerminalAnsi) {
    if ([IO.Directory]::Exists($staging)) { [IO.Directory]::Delete($staging, $true) }
    [void][IO.Directory]::CreateDirectory($staging)
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText((Join-Path $staging 'policy.json'), ($Policy | ConvertTo-Json -Depth 16 -Compress), $utf8)
    if ($null -ne $Status) { [IO.File]::WriteAllText((Join-Path $staging 'status.json'), ($Status | ConvertTo-Json -Depth 16 -Compress), $utf8) }
    $view = if ($Nyan) { 'nyan' } else { 'watch' }
    $asked = @($view, '--root', $root, '--state', $staging, '--now', $fixture.now.ToString('o'), '--zone', '0',
        '--size', ('' + $Columns + 'x' + $Rows), '--offset', [string]$Offset, '--ansi')
    # A terminal image shows the first moment of a dashboard in motion; the others one at rest.
    $asked += if ($TerminalAnsi) { @('--colours', 'indexed', '--at', '0') } else { @('--colours', 'true', '--reduced-motion') }
    $drawn = Invoke-Hotpl8NativeProcess $reader $asked
    if ($drawn.exitCode -ne 0) { throw ('The reader drew no frame: ' + $drawn.errors.Trim()) }
    $lines = $drawn.output.Split("`n")
    # The frame ends with the offset it settled on and a line end.
    if ($lines.Count -lt 3 -or $lines[$lines.Count - 1] -ne '' -or $lines[$lines.Count - 2] -notmatch '^offset \d+$') { throw 'The reader''s answer is not a frame.' }
    foreach ($line in $lines[0..($lines.Count - 3)]) { , @(ConvertFrom-Hotpl8TestAnsiRow $line) }
}

function Write-DashboardImage([string]$Name, $Status, $Policy, [int]$Columns, [int]$Rows, [int]$Offset=0,[switch]$Nyan,[switch]$TerminalAnsi) {
    $frame = @(Get-DashboardCells $Status $Policy $Columns $Rows $Offset ([bool]$Nyan) ([bool]$TerminalAnsi))
    $font = New-Object Drawing.Font('Consolas', 18, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
    if ($font.Name -ne 'Consolas') { $font.Dispose(); throw 'Install Consolas to reproduce documentation images.' }
    $cellWidth = 11; $lineHeight = 24; $padding = 28; $titleHeight = 44
    $bitmap = New-Object Drawing.Bitmap(($Columns * $cellWidth + 2 * $padding), ($frame.Count * $lineHeight + 2 * $padding + $titleHeight))
    $bitmap.SetResolution(96, 96)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $brushes = @{}
    function Get-Brush([string]$Colour) {
        if (-not $brushes.ContainsKey($Colour)) { $rgb = $Colour.Split(';'); $brushes[$Colour] = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb([int]$rgb[0], [int]$rgb[1], [int]$rgb[2])) }
        $brushes[$Colour]
    }
    $format = [Drawing.StringFormat]::GenericTypographic.Clone()
    $format.FormatFlags = $format.FormatFlags -bor [Drawing.StringFormatFlags]::MeasureTrailingSpaces
    try {
        # Every row opens on the dashboard's own background, which the margin continues.
        $background = $frame[0][0].background
        $rgb = $background.Split(';')
        $graphics.Clear([Drawing.Color]::FromArgb([int]$rgb[0], [int]$rgb[1], [int]$rgb[2]))
        $graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $caption = if ($TerminalAnsi) { 'HotPl8 / fictional accounts / Apple Terminal 256 colors' } else { 'HotPl8  /  fictional accounts' }
        $graphics.DrawString($caption, $font, (Get-Brush '143;156;181'), [single]$padding, [single]$padding, $format)
        for ($row = 0; $row -lt $frame.Count; $row++) {
            # Position glyphs on the terminal cell grid. The fixtures hold none wider than a cell.
            $column = 0
            foreach ($span in $frame[$row]) {
                $elements = [Globalization.StringInfo]::GetTextElementEnumerator($span.text)
                while ($elements.MoveNext()) {
                    $glyph = [string]$elements.Current
                    $left = [single]($padding + $column * $cellWidth); $top = [single]($padding + $titleHeight + $row * $lineHeight)
                    if ($TerminalAnsi -or $span.background -ne $background) { $graphics.FillRectangle((Get-Brush $span.background), $left, $top, [single]$cellWidth, [single]$lineHeight) }
                    # Block pixels occupy terminal cells, not a font's padded glyph box.
                    if ($glyph -in @('▀', '▄', '█')) {
                        $dy = if ($glyph -eq '▄') { $lineHeight / 2 } else { 0 }
                        $height = if ($glyph -eq '█') { $lineHeight } else { $lineHeight / 2 }
                        $graphics.FillRectangle((Get-Brush $span.foreground), $left, ($top + $dy), [single]$cellWidth, [single]$height)
                    } elseif ($glyph -ne ' ') { $graphics.DrawString($glyph, $font, (Get-Brush $span.foreground), $left, $top, $format) }
                    $column++
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

try {
Write-DashboardImage 'dashboard.png' $fixture.status $fixture.policy 94 25
Write-DashboardImage 'details.png' $fixture.status $fixture.policy 94 34 999
$emptyPolicy = @{ mode = 'monitor'; prefer = @(); codex = @{ slots = @() } } | ConvertTo-Json -Depth 4 | ConvertFrom-Json
Write-DashboardImage 'first-run.png' $null $emptyPolicy 80 24
$operations=Get-Hotpl8ScreenshotFixture -Operations
Write-DashboardImage 'operations.png' $operations.status $operations.policy 110 50

Write-DashboardImage 'nyan.png' $fixture.status $fixture.policy 94 40 -Nyan

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
Write-DashboardImage 'nyan.png' $healthy.status $healthy.policy 94 40 -Nyan
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

# Plenty of weekly inventory, but none is usable before a short-window reset.
$available=Get-Hotpl8ScreenshotFixture
$available.policy.mode='automate';$available.policy.reserve=@()
$available.policy.PSObject.Properties.Remove('capacity')
foreach($slot in $available.status.slots){
    $slot|Add-Member NoteProperty plan @{status='detected';profile='claude-pro';label='Pro';observedAt=$available.now.ToString('o')} -Force
    $slot.used5h=100;$slot.used7d=10;$slot.reset5h=$available.now.AddHours(5).ToString('o')
}
Write-DashboardImage 'available-now.png' $available.status $available.policy 94 25

# Three equal session allowances; weekly percentages must not lower this bar.
$session=Get-Hotpl8ScreenshotFixture
$session.policy.mode='automate';$session.policy.reserve=@();$session.policy.prefer=@(1,2,3)
$session.policy.PSObject.Properties.Remove('capacity')
$third=$session.status.slots[0]|ConvertTo-Json -Depth 12|ConvertFrom-Json
$third.slot=3;$third.label='Weekend';$third.active=$false
$session.status.slots+=@($third)
foreach($slot in $session.status.slots){
    $slot|Add-Member NoteProperty plan @{status='detected';profile='claude-pro';label='Pro';observedAt=$session.now.ToString('o')} -Force
    $slot.used5h=0;$slot.used7d=20
}
$session.status.slots[1].label='Second';$session.status.slots[1].used5h=25
$session.status.slots[1].reset5h=$session.now.AddMinutes(42).ToString('o')
foreach($slot in $session.status.providers.codex.slots){$slot.buckets.codex.windows.PSObject.Properties.Remove('300');$session.policy.codex.capacity.($slot.id).weekly=1}
$session.status.providers.codex.slots[0].buckets.codex.windows.'10080'.usedPercent=5
$session.status.providers.codex.slots[0].buckets.codex.windows.'10080'.remainingPercent=95
$session.status.providers.codex.slots[1].buckets.codex.status='blocked'
$session.status.providers.codex.slots[1].buckets.codex.windows.'10080'.usedPercent=100
$session.status.providers.codex.slots[1].buckets.codex.windows.'10080'.remainingPercent=0
Write-DashboardImage 'session-capacity.png' $session.status $session.policy 94 42

Write-DashboardImage 'nyan-compact.png' $healthy.status $healthy.policy 48 24 -Nyan

# The colours Apple Terminal is sent, with a deterministic live frame.
Write-DashboardImage 'nyan-apple-terminal.png' $healthy.status $healthy.policy 113 33 -Nyan -TerminalAnsi
Write-DashboardImage 'nyan-apple-terminal-large.png' $healthy.status $healthy.policy 109 40 -Nyan -TerminalAnsi
} finally {
    if ([IO.Directory]::Exists($staging)) { [IO.Directory]::Delete($staging, $true) }
}
