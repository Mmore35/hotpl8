# T3 Code and Codex account routing

The optional bridge makes T3's normal **Codex** provider consume HotPl8's account policy.
It supports T3's stdio app-server sessions, account/model probes and stateless
`codex exec` helpers. Windows, Node 22+, independently enrolled file-backed native
Codex homes and a running HotPl8 collector are required. It is experimental;
the external-token API is an experimental Codex interface.

## Install and remove

Close T3 (including a separately started server) before first-time setup. From a
reviewed source checkout or extracted release:

```powershell
.\setup-t3.ps1 -Operation install -StateDirectory C:\HotPl8State -MakeDefault
.\setup-t3.ps1 -Operation doctor -StateDirectory C:\HotPl8State
```

Setup replaces the binary path on the existing `codex` provider, preserving its
ID, label, model choices, conversation home and helper selections. The model
picker shows Codex once; models such as Astra are unchanged. Removal restores the
recorded original provider configuration. First-time setup requires T3 to be
closed because T3 can tear down sessions when provider configuration changes.

`-MakeDefault` verifies helper model mappings and supplies an explicit mapped
helper model when absent; `-TextGenerationModel` chooses that model. Existing
helper models are preserved unless explicitly overridden. An explicit distinct
`-TargetProviderId` still supports an opt-in provider for isolated qualification;
in that mode `-MakeDefault` also moves matching default selections. Ordinary
installations need no second provider. Setup does not enable Claude automation
or restart T3.

Optional parameters: `-SettingsPath`, `-IntegrationDirectory`, `-CodexExecutable`,
`-NodeExecutable`, `-ProviderId` (source) and `-TargetProviderId` (defaults to source).
For an existing integration, `-Operation defaults` applies helper routing without
rebuilding the provider or interrupting chats. Removal restores the recorded
helper defaults only if they remain unchanged, including originally absent fields.
Custom launch arguments and shadow homes require manual reconciliation before
installation. No Developer Mode, symlink or administrator privilege is needed.

For a [Local Delivery](delivery.md) installation, keep the integration directly
under `<installation>/integrations/<name>` (the default is `t3-codex`). Existing
owned integrations there are enrolled when the next release activates. New
installations enroll during setup. New provider processes resolve the same
verified `current.json` release as HotPl8; active processes keep their loaded
code until T3 closes them. No update kills a chat, swaps accounts mid-turn or
rewrites T3 settings. The next ordinary title/helper process also adopts the
current release. An idle but long-lived app-server may remain old until restarted.

Standalone integrations outside that inventory retain a pinned snapshot and
report `unmanaged`. They require deliberate installation upgrades. The native
launcher is retained; an incompatible launcher change blocks automatic promotion
until its migration is qualified. State, credentials and retained releases are
never rolled back with code.

`hotpl8 delivery` reports each registered bridge's desired, installed, next-launch
and observed running SHAs. `restart-pending` means older processes are alive;
`running-version-unknown` includes sessions launched before process receipts were
introduced. Neither is evidence that a chat has loaded the fix. Health verifies
the selected bridge module and package hashes without native login or inference.
It continues on timer checks even when main has not advanced. Removed providers
are not reinstalled; a missing registered integration cannot report healthy.

### Existing two-provider installations

Earlier setups created `hotpl8-codex`. Automatic delivery updates that bridge but
preserves its provider ID because T3 stores it on conversations. Do not delete or
disable it while conversations reference it. Consolidation requires routing the
original Codex provider in place, moving the old selections through T3's supported
model-selection operation while those threads are idle, and then removing the
unused instance. Preserve model/options, projects, helpers and native resume
identity; do not rewrite T3's event database. This release fixes new installations
and automatic code delivery; it does not perform that separate conversation
migration on existing two-provider installations.

Close T3 (including any separately started T3 server) before removal:

```powershell
.\setup-t3.ps1 -Operation remove -StateDirectory C:\HotPl8State
```

Removal rejects edits to the installed provider rather than overwriting them. It
restores the original provider for in-place installs. For a separately added
instance, it removes that instance and restores only unchanged installed defaults;
move its thread selections back before removal.

## Account lifecycle

1. T3 starts the native launcher with its original argument boundaries and pipes.
2. The bridge starts Codex against T3's existing shared home, forcing ephemeral
   credential storage. It validates the effective provider/transport configuration.
3. A private PowerShell broker reuses HotPl8's selectors, reserves, critical policy,
   holds, model-to-meter mapping, freshness checks and canonical identity bindings.
   It validates the selected home through native account/quota reads. A newly
   exhausted candidate is excluded and another fresh eligible candidate can win.
   Concurrent title helpers and chat sessions may briefly contend for the same
   native account lock. Admission waits up to 2.5 seconds per candidate, within
   a shared validation deadline, before reporting prolonged contention.
