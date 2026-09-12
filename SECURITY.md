# Security

This project is pre-release. No version is currently designated a stable security-supported release. Fixes are developed on the maintained branch; release notes will identify supported versions after launch.

Do not post tokens, auth.json, hooks with secrets, full environment dumps, real account labels, or native provider logs in public issues. Offline `hotpl8 doctor -AsJson` emits an allowlist of diagnostic fields, but review anything you share.

Use GitHub's private **Report a vulnerability** control on the repository Security tab when enabled. If it is unavailable, file only a non-sensitive request for a private reporting channel; do not include vulnerability details. Enabling and testing private reporting is a publication prerequisite. No monitored email address or response SLA is implied here.

HotPl8 uses native provider authentication and keeps state local. Experimental Claude warming/recovery still has a legacy credential-cleanup workaround; its provider compatibility and concurrency behavior require release review. See [privacy](PRIVACY.md) and [release gates](docs/release-checklist.md).
