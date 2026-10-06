# Compiled reader for display commands

Status: stage 2 of 3 implemented. `version`, `status` and `explain` are answered by a compiled Rust program when the release ships one that matches it. The dashboard still runs in PowerShell and is the last stage.

Baseline read for this plan: main `b5ebd83986fd4bddabf1f556d7481a98be707a74`.

## Behavior

Nothing the user sees changes. Commands that only print cached state are moved, one at a time, from PowerShell into one small program, `hotpl8-native`. The PowerShell implementation stays in the release as the authority, the fallback and the test referee.

The reason is cost. The dashboard and the read commands are the most frequently run code in the product and the most expensive: a display command spends seconds loading modules before it prints, and an animated dashboard holds a processor core. Their inputs and outputs are fully defined (cached files, the clock, the terminal), so they can be compared exactly against the existing code.

The collector, account switching, setup, onboarding, the agent interface and the T3 bridge are not part of this work.

## Stages

| Stage | Commands | State |
|---|---|---|
| 1 | Packaging, routing, fallback, `version` | Implemented |
| 2 | `status`, `explain`, live preview of a candidate's reader | Implemented |
| 3 | `watch`, `nyan` | Planned |

Each stage ships alone and leaves the PowerShell path intact.

## Rules

1. The contract below is written before the code. Each behavior is marked preserve, change on purpose, or unknown.
2. PowerShell is the referee. For the same input the compiled reader prints the same bytes, checked in the same CI job on Windows and macOS.
3. Decline and fall back. The reader answers only input it models exactly. For anything else it exits with status 64 and prints nothing, and `hotpl8.ps1` continues into the PowerShell code. Errors, unusual files and edge cases therefore keep their existing text and exit status without being imitated.
4. A change to the referee or to an expected result is never made in the same commit as reader code. A deliberate difference needs a row in the contract.
5. The kill switch and every fallback are tested, including a test that proves routing happens.

## How it runs

`hotpl8.ps1` loads `src/native.ps1` before its other modules, and only for a request it can hand over: `version`, `status` or `explain` with no parameter beyond those the contracts below name. The reader is started once per request and is told the request and who is asking:

```text
hotpl8-native <command> --protocol 2 --shell desktop|core [--release <commit>] --root <release> [--state <directory>] [--policy <file>] [-AsJson]
```

It is started only when all of these hold:

- `HOTPL8_NATIVE` is not `0`.
- `bin/windows/hotpl8-native.exe` or `bin/macos/hotpl8-native` exists in the release, and on macOS has its executable bit.
- The caller is Windows PowerShell 5.1 (`desktop`) or PowerShell 7.5 or later (`core`), with English or invariant regional settings as the contract describes.
- A release has a 40-character commit as `sha` in its `build-info.json`, which is sent as `--release`. A source checkout has no `build-info.json` and sends none; there the protocol alone decides. A `build-info.json` without a readable commit disables the reader.

The reader checks who is asking before it reads anything else. Another protocol number, a shell it does not follow, or a `--release` other than the commit compiled into it is declined: status 64, nothing printed. The identity check therefore costs no program start of its own. Stage 1 started the reader twice, once for `hotpl8-native self-check` and once for the command. `self-check` remains for the build script and the tests and prints `hotpl8-native protocol=2 sha=<commit>`.

The command's text is used only when the reader exits 0 and its output ends with a line break. Every other outcome means PowerShell answers. The build commit is compiled into the binary by `scripts/build-native.ps1`; CI builds it once per platform, tests that file, and packages that file.

Set `HOTPL8_NATIVE=0` to use PowerShell for everything.

Two more arguments exist for the tests, and `hotpl8.ps1` never sends them. `--now <instant>` answers for that instant instead of the clock. `--dump`, with `-AsJson`, prints the value with each number's type and exact digits instead of JSON text. When the reader declines `status` or `explain` it names the source line on standard error (`hotpl8-native: declined at <file>:<line>`); `hotpl8.ps1` does not show it.

## Contract: `version`

