# T3 admission under load

A new T3 chat on a saturated machine could fail with `routing_account_busy`,
`routing_validation_timeout` or `routing_unavailable` while every account had
quota and a valid sign-in. Sending again once the machine was quieter worked.

Nothing was corrupted and no two readers ever held one account at once: the
per-home lock did its work. The failures came from fixed waits that were sized
for an idle machine, and from how many readers a working session added.

- **A slow read was taken for a bad account.** The collector allows one native
  read 12 seconds. An admission allowed its own read 6.5. On a machine where
  starting native Codex and getting four answers from it takes eight seconds,
  the collector kept publishing fresh, healthy rows and every admission read
  timed out, one account after another, until none was left:
  `routing_unavailable`, or `routing_validation_timeout` at the 20-second
  deadline.
- **A busy account was given up on for good.** An admission waited 6.5 seconds
  for a busy lock and then discarded that account for the rest of the request.
  With one eligible account, a single reader slower than that was enough for
  `routing_account_busy`, although the lock was free moments later.
- **Working sessions kept the lock busy.** Native Codex sends
  `account/rateLimits/updated` after every model response, and a bridge ran a
  full validation for each one. Two busy sessions produced a validation every
  few seconds, each one a PowerShell start and a native read under the same
  lock. They queued behind one another and behind the collector, and a new
  admission joined the end of that queue.
- **An admission waited behind its own session's background work.** A bridge
  runs one validation at a time. A new admission arriving during a background
  validation waited for it, and for any other already queued, before its own
  broker was started.
- **Broker startup spent the bridge's allowance.** The bridge allowed the broker
  25 seconds from the moment it was started; the broker's own 20-second deadline
  began only once PowerShell had loaded. Several seconds of startup on a loaded
  machine left the bridge's timer to fire first: `routing_broker_failed`.

## Implementation

1. Give an admission's native read the collector's bound,
   `Get-CodexReadBudgetMs`, limited by the time the request has left. Refresh
   keeps 6.5 seconds, because native Codex does not wait longer for it.
2. Give ordinary validation 30 seconds: one slow reader to wait out and one
   slow read of its own, with room to spare. Give the bridge 40 seconds for the
   broker, so the broker's own deadline is the one that ends a request and the
   more specific failure is the one reported.
3. Set a busy account aside instead of discarding it. Try the eligible peers,
   each with a fresh native read, then return to the busy one, as often as the
   deadline allows. A peer that validates is still admitted at once.
   `routing_account_busy` now means the lock stayed held until the deadline.
4. A background validation makes one attempt at the lock and never waits. Held
   means skipped: the session keeps its account, nothing is shown, no event is
   recorded, and the next wakeup repeats the validation. Only a persistent
   condition is worth a diagnostic, and that one fails the next attempt too.
5. An admission ends its own session's background validation, running or
   queued. The lock is an operating-system handle and authorization writes no
   state, so a broker that is stopped leaves nothing behind.
6. Validate for native quota notifications at most once a minute per session.
   Every notification still reaches the client. Collector publications, policy
   changes and control changes still validate at once.
7. Stop a session's brokers when it closes.

Selection, eligibility, quota margins, bindings, active-work deferral, the
account lock and what the broker returns are unchanged.

## What this does not change

- A native read slower than 12 seconds is still a failed read, for the collector
  and for admission alike.
- A request that cannot be admitted now says so after up to 30 seconds of
  validation, not 20.
- A policy, hold or status change that lands while an admission is validating
  still ends it with `routing_state_changed`.
- The client's own deadlines belong to the client. One that gives a provider
  less time to answer than a slow read takes will report its own timeout.

## Acceptance and delivery

- A native read of seven seconds admits the preferred account, with one read,
  and is given the collector's full bound.
- A single eligible account whose lock is held for eight seconds is admitted
  once the lock is released, with one native read.
- A background validation that finds the lock held answers within one attempt,
  records no event and shows no diagnostic. An admission behind a lock that is
  never released fails with `routing_account_busy` at its deadline.
- An admission is answered while a background validation of the same session
  is still running, and without running one that was queued.
- A burst of quota notifications starts one validation per interval and every
  notification is forwarded.
- Closing a session leaves no broker running.
- Run the T3 Windows/protocol suites, static checks and the full CI workflow
  before merging.

No migration is required. A session started before the update keeps the bridge
it loaded; a new session uses the new one. Do not terminate active work to force
adoption. Rollback uses the prior release without changing conversation or
account homes.
