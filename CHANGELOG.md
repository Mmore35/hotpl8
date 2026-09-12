# Changelog

## 0.1.0-rc.1 — unreleased

- Remove the dashboard tagline.
- Add monitoring-only defaults, independently controlled Claude actions, and observation-only refresh.
- Preserve automation behavior for existing unversioned policy files.
- Add policy validation, shared state resolution, redacted doctor output, version/help, and local JSON status.
- Bound Claude child-process time and output; reject malformed/disabled account readings.
- Add per-user installation, optional scheduled collection, updates, rollback, and uninstall.
- Package explicit files with checksums; add offline CI and publication checks.
- Replace private research/diagnostics with public documentation and prepare a clean public initial history.
- Correct UTF-8 quota-pipe input and preserve Unicode account paths independently of console encoding.

This is an early Windows preview, not a stable-support designation. Live provider/concurrency qualification remains open. See [compatibility](docs/compatibility.md) and the [release checklist](docs/release-checklist.md).
