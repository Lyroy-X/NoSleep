# Verification: redesign-native-ui

Scope: /private/tmp/nosleep-compact-ui, feature/compact-ui; compact UI, existing shortcut and required native-proof routing.
Base: 9b0803985ced72b658dbd696fe2bb4cb7fbf5f02 (main was updated during implementation).
Code state: base plus working UI diff; tested source digest `abd6adc23a9ac9214a976d71775b67c67bab36d5d04b9323e65b0fa2a38ba37e`.

| Requirement / scenario | Implementation | Check / evidence | Result |
| --- | --- | --- | --- |
| Compact/expanded native layout | MenuApp.buildWindow | Sources/UITests.swift fixture; 4 appearances × 3 sizes, current native PNGs | passed |
| Requested versus actual state | PowerPresentation.make | PresentationTests.swift: normal/checking/pending/error/external/retry and all 16 boolean boundaries | passed |
| First-run, error and retry | MenuApp.render | current private UI fixture, cancellation feedback and retry state | passed |
| Independent controls and menus | unchanged command routes | native fixture switch/menu/combined actions and duplicate refusal | passed |
| Existing Shift-Command-A | ApplicationMenu uppercase key equivalent | correct synthetic native event; isolated action recorder and fake power action | passed |
| Original shortcut bug | exact base snapshot + changed UITests.swift | build/quality/red-green-1.log: compiled original emits ERROR for unmatched shifted shortcut | reproduced |
| Critical status confirmation gate | unchanged versus defective private copies | tests/compact_status_mutation.py; faulty copy fails by assertion | passed |
| Workflow native-proof safety | macOS quality job, existing ARM/Intel native matrix | compact_ci_acceptance.py; faulty scheduling and unknown-architecture fallback rejected by assertions | passed |
| Exact diff/metadata/coverage policy | repository quality command | build/quality/receipt.json; 12 existing critical mutations, native red-green proof, no changed production Python | passed |
| Complete native regression and selected business E2E | final fixed sources | scripts/test.sh --local; UI receipt build/ui-acceptance/405ff517bfb14a13862f9f659b65e13b/receipt.json | passed locally on ARM |
| Universal package | separate release build | package-dmg.sh + dmg_acceptance.py --ci: signature, exact bytes/version, both architectures/layout | passed locally |
| UI responsiveness observation | unchanged native fixture render | 300 samples, p95 recorded in render-observation.json, unchanged ui.json mtime; no baseline/energy/FPS claim | observed |
| Agent review | exact implementation | power/setup/export/termination logic retained; all production paths have focused changed tests | passed; personal review not required |

Commands: `build/ci-python/bin/python scripts/check-quality.py --base 9b0803985ced72b658dbd696fe2bb4cb7fbf5f02 --worktree --actionlint <verified actionlint 1.7.12>`, `./scripts/test.sh --local`, `python3 tests/compact_status_mutation.py`, `./scripts/package-dmg.sh`, `python3 tests/dmg_acceptance.py --ci build/NoSleep-universal.dmg`.

Earlier outcomes retained: initial sandbox UI launch failed without output; the same fixture passed outside sandbox. Two initial synthetic-shortcut attempts failed; a separate 4-case diagnostic proved the original lowercase declaration remains unmatched with correct shifted-event metadata. The UI expectation and declaration were corrected, and the complete final gates passed. Targeted successes did not override those failed full runs.

Manual/unverified: real power, administrative setup, shutdown/restart, lid closure, downloaded-app Gatekeeper, VoiceOver session and physical keyboard input. PNGs cache native view drawing rather than proving composited window-server materials. Local packaging proves both architectures exist, not Intel execution. Remote exact-head CI is pending PR creation.

Business decisions: compact concept 1; local E2E; no personal implementation review; concrete solution accepted; PR targeting main without merge/publication. No memory save/scope registration authorized.
