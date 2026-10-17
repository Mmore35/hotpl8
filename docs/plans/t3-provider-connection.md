# Connect metadata without waiting for another account reader

Status: implemented and qualified on Windows; in review, not deployed.
Qualified against main `8b4faf1b07c7d83bde205edb6ba61e200a0ebb1b`; applies unchanged to `ca7ddbca987ebd748fcb4fa9a6560767138690d5`.

T3 gives its complete provider probe ten seconds. HotPl8 currently performs a full
native account and quota read during initialization. Another collector can hold
that account's exclusive lock longer than the entire probe deadline. Extending
HotPl8's admission timeout cannot extend the host application's deadline.

## Contract

Initial bridge setup asks the compiled broker for `connect`. It applies the same
account selection, quota freshness, binding, duplicate identity, and control
authorization rules as an explicit admission. It may reuse a successful collector
observation when the exact credential bytes remain unchanged and its receipt is
within the configured quota freshness limit. It neither acquires the account's
native read lock nor starts another Codex reader on this path.

The collector stores only credential and identity digests plus the original
observation time in the existing private account record. Credential bytes must be
stable across the native observation. A busy or timed-out collection preserves
the old timestamp; authentication and configuration failures remove the receipt.
The broker bounds credential reads, compares exact bytes, and rechecks the receipt,
home binding, and controls at its existing final authorization boundary.
Nothing refreshes cached quota timestamps during connection.

The access token still travels only on the private broker pipe. The bridge checks
its serving native configuration, performs ephemeral external-token login, and
checks the serving process's native account identity before finishing setup.
Models, skills, account information, and usage remain actual native responses.
No client-name heuristic or synthetic model catalogue is involved.

Every new turn, compaction, automatic continuation, refresh, and exec retains the
existing full validation path and active-work barriers. Connection is not admission
to inference. Missing, changed, malformed, or old receipts use full validation.
This preserves upgrade compatibility but means cold connections can still exceed
the host deadline. Native startup and backend outages can independently exceed it.

## Evidence and reproduction

The opt-in Windows harness uses the installed Codex executable, unchanged bridge
entrypoints, production broker binaries, a receipt written by the real collector,
and an actual Windows exclusive account lock. A process-local TLS test CA directs
fictional authentication and metadata to a localhost responder. The responder
opens no outbound sockets and refuses all POSTs. The CA is never installed into
the OS trust store. No real homes, credentials, or model services are used.

Build this candidate's native reader and supply a complete unchanged baseline
release. With Python, Node and an existing OpenSSL executable available:

```powershell
python tests/probe_t3_provider.py --codex C:\Tools\codex.exe --baseline C:\Scratch\baseline --scratch C:\Scratch\provider-proof --openssl C:\Tools\openssl.exe
python tests/probe_t3_connection_failures.py --codex C:\Tools\codex.exe --baseline C:\Scratch\baseline --scratch C:\Scratch\failure-proof --openssl C:\Tools\openssl.exe
```

The first harness asserts that the baseline works without contention, misses the
ten-second deadline with a thirteen-second lock, and the candidate completes under
that same lock. It includes account identity, skills, four pages of models, and an
optional usage query. It writes every measured run to `whole-path-results.json`.
The second asserts rejection of mismatched identity and unavailable native auth,
full live admission before a turn, legacy-state fallback, no model request on
refusal, ephemeral shared auth, and cleanup of all observed descendants.

Initial qualification with Codex 0.160.0: baseline without contention 477 ms;
baseline with contention timed out at 10005 ms; candidate with contention 202,
414 (including usage), and 232 ms. Each successful probe returned eight models.
These are deterministic lock-contention tests against a local backend, not a
production latency SLA or proof of the cause of every reported T3 timeout.

## Finish and delivery

The existing managed release owns both the bridge and its broker. No new helper,
daemon, schedule, setting, or external token cache is installed. Activate them as
one tested release through the existing T3 integration delivery boundary; never
mix a new bridge with an old broker. A prior collector record remains readable and
the first successful new collection supplies its optional receipt. Rolling back
ignores that optional field and restores the previous full-read initialization.

Before landing, run the full offline suite, Windows and Mac CI, and independent
relay review. Obtain owner preview acceptance through the standard delivery
handoff. After normal release delivery, verify installed and newly launched bridge
revisions, collector receipt production, and actual T3 provider readiness. Existing
chat processes retain their loaded version until their normal restart.