| Behavior | Label | Notes |
|---|---|---|
| `hotpl8 version` prints `<VERSION> main <first 12 characters of sha>` for a release with a build identity, the bare version otherwise, exit 0 | Preserve | Byte-equal to PowerShell |
| `VERSION` is trimmed with .NET `Trim()` rules | Preserve | Only ASCII files are modelled; others are declined |
| The `sha` property name ignores case; a missing, null, false, zero or empty `sha` prints the bare version | Preserve | |
| A `sha` shorter than 12 characters, or not a string, is a PowerShell error | Preserve | Declined, so PowerShell reports it |
| `version -AsJson` reports `version` and the whole build record in file order | Preserve | Equal after parsing |
| Layout of `-AsJson` text (indentation, spacing, line endings, which characters are escaped) | Change on purpose | The two PowerShell versions in use already differ from each other here |
| A missing, empty, non-ASCII or UTF-16 `VERSION`; a build record that is not a flat object of null, boolean, integer and plain string values; duplicate or non-ASCII property names; date-like strings | Preserve | Declined; PowerShell reads these in ways a strict parser does not |
| `version` with any other parameter (for example `-StateDirectory`) | Preserve | Not routed. The one exception is `-CodexExecutable`, which the Mac launcher adds to every request and `version` does not read |
| On the compiled path `version` no longer loads the other modules, resolves the state directory or prepares onboarding tools | Change on purpose | A fault in those steps no longer stops `version` from printing. With `HOTPL8_NATIVE=0` they run as before |
| Wording of errors | Preserve | Never produced by the reader |

## Contract: `status` and `explain`

Both commands recalculate the overview, capacity, selection and eligibility from the cached files on every read, so the reader carries those rules too, ported function by function. The two PowerShell versions in use disagree with each other about numbers (5.1 reads `1.5` as a decimal and whole numbers as 32-bit; 7 reads them as a double and 64-bit) and about time arithmetic, so the caller says which one it is and the reader follows that one.

| Behavior | Label | Notes |
|---|---|---|
| `hotpl8 status` and `hotpl8 explain` print the same lines as PowerShell for the same files at the same instant, exit 0 | Preserve | Byte-equal, against Windows PowerShell 5.1 and PowerShell 7 |
| Number types, arithmetic, rounding and number-to-text rules of the calling PowerShell version | Preserve | Decimal and double results differ between the two versions; each is matched against its own |
| `-PreviewPolicy FILE`, the state directory order (parameter, `HOTPL8_STATE_DIRECTORY`, `install-state.json`, the code directory) | Preserve | Paths that are not absolute are declined |
| `No cached status. Run hotpl8 refresh.` and `No observation. Run hotpl8 refresh.` | Preserve | |
| The stale notices: a reading older than 900 seconds or more than 5 seconds ahead of the clock | Preserve | |
| Agent pauses, the manual pause, and an invalid pause file | Preserve | |
| Reset times in the Codex lines use the machine's time zone | Preserve | Declined for a time more than two years from now, and on a Mac with `TZ` set |
| `-AsJson` reports the same properties with the same values and number types | Preserve | Compared value by value before either side is written as text |
| Layout of `-AsJson` text, and the order of keys in objects PowerShell builds from hash tables | Change on purpose | The two PowerShell versions already differ in layout, and hash table order is not defined. The reader writes two-space indentation, a fraction on every double (`6.0` where Windows PowerShell writes `6`), the shortest digits that read back as the same double (`62.00000000000001` where Windows PowerShell writes `62.000000000000007`), and `\uXXXX` for every non-ASCII character. The text is checked to read back as the value PowerShell's own text reads back as |
| The clock is read once per request | Change on purpose | PowerShell read it at each use, a few milliseconds apart. PowerShell now reads it once too, so both can be compared at one instant |
| On the compiled path the commands no longer load the other modules or prepare onboarding tools | Change on purpose | As for `version`. With `HOTPL8_NATIVE=0` they run as before |
| The identity check is part of the command's own start (protocol 2) | Change on purpose | One program start per request instead of two. See How it runs |
| A missing or invalid policy, and every other PowerShell error | Preserve | Declined, so PowerShell reports it with its own text and exit status |
| Files that are not strict UTF-8 JSON objects; duplicate or non-ASCII property names; date-like strings; numbers with an exponent, more than 28 digits or beyond 64 bits; nesting deeper than the JSON depth limits | Preserve | Declined |
| Timestamps that are not `yyyy-MM-ddTHH:mm:ss[.fraction]` with `Z` or an offset | Preserve | Declined; PowerShell parses many other forms by regional rules |
| A sort, comparison or hash table lookup whose result depends on regional text rules or on PowerShell 5.1's unstable sort | Preserve | Declined |
| Values of a type a rule does not expect (text where a number belongs, an array where an object belongs, and so on) | Preserve | Declined unless the PowerShell result for that combination was measured and is modelled |
| Provider definitions and capacity profiles that differ from the ones this release was built with | Preserve | Declined |
| Regional settings whose decimal point is not `.`, minus sign is not `-`, time separator is not `:` or calendar is not Gregorian; languages other than English | Preserve | Not routed |
| PowerShell 7 before 7.5 | Preserve | Not routed |
| Any parameter other than `-AsJson`, `-StateDirectory`, `-PreviewPolicy` and `-CodexExecutable` | Preserve | Not routed |
| `refresh` and `tick`, which print status after collecting | Preserve | Not routed |
| Wording of errors | Preserve | Never produced by the reader |

