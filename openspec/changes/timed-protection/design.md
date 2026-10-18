# Design

GuardEngine owns timer plans on its existing serial queue. A plan overlays finite system/display leases on explicit baseline selections; effective sleep also depends on display. Expiration is reconciled before the existing watchdog refresh. Failed restoration retains the old plan and reports a retryable error instead of issuing unbounded retry attempts.

ContinuousClock supplies elapsed time. Each successful activation sets its deadline after acquisition. The existing one-second watchdog updates state; the UI adds no new timer or continuous animation. MenuApp receives immutable presentation snapshots on the main queue.

Before temporary activation, capture baseline launch preferences and a recovery marker. Active countdowns intentionally do not resume after process exit: normal quit uses existing cleanup; an interrupted run's next ready launch restores baseline immediately. This avoids serializing a process-local continuous instant or extending an expired session. A closed window continues in the same process.

DurationHistory validates integral minute values, uses feature-scoped UserDefaults, suppresses built-in/duplicate choices and retains five most recent custom values. A separate accessible removal button only updates history. A successfully applied duration updates history and the next picker selection; failed/cancelled input does not.

DurationPopover uses AppKit stack views, buttons, text fields and a transient NSPopover anchored to the selected row. Five custom choices wrap across at most three rows. Fields, validation, return-state disclosure and primary action remain in the popover. Existing switches retain their manual behavior and permission/password gates.

User decisions: design A; separate timers; restore previous state; saved removable custom chips; no personal implementation review. Scope is sleep/display, with automatic lock manual. User subsequently authorized a local installed-app update, commit/push, creating or updating a PR, and publishing the new version. PR merge requires the final explicit merge decision under the host instructions. Real-power acceptance and project-memory writes remain outside scope.

Release integration: use current main d10712d3b24f4686f716dea7ddee13fcbbe8e880 as the base, preserve its ARM-only CI policy, published cleanup, fitting native viewport, keyboard shortcut, and delayed-completion/termination contracts. Expand content to 600×620 (minimum width 520) for the selected duration controls. Preserve 3.6.0 and earlier release notes. Version 4.1.0/build21 covers the pending major-4 dependency change and compatible timer capability.
