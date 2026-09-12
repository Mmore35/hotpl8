# Updating the screenshots

From the repository root, on Windows with Windows PowerShell 5.1 and Consolas:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\screenshots.ps1
```

Commit the regenerated PNGs in [assets](assets/dashboard.png) with the UI change. Open both images before committing; inspect legibility, clipping, colors, and the first-run instructions. No screenshot tool or provider installation is required.

The harness calls the production [dashboard renderer](../src/dashboard.ps1) and its shared palette. It draws those terminal cells into PNGs with a small caption using Windows System.Drawing. It is a reproducible rendering of the actual UI, not a capture of a live account session. The caption identifies the data as fictional.

The [fixture](../tests/fixtures/screenshots.ps1) fixes account labels, percentages and the clock. The harness fixes viewport, font, DPI and cell size. Identical inputs on the same Windows/font environment produce identical bytes; other font/OS revisions may rasterize differently. Use `-OutputDirectory PATH` to compare a second render without replacing the committed images.

Change the renderer for a UI change, or the fixture for a different documentation scenario. Keep fixtures fictional and independent of the machine. Never load policy.json, status.json, account homes, environment secrets, or native provider output into this harness. This is a development tool, not an application demo command.
