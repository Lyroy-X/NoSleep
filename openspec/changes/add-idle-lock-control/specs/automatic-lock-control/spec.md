## Purpose

Allow a user to prevent automatic session locking while the display sleeps, independently of NoSleep's existing system and display protections.

## ADDED Requirements

### Requirement: macOS 27 behavior gate
Production implementation SHALL wait for observed macOS 27 behavior confirming automatic lock before the change, actual display sleep without automatic lock after disabling it, and automatic lock after restoring the original policy. Status text alone SHALL NOT pass this gate.

#### Scenario: Behavioral precondition missing
- **WHEN** no valid macOS 27 before/off/restored observation exists
- **THEN** the feature remains unimplemented and the missing evidence is reported

### Requirement: Independent native control
NoSleep SHALL provide “Не блокировать автоматически” with an accessible help control explaining system sleep, display sleep and session lock, including the effect of a locked session on GUI automation. Requested and confirmed state SHALL remain distinguishable.

#### Scenario: Help and independent operation
- **WHEN** a user reads help or changes automatic-lock protection
- **THEN** help explains the three behaviors and the existing independent power settings retain their meaning

### Requirement: Password-confirmed policy change
Policy changes SHALL occur as the current graphical user through an in-app secure password prompt. The password SHALL NOT be persisted, included in process arguments, logs, diagnostics or exports. Cancellation, invalid credentials and refusal SHALL retain the prior confirmed lock-control state.

#### Scenario: Correct password
- **WHEN** the user confirms a supported policy change with a valid password
- **THEN** the control changes only after the requested policy is confirmed

#### Scenario: Cancellation or invalid password
- **WHEN** the user cancels the prompt or macOS refuses the supplied credentials
- **THEN** no successful control transition is reported and the user can retry

#### Scenario: Timeout or overlapping requests
- **WHEN** a policy change times out or another request arrives while one is pending
- **THEN** duplicate changes are refused and the interface remains responsive with an explicit pending or error state

### Requirement: Restore captured policy
Before disabling auto-lock, NoSleep SHALL persist only the original policy and restoration ownership. Disabling its control or normal termination SHALL restore that exact policy with password confirmation when a change is needed. Cancellation or failed restoration SHALL keep restoration retryable and cancel termination.

#### Scenario: Restore a nonzero delay
- **WHEN** NoSleep disabled a policy with an original delay and the user later disables the control
- **THEN** that same delay is restored instead of an assumed immediate-lock default

#### Scenario: Termination cancelled
- **WHEN** restoration needed for a quit is cancelled or fails
- **THEN** NoSleep retains its guard and restoration journal and rejects termination

#### Scenario: App restarts after a crash
- **WHEN** a previous run left a pending restoration journal
- **THEN** NoSleep exposes the pending state and offers password-confirmed restoration without silently changing policy or discarding the journal

### Requirement: Preserve manual locking
Disabling automatic lock SHALL NOT implement automatic unlocking or prevent an explicitly requested manual lock. The app SHALL explain that a system policy change can outlive a process crash.

#### Scenario: User locks the Mac manually
- **WHEN** the user requests manual lock while automatic-lock prevention is enabled
- **THEN** the Mac locks and NoSleep does not unlock it

### Requirement: Isolated automated verification
Automated app tests SHALL use isolated state and fake policy/power dependencies. Real host power, session-lock and credential acceptance SHALL require explicit manual action and SHALL NOT change the installed NoSleep app merely to obtain a test result. An explicitly authorized throwaway macOS 27 VM MAY perform autonomous real guest acceptance with public fixture credentials, exact guest identity guards and no host input devices or clipboard attached.

#### Scenario: Native acceptance fixture
- **WHEN** the native automated suite exercises prompt cancellation, error, retry and termination
- **THEN** no real host policy, user Keychain or installed app is changed

#### Scenario: Other agents use the host during acceptance
- **WHEN** the user selects an autonomous isolated VM acceptance
- **THEN** the test operates only the exact owned guest, records sleep/wake/session evidence and restoration itself, rejects foreign guest results and requires no human timing or report

### Requirement: Bounded retained VM fixture
Autonomous acceptance SHALL limit its exact owned VM to two vCPUs, 4096 MiB, reduced priority and 600 seconds per generation. An independent supervisor SHALL stop it on controller loss, resource pressure or timeout. Cleanup SHALL confirm stopped status and retained disk. No other VM SHALL be stopped.

#### Scenario: Controller crashes during a test
- **WHEN** the test controller exits before normal cleanup
- **THEN** its independent supervisor stops and reaps only its own VM child, preserving the guest disk

#### Scenario: Test completes or fails
- **WHEN** autonomous acceptance ends with success or failure
- **THEN** terminal cleanup confirms the exact VM registry reports stopped and the disk remains available for future tests

#### Scenario: Host lacks resources
- **WHEN** memory headroom is below 20 percent, disk headroom is below 40 GiB or a thermal restriction is reported
- **THEN** the VM is not started or its owned running instance is stopped, and the test reports refusal instead of success

### Requirement: Offline ASIF fixture registration
The fixture adapter SHALL support pinned raw and ASIF macOS images using the existing verified cache without network access. ASIF SHALL retain its native format and be validated by the host. Registration SHALL preserve the immutable cache, refuse an existing guest and confirm the CPU/memory limits before publishing readiness.

#### Scenario: Cached ASIF image
- **WHEN** a supported host registers the already downloaded ASIF fixture
- **THEN** the adapter verifies its pinned metadata and disk layers, validates native ASIF information and creates a copy-on-write guest disk without conversion or download

#### Scenario: Invalid or repeated registration
- **WHEN** hashes, format, host support or resource limits are invalid, or the target already exists
- **THEN** registration refuses without overwriting the preserved source or claiming readiness