4. Only the access token and account ID travel through private pipes to Codex's
   external-token login. Refresh tokens stay in their native homes. Neither
   tokens nor raw provider errors appear in HotPl8 status, logs or diagnostics.
5. New turns validate and select again. Active follow-ups with unchanged model
   and working directory pass directly to native Codex, retaining its turn ID.
   Collector publications and native quota notifications also trigger validation
   during ongoing work. A validated alternative can be adopted for later model
   requests without replaying the turn. Existing native requests finish under
   their original account; native owns WebSocket reconnection and continuation.
   Account changes serialize independently of follow-ups, steering, interrupts,
   approvals and tool replies. Observed active child models participate in selection.
6. An external-token refresh request is answered only for the matching account.
   Native Codex refreshes that canonical home under HotPl8's per-home lock. A
   failed refresh or changed identity fails closed; it never refreshes another
   account into an active turn.
7. Stateless `exec` helpers use the selected canonical home with managed native
   authentication, preserving stdin, output files, model/options and exit status.
   Their account home's configuration applies. These helpers do not resume chats.

Authentication files are never copied, overwritten or symlinked. Native Codex
still owns ordinary session/database writes in the shared home. Billing/API-key,
custom transport, unknown model mappings and missing quota evidence are rejected.
Keyring-only accounts are not supported by this adapter. Native enrollment remains
the place to sign in/out; account mutations and credit redemption through the
managed T3 provider are intentionally unavailable.

Selecting a provider or sending a new turn is a deliberate launch, like
`hotpl8 codex`. Monitor mode and automation pauses do not block these explicit
launches. A selection hold still constrains which account can be selected.
Enabling the bridge also enables these policy checks throughout admitted work;
collector monitor mode does not pin an admitted task for its entire lifetime.

## Errors and recovery

Errors have fixed `routing_*` codes. `routing_stale` means refresh the collector;
`routing_model_unknown` requires a verified model-meter mapping;
`routing_unavailable` means no validated eligible account was found;
`routing_binding_changed` requires rechecking enrollment;
`routing_refresh_failed` requires native authentication inspection;
Older loaded bridges can still report `routing_busy` for active follow-ups.
Check their running revision; this implementation removes that blanket rejection.
`routing_model_changed` defers a switch when active models change during validation;
`routing_observation_failed` means the collector subscription failed. Native quota
notifications remain an additional wakeup. See the
[rollover design and evidence](plans/t3-active-turn-admission.md).
`routing_account_busy` means another validator held the account lock beyond the
bounded wait; `routing_validation_timeout` means the admission deadline expired.
These failures occur before inference. The broker records only the time and
fixed failure code in HotPl8's bounded `events.jsonl`, never credentials or paths.
See the [concurrent admission repair](plans/t3-concurrent-admission.md).

An account can still run out after admission: reserve headroom cannot cover every
in-flight request, observation delay, explicit hold or exhausted-all condition.
Unsuccessful background selection reports a fixed diagnostic and preserves native
work. The original native failure, if one occurs, is shown once;
the bridge never replays a partially executed prompt or duplicates tool effects.
The next user turn performs a fresh selection. Unknown/unsupported protocol or
command options fail closed, including non-stdio app-server transports.

The dashboard's NEXT LAUNCH remains a collector recommendation, not an assertion
that every open T3 session changed accounts. `setup-t3.ps1 -Operation doctor` checks
the installed connection offline; it does not authenticate or send prompts.

## Qualification

Offline suites exercise production routing and protocol code, a compiled fake
Codex process, the actual launcher/broker pipes, argument escaping, settings
installation/removal and token redaction. Run:

```powershell
node --test tests/test-t3-codex.mjs
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test-t3-routing.ps1
python tests/test_delivery.py
```

Native qualification on 2026-09-19 used T3 0.0.42's installed launch contract and
Codex CLI 0.155.1. External login, account/quota/model reads, a minimal read-only
turn, a resumed turn, structured-output exec and a forced canonical-account
refresh succeeded. A live test seeded an idle app-server with the exhausted
account, then used the production broker for turn admission: the native account
changed and the turn succeeded. The shared authentication file remained
unchanged. This does not establish a multi-day refresh soak, two healthy accounts
alternating successful inference, all future T3/Codex versions or other platforms.
On 2026-09-20, isolated native HTTP and WebSocket probes on 0.155.1 also passed
same-turn A-to-B model-request adoption through the production dispatcher, with
an active follow-up and one tool execution. WebSocket continuation state was
cleared across accounts. These synthetic-account tests do not establish real
billing or exhaustive child/retry races. The linked rollover design records
reproduction steps and the remaining experimental promotion boundaries.

See the [implementation plan](plans/t3-codex-integration.md),
[compatibility](compatibility.md) and the
[official Codex app-server contract](https://learn.chatgpt.com/docs/app-server).
