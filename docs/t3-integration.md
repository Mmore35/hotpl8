# T3 Code and Codex account routing

The optional **HotPl8 Codex** provider makes T3 consume HotPl8's account policy.
It supports T3's stdio app-server sessions, account/model probes and stateless
`codex exec` helpers. Windows, Node 22+, independently enrolled file-backed native
Codex homes and a running HotPl8 collector are required. It is experimental;
the external-token API is an experimental Codex interface.

## Install and remove

From a reviewed source checkout or extracted release:

```powershell
.\setup-t3.ps1 -Operation install -StateDirectory C:\HotPl8State -MakeDefault
.\setup-t3.ps1 -Operation doctor -StateDirectory C:\HotPl8State
```

Setup clones the existing `codex` provider into a new `hotpl8-codex` instance named
**HotPl8 Codex**. `-MakeDefault` changes the default only if it currently selects
the source provider; it preserves model and reasoning options. It also routes
title/branch/commit helpers previously assigned to that Codex provider through
HotPl8. An absent helper selection uses the chosen chat model with low reasoning;
an explicit helper model is preserved. Every helper model must have a verified
quota mapping; supply `-TextGenerationModel` to choose a mapped model explicitly.
Selections belonging to other providers are preserved. Existing project
defaults and threads keep their existing selections. Select **HotPl8 Codex** in
those threads to opt in. T3 identifies continuation by the shared home, so the
native conversation remains in the same location.

The original provider is untouched: T3 tears down a provider's sessions when its
configuration changes. Adding a distinct provider avoids that interruption.
Setup does not restart T3 or enable the collector's Claude automation.

Optional parameters: `-SettingsPath`, `-IntegrationDirectory`, `-CodexExecutable`,
`-NodeExecutable`, `-ProviderId` (source) and `-TargetProviderId` (new instance).
For an existing integration, `-Operation defaults` applies helper routing without
rebuilding the provider or interrupting chats. Removal restores the recorded
helper defaults only if they remain unchanged, including originally absent fields.
Custom launch arguments and shadow homes require manual reconciliation before
installation. No Developer Mode, symlink or administrator privilege is needed.

Setup pins a complete copy of the reviewed application files under the integration
directory, compiles an argument-preserving native launcher and records a receipt.
Working-tree edits and ordinary HotPl8 updates do not change that running adapter.
Upgrade deliberately: close T3, remove the old instance, then install the reviewed
new revision into a new integration directory. Retained code is not deleted.

Close T3 (including any separately started T3 server) before removal:

```powershell
.\setup-t3.ps1 -Operation remove -StateDirectory C:\HotPl8State
```

Removal rejects edits to the installed provider rather than overwriting them. It
preserves other provider settings and restores the prior default only if the
installed default is still unchanged. Sessions previously selected on the removed
instance need their provider changed back to the original Codex instance.

## Account lifecycle

1. T3 starts the native launcher with its original argument boundaries and pipes.
2. The bridge starts Codex against T3's existing shared home, forcing ephemeral
   credential storage. It validates the effective provider/transport configuration.
3. A private PowerShell broker reuses HotPl8's selectors, reserves, critical policy,
   holds, model-to-meter mapping, freshness checks and canonical identity bindings.
   It validates the selected home through native account/quota reads. A newly
   exhausted candidate is excluded and another fresh eligible candidate can win.
4. Only the access token and account ID travel through private pipes to Codex's
   external-token login. Refresh tokens stay in their native homes. Neither
   tokens nor raw provider errors appear in HotPl8 status, logs or diagnostics.
5. Before each new `turn/start`, the broker validates and selects again. The same
   thread ID and conversation home are retained. A running turn, including an
   observed child turn, pins the account. Concurrent starts are rejected as busy;
   steering, interrupts, approvals and tool responses continue to pass through.
6. An external-token refresh request is answered only for the pinned account.
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

## Errors and recovery

Errors have fixed `routing_*` codes. `routing_stale` means refresh the collector;
`routing_model_unknown` requires a verified model-meter mapping;
`routing_unavailable` means no validated eligible account was found;
`routing_binding_changed` requires rechecking enrollment;
`routing_refresh_failed` requires native authentication inspection;
`routing_busy` means wait for the current parent/child turn to finish.

An account can run out after admission. The original failure is shown once;
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
```

Native qualification on 2026-09-19 used T3 0.0.42's installed launch contract and
Codex CLI 0.155.1. External login, account/quota/model reads, a minimal read-only
turn, a resumed turn, structured-output exec and a forced canonical-account
refresh succeeded. A live test seeded an idle app-server with the exhausted
account, then used the production broker for turn admission: the native account
changed and the turn succeeded. The shared authentication file remained
unchanged. This does not establish a multi-day refresh soak, two healthy accounts
alternating successful inference, all future T3/Codex versions or other platforms.
Quota exhaustion/fallback, active-turn pinning and refresh failures have offline
regression coverage; promotion requires corresponding native observations.

See the [implementation plan](plans/t3-codex-integration.md),
[compatibility](compatibility.md) and the
[official Codex app-server contract](https://learn.chatgpt.com/docs/app-server).
