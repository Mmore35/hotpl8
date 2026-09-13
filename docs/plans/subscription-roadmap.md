# Subscription operations delivery status

Approved scope: all twelve roadmap items, with native Mac implementation explicitly handed off to a Mac. Candidate source: 0.2.0-rc.1. This checklist distinguishes implemented code from native qualification; a green offline suite does not prove provider behavior or desktop delivery.

| Item | Implementation | Qualification / remaining work |
|---|---|---|
| 1. Verified warming outcomes | Persistent pre-dispatch receipts, later observation reconciliation, crash/restart suppression, dashboard/CLI states. | Claude remains experimental; confirm native window behavior before promoting it. |
| 2. Explain and activity | Recorded reasons from production decisions, bounded local events, stale warning, CLI/dashboard/tray consumers. | No claim of causal quota savings. |
| 3. Collector health and coordination | Persisted starts/completions/due times, shared lock, failure backoff, independent provider results, live health overlay. | Native sleep/wake and long-running qualification remain release checks. |
| 4. macOS | Complete [Mac implementation handoff](macos-handoff.md). | Implement and qualify on the owner's Mac; Windows is the supported preview runtime. |
| 5. Pace and history | Shared cycle-average forecast, optional recent history, bounded retention, clear command, private stream pseudonyms. | Estimates remain labeled; no historical burn-rate promise. |
| 6. Model eligibility | Explicit Claude scoped constraints; Codex model-meter validation; disabled slots block selection and launch. | Confirm each native plan's exact scope/meter mapping. |
| 7. Controls | Work hours, overnight/time-zone logic, persistent pause, prompt exclusions, daily attempt budgets. | Mac time-zone IDs and daylight-saving/sleep qualification are in the handoff. |
| 8. Setup/account operations | Guided/native enrollment, duplicate subscription checks, rename/disable/reserve controls, atomic validated saves and offline capabilities. | Newcomer walkthrough on a clean native installation remains a release check. |
| 9. Selection | Opt-in weekly-expiry and balanced ordering, shared selectors, per-tick shadow decisions and read-only trace replay. | Keep default unchanged; prospective trials are needed before claiming improvement. |
| 10. Codex warming | Native option investigation and [explicit result/continuation gate](codex-warming.md). | Unavailable: no qualified isolation/window-benefit evidence. No warm button or inferred success ships. |
| 11. Updates | Explicit channel-aware check/dismiss, owned-install updater, exact source/tag/provenance checks, staged installer and compatible rollback; attested build workflow. | First attested artifact must be built from merged main and published before this updater can install it. Old unsigned previews are deliberately rejected. |
| 12. Tray/notifications | Optional Windows Forms cache consumer, deliberate dashboard/pause commands, opt-in quiet-hour notifications and restart dedup. | Interactive desktop behavior and idle-resource measurements remain native release checks; Mac shell is handed off. |

See [operations](../operations.md) for commands, configuration and state semantics, and [release checklist](../release-checklist.md) for promotion requirements. No competitor implementation was copied. Tests cover fictional account/process behavior; private accounts, credentials and usage traces are excluded from the package.

The public Mac handoff can proceed from this branch or merged main without the development conversation. Complete each remaining native evidence cell before advertising it as verified support.
