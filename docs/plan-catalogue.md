# Updating the plan catalogue

[`data/capacity-profiles.json`](../data/capacity-profiles.json) sizes every subscription plan HotPl8 knows. The unit is one week of the provider's smallest paid plan: Claude Pro is 1, Max 5 and Ultra 10; Codex Plus is 1, Pro 5x 5 and Pro 20x 20. A plan's five-hour window is its `weekly` times the provider's `fiveHourShare` unless the profile names a `fiveHour` of its own. A plan HotPl8 does not know is size 1. Sizes come from what a vendor page says, never from prices.

Each profile names its `source` page and, in `published`, the exact sentence its size rests on. A profile whose size no page states has `published: null` and `"confidence": "unconfirmed"`.

## When the owner says "update the plan catalogue"

1. Run the checker. It reads each `source` page, takes out markup and whitespace, and looks for the `published` sentence:

   ```powershell
   python scripts/check-plans.py
   ```

   Each row says `unchanged` (the sentence is there), `CHANGED` (the page was read and the sentence is gone) or `unreadable` (blocked, cut short, or no `published` sentence to look for). It exits 1 only on `CHANGED`. `--json` prints the same rows for an agent.
2. For each `CHANGED` or `unreadable` row, read the page itself. Use a browser for learn.chatgpt.com, whose plan details lie past the first 40,000 characters a script sees, and for help.openai.com, which answers 403 to scripts.
3. Set the profile's `tier`, `weekly` and `published` to what the page says, and `verifiedAt` to today. A removed five-hour window needs no catalogue change.
4. A renamed plan also changes `PROFILES` in `native/src/plans.rs` and `PLANS` in `src/providers/claude_plan.py`; a new plan ID also changes every `profile` list in `policy.schema.json`. The tests that keep these in step say which file is behind: `cargo test` in `native/` and `python tests/test_claude_plan.py`.
5. Ask the owner only for a size no page states, offering size 1 as the default.
6. Rerun the suites, regenerating the recorded parity output with `tests/test-native-parity.ps1 -Update`, then `scripts/check.ps1` and `scripts/test.ps1`, and open a pull request.

The [plan-catalogue workflow](../.github/workflows/plan-catalogue.yml) runs the checker every week and can be started by hand. A `CHANGED` row fails the run, and GitHub mails the owner. It only reports; it changes nothing.

## The five-hour share

No vendor publishes how much of a week one five-hour window holds. `fiveHourShare` is 0.1 for each provider, measured on a Max account from paired readings: between two readings of the same account, the five-hour window rose 56, 66 and 11 points while the weekly window rose 5, 7 and 1. Pooled, 13 weekly points bought 133 five-hour points, so a full five-hour window is 13 / 133 = 0.098 of a week.

To measure it again, take readings of one account across several stretches of use inside a single five-hour window and a single week (neither window resetting between the two readings of a pair). Add up the weekly rises and the five-hour rises; the share is the weekly sum over the five-hour sum. Larger rises give a steadier answer, since each reading is rounded to whole points. Change `fiveHourShare` and its `fiveHourShareEvidence` line together.
