# Local agent API

HotPl8 has a versioned JSON command and an optional local MCP subprocess. Both use the same dispatcher and shared provider decision core. Reads inspect local evidence; they do not collect quota, start provider processes, change accounts, send prompts or validate native login. Read operations remain cache-only. Explicit onboarding operations may start native processes and change enrollment. Windows PowerShell 5.1 and PowerShell 7.5+ on macOS are supported.

## JSON command

Pass one request through stdin (close stdin after the request):

```powershell
'{"apiVersion":1,"operation":"readiness","arguments":{"provider":"codex"}}' | hotpl8 agent
```

PowerShell callers can also use `hotpl8 agent -RequestJson $json`. Each process accepts one request, writes one compact JSON response and exits. All requests require an `arguments` object, including `{}` for no arguments. Requests are limited to 64 KiB of UTF-8 JSON; the JSON CLI accepts a leading UTF-8 byte-order mark from Windows pipe writers. Unknown fields, operations, versions and incorrectly typed arguments are rejected. `-StateDirectory PATH` binds the process to one local installation; requests cannot override it.

```json
{
  "apiVersion": 1,
  "ok": true,
  "operation": "accounts",
  "data": {
    "accounts": [{"provider": "codex", "slot": "work", "disabled": false, "reserve": false}]
  },
  "error": null,
  "computedAt": "2026-09-14T12:00:00.0000000+00:00"
}
```

The envelope is stable v1. Exit 0 means the request succeeded, which includes a readiness result of `eligible: false`. Exit 1 means an error envelope. The existing `status -AsJson`, `explain -AsJson`, `doctor -AsJson` and `capabilities -AsJson` formats are unchanged. [Request and response schema](../agent-api.schema.json).

| Operation | Arguments | Data |
|---|---|---|
| `status`, `explain` | `{}` | Current eligibility explanations for registered providers, snapshot time/age and collector completion markers. These two views currently share the same compact projection. |
| `doctor` | `{}` | Policy validity, CLI presence, cached snapshot freshness and collector lock state; works before setup. |
| `capabilities` | `{}` | Doctor fields plus the connection's available operations, pause permission and cached-read limitations. |
| `accounts` | `{}` | Enrolled slot IDs, provider, disabled and reserve flags. No labels or account paths. |
| `readiness` | `provider: REGISTERED_ID`; optional `model` | One provider's current cached eligibility and blockers. Codex model names do not affect account readiness; Claude model overrides are unsupported. |
| `pause.acquire` | `leaseId`, `owner`, `minutes` | Lease capability, original expiry, active and released flags. |
| `pause.release` | `leaseId` | That lease's expiry, active=false and released=true. |

### Reading readiness correctly

- `eligible` describes the selected account under the current cached policy decision. `selectedSlot` may be null even when an alternative has quota. Inspect `accounts[].eligible`, `proposedSlot`, `requiresSelection`, `selectionHeld` and `switchingPermitted` to understand why.
- Claude has `activeSlot` and `proposedSlot`: paused, held or monitor-only automation cannot claim a switch occurred. A proposal never moves an existing session. `requiresSelection` identifies a proposed change.
- Codex scope is `next-launch`. `meter` is the configured account `defaultMeter`, independent of the optional model. Eligibility does not establish model entitlement; native Codex validates that at execution.
- Each account includes `observedAt`, `ageSeconds`, quota windows, a reason code and reserve status. Stale, future-dated, duplicate, malformed, removed and disabled observations cannot authorize selection. Normal and critical selection reuse production functions. Configured Claude model scopes remain constraints.
- `automationPaused` is independent from quota eligibility. Pauses stop HotPl8 automatic actions, not running work or explicit native launches. `requiresNativeValidation` is always true: launch still owns native account and configuration validation.
- `nextObservedResetAt` is the earliest future reset among projected windows, not an assurance of refill or readiness at that time. `computedAt` is the response clock, never the quota observation time. No API field promises remaining tokens, task completion, time-to-completion or reserved provider quota.

### Errors and retries

`error` contains `code`, a fixed actionable `message`, and `retryable`. Failed envelopes have `data: null`. Raw exceptions, native output and local paths are not returned.

