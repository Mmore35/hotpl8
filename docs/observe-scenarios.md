# Observe scenarios

> How an agent checks a pull request's dashboard change by running it, without anyone
> watching: the scenario it writes, what is run, how the verdict is reached, and the report.

`hotpl8 observe pr NUMBER -TrustRevision FULL_SHA -Scenario FILE` runs the PR's compiled
reader beside main's, through a timeline of simulated times, on fictional accounts, and
judges what the scenario says the PR changes. Nothing is activated, no account is read and
no terminal is needed. It is the check that [the PR handoff](delivery.md#required-pr-handoff)
asks for before merge; the owner reads its verdict instead of opening a preview.

```powershell
hotpl8 observe pr 81 -TrustRevision 0123456789abcdef0123456789abcdef01234567 -Scenario pr81.json
```

| Exit | Meaning |
|---|---|
| 0 | PASS: every check met, every surface answered on both sides |
| 10 | FAIL: the report says why |
| 11 | Not ready yet: no package for the head, the head moved, or main's revision is not released yet. Nothing was judged; try again later |
| 1 | Refused or not made: an invalid scenario, a fork, a head that is not trusted, a failed download |

The same refusals as the [live preview](delivery.md#live-candidate-dashboard) come first: the pinned
head, the same repository, a passing run for exactly that revision, and the package that run
built. `-TrustRevision` authorizes running that candidate's reader with your user rights,
as it does for the preview; it is not an OS sandbox.

## What is run

The **candidate** is the PR's source at the pinned head, with the reader its passing run
built. The **baseline** is main where the PR's branch left it (GitHub's merge base), as a
release: the installed release of that revision, else its attested package, unpacked once
under `previews/baseline-SHA` and removed by an update 14 days after its last use, as
old previews are. `-Baseline FULL_SHA` names another main revision.

Both readers are given the same input: the candidate's screenshot fixture
(`tests/fixtures/screenshots.ps1`, drawn at its own fixed clock), changed by the scenario's
patches, in a disposable state folder with the home, `LOCALAPPDATA`, `APPDATA` and `TEMP`
pointed into the report's `lab` folder. Tokens and `HOTPL8_INSTALL_DIRECTORY` are removed.
At every step of the timeline each side draws these surfaces, its 14 health captures:

| Capture | What |
|---|---|
| `watch-100x26-plain`, `watch-80x24-plain`, `watch-60x40-plain` | the dashboard at three sizes |
| `watch-100x26-ansi`, `watch-80x24-ansi`, `watch-60x40-ansi` | the same with colour |
| `watch-100x26-plain-at0.5`, `watch-100x26-plain-at1.25` | the animation 0.5 s and 1.25 s in |
| `watch-100x26-plain-frozen` | frozen, as Space leaves it |
| `watch-60x40-plain-frozen-offset3` | frozen and scrolled three lines |
| `status`, `status-json`, `explain`, `tray` | the other surfaces the reader owns |

A surface that does not answer, answers nothing, or ends with a status other than 0 is a
problem, and any problem is a FAIL. So a PR that breaks a surface it did not mean to touch
fails even when its own checks are met. Each reader has 30 s per capture.

## The scenario

A JSON file the agent writes from the PR's claim, before it runs. A check states what the
candidate must show **and what the baseline must show**, so a check that main already
passes, or one that cannot tell the two apart, does not count as evidence. A visible
change needs at least one check whose two expectations differ.

```json
{
  "claim": "The footer and RECENT list show only automation events from the last 24 hours",
  "change": "visible",
  "patches": [
    { "file": "status", "path": "recentActions",
      "value": [ { "provider": "claude", "slot": "1", "kind": "recovery_probe", "reason": "failed", "at": "@now-20h" } ] }
  ],
  "steps": [
    { "name": "start", "at": "0" },
    { "name": "plus3h", "at": "+3h" },
    { "name": "plus5h", "at": "+5h" }
  ],
  "checks": [
    { "name": "a 20-hour-old event is shown", "step": "start", "capture": "watch-100x26-plain",
      "text": "probe failed", "candidate": true, "baseline": true },
    { "name": "still shown at 23 hours", "step": "plus3h", "capture": "watch-100x26-plain",
      "text": "probe failed", "candidate": true, "baseline": true },
    { "name": "gone at 25 hours", "step": "plus5h", "capture": "watch-100x26-plain",
      "text": "probe failed", "candidate": false, "baseline": true }
  ]
}
```

| Field | Meaning |
|---|---|
| `claim` | Required. One line: what the PR says changes |
| `change` | `visible` (the default) needs at least one check that expects something different of the candidate and the baseline; a scenario without one is refused. `none` says nothing drawn should change, needs a `reason`, and fails if any capture differs from the baseline at any step |
| `fixture` | `{ "operations": true }` or `{ "twoAccounts": true }` turns on the fixture's switch of that name; the candidate's fixture must have it |
| `patches` | Changes to the fixture's `status` or `policy` before anything runs. `path` is dotted (`slots.0.used5h`); an array element is set by an existing index. `value` replaces what is there, or `"remove": true` removes it |
| `steps` | The timeline: each a `name` and an offset `at` from the fixture's clock (`0`, `+3h`, `90m`, `-1d`, `30s`). Without steps, one step `start` at `0` |
| `captures` | Extra captures, each an `id`, a `surface` (`watch`, `status`, `status-json`, `explain`, `tray`) and, for `watch`, a `size` such as `120x30`, with optional `mode` (`plain` or `ansi`), `at`, `frozen` and `offset` |
| `checks` | Each names a `step` and a `capture` and tests one of: `text` (the text appears), `match` (a .NET regular expression matches), `json` (a dotted path into a JSON surface, compared as text). `candidate` and `baseline` are both required: `true` or `false` for `text` and `match`, the expected value for `json` (`"11.8"`, `"true"`, `"null"`, `"(missing)"`) |

In a patch value, `"@now"` is the fixture's time as ISO 8601 and `"@epoch"` the same as Unix
seconds, each with an optional offset: `"@now-20h"`, `"@epoch+2h"`. They resolve against the
fixture's clock, not the step's, so an event patched at `@now-20h` is 23 hours old at `+3h`.

A state change that is not a time change (a reading that goes stale, an account that is
refused) is a patch: draw it as a second scenario, or patch the input a later step would
see and check only at that step. The fixture is the candidate's, so a PR that changes the
fixture changes both sides' input.

### A change that shows nothing

A delivery, collector or documentation PR changes no surface. Observe it to show that:

```json
{
  "claim": "Delivery keeps the three newest releases and removes the rest after activation",
  "change": "none",
  "reason": "only delivery/runner.py changes; the reader and its fixture are untouched",
  "steps": [ { "name": "start", "at": "0" }, { "name": "plus6h", "at": "+6h" } ]
}
```

It passes only when every capture at every step is the same on both sides, byte for byte,
with the release paths written as `<root>`.

## The verdict

PASS needs all of: every capture answered on both sides; every check met on both sides; for
`change: none`, no capture differs. Anything else is FAIL, with each reason in the report.
An invalid scenario is not a verdict: it ends with status 1 and names what is wrong.

## The report

By default under `previews/pr-NUMBER/SHA/observe-UTCSTAMP/` in the installation, or the
folder `-Report` names when the runner is called directly:

| File | What |
|---|---|
| `report.md` | The verdict, the claim, each check with what was expected and seen on each side, the health line and what was not observed. Paste it into the PR's **Observed run** section |
| `report.json` | The same, with the steps, captures, problems, differing captures and any file a reader wrote into its state folder (`stateWrites`) |
| `scenario.json` | The scenario as run |
| `frames/SIDE/STEP/CAPTURE.txt` | Every capture, `.json` for `status-json` and `tray`, with lab and release paths hidden |

`previews/pr-NUMBER/SHA/observed.json` records the last verdict for that revision. The
command prints `{"state":"observed","verdict":...,"report":...}` as its last line, or
`{"state":"blocked","reason":...}` with status 11.

Observe runs the reader only. It does not observe key input or a resize in a live terminal,
the terminal being restored on exit, the collector, scheduled wakes or provider tools, or
the other operating system; the report lists these, and CI and the other suites cover
them. `hotpl8 preview pr NUMBER -Live` stays available to look by hand.

Before merge the installed `hotpl8` may predate `observe`. Run the candidate's own runner
against the installation instead:

```text
<enrolled-python> <reviewed-checkout>/delivery/runner.py --install <managed-root> preview NUMBER --trust-revision FULL_SHA --observe SCENARIO
```

It also takes `--report DIRECTORY` and `--baseline FULL_SHA`. Say in the handoff that the
run used this bootstrap.
