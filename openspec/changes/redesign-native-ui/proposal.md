# Proposal

## Why

The operator requested a redesigned NoSleep interface and a pull request targeting main, with visual alternatives presented before implementation. The current 600×620 utility window gives its two controls little visual hierarchy and leaves substantial unused space.

## What Changes

- Present three static native-style concepts in light and dark appearance: compact utility, separate protection cards, and sidebar navigation.
- Implement the selected compact concept after concrete solution approval; local E2E and no personal implementation review were explicitly selected.
- Preserve independent sleep/display controls, requested versus actual state, combined action, first-run permission feedback, error/retry feedback, diagnostics, window restoration and menu commands.
- Verify the approved UI using isolated power/state fixtures, native appearance/layout checks and the repository's required regression/package checks.
- Prepare a scoped feature-branch PR targeting main, preserving pre-existing uncommitted release and termination work outside this task's publication scope.

## Capabilities

### New Capabilities

- `native-utility-presentation`: adaptive native visual hierarchy, explicit protection status, first-run/error presentation and keyboard/accessibility support for the existing utility commands.

### Modified Capabilities

None. Power behavior and diagnostics contracts remain unchanged.

## Impact

Scope: compact AppKit presentation in Sources/NoSleep.swift and PowerPresentation.swift, the existing shifted shortcut in ApplicationMenu.swift, focused native UI tests/fixtures, native-proof CI routing, version metadata, changelog/docs and this OpenSpec change. No new power, VPN, credential or network operations. The committed intake base is ffcd093827c158a5b95c29658dac9dca94a6ef1f; remote main and overlapping version work must be rechecked before preparing the implementation branch.

The operator accepted the concrete compact redesign proposal on 2026-10-14. Implementation, full local checks and agent review passed; commit/PR and remote checks remain pending. These planning artifacts do not authorize production-code changes or attest any UI/performance checks.
