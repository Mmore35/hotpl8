# Compiled program for the display commands and the collector

Status: stage 5 of 6 implemented. `version`, `status`, `explain`, what the tray shows and the dashboard (`hotpl8`, `hotpl8 watch`, `hotpl8 nyan`) are answered by a compiled Rust program, `hotpl8-native`, and by nothing else, and the same program is the collector: every wake runs in it, the reading of Codex accounts included. The launcher asks that program before it starts PowerShell, on Windows and on a Mac. The scheduler starts a wake without PowerShell on Windows and on a Mac that updates itself; the exceptions are under Limits.

Baseline read for this plan: main `b5ebd83986fd4bddabf1f556d7481a98be707a74`. Stage 2 was measured against main `c94ab0da562c07cc9b4f7c8c8d13b953b2d400af`, stage 3 against main `2323e0a640b5dcf4fb2c75e537e0b51bea3eb3bd`, stage 4 against main `9bd58798f54d6e8ddd5559a6602ba766706e5be9`, stage 5 against main `88f2220ad0dea7a27edf8891cb2d6f0091a21627`.

## Behavior

Commands that only print cached state move, one at a time, from PowerShell into one small program. A command that has moved has one implementation. PowerShell keeps no copy of it, and no setting brings one back.

The reason is cost. The dashboard and the read commands are the most frequently run code in the product and the most expensive: a display command spent seconds starting PowerShell and loading modules before it printed, and an animated dashboard held most of a processor core for as long as it was open. Their inputs and outputs are fully defined (cached files, the clock, the terminal), so a replacement can be checked exactly.

Most of that cost is PowerShell starting, so a moved command is asked for before PowerShell starts. On the measuring machine `hotpl8 status` took 2,153 ms through an ordinary installation before this stage and takes 217 ms after it.

The collector moves for the same reason. It is started every minute on every installation, and most of a wake was PowerShell starting and loading modules: 4.0 s on the measuring machine for a wake that reads fictional Claude accounts from a stand-in for cswap and changes nothing, 0.6 s for the same wake in the compiled program.

What the tray shows moves for the same reason. An open tray asks for its view every five seconds. In PowerShell one refresh took 826 ms and about a second of processor time in the tray's own process; asking the program takes 121 ms.

The dashboard moves for the same reason, and it is the one that never ends. With the animation showing, the PowerShell dashboard used 716 ms of processor time every second and held 213 MB for as long as its window was open. The compiled one uses about 8 ms a second and 10 MB, and close to nothing without the animation.

Two pieces of a wake stay in PowerShell, each started only when the wake has that work: keeping Claude's continue hook as the policy says, and closing an account addition the collector has now observed. Setup, onboarding, account management, the agent interface and the T3 bridge are not part of this work.

## Stages

| Stage | What moves | State |
|---|---|---|
| 1 | Packaging and `version` | On main |
| 2 | `status` and `explain`. The reader becomes the only implementation of all three. The Windows launcher asks the reader first. A live preview can run a candidate's reader | On main |
| 3 | The collector. A wake runs in the compiled program and PowerShell's collector is deleted. `tick.ps1` starts the program. The scheduler of a main delivery installation on Windows starts it without PowerShell | On main |
| 4 | What runs unattended. The collector reads Codex accounts itself, and PowerShell's Codex collection is deleted. The tray asks the program what to show, and PowerShell's tray model, alerts, explanation text and work-hours rule are deleted. An ordinary Windows installation, a Mac that updates itself and a newly scheduled ordinary Mac start a wake without PowerShell. The rules still in both languages that nothing compared are held to shared cases | On main |
| 5 | The dashboard. `watch` and `nyan` are drawn by the program, and PowerShell's dashboard and the rules only it needed are deleted. The launcher of a Mac asks the reader first. A live preview shows the dashboard a candidate's reader draws, and nothing in its place | Implemented |
| 6 | The other PowerShell commands (the agent interface, account management, Codex launch and routing, parking, replay, doctor) ask the program for the rules it holds, and PowerShell's copy of them is deleted | Planned |

This plan had five stages. Stage 4 was to have the tray, the dashboard and every other PowerShell command ask the program for its rules, and stage 5 was to draw the dashboard in the program. The order is changed for a measured reason. One refresh of the PowerShell dashboard on the measuring machine spends 264 ms calculating the rules, 549 ms laying out the lines and 140 ms colouring them, and with the animation 278, 637 and 297 ms; the table is under Evidence. A dashboard that asked the program for the rules alone would still spend about three quarters of every refresh in PowerShell, and would be written a second time one stage later. So the dashboard moved once and whole, in stage 5. Stage 4 took what runs with nobody watching: the Codex read of every wake, the tray's refresh every five seconds and the scheduled starts. The commands a person runs by hand a few times a day move last.

## Rules

