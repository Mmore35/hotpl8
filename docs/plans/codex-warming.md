# Native Codex warming investigation

Decision for the 0.2 candidate: keep automatic Codex warming unavailable. This is the conditional branch of the approved roadmap, not a completed warming implementation.

On 2026-09-12, local `codex-cli 0.154.0` help verified native `exec` options including `--ignore-user-config`, `--ignore-rules`, `--strict-config`, `--ephemeral`, `--skip-git-repo-check`, `--disable`, read-only sandboxing and JSON events. These establish possible controls; help output does not establish isolation from all managed/project settings or prove a useful quota-window transition.

The available observation had a weekly-only main meter, for which preparing a five-hour window is not applicable. The additional meter had 0% usage, unconfirmed anchors and an unknown constraint; those observations cannot authorize spending that pool or demonstrate coldness. No warm inference was sent and no native credentials were moved during this investigation.

The official [noninteractive guide](https://developers.openai.com/codex/noninteractive/) and [configuration reference](https://developers.openai.com/codex/config-reference/) describe the native controls. Shell execution, hooks and MCP are separate surfaces; a temporary working directory and read-only sandbox alone are insufficient. Native versions and contracts must be rechecked when resuming.

## Evidence required before implementation

1. Obtain an eligible test subscription with an observed five-hour window and a verified intended model-to-meter mapping. Reject weekly-only, unknown spend constraints, missing scopes and unrelated fallback pools.
2. Establish effective native isolation. Prove that tool execution, MCP startup, user/project hooks, skills, repository instructions, memories and unintended project context are absent. Test hostile fictional config/hook fixtures and managed configuration. If any layer cannot be disabled or audited through supported native controls, stop with an explicit unsupported-configuration reason.
3. Reuse native home ownership, a bounded process tree, the existing per-home lock, a dedicated workspace, the shared attempt budget and schedule/pause/exclusion gates. Record the receipt before dispatch so a crash cannot duplicate a request. Do not introduce a direct bearer-token HTTP client.
4. Observe before, immediately after and at normal subsequent collection intervals. Require a relevant reset transition; exit code zero and a sliding reset are insufficient. Measure quota overhead and preserve existing interactive authentication/session ownership in the same home.
5. Add native transport fixtures, process timeout/crash/concurrency tests, policy/schema validation, collector wiring, public capability reporting, CLI/dashboard/tray states and package dependencies. Keep off by default. Ship only the provider/model/platform combinations that pass.

Save sanitized results and exact versions here. If there is no reproducible window benefit, leave warming unavailable and keep Codex observation/selection useful independently. Mac qualification may continue without resolving this separate experiment.
