# Defer account changes while native work is active

## Native evidence

On 2026-09-26, the installed Codex CLI 0.157.1 recorded a HotPl8-originated
`account/login/start` request followed immediately by `application network
permission was revoked` in the same native process. Both an active turn and an
MCP event stream failed. The affected thread's saved sandbox policy was disabled;
this was not evidence of a network-disabled tool sandbox. No deliberate failing
live prompt was sent during the investigation.

Earlier qualification on CLI 0.155.1 and an offline provider that treated login
as a harmless account assignment did not establish survival of native network
permissions in 0.157.1. Successful external-token login is insufficient evidence
that already-running turns, children or MCP connections remain usable.

## Behavior

After fresh broker validation, the bridge rechecks all active threads and pending
admissions before changing process-wide authentication. Background selection
retains the current account while work is active. A new admission that requires
another account reports `routing_account_change_deferred` without submitting it.
Normal follow-ups, approvals, steering and interrupts continue to pass through.
Same-account token refresh keeps its existing pinned-account contract.

Once all work finishes, the next admission can select another account using
current quota and policy. A task that exhausts its account is not transparently
replayed; preserving executed effects takes precedence over switching it live.
There is no new setting or feature flag.

## Verification and delivery

Regression fixtures model network revocation on active login, including children
that outlive parents and work that starts while validation is pending. The Windows
integration uses the real launcher, broker and fake native transport to check that
collector publication preserves the active account, follow-ups retain their turn,
and a later idle admission switches without repeating executed work.

New bridge processes adopt this repair through verified main delivery. Already
running bridges retain their loaded code; installation alone does not prove an
existing conversation has adopted the fix. Do not terminate active work to force
adoption. Reopen affected sessions once idle, then check their process receipts.
