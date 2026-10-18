## ADDED Requirements

### Requirement: Independent confirmed finite protection
NoSleep SHALL offer a native popover for each power control, with 15/30/60/120 minute presets, custom hours/minutes from 1 minute through 7 days, and an indefinite action. Time SHALL start after successful protection acquisition and SHALL use a continuous deadline independent of wall-clock adjustments. Readiness, busy and termination guards SHALL apply.

#### Scenario: Confirmed activation
- **WHEN** the user applies a valid duration to a ready control
- **THEN** its full duration begins after acquisition confirmation and the row displays remaining time and its return state

#### Scenario: Invalid or refused activation
- **WHEN** input is invalid, permission is absent or activation fails
- **THEN** no successful timer is presented, the error is visible and retry remains possible

### Requirement: Restore baseline with dependencies
Each timer SHALL restore the selection from before the temporary session. A running display timer SHALL retain system protection after an independent system timer expires. Existing manual system-off SHALL cancel both timers; manual display-off SHALL preserve sleep protection. Replacing a timer SHALL retain the original baseline.

#### Scenario: Crossed deadlines
- **WHEN** system protection expires while a longer display session still needs it
- **THEN** system protection remains effective until the display session ends or is manually disabled

#### Scenario: Already enabled baseline
- **WHEN** a timer starts on an already indefinitely enabled feature
- **THEN** expiration returns that feature to enabled and the picker explains that outcome

#### Scenario: Restoration refused
- **WHEN** baseline restoration fails
- **THEN** ownership and an explicit retry action remain; the application does not claim successful completion

### Requirement: Bounded persistent custom choices
NoSleep SHALL remember at most five unique recent custom durations separately per feature, in addition to fixed presets. Reuse SHALL move a custom duration to the front. Choices SHALL be saved only after successful activation; duplicate standard durations SHALL NOT create custom chips. Each custom chip SHALL have an accessible removal control. Removal SHALL NOT change an active deadline or another feature's history.

#### Scenario: Five-hour reuse
- **WHEN** the user successfully applies five hours and later reopens the picker or restarts the app
- **THEN** the five-hour chip and last duration remain available for that feature

#### Scenario: Remove running duration
- **WHEN** the user removes the chip whose value equals an active timer
- **THEN** the saved choice is removed persistently and the active timer continues

#### Scenario: Limit and corrupt preferences
- **WHEN** more than five custom values are used or stored preferences contain malformed values
- **THEN** only five recent valid distinct custom values are displayed and invalid values are not coerced

### Requirement: Safe process lifecycle
Closing the window SHALL preserve running timers. Normal termination SHALL use existing power cleanup and retain baseline launch preferences. After an interrupted temporary session, the next ready launch SHALL restore the captured baseline immediately rather than restart a full duration or retain temporary protection indefinitely. Failed or corrupt recovery SHALL stay visible and allow explicit manual recovery.

#### Scenario: Relaunch after interruption
- **WHEN** a saved temporary baseline exists at startup
- **THEN** baseline restoration is confirmed before its marker is removed; invalid recovery is reported

### Requirement: Native isolated verification
The picker SHALL use semantic native colors, accessible controls, keyboard editing and bounded layout, with no additional polling timer. Automated tests SHALL use fake power and separate app/state and SHALL NOT change real power, credentials, the installed application or VM state. Automatic-lock timed restoration SHALL remain unavailable under the existing fresh-password contract.

#### Scenario: Native saved-chip acceptance
- **WHEN** the isolated UI enters a custom duration, retries failure, removes its chip and finishes a session
- **THEN** actual native controls, persisted isolated history and baseline state agree in light/dark appearances

### Requirement: Discoverable timer action
The idle per-function duration control SHALL show a native timer symbol and a clear localized timer label, retaining the symbol beside an active countdown.

#### Scenario: Recognize and reuse the duration control
- **WHEN** protection is idle, running, refused, or finished
- **THEN** the duration action remains recognizable as a timer and preserves permission gating
