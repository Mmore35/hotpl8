# Changelog

## Unreleased — shared provider core

- Report a Claude warm ping that worked but left the account's stored sign-in unrenewed. Such a sign-in can stop working hours later with nothing on record to connect the two; the status line and the activity list now say so when it happens, and the credential audit line gains the profile copy's generation (`prof-after`).
- Check a Claude sign-in that the account manager has given up on twice per stored token, instead of every six hours for as long as it stays. After the second failed check the account reads `NEEDS RE-LOGIN` rather than `QUARANTINE STALE`, and is checked again only when a new sign-in is stored.
- Allow `cswap list --json` 90 s instead of 20 s. The read renews expired sign-ins, and stopping it before the account manager's own reply waits ended could discard a renewal that had already been issued.

- Add automatic continue. When a hosted conversation's turn dies on a usage limit, HotPl8 sends that conversation one `Automated message: continue.` as soon as a usable account is in place: a different account, or the same one read again after the limit. It is a new turn; nothing is replayed. Claude and the T3 Codex bridge share one waiter, `continue.ps1`. Interactive terminal Claude and plain `hotpl8 codex` are not covered. [Behavior, limits and evidence](docs/plans/automatic-continue.md).
- **After this update, an installation that is not in monitor mode gets automatic continue without a policy change.** On its next collector run HotPl8 adds one entry to the `StopFailure` hooks in Claude's user settings by itself. To turn it off and remove the entry: `hotpl8 continue -Operation disable`. With T3 Code 0.0.46 or later, turn off T3's own resume of limited conversations.
- New installations start with automatic account switching and automatic continue on. Warming stays off; interactive setup asks whether to turn it on. Existing policies are not changed.
- Add `hotpl8 continue` to show, enable or disable automatic continue, and one doctor line for its state.
- Ship a compiled reader with each release and have it alone answer `hotpl8 version`, `hotpl8 status` and `hotpl8 explain`. PowerShell keeps no second implementation of the three and nothing switches back to one: `HOTPL8_NATIVE` is no longer read. A copy whose reader cannot start says so and ends with status 1, and the installers and main delivery refuse such a copy before it is put in place. Building from source now needs Rust. [Contract and evidence](docs/plans/rust-read-side.md).
- The three commands print the same lines as before for the state HotPl8 writes. `-AsJson` carries the same values in a different layout: two-space indentation and every non-ASCII character escaped. Output no longer follows the regional formats of the PowerShell that started the command, and numbers are calculated as the platform's own PowerShell calculates them (Windows PowerShell 5.1 on Windows, PowerShell 7 elsewhere) whichever one starts it. A state file that is not JSON as HotPl8 writes it is refused with a message that names the file and the place. [Every difference](docs/plans/rust-read-side.md#differences-from-the-powershell-commands).
- On Windows, `hotpl8` asks the reader before it starts PowerShell. On the measuring machine `hotpl8 status` went from 2.15 s to 0.22 s through an ordinary installation and from 2.51 s to 0.27 s through a main delivery installation; `explain` and `version` are answered in the same 0.2 to 0.3 s. Every other command starts PowerShell as before, about 0.1 s later. The launcher files of an installation change with this release: [what changes, and what a running dashboard sees](docs/install.md#the-launcher). On a Mac the launcher still starts PowerShell first.
- Run every collection in the compiled program. `tick.ps1`, `hotpl8 tick` and `hotpl8 refresh` start it and keep their parameters, so installations and scheduled tasks need no change. PowerShell is started only when a wake changes Claude's continue hook or closes an account addition. On the measuring machine a wake that reads Claude accounts and changes nothing went from 4.0 s to 0.6 s, and to about 1 s when it is started through `tick.ps1`.
- On Windows, a main delivery installation's scheduled task starts the collector without PowerShell after its next activation; it started PowerShell twice per minute before.
- Read Codex accounts inside the collector, with the same four requests to the Codex program, the same 12 s per read and the same failure names. On the measuring machine a wake that reads two Codex homes went from 2.2 to 2.7 s down to 0.8 to 0.9 s. `codex-state.json` holds the same data in a two-space layout. [Every difference](docs/plans/rust-read-side.md#differences-from-the-powershell-codex-collection).
- Have the tray ask the compiled program what to show. One refresh, every five seconds while the tray is open, went from 0.83 s and about a second of processor time to 0.12 s. `hotpl8 tray -Once` prints one member more, `notify`. The tray shows Claude's decision line, checks the policy at every refresh, and shows `HotPl8 - view unavailable` for state the reader refuses. [Every difference](docs/plans/rust-read-side.md#differences-from-the-powershell-tray).
- Start the scheduled collector without PowerShell in more places: an ordinary Windows installation once the release it keeps for rollback has a compiled collector too (0.5 s to 0.16 s for a wake with nothing due), a Mac main delivery installation, and an ordinary Mac whose collector job is newly written. An existing ordinary Mac job is kept as it is. [Scheduled starts](docs/plans/rust-read-side.md#contract-scheduled-starts).
- `hotpl8 explain` and the tray no longer print an empty Codex account, decision or reserve line, or announce `codex//no-eligible`, on an installation with no Codex account.
- A `hold.json` that is a list of objects is no hold, and a manual pause whose `until` is a date with no time is a pause that cannot be read, which blocks every action.
- An account with no warm request no longer shows an empty `warm:` note on Windows.
- The collector looks for cswap on `PATH` only as a program (`.com`, `.exe`, `.bat`, `.cmd`), and treats a state file that is not strict JSON as unreadable.
- Let a live PR preview run the reader that CI built for the pinned revision, so a compiled dashboard can be previewed before it is merged. The package is taken from the same passing run the preview already requires and is checked before anything runs.

- Remove Codex model registration from T3 routing, helper setup, CLI launches and cached readiness. Account selection uses the configured quota basis; native model/options pass through unchanged, including omitted defaults. Legacy model maps remain readable but are ignored. Active-work ownership and quota/account controls are preserved.

- Add `hotpl8 park` and `hotpl8 unpark`. Park finds accounts whose plan ended or whose sign-in has failed for a week, asks once, and removes them from collection, totals, selection and the warming schedule while keeping their settings; unpark or a new sign-in restores them. Doctor and the dashboard name these accounts instead of pointing at each other.
- Show Codex plan names as reported (for example `prolite`) instead of `unknown`, and record each account's plan change.
- Do less work on each collector run and each `hotpl8 codex` launch: compute the provider overview once per run instead of once more for every provider, hash the control files without loading the file-hash cmdlets into every process, and skip the dashboard summaries before a native launch, which never reads them. Published status, decisions and messages are unchanged. A control file marked hidden is now read like any other; it previously stopped the action with an error.

- Fix unreadable magenta backgrounds in Apple Terminal by rendering the dashboard and Nyan animation with its fixed 256-color palette. Apple Terminal uses solid background-cell Nyan pixels to avoid font gaps; Windows retains its RGB half-block renderer and sizing.
- Add an explicitly trusted, commit-pinned live PR dashboard preview with fictional accounts, exact-head CI checks and disposable state. Image previews remain available.

- Keep a Codex account in service through one busy or slow read. The collector now waits for another reader's lock within its read budget instead of reporting the home busy at once, T3 routing reconsiders a fresh account after a timed-out collector read (fresh native validation still decides), and the dashboard shows READ RETRYING without the unavailable warning until the last success ages out.
- Allow a native Codex quota read 12 s instead of 5 s. On a CPU-saturated machine app-server startup alone passed 5 s, so every account read as unavailable and launches stopped while cached quotas were minutes old.
- Use one normalized selection core for Claude, Codex launches and T3 routing, including reserves, degraded accounts, critical state, holds and pause controls. Better health/work tiers bypass ordinary churn protection consistently.
- Distinguish explicit admission, autonomous rollover and pinned refresh. Validate current controls at the action boundary and record Codex binding/dwell only after native acknowledgement; never replay turns or tools after ambiguous login failure.
- Discover providers through validated shipped-driver definitions across enrollment, collection and cached consumers. Add explicit schema-v3 migration while preserving legacy policy behavior and rejecting incompatible rollback readers before activation.
- Add gradual T3 transition: manage ordinary Codex alongside the functional legacy alias, with settings locks, recovery journals and separate removal receipts. Existing conversation data is unchanged.
- Qualify the real policy/broker/bridge/native rollover chain with synthetic HTTP and WebSocket accounts on Codex CLI 0.155.1. Real billing and long-running refresh qualification remain separate.

## Unreleased — local agent interface

- Add a versioned JSON agent command and local MCP read tools with explicit cached readiness.
- Add opt-in independent pause leases, retry-safe acquisition/release and active-lease rollback protection.
- Preserve legacy CLI JSON formats; agent reads omit labels, native paths and identities.
- Run the offline suites concurrently, longest first, so a full verification takes a little over half the wall time; `scripts/test.ps1 -Parallel 1` still runs them one at a time.
- Cover the two paths that make an installation run unattended: the scheduled collector command line and the updater launcher. Remove an unused launcher script.


## Unreleased

- Record why a Codex account is blocked, so a plain quota exhaustion with a confirmed reset projects its refill while spend and account restrictions stay conservative. Name the first useful refill beyond 24 hours as text, and stop repeating a weekly-only account's own figure as separate weekly text.

- Preserve the renovated dashboard, full-resolution Nyan animation and updated fictional screenshots. Retry Windows replacement error 1175, release read handles before parsing JSON, distinguish storage recovery from provider backoff, isolate provider health, and keep legacy output failures from invalidating the primary snapshot.

- Report low-balance Claude rotation consistently in status and selection explanations. Add a collector regression covering exhausted-account escape, highest-balance rotation, dwell, stale readings, refills, holds and observation-only previews; document matching critical entry to the normal margin.

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
