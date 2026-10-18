## Purpose
Keep NoSleep's power selections consistent with the requested display-to-system dependency across commands, failures, native UI and restart.

## ADDED Requirements

### Requirement: Display requires system protection
NoSleep SHALL confirm system protection before enabling display protection.

#### Scenario: Display enabled from off
- **WHEN** display protection is enabled
- **THEN** both power switches become selected after system protection is acquired

#### Scenario: Prerequisite refused
- **WHEN** macOS refuses system protection
- **THEN** display protection remains off, the failure is reported and retry remains possible

### Requirement: Directional disabling
Disabling system protection SHALL release dependent display protection only after system restoration succeeds.

#### Scenario: Sleep disabled
- **WHEN** system restoration succeeds with both protections on
- **THEN** both protections turn off

#### Scenario: Sleep restoration refused
- **WHEN** system restoration fails
- **THEN** both previously active protections remain selected and retryable

#### Scenario: Display disabled
- **WHEN** display protection alone is disabled
- **THEN** system protection remains enabled

### Requirement: Partial outcomes persist
NoSleep SHALL persist the owned state actually retained after every completed power command, including a failed command.

#### Scenario: Display acquisition fails
- **WHEN** system protection succeeds and display acquisition fails
- **THEN** system protection remains enabled, display stays off, the error is shown and saved selections match that retained state

### Requirement: Restore valid combinations
Startup SHALL restore saved power selections through one serialized ready-state transition.

#### Scenario: Legacy display-only preference
- **WHEN** a previous configuration saved display on and system off
- **THEN** startup requests both protections after readiness succeeds

#### Scenario: Initial permission missing
- **WHEN** initial sleep permission is missing or still being checked
- **THEN** neither power protection can be enabled and the setup state remains visible

#### Scenario: Initial setup completes
- **WHEN** initial sleep permission becomes ready after setup
- **THEN** system protection enables and the previously saved display selection is retained

### Requirement: Honest common status
The common status SHALL flag a selected power protection whose actual state is unconfirmed.

#### Scenario: Display unconfirmed
- **WHEN** system protection is confirmed but selected display protection is absent
- **THEN** the status reports a problem even without a separate error string

### Requirement: Shared native routes
Window controls, application menus and status menus SHALL use the same dependency, readiness and busy guards.

#### Scenario: Duplicate or unready combined enable
- **WHEN** enable arrives during an operation or without required readiness
- **THEN** it starts no dependent power command or automatic-lock password prompt

#### Scenario: Native status menu validation
- **WHEN** AppKit updates the status menu while readiness is absent
- **THEN** the protected enable actions remain disabled just like the window controls

### Requirement: Independent lock policy
Power transitions SHALL preserve automatic-lock selection unless the user explicitly invokes a lock or combined action.

#### Scenario: Screen toggled
- **WHEN** screen or system protection changes
- **THEN** no automatic-lock policy change or password prompt occurs

#### Scenario: Combined password cancelled
- **WHEN** the user cancels password confirmation for a combined action
- **THEN** the existing rule preventing subsequent power changes remains in force

### Requirement: Isolated verification
Automated acceptance SHALL use separate state and fake power and policy dependencies.

#### Scenario: Native local E2E
- **WHEN** the selected local acceptance runs
- **THEN** no real power settings, installed application, user Keychain, networking or VM is changed


### Requirement: Bounded readiness and native quit routing
Power readiness SHALL isolate child stdin, drain bounded output while the child runs, limit execution and retry one failed startup read. Existing authorized controls SHALL become available after a transient read failure without administrative setup. Native quit requests SHALL let main-queue restoration callbacks run and serialize a fresh request until a cancelled termination unwinds.

#### Scenario: Existing permission after transient failure
- **WHEN** the first readiness read fails and the second confirms both exact permitted commands
- **THEN** both power controls become available without changing permissions

#### Scenario: Missing permission
- **WHEN** both readiness reads refuse access
- **THEN** both controls stay disabled and setup remains available without an automatic privileged action

#### Scenario: Cancel and immediate retry
- **WHEN** a password-confirmed quit is cancelled and another quit arrives while AppKit is unwinding
- **THEN** cancellation preserves guards and the fresh request executes without nested termination or duplicate cleanup
