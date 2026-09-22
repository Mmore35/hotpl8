# Automatic main updates and PR previews

## Shared update ownership

An operator may enroll an installation into a compatible protocol-1 central
manager. Its local `delivery-owner.json` pins a manager entrypoint digest, service
identity and task name. The stable bootstrap delegates update and preview calls;
status retains HotPl8's richer component diagnostics. Missing or changed manager
identity fails closed rather than starting a second updater. Direct invocation of
the bundled update runner and standalone re-enrollment are refused while owned.

The native registrar continues to update the collector, but never creates or
changes the product updater under central ownership. A retained legacy updater
must stay disabled. Export task definitions and preserve bootstrap bytes before
handoff; rollback drains the central owner before restoring them. Runtime state
and active provider sessions are not rolled back. `delivery/contract.json` declares
the application lifecycle accepted by the shared manager. This optional integration
does not enroll other installations or add a dependency for standalone use.

HotPl8 has two installation choices. Ordinary installations use reviewed versioned
releases. An installation explicitly enrolled in Local Delivery follows tested
`main` automatically. Contributors continue to work in separate source checkouts.

## Enroll an installation

Install HotPl8 using the [normal installer](install.md), then install Python 3.11+
and GitHub CLI and authenticate `gh` with read access to the repository and Actions.
Run from a reviewed source checkout or extracted release:

```powershell
python delivery/setup.py --install "$env:LOCALAPPDATA/HotPl8"
```

Enrollment preserves the configured state directory and collector task, keeps the
old app directory as a recovery copy, installs stable compatibility launchers and
registers `LocalDelivery-hotpl8`. The updater runs hidden every five minutes while
the user is signed in, catches missed executions when available, and checks at
logon. It does not keep the computer awake or run while Windows is shut down.

The task downloads only the package published by a successful main workflow. The
release tag, source commit, asset digest, provenance, file inventory and file
hashes must agree. Packages are retained prerelease assets named by source SHA;
they do not expire with Actions artifacts. A failed or missing main build leaves
the existing version installed. No local build or arbitrary PR script substitutes
for a verified package.

## Status and updates

```powershell
hotpl8 version -AsJson
hotpl8 delivery
hotpl8 update
hotpl8 preview pr 12
```

`update` is an optional immediate check; the timer performs the same operation.
`delivery` distinguishes desired and installed SHA, previous release, last check,
last update and a pending/error reason. `collector.json.runningSha` records the
code used by a completed collector pass; it is separate from installed source.
An interactive dashboard's window title identifies its loaded main SHA and update
state. When production changes it hands off to the new release in the same console.

`delivery` also reports registered [T3 bridges](t3-integration.md): next-launch
selection and observed running revisions. `current` at the release level means
the code pointer/readiness passed, not that every long-lived session restarted.
Read component adoption states before claiming a reported bug is fixed in an
already-open session. Existing bridges without process receipts are explicitly
unknown until those processes end.

Updates prepare immutable `releases/<sha>` directories and change `current.json`
only after preflight and writer drain. Existing short commands finish first. The
collector's existing lock is also held during activation. Dashboards and native
client sessions use their original immutable code; native sessions are never
killed by an application update. State and credentials remain outside releases.

The normal semantic-version installer and rollback commands must not be run over
an enrolled installation. Use its delivery status and retained release pointers
for recovery, or a separately coordinated unenrollment. Channel enrollment is an
installation decision, not a feature switch in quota policy.

## Preview boundary

`preview pr NUMBER` downloads the successful PR workflow's PNG dashboard renders
and reports their paths, exact PR SHA and fictional-data mode. Open the returned
images in your image viewer. These are CI-rendered visual previews, not interactive
copies and not your live account readings. Old PRs without this workflow need a
new run before a preview is available. Production selection never changes.

Arbitrary PR code is not executed on the host. A local working directory or a
display-command allowlist does not isolate a contributor's code from credentials.
Interactive previews require separately qualified OS isolation and an exported
display snapshot; this version does not claim to provide that sandbox.

## Failure and recovery

If the updater is interrupted during activation, its next invocation restores the
previous code pointer and records the rejected SHA. It retains all current state.
An activation failure is quarantined until a newer main commit exists; it is not
retried on every timer wake. Interrupted first enrollment is reported for operator
recovery because no previous managed release exists yet. The original app remains
available until successful enrollment installs its compatibility launchers.

Inspect `delivery-status.json`, `transaction.json`, `current.json`, `previous.json`
and `rejected.json` in the owned installation. Do not delete or restore subscription
history to roll code back. An operator recovery must hold the same update/runtime
and application writer locks before changing the pointer. Retained immutable code
does not make incompatible data/schema migrations reversible.

