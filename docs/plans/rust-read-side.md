# Compiled reader for display commands

Status: stage 2 of 4 implemented. `version`, `status` and `explain` are answered by a compiled Rust program, `hotpl8-native`, and by nothing else. On Windows the launcher asks that program before it starts PowerShell. The collector, the tray and the dashboard still run in PowerShell.

Baseline read for this plan: main `b5ebd83986fd4bddabf1f556d7481a98be707a74`. Stage 2 was measured against main `c94ab0da562c07cc9b4f7c8c8d13b953b2d400af`.

## Behavior

Commands that only print cached state move, one at a time, from PowerShell into one small program. A command that has moved has one implementation. PowerShell keeps no copy of it, and no setting brings one back.

The reason is cost. The dashboard and the read commands are the most frequently run code in the product and the most expensive: a display command spent seconds starting PowerShell and loading modules before it printed, and an animated dashboard holds a processor core. Their inputs and outputs are fully defined (cached files, the clock, the terminal), so a replacement can be checked exactly.

Most of that cost is PowerShell starting, so a moved command is asked for before PowerShell starts. On the measuring machine `hotpl8 status` took 2,153 ms through an ordinary installation before this stage and takes 217 ms after it.

Collecting readings, switching accounts, setup, onboarding, the agent interface and the T3 bridge are not part of this work.

## Stages

| Stage | What moves | State |
|---|---|---|
| 1 | Packaging and `version` | On main |
| 2 | `status` and `explain`. The reader becomes the only implementation of all three. The Windows launcher asks the reader first. A live preview can run a candidate's reader | Implemented |
| 3 | The collector, tray and dashboard ask the reader for the rules it already holds, and the PowerShell copy of those rules is deleted. The Mac launcher asks the reader first | Planned |
| 4 | `watch` and `nyan` | Planned |

## Rules

