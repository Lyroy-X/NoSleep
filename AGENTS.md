# NoSleep: versions and releases

Preserve existing work and follow the user's scope and Git permissions. A release
workflow does not authorize an agent to commit, push, merge or publish manually.

## Version every update to main

Before preparing changes for main, the implementing agent chooses a version from
the complete change relative to current main. Use semantic versioning:

- **major**: incompatible user behavior or removal of a supported capability;
- **minor**: a new compatible user capability;
- **patch**: fixes, packaging/CI, tests, documentation or maintenance.

Update `Resources/Info.plist` in the same change. Use exactly `MAJOR.MINOR.PATCH`
for `CFBundleShortVersionString`; reset lower components after a major/minor bump.
Increment the positive integer `CFBundleVersion` independently of the version.
Both values must exceed current main. Explain the chosen bump in the change report.
One push to main creates one release for its final SHA, even if it contains several
commits. Rebase/update an overlapping branch and recompute its version before merge.
Never reuse or move a published version tag.

CI validates these numbers; it does not call a model or commit version changes.
Every update to main, including docs-only changes, needs a new version. Test the
release logic with `python3 tests/release_acceptance.py`. Run the existing regression
checks and DMG acceptance appropriate to the task. Do not claim a GitHub release
or Intel runtime test from a local package check.

## Required verification for agents

- For every production behavior change, add or update a focused test for the
  changed outcome. Include normal, error/refusal, boundary and retry cases; a
  bug fix must reproduce the old incorrect outcome before proving the fix.
- Add a changed `tests/evidence/*.json` declaration. Its production paths must
  exactly own the diff, once each; it must name changed, existing test files.
  Do not cite an unrelated test, a checklist or an old successful receipt as proof.
- Use `new-capability` only for new behavior, `preservation` only for behavior
  intentionally preserved, and `regression` for a bug fix. The gate transplants
  regression tests into an isolated base snapshot; setup/import/compile failures
  are not valid evidence of the original bug. Never put commands in evidence.
- Require 100% execution of changed Python executable lines and outgoing branches;
  do not exclude changed code or lower thresholds to make CI green. Native Swift,
  shell and workflow behavior use focused black-box tests and complete macOS
  regression; their Python orchestration coverage does not measure Swift behavior.
- Add a critical mutation when changing a refusal, exact-source, safety or
  publication gate. The unmodified fixture must pass and its faulty copy must fail
  by an assertion, without modifying the working repository.
- Run the same quality command locally and in CI (see `docs/quality-gates.md`),
  then the complete native suite and package checks. Check all lanes; a targeted
  rerun cannot replace a failed full gate. Keep source/config/runtime receipts.
- Update the exact version's changelog and documentation. Record test limitations
  and required manual acceptance for real power, first administrative setup,
  shutdown/restart, lid closure and downloaded-app Gatekeeper behavior.
- Automated tests must use isolated app/state and fake power dependencies. Never
  change real power settings, Cisco, user Keychains or an installed app merely to
  obtain a test result. Manual acceptance needs the user's explicit instruction.
- CI on Intel must execute native tests on Intel; assembling both architectures
  into a DMG alone is not an Intel runtime result. GitHub success must be confirmed
  from a real run before claiming the published pipeline works remotely.

## Retained local macOS test VM

A stopped macOS 27 ASIF fixture is retained in the original checkout's ignored
`build/vpn-lab/idle-lock-macos27-20261015/` directory. Read
[docs/test-vm.md](docs/test-vm.md) before any explicitly authorized VM work, including
from a linked worktree. Keep its disk local and retained, use its exact isolated
registry and independent resource/time supervisor, and verify stopped status after
every outcome. Inventory and historical receipts do not authorize starting a VM,
changing host settings or using a foreign VM. Never add the image, cache, raw logs
or state backups to Git.