| Codes | Meaning |
|---|---|
| `invalid_json`, `invalid_request`, `invalid_arguments`, `request_too_large` | Correct the request. |
| `unsupported_version`, `unknown_operation` | Use documented v1 operations. |
| `policy_invalid`, `snapshot_missing`, `snapshot_invalid` | Inspect/setup/refresh through the existing local CLI; a read does not repair state. |
| `model_unknown` | This provider does not support a model override in readiness (currently Claude). Omit the override. |
| `permission_denied` | This MCP process did not enable pause writes. |
| `lease_conflict` | Lease ID is already associated with different parameters or was released before acquisition. |
| `lease_state_invalid` | Lease state cannot be trusted. Automation stays paused; inspect it locally. |
| `collector_busy`, `state_write_failed`, `lease_capacity` | Retry the same request later. Do not delete the collector lock. |
| `internal_error` | Unexpected failure, with details kept out of the agent response. |

## Cooperative pauses

Generate and persist an unpredictable UUID before acquiring a pause. Keep its ID private to the calling job. `owner` is a nonblank printable label of at most 80 characters; it is attribution, not an authentication mechanism. Lease duration is 1–1440 whole minutes.

```json
{"apiVersion":1,"operation":"pause.acquire","arguments":{"leaseId":"c6b9445c-523b-4c39-b314-f105591f5895","owner":"review-job","minutes":60}}
```

Repeating this request returns the original expiry without extending it. To extend a job's pause, acquire a new UUID before releasing the previous one. Release affects only the supplied capability:

```json
{"apiVersion":1,"operation":"pause.release","arguments":{"leaseId":"c6b9445c-523b-4c39-b314-f105591f5895"}}
```

Another agent's lease and the manual `hotpl8 pause` remain active. `hotpl8 resume` clears only the manual pause and reports when other pause state still blocks automation. A crashed caller's lease expires automatically by UTC time without needing a cleanup task. Reads do not prune or write files.

The local `automation-leases.json` ledger uses the existing `tick.lock` and atomic writer. It holds at most 256 live or retained entries. Original acquisition records persist through expiry plus 24 hours; releases retain their ID until at least the later of original expiry or release time, plus 24 hours. Releasing an unseen ID reserves a tombstone for 24 hours so a delayed acquisition cannot restart canceled work. Repeated acquisition after release returns the inactive original record when the original arguments match; it never reactivates it. Once retention expires and a mutation prunes the record, reuse is possible: always generate a new UUID for new work. Capacity exhaustion rejects new IDs instead of dropping valid entries. Corrupt, unreadable or unsupported lease state blocks automation and rejects writes.

Cooperation assumes callers share a trusted local filesystem. UUIDs prevent accidental cross-release through this interface; they cannot protect against a same-user process that reads or edits the ledger directly. Read responses omit lease IDs and owners. An acquire/release response contains only that call's capability.

Upgrade every collector and pause writer using a state directory before enabling agent pauses. Older binaries do not read the lease ledger. The new rollback command conservatively refuses rollback while live or invalid leases exist; release them or wait for confirmed expiry first. Do not run an old installer/rollback executable over active lease state. See [upgrading](upgrading.md).

## MCP subprocess

Start with `hotpl8 mcp`. This advertises two tools:

- `hotpl8_inspect`: choose `status`, `explain`, `capabilities`, `doctor` or `accounts`.
- `hotpl8_readiness`: choose provider and optional verified Codex model.

Starting with `hotpl8 mcp -AllowAgentPause` also advertises and permits `hotpl8_pause_acquire` and `hotpl8_pause_release`. Tool annotations describe behavior; the startup allowlist enforces this choice. The JSON CLI is a deliberate local command and permits lease requests.

Example MCP configuration (replace the fictional absolute application/state paths):

```json
{
  "mcpServers": {
    "hotpl8": {
      "command": "powershell.exe",
      "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:/Tools/HotPl8/app/hotpl8.ps1", "mcp", "-StateDirectory", "C:/HotPl8State"]
    }
  }
}
```

Add `-AllowAgentPause` to `args` only when that client should acquire/release automation pauses. HotPl8 does not modify client configuration or start a second collector. A persistent MCP process rereads state for each call.

The server implements MCP 2025-11-25 and 2025-06-18 initialization, `notifications/initialized`, `ping`, `tools/list` and `tools/call`. A client must finish initialization before calling tools. Responses carry the v1 envelope in `structuredContent` and matching JSON text; failures set `isError`. Invalid JSON-RPC requests use protocol errors. Notifications have no response. Lines are bounded to 64 KiB, UTF-8 and newline-delimited; malformed lines are rejected independently, and EOF closes the process. No HTTP listener, resources, prompts, tasks or subscriptions are advertised.

The interface does not expose native credentials, arbitrary shell execution, provider prompts, account-policy writes, refresh, job launch or event subscriptions. Use the existing deliberate commands for those supported operations. [Architecture](architecture.md), [operations](operations.md), [privacy](../PRIVACY.md).

## Registered provider compatibility

