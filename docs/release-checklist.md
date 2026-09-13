# Release checklist

For the 0.2 candidate, consult [delivery status](plans/subscription-roadmap.md) and retain experimental labels for unqualified native capabilities. Run the full suite including operational state and replay tests. Verify both schema versions, new release-manifest entries, pause after restart, delayed warm reconciliation, and incompatible-policy rollback refusal.

To publish an updater-compatible artifact, merge reviewed code into main, run **Build attested release** (`.github/workflows/release.yml`) on that exact main revision, and download its tested archive plus SHA256SUMS. Verify the archive with `gh attestation verify --repo Mmore35/hotpl8 --signer-workflow Mmore35/hotpl8/.github/workflows/release.yml --source-ref refs/heads/main --source-digest COMMIT --deny-self-hosted-runners`. Create the matching version tag at that exact commit and upload the unchanged archive as a release asset. Keep prereleases in the preview channel. Do not rebuild or rezip the attested file. Creating/publishing the release is a separate explicit maintainer action; the workflow only builds and attests.

The first release is a Windows source-and-download preview. A stable-support claim requires additional evidence; publishing a preview does not establish provider permission or live reliability.

## Required for the public preview

- [ ] Confirm the owner has the right to publish the code under MIT; keep license and third-party notices in the archive.
- [ ] Publish only the reviewed clean initial history. Keep the original development repository, its old refs, PRs, and private evidence private.
- [ ] Check every public ref, tracked file, commit author/message, and release archive for secrets and unintended personal data.
- [ ] Pass the complete offline suite, static checks, secret scan, and package/lifecycle checks on the exact source revision.
- [ ] Verify the downloaded CI ZIP, its per-file hashes, and SHA256SUMS. Ship the exact reviewed archive.
- [ ] Keep monitor-only defaults and prominent compatibility limits; make no unsupported provider-approval or stable-automation claim.
- [ ] Provide installation, account enrollment, troubleshooting, uninstall, licensing, and best-effort support instructions.
- [ ] Obtain the owner's approval for the concrete public repository and release publication batch.
- [ ] Enable Issues and private vulnerability reporting; configure the existing Windows CI check as required after it succeeds in the public repository.
- [ ] Publish the release as a prerelease, then verify source/download/reporting links without authentication.

## Before promoting features to stable support

- [ ] Resolve the provider credential/permission boundary for the features being promoted, especially the Claude adapter.
- [ ] Verify real quota collection, native launches, supported versions and plan shapes, and independent accounts where advertised.
- [ ] Verify credential refresh contention, offline recovery, sleep/wake/reboot, scheduled execution, PATH and hook cleanup.
- [ ] Have an unfamiliar Windows user follow the downloaded-file install/use/uninstall instructions with their own native login.
- [ ] Gather sustained scheduled-use evidence; 72 hours is a useful qualification target, not a requirement for making source open.

Signing, additional operating systems, package-manager distribution, a website, and a hosted backend are not prerequisites for this preview. Revisit them based on actual installation feedback and demand.

## Build and verify

From a Windows source checkout:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package.ps1
```

CI uploads the ZIP and SHA256SUMS for review. Building or pushing a candidate branch does not authorize public publication. A checksum detects mismatch; it does not independently establish publisher identity.
