# Privacy and local data

HotPl8 has no telemetry service. Quota collection invokes native provider tools, which contact their providers and retain their own authentication/logging behavior. Cached dashboard, status, and doctor commands do not call quota APIs or send prompts. Enabled Claude warming/recovery sends a prompt and can consume subscription capacity.

The state directory contains policy.json (account homes/labels and action choices), status snapshots, Codex observations and identity/binding hashes, warming timestamps, a lock file, and bounded event logs. Codex observation history is capped; event logs rotate. Hashes and quotas can still identify or describe a user and are not anonymous data. Do not upload the state folder.

Native Codex owns sign-in and token refresh. HotPl8 reads native identity information, including the account identity field in auth.json when available, without persisting its tokens. Legacy Claude warming/recovery reads credential-generation markers and deletes a cswap session credential copy; this remains experimental. Monitoring mode bypasses that path. Credentials are never included in release archives.

`status -AsJson` is local operational output and can contain private labels. `doctor -AsJson` excludes labels, account IDs, paths, tokens, environment values, and native output. Error events contain fixed codes rather than raw exception/server messages.

Uninstall preserves state and native credentials/conversations. Delete only HotPl8's retained state after deciding you no longer need it. Native tools have their own separate uninstall and data-retention procedures.

Version 0.2 adds private local `collector.json`, `activity.json` (last 100 events), `warm-outcomes.json`, `attempt-budget.json` (current UTC day), `automation-pause.json`, `notification-state.json`, `update-state.json` and `policy.previous.json`. Optional `usage-history.json` retains at most 4,096 samples for 14 days; `hotpl8 history -Operation clear` clears it. Disable `historyEnabled` to stop recording. Status/history stream pseudonyms are derived separately from native login-binding hashes, but remain private identifying data. No prompts or raw native output are recorded by these modules.

The optional tray reads local snapshots and delivers system notifications. Explicit update commands contact GitHub for release metadata and artifact provenance; opening a dashboard or tray does not check for updates.

Claude collection also detects subscription plans through read-only requests to `https://api.anthropic.com/api/oauth/profile`, using the installed claude-swap Python adapter's credential reader. The helper keeps access tokens in memory and sends them only to that fixed HTTPS endpoint; redirects are refused. It never sends prompts, refreshes tokens or writes credentials. Only identity-matched plan labels, profile IDs, session multipliers, fixed error codes, timestamps and account-binding hashes enter `claude-plans.json` and status snapshots. No email, raw profile, invoice URL or credential is saved by this feature. Discovery refreshes every 15 minutes, retries failures no faster than that, and honors longer bounded rate-limit delays. Cached display commands never invoke the helper. claude-swap retains ownership of its storage and initialization/migration behavior.

## Agent interface

Agent JSON and MCP reads use explicit projections that omit labels, account homes, native identities, credentials and lease capabilities. Slot IDs, quota observations and availability remain local account data; an MCP client can send returned data to its model. Acquire/release replies return only the supplied job capability. The private `automation-leases.json` ledger stores UUID capabilities, caller owner labels and expiry/tombstone times. It is gitignored and never part of a release. Anyone with the same filesystem permissions can inspect it; cooperative ownership is not a security boundary. No network service is started. [Agent API](docs/agent-api.md).

## Optional T3 integration

The opt-in T3 adapter reads an enrolled home's access token after native account
validation and sends it to native Codex over private subprocess pipes. It does not
copy or store refresh tokens or replace shared auth files. Its setup receipt stores
local paths and the original default model selection. Native conversation state
remains governed by Codex and T3. See [integration details](docs/t3-integration.md).
