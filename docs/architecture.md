# Architecture

The terminal app reads a local status snapshot. tick.ps1 owns collection and writes status.json atomically under tick.lock. status.json is canonical; status.txt and status.js are compatibility outputs. Codex observations are native JSON-RPC reads through a child app-server. Claude observations use claude-swap JSON.

| Module | Responsibility |
|---|---|
| common.ps1 | Atomic files, hashes, quoting, bounded Claude processes, native Codex discovery. |
| config.ps1 | Shared state path resolution, policy validation, action switches and legacy defaults. |
| providers/claude.ps1 | Claude eligibility/ranking, opt-in rotation/warming/probes, legacy credential workaround. |
| providers/codex.ps1 | Native transport, quota normalization, independent home binding, recommendations and launch. |
| diagnostics.ps1 | Fixed-code rotating logs and allowlisted offline diagnostics. |
| dashboard.ps1 | Cached terminal rendering, no provider actions. |
| setup-codex.ps1 | Explicit enrollment and optional non-clobbering native hook registration. |
| lifecycle.ps1 and install/uninstall/rollback.ps1 | Owned per-user installation lifecycle. |

Preserve these invariants: stale/unknown limits cannot select automatically; no fabricated reset refill; reserve margins differ from work margins; hysteresis prevents thrash; warming success requires a real successful child exit; recovery uses terminal-scoped run, never a global switch; one native home is not multiple independent subscriptions; resume stays with its owner; parent CODEX_HOME remains unchanged.

Legacy Claude credential cleanup remains a compatibility boundary, not a proven upstream public API. It must be retired or verified with supported upstream behavior before those actions become release-qualified. Historical personal incident notes are archived privately; keep future design evidence sanitized and adjacent to the relevant contract.