1. One implementation. A command the reader answers has no PowerShell implementation and no switch to one. A copy whose reader cannot start says so and answers nothing.
2. The reader refuses what it cannot read, in words of its own and with status 1. It does not guess, and nothing else is asked in its place.
3. The contract below is written before the code. Every difference from the PowerShell command it replaced is listed.
4. A rule that is still calculated in two places is compared on every test run, and a stage is named that removes the second place. No rule is added to one place alone.
5. A case or an expected result is never edited only to make a comparison pass.
6. The checks stay cheap enough to run on every change. Starting a program costs more than any answer, so the reader answers all the questions of a check in one start.
7. A launcher file that sessions run from never changes its text. See [the launcher](../install.md#the-launcher).

## What is still calculated twice

A wake is not: it has one implementation, and since stage 4 that includes reading Codex accounts. What `status`, `explain`, the tray and the dashboard show is not either. What PowerShell had only for those is deleted. Stage 3 removed 37 functions and two whole files (`src/warming.ps1` and `src/provider-runtime.ps1`): the Claude collection and its window-opening schedule, warm receipts, the forecast and the usage history, the activity log, collection due times and backoff, attempt budgets, the one reason an action is blocked, and the registered-provider dispatch. Stage 4 removed ten more and two more files (`src/notifications.ps1` and `src/forecast.ps1`): the Codex collection, the tray's model and its details, the alerts, the explanation and overview text, the forecast text, the capacity display and the work hours of a schedule. Stage 5 removed the dashboard: the 59 functions of `src/dashboard.ps1` and `src/presentation.ps1` that laid it out, coloured it, animated it and ran its window, and two in `src/overview.ps1` that only it called. `src/presentation.ps1` is gone and `src/dashboard.ps1` defines nothing; why it is still a file is under Packaging.

Rules that another PowerShell command also needs still exist in both places:

| Rule | PowerShell that still needs it | Held together by | Removed by |
|---|---|---|---|
| Overview, capacity, selection, eligibility, health, pauses, policy and provider-definition checks, with the Codex selection and the Codex policy check | The agent interface, account management, installation and delivery (`src/insights.ps1`, `src/overview.ps1`, `src/provider-registry.ps1` and the modules they call) | The parity suite, on every run: both are asked the same questions about the same files | Stage 6. What only the dashboard needed went in stage 5 |
| What an account's limits mean (`ConvertTo-CodexBuckets`) | Codex launch and routing | `tests/parity/codex-buckets.json`: 102 cases, read by `tests/test-codex.ps1` and by the program's tests | Stage 6 |
| The conversation with the Codex program and the search for it (`Read-CodexQuota`, `Resolve-CodexExecutable`) | Codex setup, launch and routing, account management, onboarding, parking | Not case for case. Each side is tested against a stand-in that plays the same scenarios: `tests/test-codex.ps1` with `tests/fake-codex.cs`, and `native/src/codex_read.rs` with `native/examples/codex_stand_in.rs` | Stage 6 |
| The switch hold (`Get-Hold`) | Launch-time authorization, the agent interface | `tests/parity/shared-rules.json` | Stage 6 |
| The generation of the control files and what an action is told of them (`src/provider-actions.ps1`) | Codex launch and routing, parking, pauses | `tests/parity/shared-rules.json` | Stage 6 |
| Replay of each ordering's choice (`src/replay.ps1`) | `scripts/replay.ps1` | `tests/parity/shared-rules.json`, with `replay-frames.txt` and `replay-expected.txt` | Stage 6 |
| Finding cswap and how long its account list may take | Account management, onboarding, parking, doctor | `tests/parity/shared-rules.json` | Stage 6 |
| The kind a failure is recorded under (`Get-Hotpl8FailureCode`) | The lanes and doctor | `tests/parity/shared-rules.json` | Stage 6 |

`tests/parity/shared-rules.json` holds 55 cases and the time limit. `tests/test-shared-rules.ps1` asks PowerShell each one and the program's unit tests ask the program the same lines, on every run. For the control cases the file also holds the answer: `-Update` on the PowerShell suite records what PowerShell says, and the program must then say the same. An answer that depends on the machine, such as a time in the machine's own zone, is not recorded there; each side checks that input with the zone in hand.

So rule 4 holds for every row but one. The rows stage 3 listed as not compared are compared now, and the first run of their cases found four places where the collector already on main disagreed with PowerShell. Two were the program being stricter than it needed to be about a switch hold, and are corrected. Two are refusals the program keeps, and are listed under [the wake's differences](#differences-from-the-powershell-collector). The row that is still not compared case for case is the conversation with the Codex program.

The PowerShell half of the shared cases runs on Windows only. The program's half runs on both platforms. A rule that changes is changed in both, in one commit. When the last PowerShell caller of a row moves, its PowerShell side and its comparison go together, and the cases stay as the program's own expected results. Text formatting is not duplicated: PowerShell has no `status`, `explain` or tray text, and draws no dashboard.

The release in force is read in three places: delivery's Python, `launch.ps1` and the program's front door. That is one file format with three readers, not a rule decided twice, and no stage removes it while PowerShell commands remain. `tests/test-native.ps1`, `tests/test-lifecycle.ps1` and `tests/test_macos_delivery.py` send each of them into the same installation.

## How it runs

The launcher asks the reader, in the words typed after `hotpl8`. On Windows:

```text
hotpl8 <words>
  hotpl8.cmd           one line that hands over to hotpl8-launch.cmd
  hotpl8-launch.cmd    bin\windows\hotpl8-native.exe user <words>
                         0      the reader answered
                         1      the reader refused, and said why
                         other  powershell -File hotpl8.ps1 <words>
```

On a Mac the installed `hotpl8` is a shell script that does the same: it runs `bin/macos/hotpl8-native user <words>`, ends with the reader's status when that is 0 or 1, and starts `pwsh -File hotpl8.ps1 <words>` for any other. On a Mac that updates itself the launcher is delivery's Python (`delivery/macos.py`). It runs `<release>/bin/macos/hotpl8-native ask <installation> <words>` for the release it chose, ends with 0 or 1, and starts `launch.ps1` for any other.

The reader takes the words as its own when the first is `status`, `explain`, `version`, `watch` or `nyan` in any letter case, or when there is no command word, which means `watch`. The rest may only be `-StateDirectory <directory>`, `-PreviewPolicy <file>` and `-CodexExecutable <path>`, with `-AsJson` for the first three and `-ReducedMotion` and `-NoColor` for the dashboard, each by its whole name and once. `version` takes only `-AsJson` and `-CodexExecutable`. For any other words, an abbreviated parameter or a `-Name:value` spelling included, it ends with status 64 before it prints anything and PowerShell is started with the same words. `tray` is among the other words: a user who types it opens the tray's window, which PowerShell draws. A dashboard for a user with no policy, or with no account in it, is left to PowerShell the same way: taking a first account in is PowerShell's. The launcher holds no list of commands, so a command that moves later needs no new launcher.

`hotpl8.ps1` is the other way in: it is what a script calls and what a launcher falls through to. It loads `src/native.ps1` before any other module. A request for `version`, `status`, `explain` or `tray -Once` with no parameter beyond those above is handed over at once. One with other parameters is checked like any command and then handed over too. `watch` and `nyan` reach it when they were started some other way than through a launcher, or when the user had no account a moment ago: it runs the guided setup, or says that every account is parked, and otherwise hands the dashboard over. With a terminal at both ends it starts the reader on that terminal; anything else is passed the one frame the reader prints.

```text
hotpl8-native <version|status|explain|tray> --root <release> [--state <directory>] [--policy <file>] [-AsJson]
hotpl8-native <watch|nyan> --root <release> [--state <directory>] [--policy <file>] [--reduced-motion] [--no-color]
```

The reader prints the answer and ends with 0, or prints `HotPl8: <reason>` on standard error and ends with 1. `hotpl8.ps1` passes on either. When the reader's file is missing or cannot be started, `hotpl8.ps1` prints `HotPl8: This copy has no compiled reader it can start, and this command is answered by it. A release ships one; in a checkout, build it with scripts/build-native.ps1.` and ends with 1. For `watch` and `nyan` the same sentence says `and the dashboard is drawn by it`.

An open dashboard has one more ending, 75: the release it was started from is no longer the one in place, and the dashboard of the one that is should open in the same window. What started it opens that one. The copy beside a delivery launcher and `launch.ps1` each start the dashboard of the release now in force. A Windows or Mac launcher of an ordinary installation falls through to `hotpl8.ps1` as for any status that is not 0 or 1, and `hotpl8.ps1`, when the dashboard it started ends with 75, runs itself again from the file now on disk.

A [main delivery installation](../delivery.md) keeps a copy of the reader beside its launcher. That copy answers nothing itself. For words the reader owns it takes the shared lease on `runtime.lock` that every running command holds, reads `current.json`, and starts the reader of the release in force with the same words, the installation's state directory and its installation directory. It passes on 0 and 1. Anything else, a failure of its own included, becomes 64, so `launch.ps1` runs as before and reports the problem in its own words. A dashboard is the exception to the lease: it stays open for days and an update must not wait for it, so the copy holds none while one is open, as `launch.ps1` never did.

For `status` and `explain` the reader finds the state directory as PowerShell did: the parameter, then `HOTPL8_STATE_DIRECTORY`, then `stateDirectory` in the release's `install-state.json`, then the release directory. It reads the clock once per request, and reads `data/providers/*.json` and `data/capacity-profiles.json` from its own release when it runs.

Numbers are calculated as the PowerShell that collects on the platform calculates them: Windows PowerShell 5.1 on Windows, PowerShell 7 elsewhere. The two disagree about number types (5.1 reads `1.5` as a decimal and whole numbers as 32-bit; 7 reads them as a double and 64-bit), about rounding ties and about how a double is written, and the collector's own results are what the commands show.

The tray's window is drawn by PowerShell (`src/tray.ps1`) and shows what the reader answers. When it opens and every five seconds after, it starts `hotpl8-native tray --root <release> --state <directory>` and shows the title, the lines and the new announcements of the answer, which is always JSON. `hotpl8 tray -Once` prints that answer.

A wake is one start of the program:

```text
hotpl8-native collect --root <release> [--state <directory>] [--cswap <program>] [--codex <program>]
                      [--powershell <program>] [--scheduled] [--observe-only] [--strict]
```

It takes `tick.lock`, reads `policy.json` and the control files, reads every registered provider that is due, checks the readings against each other, adds the forecast, history, activity and shadow decisions, and replaces `status.json` and its mirrors. It prints one line per account action. A scheduled wake ends with 0 whatever happened; with `--strict` a wake that could not read or store something ends with 1. `collector.json` records the outcome and the commit the program was built from.

`tick.ps1` keeps its path and its parameters (`-StateDirectory`, `-CswapExecutable`, `-CodexExecutable`, `-ObserveOnly`, `-Strict`, `-Scheduled`). It starts the program with the matching arguments, prints its lines and ends with its status. `hotpl8 tick` and `hotpl8 refresh` call it as before. A copy without a compiled program says `HotPl8: This copy has no compiled collector it can start.` and collects nothing.

Claude accounts are read and acted on inside the program: `cswap list --json`, each account's plan, the decision, `cswap switch`, and the one small request that opens a window. Codex accounts are read inside it too: for each enrolled home that is due, the Codex program is started in that home and asked four questions over its standard streams, as [the contract](#contract-reading-codex-accounts) says. The search for the Codex program runs once per wake.

What stays in PowerShell is `src/lane.ps1`, one start per piece of work, answering with one line of JSON:

| Lane | Started when | Does |
|---|---|---|
| `continue` | The policy, the hook record or Claude's settings file changed since the lane last finished | Adds or removes Claude's continue hook. What it was run for is kept in `continue/upkeep.json` |
| `onboarding` | An account addition is waiting for the collector to see the account | Closes it |

A wake with nothing changed starts no PowerShell at all. On Windows a lane runs in Windows PowerShell 5.1; elsewhere in the PowerShell named with `--powershell`, or `pwsh`.

What the scheduler starts every minute depends on the installation:

| Installation | Started |
|---|---|
| Updates itself, Windows | The copy of the program beside the launcher, with the one word `wake`. That copy takes the shared lease on `runtime.lock`, reads `current.json` and starts `collect --scheduled` in the release in force. A release from before stage 3 that a rollback puts back in force has no compiled collector, and the copy starts its `tick.ps1` in PowerShell as `launch.ps1` did. The task is registered this way only when the copy beside the launcher is the release's own, and with `tick.ps1` otherwise |
| Updates itself, Mac | The job runner (`delivery.py job collector`), which starts the program of the release in force as `wake <installation> --powershell <pwsh>` with the installation's runtime bindings. The program takes the same lease, reads the same pointer and starts `collect --scheduled` with those words in the release in force |
| Ordinary, Windows | The collector of the release under `app`, when that release and the one kept under `previous` both have one. Otherwise `tick.ps1` through PowerShell, which every release answers to |
| Ordinary, Mac | The compiled collector, with the PowerShell its lanes are to use, for a job this release writes. A job written earlier starts `tick.ps1` through PowerShell and is kept |

An update in progress is not a failure anywhere: the wake ends with 0 and the next one collects. Whichever way a wake is started, it is the same collector.

Further arguments exist for the tests, and no launcher or script sends them: `--now <instant>` and `--zone <minutes>` answer for that instant and offset instead of the machine's; `--shell desktop|core` chooses the number rules; `--dump`, with `-AsJson`, prints each number's type and exact digits; `batch <file>` answers many requests in one start. For `watch` and `nyan`, `--size <columns>x<rows>` prints one frame as a terminal of that size would show it and ends, with `--offset <lines>` scrolled, `--at <seconds>` into the animation, `--frozen`, `--colours true|indexed`, and `--plain` or `--ansi` for the text alone or the escape sequences a terminal is sent. `hotpl8-native self-check` prints `hotpl8-native sha=<commit>` for the build script, delivery and the tests. The build commit is compiled into the binary by `scripts/build-native.ps1`; CI builds the file once per platform, tests that file and packages that file.

## Contract: `version`

| Behavior | Label | Notes |
|---|---|---|
| `hotpl8 version` prints `<VERSION> main <first 12 characters of sha>` for a release with a build identity, the bare version otherwise, exit 0 | Preserve | |
| `VERSION` is read as UTF-8, with or without a byte order mark, and trimmed | Preserve | |
| A missing, null or empty `sha` in `build-info.json` prints the bare version | Preserve | |
| `version -AsJson` reports `version` and the whole build record in file order | Preserve | Layout as for the other commands, below |
| A copy without a `VERSION` file, or with one that names no version | Change on purpose | Refused: `This copy of HotPl8 has no VERSION file.` or `This copy of HotPl8 has a VERSION file that names no version.` |
| `version` no longer loads the other modules, resolves the state directory or prepares onboarding tools | Change on purpose | A fault in those steps no longer stops `version` from printing |
| `version` with `-StateDirectory` or another parameter it does not read | Preserve | Goes through PowerShell's usual checks first; the reader then answers |

## Contract: `status` and `explain`

| Behavior | Label | Notes |
|---|---|---|
| `hotpl8 status` and `hotpl8 explain` print the same lines for the same files at the same instant, exit 0 | Preserve | Compared with `tests/parity/expected-status.txt` and `expected-explain.txt`. The first version of each was what PowerShell printed; faulty lines of `explain` were then removed on purpose, listed under [the tray's differences](#differences-from-the-powershell-tray) |
| `-AsJson` reports the same properties with the same values and number types | Preserve | Compared value by value and type by type with what PowerShell's rules calculate |
| `-PreviewPolicy FILE` and the state directory order | Preserve | |
| `No cached status. Run hotpl8 refresh.` and `No observation. Run hotpl8 refresh.` | Preserve | |
| `No valid policy.json. Run hotpl8 setup or see docs/install.md.` and the policy checks | Preserve | The same words |
| The stale notices: a reading older than 900 seconds or more than 5 seconds ahead of the clock | Preserve | |
| Agent pauses, the manual pause, and an invalid pause file | Preserve | |
| Reset times in the Codex lines use the machine's time zone | Preserve | |
| Provider definitions and policies are checked by the same rules, with the same messages | Preserve | See the exceptions below |
| `refresh` and `tick`, which print status after collecting | Preserve | Not moved; they still run in PowerShell |

### Differences from the PowerShell commands

| Difference | Notes |
|---|---|
| `HOTPL8_NATIVE` is not read | There is no PowerShell implementation to choose |
| Layout of `-AsJson` text | Two-space indentation, `\uXXXX` for every non-ASCII character, and objects PowerShell built from hash tables in a fixed key order. The two PowerShell versions already differed from each other here. Numbers are written as the platform's `ConvertTo-Json` writes them |
| Output does not follow regional formats | PowerShell formatted some numbers and times by the regional settings of the session. The reader always writes what an English session wrote |
| Numbers follow the platform, not the caller | `pwsh` on Windows gets Windows PowerShell 5.1's numbers, the ones the collector on that machine calculates |
| A state file that is not JSON as HotPl8 writes it is refused | PowerShell's parser took comments, trailing commas, single-quoted text, repeated or empty property names, `\/Date(...)\/` text, a number beyond 64 bits or with more digits than a decimal holds, and `-0.0`. The reader refuses each and names the file and the place: `status.json is not JSON as HotPl8 writes it (line 1, column 2).` It also refuses a file over 1,000,000 bytes or nested more than 20 deep |
| A time that is not `yyyy-MM-ddTHH:mm:ss[.fraction]` with `Z` or an offset is refused | PowerShell parsed many other forms by regional rules |
| A value of a kind the rules do not expect is refused where PowerShell's own conversion was an accident | An array where an object belongs, a lease ledger that is not an object, a one-item list holding another list, an identifier edited to hold non-ASCII text, provider IDs whose order depends on the machine's sorting tables. The refusal names the line of the reader's source that stopped: `This state cannot be shown: one of its values is not one HotPl8 writes (<file>:<line>). Run hotpl8 refresh; if that changes nothing, run hotpl8 doctor.` |
| Provider definitions: a file that is not strict JSON | `codex.json is not JSON as HotPl8 writes it (line N, column M).` in place of `Invalid provider definition JSON.` A copy without `data/capacity-profiles.json` says `This copy of HotPl8 has no data/capacity-profiles.json.` |
| A number written with an exponent is read as the nearest double | Windows PowerShell 5.1 reads about one such number in five thousand one unit in the last place away, and writes about one double in two thousand with fifteen digits where seventeen are needed or the reverse. The reader's text always reads back as the double it wrote. `1e400`, `1e-400`, `5E-324` and `-0e0` are refused |
| `status` does not stop on a schedule time zone the machine does not know | PowerShell failed the whole command |
| The clock is read once per request | PowerShell read it at each use, a few milliseconds apart |
| The reader is not stopped after a time limit | It reads a bounded amount and starts nothing |
| On Windows the plain spellings do not start PowerShell | A profile-free PowerShell start was the larger part of each command. Output sent to a file or a pipe is written in the console's code page with CRLF line ends, as Windows PowerShell wrote it; this is compared byte for byte |
| Every other command costs one reader start more on Windows | About 0.1 s; see Evidence |
| A command typed in a dashboard's window after the launcher under it is removed | See [the launcher](../install.md#the-launcher) |
| An install, update or rollback that meets a release whose reader is answering | The reader runs for about 0.1 s. An update moves the release aside, which Windows allows under a running program. A rollback or an uninstall on Windows removes it, and since stage 5 refuses before it removes anything; see [the dashboard's differences](#differences-from-the-powershell-dashboard). Main delivery waits for the lease |

## Contract: a wake

| Behavior | Label | Notes |
|---|---|---|
| `status.json`, `status.js`, `status.txt`, `collector.json`, `events.jsonl`, `history.jsonl`, `activity.json`, the warm receipts, attempt records and `cred-audit.log` hold the same data for the same inputs | Preserve | Compared as data, file by file, with the PowerShell collector before it was deleted; see Evidence |
| The same decisions: which account is switched to, which window is opened, which probe is sent, and which of them a pause, a hold, the schedule, a budget or monitor mode blocks | Preserve | |
| The lines a wake prints, and its exit status with and without `-Strict` | Preserve | |
| `tick.lock` first, then `action-control.lock`; a second wake that finds the first lock held leaves | Preserve | |
| Due times and backoff: a healthy provider on its own interval, a failing one after 5, 10, 20 and then 30 minutes, a local write failure at the next wake | Preserve | |
| A failed read never looks fresh, never authorizes a credential change, and leaves the last complete snapshot in place | Preserve | |
| `tick.ps1` and its parameters | Preserve | `-CodexReader`, which only tests passed, is gone |
| Codex accounts | Preserve | Read by the program since stage 4; see [reading Codex accounts](#contract-reading-codex-accounts) |
| The continue hook and onboarding completion | Preserve | Still PowerShell, in a lane |
| Byte order marks and line ends of the files a wake writes | Preserve | The status files with a mark, `cred-audit.log` without, as PowerShell wrote them on the platform |
| A byte order mark at the start of what cswap prints is not part of its answer | Preserve | |

### Differences from the PowerShell collector

| Difference | Notes |
|---|---|
| `warmOutcome` of an account with no warm request is `null` | Windows PowerShell 5.1 wrote an empty object, and the dashboard showed an empty `warm:` note for it |
| Members of a file PowerShell built from a hash table come in one fixed order | Their order used to depend on the PowerShell version. The data is the same |
| `recentActions` are sorted by their times as plain text, and events of one instant keep the order they were recorded in | PowerShell sorted by the session's language rules, and Windows PowerShell 5.1 could reorder events of one instant |
| A lane that does not answer (it could not start, ran out of its 90 seconds or printed something else) has failed, and what it was for waits for the next wake: `continue_hook_failed` is recorded for the continue hook, and an account addition stays open | There was no second process to fail |
| The continue hook is looked at only when one of its inputs changed | PowerShell rewrote or checked it on every wake. The memo is `continue/upkeep.json` |
| The onboarding step runs only when an addition is waiting | PowerShell loaded the onboarding modules on every wake |
| Lanes on Windows always run in Windows PowerShell 5.1 | A wake started from `pwsh` used to do all of its work in `pwsh` |
| cswap is looked for on `PATH` as `.com`, `.exe`, `.bat` or `.cmd` | PowerShell also found scripts and aliases, which it could not start as a program |
| A credential file over 1 MiB is unreadable | PowerShell read any size |
| A state file that is not JSON as HotPl8 writes it is unreadable | PowerShell's parser took comments, trailing commas and single-quoted text. An unreadable pause still blocks every action, an unreadable hold still blocks nothing, and an unreadable record of the collector's own is still started over |
| A Codex collection that fails is recorded with the program's own failure code and place | The lane reported a PowerShell file and line |
| `codex-state.json` is written in the layout of `status.json`, two-space indentation | Windows PowerShell's wide layout. The data is the same, and every other reader of the file reads it as data |
| A Codex collection uses the policy and the previous snapshot the wake already read | The lane read `policy.json` and `status.json` a second time |
| A switch hold whose time is spelled with a small `t` or `z`, or whose `reason` is a list, is a hold | Found by the shared cases in the collector stage 3 put on main, which dropped both. PowerShell held, and a hold that is dropped lets a switch through. The program now reads them as PowerShell does: a list's items joined by spaces |
| A `hold.json` that is a list of objects, or whose `reason` holds an object inside a list, is no hold | Found the same way and left as it is: PowerShell read the members of the list's items and held under a reason such as `@{a=1}`. Pinned in `native/src/automation.rs` |
| A pause whose `until` is a date with no time is a pause that cannot be read | Found the same way and left as it is: PowerShell took it as a pause until that midnight. It blocks every action either way, and the program also marks the state unsafe. Pinned in `native/src/control.rs` |
| A hold whose `until` is a date with no time ends at the machine's own midnight in both | No difference, but not a shared case: the answer carries the machine's time zone, so each side checks it with the zone in hand |

## Contract: reading Codex accounts

| Behavior | Label | Notes |
|---|---|---|
| Each enrolled home that is due is read once: the Codex program is started in that home as `codex app-server --stdio` with `CODEX_HOME` set to it, and asked `initialize`, `account/read` without a refresh, `account/rateLimits/read` and `config/read` | Preserve | The same messages; see the differences for their spelling |
| The program is given none of the caller's `CODEX_ACCESS_TOKEN`, `CODEX_API_KEY`, `OPENAI_API_KEY` or `CODEX_SQLITE_HOME` | Preserve | |
| No sign-in is refreshed, and no token is kept, printed or passed on. A refusal is told by its number alone | Preserve | |
| One read has 12 seconds, and a home another HotPl8 process is reading is `home_busy` | Preserve | The lock of a home is the same file in both languages, so a wake and a launch still exclude each other |
| A read that fails is named as before: `home_missing`, `home_busy`, `codex_missing`, `native_codex_required`, `subscription_login_required`, `authentication_required`, `access_denied`, `rate_limited`, `rpc_failed`, `invalid_json`, `response_too_large`, `timeout`, `process_exited`, `transport_failed` | Preserve | |
| An account signed in with a key is `subscription_login_required` | Preserve | |
| What an account's limits mean: the two measured meters and their windows, a limit HotPl8 lists without measuring, a blocked meter, a reset that slides | Preserve | 102 shared cases, answered by both |
| Which accounts a wake reads and in what order: the one attempted longest ago first, none that is disabled or backing off, none once the wake's time is spent, a busy home asked again inside it | Preserve | |
| What was last read is kept when a read fails. A record follows the sign-in it was read from, and one that is not this home's starts over. One subscription in two homes is not counted twice | Preserve | |
| The recommendation for each meter, the hold and the meter asked for | Preserve | The selection rules were already the program's, for `status` |
| `codex-state.json`, `codex-observations.jsonl` cut back to its last lines, and the provider's part of `status.json` | Preserve | Compared as data with the PowerShell collection before it was deleted |
| The Codex program used: the one named; then the one HotPl8's setup installed; then the first `codex.exe` on `PATH`; then the single native program inside the package a `codex` command on `PATH` belongs to; then, off Windows, `codex` on `PATH`. A named script is `native_codex_required`, and none found is `codex_missing` | Preserve | See the differences for the bounds of the search |
| `-CodexExecutable` on `tick.ps1`, and `--codex` on `collect` | Preserve | |

### Differences from the PowerShell Codex collection

| Difference | Notes |
|---|---|
| Accounts last attempted at the same instant are read in policy order, and the order is by the instant, not its text | Windows PowerShell 5.1's sort is not stable, so two such accounts could be read in either order |
| Requests are written in one fixed member order and end with a line feed on every system | PowerShell ended them with CRLF on Windows. The messages are the same |
| An answer and `auth.json` are read by the program's own JSON reader, as UTF-8 | A member with no name, a name outside printable ASCII or a name PowerShell keeps for itself is passed over, where PowerShell answered `invalid_json` for the first and last. `/Date(` text stays text. A number with leading zeros, a raw control character inside text and an empty answer are `invalid_json`. A number too long for an integer is a double, where 5.1 made a decimal. An `auth.json` over 16,000,000 bytes is not read |
| A message that is a list is read past, and so is one whose `id` is a list | PowerShell took the list's items one by one and answered `invalid_response`, and read `[1]` as 1 |
| An error `code` that is a list or an object is `rpc_failed` | PowerShell joined a list's items into one code |
| The account's type must be the word `chatgpt` as text | PowerShell also passed `true` and a list holding the word |
| A limit's name or a plan's name that ends in a line break is not a name | PowerShell's pattern allowed one |
| A limit holding a list or an object where a number, a word or a yes-or-no belongs is `unsupported`, with no windows | PowerShell could answer `unsupported` with windows, `blocked`, or one answer per item |
| `hold` in the result is an object with `until` and `reason` | PowerShell's was a hash table, whose member order varied |
| A request that cannot be written because the program has gone is `process_exited` | In PowerShell the same moment was sometimes `transport_failed` |
| Anything else inside one read that cannot be understood is `transport_failed` | PowerShell's error for it varied with where it stopped |
| A line longer than 1,048,576 UTF-16 units is refused when it passes that length; a line ending in a lone carriage return is delivered at once | PowerShell read the whole line first |
| The search for the Codex program runs once per wake | Once per account |
| The search does not look in the two Unix library directories on Windows, uses the other architecture's single program when this one's is absent, follows no directory links and goes 16 directories deep at most | PowerShell searched without those bounds |
| A kept record of the wrong kind in `codex-state.json` makes that account start over, and a retry time that cannot be read is no backoff | PowerShell stopped the whole collection |
| A home written with Windows short names is read as its long name for as much of the path as exists | Windows PowerShell 5.1 left some short names as written when the end of the path did not exist. Such a home is `home_missing` either way. Off Windows `~` is an ordinary character. A home whose long name is not printable ASCII is not read |

## Contract: what the tray shows

| Behavior | Label | Notes |
|---|---|---|
| The title, the lines of the window and the announcements for the same files at the same instant | Preserve | Compared with PowerShell's tray model before it was deleted; `tests/parity/expected-tray.txt` holds them now |
| An announcement is made only when the policy asks for it and inside the schedule's work hours | Preserve | |
| Which announcements were already made, the icon, the menu and the five-second timer | Preserve | Still `src/tray.ps1`, and nowhere else |
| `hotpl8 tray` opens the window; `hotpl8 tray -Once` prints the view and opens nothing | Preserve | The front door leaves `tray` to PowerShell; `tray -Once` is handed to the reader |
| `tray -Once` prints `providerOverview`, `title`, `details` and `alerts` | Preserve | And one member more; see below |

### Differences from the PowerShell tray

| Difference | Notes |
|---|---|
| `tray -Once` also prints `notify`, whether announcements are asked for | The window needs it, and it asks the same question |
| Each refresh checks the policy as `status` does | PowerShell checked it when the tray started. A policy that becomes invalid while the tray runs shows `HotPl8 - view unavailable` until it is valid again |
| A missing policy is refused with `No valid policy.json. Run hotpl8 setup or see docs/install.md.` | `Provider configuration requires a policy object.` |
| State the reader cannot read faithfully is refused, and the window shows the view as unavailable | PowerShell's tolerant rules showed something. The refusals are those of `status` |
| A provider whose name holds `$` is refused | |
| A line that begins with one of four letters outside ASCII that some comparisons fold to an ASCII letter (U+0130, U+0131, U+017F, U+212A) is not taken for the line it resembles | PowerShell's comparison folded them |
| Errors of `tray -Once` are in the reader's words | |
| Each refresh starts the program once | PowerShell calculated the view inside the tray's own process |
| `Claude: <reason>; policy <policy>` is shown for Claude's decision | PowerShell's tray left out lines by how they began, to drop the overview it showed separately, and Claude's decision line went with them. The program asks for the explanation without its overview, so nothing is filtered |
| No line for an account, a decision or a reserve that is not there, in the tray and in `explain` | PowerShell printed `Codex  []: NO OBSERVATION` without a Codex account, `Codex : next launch none; policy` and `  : ; reserve=` without a decision, and announced `codex//no-eligible` with nothing wrong. These four were found by reading the first expected files |
| `Show-Hotpl8Tray` has no `-Once`, and `src/notifications.ps1` and `src/forecast.ps1` are gone | For a script that loaded them |

## Contract: the dashboard

| Behavior | Label | Notes |
|---|---|---|
| `hotpl8`, `hotpl8 watch` and `hotpl8 nyan` show the same frame for the same files at the same instant: every character, and the foreground and background colour of every cell | Preserve | Compared cell by cell with the PowerShell dashboard before it was deleted, in twelve views of every case; see Evidence. `tests/parity/expected-watch.txt` holds the frame of each parity case now |
| The layout by size: 110 columns at the widest, the compact layout under 32 rows, and `Make the terminal larger.` under 48 columns or 17 rows | Preserve | |
| The animation: the same sprite, rainbow and stars at the same moment, in both sprite sizes, and the frozen frame | Preserve | The frames are still `data/nyan-frames.json`; `THIRD_PARTY_NOTICES.md` names their source |
| Colours: 24-bit, and the fixed 256-colour palette in Apple Terminal | Preserve | |
| Keys: Q, Escape and Ctrl+C close it; Space freezes and resumes; the arrows, Page Up, Page Down, Home and End scroll, a page being ten lines | Preserve | |
| The state is read again every second unless frozen. Only files are read: no provider is started and no file is written | Preserve | |
| `-ReducedMotion`, `-NoColor`, `NO_COLOR`, `HOTPL8_REDUCED_MOTION`, and `display.reducedMotion` and `display.noColor` in the policy | Preserve | |
| Output or input that is not a terminal is given one plain frame, 100 columns wide and as tall as it needs, and the command ends | Preserve | |
| On leaving, the terminal is as it was found: its screen, cursor and input mode, and on Windows its title | Preserve | |
| The dashboard of a main delivery installation names its release and update state in the window title, `HotPl8 main <12 characters> \| <state>`, and ends with 75 within about a second of another release coming into force; that release's dashboard opens in the same window | Preserve | |
| A user with no policy or no account is taken through guided setup, and one whose accounts are all parked is told so | Preserve | Still PowerShell; the reader answers 64 for both |
| The documentation images | Preserve | The 13 images drawn from the reader's frames are byte for byte those drawn from the PowerShell dashboard |

### Differences from the PowerShell dashboard

| Difference | Notes |
|---|---|
| State the reader cannot read faithfully is refused | The refusals are those of `status`: a state file that is not JSON as HotPl8 writes it, a value of a kind the rules do not expect, an account list that cannot be read. PowerShell's tolerant rules drew something. In the comparison this was 456 of 3,600 frames, all from cases written to be malformed |
| A Codex limit whose window is not named by plain digits, or two windows of one limit with the same number, is refused | |
| A line holding characters two cells wide is padded by cells | PowerShell counted characters, so the right edge of such a line stood out by one cell for each wide character. 10 of 3,600 compared frames, all of the case with labels outside ASCII |
| Characters that take no cell or control the terminal are found by one fixed table | PowerShell asked the .NET it ran on, whose tables differ between 5.1 and 7 |
| A reset day is named in English | PowerShell used the language of the session |
| A badge's colour is chosen by comparing ASCII letters without regard to case | PowerShell's comparison folded some letters outside ASCII onto ASCII ones |
| The escape sequences sent to a terminal are fewer: a colour is named only where it changes, and a blank cell is given no foreground | The cells shown are the same |
| A row that has stopped moving is drawn once more, at rest | PowerShell left it as it last moved until the next layout, up to a second later |
| The policy is checked every second, as `status` checks it, and `display.noColor` takes effect while the dashboard is open | PowerShell read the policy every second without checking it, and read `display.noColor` once, when the dashboard opened. A `-PreviewPolicy` file is read every second too; PowerShell read it once |
| State that cannot be read while the dashboard is open leaves the last frame in place for 5 seconds and then shows the reason, until it can be read again | An error in PowerShell's layout worker ended the dashboard |
| Layout runs between frames in the one thread | PowerShell laid out in a second runspace so that its layout, most of a second of work, did not stall the animation. The program reads the state and lays out a frame in about 3 ms |
| With colours off, the dashboard still opens on the terminal's alternate screen | PowerShell drew on the ordinary screen with cursor moves, and its last frame stayed there |
| A Windows console that does not take escape sequences is given one plain frame, like a pipe | PowerShell drew on it with cursor moves |
| An open dashboard of an ordinary installation ends with 75 within about a second of an update, and the new release's opens in the same window | PowerShell's ran the old release's code until it was closed |
| A dashboard whose release directory has gone ends with 75 after three looks | Three seconds, so that an installer moving directories is not taken for a removal |
| A terminal that takes no more output ends the dashboard with 1 | |
| **A rollback or an uninstall of an ordinary Windows installation is refused while a dashboard of it is open** | Windows does not remove the file of a program that is running, and the PowerShell dashboard held no such file. `rollback.ps1`, `uninstall.ps1` and the installer's removal of the kept release now look for a program in use before they remove anything, and say `HotPl8 cannot remove <file> while it is in use: a dashboard or a command of this installation is still running. Close it and run this again. Nothing was removed.` An update is not affected: it moves the release aside, which Windows allows |
| On a Mac the installed command starts no PowerShell for what the reader owns | It started PowerShell for every command |
| On Windows the plain spellings of `hotpl8`, `hotpl8 watch` and `hotpl8 nyan` start no PowerShell | A dashboard reopened after an update, or opened by guided setup, has `hotpl8.ps1` as its parent for as long as it is open |
| A live preview shows only a candidate's compiled dashboard | A candidate with no reader for the system, or whose reader leaves the dashboard to PowerShell, ends the preview with a message; see [previewing](#previewing-a-candidates-reader). The fictional policy a preview stages must be a valid policy |
| The documentation images are drawn with the fixture's clock and UTC passed to the reader, so every machine draws the same frame | The PowerShell harness left the time zone to the machine |
| `src/presentation.ps1` is gone and `src/dashboard.ps1` defines nothing | For a script that loaded them. `Show-Hotpl8Dashboard` and `Get-Hotpl8DashboardFrame` no longer exist |

## Contract: scheduled starts

| Behavior | Label | Notes |
|---|---|---|
| One collector per installation, started every minute under the same task or job name, with the same state directory | Preserve | |
| A wake during an update collects nothing and is not a failure | Preserve | |
| An installation whose task or job was written by an earlier release keeps working without being touched | Preserve | The task of an ordinary Windows installation is registered again by each update; a Mac job is kept |

### Differences from the scheduled starts before

| Difference | Notes |
|---|---|
| The task of an ordinary Windows installation names the collector: `<app>\bin\windows\hotpl8-native.exe collect --root <app> --state <state> --scheduled`, behind the same hidden host and its time limit | Only when `app` and the release kept under `previous`, if there is one, both have a compiled collector and `src/lane.ps1`. Otherwise it names `tick.ps1` as before |
| Such a task no longer prints `tick.ps1`'s message for a copy without a collector | The installer refuses a copy without one |
| The job of a Mac that updates itself starts `<release>/bin/macos/hotpl8-native wake <installation> --powershell <pwsh>`, then the installation's runtime bindings and `--observe-only` when it is set | It started `delivery.py run tick -Scheduled`, which started `launch.ps1`, which started `tick.ps1`. The lease, the check of the release in force, `HOTPL8_STATE_DIRECTORY` and `HOTPL8_INSTALL_DIRECTORY` are the program's now, and the state directory is passed by name |
| A wake named with its installation that finds a release without a compiled collector in force collects nothing and ends with 0 | It can meet one only when an update came between the job's choice and the lease. That release's own job runner starts the next wake |
| A newly written job of an ordinary Mac starts `<app>/bin/macos/hotpl8-native collect --root <app> --state <state> --scheduled --powershell <pwsh>` | An existing job is kept. The installer and uninstaller of this release recognize either form; those of an earlier release refuse the new one with `Collector ownership mismatch.` |

## Packaging

`release-files.json` carries a `platformFiles` map beside `files`. `files` and `schemaVersion` are unchanged, so existing readers of the manifest keep working.

- `Get-Hotpl8ReleaseFiles` lists a platform file only when it exists. `-Platform` limits the list to one platform and `-RequirePlatformFiles` makes a missing one an error.
- `scripts/package.ps1`, `install.ps1` and `install-macos.ps1` require their platform's binary. A package cannot be built without one, and a source checkout cannot be installed before its reader is built.
- `files` gains the launcher files: `hotpl8-launch.cmd`, `delivery/launch.cmd` and `delivery/hotpl8.cmd`.
- Stage 3 adds `src/lane.ps1` to `files` and takes `src/warming.ps1` and `src/provider-runtime.ps1` out. `tick.ps1` stays where installations and scheduled tasks name it.
- Stage 4 takes `src/notifications.ps1` and `src/forecast.ps1` out of `files` and adds what the shared cases need to the files a source package carries for its tests: `tests/test-shared-rules.ps1`, `tests/parity/shared-rules.json`, `replay-frames.txt`, `replay-expected.txt`, `codex-buckets.json`, `expected-explain.txt` and `expected-tray.txt`.
- Stage 5 takes `src/presentation.ps1` out of `files`. `src/dashboard.ps1` stays as a file that holds only a comment: the preview harness of every installed release from before stage 5 loads that file from a candidate and refuses a candidate without it. It can go once no such release is installed. The source package gains `tests/fixtures/console.ps1`, `tests/fixtures/frame.ps1` and `tests/parity/expected-watch.txt` for its tests.
- Zip extraction drops the Unix executable bit. `install-macos.ps1` sets it when copying, and the Mac delivery adapter sets it on the candidate release before preflight.
- Rust sources under `native/` are not shipped. The reader depends on no crate; `THIRD_PARTY_NOTICES.md` records what is linked into it.

The Windows binary is built for `x86_64-pc-windows-msvc` with a static C runtime. The Mac binary is one file for Apple silicon and Intel, joined with `lipo` and signed without an identity. Neither is signed with a publisher certificate; see Limits. A Linux checkout has no packaged reader and builds its own.

## Component lifecycle

| Question | Compiled reader | Windows launcher |
|---|---|---|
| Update owner | The verified release package. The binary is an inventoried file inside `releases/<sha>` or `app` | Ordinary installation: the installer writes the one-line `hotpl8.cmd`; the launcher itself is a file of the release. Main delivery: enrollment installs `hotpl8.cmd`, `launch.cmd` and the reader copy, and activation migrates an installation enrolled earlier and refreshes the copy |
| Activation boundary | The existing release pointer. A fresh `hotpl8` process uses the reader of the release in force | A new `hotpl8` command. A session already running finishes in the file it was started from, which is why that file never changes |
| Loaded-version evidence | `hotpl8-native self-check` reports the commit it was built from. Delivery starts the candidate's reader at preflight and at its health check and refuses a release whose reader does not answer `version` | `tests/test-native.ps1` holds the bytes of every launcher |
| Recovery | Pointer rollback selects the previous release and its reader. A release from before stage 2 answers the three commands in PowerShell as it always did | `rollback.ps1` leaves the one line in place; it names `app\hotpl8.cmd`, which every release has. A reader copy from stage 1 behind the delivery launcher answers 64 to everything, so PowerShell starts |

The collector is the same file of the same release, so its update owner and its recovery are the reader's. What is its own:

| Question | Collector |
|---|---|
| Activation boundary | The next wake. A wake in progress finishes in the release it started in: the copy beside the launcher holds the lease on `runtime.lock` until its collector has ended |
| Scheduled start | An installation that updates itself, on Windows: activation refreshes the copy beside the launcher and then registers the task, which names that copy and the word `wake` only when the copy is the release's own. The same on a Mac: the job runner of the release in force starts that release's program with `wake` and the installation. An ordinary Windows installation: each install or update registers the task with the collector of `app` when `app` and `previous` both have one, and with `tick.ps1` through PowerShell otherwise. An ordinary Mac: the job names the compiled collector when this release or a later one first writes it; a job that exists is kept as it is |
| Loaded-version evidence | `collector.json.runningSha` is the commit the program that ran the last wake was built from. `hotpl8 delivery` reports it |
| Recovery | A rollback to a release from before stage 3 puts back a PowerShell collector. On Windows the copy beside the launcher starts that release's `tick.ps1` in PowerShell, with the state and installation directories `launch.ps1` gave it. An ordinary Windows task names the compiled collector only once the release a rollback would restore has one. On a Mac that updates itself the job runner belongs to the release in force, so a release from before stage 4 is started as it always was; a wake that finds such a release in force after an update came between its start and its lease collects nothing and ends with 0 |

The dashboard is the same file too, and the one part of it that stays running. What is its own:

| Question | Dashboard |
|---|---|
| Activation boundary | An open dashboard looks once a second and ends with 75 when it is no longer the release in place: on an installation that updates itself, when `current.json` names another release; on any installation, when the program file it was started from has been replaced or is gone for three looks. What started it then opens the dashboard of the release in place, in the same window: the copy beside a delivery launcher, `launch.ps1`, or `hotpl8.ps1` behind the launcher of an ordinary installation. A dashboard holds no lease on `runtime.lock`, so an update never waits for one |
| Loaded-version evidence | On an installation that updates itself, the window title: `HotPl8 main <first 12 characters of sha> \| <delivery state>`, set again every second. `hotpl8 version` in another window names the release in place |
| Recovery | A rollback is another release coming into force, and the dashboard hands off to it like an update. A release from before stage 5 draws its dashboard in PowerShell as it always did. On an ordinary Windows installation a rollback or an uninstall is refused while a dashboard is open, because the program's file cannot be removed; closing the dashboard clears it |

## Previewing a candidate's reader

A live PR preview extracts the candidate's source archive, which holds no compiled file. For a candidate whose `release-files.json` lists a reader for the platform, `delivery/live_preview.py` also takes the one CI built for it:

- It downloads the artifact `hotpl8-<platform>-candidate` from the passing `pull_request` run for the pinned commit in the enrolled repository, the run the preview already requires. A missing, expired or ambiguous artifact stops the preview and asks for the workflow to be rerun.
- The artifact must hold exactly `SHA256SUMS` and one package, the package must match that checksum, and the reader inside must match the package's own `checksums.json`. Anything else stops the preview before candidate code runs.
- The reader is written to its release path under the extracted source, inside the preview's temporary directory. The head is checked again after both downloads.

The run is what vouches for the file. The checksums show only that the package arrived as CI wrote it. GitHub builds a pull request run from the head merged into the target branch, so the commit compiled into the reader is that merge and not the pinned head.

`delivery/live-preview.ps1` then asks the candidate's reader for the dashboard in the words a user types, with the terminal passed through:

```text
hotpl8-native user nyan -StateDirectory <fictional state>
```

The reader's dashboard is the only one there is, so nothing is shown in its place. A candidate with no reader for the system ends the preview with `This candidate ships no compiled reader for this system, so it has no dashboard to preview.` and status 1. Status 64 from the reader ends it with `This candidate's compiled reader left the dashboard to PowerShell, which draws none, so there is nothing to preview.` and status 1. Any other non-zero status ends it with `Candidate reader exited with <status>.`, the reader's diagnostics and that status. Each ending prints `Preview ended:` with the pull request and the revision.

The preview harness that runs is the installed release's, not the candidate's. A release from stages 2 to 4 asks the candidate's reader in the same words and shows the candidate's PowerShell dashboard when the answer is 64; a candidate from stage 5 on answers with its dashboard, so that fallback is not reached. Such a harness also loads `src/dashboard.ps1` from the candidate before it asks, which is why that file still ships. A later stage must keep to the hand-over: the words above, and status 64 before any output when the reader does not draw.

## Evidence

| Check | Result |
|---|---|
| Unit tests of the program (`cargo test --locked` in `native/`) | 200 on Windows. The dashboard's hold what the PowerShell dashboard suite held: the layout at each size, scrolling, the animation at given instants, the colour of each kind of cell, the escape sequences a terminal is sent, the keys, and what a release that is no longer in place does. The collector's are run in a scratch home against a stand-in for cswap and a stand-in for Codex (`native/examples/codex_stand_in.rs`), with the clock and the upkeep lanes passed in, so none starts PowerShell, looks for a program on the machine's path or reads the machine's own state |
| Whole wakes, compared once before the PowerShell collector was deleted | Each of the 67 wakes of `tests/test-tick.sh` was run from the same files by main's PowerShell collector and by the compiled one. Every file each left was compared as data: the same decisions and the same values in all 67, in two runs. The comparison cannot be rerun on this tree, which has one collector |
| Collector suites | `tests/test-tick.sh` runs the same wakes against the compiled collector. `tests/test-safety.ps1`, `tests/test-capacity.ps1`, `tests/test-codex.ps1`, `tests/test-provider-registration.ps1` and `tests/test-operations.ps1` start it through `tick.ps1` for scheduled wakes, locks held by another program, backoff and recovery, output files that cannot be written, and a second registered provider. Checks of functions that no longer exist moved to the unit tests with the results PowerShell gave |
| Codex accounts (`tests/test-codex.ps1`), 34 s | 100 checks. Whole wakes read two fictional homes from a compiled stand-in for Codex (`tests/fake-codex.cs`) that answers, refuses, stalls, exits or sends what is not JSON, as each check asks; the rest hold the PowerShell reader that launching and account management still use to the same stand-in and to the shared cases |
| Whole wakes, compared once before PowerShell's Codex collection was deleted | 18 wakes through `tick.ps1` against the stand-in: one each for an answer, an answer with a notice between, noise on standard error, no sign-in, a refusal by 401, 403 and 429, an answer that is not JSON, a program that exits, a custom endpoint, a custom provider and one subscription in two homes, and six in a row through a refusal, its backoff and a recovery. Each was run from the same files by main `9bd58798`'s PowerShell lane and by the program, and every file a wake leaves was compared as data: `status.json`, `status.js`, `status.txt`, `codex-state.json`, the last line of `codex-observations.jsonl`, `collector.json`, `activity.json` and the exit status. No file differed, setting aside the order in which accounts never attempted are read, the layout of `codex-state.json` and each snapshot's made-up id. Run again on the final code with the same result |
| What the tray shows (`tests/test-tray.ps1`), 2 s | The window's own rules: which announcements are new, and a view it cannot get shown as unavailable. What the view holds is the reader's, in the parity suite |
| Scheduled start and removal (`tests/test-lifecycle.ps1`, 24 checks; `tests/test_macos_delivery.py`; `tests/test-install-macos.ps1`) | The task of an installation that updates itself names the copy beside the launcher and `wake` only when that copy is the release's own, and `tick.ps1` otherwise. An ordinary installation's task names the collector of `app` only when `app` and the release kept under `previous` both have one. Each task's own command line is run: it reaches the collector. A wake during an update ends with 0 and collects nothing; a release without a compiled collector has its `tick.ps1` started with the same state; an installation that cannot name its release ends with 1. On a Mac: the job of an installation that updates itself starts the release's program with `wake` and the installation, and a wake named that way collects in the release in force; a newly written ordinary job names the compiled collector, and a job of either form is recognized as the installation's own. On Windows, with a program still running from the installation, a rollback and an uninstall each stop with the message under the dashboard's differences, and the launcher, the installation record, both kept releases and the policy are as they were |
| Launcher and hand-over suite (`tests/test-native.ps1`) | 18 checks on Windows, 14 elsewhere: no module-loading command in the hand-over; the commit a built reader names; `version` for a release and a checkout; `status`, `explain` and `tray -Once` through the entry; text and JSON delivery; a refusal in the reader's words with status 1; the typed words answered without PowerShell; every other request left to PowerShell with 64 and nothing printed; a start that is not a request; a copy without a reader; the dashboard as the reader's frame, from the words a user types and through the entry; a live preview that shows the dashboard a candidate's reader draws, and its three endings without one; the launcher bytes. On Windows also: each earlier launcher replaced under a running session, with one replacement that must fail; a rollback behind the new one line; output byte for byte as PowerShell wrote it; PowerShell started with the words the reader leaves, and only then; a main delivery installation answering from the release in force |
| Parity suite (`tests/test-native-parity.ps1`), 107 s under Windows PowerShell 5.1 | 167 fictional cases, each as `status -AsJson` and `explain -AsJson`, compared with what PowerShell's rules calculate: 334 answers, 248 the same, 54 refused by both, 32 refused by the reader alone, as their cases say. The text of `status`, of `explain`, of what the tray shows and of the dashboard matches an expected file for every case that has an answer (165, 162, 165 and 164 cases). One check gives the reader an edited reading and requires the comparison to fail; one requires a single start for many questions to change no answer: 24 questions, 18 answered and 6 refused |
| Seeded variations, each run | 150 variations of the cases, seed 1: 300 answers, 202 the same, 68 refused by both, 30 refused by the reader alone. No differing answer |
| Seeded variations, `-Deep` | 1,500 variations, seed 6: 3,000 answers, 1,924 the same, 666 refused by both, 410 refused by the reader alone. No differing answer. Seed 5, a stage earlier: 1,990, 610 and 400, in 419 s |
| The tray's view and the explanation text, compared once before PowerShell's were deleted | `-Deep` then asked PowerShell for those two as well. 163 cases: 479 answers the same, 108 refused by both, 64 refused by the reader alone. 1,500 variations, seed 4, 6,000 answers: 3,928 the same, 1,204 refused by both, 868 refused by the reader alone. No differing answer. The comparison cannot be rerun on this tree, which has one implementation of both; the expected files hold them now |
| The dashboard, compared once before PowerShell's was deleted | Each case was drawn twelve ways by both: to a pipe as `watch` and as `nyan`, and ten ways as a terminal from 40 by 10 to 118 by 64, with and without the animation, scrolled, frozen, in 24-bit colour, in 256 colours and plain, and one a moment after its layout. Frames were compared cell by cell: the character and the colours a terminal would show. 300 variations, seed 1, 3,600 frames: 2,330 the same, 804 refused by both, 456 refused by the reader alone, 10 padded by the cell as the differences say, none differing otherwise. Seed 2: 2,165, 864, 551, 20 and none. The first run, over the 162 cases as written, found one cell of the overview bar that the program rounded the other way at a width of 48; the program was corrected. The reader drew the 3,600 frames of seed 1 in 10.4 s, reading the state for each; PowerShell took 34 minutes. The comparison cannot be rerun on this tree, which has one dashboard; `tests/parity/expected-watch.txt` holds what it drew |
| The dashboard as a program (`tests/test-dashboard.ps1`), 13 s | 3 checks on fictional state. The frame a terminal is sent is the frame that is printed, row for row, for `watch` and `nyan` in both colour forms. The decoder the documentation images use reads both forms and refuses any other sequence. On Windows the program is opened on a console of its own with no window, and that console's screen is read back: the dashboard moves, freezes on what it had read while the state changes under it, scrolls and returns, shows the new state when resumed, stays open through other keys, closes on its key with status 0, and leaves the screen, the console modes, the title and the cursor as it found them. On a Mac, `tests/test_live_preview.py` runs a preview on a terminal it creates, freezes it, resizes it and ends it |
| Documentation images (`scripts/screenshots.ps1`) | The 13 images drawn from the reader's frames are byte for byte the 13 drawn from the PowerShell dashboard's, from the same fictional state, clock and zone |
| Shared cases (`tests/parity/shared-rules.json`, `tests/parity/codex-buckets.json`) | 55 cases of the control files and what an action is told of them, the switch hold, where cswap is found, replay and the kinds of failure, and 102 of what an account's limits mean. PowerShell answers them in `tests/test-shared-rules.ps1` (5 checks, 11 s) and `tests/test-codex.ps1`; the program answers the same lines in its unit tests on both platforms. The first run of the control cases found four disagreements in code already on main; see the wake's differences |
| Number rules | The reader's reading and writing of doubles compared with 200,017 doubles recorded from each PowerShell |
| Live preview (`tests/test_live_preview.py`) | A candidate with a reader runs with the one its trusted run built, and what is shown is that reader's dashboard. Refused without running anything: fork, failed CI, changed head, missing, expired or ambiguous package, failed download, wrong or foreign checksum, extra or unsafe content, other platform, no reader, reader differing from its checksum |
| Delivery (`tests/test_delivery.py`, `tests/test_macos_delivery.py`) | Prior release without a binary, verified package with one, activation, a candidate whose reader does not start refused, rollback. On Windows: enrollment installs the launcher, the one line and the reader copy; activation migrates an earlier enrollment and replaces a reader copy that differs |
| Ordinary Mac install (`tests/test-install-macos.ps1`) | A package copy whose reader has lost its executable bit installs with the bit restored |
| Binary size, Windows | 1,957,888 bytes (local build); 1,741,312 before the dashboard; 1,575,936 before Codex reading and the tray's view; 1,092,608 before the collector |
| Installed adoption, stage 1 | Main `1079508fffd708dbc266c6813bf286a1539cf8eb` was delivered and activated on Windows on 2026-10-05. The installed reader's `self-check` reported that commit, and `hotpl8 version` printed `0.2.0-rc.1 main 1079508fffd7` |
| Installed adoption, stage 2 | Main `2323e0a640b5dcf4fb2c75e537e0b51bea3eb3bd` was delivered and activated on Windows on 2026-10-07. `delivery-status.json` named it as both the desired and the installed commit, the collector's next wake recorded it as `runningSha`, and `hotpl8 version` printed `0.2.0-rc.1 main 2323e0a640b5` |
| Installed adoption, stage 3 | Main `9bd58798f54d6e8ddd5559a6602ba766706e5be9` was delivered and activated on Windows on 2026-10-07. Its scheduled task named the copy beside the launcher and the word `wake`. The next 18 wakes each recorded that commit as `runningSha` and none failed: 526 ms at the fastest and 600 ms at the median, and 4.3, 4.9 and 6.4 s for the three that read Codex accounts through the PowerShell lane stage 4 removes |
| Installed adoption, stage 4 | Main `88f2220ad0dea7a27edf8891cb2d6f0091a21627` was delivered and activated on Windows on 2026-10-07. `delivery-status.json` named it as both the desired and the installed commit, and the scheduled task still named the copy beside the launcher and the word `wake`. The next 25 wakes, one a minute, each recorded that commit as `runningSha` and none failed. The four that read Codex accounts took 2.4, 2.8, 2.9 and 3.2 s, against 4.3, 4.9 and 6.4 s on the release before; the others took 0.5 to 1.5 s |
| Installed adoption, stage 5 | Recorded after merge |

Time from typing a command to its last line, Windows, median of 20 rounds, fictional state. "Before" is main; both were installed side by side and every arrangement ran once per round.

| Command | Installation | Before | After | |
|---|---|---|---|---|
| `status` | Ordinary | 2,153 ms | 217 ms | 9.9 times faster |
| `status` | Main delivery | 2,511 ms | 271 ms | 9.3 times faster |
| `explain` | Ordinary | 1,926 ms | 208 ms | 9.3 times faster |
| `explain` | Main delivery | 2,312 ms | 277 ms | 8.3 times faster |
| `version` | Ordinary | 941 ms | 208 ms | 4.5 times faster |
| `version` | Main delivery | 1,436 ms | 279 ms | 5.1 times faster |
| `help`, which the reader leaves to PowerShell | Ordinary | 889 ms | 1,011 ms | 122 ms slower |

In the same rounds the reader asked directly took 129 ms, `cmd /c exit` 134 ms and `powershell -NoProfile` doing nothing 292 ms; the first two include starting the process that measured them. `status` through `powershell -File hotpl8.ps1`, the way a Mac or a script asks, took 543 ms. `status` and `explain` printed the same text as main in all 20 rounds of every arrangement.

What remains of a command on Windows is two or three `cmd` files and one program start. PowerShell is not part of it.

One wake, Windows, fictional Claude accounts behind a stand-in for cswap, nothing to switch. "Before" is main's PowerShell collector.

| Start | Before | After |
|---|---|---|
| The collector alone | 4,025 ms (median, `tick.ps1` in Windows PowerShell 5.1) | 538 to 617 ms (`hotpl8-native collect`) |
| Through `tick.ps1`, as `hotpl8 refresh` starts it, and as the scheduler started it wherever stage 3 left that to PowerShell | 4,025 ms | 950 to 1,140 ms |
| PowerShell starts in a scheduled wake of a main delivery installation | 2 (`launch.ps1`, then `tick.ps1`) | 0, and 1 more for each lane the wake needs |

`tests/test-tick.sh`, which runs 67 wakes, went from 235 s to 149 s. Its checks of the window-opening schedule, which started PowerShell once each, are unit tests now.

Stage 4, the same machine and the same kind of fictional state. "Before" is main after stage 3.

| What | Before | After |
|---|---|---|
| A wake that reads two Codex homes from a stand-in, through `tick.ps1` | 2.2 to 2.7 s | 759 to 885 ms |
| PowerShell starts for that wake's Codex read | 1 | 0 |
| The scheduled start of an ordinary Windows installation with nothing due: lowest, median, highest | 485, 505, 544 ms (`tick.ps1`) | 151, 161, 167 ms (the collector, named by the task) |
| One refresh of what the tray shows, median of 20, measured twice | 826 and 855 ms | 121 and 122 ms |
| Processor time one refresh costs the tray's own process | 1,048 and 1,072 ms | 12 and 9 ms |
| Programs a scheduled wake starts on a Mac that updates itself (counted, not timed) | Python twice and PowerShell twice | Python once, and PowerShell only for a lane with work |

A tray refreshes every five seconds, so in PowerShell it held about a fifth of one processor core for as long as its window was open.

`tests/test-codex.ps1` went from 99 s to 34 s for its 100 checks: its wakes no longer start PowerShell to read an account, and the checks of the deleted collection function are unit tests.

Stage 5, the same machine and the same kind of fictional state. "Before" is main after stage 4.

| What | Before | After |
|---|---|---|
| Processor time an open dashboard uses each second, with the animation | 716 ms | 7.8 ms |
| The same without the animation | One refresh a second, timed by its parts below | Too little to measure |
| Memory an open dashboard holds | 213 MB | About 10 MB |
| One frame laid out and coloured from files on disk, the state read included | Most of a second, by the parts below | 2.9 ms (3,600 frames in 10.4 s) |
| PowerShell functions that draw the dashboard | 59, and 2 more only it called | 0 |
| The documentation images, all 13 (`scripts/screenshots.ps1`) | 28.7 s | 24.6 s |

The PowerShell dashboard suite was 31 checks in 27 s. What it checked is in the program's unit tests now, and three checks of the running window take 13 s.

One refresh of the PowerShell dashboard that stage 5 deleted, timed by its parts (Windows PowerShell 5.1, fictional state, 15 rounds), which is what the order of the stages rested on:

| Part | Plain | With the animation |
|---|---|---|
| Loading its modules, once | 701 ms | 701 ms |
| Calculating the rules | 264 ms | 278 ms |
| Laying out the lines | 549 ms | 637 ms |
| Colouring them | 140 ms | 297 ms |
| One frame between refreshes | 18 ms | 132 ms |

## Limits

- The binaries carry no publisher signature. Windows Smart App Control, where enabled, can refuse to start one. `version`, `status`, `explain` and the tray then have no answer and no wake collects: Windows reports the blocked start, or the copy says it has no reader or collector it can start.
- An installer or uninstaller from before stage 1 does not know the `bin/` paths and stops with `Unrecognized file in application directory` when it checks a kept release that has them. On Windows the older installer checks only `previous`, so this appears on the run after a downgrade, while the newer release is still kept there. On Mac it also checks `app` before moving it, so the downgrade itself stops. Removing `bin` from the kept copy that has it (`app/bin` or `previous/bin`) clears it. On Windows, installing the newer package again also clears it. Managed delivery is unaffected: it keeps whole release directories.
- The rules the other PowerShell commands need are calculated a second time in PowerShell until stage 6. The parity suite and the shared cases are what keep the two alike. The conversation with the Codex program is the one rule not held case for case: each language is tested against its own stand-in.
- An ordinary Windows installation updated from a release without a compiled collector keeps starting its wakes through `tick.ps1` until the update after that one, because the release it would roll back to has no collector for the task to name.
- An ordinary Mac whose collection was scheduled by an earlier release keeps the job it has, PowerShell start included, until that job is removed and written again. An installer or uninstaller from before stage 4 refuses a job that names the compiled collector, with `Collector ownership mismatch.`
- The scheduled start on a Mac was counted from its code path and tested on the Mac job, not timed.
- A wake starts PowerShell for Claude's continue hook and for closing an account addition, each only when it has work. No stage here moves those two.
- A running tray starts the program once every five seconds. One long-lived program drawing its own tray would start nothing; no stage here plans that.
- A live PR preview runs a candidate's dashboard and never its collector. What vouches for a candidate collector is the suites and the comparison under Evidence.
- Every command the reader does not answer costs one reader start more on Windows, about 0.1 s on the measuring machine.
- A session still running from a launcher that is then removed ends with `The batch file cannot be found.` and status 1. See [the launcher](../install.md#the-launcher).
- macOS on Intel is built but only Apple silicon is exercised in CI. Linux is built and tested only by whoever runs a checkout there.
- A live PR preview shows a candidate's compiled dashboard and nothing else. A candidate from before stage 5 is shown its PowerShell dashboard only by an installed release from stages 2 to 4, whose harness still has that fallback.
- The reader built for a live preview comes from the pull request's merge with the target branch, while the fictional state it is shown comes from the pinned head. The two differ when the target branch has moved since the head was pushed.
- An ordinary Windows installation cannot be rolled back or uninstalled while its dashboard is open. Both stop before removing anything and say so; closing the dashboard clears it. An update is not held up. In a checkout on Windows, `scripts/build-native.ps1` cannot replace the program while a dashboard is running from it.
- `src/dashboard.ps1` ships as a file with only a comment in it until no installed release's preview harness loads it from a candidate.
- A dashboard that PowerShell started, after guided setup or after an update of an ordinary installation, has that PowerShell as its parent for as long as it is open, and each further update it hands off to adds one more. On a Mac that updates itself the Python launcher stays as the dashboard's parent.
- On a Mac or Linux the window title a dashboard sets is not put back when it closes, as before. A checkout or an ordinary installation sets no title.
- A resize while a dashboard is open is tested on the Mac job. On Windows the suite opens the dashboard at one size, and the layout at every other size is held by the unit tests and the expected file.
- `tests/parity/expected-watch.txt` is 540 KB of text, 13 KB compressed, and a package carries it with the other files its tests need.
- Six of the 13 images under `docs/assets` were already older than the dashboard that draws them on main. This stage does not draw them again; CI draws all 13 for each pull request.
- The default test run compares PowerShell's rules with the reader's under one PowerShell per platform: Windows PowerShell 5.1 on Windows and PowerShell 7 on the Mac job. PowerShell 7's rules on Windows are compared only when the suite is run in `pwsh` there by hand.
