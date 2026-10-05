# Compiled reader for display commands

Status: stage 1 of 3 implemented. `version` is answered by a compiled Rust program when the release ships one that matches it. `status`, `explain` and the dashboard still run in PowerShell and are the next two stages.

Baseline read for this plan: main `b5ebd83986fd4bddabf1f556d7481a98be707a74`.

## Behavior

Nothing the user sees changes. Commands that only print cached state are moved, one at a time, from PowerShell into one small program, `hotpl8-native`. The PowerShell implementation stays in the release as the authority, the fallback and the test referee.

The reason is cost. The dashboard and the read commands are the most frequently run code in the product and the most expensive: a display command spends seconds loading modules before it prints, and an animated dashboard holds a processor core. Their inputs and outputs are fully defined (cached files, the clock, the terminal), so they can be compared exactly against the existing code.

The collector, account switching, setup, onboarding, the agent interface and the T3 bridge are not part of this work.

## Stages

| Stage | Commands | State |
|---|---|---|
| 1 | Packaging, routing, fallback, `version` | Implemented |
| 2 | `status`, `explain` | Planned |
| 3 | `watch`, `nyan` | Planned |

Each stage ships alone and leaves the PowerShell path intact.

## Rules

1. The contract below is written before the code. Each behavior is marked preserve, change on purpose, or unknown.
2. PowerShell is the referee. For the same input the compiled reader prints the same bytes, checked in the same CI job on Windows and macOS.
3. Decline and fall back. The reader answers only input it models exactly. For anything else it exits with status 64 and prints nothing, and `hotpl8.ps1` continues into the PowerShell code. Errors, unusual files and edge cases therefore keep their existing text and exit status without being imitated.
4. A change to the referee or to an expected result is never made in the same commit as reader code. A deliberate difference needs a row in the contract.
5. The kill switch and every fallback are tested, including a test that proves routing happens.

## How it runs

`hotpl8.ps1` loads `src/native.ps1` before its other modules, and only for a request it can hand over. `Get-Hotpl8NativePath` returns the binary's path only when all of these hold:

- `HOTPL8_NATIVE` is not `0`.
- `bin/windows/hotpl8-native.exe` or `bin/macos/hotpl8-native` exists in the release, and on macOS has its executable bit.
- `hotpl8-native self-check` exits 0 within five seconds and prints exactly `hotpl8-native protocol=1 sha=<commit>`.
- That commit equals the `sha` in the release's `build-info.json`. A source checkout has no `build-info.json`; there the protocol alone decides. A `build-info.json` without a readable 40-character commit disables the reader.

The command's text is used only when the reader exits 0 and its output ends with a line break. Every other outcome means PowerShell answers. The build commit is compiled into the binary by `scripts/build-native.ps1`; CI builds it once per platform, tests that file, and packages that file.

Set `HOTPL8_NATIVE=0` to use PowerShell for everything.

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
| Loaded-version evidence | `hotpl8-native self-check` reports the commit it was built from, and must equal the release's own |
| Recovery | Pointer rollback selects the previous release and its binary, or none. `HOTPL8_NATIVE=0`, a missing file or a failed check all give the PowerShell answer |

## Evidence

| Check | Result |
|---|---|
| Reader unit tests (`cargo test --locked` in `native/`) | 14 |
| Routing and fallback suite (`tests/test-native.ps1`) | 15 checks: used when matching; kill switch; other protocol or commit; declined, failed and cut-off answers; missing, corrupt and non-executable file; unreadable build identity; other parameters; hung reader; the built reader against PowerShell for a source checkout and for a release |
| Upgrade (`tests/test_delivery.py`, `tests/test_macos_delivery.py`) | Prior release without a binary, verified package with one, activation, fresh process through the stable launcher, removed and corrupt binary, rollback |
| `hotpl8 version` through `hotpl8.cmd`, median of 20, Windows | 1,615 ms before, 2,276 ms after |
| `hotpl8 version` through the installed stable launcher, median of 20, Windows | 2,913 ms before, 3,217 ms after |
| Reader alone, median of 20, Windows | 496 ms; an empty `powershell -NoProfile` took 677 ms in the same run |
| Binary size, Windows | 330,752 bytes (local build) |
| Installed adoption | Recorded after merge |

The launcher timings include the PowerShell processes that start `hotpl8.ps1`. Those launchers are outside this work, so `version` shows the floor they set rather than the reader's own speed.

`version` did not get faster, and on the measuring machine it got slower. The runs were interleaved on a machine at 68% to 93% processor load, where starting any small program (`cmd /c exit` included) took as long as starting the reader. The reader path replaces loading the PowerShell modules, about 0.3 s there, with two program starts: the identity check and the command. It wins only where a program start costs less than half of that module load. `version` was chosen to prove packaging, delivery and fallback, not speed; the commands that follow replace seconds of PowerShell work. Folding the identity check into the command's own start would halve the added cost and is a decision for stage 2.

## Limits

- The binaries carry no publisher signature. Windows Smart App Control, where enabled, can refuse to start one. That is a failed start, so PowerShell answers.
- An installer from before this change does not know the `bin/` paths. If such an installer is run after a downgrade while a newer release is still kept in `previous`, it stops with `Unrecognized file in application directory`. Installing the newer package again, or removing `previous/bin`, clears it. Managed delivery is unaffected: it keeps whole release directories.
- The reader's speed is hidden behind the PowerShell launchers until they are replaced, which needs its own lifecycle plan.
- macOS on Intel is built but only Apple silicon is exercised in CI.
- A live PR preview runs from the source archive, which has no compiled file, so it shows the PowerShell implementation. Previewing the reader needs the CI-built package and is part of stage 3.
