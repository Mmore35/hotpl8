# Model-independent Codex account selection

HotPl8 must not require a registration or release when a native model name changes.
Account policy belongs to HotPl8; model selection and entitlement belong to native
Codex. An unknown model used to fail locally with `routing_model_unknown`, before
Codex could decide whether it was valid.

## Implementation

- The broker, CLI and cached readiness select on the configured `defaultMeter`,
  normally `codex`. They do not look up or intersect model-to-meter mappings.
- The T3 bridge forwards model/options unchanged, including absent/null choices.
  Native errors are forwarded once. There is no replacement model, retry or replay.
- Helper setup uses the explicit native helper selection or T3's native default.
  It does not check a HotPl8 model catalog. CLI model omission lets native resolve
  its default rather than injecting a cached model.
- Fresh quota validation, identity/binding checks, margins, reserves, ordering,
  holds, pauses and transport restrictions remain. Cached readiness stays local.
- Active turns, children and pending admissions still prevent account changes.
  Queued background observations do nothing once work drains. Child model discovery
  solely for quota selection is removed; activity tracking remains.

No inference is sent to test model availability. A successful account quota check
cannot guarantee model entitlement or remote acceptance after the observation.
Native remains responsible for plan, workspace and model restrictions. Undisclosed
special allowances cannot establish the best account without an authoritative
provider contract. HotPl8 does not infer those from model names.

## Compatibility and migration

New policies need no `modelMeters`. Existing objects are accepted as deprecated,
inert data and preserved on unrelated writes; per-model meter selection is retired.
Structural bounds remain. An explicitly configured nondefault `defaultMeter` is
preserved, including its existing failure behavior when evidence is unavailable.
Legacy setup `-Model` remains accepted and explains that registration is unnecessary.
`-Meter` retains its account-basis meaning. Explicit CLI `-Slot` still validates
the owning home and intentionally bypasses automatic quota eligibility.

The quota decoder and billing behavior are unchanged. In native Codex 0.155.1 and
0.160.0, additional pools have null spend-control evidence. The existing decoder
marks those `constraint_unknown`; a fixture inventing `spendControlReached:false`
does not prove an additional pool supported automatic selection in production.
The [pinned native conversion](https://github.com/openai/codex/blob/a956835d020762cb2b570053af06f643a11c0ecc/codex-rs/backend-client/src/client.rs#L640)
passes no spend-control value for an additional pool.
Neither the old map nor this change guarantees included-only spending.

Managed installations adopt the current bridge on new processes. Existing loaded
processes keep their version until normal closure; do not terminate work to force
adoption. Check the component's running revision separately from installed code.
Rollback restores the older code's mapping requirement. Retain the prior policy;
no account credential or conversation migration is needed.

## Verification

The existing suites cover unfamiliar model passthrough, omitted defaults, native
errors once, child/pending ownership, queued completion, helper exec, setup and
removal, legacy maps, account policy and token redaction. Windows integration uses
the real launchers and pipes with a compiled synthetic native process.

Investigation also compared 1,200 broker/CLI decisions across 200 combinations of
account ordering, reserve status and quota levels against the prior known-model
behavior. Eight isolated loopback cases exercised installed native Codex 0.160.0
with synthetic credentials and no real inference: ordinary and additional quota,
exhaustion, nullable ordinary permission, future pool/window and identity mismatch.
These probes establish protocol behavior, not future entitlements or real billing.

Run `scripts/check.ps1`, `scripts/test.ps1`, and the existing Windows/Mac CI jobs
on the final candidate. The pinned fictional dashboard preview checks presentation
and interaction; it does not exercise live account routing.
