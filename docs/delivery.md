# Automatic main updates and PR previews

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
