# Updates, rollback, and uninstall

`hotpl8 watch` and `hotpl8 nyan` are modes of the same installed application, using the same state, policy, dashboard and update path. Nyan only adds the animated banner; it has no separate installation or update step. After updating, restart either view to load the new code. Development preview commands must remain explicit; do not redirect the ordinary `nyan` command to a pinned checkout.

## Verified update commands (0.2 source candidate)

```powershell
hotpl8 update-check -Channel preview
hotpl8 update-check -Channel preview -Operation dismiss
hotpl8 update -Channel preview -InstallDirectory "$env:LOCALAPPDATA\HotPl8"
```

Checks are explicit and report installed source version, release version, whether it is newer, release notes, and dismissal of that exact tag. A new release is not hidden by a previous dismissal. Stable is the default channel. `-ReleaseVersion 0.2.0-rc.1 -Channel preview` selects an exact preview; optional `-SourceDigest COMMIT` pins its reviewed commit. No dashboard/tray opening triggers a network check.

The updater requires an owned Windows installation and GitHub CLI with `gh attestation verify`. It resolves the release tag to an exact commit, verifies GitHub artifact provenance for this repository's `release.yml` on main, rejects self-hosted signing runners, and rechecks that the tag has not moved. It checks archive paths/size and package version before invoking the existing staged installer. Failed download or verification installs nothing. The installer holds the collector lock and preserves rollback/state on failed replacement.

Only an artifact built by the attested release workflow can pass this check. The original 0.1 preview is unsigned and cannot be installed by the verified updater. Until a new attested build is published, use the reviewed source/manual procedure. Close dashboard and tray processes before replacement. Source checkouts and package-manager-owned installs use their own update procedure.

Extract a new reviewed archive and rerun install.ps1 with the existing InstallDirectory. Installation checks file hashes when supplied, validates ownership/policy, takes the collector lock, keeps the former app in previous/, and preserves state. Optional scheduler and PATH registration are idempotent. The state location cannot change during an update.

Roll back from a separate extracted release:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\rollback.ps1 -InstallDirectory "$env:LOCALAPPDATA\HotPl8"
```

Only the preceding app is retained. Policy is not downgraded. The current rollback command validates policy using the previous version's reader before removing working code. A version-1 reader rejects a version-2 policy; restore a reviewed compatible backup first. `policy.previous.json` contains the immediately preceding policy save, which may itself be version 2 after several edits. Preserve an explicit version-1 backup before adopting version-2 settings if that rollback matters. No state file is destructively migrated. Never update while an interactive process depends on files you intend to replace; close the dashboard first.

Uninstall from the extracted release:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -InstallDirectory "$env:LOCALAPPDATA\HotPl8"
```

Owned scheduler/PATH/app files and this installation's exact optional HotPl8 hook commands are removed. State and native provider account homes, credentials, conversations, and unrelated hook handlers are retained. Invalid hook files or unknown files in an owned app directory stop deletion rather than being discarded.

## Existing private/source installation

The default portable state behavior remains supported. To migrate, install into a new directory and point StateDirectory at the existing HotPl8 state directory. Existing policy is preserved. Disable the old scheduler only when the new scheduler is verified; do not leave two independent timers. Re-register optional hooks with the new stable app path and remove only obsolete HotPl8 handlers. Never copy native auth.json or cswap credentials between account homes.

Private development repositories may contain account data in older commits. Keep their history private when migrating to this public source release; never import native credentials or private logs into a public branch.

## Agent pause compatibility

The new collector reads `automation-leases.json` in addition to the manual pause file. Upgrade every collector and pause writer sharing that state before enabling MCP pause writes. Old binaries cannot honor leases. The new rollback command refuses rollback while live or invalid lease state exists; released and expired leases do not block it. Old rollback/install binaries cannot enforce this guard. See [agent API](agent-api.md).
