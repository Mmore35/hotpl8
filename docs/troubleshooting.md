# Troubleshooting

Start with `hotpl8 doctor -AsJson`. It is offline and redacted. Run `hotpl8 refresh` when you explicitly want fresh provider reads.

| Symptom | Next step |
|---|---|
| No policy | Run init in the intended state directory; enroll accounts. |
| Missing cswap/Codex | Install the relevant native dependency; verify PATH in a new terminal. |
| No accounts | Complete native login and explicit enrollment. |
| Stale reading | Check the collector task in Task Scheduler and local events.jsonl. Offline/sleep periods do not imply refreshed quota. |
| Collector busy | Another collector/setup holds the state lock. Wait; do not delete live lock files. |
| Authentication required | Use the native provider login/recovery flow. Do not copy another home's token. |
| Unknown meter/model/constraint | Use a supported mapping or explicit native tools; do not interpret unknown as unlimited. |
| Failed refresh | Nonzero exit means incomplete collection. Review fixed event codes; the previous cache is not fresh evidence. |
| Hook absent | Review/trust the exact SessionStart handler in native Codex /hooks. |
| Installation refuses directory | Choose an empty per-user directory; the installer refuses unrelated files and junctions. |
| First installation failed | Fix the reported problem and rerun the same installer command. Its ownership marker permits retry while preserving state; do not delete your policy or native accounts. |

Events rotate at 256 KiB to one backup. State, labels, native homes, quota observations, and credential-generation logs are private. Share redacted doctor output rather than a ZIP of the installation. See [SECURITY.md](../SECURITY.md) for sensitive reports.

## Claude intermittently drops a reading

Claude's adapter schedules idle usage reads about ten minutes apart, with jitter. HotPl8 observes that adapter each minute; the adapter still owns API polling, locks and rate-limit backoff. Older HotPl8 builds added another five-minute cache delay, which could push a healthy reading past the fifteen-minute freshness cutoff. Update both the source preview and the installed collector to obtain this fix. Older manually configured five-minute tasks must also use a one-minute interval; keep one collector for each state directory. The supported installer already uses that interval.

If a reading still expires, account details show its age and the overview identifies incomplete coverage. Enrollment is retained. Check `hotpl8 explain` for provider failures and `hotpl8 doctor` for a missing or stalled scheduler. Provider throttling, offline machines and expired authorization can still prevent fresh readings; HotPl8 must not turn those into a full balance or select stale accounts. Re-login is needed only when native account status indicates an authentication problem.

## Codex quota disappeared after a collection error

Update to a build containing the sparse-cache recovery fix. Failed collection retains old account evidence as unavailable and clears recommendations. During backoff, skipped wakes do not extend the deadline. `failureStage` and `failureCode` in provider status distinguish safe error categories; native error messages are not exported. A successful quota read and unsupported warming are separate conditions. A secondary unknown meter does not invalidate the selected meter.
