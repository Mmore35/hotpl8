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

## The launcher

On Windows, `hotpl8` is a command file that asks HotPl8's compiled reader first. `version`, `status` and `explain` in their plain spellings are answered by the reader, and PowerShell is not started. For any other words the launcher starts PowerShell with the same words, as it always has. On a Mac the launcher starts PowerShell for every command for now, and PowerShell hands those three to the reader.

| Copy | What `hotpl8` runs |
|---|---|
| Source checkout or extracted package | `hotpl8.cmd` hands over to `hotpl8-launch.cmd`, which asks `bin\windows\hotpl8-native.exe` |
| Ordinary installation | `hotpl8.cmd` in the installation directory hands over to `app\hotpl8.cmd`, and from there as above |
| [Main delivery installation](delivery.md) | `hotpl8.cmd` hands over to `launch.cmd` beside it, which asks the `hotpl8-native.exe` beside it. That copy answers nothing itself: it reads which release is in force and has that release's own reader answer |

The reader ends with 0 for an answer and 1 for a refusal. Any other status, a crash included, means the words were not its to answer, and the launcher starts PowerShell.

The files are split this way because `cmd` reads a command file again after every line and carries on from a position in it. A dashboard started from a launcher comes back to that file when it ends, perhaps days later. If the file holds other text by then, `cmd` carries on in the middle of it. Three rules follow:

- A launcher that sessions run from keeps its text for good. `hotpl8-launch.cmd` and `delivery/launch.cmd` are such files, and `tests/test-native.ps1` holds their bytes.
- `hotpl8.cmd` is one line that hands over and is not returned to. It is shorter than the place the earlier three-line launchers come back to, so a session started from one of those ends cleanly at the end of it.
- A launcher that has to change ships under a new file name, and the one line names it.

An ordinary installation gets its one line when the installer is rerun. `rollback.ps1` puts the previous release back under `app` and leaves the line as it is; `app\hotpl8.cmd` exists in every release, and in a release from before this arrangement it starts PowerShell.

A main delivery installation enrolled earlier gets `launch.cmd`, the reader beside it, and the one line at the first activation of a release that ships them. Its `hotpl8.cmd` is replaced only when it is exactly the text enrollment wrote; an edited one is left alone and keeps starting PowerShell for every command. Every activation after that refreshes the reader beside the launcher. A reader that is answering cannot be written over, so the one in use is moved aside as `hotpl8-native.<id>.old` and removed at the next activation.

One case ends untidily. A session still running from `app\hotpl8-launch.cmd` when that file is taken away under it (a rollback or downgrade to a release from before this arrangement, or enrollment in main delivery) prints `The batch file cannot be found.` when it ends, with status 1 in place of its own. Nothing else is affected.
