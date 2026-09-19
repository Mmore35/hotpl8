# Compatibility and evidence

| Surface | Candidate status |
|---|---|
| Windows PowerShell 5.1 | Primary runtime; offline tests exercise CLI, dashboard, fake providers, and isolated lifecycle. |
| PowerShell 7 / Mac / Linux | Not release-qualified. Source experimentation only; full native fake tests currently target .NET Framework/Windows. |
| Claude inventory | Via separately installed claude-swap; package metadata floor in prior implementation was 0.25.0, with 0.26.0 documented during development. Revalidate upstream contracts before promotion. |
| Claude switching/warming/probes | Experimental; off in new policy. Legacy configs preserve enabled behavior. No guarantee that prompts open a useful quota window. |
| Codex | Native app-server API; prior live evidence used CLI 0.153.4. This candidate's offline fixture tests do not expand that live evidence. |
| Codex meters/windows | codex and codex_bengalfox; 300/10080-minute windows. Unknown shapes/constraints block automatic use. |
| Codex model selection | Requires an explicitly verified modelMeters mapping. Explicit-slot launch is separate from a quota guarantee. |
| Codex warming | Unavailable after the conditional native investigation; see the [evidence gate](plans/codex-warming.md). |
| Multi-account live routing / native refresh contention | Offline mechanics covered; release acceptance still pending with independent native accounts. |
| T3 Code | Optional Windows adapter; native Codex 0.155.1 probes and read-only first/resumed turns qualified. Multi-day refresh and multi-account inference promotion remain pending. [Scope and setup](t3-integration.md). |
| Other desktop / IDE clients | Not claimed. |

The [official app-server contract](https://learn.chatgpt.com/docs/app-server) can evolve. Passing fixture tests is not proof of behavior on an untested native CLI or subscription plan. Never widen quota eligibility merely because a required field is missing. Provider permission review remains independent of technical compatibility.

## Provider boundaries

Each user signs into the native provider tools under their own agreement. HotPl8 does not supply subscriptions, redistribute provider binaries, or offer a hosted sign-in service.

Anthropic's [authentication and credential-use rules](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use) distinguish native Claude Code sign-in from third-party credential intermediation. The claude-swap adapter and its legacy credential cleanup have not been established as an approved integration. Labeling the adapter experimental or releasing this code under MIT does not change those rules. Treat Claude automation as an unresolved integration, not an endorsed or stable capability.

Publishing this source preview does not claim completed live refresh-concurrency, independent-account, reboot/sleep, or long-running scheduler qualification. Those checks belong to promotion of the corresponding feature to stable support.

The 0.2 operations candidate retains these qualification limits. The optional Windows tray has offline model/event coverage; interactive desktop and resource qualification are still required. [Delivery status](plans/subscription-roadmap.md) separates implemented features from native evidence, and the [Mac handoff](plans/macos-handoff.md) defines the native implementation work.