## Packaging

`release-files.json` gains an additive `platformFiles` map. `files` and `schemaVersion` are unchanged, so existing readers of the manifest keep working.

- `Get-Hotpl8ReleaseFiles` lists a platform file only when it exists. `-Platform` limits the list to one platform and `-RequirePlatformFiles` makes a missing one an error.
- `scripts/package.ps1` requires its platform's binary, so a package cannot be built without one.
- `install.ps1` and `install-macos.ps1` copy and verify their own platform's binary. Application removal recognises both platforms' paths.
- Zip extraction drops the Unix executable bit. `install-macos.ps1` sets it when copying, and the Mac delivery adapter sets it on the candidate release before preflight. A binary without the bit is treated as absent.
- Rust sources under `native/` are not shipped. Crates compiled into the binary are listed in `THIRD_PARTY_NOTICES.md`.

The Windows binary is built for `x86_64-pc-windows-msvc` with a static C runtime. The Mac binary is one file for Apple silicon and Intel, joined with `lipo` and signed without an identity. Neither is signed with a publisher certificate; see Limits.

## Component lifecycle

| Question | Answer |
|---|---|
| Update owner | The verified release package. The binary is an ordinary inventoried file inside `releases/<sha>` or `app`; nothing is copied elsewhere |
| Activation boundary | The existing release pointer. A fresh `hotpl8` process uses the binary of the release it was started from |
| Loaded-version evidence | `hotpl8-native self-check` reports the commit it was built from. Every request names the release's commit, and a reader built from another declines |
| Recovery | Pointer rollback selects the previous release and its binary, or none. `HOTPL8_NATIVE=0`, a missing file or a failed check all give the PowerShell answer |

## Previewing a candidate's reader

A live PR preview extracts the candidate's source archive, which holds no compiled file. For a candidate whose `release-files.json` lists a reader for the platform, `delivery/live_preview.py` also takes the one CI built for it:

- It downloads the artifact `hotpl8-<platform>-candidate` from the passing `pull_request` run for the pinned commit in the enrolled repository, the run the preview already requires. A missing, expired or ambiguous artifact stops the preview and asks for the workflow to be rerun.
- The artifact must hold exactly `SHA256SUMS` and one package, the package must match that checksum, and the reader inside must match the package's own `checksums.json`. Anything else stops the preview before candidate code runs.
- The reader is written to its release path under the extracted source, inside the preview's temporary directory. The head is checked again after both downloads.

