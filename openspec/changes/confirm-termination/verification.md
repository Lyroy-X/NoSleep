# Verification: confirm-termination

Scope: shutdown/restart confirmation on the merged automated-release base, version 3.4.5/build16, isolated feature/confirm-system-termination. Base/main: 9b0803985ced72b658dbd696fe2bb4cb7fbf5f02 (3.4.4/build15). The dependency chat completed locally without Git publication; imported files and digests are retained in .taskflow/confirm-termination-release/import.json. Unfinished UI redesign is excluded.

| Requirement / scenario | Implementation | Check / evidence | Result |
| --- | --- | --- | --- |
| Shutdown/restart only, encoded reason boundaries | SystemTerminationRequest | terminationTests in complete native suite | passed |
| Cancellation, safe Enter/Escape, repeated/reentrant requests | MenuApp + native confirmation | nativeTerminationAcceptance and actual local Apple Event dispatch | passed |
| Cleanup failure preserves protections, guard/retry and visible error | GuardEngine + MenuApp | FakePower unit and native fixture failure/retry | passed |
| Ordinary quit/logout unchanged | quit event parser + existing cleanup | unit + native UI acceptance | passed |
| Original bug reproduces on compilable base | public termination delegate, embedded fake dependencies | build/quality/red-green-0.log: cancel=false, protected=false, cleanup counts 1/2; Python assertion failures, not import/compile errors | passed |
| Confirmation safety guard detects faulty copy | termination_regression.py | original passes; bypassed guard fails cancellation/protection assertion | passed |
| Native proofs execute in macOS lanes | check-quality + workflow | runner/workflow tests; critical Linux-deferral mutation | passed |
| Exact diff, coverage and release metadata | completed release infrastructure | complete quality gate; scripts/release.py and scripts/quality.py each 100% lines/branches; 13 critical mutations | passed |
| Full native regression and isolated UI | scripts/test.sh --local | native-3.4.5.log; 200-MB fixture; UI receipt 881f7a6c6d0b4d42bb50d584df65d0e5 | passed |
| Universal DMG/Finder/signature/exact bundle | packager + dmg_acceptance | package.log + dmg.log, version 3.4.5/build16, arm64/x86_64 | passed |

Commands: PYTHONPATH=<existing pinned dependency directory> python3 scripts/check-quality.py --base a5589e08f11e7394b42db7b7ec7a5981822a415b --actionlint <verified actionlint>; ./scripts/test.sh --local; ./scripts/package-dmg.sh; python3 tests/dmg_acceptance.py build/github-release/NoSleep-universal.dmg. Raw logs and hashes are in .taskflow/confirm-termination-release.

DMG SHA256: 36e7273ef138835f4bf4e8daf345064cd7a1d007c98c2219bad38e31e98f53dc. Strict document validation is recorded in openspec-validation.log. Git publication uses this tested content; final commit/PR receipts remain private to avoid a self-referencing source SHA.

Unverified locally: actual host shutdown/restart/logout, real power/admin/lid/Gatekeeper, Intel execution and real GitHub release/download. The local event is dispatched exclusively inside the fixture process. CI/Intel execution is reported separately when observed; no merge or manual release publication is authorized. Forced termination and unrecognized system reasons cannot be intercepted by this contract.

User decisions: system shutdown/restart only, local E2E, no personal review, nothing saved in memory, wait for the completed automation, then patch bump/DMG/checks/commit/push/PR. No repeat approval is required. Taskflow's historical question audit did not recognize the original E2E option order; the actual submitted local E2E choice remains authoritative, without new preference questions or plugin modifications.

Final integration: automation was merged into main during verification. The candidate was rebased on a5589e08f11e7394b42db7b7ec7a5981822a415b; incoming automation/Intel contracts and changelog history are retained. Existing application/package input hashes match the verified DMG. Quality and full native checks are refreshed on this base; release/DMG metadata will bind to the final commit.

Main advanced again to 9b0803985ced72b658dbd696fe2bb4cb7fbf5f02 (3.4.4/build15), with bounded UI completion. Its test and changelog are preserved through local feature integration without force-push. Version recomputed to 3.4.5/build16; quality, native and DMG checks are refreshed. Earlier published SHA 480e8f6 passed all four GitHub lanes, including actual Intel execution; final-head CI is checked separately.
