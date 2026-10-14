## Context
See proposal.md. The selected implementation decides versions before merge; no
model API runs in CI. The user additionally requested codex-taskflow-style CI,
choosing strict new-change checks plus complete existing regression.

## Goals / Non-Goals
Verified downloadable releases for exact main SHAs and reproducible quality gates.
No repository visibility change, Apple notarization, live power changes, manual
publication, Git commit/push/merge, or edits in the reference codex-taskflow repository.

## Decisions
- One reusable CI workflow owns quality, native arm64/x86_64 regression and package.
  The main-push release workflow consumes its same-run verified artifact; there is
  no privileged workflow_run execution of PR code and no repeated DMG build.
- Publisher alone gets contents:write and the token. Standard-library API client
  uses fixed GitHub hosts and does not print response bodies or credentials.
- Agent increments SemVer/build and changelog. CI validates against the event's
  previous main SHA; initial historical 3.0 is normalized only for comparison.
- Draft upload is resumable. Tag must match the source; original published bytes
  and checksum receipt survive a rebuilt rerun. No published replacement occurs.
- Python changed-code lines/branches require 100% coverage. Native Swift, shell,
  workflows and orchestration use black-box tests; no Swift percentage is invented.
  Regression proofs transplant tests into read-only base archives and reject setup
  failures. Critical mutations require a green unmodified copied fixture first.
- First policy adoption compares evidence from ffcd093827c158a5b95c29658dac9dca94a6ef1f;
  later PRs compare the complete actual base diff. Old native regression always runs.

## Risks / Trade-offs
- Hosted macOS UI and Intel execution are unverified until an actual Actions run.
- GitHub's queue supports 100 pending runs; excess runs need an explicit retry.
- actionlint 1.7.12 lacks queue support: one precise diagnostic is filtered only
  alongside independent exact queue validation. All remaining errors block CI.
- No branch protection mutation is authorized; green CI remains a merge policy.
- Test evidence is enforced structurally and executed, but behavior relevance
  still requires code review. Global or historical 100% correctness is not claimed.

## Migration Plan
Keep files local and the OpenSpec change active. After explicit Git publication
authorization, land the scoped change; observe first main CI/release and download.
Failures leave logs/artifacts and a resumable draft; never move a published tag.
