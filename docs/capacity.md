# Capacity, critical mode and motion

HotPl8 has one layered bar per provider. The full track is the combined weekly allowance of enabled unique subscriptions. The solid foreground is estimated usable allowance under current limits and routing policy. The patterned extension is the additional allowance expected at the next confirmed reset, assuming no further consumption. The right-hand countdown refers to that reset. A reset still blocked by another limit adds zero. The clock reaching zero never turns a projection into measured capacity.

Account details retain raw quota percentages. Unknown readings and missing conversion factors remain visible. A paused/held/manual Claude configuration can leave allowance on other accounts outside the solid routed amount. Codex availability applies to a new launch; existing sessions retain their native account.

A fresh, explicitly blocked Codex account with a measured zero contributes zero usable allowance and keeps its weight in the total. It does not turn the other subscriptions' readings into unknown data. The reset countdown can still be shown, but projected gain stays unknown until a later observation clears the block: a quota reset does not necessarily remove a spend or account restriction. Stale readings and unknown provider constraints remain unknown.

## Set subscription capacity

Prices and percentages are not interchangeable units. The [profile catalogue](../data/capacity-profiles.json) records published tier names and session multipliers with sources. Published session multipliers alone do not establish weekly totals or the conversion between five-hour and weekly windows. Until these are configured, HotPl8 shows quota readings and a capacity-setup message. A single weekly-only Codex account can be normalized without comparing tiers.

Choose a profile and supply calibrated relative capacities through an account operation:

```powershell
hotpl8 accounts -Operation capacity -Provider claude -Slot 1 -CapacityProfile claude-pro -WeeklyCapacity 1 -FiveHourCapacity 0.3
```

**The values above are fictional examples, not Claude plan rates.** Use the same unit for every window/account within a provider. If one full weekly allowance is 1 unit and a larger plan demonstrably offers five times that weekly allowance, its weekly capacity is 5. Measure short-window conversion separately; never assume that a 50% short window equals half the weekly budget. Configuration records user estimates; no calibration prompts run automatically. `capacity.SLOT.scoped.MODEL` supplies a calibrated capacity for an explicitly constrained Claude model.

For each account, current gross allowance is the smallest remaining amount across applicable windows after conversion. Selection margins, known blocks and holds determine which amount is admitted. Exhausted accounts remain in the denominator; disabled accounts leave it. Duplicate native identities count once. Extra credits and paid overage are not automatically included.

Use `hotpl8 status -AsJson` for `providerOverview.PROVIDER.capacity`, or `hotpl8 explain` for current totals, projection, confidence and selection reasons. The older normalized weekly-headroom fields remain additive compatibility data and are labeled separately.

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

The default floor leaves 1%; `drainToZero: true` admits any positive measured remainder. Reported zero stays ineligible. A positive remainder is not a promise that an arbitrary prompt will finish. Dwell and a required advantage prevent constant bouncing; an unusable current account can be replaced immediately. Pauses and holds still apply. Warming/probe budgets and cooldowns remain independent of faster observation.

The Windows collector wakes once per minute and checks persisted per-provider due times: normally 300 seconds, 60 in critical mode. Failure backoff takes precedence. Existing installations must update their owned collector task through installation to obtain the faster wake interval. Never run two collectors against one state directory. macOS scheduling and native-session verification remain in the [Mac handoff](plans/macos-handoff.md).

## Presentation

Provider accents: Claude orange and Codex cyan. Budget fills transition green, yellow, orange and red. Below 10%, a small critical marker pulses red/pale white; stale or unknown values do not pulse. Disable motion with `hotpl8 -ReducedMotion`, `HOTPL8_REDUCED_MOTION=1`, or `display.reducedMotion` in policy. `-NoColor`, `NO_COLOR`, or `display.noColor` suppresses color; redirected output is a single static frame.

`hotpl8 nyan` opens the dashboard with a compact Nyan Cat animation from the existing terminal project. It is silent, uses bundled data and sends no requests. The standard cat occasionally blinks or moves its tail. [Animation attribution and license](../THIRD_PARTY_NOTICES.md). Small terminals use a static compact header. Both modes retain normal quit, scrolling and freeze controls.

## Preview before merge

Run the source entrypoint against an existing cache for a passive view:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\hotpl8.ps1 watch -StateDirectory C:\path\to\existing-state
powershell -NoProfile -ExecutionPolicy Bypass -File .\hotpl8.ps1 nyan -StateDirectory C:\path\to\existing-state
```

Read-only previews cannot validate actual credential switching or install a repaired collector. Use offline replay/fake-provider tests first, then separately activate reviewed behavior in a controlled local installation. Keep the stable collector running for UI-only previews. Documentation screenshots use fictional fixtures with explicitly supplied capacity conversions.
