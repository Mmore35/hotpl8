# Privacy and local data

HotPl8 has no telemetry service. Quota collection invokes native provider tools, which contact their providers and retain their own authentication/logging behavior. Cached dashboard, status, and doctor commands do not call quota APIs or send prompts. Enabled Claude warming/recovery sends a prompt and can consume subscription capacity.

The state directory contains policy.json (account homes/labels and action choices), status snapshots, Codex observations and identity/binding hashes, warming timestamps, a lock file, and bounded event logs. Codex observation history is capped; event logs rotate. Hashes and quotas can still identify or describe a user and are not anonymous data. Do not upload the state folder.

Native Codex owns sign-in and token refresh. HotPl8 reads native identity information, including the account identity field in auth.json when available, without persisting its tokens. Legacy Claude warming/recovery reads credential-generation markers and deletes a cswap session credential copy; this remains experimental. Monitoring mode bypasses that path. Credentials are never included in release archives.

`status -AsJson` is local operational output and can contain private labels. `doctor -AsJson` excludes labels, account IDs, paths, tokens, environment values, and native output. Error events contain fixed codes rather than raw exception/server messages.

Uninstall preserves state and native credentials/conversations. Delete only HotPl8's retained state after deciding you no longer need it. Native tools have their own separate uninstall and data-retention procedures.

Version 0.2 adds private local `collector.json`, `activity.json` (last 100 events), `warm-outcomes.json`, `attempt-budget.json` (current UTC day), `automation-pause.json`, `notification-state.json`, `update-state.json` and `policy.previous.json`. Optional `usage-history.json` retains at most 4,096 samples for 14 days; `hotpl8 history -Operation clear` clears it. Disable `historyEnabled` to stop recording. Status/history stream pseudonyms are derived separately from native login-binding hashes, but remain private identifying data. No prompts or raw native output are recorded by these modules.

The optional tray reads local snapshots and delivers system notifications. Explicit update commands contact GitHub for release metadata and artifact provenance; opening a dashboard or tray does not check for updates.
