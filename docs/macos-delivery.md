# Verified main updates on macOS

Mac delivery selects the same verified main release as Windows when explicitly
invoked. Setup creates no schedules by default. Operators own automated update
scheduling and machine configuration; a merged PR, source sync or passing CI does
not enroll a host. See [the delivery contract](delivery.md) and
[acceptance plan](plans/macos-delivery.md).

## Prerequisites and enrollment

Use Python 3.12+, PowerShell 7.5+, Node 22+ for T3, and a signed-in GitHub CLI
supporting `gh attestation verify`. Keep native provider login homes independent.
The existing HotPl8 state directory must contain a compatible `policy.json`.
The GUI user must be logged in. Do not run as root or create a system daemon.

Before choosing collector scheduling, inspect the current LaunchAgent and command.
Retire only that inspected collector, using its exact path and SHA256 digest.
Other HotPl8 collector or unrecognized definitions in user/system LaunchAgents
or LaunchDaemons block collector enrollment for explicit reconciliation;
cron or an external scheduler must also be inspected
by the operator. The updater never guesses ownership from a process name.

From a trusted checkout, with absolute host-specific paths:

```sh
python3 delivery/macos.py setup \
  --install "$HOME/Library/Application Support/HotPl8/managed" \
  --state "$HOME/Library/Application Support/HotPl8/state" \
  --powershell /absolute/path/to/pwsh --gh /absolute/path/to/gh \
  --codex /absolute/path/to/native-codex --cswap /absolute/path/to/cswap
```

Choose an empty managed directory; the pinned source installation remains intact.
Bind the existing collector's exact Codex/cswap executables, especially when
HotPl8 uses a separate native package from T3's global CLI. Omitted bindings use
the existing provider resolver and the enrolled PATH; omission is appropriate
only after verifying those resolve the intended binaries. These are runtime
bindings, not account enrollment or credential copies.
To register HotPl8's one-minute collector, add `--schedule-collector`. To replace
an existing collector, also supply `--adopt-collector` with its inspected plist
and `--adopt-digest` with that exact file's SHA256. Adoption without explicit
collector scheduling is refused. Without scheduling, existing collectors remain
untouched and may still point to pinned source; do not claim they are managed.

Collection follows the existing policy. Add `--observe-only` only when this
installation should suppress automatic actions regardless of policy. The override
is local enrollment configuration, preserved on repeated setup; the OS does not
decide warming ownership. Adopting a collector that already passes `-ObserveOnly`
requires this flag so migration cannot silently enable actions. Changing an
existing override requires explicit local
reconciliation while collection is stopped, rather than a product update changing
account behavior.

Enrollment first obtains an attested passing **main** Mac package; it never installs a PR
artifact or builds a fallback from source. A missing release leaves the existing
collector untouched. Repeat the command after the passing package is published.

The old collector definition is retained as `legacy-collector.plist`. Its native
job is stopped only after acquiring the writer lock, then its plist is removed
before the replacement is registered. `collector-migration.json` records each
step so interruption can be retried without a duplicate collector. If interrupted
after retirement, repeat enrollment; the receipt is sufficient to continue.

When requested, one installation-specific collector LaunchAgent wakes at login
and every minute. HotPl8 creates no updater LaunchAgent. Sleeping or logged-out
hosts do not provide
continuous service; the next eligible wake reconciles current state without
replaying missed ticks. Intentional launchd disablement is reported separately
and is not cleared by an update. Policy and native accounts are retained; setup
does not add missing sign-ins or assign any other machine a role. Experimental
installations with a product-owned updater receipt or registration require its
explicit retirement before adopting externally scheduled updates.

Use the enrolled `managed/hotpl8` command for the CLI/dashboard. Existing shortcuts
that still point at the source tree remain pinned until explicitly rebound to
this command. Do not infer that a source shortcut is managed from the presence
of a new managed installation.

## T3 uses ordinary Codex

Stage one managed bridge using the same installation, explicit native Codex
executable and **existing** shared conversation home:

