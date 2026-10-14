## Context
Baseline HEAD is 0beea41c337a3e773cfd6eec76d3e35f213a2b7f with mixed uncommitted VPN and unrelated improvements. A private full file/hash backup and binary Git diff were frozen before edits.

## Goals / Non-Goals
Remove all production VPN code and UI. Preserve the current power implementation, native utility UI, diagnostics resource bounds, build/install/packaging guards. Installed application, power settings, corporate connection, Keychain and historical VM state remain untouched.

## Decisions
Delete VPN-only Swift modules rather than disabling their controls. Remove VPN fields and event types from diagnostic serialization and increment summary format to 3. Keep native menu/edit/window/help actions and two independent switches. Run current UI against fail-closed in-memory power dependencies with a private defaults domain and output directory. Retain existing power-handoff tooling and VM transport dependencies so unrelated work is not discarded.

## Risks / Trade-offs
Legacy VPN preferences/credentials remain inert on disk and in Keychain; no migration deletes user data. Historical VM tools are not current application functionality or acceptance evidence. Native UI E2E proves routing/presentation with isolated power, while production unit tests verify power/diagnostic logic; actual pmset/lid behavior is not exercised in this task.

## Migration Plan
No installation or external migration. Build a separate candidate and verify absent network/credential/accessibility imports. Private pre-change backup permits reversal.

## Open Questions
None. User selected all VPN removal, local E2E and no personal review; commit/push/install are not authorized by this task.
