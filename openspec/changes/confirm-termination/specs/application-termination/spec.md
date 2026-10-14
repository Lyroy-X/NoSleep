## Purpose

Preserve NoSleep and its power protection when the user cancels a Mac shutdown or restart, with an explicit confirmation before cleanup.

## ADDED Requirements

### Requirement: Confirm system shutdown and restart
NoSleep SHALL ask for confirmation before releasing protection when the current quit Apple Event identifies shutdown or restart. The default and Escape actions SHALL cancel termination. Ordinary quit and logout SHALL retain their existing behavior without a prompt.

#### Scenario: Shutdown cancelled
- **WHEN** a system shutdown quit request arrives and the user chooses Cancel
- **THEN** NoSleep rejects termination and keeps protection and its background guard running

#### Scenario: Restart cancelled
- **WHEN** a system restart quit request arrives and the user chooses Cancel
- **THEN** NoSleep rejects termination and keeps protection and its background guard running

#### Scenario: Confirmation pending
- **WHEN** the shutdown or restart confirmation remains open
- **THEN** NoSleep keeps protection running and rejects concurrent termination requests

#### Scenario: Explicit confirmation
- **WHEN** the user confirms a shutdown or restart quit request
- **THEN** NoSleep releases protection and permits termination only after successful cleanup

#### Scenario: Ordinary quit or logout
- **WHEN** the quit request is ordinary quit, logout, unknown or missing a system reason
- **THEN** NoSleep performs existing cleanup and allows termination without confirmation

### Requirement: Retry after cancellation or cleanup failure
NoSleep SHALL evaluate each new quit request independently. If cleanup fails, it SHALL cancel termination, keep the guard retryable, show its window and display an error.

#### Scenario: New request after cancellation
- **WHEN** the user cancels one system quit request and a later shutdown or restart is requested
- **THEN** NoSleep asks again with no approval carried over from the earlier request

#### Scenario: Cleanup failure
- **WHEN** confirmed termination cannot restore normal sleep
- **THEN** NoSleep rejects termination, retains protection and resumes its background guard with a visible error

### Requirement: Isolated acceptance
Automated acceptance SHALL exercise the current UI and real termination event parsing with private fixture power and state. It SHALL NOT request host shutdown, restart, logout or installed-app termination.

#### Scenario: Local native acceptance
- **WHEN** termination acceptance runs
- **THEN** production termination code handles fixture quit Apple Events and native dialog choices without real power or host lifecycle actions
