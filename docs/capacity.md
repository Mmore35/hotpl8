# Capacity, critical mode and motion

HotPl8 has one **Available now** bar per provider. Its solid foreground is estimated usable allowance under current limits and routing policy. The patterned extension is additional allowance at the first confirmed reset that increases availability within 24 hours, assuming no further consumption. Resets still blocked by other limits are skipped. With no positive refill in that horizon, no pattern appears. The clock reaching zero never turns a projection into measured capacity.

The main bar measures the currently usable window: five-hour allowance when present, otherwise the actual weekly-only allowance. Three equal plans at 100%, 100% and 75% show **91.7% now**, with **+8.3%** when the depleted session resets. Weekly remaining is supporting text, not the denominator of that bar.

Weekly and model limits reduce session capacity only after conversion into the same units. For example, if a full week is 1 unit and a full session is 0.3 units, 2% weekly remaining permits at most 0.02 / 0.3 = **6.7% of a session**. Taking the smaller raw percentage is incorrect. Without a verified conversion, known plan session multipliers weight the session estimate; weekly/model limits still block exhausted or policy-ineligible accounts. A positive weekly balance cannot be converted automatically from its percentage alone. At 20% weekly remaining or less, an unconverted limit is labeled **weekly cap uncertain**: actual usable capacity may be lower. These are estimates, not guaranteed prompt or token budgets.

Missing readings or multi-account plan weights remain unknown. Calibrated account weights and plan multipliers are not mixed without a common basis. A paused/held/manual Claude configuration can leave allowance on other accounts outside the solid routed amount. The Codex summary always uses main Codex, excluding Spark; existing sessions retain their native account.

A fresh, explicitly blocked Codex account with a measured zero contributes zero usable allowance and keeps its weight in the total. Forecasts keep that account at zero until a later observation clears the block: a quota reset does not necessarily remove a spend or account restriction. A known refill from another healthy account can still appear, with `projectionComplete: false` indicating that blocked-account recovery is excluded. Stale readings and unknown provider constraints remain unknown.

## Set subscription capacity

Claude plan discovery is automatic during collection: HotPl8 reads each enrolled account through the installed claude-swap Python adapter and verifies its identity against Anthropic's OAuth profile response. Recognized Pro, Max 5x and Max 20x profiles appear in account details and supply the matching catalogue profile unless you explicitly override it. Team/Enterprise and unknown Max tiers retain their labels without inventing a consumer multiplier. Discovery refreshes every 15 minutes; the display allows up to 20 minutes for the next scheduler wake, preventing brief gaps in known plan weights. This grace does not extend usage freshness. Account replacement invalidates the old identity immediately, and failed detection is not treated as a current plan. No separate sign-in, API key or plan questionnaire is needed for supported accounts.

Plan discovery requires the Python interpreter belonging to the native cswap installation (Windows system/venv installs and Unix Python shebangs are recognized). Custom batch adapters can still collect quota but may not supply automatic plan metadata. The profile endpoint and cswap reader are compatibility boundaries, not a stable public billing API. Unsupported schemas remain unknown. HotPl8 does not refresh authentication or copy credentials to recover plan detection.

Native discovery was verified with cswap 0.26.0: schema-v1 inventory includes `email` and `organizationUuid`, which agree with the adapter's `account_identity` reader. Both are required for binding. An older/custom inventory that omits organization identity remains unverified; do not remove the identity check to force a plan label. Unix `env`-style shebang launchers are not yet resolved; qualify that path in the Mac handoff.

