# Contributing

Use Windows PowerShell 5.1, Git Bash, Python 3 and Node 22+ for the complete offline suite. Python 3.12+ is needed separately if using claude-swap. Clone the repository and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test.ps1
```

Suites run concurrently, so each one's output is printed whole when it finishes rather than streamed. Add `-Parallel 1` to run them one at a time with live output when reading a single suite's progress matters.

Tests use temporary fixture accounts and a compiled fake Codex executable. They must not log into accounts, send prompts, mutate native credential homes, or change your installed scheduler/PATH. The complete Windows suite needs permission to execute temporary test binaries. A restricted sandbox can report transport failures before product code reaches the fake provider.

Run [static checks](scripts/check.ps1), then relevant focused suites during development. CI runs the complete suite. Keep fixes small, describe observable behavior, and include regression coverage for meaningful bugs. Preserve the existing eligibility, quota-freshness, isolation, and failure tests. Do not weaken checks simply to obtain a green count.

PowerShell files use UTF-8 BOM when non-ASCII text is present, for Windows PowerShell 5.1 compatibility. Shell scripts use LF. Runtime has no dependency on Python or Bash except the separately installed Claude adapter dependency.

Never commit real emails, user paths, credentials, native account homes, quota logs, screenshots of real accounts, or diagnostic dumps. Use fictional fixtures. Security reports belong in the private route in [SECURITY.md](SECURITY.md).

Release maintainers follow [release-checklist.md](docs/release-checklist.md). Do not publish from a working-directory ZIP or tag an untested revision. Provider contract changes need recorded native-client evidence; offline fakes alone cannot prove token-refresh or billing behavior.

Contribute code you have the right to submit, under the project's MIT license. Be respectful, describe problems concretely, and avoid harassment or sharing personal information. Maintainers may remove abusive content and restrict participation.

## Navigating and changing the code

Public entrypoints are at the root, internal code in `src/`, provider adapters in `src/providers/`, and all offline suites in `tests/`. Build and verification tools live in `scripts/`. See the [source map and decisions](docs/architecture.md). Preserve entrypoint paths used by installations and hooks. Update release-files.json when a shipped file moves.

Before adding or changing an installed bridge, helper, launcher or service, read
[the delivery contract](docs/delivery.md#component-lifecycle). Define its update
owner, activation boundary, loaded-version evidence and recovery behavior. Include
it in the existing adapter inventory/readiness and test an upgrade from a prior
installation. A working source checkout or passing clean-install test does not
prove an enrolled installation will receive the change.

For UI changes, regenerate and inspect the [documentation screenshots](docs/screenshots.md). The harness uses the real renderer with fixed fictional fixtures; never capture live accounts. Relevant focused checks:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test-dashboard.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test-onboarding.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\screenshots.ps1
```

Capacity and emergency-policy changes also require `tests/test-capacity.ps1`. Do not infer weekly or short-window capacity from price ratios, weaken unknown-state checks, or count a skipped retry as a failed provider attempt. Preserve third-party animation notices in source and release packages.

Claude plan discovery is isolated in `src/providers/claude_plan.py` and `claude-plans.ps1`. Run `python tests/test_claude_plan.py` and `tests/test-claude-plans.ps1` for identity/schema/cache changes; the full suite includes both. Fixtures must not contact Anthropic or read real native credentials. Native qualification must return only the sanitized plan projection.

T3 integration changes require `node --test tests/test-t3-codex.mjs` and
`tests/test-t3-routing.ps1`. Fixtures use synthetic credentials and a fake native
executable. Never print the private broker response: it contains an access token.
