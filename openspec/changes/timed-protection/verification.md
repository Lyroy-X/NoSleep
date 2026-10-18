# Verification: timed-protection

Scope: the original NoSleep checkout; independent sleep/display timers, baseline restoration and native saved removable custom durations. Automatic-lock remains manual.

Code state: HEAD ffcd093827c158a5b95c29658dac9dca94a6ef1f plus the existing working tree and this task's reviewed changes; version 4.1.0/build 21. Exact source/config/test identities are retained in `build/timed-protection-implementation/quality-receipt.json`, `native-receipt.json`, `package-receipt.json` and `review.json`. No commits or Git refs changed. Completion updates to this verification document and task checkboxes follow the checks; production/test/config inputs remain unchanged.

| Requirement / scenario | Implementation | Check / evidence | Result |
| --- | --- | --- | --- |
| Independent confirmed deadlines and crossed sessions | TimedPowerPlan, GuardEngine | timed-receipt.json; seven compiled faulty copies rejected by assertions | passed |
| Refusal, retry, lost assertions and no-save preservation | GuardEngine | timed-receipt.json; quality-verified.log | passed |
| Five-hour custom chip, duplicates, cap, deletion and restart | DurationHistory, DurationPopover | timed-receipt.json separate-process write/read/remove/read; native UI fixture 8cf0504f9ae74acf9e18e7c004102d87 | passed |
| Actual native picker, invalid fields, activation retry, deletion during an active session | MenuApp, DurationPopover | same UI fixture receipt/runtime and light/dark PNGs | passed |
| Stable text, error visibility, minimum window and native alignment | MenuApp.render | same UI fixture and native-regression.log | passed |
| Existing power/lock/quit/diagnostics behavior | full existing native suite | `env -u NOSLEEP_SIGNING_CONFIG ./scripts/test.sh --local`; native-receipt.json | passed |
| Exact diff, coverage, release metadata and quality mutations | unchanged quality command | quality-receipt.json; quality-verified.log | passed |
| Universal image contents, stored layout and exact binary | universal package | package-receipt.json; dmg-acceptance.log (`--ci`, no Finder automation) | passed |

Document validation: `node <selected Taskflow 0.16.2>/scripts/openspec.mjs run build/timed-protection-implementation/validate.json` passed strict local change validation; output is `openspec-validation.json`.

Behavior checks: `python3 tests/timed_protection_acceptance.py`; the full quality command in docs/quality-gates.md with base ffcd093827c158a5b95c29658dac9dca94a6ef1f and worktree mode; complete `scripts/test.sh --local`; universal package and read-only DMG acceptance. Commands and source identities are recorded separately in their receipts.

Unverified: real host sleep/wake, physical crash/lid/first administrative setup/shutdown-restart acceptance, downloaded-app Gatekeeper, Intel runtime and remote GitHub Actions. Automated power/policy dependencies were fake and preferences/app state isolated. The installed app and VM were not changed. Local universal assembly does not prove Intel runtime or publication.

Business decisions: user selected A, separate per-feature times, restoration of the prior NoSleep selection and saved removable custom choices; no personal implementation review. Five recent unique custom choices per feature is the bounded UI policy. Running deadlines are independent of history deletion. Window close continues; process exit does not resume the full duration, and interrupted baseline recovery runs at the next ready launch.

## Release integration — 2026-10-18

The delivery worktree is based on current main `d10712d3b24f4686f716dea7ddee13fcbbe8e880`. The original dirty checkout is preserved. Current-main ARM-only workflows, shortcut, published cleanup and release notes are retained. Native fitting-scroll acceptance, delayed completion, keyboard routing and all automatic-lock assertions remain in the suite. Content is 600×620 with a 520-point minimum width for the chosen timer controls.

New exact-diff quality and native UI E2E passed after integration; the initial complete native run exposed missing new-module dependencies in the existing isolated termination regression compiler. That test compiler now conditionally uses the current hermetic stubs/modules while retaining its legacy base fixture; both cancellation and confirmation-bypass mutation pass. The entire quality/native suite is rerun, and final receipts under the original checkout’s ignored `build/timed-protection-delivery/` are authoritative for delivery. Universal package/read-only DMG acceptance passed on the unchanged app sources. GitHub CI, installation and publication must be read back separately before being claimed complete.

User delivery instruction authorizes local update, commit/push, a new or existing PR and a new release. Personal review remains waived; final merge follows host instructions. Project memory remains disabled by the explicit no-save choice.