The run is what vouches for the file. The checksums show only that the package arrived as CI wrote it. GitHub builds a pull request run from the head merged into the target branch, so the commit compiled into the reader is that merge and not the pinned head. The extracted source has no `build-info.json`, so no `--release` is sent and the protocol alone decides, as in a source checkout.

`delivery/live-preview.ps1` then asks the candidate's reader for the dashboard, with the caller described by the candidate's own `src/native.ps1` and the terminal passed through:

```text
hotpl8-native nyan --protocol 2 --shell desktop|core --root <source> --state <fictional state>
```

Status 64 with nothing printed means this reader has no dashboard, and the candidate's PowerShell dashboard runs as before. Any other non-zero status ends the preview with that status and the reader's diagnostics, so a compiled dashboard that fails is seen failing and is not replaced by the PowerShell one. `HOTPL8_NATIVE=0` previews the PowerShell dashboard.

The preview harness that runs is the installed release's, not the candidate's. The reader of this stage declines `nyan`. The hand-over is here so that stage 3 can be previewed once this stage is installed, and stage 3 must keep to it: the command line above, and status 64 before any output when it does not draw.

## Evidence

| Check | Result |
|---|---|
| Reader unit tests (`cargo test --locked` in `native/`) | 32 |
| Routing and fallback suite (`tests/test-native.ps1`) | 20 checks: no module-loading command in the hand-over; which PowerShell is asking; one start per request with the caller and release named; the directories given to `status` and `explain`; text and JSON delivery; kill switch; declined, failed and cut-off answers; missing, corrupt and non-executable file; unreadable build identity; source checkout; unknown regional format; other parameters; live preview hand-over; hung reader; the built reader against PowerShell for a source checkout and for a release, and declining another commit, protocol and shell |
| Parity suite (`tests/test-native-parity.ps1`), Windows PowerShell 5.1 and PowerShell 7.6 | 141 fictional cases, each as `status`, `explain` and both with `-AsJson`: 564 comparisons per version. 427 the same, 67 left to PowerShell, 70 where PowerShell fails and the reader declines. No differing answer. One check gives the reader an edited reading and requires the comparison to fail |
| Seeded variations (`tests/test-native-parity.ps1`), both PowerShells | 150 variations of the cases in the four forms, seed 1: 600 comparisons per version. 368 the same, 119 left to PowerShell, 113 where PowerShell fails and the reader declines. No differing answer. During development 1,750 further variations (950 under 5.1, 800 under 7.6) gave 7,000 comparisons with no differing answer |
| Entry script (`tests/test-native-parity.ps1`) | Six cases in the four forms through `hotpl8.ps1` against the real clock: the same with the reader, with `HOTPL8_NATIVE=0`, and from the reader asked directly |
| Live preview (`tests/test_live_preview.py`) | A candidate with a reader runs with the one its trusted run built. Refused without running anything: fork, failed CI, changed head, missing, expired or ambiguous package, failed download, wrong or foreign checksum, extra or unsafe content, other platform, no reader, reader differing from its checksum |
| Upgrade (`tests/test_delivery.py`, `tests/test_macos_delivery.py`) | Prior release without a binary, verified package with one, activation, fresh process through the stable launcher, removed and corrupt binary, rollback |
| Ordinary Mac install (`tests/test-install-macos.ps1`) | A package copy whose reader has lost its executable bit installs with the bit restored |
| `hotpl8 status` through `hotpl8.cmd`, median of 20, Windows PowerShell 5.1 | 2,141 ms on main, 704 ms with the reader: 3.0 times faster. 2,178 ms with `HOTPL8_NATIVE=0` |
| `hotpl8 explain` through `hotpl8.cmd`, median of 20, Windows PowerShell 5.1 | 1,991 ms on main, 691 ms with the reader: 2.9 times faster. 1,899 ms with `HOTPL8_NATIVE=0` |
| `hotpl8 status` and `explain` through the installed stable launcher, median of 20, Windows | `status` 2,598 ms before, 1,150 ms after: 2.3 times faster. `explain` 2,389 ms before, 1,161 ms after: 2.1 times faster |
| `status` and `explain` under PowerShell 7.6 (`pwsh -File hotpl8.ps1`), median of 20, Windows | `status` 1,926 ms with `HOTPL8_NATIVE=0`, 680 ms with the reader. `explain` 1,851 ms and 687 ms |
| Parts, in the same runs | Reader asked directly 134 ms; `powershell -NoProfile` doing nothing 310 ms; `cmd /c exit` 141 ms. `status` from a release directory, which also reads `build-info.json`, 754 ms |
| `hotpl8 version` through `hotpl8.cmd`, median of 20, Windows, stage 1 | 1,615 ms before, 2,276 ms after |
| `hotpl8 version` through the installed stable launcher, median of 20, Windows, stage 1 | 2,913 ms before, 3,217 ms after |
| Binary size, Windows | 330,752 bytes at stage 1; 1,034,240 bytes at stage 2 (local builds) |
| Installed adoption, stage 1 | Main `1079508fffd708dbc266c6813bf286a1539cf8eb` was delivered and activated on Windows on 2026-10-05. The installed reader's `self-check` reported that commit, and `hotpl8 version` printed `0.2.0-rc.1 main 1079508fffd7` with and without `HOTPL8_NATIVE=0` |
| Installed adoption, stage 2 | Recorded after merge |

