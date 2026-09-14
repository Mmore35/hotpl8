# Configuration

Copy the tracked example only for a new installation. The [schema](../policy.schema.json) documents versions 1 and 2. Runtime validation also applies to legacy policy fields before Claude actions.

| Fields | Meaning/default |
|---|---|
| `schemaVersion`, `mode` | 2 for new installations; version 1 remains supported. Monitor by default. automate permits only separately enabled actions. |
| `prefer`, `labels` | Selected Claude numeric slots in preference order; empty until explicitly enrolled. |
| `reserve` | Subset of preferred slots kept behind ordinary work slots. |
| `switchEnabled`, `warm`, `probeEnabled` | Independently control switching and inference-based warming/recovery; false by default. |
| `order`, `resetLeadMin` | prefer, soonest-reset, or version-2 weekly-expiry/balanced; 10-minute lead avoids unnecessary switches. |
| `margin5h`, `margin7d`, `margin7dWork`, `hysteresis` | Remaining-percentage floors: 25, 20, 5, and 10. |
| `maxUsageAgeS`, `staleQuarantineS` | Freshness ceiling 900 seconds; stale recovery threshold 21600 seconds. |
| `warmMin7d`, `warmMin7dWork` | Remaining weekly floors for warming: 20/5. |
| `warmFloorMin`, `warmPhaseWindowMin` | Minimum repeat interval 20 minutes; phase tolerance 15 minutes. |
| `pattern`, `weights`, `warmGroup` | maintain (default), even, synced, or clustered; optional positive weights/group size. |
| `codex.slots` | Explicit id, absolute native home, optional label. Never token contents. |
| `codex.prefer`, `codex.reserve`, `codex.order` | Codex recommendation preferences; independent of Claude. |
| `codex.defaultMeter`, `codex.modelMeters` | Default codex bucket and explicitly verified model-to-meter mappings. |
| `codex.margin5h`, `codex.margin7d`, `codex.margin7dWork` | Codex remaining-percentage eligibility floors. |

Examples in [examples/](../examples/README.md) show provider combinations using fictional slots. Replace all account homes locally. Empty provider sections are disabled. Invalid/unknown quotas cannot authorize automatic use. Explicit version-2 `claudeModels` constrain selection using reported scoped windows; automatic actions remain experimental.

Existing policies without schemaVersion preserve their legacy switching and probing defaults. Migrate deliberately by adding schemaVersion 2, mode automate, and explicit action booleans matching your intended behavior, or choose monitor to disable all actions. New installers never replace an existing policy.

See [account operations](operations.md) for version-2 schedules, persistent pause, attempt budgets, disabled accounts, scoped eligibility, history, notifications and selection replay. Account commands preserve action choices during migration and save a policy backup.

Capacity profiles, critical-mode thresholds and display motion/color preferences are additive version-2 settings. See [capacity configuration](capacity.md) for units, examples and fallback behavior. Existing selection `weights` continue to control warming distribution; they are not capacity estimates.
