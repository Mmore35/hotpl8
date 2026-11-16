## Behavior

Describe the problem and resulting behavior.

## Validation

- [ ] Relevant offline tests pass.
- [ ] No native credentials, account data, or private diagnostic output added.
- [ ] User documentation and compatibility claims match the change.

## What changes for you

One or two plain sentences: what the owner will notice, or that nothing visible changes.

## Observed run

- PR URL and exact head SHA:
- Command: `hotpl8 observe pr NUMBER -TrustRevision FULL_SHA -Scenario FILE`
- Scenario: (paste it, or attach `scenario.json`)
- Report: (paste `report.md`; the verdict must be PASS on this head)
- Windows / Mac CI:

To look by hand: `hotpl8 preview pr NUMBER -Live -TrustRevision FULL_SHA`.
See [the PR handoff](../docs/delivery.md#required-pr-handoff) and
[observe scenarios](../docs/observe-scenarios.md), including the bootstrap command
when installed main predates `observe`.
