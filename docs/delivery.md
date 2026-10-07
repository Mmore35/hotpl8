# Verified main updates and PR previews

HotPl8 has two installation choices. Ordinary installations use reviewed versioned
releases. An installation explicitly enrolled in Local Delivery follows tested
`main` automatically. Contributors continue to work in separate source checkouts.

Here, Local Delivery names HotPl8's existing standalone delivery protocol and
compatibility identifiers. It does not require an external manager, knowledge
vault or another application. Keep existing `managedBy: local-delivery` receipts
and `LocalDelivery-hotpl8` task names during upgrades; changing their spelling
would strand installed ownership and recovery checks.

HotPl8 owns the release payload, verification, explicit update/recovery commands
and component adoption. Operators choose their channel, invocation schedule,
executable bindings and account policy. A private or third-party manager can call
the same public command without any reverse dependency in HotPl8. Cross-product
registries, machine inventories and which host owns warming belong outside this
repository. Mac enrollment creates no schedules by default; see
[Mac delivery](macos-delivery.md) for explicit collector enrollment and externally
scheduled updates. Existing Windows standalone updater enrollment remains opt-in.

For macOS enrollment, collector adoption and T3 lifecycle, use
[Mac automatic delivery](macos-delivery.md). The instructions below enroll Windows.

## Enroll an installation

Install HotPl8 using the [normal installer](install.md), then install Python 3.11+
and GitHub CLI and authenticate `gh` with read access to the repository and Actions.
Run from a reviewed source checkout or extracted release:

```powershell
python delivery/setup.py --install "$env:LOCALAPPDATA/HotPl8"
```

