# HotPl8

See Claude and Codex subscription quotas together in a local terminal dashboard. Track remaining usage and reset times, and launch Codex in the account home you choose.

**Windows preview — v0.1.0-rc.1.** Uses Windows PowerShell 5.1. One account is enough to use monitoring; native provider tools and subscriptions are required. This is an early release for feedback, with [known compatibility limits](docs/compatibility.md).

## Install

Download the Windows ZIP and SHA256SUMS from [v0.1.0-rc.1](https://github.com/Mmore35/hotpl8/releases/tag/v0.1.0-rc.1), verify the ZIP checksum, and extract it. From the extracted directory run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

The installer copies HotPl8 into your user profile and adds its command to your user PATH. It does not install provider CLIs, copy credentials, or change your global execution policy. See [installation](docs/install.md) for prerequisites and native account enrollment. Open a new terminal afterward:

```powershell
hotpl8 doctor
hotpl8 refresh
hotpl8
```

New policies start in **monitoring mode**. Refresh reads quotas; it never switches accounts or sends warming/recovery prompts. Background collection is optional: pass `-Schedule` to the installer. Existing unversioned policies retain their previous automation settings; review [migration](docs/upgrading.md).

## What it does

- Cached terminal dashboard with per-account quotas, freshness, and reset uncertainty.
- Separate Claude ACTIVE and Codex NEXT LAUNCH indicators.
- Codex launches bound to a native account home; explicit ownership for resume.
- Optional Claude rotation, reserves, warming, and stale-account probes. These remain experimental pending provider-boundary and live concurrency validation; they consume quota when enabled.
- Offline diagnostics and local JSON status. No HotPl8 telemetry or hosted backend.

The Claude adapter depends on claude-swap and includes legacy credential handling whose provider-policy compatibility has not been established. It is experimental; HotPl8 does not provide a Claude sign-in flow or claim provider approval. See [provider boundaries](docs/compatibility.md#provider-boundaries).

Codex automatic warming is unavailable. Unknown constraints never imply free capacity. Mac/Linux and desktop/IDE integrations are not release-qualified. [Compatibility](docs/compatibility.md) records the exact limits.

## Learn more

[Usage](docs/usage.md) · [Configuration](docs/configuration.md) · [Troubleshooting](docs/troubleshooting.md) · [Upgrades and uninstall](docs/upgrading.md) · [Architecture](docs/architecture.md)

Questions and bugs: [GitHub Issues](https://github.com/Mmore35/hotpl8/issues). Support is best effort; include redacted doctor output and never credentials. Contributors: [CONTRIBUTING.md](CONTRIBUTING.md). Security concerns: [SECURITY.md](SECURITY.md). Data handling: [PRIVACY.md](PRIVACY.md).

HotPl8 is independently maintained and is not affiliated with or endorsed by Anthropic or OpenAI. Code is licensed under [MIT](LICENSE); native provider software and subscriptions retain their own terms. See [third-party notices](THIRD_PARTY_NOTICES.md).
