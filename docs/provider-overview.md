# Provider overview

The pinned overview shows a layered capacity bar for Claude and another for Codex. Each combines a full weekly-capacity track, solid usable-now allowance and a patterned next-reset projection. The countdown is on the right. Scroll below for per-account readings, resets and warming outcomes.

Capacity is a weighted estimate in common units, not an equal-account average or a guaranteed token budget. Missing capacity profiles/conversions and unavailable readings remain visible. A next-reset projection assumes no further consumption; passing a reset time does not refill the solid bar without a fresh observation. [How to configure capacity, critical mode and motion](capacity.md).

The dashboard, CLI, JSON and tray share the same pure computation using current policy and cached evidence. The compatibility normalized-weekly-headroom fields are retained separately from the new capacity metric. Codex's unconfirmed reset anchors restrict projections, not otherwise valid current quota percentages. Automatic Codex warming remains unavailable; weekly-only accounts report warming as not applicable.

![Account details below the overview](assets/details.png)
