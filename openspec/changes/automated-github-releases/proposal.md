## Why
NoSleep has a universal DMG packager but no automated GitHub release. Every update
to main should result in a verified, downloadable version without manual packaging.

## What Changes
- Establish agent-selected semantic versions before merge, with CI validation.
- Build/test an exact main SHA and publish a retryable GitHub release with DMG and SHA-256.
- Add headless DMG acceptance while preserving local Finder acceptance.
- Adapt codex-taskflow's exact test evidence, diff coverage and critical mutations,
  with full native regression on Apple Silicon/Intel and safe isolated UI tests.
- Preserve private visibility and ad-hoc signing; do not manually commit/push/merge/publish.

## Capabilities
### New Capabilities
- `github-releases`: verified, versioned, retryable distribution through GitHub Releases.
### Modified Capabilities
None.

## Impact
Repository instructions, Actions workflows, version metadata, release tooling,
targeted tests, DMG acceptance and documentation. Production app APIs are unchanged.
