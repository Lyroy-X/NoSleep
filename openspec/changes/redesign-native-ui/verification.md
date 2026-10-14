# Verification: redesign-native-ui

Scope: /private/tmp/nosleep-compact-ui, feature/compact-ui; compact UI, existing shortcut and required native-proof routing.
Base: 385fa5e7cc90aae50e681e7486f30b8413b0407d (main was updated during implementation).
Code state: base plus working UI diff; tested source digest `647a61aa5b91cbb59adb913223a382ee43c006b8fcc326439b6b0088e62afbb6`.

| Requirement / scenario | Implementation | Check / evidence | Result |
| --- | --- | --- | --- |
| Compact/expanded native layout | MenuApp.buildWindow | Sources/UITests.swift fixture; 4 appearances × 3 sizes × 2 scrollbar styles, current native PNGs | passed |
| Requested versus actual state | PowerPresentation.make | PresentationTests.swift: normal/checking/pending/error/external/retry and all 16 boolean boundaries | passed |
| First-run, error and retry | MenuApp.render | current private UI fixture, cancellation feedback and retry state | passed |
| Independent controls and menus | unchanged command routes | native fixture switch/menu/combined actions and duplicate refusal | passed |
| Existing Shift-Command-A | ApplicationMenu uppercase key equivalent | correct synthetic native event; isolated action recorder and fake power action | passed |
| Original shortcut bug | exact base snapshot + changed UITests.swift | build/quality/red-green-1.log: compiled original emits ERROR for unmatched shifted shortcut | reproduced |
| Critical status confirmation gate | unchanged versus defective private copies | tests/compact_status_mutation.py; faulty copy fails by assertion | passed |
| Workflow native-proof safety | macOS quality job, ARM-only shared workflow for PR/push/manual/main | compact_ci_acceptance.py; faulty scheduling, Intel reintroduction and unknown-architecture fallback rejected by assertions | passed |
| Exact diff/metadata/coverage policy | repository quality command | build/quality/receipt.json; 13 existing critical mutations, native red-green proof, no changed production Python | passed |
| Complete native regression and selected business E2E | final fixed sources | scripts/test.sh --local; UI receipt build/ui-acceptance/a4c7b3aeec754b9ab76359244654f24d/receipt.json | passed locally on ARM |
| Universal package | separate release build | package-dmg.sh + dmg_acceptance.py --ci: signature, exact bytes/version, both architectures/layout | passed locally |
| UI responsiveness observation | unchanged native fixture render | 300 samples, p95 recorded in render-observation.json, unchanged ui.json mtime; no baseline/energy/FPS claim | observed |
| Agent review | exact implementation | power/setup/export/termination logic retained; all production paths have focused changed tests | passed; personal review not required |

Commands: `build/ci-python/bin/python scripts/check-quality.py --base 385fa5e7cc90aae50e681e7486f30b8413b0407d --worktree --actionlint <verified actionlint 1.7.12>`, `./scripts/test.sh --local`, `python3 tests/compact_status_mutation.py`, `./scripts/package-dmg.sh`, `python3 tests/dmg_acceptance.py --ci build/NoSleep-universal.dmg`.

Earlier outcomes retained: initial sandbox UI launch failed without output; the same fixture passed outside sandbox. Two initial synthetic-shortcut attempts failed; a separate 4-case diagnostic proved the original lowercase declaration remains unmatched with correct shifted-event metadata. The UI expectation and declaration were corrected, and the complete final gates passed. Targeted successes did not override those failed full runs.

Manual/unverified: real power, administrative setup, shutdown/restart, lid closure, downloaded-app Gatekeeper, VoiceOver session and physical keyboard input. PNGs cache native view drawing rather than proving composited window-server materials. Local packaging proves both architectures exist, not Intel execution. PR #4 was created at head 1e51e6c; quality passed remotely, while ARM/Intel UI jobs found stale document width when legacy scrollers tile. This was reproduced locally (423 versus 440 viewport), corrected in native tiling, and the fresh complete local quality/native/package gates passed. The corrected faed504 run 38575877720 passed remotely. Main then advanced to 3.4.5/build 16; its termination behavior was retained, the isolated termination fixture was updated to include the new presentation module after its initial compile failure, and the complete local gates passed again. User explicitly disabled all Intel CI scheduling in the shared workflow for future PRs and main; the new ARM-only head remote checks remain pending. Version is 3.5.0/build 17.

Business decisions: compact concept 1; local E2E; no personal implementation review; concrete solution accepted; PR targeting main without merge/publication. No memory save/scope registration authorized.
