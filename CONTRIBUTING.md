# Contributing

Use Windows PowerShell 5.1, Git Bash, Python 3, Node 22+ and Rust (through [rustup](https://rustup.rs); the version is pinned in `native/rust-toolchain.toml`) for the complete offline suite. Python 3.12+ is needed separately if using claude-swap. Clone the repository, build the compiled reader once and after any change under `native/`, and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-native.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test.ps1
```

Suites run concurrently, so each one's output is printed whole when it finishes rather than streamed. Add `-Parallel 1` to run them one at a time with live output when reading a single suite's progress matters.

Tests use temporary fixture accounts and a compiled fake Codex executable. They must not log into accounts, send prompts, mutate native credential homes, or change your installed scheduler/PATH. The complete Windows suite needs permission to execute temporary test binaries. A restricted sandbox can report transport failures before product code reaches the fake provider.

Run [static checks](scripts/check.ps1), then relevant focused suites during development. CI runs the complete suite. Keep fixes small, describe observable behavior, and include regression coverage for meaningful bugs. Preserve the existing eligibility, quota-freshness, isolation, and failure tests. Do not weaken checks simply to obtain a green count.

PowerShell files use UTF-8 BOM when non-ASCII text is present, for Windows PowerShell 5.1 compatibility. Shell scripts use LF. Runtime has no dependency on Python or Bash except the separately installed Claude adapter dependency.

Never commit real emails, user paths, credentials, native account homes, quota logs, screenshots of real accounts, or diagnostic dumps. Use fictional fixtures. Security reports belong in the private route in [SECURITY.md](SECURITY.md).

Keep account incident details, workstation inventories, fleet roles and private
automation instructions out of source comments and plans too. Explain the
reusable failure mechanism with fictional examples. Automated privacy checks
are a supplement to review; they cannot recognize every personal narrative.

HotPl8 owns its release format, explicit update/recovery commands and component
lifecycle. Operator configuration owns executable bindings, channel enrollment,
update schedules and cross-application coordination. Product code must work
without a private manager or knowledge vault. Do not infer a machine's action
policy or warming role from its platform. Preserve compatible installed receipts
when generalizing old names; a naming cleanup must not strand working updates.

Release maintainers follow [release-checklist.md](docs/release-checklist.md). Do not publish from a working-directory ZIP or tag an untested revision. Provider contract changes need recorded native-client evidence; offline fakes alone cannot prove token-refresh or billing behavior.

Contribute code you have the right to submit, under the project's MIT license. Be respectful, describe problems concretely, and avoid harassment or sharing personal information. Maintainers may remove abusive content and restrict participation.

## Navigating and changing the code

Public entrypoints are at the root, internal code in `src/`, provider adapters in `src/providers/`, and all offline suites in `tests/`. Build and verification tools live in `scripts/`. See the [source map and decisions](docs/architecture.md). Preserve entrypoint paths used by installations and hooks. Update release-files.json when a shipped file moves.

Before adding or changing an installed bridge, helper, launcher or service, read
[the delivery contract](docs/delivery.md#component-lifecycle). Define its update
owner, activation boundary, loaded-version evidence and recovery behavior. Include
it in the existing adapter inventory/readiness and test an upgrade from a prior
installation. A working source checkout or passing clean-install test does not
prove an enrolled installation will receive the change.

For UI changes, regenerate and inspect the [documentation screenshots](docs/screenshots.md). The harness draws the frames of the compiled reader with fixed fictional fixtures, so build the reader first; never capture live accounts. The dashboard's layout, colours and keys are unit tests in `native/` (`dashboard.rs`, `display.rs`, `paint.rs`, `nyan.rs`, `watch.rs`, `terminal.rs`), and `tests/test-dashboard.ps1` opens the program itself. Relevant focused checks:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-native.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test-dashboard.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test-onboarding.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\screenshots.ps1
```

Capacity and emergency-policy changes also require `tests/test-capacity.ps1`. Do not infer weekly or short-window capacity from price ratios, weaken unknown-state checks in the calibrated capacity model, or count a skipped retry as a failed provider attempt. The displayed metric measures readable accounts and records every exclusion in `coverage`; it must never blank because one account is unreadable. Preserve third-party animation notices in source and release packages.

Claude plan discovery is isolated in `src/providers/claude_plan.py`, which the collector asks (`native/src/plans.rs`); the check of a stored answer is there too. Run `python tests/test_claude_plan.py` and `cargo test --locked` in `native/` for identity/schema/cache changes; the full suite includes both. Fixtures must not contact Anthropic or read real native credentials. Native qualification must return only the sanitized plan projection.

The compiled program under `native/` is the only implementation of `version`, `status`,
`explain`, what the tray shows and the dashboard, of the collector, of the choice of an
account for T3 and of the Codex launch, and it holds every rule about accounts. PowerShell
hands those requests and every wake to it and has no answer or collector of its own, so do
not add one. `tick.ps1` only starts it, `src/tray.ps1` draws the window around its answer,
and `src/lane.ps1` holds the two pieces of a wake it still asks PowerShell for. A PowerShell
command that needs a rule asks for it through `src/rules.ps1`, one start of the program per
question: add a question there and in `native/src/rule.rs`, never a calculation in
PowerShell. Remember an answer (`-Remembered`) only when it depends on nothing but the
release. Changes to the program require `cargo test --locked` in `native/`,
`tests/test-native.ps1` and `tests/test-native-parity.ps1`; a change to a wake also requires
`tests/test-tick.sh`, and a change to how Codex accounts are read `tests/test-codex.ps1`. A
unit test passes a scratch home, a stand-in for cswap and for Codex, and its own clock,
environment and lanes; none may reach the machine's accounts, look for a program on the
machine's path or start PowerShell. A suite that reads an account through `Read-CodexQuota`
passes a stand-in program by name, since the program otherwise finds the machine's own Codex,
and a fixture release that a suite installs or loads rules from carries `bin/`.

The rules are held by four kinds of expected result, all under `tests/parity`. The
program's unit tests read `shared-rules.json` and `codex-buckets.json`, one case to a line,
and replay `rule-cases.json`: calls recorded from the PowerShell rules before they were
deleted, each with what PowerShell answered. A recorded case the program answers differently
on purpose carries `"program"` and a `"why"`, and the reason is a difference written in the
contract. The parity suite asks the program about the fictional cases in `cases.ps1` and
about seeded variations of them, and compares what `status`, `explain`, the tray and the
dashboard show with `expected-status.txt`, `expected-explain.txt`, `expected-tray.txt` and
`expected-watch.txt`, and the values behind them with the digests in `expected-values.txt`
and `expected-variations.txt`. Add a case for every input shape a change touches. `-Only NAME`
runs one case, `-Only NAME -Values` prints the values a digest stands for, `-Deep` asks many
more variations, and `-Update` rewrites the expected text after a deliberate change; review
what it rewrote like any other change. One rule is still in PowerShell as well, the kind a
failure is recorded under (`Get-Hotpl8FailureCode`): a change to it changes
`native/src/ps.rs`, `src/collection.ps1` and the `failures` cases of
`shared-rules.json` in one commit, and `tests/test-safety.ps1` holds PowerShell to them.
Write the behavior into [the contract](docs/plans/rust-read-side.md) before the code. A case
or an expected result is never edited only to make a comparison pass. The reader depends on no crate, and adding one means recording it in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

`hotpl8-launch2.cmd` and `delivery/launch2.cmd`, and the `hotpl8-launch.cmd` and
`delivery/launch.cmd` they took over from, keep the text they were released with, because a
running session comes back to them by position. A launcher that has to change ships under a new
file name; see [the launcher](docs/install.md#the-launcher). `tests/test-native.ps1` holds their
bytes and fails on any other.

Anything that is started later from a folder HotPl8 does not choose (a launcher, a hook, a
scheduled task, a program recorded in a registration) names its program by a whole path.
Windows looks for a bare name in the current directory before `PATH`.
`tests/test-safety.ps1` reads every command file that ships for this.

T3 integration changes require `node --test tests/test-t3-codex.mjs` and
`tests/test-t3-routing.ps1`. Fixtures use synthetic credentials and a fake native
executable. Never print the private broker response: it contains an access token.

## PR preview handoff

Follow [the live PR handoff](docs/delivery.md#required-pr-handoff) for every PR.
Include the PR URL, exact head SHA, Windows/Mac checks and a runnable, pinned
live-preview command. The owner tests the candidate before merge. Keep Windows
and Mac terminal behavior qualified; screenshots alone do not establish native
terminal rendering. A changed head needs a fresh command and fresh checks.
