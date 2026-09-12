# Updates, rollback, and uninstall

Extract a new reviewed archive and rerun install.ps1 with the existing InstallDirectory. Installation checks file hashes when supplied, validates ownership/policy, takes the collector lock, keeps the former app in previous/, and preserves state. Optional scheduler and PATH registration are idempotent. The state location cannot change during an update.

Roll back from a separate extracted release:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\rollback.ps1 -InstallDirectory "$env:LOCALAPPDATA\HotPl8"
```

Only the preceding app is retained. Policy is not downgraded: review configuration changes before rollback. Version 1 has no destructive state migration. Never update while an interactive process depends on files you intend to replace; close the dashboard first.

Uninstall from the extracted release:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -InstallDirectory "$env:LOCALAPPDATA\HotPl8"
```

Owned scheduler/PATH/app files and this installation's exact optional HotPl8 hook commands are removed. State and native provider account homes, credentials, conversations, and unrelated hook handlers are retained. Invalid hook files or unknown files in an owned app directory stop deletion rather than being discarded.

## Existing private/source installation

The default portable state behavior remains supported. To migrate, install into a new directory and point StateDirectory at the existing HotPl8 state directory. Existing policy is preserved. Disable the old scheduler only when the new scheduler is verified; do not leave two independent timers. Re-register optional hooks with the new stable app path and remove only obsolete HotPl8 handlers. Never copy native auth.json or cswap credentials between account homes.

Private development repositories may contain account data in older commits. Keep their history private when migrating to this public source release; never import native credentials or private logs into a public branch.
