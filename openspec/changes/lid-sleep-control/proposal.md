# Proposal

## Why

MacBook users need to choose what happens when they close the lid separately from idle sleep and display protection.

## What Changes

- Add a separate native switch «Не усыплять Mac с закрытой крышкой» and expose it in both menus and the combined action.
- Scope the existing sleep switch and the display prerequisite to idle protection. Only the lid switch uses the system-wide sleep override.
- Preserve the local watchdog feedback fix. Verify independent choices, recovery, migration and combined actions with simulated power.

## Capabilities

### New Capabilities

- `lid-sleep-presentation` gives the closed-lid policy its own control, feedback and persistent selection.

### Modified Capabilities

None.

## Impact

AppKit control labels, help, status text, native acceptance and release documentation.
