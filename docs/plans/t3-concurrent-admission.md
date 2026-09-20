# Concurrent T3 admission repair

T3 can start a chat app-server and its automatic title helper concurrently.
Both validate the selected native account before inference. The per-home lock
correctly serializes native credential access, but the original broker treated
`home_busy` like a failed account and immediately discarded the candidate.
With one eligible subscription, one request could fail `routing_unavailable`
while the other succeeded. Resending after the lock cleared then worked.

The reported trace showed simultaneous title generation and failed session
startup, followed by successful session startup on retry. Collector data was
fresh and showed ample quota. Historical broker logs did not retain the native
read reason, so lock ownership cannot be proven retroactively. An offline test
reproduces the exact error by returning temporary lock contention, and the
compiled integration fixture exercises overlapping title/chat admissions.

## Implementation

1. Retry only native `home_busy` during admission, at 75 ms intervals for up to
   2.5 seconds per candidate. Each attempt must acquire the existing exclusive
   lock and perform fresh native validation. Do not change collector behavior.
2. Bound all validation, waits and candidate fallback by 20 seconds for ordinary
   admission and 6.5 seconds for pinned refresh. Pass remaining time to the
   native reader, inside the bridge's existing 25/8.5-second outer deadlines.
3. If another eligible account exists, retain ordinary validated fallback.
   Pinned refresh must never change accounts. Prolonged contention returns
   `routing_account_busy`; total budget exhaustion returns
   `routing_validation_timeout`.
4. Record only time and the fixed allowlisted failure code in the existing
   bounded event log. Never write broker responses, tokens, prompts, account
   identities, paths or native exception text.
5. Preserve all freshness, binding, quota and active-turn checks. Never retry a
   submitted turn, helper inference, auth failure or network failure.

## Acceptance and delivery

- Temporary contention recovers for chat admission, exec helpers and pinned
  refresh; genuine unavailable capacity/authentication still fails.
- A compiled title helper holds the native quota lock while chat initializes;
  both complete, and helper inference is executed once.
- Persistent contention has a bounded, distinguishable error. A busy preferred
  candidate can fall back to a separately validated eligible account.
- Diagnostics contain only the fixed failure code and timestamp.
- Run the T3 Windows/protocol suites, existing Codex regression, static checks
  and the full CI workflow before merging.

No native credential migration is required. Initial installations pinned their
source snapshot; the [managed delivery repair](t3-managed-delivery.md) supersedes
that deployment path. Existing provider processes retain their loaded revision.
Do not terminate active work to force adoption. Rollback uses the prior pinned
revision without changing conversation or account homes.
