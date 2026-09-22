# Shared provider decisions and configuration-first enrollment

Status: implemented shared production decisions, registry-driven consumers and gradual T3 transition. Native synthetic rollover is qualified on Codex CLI 0.155.1; automatic bulk conversation migration remains deferred.

## Behavior

Users choose ordinary Claude or Codex in their host. Account selection and qualified ongoing rollover happen behind that entry. Both providers use common eligibility, reserves, ranking, controls and decision explanations. Their native authentication and conversation protocols remain separate adapter responsibilities.

Adding a provider with a supported driver should require one validated definition and account enrollment. Collector scheduling, setup, dashboard sections, CLI/API/MCP provider validation and delivery inventory must discover that definition. A genuinely new native protocol requires one adapter and its conformance tests, not another policy engine.

## Architecture

1. Thin native adapters decode quota, identity, window applicability and native capabilities.
2. One normalized account/policy contract preserves original observation times, required versus non-applicable windows and model scopes.
3. One pure decision function owns eligibility, margins, reserve/degraded tiers, reset interpretation, ranking, churn protection and critical selection.
4. Shared action controls and generation checks authorize a re-evaluated proposal at a short locked boundary. Native adapters apply it and record the confirmed outcome in their ownership scope.
5. Cached views consume the same decisions. They never perform native reads or turn a proposal into a confirmed binding.

Keep the existing PowerShell runtime and shared window, capacity, critical, automation and collection helpers. The T3 JavaScript bridge owns framing, input/control delivery, active scope tracking and native request correlation; it must not implement a second ranking algorithm.

Provider definitions select reviewed shipped drivers. They cannot contain executable expressions, arbitrary modules or commands, or claim capabilities absent from the driver. Discovery is read-only; enrollment does not infer credentials or enable automatic spending. A HotPl8 descriptor cannot add an unsupported native driver to a host application.

## Deliberate common-policy changes

Two existing selector divergences were reproduced with equivalent in-memory observations:

- With an active account at 6% weekly headroom, an alternative at 16%, both at 90% short-window headroom and a later alternative short reset, Claude retains the active account while Codex chooses the alternative.
- In preference mode, an active reserve account and a work alternative at 30% short headroom, with a 25% floor and 10% hysteresis, cause Claude to retain reserve while Codex returns to work.

The common rule applies ordinary churn protection only among comparable healthy peers. Better work/reserve or health tiers bypass it; strictly better degraded weekly headroom can win, while equal degraded headroom retains an eligible current account. Critical-mode dwell remains distinct. Unknown or exhausted quota never becomes eligible through a zero floor or a hold.

## Action and ownership contract

| Intent | Behavior |
|---|---|
| Cached observation | Pure, no account action or state write |
| Explicit admission | Eligible native-validated launch remains available in monitor/pause mode; explicit pins are manual choices |
| Autonomous rebinding | Requires enabled automation, no pause and no hold; intersects all active model scopes |
| Follow-up/control delivery | Preserve native semantics and responsiveness; no blanket busy rejection or tool replay |
| Same-account refresh | Requires known pinned identity; cannot choose another account |
| Warm/probe | Common controls/budgets/receipts; capability-dependent native operation |

A hold needs actual binding evidence, not the collector's next-launch recommendation. Unknown held binding defers selection. Critical dwell belongs to the actual action scope: global Claude activation and each Codex app-server process do not share one fictitious active account.

Serialize apply per native ownership scope. Validate controls at a documented short authorization boundary; changes after admission govern subsequent actions. Native timeouts can leave an ambiguous result: reconcile binding through supported observation rather than assuming the old identity or repeating work. Preserve existing locks and bounded deadlines without holding a global collector lock through unbounded native I/O.

## Compatibility and rollout

Legacy policies retain their defaults. The generic v3 provider map supports explicit migration preview, atomic writes, conflict rejection and version-preserving account edits. Incompatible rollback targets must pass their own state validation before replacing the current reader. Existing v1/v2 installations need no rewrite merely to load the refactor.

Keep existing public entrypoint paths, status mirrors and agent API meanings. New provider collections and context evidence must not silently redefine next-launch recommendations as live-session binding. Old immutable processes can coexist with new releases; installed version is not proof of adoption.

T3 transition manages the ordinary Codex entry alongside the retained legacy alias, using separate setup receipts and shared settings transactions. Existing conversations may stay on the alias or be changed manually through the picker and checked for continuation. Setup never changes conversation data or deletes the alias automatically. See [T3 setup](../t3-integration.md).

## Qualification gates

- Core fixtures: fixed-clock expected outcomes, provider-label invariance, all ranking modes, required/optional windows, stale/future/expired observations, holds/pauses and critical-state ownership.
- Full third-provider acceptance: only a descriptor and enrollment config may be added for a supported driver; collector, setup, policy, UI, CLI/API/MCP, controls and delivery must work without consumer source edits. Registry-only tests are insufficient.
- Native rollover: separately run the HTTP/WebSocket synthetic native probe; verify outgoing A-to-B account identity, same turn and one tool execution. Also qualify the full real policy/broker/bridge chain rather than substituting the broker alone.
- Gradual T3 transition: read-only preview, closed-host checks, separate receipts, preserved defaults/options, settings conflict detection, interrupted recovery and independent removal. Full consolidation remains a separate host-contract gate.
- Delivery: test old/new process overlap, prior-install upgrade, failed activation, partial migration recovery and uninstall/reinstall without dangling provider references. Never roll back credentials or conversation data.

## Deferred full consolidation

The installed T3 contract does not provide a demonstrated atomic no-inference provider rebind for stopped sessions. Changing model-selection metadata alone does not move the persisted runtime binding. The exact qualification result and required host contract are recorded in [T3 consolidation prerequisite](t3-provider-consolidation-contract.md).

Until that dependency is resolved, the old alias remains functional. Shared decisions and ordinary-entry routing do not depend on bulk rebinding. Changing a picker selection is not evidence that every dormant or archived thread can resume safely under a different provider ID.

## Qualification evidence

Offline suites exercise both production decoders, shared decisions and action controls, native-failure paths, all cached consumers, policy migration and delivery recovery. An isolated package adds a fictional third registration using a shipped driver and enrollment config, then exercises real collection, enrollment, CLI, dashboard/tray, API/MCP and diagnostics without editing consumer source.

The optional native probe exercises both HTTP and WebSocket with synthetic local accounts on Codex CLI 0.155.1. The policy-broker variant runs the real decision/broker/bridge/native chain, verifies A-to-B request identity, preserves the same turn and follow-up, and observes exactly one tool execution. It does not prove real subscription billing or multi-day token refresh. [Compatibility limits](../compatibility.md).
