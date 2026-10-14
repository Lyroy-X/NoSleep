## Purpose

Provide a compact, accessible native presentation of NoSleep's existing power protections, with clear separation between requested and confirmed state.

## ADDED Requirements

### Requirement: Compact independent controls
NoSleep SHALL show its two independent protection controls in one compact group, with an overall status, combined action and manual diagnostics export. The ordinary ready-state window SHALL fit approximately 440×430 content points and retain resize, close-to-background and standard menus.

#### Scenario: Ready state
- **WHEN** power permission is ready and no command or error is pending
- **THEN** both independent switches, their state labels, combined action and report command are visible in the compact window

#### Scenario: Expanded window
- **WHEN** the user enlarges the window
- **THEN** controls remain aligned and text remains readable without overlapping

### Requirement: Confirmed protection status
The overall status SHALL describe confirmed app-requested protection and SHALL NOT present an unconfirmed requested action as successfully applied. Switching, permission checking and failure SHALL have explicit textual feedback.

#### Scenario: Requested protection not confirmed
- **WHEN** protection is requested but actual protection is absent
- **THEN** the status shows confirmation failure and retains the independent requested switch state

#### Scenario: Retry succeeds
- **WHEN** an unsuccessful action is retried and actual protection becomes confirmed
- **THEN** failure feedback clears and the status reflects confirmed protection

#### Scenario: Command pending
- **WHEN** an action is applying
- **THEN** the interface presents pending feedback and retains existing duplicate-action prevention

### Requirement: Setup and errors remain usable
First-run setup, cancelled setup, permission loss and operation errors SHALL stay visible. Missing sleep permission SHALL leave display protection available. Additional content SHALL remain reachable through scrolling at the minimum window size.

#### Scenario: Missing permission
- **WHEN** sleep permission is unavailable
- **THEN** sleep control is disabled, display control is available and the native setup action is visible

#### Scenario: Cancelled setup
- **WHEN** setup is cancelled
- **THEN** explanatory feedback remains visible and setup can be attempted again

### Requirement: Native accessible appearance
The interface SHALL follow system light/dark appearance, use textual status in addition to color, retain accessible control names and keyboard/menu access, and require no continuous animation or additional background polling.

#### Scenario: System appearance changes
- **WHEN** the system changes between light and dark appearance
- **THEN** labels, controls and surfaces remain legible using native semantic colors

#### Scenario: Keyboard and assistive use
- **WHEN** the user navigates by keyboard or accesses the controls through assistive technology
- **THEN** both protection controls, setup and diagnostics have meaningful names and remain reachable

### Requirement: Isolated acceptance
Automated verification SHALL use separate build/state and fake power dependencies, without changing real power, Keychains, networking or an installed NoSleep application.

#### Scenario: Local E2E
- **WHEN** the selected local E2E runs
- **THEN** it verifies current native UI routes, state transitions and layout using the isolated fixture and records its input identities