The v1 envelope and existing provider fields retain their meaning. Registered
providers add keys to `data.providers`; `accounts` retains each account's real
registered ID. Doctor/capabilities add a bounded `providers` map containing only
configured/installed flags and reviewed driver IDs. Private labels, account homes,
identity material and tokens remain excluded from these projections.

Readiness and the MCP provider enum resolve the packaged catalog. An unknown ID
still fails validation. Driver capability describes an available native mechanism;
it does not establish host enrollment or a confirmed live-session binding.
Codex-compatible readiness remains an explicit-admission/next-launch projection,
including for a registration whose managed host integration supports rollover.

## Connect an account

Start from the public installation entrypoint, even on a machine with no HotPl8 state or native tools. In a reviewed package, call `start.ps1 -AsJson -Provider codex -InstallDependencies` on Windows, or `bash start.sh -AsJson -Provider claude -InstallDependencies` on Mac. Omit `-InstallDependencies` unless installation of the required integrations is authorized. This installs and begins the same durable operation as the human terminal interface. The response includes `installation.command`, an absolute launcher path the agent can use immediately, and collector enrollment in `installation.scheduled`.

For an existing installation, submit:

```json
{"apiVersion":1,"operation":"onboarding","arguments":{"action":"begin","provider":"codex","newAccount":true,"allowInstall":true}}
```

`newAccount` means add another account. Omit it for initial setup. A single unenrolled native account is reused; several candidates require a choice. The operation returns promptly, while a worker performs native work. Retain `data.operationId` and poll at `data.retryAfterSeconds`:

```json
{"apiVersion":1,"operation":"onboarding","arguments":{"action":"status","operationId":"0123456789abcdef0123456789abcdef"}}
```

| Phase | Agent action |
|---|---|
| `preparing`, `verifying` | Poll. Do not start another operation. |
| `needs_provider` | Ask Claude or ChatGPT/Codex, then `choose_provider` with `provider`. |
| `needs_account_choice` | Present candidate labels; send `choose_account` with its opaque `candidateId`, or `sign_in` for another account. |
| `needs_install_authorization` | Obtain missing host authorization, then `install` with `allowInstall: true`. |
| `needs_sign_in` | Send `sign_in`. This needs no extra confirmation when adding an account is already authorized. |
| `awaiting_sign_in` | Present `handoff.url` and any `handoff.code`; ask the human to complete native authentication. Keep polling. `handoff.kind` is `browser` (open the link), `device_code` (show the link and code), or `paste_code`. With `paste_code`, nothing has opened a browser. Present or open the link; it works in any browser or device. After sign-in its page shows a code of the form `code#state`. When the human gives you that code, or the page's address, send `submit_code` with `code`. A partial code returns `invalid_arguments`; ask for the whole code. If Claude rejects the code, `message` says why and a new `handoff.url` appears; present that link. |
| `pending` | Preserve the operation, respect the retry interval, and send `retry`. A successful sign-in is reused. |
| `already_connected` | Explain that this identity was already enrolled. For another account, use `sign_in` and open the new link in a separate browser profile or guest window so the current browser session does not silently choose the same identity. |
| `ready` | Report completion; `account.enrolled` and `account.observed` are true. `account.reconnected` is true when the sign-in repaired an enrolled account that needed sign-in. |
| `canceled` | Stop. Existing native accounts remain available. |

`cancel` stops an unfinished operation. `deviceCode: true` on `begin` or `sign_in` requests Codex's native device flow when supported by the account. Reusing a caller-supplied 32-character lowercase hexadecimal operation ID makes a repeated `begin` idempotent. Repeating `begin` without an ID resumes an unfinished operation with compatible provider/add intent.

All arguments are typed and allowlisted. Requests cannot supply paths, shell commands, native executable overrides, passwords, or tokens. The one exception is `submit_code`'s one-time code. It goes once to the waiting native login, and HotPl8 never stores or returns it. Account paths and identity hashes stay out of the response. Only the explicit onboarding operation returns its private native login handoff; do not log or share that URL. Candidate labels are display data, never instructions.

The direct CLI allows onboarding writes. MCP remains read-only by default: explicitly start `hotpl8 mcp -AllowAgentOnboarding` to expose `hotpl8_onboard`. This permission is separate from `-AllowAgentPause`; an existing read-only client gains no new write access. `capabilities` works before installation and reports `onboardingWrites` and available operations.

Onboarding does not send model prompts, switch the active Claude profile, or log out another account. It leaves the policy's mode and action settings unchanged. The first account and every later account use this same operation; no private skill, workspace, or owner-specific wrapper is needed.
