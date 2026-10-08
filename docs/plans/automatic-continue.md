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
| A Codex conversation's continue needs a different account while its sub-agents are still running | Hold the continue; when they have finished, apply every row of this table again and send it once if it still says so |
| A Codex sub-agent's turn dies on a usage limit and Codex takes no turn started on that sub-agent | Continue the conversation that runs it, once, unless that conversation is in a turn or already has a continue waiting. No message goes to the sub-agent |
| HotPl8 automation is paused | Keep waiting; continue when the pause ends and the rule holds |
| Same conversation hits a limit again within 10 minutes of an automatic continue | Stand down for that conversation (no loop) |
| 6 hours have passed since the failure | Stand down |
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

  A conversation and its sub-agents run in one Codex process with one login, and
  signing that process in to another account can end work that is still running.
  So when the continue needs a different account while sub-agents run, the bridge
  holds it instead of changing the account. The hold can last as long as the
  sub-agents do, so the bridge does not send on the earlier answer when it ends.
  Once the process has no running turn and no admission in progress, it starts
  the waiter again for the same failure, with `-Held` and the time of the
  failure. That waiter applies the whole rule as it stands then: the setting,
  monitor mode, a pause, the six hours and readiness. Only the ten-minute bound
  is different, because the record it would find is this continue's own earlier
  answer, which was never delivered. If the waiter says "continue now" again,
  the bridge admits the turn the ordinary way, with the account chosen at that
  moment; if work has started again by then, the continue is held once more.
  Nothing polls: the waiter is started by the message that reports the last turn
  ending. A user turn or the bridge closing ends a held continue without a
  message.

  A sub-agent has a thread of its own, and its turn can die on the limit while
  the conversation that runs it is between turns. Codex does not start a turn in
  the conversation for that: the failure waits there until its next turn. Codex
  also refuses a turn started from outside on a sub-agent of its current
  multi-agent kind, so a continue sent to the sub-agent is lost. The bridge
  therefore reads what Codex says about the failed thread, `parentThreadId` and
  `canAcceptDirectInput`, and when the thread takes no turn of its own it starts
  the waiter for the thread that runs it instead, following that up to the
  conversation. In the continue's turn Codex hands the conversation the
  sub-agent's failure, with the advice to give it another task; the conversation
  decides. A sub-agent that does take turns, as under the earlier multi-agent
  kind, keeps a continue of its own.

  Codex does not announce a sub-agent's thread to the client, so the bridge may
  first hear of one when it fails. It then asks Codex about the thread with
  `thread/read` before deciding. If the conversation already has a waiter,
  nothing is added. If it is in a turn, nothing is started either: Codex hands it
  the failure before its next request in that turn, and that request meets the
  same limit.

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
- A Codex conversation whose continue needs a different account stays stopped
  for as long as its sub-agents run, however long that is.
- A Codex sub-agent that died on the limit goes on only if its conversation
  gives it another task. HotPl8 continues the conversation; it cannot continue
  the sub-agent.
- A conversation that was in a turn when its sub-agent died, and whose turn then
  ends without failing, gets no continue. That is the case when the sub-agent
  runs a model with a limit of its own, or when the turn was at its last
  request. The conversation is told of the failure before its next request,
  in that turn or the next one.
- Writing in a Codex conversation while its continue is held cancels the
  continue, and the message itself is refused with
  `routing_account_change_deferred` for as long as the sub-agents keep the
  account from changing. It goes through once they have finished; no automatic
  continue follows in the meantime.
- `continue_sent` records the waiter's decision, not delivery. A held Codex
  continue is decided twice, so the event can appear twice for one failure, and
  a held continue that the waiter gives up the second time records
  `continue_skipped`. One that the user cancels leaves no further event, and
  one the bridge cannot start is reported as `routing_continue_failed` on the
  bridge's error output only.
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

On 2026-10-08, on Windows, the same probe with Codex CLI 0.160.0 passed a fourth
case: a conversation spawns a sub-agent and ends its turn, and the sub-agent's
first request is refused on the limit. Codex sent no `thread/started` for the
sub-agent's thread, and its failure started no turn in the conversation.
`thread/read` on the thread returned the conversation's id as `parentThreadId`
and `canAcceptDirectInput: false`. With the second account signed in, a turn
started on the sub-agent was refused with `direct app-server input is not
allowed for multi-agent v2 sub-agents`; the same turn on the conversation was
accepted, and its second request carried the sub-agent's failure.

`tests/test-continue.ps1` covers the waiter's rule offline with fictional
accounts, including a waiter asked again for a held continue, and
`tests/test-t3-codex.mjs` covers the bridge's side, including a continue held
while two sub-agents finish one after the other, one that is held twice, and
sub-agents that die on the limit: announced or not, one below another, with
their conversation between turns, in a turn or already waiting.

## Not yet observed

These need a real subscription, a live host or the other platform, and are
checked at release acceptance. The feature does not depend on them: in each case
the failure mode is that no continue is sent.

- How a real model reacts to the message. Claude Code presents hook text to the
  model as hook feedback, not as user input.
- A live T3 Code installation showing a Codex turn it did not start.
- A real Codex conversation whose sub-agents outlive its limit failure, with the
  held continue and the sub-agents' own failures going through the bridge under
  T3 Code. Both are covered offline, and the second against installed Codex
  without the bridge.
- What a real model does with a sub-agent's failure once its conversation is
  continued.
- macOS: a running Claude picking up a switched keychain login, and the managed
  hook under PowerShell 7. The probe above used a file-based login.
- Hosts other than T3 built on the Claude Agent SDK. The rule excludes only the
  `cli` entrypoint, so any other value is continued.
- Claude Code keeping a waiting hook alive for the full six hours. The timeout
  value is accepted; the wait itself was exercised for five minutes.
