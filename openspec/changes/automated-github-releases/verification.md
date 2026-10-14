# Verification: automated-github-releases

Scope: NoSleep automatic releases and codex-taskflow-style new-change quality gates.
User accepted the plan, chose versions before merge, private releases, current
signing, local E2E, no personal review, and strict new changes plus full old regression.

Code state: base `ffcd093827c158a5b95c29658dac9dca94a6ef1f` plus the scoped
uncommitted inputs in `.taskflow/auto-releases/final/receipt.json`. The independent
candidate is `/private/tmp/nosleep-ci-final-r48umo99/NoSleep`; uncommitted
termination/UI changes were excluded. Version is 3.4.3, build 14. Code APIs of the
production app were not changed by this task.

| Requirement / scenario | Implementation | Check / evidence | Result |
| --- | --- | --- | --- |
| Agent version and increment validation | AGENTS, release validator, Info.plist | Version/CLI tests, quality gate | passed |
| Exact-source assets and CI dependency graph | reusable CI, publisher, manifest checks | 48 targeted tests; workflow validation | passed locally; remote unverified |
| Draft retry, tag conflict, no published overwrite | API client and checksum receipt | API/transport fault fixtures | passed simulated API |
| New-change ownership and changed Python coverage | quality validator | 100% measured lines/branches in release.py and quality.py | passed |
| Red-green rejects setup failure | disposable base archive runner | 5 real transplant/import/symlink fixtures | passed |
| Critical guards are asserted | disposable mutation runner | 12 faults; each copied unmodified baseline green first | passed |
| Complete native old regression | regression runner | native-final-clean-cache.log, 200-MB/RSS receipt, private native UI | passed Apple Silicon/macOS 27 |
| Universal mounted image and layout | packager and DMG acceptance | Finder and --ci logs, signature/bytes/version/slices | passed |
| Version and checksum finalization | release finalizer | local-only fixture with synthetic source SHA | passed; not a release record |
| Visibility and token boundary | workflow permissions | Actions enabled/all; default workflow permission read; write only publisher | inspected; unchanged remotely |

Commands on the frozen candidate:
- `python3 scripts/check-quality.py --base ffcd093827c158a5b95c29658dac9dca94a6ef1f --worktree --actionlint <verified actionlint>` with the task's pinned Python dependency path.
- `./scripts/test.sh --local` outside the host sandbox for read-only ps/lsof.
- `./scripts/package-dmg.sh` and `python3 tests/dmg_acceptance.py build/NoSleep-universal.dmg`.
- `python3 tests/dmg_acceptance.py --ci build/NoSleep-universal.dmg`.
- Local `release.py finalize` fixture: synthetic SHA, no publish call or credentials.

Raw logs, input digests, coverage and receipts are in
`.taskflow/auto-releases/final/`. Local image:
`build/ci-release-acceptance/NoSleep-3.4.3-universal.dmg`, SHA-256
`c84d1e1b606a3d7bbedc07caa10d4d58628afb6dd9f0b3c80af1b618fde4285b`.

Historical failures were retained rather than masked: initial sandbox denied ps;
the first snapshot became inconsistent when another task added an icon test;
relocated Swift caches failed due to absolute paths. The final coherent snapshot
used fresh owned caches and the final complete regression passed. Pure quality
and workflow checks were repeated after their actual inputs changed. No successful
old run is used to override a newer failed run.

Document validation: bundled OpenSpec 1.14.1 strict validate reports valid with no
issues. Review: self-review completed; personal review explicitly not required.
At the initial local handoff no commit, push, merge, GitHub publication, installation or scope registration had run. The user subsequently requested a PR; its branch contains the tested inputs and omits unrelated termination documentation. Commit, branch push and PR creation are authorized by that follow-up; merge and release publication remain outside this action.
Change remains active; archival was not requested.

Unverified: actual GitHub Actions run and download; native Intel execution;
real power/admin setup/lid/shutdown/Gatekeeper; the other task's uncommitted
termination UI. Native Swift/shell/orchestration use black-box evidence rather
than a claimed 100% Swift percentage. Python patch/Swift runtime differs across
hosted platforms; actual runtime is retained, not inferred from the runner label.

Hosted follow-up: PR #1 head `8e110a6c8c208aa4991225fd0b7c5e063d1daaef`, run `38557413768`: quality and ARM passed; Intel failed because the contract fixture compiled its read-only probe as ARM unconditionally (`OSError: Bad CPU type in executable`). Package was correctly skipped. The fixture now targets the actual native architecture and asserts the Mach-O slice; real power/VM behavior remains isolated. Hosted final-head validation is pending.

Local follow-up checks: `scripts/test.sh --local` passed on Apple Silicon after the fix, including 19 power-handoff contracts; unchanged app packaging inputs retain their prior mounted-DMG evidence. The complete quality gate passed (48 focused tests, 12 assertion-killed mutations). The initial sandbox compile failed because the default Swift module cache was not writable; the complete authorized run outside that sandbox passed.
