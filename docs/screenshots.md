# Updating the screenshots

`operations.png` uses the optional operations fixture: collector health, weekly pace, an unconfirmed warm receipt and work-hour blocking. Like the primary dashboard image, it is rendered from fictional data through the production frame renderer.

From the repository root, on Windows with Windows PowerShell 5.1 and Consolas:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\screenshots.ps1
```

Commit the regenerated PNGs in [assets](assets/dashboard.png) with the UI change. Open all images before committing; inspect legibility, clipping, colors, and the first-run instructions. No screenshot tool or provider installation is required.

The harness calls the production [dashboard renderer](../src/dashboard.ps1) and its shared palette. It draws those terminal cells into PNGs with a small caption using Windows System.Drawing. It is a reproducible rendering of the actual UI, not a capture of a live account session. The caption identifies the data as fictional.

The [fixture](../tests/fixtures/screenshots.ps1) fixes account labels, percentages and the clock. The harness fixes viewport, font, DPI and cell size. Identical inputs on the same Windows/font environment produce identical bytes; other font/OS revisions may rasterize differently. Use `-OutputDirectory PATH` to compare a second render without replacing the committed images.

Change the renderer for a UI change, or the fixture for a different documentation scenario. Keep fixtures fictional and independent of the machine. Never load policy.json, status.json, account homes, environment secrets, or native provider output into this harness. This is a development tool, not an application demo command.

`dashboard.png` fixes the opening view at 94 columns by 25 rows. `details.png` renders the last details page at 94 by 34 with the same pinned provider overview. `operations.png` exercises operational detail at 110 by 50. All use the same fixed clock and renderer.

Capacity fixtures declare fictional per-window weights. `nyan.png` uses the bundled attributed animation with a frozen frame; critical/unknown frames should be added or regenerated alongside main/detail screenshots. Both screenshot and terminal paths consume the same sanitized styled spans and palette.
