# Verified main delivery on macOS

## Problem and outcome

The main-channel updater currently ships a Windows package. A working Mac source
installation therefore remains pinned, including any separately copied T3 bridge.
Adding a timer that pulls or builds source would bypass the tested-release and
recovery contract.

The target is an explicitly enrolled Mac installation able to select tested public main, with
separate desired, installed, next-launch and running version evidence. Updates
preserve native credentials, policy, history and active conversations. This plan
does not declare the broader Mac feature port complete.

## Release contract

- CI tests Windows and Mac before publishing either main-channel candidate.
- A retained `main-<sha>` release contains `hotpl8-main.zip` for Windows and
  `hotpl8-macos-main.zip` for Mac. Each has exact source identity, a complete
  checksummed inventory and provenance from the main CI workflow.
- Enrollment records an explicit platform. Legacy registrations without that
  field retain their Windows interpretation. Wrong-platform candidates fail
  before adapter execution, including candidates already staged on disk.
- The Mac package contains every required native fix. A source installation
  with unpublished fixes cannot safely enroll into a package that omits them.
- A failed or unfinished build, missing asset, offline host or failed provenance
  check leaves the working release selected. There is no source-build fallback.

## Native installation and activation

The Mac adapter binds absolute Python, PowerShell and GitHub CLI paths to its owned
installation and preserves its existing state directory. Setup creates no
schedules by default. An operator may enroll the collector and independently
schedule the public bounded update command using an external manager. Sleep and logout are
availability boundaries; a timer wake reconciles current desired state rather
than replaying missed work. Dependencies run without interactive input and with
bounded execution and process cleanup.

Use the existing protocol-1 immutable releases, update/runtime/writer locks,
`current.json`, transaction and previous-release records. Verify Python/native
writer lock interoperability on macOS. Candidate preflight must run without
provider actions. Readiness failure or interrupted activation restores a
compatible previous reader while retaining current application state.

First enrollment preserves the source installation as recovery evidence. Native
scheduler replacement requires proof of ownership and cannot create a second
collector. Collector observation overrides are explicit local configuration;
platform identity never implies an account-action policy or another host's role.
Unenrollment must leave native accounts and unrelated jobs intact.

## Components

The collector and CLI select the current immutable release through stable
entrypoints. A completed collector records the actual loaded SHA. Long-lived
displays and native/T3 sessions retain loaded code until their defined adoption
boundary; installation status must not imply those processes restarted.

A managed T3 bridge uses the same verified release pointer and rollback. Preserve
the ordinary Codex provider identity and shared conversation home. Initial
activation into T3 remains a host-closed operation; delivery must not rewrite
thread metadata, kill active work or replay prompts. A separately pinned bridge
must report unmanaged until deliberately enrolled.

## Acceptance

The implementation PR must record Windows regression results and actual native
Mac evidence for:

1. Clean and repeated enrollment; migration of the existing owned collector.
2. Previous release to attested main update and no-change externally invoked checks.
3. Wrong platform, bad provenance, corrupt inventory, held writer, offline
   GitHub and unavailable build without disturbing the working release.
4. Failed readiness, interrupted activation and compatible rollback; rejection
   of incompatible previous readers without reverting application state.
5. Active-process preservation, fresh collector/bridge adoption, missing or
   removed components and accurate unknown/unmanaged diagnostics.
6. Actual launchd invocation, bounded hung descendants, overlap, login and
   sleep/wake behavior, plus preserved authentication and observation policy.

Fixture and CI success do not establish installation or update scheduling on a
user's Mac. Product acceptance covers the interfaces and native fixture evidence;
host deployment is separately qualified after its attested package is published.
Machine inventories, private updater registration and cross-host action ownership
remain in operator records outside this repository.