## Reusable protocol

`delivery/runner.py` is Local Delivery protocol 1, a standalone standard-library
module with no HotPl8 imports. Each installation registers a repository, main
workflow, asset, compatibility number, writer locks and application adapter.
Adapters provide `preflight`, `drain`, `activate`, `health` and `recover`; they must
not report success until the application's readiness contract is met. The
HotPl8 adapter validates the policy without provider actions; the next normal
collector wake supplies separate live completion evidence.

Other applications can consume this protocol while keeping their own state,
dependencies and lifecycle adapter. Private repositories can use authenticated
GitHub asset digests and exact workflow evidence when their plan does not support
artifact attestations. HotPl8 additionally requires provenance from its CI workflow.

## Component lifecycle

### Native scheduled launchers

Windows collector and updater launches use a GUI host with an at-creation Job
Object. It closes stdin, propagates exits, bounds output to 4 MiB per attempt,
and contains descendants on timeout or launcher death. Collector and updater
budgets are 225 and 540 seconds respectively. There is no additional retry loop.
Collector `incomplete`/provider backoff remains in `collector.json`; a zero process
exit is not evidence that every provider is fresh. Updater results remain in
`delivery-status.json`. Per-attempt execution evidence lives in `job-runs`.

The containment import is pinned in `src/jobs/provenance.json`. Verify a refresh
against that repository/revision and replace the import plus normalized LF SHA256
together; the installer rejects a mismatched import. Product host source is beside
it. Full UA runner enrollment is not used for these native multi-trigger jobs.

Ordinary installations receive the collector host through `install.ps1 -Schedule`.
For an already-enrolled installation, explicitly migrate the native components
from its verified current release:

```powershell
powershell -NoProfile -File <current-release>/delivery/register.ps1 -InstallDirectory <install> -Python <python.exe> -CollectorTaskName <existing-collector-name> -AdoptCollectorLauncher <exact-legacy-vbs>
```

The adoption path is needed only for a legacy collector whose description predates
installation ownership. `-PlanOnly` stages the immutable host without changing any
task. Migration preserves existing XML trigger, principal, enabled and battery
settings, exports recovery XML, and records `scheduledJobs` in the delivery
registration. Subsequent verified activation/recovery reconciles these enrolled
components through the same registrar. Only Actions change: admitted updater work
continues on its original immutable host. No loaded executable or stable dispatch
file is overwritten. Next launches use the normal release-pointer dispatch, also
compatible with the predecessor release. T3 sessions are untouched.

For recovery, pause the affected task, let admitted work finish, restore its
exported XML and intended enabled state, and remove the `scheduledJobs` enrollment
only when deliberately undoing this component migration. Preserve current product
state. Retain `launchers` versions while any task or running process references
them. Execution records are private and may be archived after investigation.
`tests/test-job-host.ps1 -Native` qualifies live action replacement with one unique
fixture task; the default suite does not register tasks.

Every shipped runtime component needs an update owner and acceptance evidence.
Extend the application's existing adapter and inventory before adding another
updater. Packaged files alone are insufficient when setup copies them elsewhere.

| Component | Selection and adoption | Evidence and recovery |
|---|---|---|
| CLI and scheduled collector | Stable launchers select current release; existing short writers drain | Installed SHA and completed collector SHA; pointer rollback |
| Interactive dashboard | Existing handoff after pointer change | Loaded SHA in window title; retained release |
| Managed T3 bridge | Bootstrap selects verified current release once per new provider process | Per-process SHA/start/heartbeat, read-only import probe; same pointer rollback, active sessions retained |
| Standalone T3 bridge | Deliberately pinned setup copy | Doctor reports unmanaged; explicit reinstall |

The HotPl8 adapter discovers owned T3 receipts under `integrations`, records their
membership in `delivery.json`, and detects missing registered components. It
validates unchanged T3 provider ownership and state binding before enrollment.
Configuration is switched atomically to an immutable bootstrap; its protocol-1
dispatch also works with the predecessor's exported bridge entrypoint. Therefore
interrupted activation and an older adapter's recovery only need the existing
release-pointer transaction. No additional code-selection pointer can get stuck
on a rejected release.

For component changes, test prior install -> verified package -> activation ->
fresh process adoption, plus concurrent old work, missing components, failed
readiness and interrupted rollback. New integrations should preserve native
provider identities and labels where possible; exposing an internal router as a
second model choice creates a separate conversation-migration obligation.
