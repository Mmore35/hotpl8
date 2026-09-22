# Adding a registered provider

Provider definitions live in `data/providers/`. They select a reviewed native
driver; they are not executable plugins. Adding a compatible definition and
enrolling its accounts does not require changing collector, selection, dashboard,
CLI, agent API or MCP provider lists.

Copy the [Codex definition](../data/providers/codex.json), assign a unique lowercase
`id` and filename, set its display `name` and `display.order`, and retain only
capabilities and meters supported by that driver. The automated fixture uses
`fictional.json`, ID `fictional`, name `Fictional`, and display order 30. This is
a second registration of the existing native contract, not proof that an unrelated
service supports that protocol or authentication model.

Every definition is validated by
[the registry](../src/provider-registry.ps1). Unknown fields, executable paths,
unsupported driver IDs, changed window applicability and overstated capabilities
are rejected. `integrations.native` identifies the native adapter family;
`integrations.t3` is the host's exact driver identifier (`claudeAgent` or `codex`).
A compatible host driver is not evidence that this registration is enrolled in
the host. T3 setup and live-session adoption require their own supported boundary.

## Enrollment and ownership

Use `hotpl8 setup` to discover available registrations. Native-home drivers use:

```powershell
hotpl8 enroll -Provider fictional -Slot work -AccountHome C:\Accounts\fictional
```

An installation using legacy policy receives a migration preview first. Repeat
with `-MigratePolicy` to accept policy version 3 after reviewing that preview.
Migration retains existing action settings and homes. Existing v1/v2 installations
remain readable without rewriting their policy. Account edits preserve v3 and
unrelated registrations. An older reader cannot safely load v3 and must reject
downgrade before replacing the working installation.

Version 3 stores native-driver policy parts under `providers.<registered-id>` and
keeps mode, automation pauses, work schedules and other shared controls at the
root. Do not mix the map with legacy root Claude or nested Codex policy fields.
New registrations do not grant automatic spending. A missing work-account weekly
margin inherits the ordinary weekly floor rather than inventing a lower floor.

Native ownership is a driver constraint. A native home cannot belong to two
registrations, and enrollment checks subscription identity across registrations
using the same driver. Collector evidence identifying the same subscription in
two registrations makes those observations unavailable. The global Claude account
activation driver has one configured owner per installation; aliases cannot
create independent global activation histories. Codex registrations with distinct
homes keep private cache/state under their registration namespace. Installation
pause/hold controls remain shared.

## Qualification and packaging

Run the conformance and isolated end-to-end fixture:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test-provider-registration.ps1
```

It copies the product into a temporary package, adds the fictional descriptor,
enrolls synthetic accounts, and exercises collection, ranking, CLI, dashboard,
API/MCP discovery, pause/hold, account changes and diagnostics. Native reads are
synthetic and no real credential homes or model service are used. Run the full
suite and static checks before publishing; extend fixtures for any new contract.

Add the reviewed descriptor to `release-files.json` so the verified package owns
it. Existing delivery and installer validation must reject a package that drops a
configured registration. Follow [the component lifecycle](delivery.md#component-lifecycle)
for host bridges and [release qualification](release-checklist.md) for native
behavior. Never load a user-supplied script or arbitrary executable from a
definition.

A genuinely new native protocol needs a reviewed driver implementation, quota and
identity decoders, explicit capability/ownership boundaries, native qualification
and shared-core contract tests. It does not need a second selection algorithm.
