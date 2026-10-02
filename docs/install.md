# Install and connect your first account

The current candidate supports guided first-account setup on Windows and macOS 14+. Mac source use requires PowerShell 7.5+; the startup script handles that dependency. The older `v0.1.0-rc.1` release uses [its versioned instructions](https://github.com/Mmore35/hotpl8/blob/v0.1.0-rc.1/docs/install.md); it does not include this flow.

An agent can install HotPl8, prepare the selected provider, and finish setup after your native sign-in. No private manager, GitHub account, Git checkout, or preconfigured account roster is required. One account is enough.

## From a reviewed candidate or extracted package

On Windows, open PowerShell in the extracted directory and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1
```

On macOS, open Terminal in that directory and run:

```bash
bash start.sh
```

Mac startup reuses PowerShell if installed, or downloads a pinned, checksum-verified runtime to your user directory. Setup installs HotPl8, registers observation-only background collection, and starts account onboarding. Choose Claude or ChatGPT/Codex only if local discovery cannot determine the provider. The guided installer prepares the required integration tools, then asks you to complete native sign-in if necessary. HotPl8 does the remaining work.

There are no administrator steps. Windows defaults to `%LOCALAPPDATA%\HotPl8`; Mac defaults to `~/Library/Application Support/HotPl8`. Application code is separate from writable `state`. Native tools remain responsible for authentication. Setup never asks you to paste credentials, run `cswap add`, locate an account directory, choose a slot ID, or edit JSON.

Use `-Provider claude` or `-Provider codex` to express intent up front. `-InstallDependencies` supplies dependency authorization for structured callers. The human installer includes required integrations as part of setup. Agents use `-AsJson`; see [agent onboarding](agent-api.md#connect-an-account). `-NoSchedule` omits the collector, and `-NoPath` omits command registration. `-InstallDirectory` is available for deliberate custom installations.

## Public download entrypoints

After this candidate reaches a passing main build, the repository's `get.ps1` (Windows) and `get.sh` (Mac) entrypoints download the latest passing main package. They require no developer GitHub authentication. Download and inspect the entrypoint from the repository you trust, then run it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\get.ps1
```

```bash
bash get.sh
```

The bootstrap checks the successful public workflow, release tag, source revision, asset SHA256, file inventory, and individual file checksums before running setup. It installs that tested package as an ordinary installation; continuous main updates remain a separate opt-in. A package predating onboarding produces a clear error rather than silently using the old manual flow. Download failures leave the existing installation intact.

## Add another account

```powershell
hotpl8 add
```

The [account flow](onboarding.md) reuses a single available sign-in or opens the provider login, then enrolls and reads usage automatically. Additional accounts follow the same flow as the first account. An agent can drive both providers through structured operations.

The older `enroll`, `accounts`, and `setup-codex.ps1` commands remain available for explicit native-home bindings, labels, reserves, and hooks. They are advanced controls, not prerequisites for starting.

## Background collection and removal

Ordinary guided installation registers one per-user collector: a hidden Windows task or a Mac LaunchAgent. It wakes every minute while the user is signed in; provider cadence and backoff still apply. Codex normally reads every five minutes. The dashboard shows observation freshness; an installed collector does not guarantee a provider is reachable. `-NoSchedule` installations can collect explicitly with `hotpl8 refresh`.

Windows adds its command to user PATH for new terminals. Mac places a command in `~/.local/bin`; setup itself opens the view immediately. If your shell does not include that directory, an agent can use the installed `hotpl8` launcher directly. No terminal restart is required to complete setup.

Rerun the ordinary installer to update its owned application. `rollback.ps1 -InstallDirectory PATH` restores the previous code when compatible. `uninstall.ps1 -InstallDirectory PATH` removes owned code and integration while retaining state, onboarding progress, and native account data. A separately enrolled [main delivery installation](delivery.md) keeps its existing delivery owner; ordinary setup will not overwrite it.

The private Mac bootstrap runtime is retained at `~/Library/Application Support/HotPl8-Runtimes` because installed launchers may reference it. Remove it only after no installation uses it. Claude adapter runtimes remain with preserved state.
