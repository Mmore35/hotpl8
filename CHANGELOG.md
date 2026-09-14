# Changelog

## Unreleased

- Keep the main bars on usable-now capacity, using an explicit plan-weighted quota-headroom estimate when conversions are unavailable. Weekly remaining is supporting text. Forecast only the first positive refill within 24 hours and exclude Spark from Codex summaries, dashboard and tray.

- Observe Claude's adapter every scheduler minute so its native poll cadence does not compound with a second cache delay. Preserve freshness and backoff limits. Simplify overview labels, reserve hatching for attached refill projections, align weekly fallback projections with weekly resets, and remove the disappearing cat tail.

- Detect Claude subscription plans automatically using identity-verified profile metadata, with bounded retries, private caching and explicit handling of unknown tiers. Surface detected plans in dashboard/JSON/text/tray and prefer configured capacity overrides.

- Unified Claude and Codex weekly-headroom overview with pinned summaries and scrollable account details. Shared CLI/tray summaries show partial coverage, reserves, readiness and automation state without treating percentages as absolute capacity.

## 0.2.0-rc.1 ? source candidate

- Add observed warming receipts, explanations/activity, collector health/backoff, weekly estimates and optional local history.
- Add scoped Claude eligibility, persistent pause/work hours/budgets, guided native enrollment and account controls.
- Add experimental weekly-expiry/balanced ordering with production-selector shadow/replay comparison.
- Add channel-aware verified update tooling, compatible rollback checks and an attested release build workflow.
- Add an optional Windows tray with opt-in transition notifications.
- Save complete Mac implementation and conditional Codex warming handoffs; neither gains an unsupported compatibility claim.


## Unreleased

- Lead the README with account selection, optional Claude warming, and a real dashboard rendering with fictional data.
- Add a repeatable screenshot harness and selection/warming diagrams linked to implementation and tests.
- Add `hotpl8 enroll`, actionable offline doctor guidance, and setup/refresh hints in the cached dashboard.
- Group internal runtime code under src/ and all regression suites under tests/ while preserving public entrypoint paths.

## 0.1.0-rc.1 — 2026-09-12

- Remove the dashboard tagline.
- Add monitoring-only defaults, independently controlled Claude actions, and observation-only refresh.
- Preserve automation behavior for existing unversioned policy files.
- Add policy validation, shared state resolution, redacted doctor output, version/help, and local JSON status.
- Bound Claude child-process time and output; reject malformed/disabled account readings.
- Add per-user installation, optional scheduled collection, updates, rollback, and uninstall.
- Package explicit files with checksums; add offline CI and publication checks.
- Replace private research/diagnostics with public documentation and prepare a clean public initial history.
- Correct UTF-8 quota-pipe input and preserve Unicode account paths independently of console encoding.

This is an early Windows preview, not a stable-support designation. Live provider/concurrency qualification remains open. See [compatibility](docs/compatibility.md) and the [release checklist](docs/release-checklist.md).

## Unreleased — capacity preview

- Recover Codex collection after sparse failure snapshots without extending retry deadlines on skipped wakes.
- Add weighted current/next-reset capacity estimates, configurable capacity profiles, independent provider/health colors and reduced motion.
- Add opt-in critical-budget selection with persisted hysteresis, dwell, emergency floors and faster healthy polling.
- Animate the header cat and add `hotpl8 nyan` using credited terminal-project frames.
