# macOS implementation handoff

Owner-approved handoff, 2026-09-12. Continue from the public `Mmore35/hotpl8` repository, branch `improve-subscription-operations` (or main after its PR merges). Work from this public history only. The Windows development install and any private predecessor are not migration sources. This file is the task contract; no previous chat is required.

## Outcome

A newcomer on a supported Mac can install, enroll native accounts, observe quotas, launch Codex in the correct home, run qualified Claude automation, pause it, use local forecasts and explanations, update/roll back, and uninstall without harming native accounts. Ship precise capability claims for what passes. Codex warming is conditional, not a prerequisite for honest Mac observation/launch support.

The shared implementation already includes warm receipts, action controls, forecasts/history, scoped Claude eligibility, account management, selection replay, collector health, and a Windows tray/updater. Read [operations](../operations.md), [architecture](../architecture.md), [compatibility](../compatibility.md), [Codex warming investigation](codex-warming.md) and [delivery status](subscription-roadmap.md) first. New policies use schema version 2; snapshots remain version 2 with additive optional fields.

## 1. Establish the native baseline

- Record macOS, CPU architecture, terminal, PowerShell, native Codex and cswap versions, plus public commit tested. Do not commit account labels, homes, raw RPC output or credentials.
- Install PowerShell 7 using its official distribution. Read the current native provider contracts before modifying adapters. Use independently signed-in native homes; never copy authentication from Windows.
- Run `pwsh -NoProfile -File scripts/check.ps1`. Run the pure operations suite after adapting its Windows-only archive/CLI cases. Do not mistake a Windows-only full-suite refusal for a Mac product failure or delete those tests to make a badge green.
- Add native executable fixtures for PowerShell 7/.NET, replacing assumptions about .NET Framework compilation and `.cmd` launch in `tests/fake-codex.cs` and test helpers. Keep Windows PowerShell 5.1 coverage.

## 2. Platform seams and owned lifecycle

- Inspect `src/common.ps1` process construction, executable resolution, account lock identity and bounded process-tree cleanup. Verify native app-server stdout framing, Unicode paths, quotes, spaces and non-ASCII labels on ARM64. Test symlinks and case-sensitive home paths; the current Windows case folding must not conflate distinct Mac homes.
- Add a Mac launcher and owned per-user install/state directories. Reuse `release-files.json`, atomic writes, checksum validation, staged replacement and previous-version retention. Reject links/traversal and unrelated files before deletion. Keep policy/state separate from application files.
- Implement launchd scheduling as a lifecycle adapter, with exactly one user-owned job and the same `tick -Scheduled` entrypoint. Define and test missed-interval/sleep/wake behavior; never catch up by firing multiple prompts. Surface registration/running/last-completion evidence in capabilities and collector health.
- Implement uninstall and rollback for the Mac installation. Preserve native authentication, histories and unrelated hooks. Validate the previous reader against the current policy before rollback, just as Windows does.

## 3. Native provider qualification

- Codex: verify account/read, config/read and rate-limit shapes through native app-server; preserve strict model-to-meter mapping and per-home locking. Two homes for one subscription must not count as two accounts. Confirm automatic and explicit launch, resume ownership, custom transport rejection, unavailable login, 429, timeout and concurrent interactive use. Changing a login in an enrolled home must invalidate old anchors and dispatch binding.
- Claude: verify the installed cswap JSON contract, native account selection, scoped window names, quota age and cold-window representation. Inspect `Invoke-SlotPing` and legacy credential cleanup carefully: Windows filesystem behavior is not evidence for macOS Keychain/session behavior. Resolve or explicitly retain the documented integration boundary before calling automation stable.
- Test warm outcomes with a real opted-in test account: before observation, one bounded native request, later observations. A successful process alone must remain `sent`/`unconfirmed`. Verify no extra prompt during delayed verification and no duplicate after restart. Include recovery probes, disabled slots, work hours, overnight/DST boundaries, budgets, pause/resume and existing hold leases.
- Weekly-only Codex accounts remain warming-not-applicable. Unconfirmed five-hour anchors do not authorize a warm implementation. Follow the separate warming investigation gate if suitable native evidence becomes available.

## 4. Desktop and distribution

- Keep the terminal dashboard available without desktop dependencies. Verify resize, narrow/compact views, stale warnings, scoped usage, receipts and forecasts. Preserve the deterministic screenshot harness; add a Mac renderer/font baseline only if useful.
- Choose a lightweight native menu-bar host over the cached status/command contract. Reuse notification candidate/dedup semantics; it must not own a second collector or credentials. Verify notification permissions, quiet hours, reset drift, restart dedup, pause/resume and opening the dashboard. Measure startup, idle CPU and memory before enabling startup by default.
- Build an explicit macOS artifact (universal script package or separately qualified architecture packages). Add a Mac job to CI and the attested release workflow. Extend updater platform selection and verification to that exact artifact and signer workflow; do not download or run a Windows ZIP. Consider Homebrew only after a stable artifact layout exists.

## Acceptance and return handoff

Record pass/fail, exact versions and sanitized evidence for each row; do not mark a row passed based solely on fixtures.

| Area | Required evidence |
|---|---|
| Fresh install | Clean user/environment; one real reading following only public docs; no manual policy edit needed. |
| Multiple accounts | Independent subscriptions; duplicate detection; correct model/meter and resume ownership. |
| Automation | One owner; warm receipts; switch/probe guards; monitor sends no prompts; persistent pause and budget. |
| Recovery | Sleep/wake, network loss, stale data, native login change, process hang, restart during a request. |
| Lifecycle | Repeat install, interrupted update, bad provenance, held lock, incompatible policy rollback, uninstall preservation. |
| Views | Two views cause no extra polls; stale state stays visible; notifications deduplicate. |
| Engineering | Windows suite still passes; Mac suite and CI pass; reproducible package includes every dependency; secret scan passes. |

Commit the Mac implementation, tests and qualification record together in reviewable increments, push the public branch, and open a PR. Update compatibility, install/usage/upgrading docs, policy schema, release manifest and feature-status plan as applicable. Keep unsupported cells explicit. Leave the owner a short report of what works, any real account/provider boundary requiring a decision, and links to the PR and tested artifact. Do not publish a stable support claim until its rows pass.
