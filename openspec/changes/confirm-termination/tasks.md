# Tasks

## 1. Termination behavior

- [x] 1.1 Parse shutdown/restart quit reasons and cover normal, logout, unknown, malformed and missing events with unit tests.
- [x] 1.2 Gate existing termination cleanup with a native safe-default dialog, preserve protection on cancellation and reject reentrant requests; verify native fixture acceptance.
- [x] 1.3 Retain retryable cleanup failures and make them visible; verify real GuardEngine with FakePower and fixture UI failure/retry.
- [x] 1.4 Document dialog scope and manual limitations in README and docs/testing.md; compare wording with implemented behavior.

## 2. Integration verification

- [x] 2.1 Run separate candidate build, core regression and selected local native E2E; preserve logs and source digests.
- [x] 2.2 Review task-only diff against starting working-tree snapshots, run strict OpenSpec validation and record scenario evidence in verification.md.

## 3. Release integration

- [x] 3.1 Add a compileable base/current native event regression and a confirmation-bypass mutation; run them with fake power.
- [x] 3.2 Route native red-green proofs to macOS lanes and cover deferral/history/dependency rules with focused tests.
- [x] 3.3 Update version to 3.4.4/build15, changelog and exact evidence; run full quality/native/package gates.
- [x] 3.4 Prepare the reviewed staging manifest and English commit/PR text; verify no unrelated work is included.

## Publication follow-up

- User-authorized commit, push and PR follow the completed local checks; do not merge or publish a GitHub Release manually.
