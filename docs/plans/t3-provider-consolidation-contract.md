# T3 provider consolidation: host contract dependency

Status: **bulk provider-ID consolidation deferred; gradual transition supported**.
The approved scope enrolls ordinary `codex` in place and retains the functioning
legacy alias. `setup-t3.ps1 -Operation transition -PlanOnly` inspects that change;
the explicit transition applies it after full host shutdown. This record does
not qualify automatic migration of existing `hotpl8-codex` conversations. The
missing bulk-rebind API does not block the gradual transition release.

## Evidence boundary

Read-only inspection on 2026-09-21 covered installed T3 0.0.42 and upstream
[`pingdotgg/t3code` main at 76cc9b08](https://github.com/pingdotgg/t3code/tree/76cc9b08f19d89012f16d18f47478c4f7b9b0a6f).
GitHub's latest release was
[`v0.0.42`](https://github.com/pingdotgg/t3code/releases/tag/v0.0.42), published
2026-09-16. There was no newer released host to qualify during this inspection.
This finding applies to those inspected versions, not all future versions.

The installed `server.asar` was read in memory, without importing or executing
its server bundle. Its `apps/server/dist/bin.mjs` SHA256 was
`3e47ada88d519451e34f2fc68837674c1a95d4bc514a2d2f87c0401c212ef3d5`.
No live server command, database write, settings edit, authentication operation,
provider start or inference was performed. Source inspection identifies a
contract gap; it is not an executed data-loss test or successful migration test.

## What the supported interface actually does

The public
[`orchestration.dispatchCommand` interface](https://github.com/pingdotgg/t3code/blob/76cc9b08f19d89012f16d18f47478c4f7b9b0a6f/packages/contracts/src/orchestration.ts#L1228)
accepts `thread.meta.update` with `modelSelection`. That command changes the
thread's selection, not its persisted native resume binding. The
[`ProviderCommandReactor`](https://github.com/pingdotgg/t3code/blob/76cc9b08f19d89012f16d18f47478c4f7b9b0a6f/apps/server/src/orchestration/Layers/ProviderCommandReactor.ts#L1780)
does not rebind sessions in response to a selection-only metadata event.

The next ordinary user turn can switch a compatible **live** session using
its active resume cursor. For a stopped session, the reactor starts without an
explicit cursor. The
[`ProviderService.startSession` implementation](https://github.com/pingdotgg/t3code/blob/76cc9b08f19d89012f16d18f47478c4f7b9b0a6f/apps/server/src/provider/Layers/ProviderService.ts#L1438)
checks compatibility across instances but reuses the persisted cursor only when
the persisted and target instance IDs are equal (lines 1458-1462). Thus a
selection-only change does not establish preserved resume after stop/restart.
The old provider must also remain registered for its compatibility lookup.

The public
[`RPC registry`](https://github.com/pingdotgg/t3code/blob/76cc9b08f19d89012f16d18f47478c4f7b9b0a6f/packages/contracts/src/rpc.ts#L297)
does not expose the internal `ProviderService.startSession` method or a
provider-rebind operation. Internal services are not a supported external API.
The alternative
[`agentSessions.import` input](https://github.com/pingdotgg/t3code/blob/76cc9b08f19d89012f16d18f47478c4f7b9b0a6f/packages/contracts/src/agentSessions.ts#L76)
accepts a project and optional expected workspace root, not a target existing
thread and provider instance; it is not a targeted rebind mechanism.

Installed-bundle equivalents provide independent local evidence:

| Code location | Observed behavior |
|---|---|
| `33290-33301`, `76209-76238` | Metadata command accepts and projects model selection. |
| `204085-204088`, `204152` | Selection-only metadata does not cause provider rebinding. |
| `203492-203520` | Live instance switch passes active resume cursor. |
| `203532` | Inactive session start supplies no explicit cursor. |
| `190849-190853` | Cross-instance compatibility lookup requires old instance; persisted cursor reuse requires equal instance IDs. |
| `143906-143920` | Codex continuation identity derives from resolved shared home. |
| `159942-159946` | Changing a provider config closes its existing runtime scope. |
| `76891-76896` | Settled-only stop protects against certain re-engagement races, but is not a rebind command. |

Consequently, changing all selections and then deleting the alias is unsafe to
qualify. Keeping history visible in T3 is insufficient evidence that native
conversation continuation is preserved. Sending a real prompt just to force
rebinding would violate the migration's no-inference requirement.

## Smallest required host capability

Obtain a supported T3 release with a recoverable provider-rebind operation.
An operation named `thread.provider.rebind` would be one possible design, **not
an existing API**. It needs:

1. A stable command ID, thread ID, expected old instance/binding revision and
   target instance; capability/version discovery and a read-only result query.
2. Admission serialization with turn start and provider configuration changes.
   Refuse active turns, pending approvals/tool replies and queued input under
   that same boundary, not from a prior idle snapshot.
3. Driver and continuation-home compatibility checks while both instances exist.
4. Preserve native resume cursor, runtime payload/mode, model/options, workspace,
   history and archive state while updating both persisted binding and thread
   selection. The host owns these state changes. No inference is necessary.
5. Recoverable commit semantics: crash or lost response must not leave a
   successful-looking selection with an old or lost binding. Repeated command
   IDs return the recorded outcome; authoritative reread proves completion.
6. An authoritative reference inventory covering persisted bindings and archived
   threads, so removal can prove the old instance is unused.

Likely upstream change sites are the orchestration command/event contracts,
command decision and projection handling, `ProviderCommandReactor`,
`ProviderService` and `ProviderSessionDirectory`, with host integration tests.
A same-continuation-key cursor fallback in `startSession` would address one
resume defect, but alone would not provide no-inference migration, atomic
reference changes or safe provider deletion.

Upstream contribution/deployment is a separate dependency. No issue or PR was
submitted by this inspection. Do not patch installed ASAR files, edit SQLite or
invoke unpublished internal services to simulate the missing operation.

## Qualification required before enabling consolidation

Use an isolated T3 host with synthetic conversation homes, fake provider
credentials and a provider fixture that records native thread identity. Prove:

- Live-idle, stopped, host-restarted and archived conversations all retain the
  same native resume identity after rebind, a second host restart and reopen.
- Migration itself makes zero model requests and performs zero tools. Native
  resume operations, if required by the host, are recorded separately.
- Concurrent new turns, queued input, approvals and setting changes cannot race
  the preconditions. Incompatible homes/drivers and stale expected revisions
  are rejected without partial changes.
- Crash before commit, after commit but before response, and before HotPl8's
  receipt write can all be retried without duplicate mutation or lost cursor.
- Alias removal remains blocked until all host references and running processes
  are gone. A partial migration keeps both provider paths operational.
- Supported rollback, uninstall and reinstall preserve migrated identities and
  do not resurrect invalid defaults or duplicate providers.

Until this evidence exists, use managed ordinary `codex` plus a retained
functioning legacy alias. Diagnostics report `ordinary-managed/legacy-retained`,
never migrated. This supports gradual transition without bulk rebinding.
Bulk rebinding and retirement remain a separate future operation. Users may
change a compatible live-idle conversation's picker and verify continuation;
leave stopped/archived conversations on their existing entry when resume
preservation is not established. Do not send a prompt merely to force migration.
