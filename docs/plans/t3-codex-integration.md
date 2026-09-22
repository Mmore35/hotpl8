# T3 / Codex integration design and acceptance

Historical initial design. Installation identity and delivery are superseded by
the [managed delivery plan](t3-managed-delivery.md); routing/authentication decisions
below remain the original qualification record.

HotPl8 previously recommended a Codex account only to its own CLI launcher.
T3 independently launched a fixed home; a healthy alternative in HotPl8 could
not help a T3 session pinned to an exhausted subscription.

## Chosen boundary

Use T3's supported configurable binary entrypoint and Codex's external-token
app-server login. A private broker reuses HotPl8's account policy and native
validation; a stdio bridge admits each new turn under that policy. T3 keeps its
existing shared conversation home. Native account homes remain the sole owners
of refresh credentials. Detailed behavior: [integration guide](../t3-integration.md).

| Alternative | Why it does not complete the fix |
|---|---|
| Timer copies selected auth into the default home | Races native refresh, affects unrelated clients and cannot reliably detect the home of every Windows process. |
| Startup-only CODEX_HOME shim | Does not rotate an already-running T3 session and splits conversation/config state across account homes. |
| T3 shadow homes | Require symlink privileges on Windows and fresh overlay directories; do not consume HotPl8 quota policy by themselves. |
| Static multi-instance balancing | Does not establish quota-aware routing, freshness, account binding or safe retry semantics. |
| Monitoring the default home as another slot | Duplicates an identity without changing T3 routing. |

## Delivery components

| Component | Responsibility |
|---|---|
| `src/codex-routing.ps1` | Policy selection, identity/freshness validation, bounded native fallback and pinned refresh. |
| `src/codex-route.ps1` | Internal token-bearing anonymous-pipe broker endpoint; not a public agent operation. |
| `src/t3-codex.mjs` | Stdio protocol lifecycle, per-turn admission, account pinning, refresh correlation, bounded framing and exec routing. |
| `src/t3-launcher.cs` | Windows argv and streaming pipe transport without shell expansion. |
| `setup-t3.ps1` | Add a separate provider, pin code, optional new-chat default, receipt, offline diagnostics and conflict-aware removal. |
| Existing collector | Remains the only scheduled quota collector; no second scheduler or credential-copy loop. |

No upstream T3 patch is needed for these entrypoints. External auth remains
experimental, so this is an opt-in integration with explicit compatibility tests.
T3 mutations that would change login or redeem credits are rejected on this
provider; the original native provider remains available for deliberate management.

## Acceptance matrix

| Scenario | Required result | Evidence |
|---|---|---|
| Exhausted preferred account, healthy alternative | Native validation rejects exhausted candidate; next candidate admitted before inference | Broker and native fake integration tests |
| Stale/malformed/disabled/rebound/duplicate account or unknown model | No inference dispatched | Broker/protocol tests |
| New and resumed conversation | Preserve thread/home; route at next turn boundary | Protocol tests; native read-only first/resumed turns |
| Parent or child turn active | No account switch; control/approval traffic passes | Protocol tests |
| Failure after work began | Surface once; never replay input/tools automatically | Protocol tests |
| External token refresh | Refresh canonical pinned identity only; do not switch on 401 | Broker/protocol tests; long native soak pending |
| T3 account/model probes | Authenticate using eligible subscription and return native protocol | Native 0.155.1 probe qualification |
| T3 stateless exec helper | Eligible canonical home, exact argv/stdin/output/exit; configure T3's independent helper default | Compiled Windows integration test and native structured-output exec |
| Shared auth/config and refresh secrets | No copying or writes by bridge; no secrets in diagnostics | Offline sentinel checks and native before/after hashes |
| Settings install/remove | Original instance and unrelated edits survive; no active provider replacement | Windows setup fixture and installed T3 lifecycle inspection |
| Regression | Static, complete offline, packaging and CI checks | PR validation record |

## Rollout and remaining promotion gates

1. Ship the opt-in adapter and docs together with the tests and release manifest.
2. Install as a separate provider; keep existing sessions on their original
   provider until explicitly switched. Default only new Codex chats when requested.
3. Record native successful routing across two healthy independent accounts,
   including the same conversation after an account change. A seeded exhausted
   native account switching to an eligible account and native exec have passed;
   this does not substitute for two healthy accounts alternating inference.
4. Observe at least 72 hours, including a native external-token refresh, exhausted
   account recovery, sleep/resume, T3 restart and collector recovery. Redact all
   identities, prompts and tokens in published evidence.
5. Verify teardown of child processes, T3 upgrades and configuration conflicts.
   Qualify Node 22 and the packaged Windows runtime in CI. Other platforms remain
   unqualified until equivalent native tests pass.
6. Promote only the cases for which evidence exists. A green fake suite is not
   a native refresh or provider-billing guarantee.

Rollback removes the added provider while T3 is closed. It retains native homes,
conversation state, the original provider and pinned integration files. No token
restore, database migration or scheduler rollback is necessary.
