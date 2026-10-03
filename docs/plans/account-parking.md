# Park accounts that are no longer paid for

## Problem

A subscription that stops being paid for stays enrolled. Its reads fail on every
collection, so the collector reports incomplete runs, the provider total shows
part of its capacity as unknown, and the dashboard shows a standing "account
unavailable" line that points at `doctor`, which does not look at accounts. In the
`even` and `clustered` warming patterns it also keeps its share of the five-hour
cycle, leaving a gap in the other accounts' schedule. `disable` stops the reads
but keeps the row and the schedule share; `remove` clears both but forgets the
account's label, order, weight, capacity and native home.

## Evidence

- A Claude account without Pro or Max cannot sign in to Claude Code: the
  browser page states that a Max or Pro subscription is required, and no code is
  issued. Its stored credential then fails with `relogin_required` indefinitely,
  and cswap keeps reporting how long ago it last read successfully.
- Codex `account/read` reports a plan name. Paid accounts can report names
  outside the earlier fixed list, such as `prolite`, which HotPl8 displayed as
  unknown. The value a lapsed Codex plan reports has not yet been observed;
  `free` is assumed until it is.

## Behavior

`park` removes the account from policy, so every consumer treats it as absent
without parking-specific code, and stores what is needed to restore it in
`parked.json`. The record is written before the policy; if the policy write does
not happen, the enrolled account takes precedence and the record is discarded
later. `unpark`, `add` and `enroll` restore the saved settings; a different
subscription found in the same slot discards the record instead.

Detection uses cached evidence only. An account is offered when its sign-in has
failed for at least seven days, or when a current Codex reading reports `free`.
The Claude login in use and disabled accounts are never offered, and nothing is
parked without the owner's answer or `-Yes`.

Codex now records `previousPlanType` and `planChangedAt` when an account's plan
changes, so the first real lapse confirms or corrects the `free` assumption.

## Verification

`tests/test-parking.ps1` covers detection, park/unpark round trips for both
providers, identity changes, the active-login refusal, record-file safety, the
dashboard and doctor wording, and the CLI prompt with redirected input.
`tests/test-tick.sh` covers the published last-good time and a parked account
that reads again. Fixtures use fictional accounts and replace every native reader.
