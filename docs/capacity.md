# Capacity, critical mode and motion

HotPl8 has one **Available now** bar per provider. Its solid foreground is estimated usable allowance under current limits and routing policy. The patterned extension is additional allowance at the first confirmed reset that increases availability within 24 hours, assuming no further consumption. Resets still blocked by other limits are skipped. With no positive refill in that horizon, no pattern appears; a useful refill further out is named in text beside the bar instead. The clock reaching zero never turns a projection into measured capacity.

The bar is compute usable right now, pooled across a provider's accounts. Every account is sized in one unit, one week of the provider's smallest paid plan: Claude Pro 1, Max 5, Ultra 10; Codex Plus 1, Pro 5x 5, Pro 20x 20. A five-hour window holds a tenth of its plan's week. An account counts its current window: its five-hour window where it has one, otherwise its week, as an Ultra account with no five-hour limit does. Three equal plans at 100%, 100% and 75% show **91.7% now**, with **+8.3%** when the depleted session resets.

With Ultra at 74% of its week and no five-hour limit, and Max at 26% of its five-hour window and 28% of its week, Ultra has 7.4 of its 10 and Max 0.13 of its 0.5: 7.53 of 10.5, **~72% now**. The weekly text beside the bar is weighted by size the same way: (7.4 + 1.4) / 15 is **7d 59%**. A plan HotPl8 does not know (Team, Enterprise, a tier it cannot tell) is size 1, so it leans low rather than counting as much as a large plan.

Weekly and model limits reduce session capacity in the same units. If a full week is 1 unit and a full session is 0.1 units, 2% weekly remaining permits at most 0.02 / 0.1 = **20% of a session**. Taking the smaller raw percentage is incorrect. These are estimates, not guaranteed prompt or token budgets; the figure is marked `~`.

In the calibrated `capacity` model, missing readings remain unknown. The displayed **Available now** metric (`immediate`) measures the accounts readable now instead: unreadable accounts are listed in `coverage` rather than blanking the total. It counts every readable account when auto-switch is off or paused; a selection hold narrows it to the held account. The Codex summary always uses main Codex, excluding Spark; existing sessions retain their native account.

A fresh, explicitly blocked Codex account with a measured zero contributes zero usable allowance now and keeps its weight in the total. Its refill is projected only when the collector recorded a plain quota exhaustion: a reached rate limit, no spend or account restriction, a window at 100% and a confirmed future reset (`blockReason: quota_exhausted`). Every other block — spend control, a workspace-owner limit, a denied account, an unconfirmed reset anchor, or a block whose reason the native client did not state — stays at zero until a later observation clears it, and keeps `projectionComplete: false` to mark the excluded recovery: a quota reset does not necessarily remove a spend or account restriction. A known refill from another healthy account can still appear either way. Stale readings and unknown provider constraints remain unknown.

`laterRefillAt` and `laterRefillGainPercent` name the first useful refill beyond the 24-hour horizon, up to eight days out. They are text only: no pattern, no shimmer, no change to the solid bar, and `nextResetAt`/`projectedGainPercent` keep their existing 24-hour meaning. A provider whose whole week refills the day after tomorrow therefore says so instead of showing an unexplained empty bar.

## Set subscription capacity

Claude plan discovery is automatic during collection: HotPl8 reads each enrolled account through the installed claude-swap Python adapter and verifies its identity against Anthropic's OAuth profile response. Recognized Pro, Max and Ultra profiles appear in account details and supply the matching catalogue profile unless you explicitly override it; Max and Ultra are stored under their older IDs, `claude-max-5x` and `claude-max-20x`, so saved policies keep working. Team/Enterprise and a Max or Ultra account whose tier cannot be told (`Max or Ultra (tier unknown)`) retain their labels and are size 1. Discovery refreshes every 15 minutes. An account keeps the size of the plan last known for it: a detected plan at any age, else the last detection within a week. When Anthropic's endpoint does not answer, the plan the stored sign-in names is used (`source: stored-sign-in`), and the endpoint is asked again only when its wait allows. A Codex account takes the catalogue profile its reported plan type names. None of this extends usage freshness. Account replacement invalidates the old identity immediately, and failed detection is not treated as a current plan. No separate sign-in, API key or plan questionnaire is needed for supported accounts.

Plan discovery requires the Python interpreter belonging to the native cswap installation (Windows system/venv installs and Unix Python shebangs are recognized). Custom batch adapters can still collect quota but may not supply automatic plan metadata. The profile endpoint and cswap reader are compatibility boundaries, not a stable public billing API. Unsupported schemas remain unknown. HotPl8 does not refresh authentication or copy credentials to recover plan detection.

Native discovery was verified with cswap 0.26.0: schema-v1 inventory includes `email` and `organizationUuid`, which agree with the adapter's `account_identity` reader. Both are required for binding. An older/custom inventory that omits organization identity remains unverified; do not remove the identity check to force a plan label. Unix `env`-style shebang launchers are not yet resolved; qualify that path in the Mac handoff.

Sizes come from what the vendors publish: Max is [five times the Pro plan's usage every five hours and every week](https://support.claude.com/en/articles/11049741-what-is-the-max-plan), and Ultra [10 times the Pro plan's usage every week](https://support.claude.com/en/articles/17728952-what-is-the-ultra-plan). Codex's sizes are unconfirmed: no page HotPl8 checks states its multiples. No vendor publishes how much of a week a five-hour window holds; the share of a tenth was measured on a Max account. The [profile catalogue](../data/capacity-profiles.json) records each size, its source and the sentence it rests on; [Updating the plan catalogue](plan-catalogue.md) says how they are checked and how the share was measured. Prices are never used. Explicit measured conversions take precedence.

Every provider shows enabled membership and any disabled or duplicate exclusions; Codex also shows the main-account candidate. An exhausted enabled subscription contributes zero while retaining its size. A disabled subscription is excluded, so the remaining account's percentage is not the combined budget of both subscriptions.

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