The launcher timings include the PowerShell process that starts `hotpl8.ps1`. That launcher is outside this work and sets the floor.

The `status` and `explain` runs were interleaved, one of each arrangement per round, on fictional state. Every round printed the same text in every arrangement.

The budget for this stage was three times faster end to end. From a source checkout `status` meets it narrowly and `explain` falls just short. Through the installed launcher neither meets it: that launcher is a second PowerShell start, about 450 ms, paid before and after alike. A request is 1.2 to 1.4 seconds shorter in every arrangement. Of the 704 ms that remain for `status`, the reader's own work is 134 ms, `cmd` and an empty PowerShell are about 450 ms, and the rest is PowerShell reading `hotpl8.ps1` and starting the reader.

Two things were learned on the way. At stage 1 `version` got slower (the rows above), because the identity check was a program start of its own; this stage sends the identity with the request, so a request is one start. `version` was not measured again. And the first `Join-Path`, `New-Object` or `Select-Object` in a fresh Windows PowerShell loads a module, 50 to 80 ms each on the measuring machine, so the hand-over calls .NET directly and a check in `tests/test-native.ps1` keeps it that way. A release still parses `build-info.json` with `ConvertFrom-Json`, which is the 50 ms between 704 and 754 above.

## Limits

- The binaries carry no publisher signature. Windows Smart App Control, where enabled, can refuse to start one. That is a failed start, so PowerShell answers.
- An installer or uninstaller from before this change does not know the `bin/` paths and stops with `Unrecognized file in application directory` when it checks a kept release that has them. On Windows the older installer checks only `previous`, so this appears on the run after a downgrade, while the newer release is still kept there. On Mac it also checks `app` before moving it, so the downgrade itself stops. Removing `bin` from the kept copy that has it (`app/bin` or `previous/bin`) clears it, and PowerShell answers for that copy. On Windows, installing the newer package again also clears it. Managed delivery is unaffected: it keeps whole release directories.
- The reader's speed is hidden behind the PowerShell launchers until they are replaced, which needs its own lifecycle plan.
- macOS on Intel is built but only Apple silicon is exercised in CI.
- A live PR preview of this stage shows the PowerShell dashboard, because this reader has none. Showing a candidate's compiled dashboard needs the installed release to contain the hand-over above, so this stage has to be installed before stage 3 is previewed.
- The reader built for a live preview comes from the pull request's merge with the target branch, while the PowerShell files come from the pinned head. The two differ when the target branch has moved since the head was pushed.
- PowerShell 7 before 7.5, and regional formats other than English or invariant, get the PowerShell implementation and none of the speed.
- The parity suite takes ten to fifteen minutes on Windows, where it runs under both PowerShells at once, and needs PowerShell 7.5 or later beside Windows PowerShell. The Windows job limit in CI is 45 minutes for that reason.
