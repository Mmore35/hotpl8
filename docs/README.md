# HotPl8 documentation

Guides for HotPl8, the local usage-limit monitor and account switcher for Claude Code and OpenAI Codex. Start with the [project README](../README.md) for what it does and how to install it.

## Using HotPl8

| Guide | What it covers |
|---|---|
| [Install and connect your first account](install.md) | Windows and macOS installation, background collection, the launcher, removal |
| [Connect an account](onboarding.md) | `hotpl8 setup` and `hotpl8 add` for Claude and Codex accounts |
| [Command reference](usage.md) | The `hotpl8` commands and what each does |
| [Account operations](operations.md) | Reserve, disable, park, pause, automatic continue, work hours, weekly pace, the Windows tray |
| [Provider overview](provider-overview.md) | What the **Available now** bars measure |
| [Capacity, critical mode and motion](capacity.md) | Plan sizes, weekly caps on session capacity, critical mode, colors and animation |
| [Configuration reference](configuration.md) | The fields of `policy.json` |
| [Troubleshooting](troubleshooting.md) | Unavailable readings, dropped Claude readings, missing Codex quota |
| [Updates, rollback, and uninstall](upgrading.md) | Update commands and changes for existing installations |
| [Compatibility and supported platforms](compatibility.md) | Tested platforms and tool versions, experimental features, provider boundaries |

## Integrations

| Guide | What it covers |
|---|---|
| [Local agent API and MCP server](agent-api.md) | `hotpl8 agent` JSON requests, `hotpl8 mcp`, cooperative pauses, agent onboarding |
| [T3 Code and Codex account routing](t3-integration.md) | The optional bridge that routes T3 Code's Codex turns through HotPl8's account choice |
| [Verified main updates and PR previews](delivery.md) | Following tested `main`, PR previews, the component lifecycle |
| [Verified main updates on macOS](macos-delivery.md) | Mac enrollment, inspection and recovery |

## Contributing and internals

| Guide | What it covers |
|---|---|
| [How HotPl8 works](architecture.md) | Architecture, account selection, warming, source map |
| [Contributing](../CONTRIBUTING.md) | Building, testing and changing the code |
| [Adding a registered provider](adding-a-provider.md) | Declarative provider definitions |
| [Updating the plan catalogue](plan-catalogue.md) | Plan sizes and their sources |
| [Updating the screenshots](screenshots.md) | Regenerating the images in `assets/` |
| [Release checklist](release-checklist.md) | Publishing releases and main packages |
| [Design plans](plans/) | Contracts and plans behind individual features |

[Privacy](../PRIVACY.md) · [Security](../SECURITY.md) · [Third-party notices](../THIRD_PARTY_NOTICES.md) · [Changelog](../CHANGELOG.md)