Enrollment preserves the configured state directory and collector task, keeps the
old app directory as a recovery copy, installs stable compatibility launchers and
registers `LocalDelivery-hotpl8`. On Windows the launchers are `hotpl8.cmd`, `launch.cmd`
and a copy of the compiled reader that they ask first; see
[the launcher](install.md#the-launcher). The updater runs hidden every five minutes while
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

Enrolled scheduled collector and updater tasks report `current` when they launch
the configured host and are turned on, `disabled` when turned off (for example,
paused for recovery) and `error` when missing or pointing elsewhere.

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

### Live candidate dashboard

For a reviewed, same-repository PR with passing CI on its current head:

```powershell
hotpl8 preview pr NUMBER -Live -TrustRevision FULL_40_CHARACTER_HEAD_SHA
```

The command prints the PR URL, exact revision and **fictional accounts** data mode,
then runs the actual PR dashboard and animation in your terminal. Space freezes
or resumes, arrows scroll, Q exits; resize the window to inspect layout. It uses
fresh demo timestamps and disposable state, never a second collector or real
account cache. This tests presentation and interaction, not provider actions.

`-TrustRevision` explicitly authorizes execution of that candidate's code with
your user permissions. This is **not an OS sandbox**. Use it only for code you
have reviewed and trust. Image previews remain available without executing PR
code, including for fork PRs. Live preview rejects forks, a moved PR head,
nonpassing or unrelated CI, and unsafe source archives. It downloads the source
from GitHub at the pinned SHA, rechecks the head, and never silently substitutes
a newer revision. If the head changed, review it and obtain a new command.

A source archive holds no compiled file. When the candidate's `release-files.json`
lists a compiled reader for this platform, the preview also downloads the package
that the same passing run built, `hotpl8-<platform>-candidate`, checks it against
its `SHA256SUMS` and the reader against the package's `checksums.json`, and places
the reader at its release path in the temporary source export. A missing or
expired package asks for the workflow to be rerun; a package that fails a check
stops the preview before candidate code runs. The run is what vouches for that
file: GitHub builds a pull request from its head merged into the target branch,
so the reader is built from that merge, by the workflow as the PR defines it.
The preview then asks the candidate's reader for the dashboard and shows the
candidate's PowerShell dashboard when the reader has none. See
[the plan](plans/rust-read-side.md#previewing-a-candidates-reader).

Each run owns a temporary source export and fixture directory, removed on exit.
The `live.json` receipt under `previews/pr-NUMBER/SHA` records the URL, SHA,
workflow and data mode. Production pointers, scheduled tasks and ongoing native
sessions are unchanged. Close an old preview and rerun the newly pinned command
after a PR update; previews never switch code underneath an active session.

The launcher is part of the normal release inventory: the existing immutable
release selection updates `delivery/runner.py`, `delivery/live_preview.py` and
`delivery/live-preview.ps1` together. No separately installed preview shim is
needed. Rollback selects the previous implementation for the next invocation;
existing previews retain their exported candidate until they exit.

### Required PR handoff

Every HotPl8 PR handoff includes its URL, full head SHA, passing Windows and Mac
CI evidence, and the pinned live command above. For presentation changes, test
animation, freeze/resume, resize/scroll and clean exit; inspect both terminal
renderers. A PNG alone does not complete interactive acceptance. Run relay review
on the final candidate and obtain owner preview acceptance before merging; after
merge, verify installed and running component adoption through normal delivery.

If installed main predates live-preview support, use the reviewed candidate's
runner temporarily, without changing the installed release:

```text
<enrolled-python> <reviewed-checkout>/delivery/runner.py --install <managed-root> preview NUMBER --trust-revision FULL_SHA
```

The same GitHub/CI/revision checks and demo mode apply. Provide this concrete
bootstrap command in that first handoff; never label an unbound local checkout
or an image command as the live PR preview.

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

Policy schema migration is allowed only after a compatible managed update commits.
The candidate records `state/delivery-owner.json` during drain, before the code
pointer changes; this ownership record survives code rollback. While holding the
same writer lock as delivery, policy migration rejects any unfinished transaction
and asks the committed release's own validators to read the proposed policy before
changing policy or its backup. This also protects the first upgrade when the
installed bootstrap still selects a previous runner without the newer recovery
guard. Recovery refuses an incompatible previous reader before restoring its
pointer or running component recovery, preserving the candidate and transaction
for operator repair.

For a custom installation created before ownership records existed, migrate policy
through its installed `hotpl8` launcher, after its updater has adopted this release.
Source commands with an arbitrary `-StateDirectory` cannot discover an undisclosed
custom installation before adoption. Known installed-launcher and default-directory
registrations are verified as a compatibility fallback; after adoption, the state
ownership record also protects source commands without environment hints. Do not
delete the ownership record to bypass a pending transaction or incompatible reader.

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
it. Provenance points to the byte-identical public HotPl8 snapshot, so verification
and source refresh need no private repository access. The retained source namespace
records its origin; the vendored implementation has no runtime dependency on that
project or its checkout.

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
| CLI and scheduled collector | Stable launchers select current release; existing short writers drain. On Windows the scheduled task starts the `hotpl8-native.exe` beside the launcher with the word `wake`, and that copy starts the compiled collector of the release in force; the task names it only when the copy is the release's own, and `tick.ps1` through PowerShell otherwise. On a Mac the job runner of the release in force starts that release's `hotpl8-native` with `wake` and the installation. See [the plan](plans/rust-read-side.md#contract-scheduled-starts) | Installed SHA and completed collector SHA; pointer rollback. A release from before the compiled collector that comes back into force has its `tick.ps1` started by the same copy |
| Interactive dashboard | Existing handoff after pointer change | Loaded SHA in window title; retained release |
| Compiled reader (`bin/`) | An inventoried file of the release; each new `hotpl8` process uses the one in the release in force. Preflight and health start the candidate's reader and refuse a release whose reader does not answer `version`. See [the plan](plans/rust-read-side.md) | `hotpl8-native self-check` reports the commit it was built from; pointer rollback. `version`, `status` and `explain` have no PowerShell answer: a copy whose reader cannot start says so and ends with status 1 |
| Windows launcher (`hotpl8.cmd`, `launch.cmd` and `hotpl8-native.exe` in the installation directory) | Enrollment installs them, and the first activation of a release that ships them migrates an installation enrolled earlier. `launch.cmd` is never rewritten. Each activation replaces the reader copy when the release's differs, moving one that is answering aside. That copy answers nothing itself: it reads the pointer under the runtime lease and starts the reader of the release in force. See [the launcher](install.md#the-launcher) | `tests/test-native.ps1` holds the launcher bytes and replaces each earlier launcher under a running session; `tests/test_delivery.py` covers enrollment, activation and rollback. A release from before the arrangement leaves every word to PowerShell, as before |
| Managed T3 bridge | Bootstrap selects verified current release once per new provider process | Per-process SHA/start/heartbeat, read-only import probe; same pointer rollback, active sessions retained |
| Standalone T3 bridge | Deliberately pinned setup copy | Doctor reports unmanaged; explicit reinstall |
| Automatic continue waiter | Claude's hook resolves the current release on each run; the Codex bridge runs the copy beside it | Doctor reports the hook; `hotpl8 continue -Operation disable` removes it |

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

For an existing two-provider T3 setup, the explicit gradual transition enrolls
ordinary Codex in a distinct integration directory and retains the old alias.
Both receipts join the existing inventory and follow the same verified pointer;
neither an update nor rollback changes thread provider IDs or deletes the alias.
Removing the ordinary integration restores its recorded original configuration
while the retained alias continues receiving updates. A pending setup journal
requires rerunning the explicit setup operation after host shutdown; automatic
delivery does not resolve user settings conflicts or perform a conversation
migration. See [T3 gradual transition](t3-integration.md#existing-two-provider-installations).

Rollback and interrupted recovery validate the previous release against current
state before restoring its pointer. State is never downgraded to satisfy an older
reader. If that preflight fails, preserve the current pointer and transaction for
an explicitly compatible recovery; no previous-release recovery side effects run.