1. One implementation. A command the reader answers has no PowerShell implementation and no switch to one. A copy whose reader cannot start says so and answers nothing.
2. The reader refuses what it cannot read, in words of its own and with status 1. It does not guess, and nothing else is asked in its place.
3. The contract below is written before the code. Every difference from the PowerShell command it replaced is listed.
4. A rule that is still calculated in two places is compared on every test run, and a stage is named that removes the second place. No rule is added to one place alone.
5. A case or an expected result is never edited only to make a comparison pass.
6. The checks stay cheap enough to run on every change. Starting a program costs more than any answer, so the reader answers all the questions of a check in one start.
7. A launcher file that sessions run from never changes its text. See [the launcher](../install.md#the-launcher).

## What is still calculated twice

`status` and `explain` recalculate the overview, capacity, selection and eligibility from the cached files on every read. The collector, the tray and the dashboard need the same rules while they run in PowerShell, so after this stage those rules exist in the reader (`native/src/`) and in PowerShell (`src/insights.ps1`, `src/overview.ps1`, `src/provider-registry.ps1` and the modules they call). Text formatting is not duplicated: PowerShell has no `status` text any more.

The parity suite holds the two to each other until stage 3 deletes the PowerShell side. A rule that changes before then is changed in both, in one commit.

## How it runs

On Windows the launcher asks the reader, in the words typed after `hotpl8`:

```text
hotpl8 <words>
  hotpl8.cmd           one line that hands over to hotpl8-launch.cmd
  hotpl8-launch.cmd    bin\windows\hotpl8-native.exe user <words>
                         0      the reader answered
                         1      the reader refused, and said why
                         other  powershell -File hotpl8.ps1 <words>
```

The reader takes the words as its own when the first is `status`, `explain` or `version` in any letter case and the rest are only `-AsJson`, `-StateDirectory <directory>`, `-PreviewPolicy <file>` and `-CodexExecutable <path>`, each by its whole name and once. `version` takes only `-AsJson` and `-CodexExecutable`. For any other words, an abbreviated parameter or a `-Name:value` spelling included, it ends with status 64 before it prints anything and PowerShell is started with the same words. The launcher holds no list of commands, so a command that moves later needs no new launcher.

`hotpl8.ps1` is the other way in: it is what the Mac launcher starts, what a script calls, and what the Windows launcher falls through to. It loads `src/native.ps1` before any other module. A request for one of the three with no parameter beyond those above is handed over at once. One with other parameters is checked like any command and then handed over too:

```text
hotpl8-native <version|status|explain> --root <release> [--state <directory>] [--policy <file>] [-AsJson]
```

The reader prints the answer and ends with 0, or prints `HotPl8: <reason>` on standard error and ends with 1. `hotpl8.ps1` passes on either. When the reader's file is missing or cannot be started, `hotpl8.ps1` prints `HotPl8: This copy has no compiled reader it can start, and version, status and explain are answered by it. A release ships one; in a checkout, build it with scripts/build-native.ps1.` and ends with 1.

A [main delivery installation](../delivery.md) keeps a copy of the reader beside its launcher. That copy answers nothing itself. For words the reader owns it takes the shared lease on `runtime.lock` that every running command holds, reads `current.json`, and starts the reader of the release in force with the same words, the installation's state directory and its installation directory. It passes on 0 and 1. Anything else, a failure of its own included, becomes 64, so `launch.ps1` runs as before and reports the problem in its own words.

For `status` and `explain` the reader finds the state directory as PowerShell did: the parameter, then `HOTPL8_STATE_DIRECTORY`, then `stateDirectory` in the release's `install-state.json`, then the release directory. It reads the clock once per request, and reads `data/providers/*.json` and `data/capacity-profiles.json` from its own release when it runs.

Numbers are calculated as the PowerShell that collects on the platform calculates them: Windows PowerShell 5.1 on Windows, PowerShell 7 elsewhere. The two disagree about number types (5.1 reads `1.5` as a decimal and whole numbers as 32-bit; 7 reads them as a double and 64-bit), about rounding ties and about how a double is written, and the collector's own results are what the commands show.

Further arguments exist for the tests, and no launcher or script sends them: `--now <instant>` and `--zone <minutes>` answer for that instant and offset instead of the machine's; `--shell desktop|core` chooses the number rules; `--dump`, with `-AsJson`, prints each number's type and exact digits; `batch <file>` answers many requests in one start. `hotpl8-native self-check` prints `hotpl8-native sha=<commit>` for the build script, delivery and the tests. The build commit is compiled into the binary by `scripts/build-native.ps1`; CI builds the file once per platform, tests that file and packages that file.

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
| `hotpl8 status` and `hotpl8 explain` print the same lines for the same files at the same instant, exit 0 | Preserve | `explain` is compared with the lines PowerShell's rules give the tray. `status` is compared with `tests/parity/expected-status.txt`, whose first version was PowerShell's output |
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
| An install, update or rollback that moves a release aside while its reader is answering | The reader runs for about 0.1 s. An ordinary installer that meets it fails and rolls back, and can be rerun. Main delivery waits for the lease |

## Packaging

`release-files.json` carries a `platformFiles` map beside `files`. `files` and `schemaVersion` are unchanged, so existing readers of the manifest keep working.

- `Get-Hotpl8ReleaseFiles` lists a platform file only when it exists. `-Platform` limits the list to one platform and `-RequirePlatformFiles` makes a missing one an error.
- `scripts/package.ps1`, `install.ps1` and `install-macos.ps1` require their platform's binary. A package cannot be built without one, and a source checkout cannot be installed before its reader is built.
- `files` gains the launcher files: `hotpl8-launch.cmd`, `delivery/launch.cmd` and `delivery/hotpl8.cmd`.
- Zip extraction drops the Unix executable bit. `install-macos.ps1` sets it when copying, and the Mac delivery adapter sets it on the candidate release before preflight.
- Rust sources under `native/` are not shipped. The reader depends on no crate; `THIRD_PARTY_NOTICES.md` records what is linked into it.

The Windows binary is built for `x86_64-pc-windows-msvc` with a static C runtime. The Mac binary is one file for Apple silicon and Intel, joined with `lipo` and signed without an identity. Neither is signed with a publisher certificate; see Limits. A Linux checkout has no packaged reader and builds its own.

## Component lifecycle

| Question | Compiled reader | Windows launcher |
|---|---|---|
| Update owner | The verified release package. The binary is an inventoried file inside `releases/<sha>` or `app` | Ordinary installation: the installer writes the one-line `hotpl8.cmd`; the launcher itself is a file of the release. Main delivery: enrollment installs `hotpl8.cmd`, `launch.cmd` and the reader copy, and activation migrates an installation enrolled earlier and refreshes the copy |
| Activation boundary | The existing release pointer. A fresh `hotpl8` process uses the reader of the release in force | A new `hotpl8` command. A session already running finishes in the file it was started from, which is why that file never changes |
| Loaded-version evidence | `hotpl8-native self-check` reports the commit it was built from. Delivery starts the candidate's reader at preflight and at its health check and refuses a release whose reader does not answer `version` | `tests/test-native.ps1` holds the bytes of every launcher |
| Recovery | Pointer rollback selects the previous release and its reader. A release from before this stage answers the three commands in PowerShell as it always did | `rollback.ps1` leaves the one line in place; it names `app\hotpl8.cmd`, which every release has. A reader copy from stage 1 behind the delivery launcher answers 64 to everything, so PowerShell starts |

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

Status 64 with nothing printed means this reader has no dashboard, and the candidate's PowerShell dashboard runs as before. Any other non-zero status ends the preview with `Candidate reader exited with <status>.` and the reader's diagnostics, so a compiled dashboard that fails is seen failing and is not replaced by the PowerShell one.

The preview harness that runs is the installed release's, not the candidate's. The reader of this stage answers 64 for `nyan`. The hand-over is here so that stage 4 can be previewed once this stage is installed, and stage 4 must keep to it: the words above, and status 64 before any output when it does not draw.

## Evidence

| Check | Result |
|---|---|
| Reader unit tests (`cargo test --locked` in `native/`) | 38 |
| Launcher and hand-over suite (`tests/test-native.ps1`), 48 s | 16 checks on Windows, 12 elsewhere: no module-loading command in the hand-over; the commit a built reader names; `version` for a release and a checkout; `status` and `explain` through the entry; text and JSON delivery; a refusal in the reader's words with status 1; the typed words answered without PowerShell; every other request left to PowerShell with 64 and nothing printed; a start that is not a request; a copy without a reader; the live preview hand-over; the launcher bytes. On Windows also: each earlier launcher replaced under a running session, with one replacement that must fail; a rollback behind the new one line; output byte for byte as PowerShell wrote it; PowerShell started with the words the reader leaves, and only then; a main delivery installation answering from the release in force |
| Parity suite (`tests/test-native-parity.ps1`), 97 s under Windows PowerShell 5.1 and 41 s under PowerShell 7.6 | 163 fictional cases, each as `status -AsJson`, `explain -AsJson` and `explain`: 489 answers. 360 the same, 81 refused by both, 48 refused by the reader alone, as their cases say. The text of `status` for every case matches the expected file. One check gives the reader an edited reading and requires the comparison to fail; one requires a single start for many questions to change no answer |
| Seeded variations, each run | 150 variations of the cases, seed 1: 234 the same, 156 refused by both, 60 refused by the reader alone. No differing answer |
| Seeded variations, `-Deep` | 1,500 variations under each PowerShell (seeds 20261006 and 20261007): 2,839 the same, 972 refused by both, 689 refused by the reader alone under 5.1; 2,886, 927 and 687 under 7.6. No differing answer |
| Number rules | The reader's reading and writing of doubles compared with 200,017 doubles recorded from each PowerShell |
| Live preview (`tests/test_live_preview.py`) | A candidate with a reader runs with the one its trusted run built. Refused without running anything: fork, failed CI, changed head, missing, expired or ambiguous package, failed download, wrong or foreign checksum, extra or unsafe content, other platform, no reader, reader differing from its checksum |
| Delivery (`tests/test_delivery.py`, `tests/test_macos_delivery.py`) | Prior release without a binary, verified package with one, activation, a candidate whose reader does not start refused, rollback. On Windows: enrollment installs the launcher, the one line and the reader copy; activation migrates an earlier enrollment and replaces a reader copy that differs |
| Ordinary Mac install (`tests/test-install-macos.ps1`) | A package copy whose reader has lost its executable bit installs with the bit restored |
| Binary size, Windows | 1,092,608 bytes (local build) |
| Installed adoption, stage 1 | Main `1079508fffd708dbc266c6813bf286a1539cf8eb` was delivered and activated on Windows on 2026-10-05. The installed reader's `self-check` reported that commit, and `hotpl8 version` printed `0.2.0-rc.1 main 1079508fffd7` |
| Installed adoption, stage 2 | Recorded after merge |

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

## Limits

- The binaries carry no publisher signature. Windows Smart App Control, where enabled, can refuse to start one. `version`, `status` and `explain` then have no answer: Windows reports the blocked start, or the copy says it has no reader it can start.
- An installer or uninstaller from before stage 1 does not know the `bin/` paths and stops with `Unrecognized file in application directory` when it checks a kept release that has them. On Windows the older installer checks only `previous`, so this appears on the run after a downgrade, while the newer release is still kept there. On Mac it also checks `app` before moving it, so the downgrade itself stops. Removing `bin` from the kept copy that has it (`app/bin` or `previous/bin`) clears it. On Windows, installing the newer package again also clears it. Managed delivery is unaffected: it keeps whole release directories.
- The rules `status` and `explain` show are calculated a second time in PowerShell until stage 3. The parity suite is what keeps the two alike.
- On a Mac the launcher still starts PowerShell for every command, so the three commands cost a PowerShell start there. That is stage 3.
- Every command the reader does not answer costs one reader start more on Windows, about 0.1 s on the measuring machine.
- A session still running from a launcher that is then removed ends with `The batch file cannot be found.` and status 1. See [the launcher](../install.md#the-launcher).
- macOS on Intel is built but only Apple silicon is exercised in CI. Linux is built and tested only by whoever runs a checkout there.
- A live PR preview of this stage shows the PowerShell dashboard, because this reader has none. Showing a candidate's compiled dashboard needs the installed release to contain the hand-over above, so this stage has to be installed before stage 4 is previewed.
- The reader built for a live preview comes from the pull request's merge with the target branch, while the PowerShell files come from the pinned head. The two differ when the target branch has moved since the head was pushed.
- The default test run compares PowerShell's rules with the reader's under one PowerShell per platform: Windows PowerShell 5.1 on Windows and PowerShell 7 on the Mac job. PowerShell 7's rules on Windows are compared only when the suite is run in `pwsh` there by hand.