```sh
python3 delivery/macos-t3.py stage --install /absolute/managed \
  --settings /absolute/t3/settings.json --home /absolute/existing/codex-home \
  --node /absolute/path/to/node --codex /absolute/path/to/native-codex
```

Quit T3 completely, then repeat with `activate` in place of `stage`. Activation
refuses while T3 is running. It configures `providerInstances.codex`, preserving
the ordinary `codex` identity, unrelated settings, conversation home and thread
data. T3 builds with an implicit default Codex provider can use this explicit
override. A separately customized Codex binary or legacy explicit Codex schema
requires an inspected migration; it is not overwritten automatically. Native
readiness probes import the bridge and validate the selected manifest without
starting a provider, authenticating or sending inference.

The bridge launcher delegates to the same `current.json` as the collector. Each
new bridge selects one immutable release. Existing sessions retain their loaded
code; diagnostics report `restart-pending` when it differs. Delivery changes no
T3 settings, never rewrites thread records and never terminates an active session.
An explicitly removed provider remains unmanaged and is not recreated.

## Inspection and recovery

```sh
python3 /absolute/managed/delivery.py status
python3 /absolute/managed/delivery.py update
```

For automatic checks, configure an external scheduler or manager to invoke
`/absolute/python /absolute/managed/delivery.py job updater`. This bounded command
uses the same verification and rollback path and records attempt outcomes. The
operator owns its schedule, environment, enabled state, timeout budget and removal;
HotPl8 neither registers nor repairs it. Allow more than the 540-second worker
budget for process cleanup. Store that registration and host bindings outside the
public repository. Inspect the external scheduler separately: a successful manual
update does not prove unattended updates are enabled.

Inspect these independent signals:

| Evidence | Meaning |
|---|---|
| `delivery-status.json` | Desired, installed, last check, pending/error reason |
| `current.json`, `previous.json`, `transaction.json` | Selected immutable code, rollback target, unfinished activation |
| `macos-jobs.json` plus launchd | Explicitly enrolled collector definition, loaded and enabled registration |
| `job-runs/collector.json`, `updater.json` | Execution result and separately recorded useful outcome |
| `job-runs/unfinished-*.json` | Prior unfinished run, retained after a later success |
| State directory `collector.json` | Actual completed collector SHA and per-provider health |
| T3 components | Next-launch SHA, observed loaded SHAs, unknown processes |

Each `job` invocation owns a separate process group. A pipe guardian cleans its
non-daemonizing descendants on timeout, excessive output, cancellation, parent
death and normal completion. Work must remain in that group; daemonizing helpers
are unsupported. Overlapping wakes coalesce through a job lock. Raw provider
output is discarded; no credentials are written to job logs. An exit-zero worker
without a fresh outcome is explicitly `no-new-outcome`, not proof of collection.

Failed readiness selects the prior compatible reader while retaining current
state. Interrupted activation is recovered by the known-good runner. A failed
first activation has no proven previous release and requires inspection of the
transaction before retry; do not erase the transaction to force admission.
Wrong platform, bad hashes/provenance and unavailable builds never replace the
working release. Immutable releases are retained for active processes/recovery.

For removal, close T3 and run `delivery/macos-t3.py remove --install ...` to
restore its prior ordinary provider configuration. Then run
`delivery/macos.py uninstall --install ...` to stop/remove only the owned native
collector job. Changed registrations are refused. External updater schedules are
removed through their owning scheduler. Both commands retain releases, receipts,
native accounts and application state. Uninstall does not automatically restart
the old collector; an operator may inspect and restore the preserved plist after
confirming no replacement collector remains enabled.

## Qualification

`scripts/test-macos-delivery.ps1` requires macOS and tests native update/rollback,
T3 adoption/ownership, process containment, real isolated launchd execution and
enabled provider/dashboard surfaces. CI also runs the shared delivery suite,
native Python/.NET locking and launcher tests, and Node bridge regressions.
Windows CI remains required before either main asset is published. Host
qualification must additionally check the real enrolled commands, account
freshness, login and sleep/wake behavior. CI fixtures alone do not establish that
automatic updates are operating on a particular user's Mac.
