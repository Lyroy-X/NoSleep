# Proposal

## Why
The display switch currently allows a sleep-off/display-on combination even though display prevention itself prevents idle system sleep. The user requests consistent dependencies, including failure, retry and restart paths. A separate confirmed defect is that a partially successful combined power action is not persisted.

## What Changes
- Define display-on => system-on consistently across model, window, menus and saved-state restoration, matching the user's clarified expectation that the sleep checkbox automatically becomes selected with display protection.
- Display-on first acquires confirmed system protection; sleep-off releases display only after sleep restoration succeeds; display-off retains system protection. **BREAKING**: display-only use without initial sleep permission now requires setup. Include this consequence in the exact solution approval.
- Persist successfully acquired/retained power state on partial failures and retain error feedback and retry.
- Serialize initial restoration with native actions and enforce readiness before combined lock/password actions.
- Keep automatic-lock policy independent; retain password cancellation, original-policy restoration and manual-lock behavior.
- Add an explicitly approved transient help card with three short use cases, separate restoration details, and native switch/status/popover motion respecting Reduce Motion. Do not delay model/accessible state for animation.
- Add focused regression/mutation tests, isolated native acceptance and exact version documentation. Prepare 4.0.0/build 16: major for removing the independent display-only behavior, including the existing compatible automatic-lock capability and release work relative to main 3.4.2/build 13.

## Capabilities
### New Capabilities
- `protection-dependencies`: consistent power selection, confirmation, failure persistence and restoration.
- `native-protection-feedback`: contextual use-case help and unobtrusive native state transitions.

### Modified Capabilities
None in openspec/specs. Relevant in-flight independent-control specs were read in remove-all-vpn-features, redesign-native-ui and add-idle-lock-control; this change will state the selected replacement behavior without rewriting unrelated work.

## Impact
Sources/NoSleep.swift, focused Swift model tests, isolated native UI fixture, evidence ownership, README/testing documentation, changelog and app version. No network, credentials, real host policy/power, VM, installed app, commit, push or publication is authorized by this proposal. Baseline identities and four named model assertions are recorded in build/control-dependencies; the first three test the proposed stronger contract, while partial-state persistence reproduces a defect under the existing contract.

## Decisions pending
User selected local E2E and no personal review. Both exact solutions were explicitly approved in this chat: original dependency/setup/version scope and the added nonmodal help/native motion scope. No commit, installed-app update or publication requested.
