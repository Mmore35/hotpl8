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
