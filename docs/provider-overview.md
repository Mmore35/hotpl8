# Provider overview

The pinned overview shows a layered capacity bar for Claude and another for Codex. Each combines a full weekly-capacity track, solid usable-now allowance and a patterned next-reset projection. The countdown is on the right. Scroll below for per-account readings, resets and warming outcomes.

**Available now** uses configured relative allowances and current limits. It remains an estimate, not a guaranteed token count. When the conversions between weekly and short limits are missing, **Weekly remaining** shows the average weekly percentage per account instead. This fallback counts each account equally, regardless of tier; its countdown and patterned refill refer only to the next weekly reset. Short limits still determine the separate ready-account count.

The pattern always touches the solid fill and means additional allowance at the indicated reset. Missing readings are reported as `Partial: 2/3 readings; total unavailable`, never as a patterned region. Partial fill includes only the measured share of the full account set; it is not the total remaining balance. No refill amount is projected from incomplete evidence. A plain `reset in` countdown without a percentage means the refill amount is unknown. Projections assume no further consumption; passing a reset time does not refill the solid bar without a fresh observation. [How to configure capacity, critical mode and motion](capacity.md).

The dashboard, CLI, JSON and tray share the same pure computation using current policy and cached evidence. The compatibility normalized-weekly-headroom fields are retained separately from the new capacity metric. Codex's unconfirmed reset anchors restrict projections, not otherwise valid current quota percentages. Automatic Codex warming remains unavailable; weekly-only accounts report warming as not applicable.

![Account details below the overview](assets/details.png)
