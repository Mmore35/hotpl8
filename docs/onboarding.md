# Connect an account

Run `hotpl8 setup` for your first account, or `hotpl8 add` for another. An agent can do the same work through the [JSON interface](agent-api.md#connect-an-account). No account directories, slot numbers, configuration edits, or manual refreshes are required.

HotPl8 checks the selected provider's native sign-ins. One available account connects automatically. If several accounts are available, choose one. If the provider tools are missing, setup offers to install the required tools for your user. If there is no usable sign-in, complete the provider's browser login. HotPl8 captures the native account, prevents duplicate enrollment, reads usage, and opens the account view.

```powershell
hotpl8 add -Provider claude
hotpl8 add -Provider codex
```

If you have neither account, choose a provider and use its official account flow, or finish later. HotPl8 does not purchase a subscription. One account provides the full monitoring experience. Setup starts in monitor mode; existing installations retain their settings.

## What you actually have to do

| Starting point | Your work |
|---|---|
| One usable native account | Start setup. |
| Several native accounts | Choose the account. |
| No native sign-in | Complete provider sign-in. |
| An account says sign-in needed | Run `hotpl8 add -Provider claude` and sign in as that account. |
| Missing provider tools | Allow their installation, then sign in if needed. |
| Both providers | Add each; an agent can manage both operations. |
| Provider temporarily unavailable | Finish later; the native sign-in is retained. |

## Signing in

For Claude, setup opens the sign-in page in your default browser and also prints the link, so you can use another browser or device instead. After you sign in, the page shows a code. Copy all of it, paste it into setup and press Enter, or give it to the agent running setup. The pasted code stays visible so you can check it. Pasting the page's address works too. Setup checks the code's shape first, so a partial copy is refused before it reaches Claude. The code goes once to the waiting `claude` login and is never saved. It is useless without that login. Claude's own browser launch is turned off; from the background setup process its tab would open behind your other windows. If Claude rejects the code (for example, one from an earlier sign-in page), setup says so and prints a new link. If the page says a Pro or Max plan is required, that account has no Claude subscription and no code will appear; cancel setup or sign in with another account.

Signing in to an account that needs sign-in repairs it in place. Setup reports "Signed in again" and refreshes its usage. It does not report the account as a duplicate.

Native authentication can require account selection, consent, MFA, or an organization's approval. Those provider steps cannot be bypassed by HotPl8. Never send passwords or tokens to an agent; the one-time code from Claude's fallback page is the only value setup accepts. Native tools own the credentials; HotPl8 stores references and private operation progress.

## Close, retry, or cancel

Close setup whenever you need to. `hotpl8 setup` resumes unfinished first-account setup; `hotpl8 add` resumes an unfinished addition. A completed native sign-in is checked before opening another login. The terminal retries temporary failures, and the agent interface provides a polling interval and explicit next actions.

A connected account whose usage is unavailable remains enrolled. Ordinary collection respects provider backoff and later updates its usage. Setup reports enrollment separately from a fresh observation; it never calls an unread account ready. A duplicate account reuses existing membership instead of adding capacity. If the browser keeps choosing that account, open the next login link in another browser profile or a guest window; an agent can handle opening that window. An unverifiable existing identity can hold enrollment pending until comparison is possible.

Canceling stops further onboarding work and cancels the pending native login when supported. It never logs out an existing account or deletes provider credentials. A policy change committed before cancellation remains enrolled. Use ordinary account controls for an intentional removal.

## Isolation and delivery

New sign-ins use dedicated native directories under the installation's private state. Codex app-server performs browser or device-code login. Claude performs native subscription login; claude-swap captures it without switching the active profile or logging out. Existing sign-ins are reused in their current locations.

The finite onboarding worker is shipped with the application and starts from that same release. Native sign-in has a fifteen-minute budget; reads, downloads, and installers have separate timeouts. Operation state and installed integration tools live outside application code and survive an update or rollback. A stopped worker becomes resumable after a short startup grace period. No always-running onboarding service is installed.

Dependency setup pins Codex 0.155.1, Claude Code 2.1.281, and claude-swap 0.26.0. It reuses existing tools when available. Downloaded native binaries are checked against publisher release checksums; Claude also passes platform signature verification. The optional Python environment belongs to the Claude adapter and is installed by uv. HotPl8's provider actions remain subject to the existing policy.

The [installation guide](install.md) describes the ordinary collector schedule and the separate opt-in main delivery channel. Provider login alone does not enable switching, warming, routing, or T3 integration.
