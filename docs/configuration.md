# Configuration

Copy the tracked example only for a new installation. The [schema](../policy.schema.json) documents version 1. Runtime validation also applies to legacy policy fields before Claude actions.

| Fields | Meaning/default |
|---|---|
| `schemaVersion`, `mode` | 1; monitor by default. automate permits only separately enabled actions. |
| `prefer`, `labels` | Selected Claude numeric slots in preference order; empty until explicitly enrolled. |
| `reserve` | Subset of preferred slots kept behind ordinary work slots. |
| `switchEnabled`, `warm`, `probeEnabled` | Independently control switching and inference-based warming/recovery; false by default. |
| `order`, `resetLeadMin` | prefer or soonest-reset; 10-minute lead avoids unnecessary switches. |
| `margin5h`, `margin7d`, `margin7dWork`, `hysteresis` | Remaining-percentage floors: 25, 20, 5, and 10. |
| `maxUsageAgeS`, `staleQuarantineS` | Freshness ceiling 900 seconds; stale recovery threshold 21600 seconds. |
| `warmMin7d`, `warmMin7dWork` | Remaining weekly floors for warming: 20/5. |
| `warmFloorMin`, `warmPhaseWindowMin` | Minimum repeat interval 20 minutes; phase tolerance 15 minutes. |
| `pattern`, `weights`, `warmGroup` | maintain (default), even, synced, or clustered; optional positive weights/group size. |
| `codex.slots` | Explicit id, absolute native home, optional label. Never token contents. |
| `codex.prefer`, `codex.reserve`, `codex.order` | Codex recommendation preferences; independent of Claude. |
| `codex.defaultMeter`, `codex.modelMeters` | Default codex bucket and explicitly verified model-to-meter mappings. |
| `codex.margin5h`, `codex.margin7d`, `codex.margin7dWork` | Codex remaining-percentage eligibility floors. |

Examples in [examples/](../examples/README.md) show provider combinations using fictional slots. Replace all account homes locally. Empty provider sections are disabled. Invalid/unknown quotas cannot authorize automatic use. Model-specific Claude windows are surfaced but not ranked; automatic actions remain experimental.

Existing policies without schemaVersion preserve their legacy switching and probing defaults. Migrate deliberately by adding schemaVersion 1, mode automate, and explicit action booleans matching your intended behavior, or choose monitor to disable all actions. New installers never replace an existing policy.
