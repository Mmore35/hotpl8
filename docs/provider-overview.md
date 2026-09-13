# Two providers, one overview

The top of HotPl8 shows one bar for Claude and one for Codex. Each estimates weekly headroom across enabled subscriptions. The line below says whether an account is usable and whether selection is automatic, paused, held, or manual. Codex readiness applies to the next launch; existing sessions retain their accounts.

Scroll down for individual quotas, reset times, warming receipts and selection explanations. The overview stays visible. `hotpl8 status`, `hotpl8 explain`, their JSON output and the optional tray use the same summary calculation. Viewing any of them reads cached evidence without calling providers or sending prompts.

## What the bar measures

Each enabled subscription contributes one equal share. For three accounts with 100%, 50% and 0% of their weekly allowances remaining, the estimate is 50%. An exhausted account stays in the denominator. Disabled accounts leave the managed set. Verified duplicate identities count once; old snapshots without identity evidence cannot establish duplicates.

This is an average of normalized percentages, **not a token budget or a forecast of work-hours**. Different plan tiers may have different capacities. HotPl8 does not invent capacity multipliers, and selection weights do not weight these bars. The primary UI omits a numerical percentage; text/JSON explanations expose the estimate and its coverage.

The Claude bar uses overall weekly usage. The Codex bar uses the configured default meter's weekly window; overlapping meters are never added together. Model limits remain separate eligibility constraints. A bar does not promise the same allowance for every model.

Reserve allowance is included and labeled. Whether it can be selected depends on policy. Readiness also considers short-window limits: the weekly bar can have substantial remaining headroom while the status says unavailable now. The details explain blocked accounts.

## Missing data stays visible

Question marks represent the unknown share of the same bar. If one of three accounts has no valid reading, it still occupies one third; the other two are not expanded to fill the bar. Partial summaries show how many accounts were measured and return no single `remainingPercent` in JSON. Known zero and unknown are distinct.

Old readings, missing windows and expired/unconfirmed resets cannot refill a bar. They require a fresh supported observation. Readers re-evaluate timestamps and policy changes even when the collector has not run again. Collector failures, sign-in needs, blocked readiness and automation pause/hold appear in the overview, with further evidence in the details.

![Individual account details below the fixed provider overview](assets/details.png)
