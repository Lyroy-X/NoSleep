# CI and test evidence

The approach follows codex-taskflow's quality gate, adapted to Swift/macOS. Each
PR and branch update runs quality checks, complete native regression and universal
packaging. Main runs the same reusable workflow before publication. No model API,
personal token or Apple Developer credential is needed.

All jobs select the Python 3.12 minor through a SHA-pinned setup action. Patch
availability differs by hosted platform; actual Python, macOS and Swift versions
are retained in receipts/logs instead of claiming identical patch/toolchain builds.

## Local command

```sh
python3 -m venv build/ci-python
build/ci-python/bin/python -m pip install -r scripts/requirements-ci.txt
build/ci-python/bin/python scripts/check-quality.py --base <base-sha> --worktree --actionlint /absolute/path/to/actionlint
build/ci-python/bin/python scripts/check-quality.py --base <base-sha> --worktree --native-regression-proofs
./scripts/test.sh --local
python3 -m pip install --target build/packaging-python -r scripts/requirements-dmg.txt
./scripts/package-dmg.sh
python3 tests/dmg_acceptance.py build/NoSleep-universal.dmg
```

Omit `--worktree` for an already committed candidate. CI uses the full commit
diff; local worktree mode also includes untracked files. Evidence is an array:

```json
[
  {
    "behavior": "An upload failure leaves a draft that can be resumed",
    "mode": "new-capability",
    "productionPaths": ["scripts/release.py"],
    "tests": ["tests/release_acceptance.py"]
  }
]
```

All changed production paths below `Sources/`, `scripts/` and
`.github/workflows/` must have exactly one owner. Native `*Tests.swift` files are
tests, not production. References must name changed, existing focused tests.
Changelog, documentation and increasing app version/build are mandatory.
Declarations cannot authorize commands or external actions.

For bug fixes, `regression` tests run in a disposable read-only archive of the
base plus only the declared test files. Python must produce a unittest assertion
failure rather than a missing import. Native Swift proofs execute only in the macOS lanes and must compile first and then
fail its self-test; compile failures do not qualify. Fixture-dependent tests must
remain self-contained or declare changed test support as tests. New capabilities
and preservation use green focused tests and coverage/mutation evidence; their
presence is not red-green proof. Passing full CI also executes all current tests.

Changed Python executable lines and branches require 100% coverage; missing files,
branch measurements and exclusions fail. Native Swift, shell scripts, workflows
and CI orchestration have a black-box contract and complete native regression,
not a fabricated Swift percentage. `scripts/check-quality.py` and
`scripts/check-mutations.py` orchestrate this gate and are explicitly outside its
Python numeric target. Safety rules need critical mutations; the unchanged copied
fixture passes first, then an assertion must catch the injected fault.

## Lanes and evidence

- Quality on Ubuntu: exact diff/test ownership, version/changelog/docs, Python
  syntax, workflow validation, changed Python coverage and critical mutations.
- Native regression on `macos-15` and `macos-15-intel`: shell syntax, build guards,
  unit/safety tests, real 200-MB/RSS fixture, isolated native UI and runtime receipt.
- Package: after both preceding lanes, build universal DMG, mount read-only, verify
  signature, version, exact app bytes, both architectures, stored layout and arrow.
- Publication: only main push; same run's verified package, restricted write job,
  draft upload verification, exact source tag, resumable retry, no published overwrite.

Logs, coverage and mutation/UI receipts are Actions artifacts for 14 days, including
failures. The packaging artifact is the exact file passed to publication.
`actionlint` is pinned to 1.7.12 and its downloaded binary checksum is verified.
That release predates GitHub's `concurrency.queue`; only its specific unknown-queue
diagnostic is filtered, with the exact `queue: max`/no-cancellation configuration
checked independently. Other diagnostics still fail.

## Adoption and platform limits

User chose strict checks for new changes plus the complete old regression. The
first rollout's reviewed adoption anchor is
`ffcd093827c158a5b95c29658dac9dca94a6ef1f`. If the comparison base predates the
quality gate, evidence/changed coverage start at this ancestor. All later PRs
compare the complete actual base diff. This is an explicit migration boundary,
not a claim that every historical app path is covered.

No workflow changes branch protection or repository visibility. A maintainer can
still merge a red check or push directly when protection is absent; policy is to
merge only green CI. A failed main check blocks its release, not the Git operation.
Real power changes, first admin setup, shutdown/restart, lid closure and Gatekeeper
on another Mac require explicit manual acceptance. Hosted Intel/UI execution and
actual release download remain unverified until a real Actions run is observed.
