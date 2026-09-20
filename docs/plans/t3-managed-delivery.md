# T3 bridge adoption through Local Delivery

An installed T3 bridge copied a reviewed snapshot outside HotPl8's managed
release tree. Main delivery advanced the application while the bridge retained
the old routing failure. Package and routing tests passed because neither
exercised upgrading that separate installed copy.

## Implementation

1. Discover owned integrations directly under the installation's `integrations`
   directory. Validate settings ownership and state binding; record membership
   so a missing component cannot silently disappear from readiness.
2. Atomically enroll each in a protocol-1 bootstrap that resolves the existing
   verified current release once at process start. Retain the native launcher,
   T3 provider IDs/settings, account homes, older releases and active processes.
3. Verify package hashes and the bridge export without native authentication or
   inference. Recheck component health even if main has not changed.
4. Record per-process revision/start/heartbeat and report desired, installed,
   next-launch and running revisions separately. Unknown predecessor processes
   and retained older sessions remain visible.
5. Exercise upgrade, retained active work, failed readiness, missing components,
   interruption and recovery through a predecessor adapter unaware of migration.
6. Put lifecycle requirements in contributor/release entry points and link to
   project documentation from the knowledge vault; do not create another updater.

## Provider identity

New installations replace the existing Codex provider's binary path while T3 is
closed. Provider ID, model labels and conversation home remain unchanged; removal
restores the exact original provider. Distinct opt-in instances remain available
only through an explicit target ID.

An existing two-provider installation is a separate migration: older conversations
persist both IDs. Automatic delivery must not remove or disable either, rewrite
event history, or force a running thread onto a new provider. See the migration
boundary in [T3 operations](../t3-integration.md#existing-two-provider-installations).

## Acceptance

- Real delivery runner, package verification, PowerShell adapter, compiled native
  launcher and Node bootstrap select B for new processes while an A process keeps
  responding as A. Fixtures perform no real provider work.
- Corrupt candidate import rolls back via an old adapter; interrupted activation
  restores A; modified release bytes fail closed.
- Missing registered integrations and unreadable receipts fail readiness; removed
  providers stay removed. Unchanged-main checks still validate components.
- Windows short-path aliases and long names identify the same owned integration;
  tests retain original path spelling so deletion cannot hide a registered bridge.
- In-place setup produces one provider and restores original settings on removal.
- Run full offline suites, static checks, package verification and CI. Native
  rollout is the reviewed main-package delivery after merge; tests do not claim
  existing production sessions already loaded the proposed change.