Detecting a tier is different from measuring its window capacities. Anthropic publishes session multipliers, but those do not specify the exact weekly-to-five-hour conversion. Automatic detection therefore does not fill unknown weekly or five-hour values with guessed numbers. The quota-headroom estimate remains available; explicit measured conversions take precedence. See [Anthropic's Max limits](https://support.claude.com/en/articles/11049741-what-is-the-max-plan).

Every provider shows enabled membership and any disabled or duplicate exclusions; Codex also shows the main-account candidate. An exhausted enabled subscription contributes zero while retaining its weight. A disabled subscription is excluded, so the remaining account's percentage is not the combined budget of both subscriptions. Weekly text is an equal-account inventory average, not the main bar's weighted estimate.

Prices and percentages are not interchangeable units. The [profile catalogue](../data/capacity-profiles.json) records published tier names and session multipliers with sources. Published session multipliers alone do not establish weekly totals or the conversion between five-hour and weekly windows. Without conversions, HotPl8 can use recognized session multipliers for the explicitly labeled quota-headroom estimate described above. A single weekly-only Codex account can be normalized without comparing tiers.

Choose a profile and supply calibrated relative capacities through an account operation:

```powershell
hotpl8 accounts -Operation capacity -Provider claude -Slot 1 -CapacityProfile claude-pro -WeeklyCapacity 1 -FiveHourCapacity 0.3
```

**The values above are fictional examples, not Claude plan rates.** Use the same unit for every window/account within a provider. If one full weekly allowance is 1 unit and a larger plan demonstrably offers five times that weekly allowance, its weekly capacity is 5. Measure short-window conversion separately; never assume that a 50% short window equals half the weekly budget. Configuration records user estimates; no calibration prompts run automatically. `capacity.SLOT.scoped.MODEL` supplies a calibrated capacity for an explicitly constrained Claude model.

For each account, current gross allowance is capped by applicable windows after conversion, then divided by its full session capacity (or full weekly-only capacity). The combined bar weights those capacities across accounts. Selection margins, known blocks and holds determine which amount is admitted. Exhausted accounts remain in the denominator; disabled accounts leave it. Duplicate native identities count once. Extra credits and paid overage are not automatically included.

Use `hotpl8 status -AsJson` for `providerOverview.PROVIDER.immediate` (the displayed metric), or `hotpl8 explain` for current totals, projection, confidence and selection reasons. `capacity` retains the calibrated model and its unknown-conversion evidence. The older normalized weekly-headroom fields remain additive compatibility data. Both models expose a 24-hour projection horizon.

## Critical mode

This is opt-in under `critical` for Claude, or `codex.critical` for Codex, in a version-2 policy:

```json
{
  "enabled": true,
  "enterPercent": 20,
  "exitPercent": 25,
  "floorPercent": 1,
  "drainToZero": false,
  "pollSeconds": 60,
  "dwellSeconds": 60,
  "advantagePercent": 10
}
```

When every fresh available work account is at or below the entry threshold on its limiting window, emergency selection can use allowance below the ordinary comfort margins. It ranks by estimated usable units when conversions exist; otherwise it discloses a percentage-based fallback. It exits only after a fresh reading exceeds the exit threshold. Unknown, disabled, authentication/model/spend-blocked accounts are not emergency candidates. Reserve policy is retained.

Set entry at least as high as your ordinary five-hour margin to avoid a gap between normal and emergency selection. For `margin5h: 25`, use `enterPercent: 25` and `exitPercent: 30`. Set `advantagePercent: 0` to choose any strictly higher balance after the dwell period; ties keep the current account. Status and `explain` report `eligible_critical` for accounts admitted below the ordinary margin.

This is account selection, not a billing cutoff. Native usage readings can lag, and switching credentials cannot retract an in-flight request. If paid extra usage must never occur, disable it in the provider account settings as well.

The default floor leaves 1%; `drainToZero: true` admits any positive measured remainder. Reported zero stays ineligible. A positive remainder is not a promise that an arbitrary prompt will finish. Dwell and a required advantage prevent constant bouncing; an unusable current account can be replaced immediately. Pauses and holds still apply. Warming/probe budgets and cooldowns remain independent of faster observation.

The Windows collector wakes once per minute and checks persisted per-provider due times: normally 300 seconds, 60 in critical mode. Failure backoff takes precedence. Existing installations must update their owned collector task through installation to obtain the faster wake interval. Never run two collectors against one state directory. macOS scheduling and native-session verification remain in the [Mac handoff](plans/macos-handoff.md).

## Presentation

Provider accents: Claude orange and Codex cyan. Budget fills transition green, yellow, orange and red. Below 10%, a small critical marker pulses red/pale white; stale or unknown values do not pulse. Disable motion with `hotpl8 -ReducedMotion`, `HOTPL8_REDUCED_MOTION=1`, or `display.reducedMotion` in policy. `-NoColor`, `NO_COLOR`, or `display.noColor` suppresses color; redirected output is a single static frame.

`hotpl8 nyan` opens the dashboard with a compact Nyan Cat animation from the existing terminal project. It is silent, uses bundled data and sends no requests. The standard cat occasionally blinks. [Animation attribution and license](../THIRD_PARTY_NOTICES.md). Small terminals use a static compact header. Both modes retain normal quit, scrolling and freeze controls.

## Preview before merge

Run the source entrypoint against an existing cache for a passive view:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\hotpl8.ps1 watch -StateDirectory C:\path\to\existing-state
powershell -NoProfile -ExecutionPolicy Bypass -File .\hotpl8.ps1 nyan -StateDirectory C:\path\to\existing-state
```

Read-only previews cannot validate actual credential switching or install a repaired collector. Use offline replay/fake-provider tests first, then separately activate reviewed behavior in a controlled local installation. Keep the stable collector running for UI-only previews. Documentation screenshots use fictional fixtures with explicitly supplied capacity conversions.
