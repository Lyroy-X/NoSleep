## Purpose

Allow users to choose closed-lid sleep separately from idle sleep, display protection and automatic locking.

## ADDED Requirements

### Requirement: Discoverable closed-lid protection

NoSleep SHALL provide a separate switch «Не усыплять Mac с закрытой крышкой» in the window, application menu and status menu. All three entry points SHALL control the same lid sleep override.

#### Scenario: Enable from the window

- **WHEN** a user enables the switch and macOS confirms the command
- **THEN** the window describes closed-lid protection and both menus show the checked state

#### Scenario: Disable from a menu

- **WHEN** the user disables the switch from either menu and macOS confirms the command
- **THEN** all surfaces show it unchecked and the window describes normal macOS lid policy

#### Scenario: Independent and combined protections

- **WHEN** a user turns off the lid switch while idle and display protection are active
- **THEN** those protections stay active and macOS can sleep when the user closes the lid
- **WHEN** a user turns off idle protection while the lid switch is active
- **THEN** dependent display protection turns off and lid protection stays active
- **WHEN** the user applies a combined action
- **THEN** it includes the available lid control and respects the existing lock-policy confirmation

### Requirement: Owned override and saved selection

NoSleep SHALL persist the lid choice independently, release its own override at normal quit and leave externally imposed sleep overrides untouched.

#### Scenario: Settings and restart

- **WHEN** a user opts into lid protection and restarts the app
- **THEN** the app restores the selection after its normal setup check
- **WHEN** a saved selection predates the new control
- **THEN** the app migrates the former system protection choice

### Requirement: Accurate confirmation

NoSleep SHALL report the confirmed sleep protection state and surface command errors. It SHALL preserve the existing setup requirement and timer and display protection behavior.

#### Scenario: Command refused and retried

- **WHEN** macOS refuses to change protection
- **THEN** the previous selection remains visible, the error is shown, and the user can retry

#### Scenario: Missing permission

- **WHEN** NoSleep lacks power permission
- **THEN** the switch and menu commands cannot enable protection before setup

#### Scenario: Timer or display protection active

- **WHEN** the system timer is running or display protection requires system protection
- **THEN** the original two switches reflect the timer and display dependency without changing the separate lid selection

#### Scenario: Watchdog repairs an external reset

- **WHEN** macOS resets system sleep protection and NoSleep successfully restores it
- **THEN** diagnostics record the reset and the interface continues to show confirmed protection without a transient warning

#### Scenario: Watchdog cannot repair an external reset

- **WHEN** macOS refuses to restore the requested system protection
- **THEN** the interface shows the failure and clears it after a successful retry
