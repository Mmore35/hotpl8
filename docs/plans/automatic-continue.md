# Continue a conversation after a usage limit

## Problem

A turn that runs into a usage limit ends as a failure. HotPl8 then moves to
another account, or the same account's limit resets, but the conversation stays
stopped until someone types into it. Unattended work therefore stops at the
first limit even though a usable account is ready a minute later.

## Behavior

When a hosted conversation's turn dies on a usage limit, HotPl8 sends that same
conversation one plain message, `Automated message: continue.`, as soon as a
usable account is in place. Nothing is said about accounts.

| Situation | Behavior |
|---|---|
| Turn dies on a usage limit, automatic continue on | One waiter starts for that conversation |
| The selected account is the one in use, and it is either a different account from the one that failed or has been read since the failure | Send `Automated message: continue.` once |
| Automatic continue off, monitor mode, or the conversation's host process is gone | Stand down silently |
| The user sends something first | Stand down; never a second message |
| HotPl8 automation is paused | Keep waiting; continue when the pause ends and the rule holds |
| Same conversation hits a limit again within 10 minutes of an automatic continue | Stand down for that conversation (no loop) |
| Waiter has waited 6 hours | Stand down |
| Interactive terminal Claude (`CLAUDE_CODE_ENTRYPOINT` is `cli`) | Stand down; Claude's own resume owns that case |
| Anything unreadable or unexpected | Stand down; the user's next message works exactly as before |

The continue is always a **new** turn. The original prompt is never sent again
and no tool effect is repeated. A missed continue is harmless; a wrong one is
not, so every doubtful case stands down.

## Mechanism

`continue.ps1` is the waiter for both providers. It holds the one rule for when
to continue, whether to continue and the loop bound, read from the collector's
published `status.json`, the policy and the pause state. It exits 2 to say
"continue now" and 0 to stand down.

Only delivery differs, because the two clients offer different ways in:

- **Claude.** Claude Code runs the waiter itself, as a `StopFailure` hook with
  the `rate_limit` matcher and `asyncRewake`. Exit 2 with the message on stderr
  wakes the conversation. The waiter watches Claude's process and the size of
  the conversation transcript, so it ends when Claude closes or the user writes.
- **Codex.** There is no such hook, but the T3 bridge already sits in the
  message stream. When a turn completes as failed with `usageLimitExceeded`, the
  bridge starts the same waiter for that thread. On exit 2 it selects an account
  through the ordinary admission path and starts one new turn with the message.
  A user turn in the meantime stops the waiter.

For example, a conversation on account 1 fails at its five-hour limit. The next
collector pass selects account 2 and switches the Claude login to it. The waiter
sees that the selected account is in use and is not the one that failed, records
`continue_sent`, and the conversation carries on. If account 1 is the only
account, the waiter waits until a reading of account 1 taken after the failure
makes it selectable again.

## Settings

Automatic continue is on whenever the policy is not in monitor mode and
`automation.continue` is not `false`. It does not depend on `switchEnabled`: a
limit that resets on the same account is continued too.

```powershell
hotpl8 continue
hotpl8 continue -Operation disable
hotpl8 continue -Operation enable
```

The first form reports the setting and whether Claude's hook is present, and
changes nothing. `disable` and `enable` change the policy and the hook together.
`hotpl8 doctor` reports the same in one line, with the time of the last continue.

The collector keeps one entry in the `hooks.StopFailure` list of Claude's user
settings file in step with the policy. It adds the entry when automatic continue
is on and a Claude account is enrolled, and removes it when the setting is off.
It changes only its own entry, never creates Claude's settings directory, and
leaves a settings file it cannot read or safely replace untouched, recording
`continue_hook_failed`. A managed installation's entry finds the current release
each time it runs, so an update needs no rewrite. Uninstall removes the entry.
A source checkout that is not an installation gets its entry only from
`hotpl8 continue -Operation enable`.

## Limits

- Under T3 Code a continue can only arrive within about 30 minutes of the
  failure, because T3 closes idle conversations after that. Turn off T3's own
  resume of limited conversations (`autoResumeLimitedThreads`, T3 0.0.46 and
  later) so only one continue is sent; once it is off, the case where every
  account stays exhausted for hours is not covered there.
- The wait is one collector pass in the worst case: about a minute for Claude,
  up to five for Codex.
- If a Codex conversation's sub-agents are still running when the waiter
  finishes, that continue is dropped rather than retried.
- Interactive terminal Claude and plain `hotpl8 codex` sessions are not covered.
- A Claude conversation that was already open when the hook was first added
  picks it up the next time it starts.
- Each waiting conversation holds one small sleeping PowerShell process until it
  continues, its host closes it, or six hours pass.

## Evidence

Two opt-in probes run the installed native clients against a local stand-in for
the provider service, with fixture logins and disposable profile directories. No
real account is read and no prompt leaves the machine. They are not part of the
offline suite.

On 2026-10-04, on Windows:

- `tests/probe-claude-continue.mjs` with Claude Code 2.1.289, in the streaming
  mode hosts use, with the hook installed by `hotpl8 continue -Operation enable`
  and a file-based login. Three cases passed: a different account signed in
  during the wait, the same account's limit reset, and a managed installation
  whose hook finds the current release under a path containing a space. In each,
  one request was refused, the waiter stayed silent while no account was ready,
  and exactly one further request followed within a few seconds of readiness, on
  the expected account and carrying the message.
- `tests/probe-codex-continue.py` with Codex CLI 0.160.0 app-server. Three cases
  passed: a different account, the same account after a reset, and a limit that
  lands after a tool call has finished. The failed turn reports
  `usageLimitExceeded`; the continue is accepted with a new turn id on the same
  thread; the request carries the earlier history including the finished tool
  call and its output; the tool is not run again.

`tests/test-continue.ps1` covers the waiter's rule offline with fictional
accounts, and `tests/test-t3-codex.mjs` covers the bridge's side.

## Not yet observed

These need a real subscription, a live host or the other platform, and are
checked at release acceptance. The feature does not depend on them: in each case
the failure mode is that no continue is sent.

- How a real model reacts to the message. Claude Code presents hook text to the
  model as hook feedback, not as user input.
- A live T3 Code installation showing a Codex turn it did not start.
- macOS: a running Claude picking up a switched keychain login, and the managed
  hook under PowerShell 7. The probe above used a file-based login.
- Hosts other than T3 built on the Claude Agent SDK. The rule excludes only the
  `cli` entrypoint, so any other value is continued.
- Claude Code keeping a waiting hook alive for the full six hours. The timeout
  value is accepted; the wait itself was exercised for five minutes.
