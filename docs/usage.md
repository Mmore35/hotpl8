# Commands

| Command | Behavior |
|---|---|
| `hotpl8` / `watch` | Show cached dashboard; no quota calls or prompts. |
| `status` | Print cached readings; warn when the snapshot is stale. |
| `status -AsJson` | Local structured snapshot; may contain private labels. |
| `refresh` | Collect quotas without switching, warming, or recovery prompts. Fail if collection is incomplete. |
| `tick` | Collect and apply actions explicitly allowed by policy; monitoring mode still prevents actions. |
| `doctor -AsJson` | Redacted offline diagnostics. Missing/invalid policy returns nonzero. |
| `version` / `help` | Print installed version / command summary. |
| `enroll -Slot main -AccountHome PATH` | Enroll a signed-in native Codex home; optional `-Label`. Available in current source; rc.1 uses setup-codex.ps1. |
| `init` | Create the default policy (automatic switching and continue on, warming off) without overwriting existing configuration. |
| `continue` | Show whether [automatic continue](plans/automatic-continue.md) is on and whether Claude's hook is present; changes nothing. |
| `continue -Operation disable` / `enable` | Turn automatic continue off or on; the policy setting and Claude's hook change together. |
| `codex -Slot main` | Validate native login and launch in that home. Does not guarantee quota. |
| `codex -Model NATIVE_MODEL` | Select an eligible account and pass the model unchanged to native Codex. |
| `codex -Slot main resume` | Resume within the home that owns the conversation. |

All commands accept `-StateDirectory PATH`. Codex native arguments follow its command; use native Codex directly for authentication/configuration/remote/admin commands HotPl8 cannot validate. HotPl8's JSON-output option is `-AsJson`, intentionally distinct from native Codex `--json`.

Omitting `-Model` leaves model selection to native Codex. Account selection uses
the configured `codex.defaultMeter`; no model registration is needed. Native
model availability remains an account/provider decision.

Q, Escape, and Ctrl+C exit the dashboard. Space **freezes the view**, not the collector or automation. Arrow/Page/Home/End keys scroll. Set `NO_COLOR=1` for uncolored output. Piped dashboard output prints once and exits.

To suspend all automatic actions, set policy mode to monitor. The legacy hold.json lease suppresses switching only, expires automatically, and does not stop warming or probing. Never interpret a hold as a general automation pause.

Doctor prints setup and dependency guidance in human mode. With an enrolled account it also prints one line for automatic continue: on or off, whether Claude's hook is present, and when a continue was last sent. Its `-AsJson` fields and exit status retain the existing contract: exit zero means the policy is valid, not that native login or every quota reading is healthy. The dashboard is a cached view; its timestamp describes the last collection. Use refresh for a new reading or opt into scheduled collection.

## Account operations

The 0.2 source candidate adds `setup [-Interactive]`, `accounts`, `park`/`unpark`, `explain`, `capabilities`, `pause`/`resume`, `history`, `tray`, `update-check` and `update`. See [commands and operational semantics](operations.md) and [verified updates](upgrading.md). These are not present in the older downloadable preview.

## Provider overview

The title bar states whether HotPl8 will switch accounts on its own (`auto-switch on`, `off`, `paused` or `held`, as the collector last applied it) and shows `warming on` only when warming runs. The dashboard opens with one **Available now** bar per provider; account problems appear on each account's own row. Solid fill estimates usable allowance across current limits; the patterned extension shows the first positive refill within 24 hours, with its countdown on the right. A refill further out appears as text without a pattern. Weekly remaining is supporting text; Spark is excluded. Arrow/Page keys scroll account details below the fixed overview; Home/End select the first/last detail page. Space freezes the view only. Resize to at least 48 columns and 15 rows. [Meaning, estimates, unknown readings and reserves](provider-overview.md).

## Capacity and mascot commands

`hotpl8 nyan` runs the same passive dashboard with the bundled terminal Nyan Cat animation. `-ReducedMotion` and `-NoColor` also work with the standard dashboard. `hotpl8 accounts -Operation capacity` configures a subscription profile and relative window capacities; see [capacity and critical mode](capacity.md).

## Agents and MCP

`hotpl8 agent` accepts one v1 JSON request from stdin or `-RequestJson`. `hotpl8 mcp` serves local cached read tools; `-AllowAgentPause` enables independent pause leases. See [agent API](agent-api.md). These commands do not collect quota or launch work.
