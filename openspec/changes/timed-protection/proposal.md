# Proposal

## Why
Users need to enable NoSleep protection temporarily without remembering to restore it. Frequently reused custom durations should be immediately available without accumulating an unlimited list.

## What Changes
- Add independent system/display timers through native per-row popovers (user-selected design A).
- Restore the pre-timer baseline on expiration while preserving the display-to-system dependency.
- Persist up to five recent unique custom durations per feature; provide accessible removal crosses which do not affect active timers.
- Preserve current permission, busy, manual-control, termination and password rules. Automatic-lock remains manual.

## Capabilities
### New Capabilities
- `timed-power-protection`: independent finite protection, baseline restoration and reusable duration selection.
### Modified Capabilities
None; existing power dependency and manual command behavior remain applicable.

## Impact
GuardEngine, native window rows, a new duration picker/history, isolated tests, source evidence, version and user documentation. No new external service, administrative setup, credential storage, network behavior or installed-app change.
