# Follow-ups and proactive rollover during ongoing work

Implementation candidate, 2026-09-20. Native transport qualification: Codex CLI
0.155.1; T3 input contract: installed 0.0.42. This replaces the earlier
containment-only proposal to pin an account for the entire active turn.

## Problem and outcome

T3 sends follow-ups using native `turn/start`. Codex accepts an overlapping start
as input to the existing turn and returns that turn's ID. HotPl8 previously
rejected every start while any parent or child was active with `routing_busy`.
It also selected only between turns, so a long task could exhaust its account
while another enrolled account had capacity.

The bridge now lets ordinary active follow-ups reach native Codex immediately.
It subscribes to the existing collector's atomic state publications and treats
native quota notifications as additional wakeups. Its private broker reuses the
same eligibility, reserve, critical, hold and ranking policy as launch admission.
A validated alternative can replace the process's external authentication while
work continues. The bridge never resubmits user turns or tool results.

## Native mechanism and ownership

`account/login/start` with `chatgptAuthTokens` updates native process authentication.
Codex resolves that authentication when preparing later model requests. An already
prepared or in-flight request retains its original account. On a later WebSocket
request, native Codex reconnects for the changed account, removes the old account's
continuation ID/state, and reconstructs model input from conversation history.
Including an existing tool result in that history does not execute the tool again.

Account changes are serialized separately from user input. Healthy selections of
the same account do not trigger another login. A login acknowledgement updates the
bridge's selected identity; it is not per-request billing telemetry. Native remains
responsible for request adoption and retries. An ambiguous login timeout closes
the provider rather than continuing with an unknown authentication owner.

Authentication belongs to the app-server process, including its native children.
The broker checks all observed active models against their mapped meters before
switching. Native `thread/started` and response snapshots supply configured models;
`thread/read` resolves unknown loaded children. `model/rerouted` adds the observed
per-turn model without changing the next turn's configured model. Missing metadata
or a new unvalidated model defers switching with a fixed diagnostic. A child can
start before its metadata notification; the protocol supplies no host callback
that can admit each child model request. This is not a per-request quota firewall.

Pending RPC reservations and actual active turn IDs are distinct. A rejected
follow-up cannot clear a running turn. A late completion cannot clear a newer turn.
Steering, interrupts, approval replies and tool replies bypass quota work. Normal
follow-ups with unchanged model and working directory bypass admission too;
changed settings and new turns receive ordinary validation.

Refresh remains identity-bound. A refresh for an old account cannot replace a
new account's authentication. Access tokens remain in private pipes and memory;
canonical homes and refresh tokens stay with the native provider. The first-party
`openai_base_url` override is rejected along with custom provider transports.

## Shared Claude/Codex behavior

| Scenario | Common expectation | Provider-specific mechanism |
|---|---|---|
| New input during work | Preserve native conversation/input semantics | Claude SDK input queue; Codex overlapping `turn/start` |
| Eligible account approaches its reserve | Apply existing account policy while work continues | Claude uses cswap's native credential update; Codex uses external-token login |
| Another account has capacity | Later requests can adopt it without restarting the task | Native clients own credential adoption and connections |
| No eligible alternative, hold, or unknown quota | Report the limitation truthfully; do not invent capacity | Existing provider eligibility and diagnostics |
| Work already executed | Never replay effects to force a switch | Native history and tool ownership remain intact |

The Claude comparison describes the existing integration contract and historical
observations, not a new exhaustive Claude intra-turn qualification. It does not
justify introducing another Claude bridge or a shared authentication implementation.
Common policy and observable behavior are shared; transport ownership stays native.

## Qualification evidence

The opt-in [native probe](../../tests/probe-codex-rollover.py), with its
[dispatcher companion](../../tests/t3-native-rollover.mjs), uses an isolated home,
synthetic JWTs and a localhost Responses service. It never uses a real credential
or paid model endpoint. It holds the first response open, appends a follow-up,
changes accounts, returns one dynamic tool call and lets native finish the turn.

| Observation | HTTP | WebSocket |
|---|---|---|
| First/next model-request identities | A / B | A / B |
| Follow-up returns original turn ID | Pass | Pass |
| Follow-up present in subsequent model input | Pass | Pass |
| Started/completed turns | 1 / 1 | 1 / 1 |
| Dynamic tool executions | 1 | 1 |
| Old account continuation ID on B | Absent | Absent |
| Old account turn-state header on B | Absent | Absent |
| Final status, same turn | completed | completed |

Both raw native external login and the production `CodexBridge` dispatcher passed.
The dispatcher test injects a synthetic broker; the Windows integration suite
separately exercises the real installed launcher, broker and collector publication.
Native schema generation for 0.155.1 confirms `Thread.model` is available but nullable.

Upstream source at commit `88ef37c64974e1209411f6d449b0db942b3eb731` supports the
observed mechanism: `responses_websocket_reconnects_after_account_switch` tests
same-session adoption and context reconstruction. `current_client_setup` rejects
an ownership change during preparation before submitting that request; the native
sampling loop classifies that I/O error as retryable within its existing budget.
This source inspection does not claim the synthetic test deterministically induced
that narrow setup race in the installed binary.

Run the opt-in qualification against a reviewed installed binary and an existing
scratch directory, once for each transport:

```powershell
python tests/probe-codex-rollover.py --codex C:/Tools/codex.exe --scratch C:/FixtureScratch --bridge --transport websocket
python tests/probe-codex-rollover.py --codex C:/Tools/codex.exe --scratch C:/FixtureScratch --bridge --transport http
```

The normal offline suites cover selection above/below the existing margin,
no-capacity/unknown-meter/hold outcomes, native lock contention, collector-driven
rollover in a live fixture process, active follow-ups, child model accounting,
late completions, shutdown and redaction. Existing delivery regressions exercise
prior-install upgrade, old active processes, fresh-process adoption and rollback.

## Limits and delivery

Proactive selection uses reserve headroom; it cannot promise zero limit errors.
Collector latency, an unusually large in-flight request, concurrent native work,
an explicit hold, emergency drain-to-zero policy, unknown readings or exhaustion
of every eligible account can still reach a provider limit. The bridge preserves
the native failure and does not replay an ambiguously executed request.

Synthetic transport evidence establishes actual request identity and continuation
behavior, not real subscription billing, a multi-day refresh soak or every native
child/reroute race. Independent-account live inference and broader native-version
qualification remain explicit promotion requirements for this experimental adapter.

This changes an existing managed component. Verified Local Delivery packages carry
the bridge and broker; new provider processes adopt the selected immutable release.
Running processes retain their loaded version. A checkout or merged commit alone
is not evidence that an open chat received the fix. The existing release pointer
is the update and rollback owner; no new daemon, scheduler or installation path
is introduced. See [delivery](../delivery.md#component-lifecycle).
