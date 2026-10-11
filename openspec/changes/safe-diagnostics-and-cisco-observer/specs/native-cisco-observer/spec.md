## ADDED Requirements

### Requirement: Native session recovery remains owned by Cisco
NoSleep SHALL reuse Cisco's existing native recovery behavior through observation only. It SHALL NOT submit credentials, run connect/disconnect commands, alter Cisco profiles, terminate native agents or automate Cisco UI. When a new session requires authentication, the user SHALL authenticate in Cisco.

#### Scenario: Existing native reconnect
- **WHEN** Cisco reports connecting or reconnecting
- **THEN** NoSleep displays that state without intervening in the native session

#### Scenario: Disconnected session
- **WHEN** Cisco reports disconnected
- **THEN** NoSleep reports it and offers a user-initiated button to open the signed Cisco GUI without submitting credentials

### Requirement: Bounded state-only observation
NoSleep SHALL query only the verified signed Cisco status client with fixed state-only arguments and EOF input, at most once per 60 seconds and one request at a time. It SHALL bound execution to six seconds and output to 16 KiB. Unknown results or failures SHALL pause observation, including across restart. Explicit off SHALL persist and cancel only an owned status process.

#### Scenario: Out of the box
- **WHEN** Cisco is installed and no observation preference exists
- **THEN** NoSleep enables status observation without requesting a password and reports the native profile policy conservatively

#### Scenario: Unknown, timeout or failure
- **WHEN** reading status fails or produces an unsupported response
- **THEN** NoSleep marks state unknown and pauses; it never attempts authentication and retains the pause after restart

#### Scenario: Offline, rapid switching and explicit off
- **WHEN** network is unavailable, toggles repeat rapidly or observation is off
- **THEN** NoSleep respects the status-query budget, performs no authentication and respects off after reopening

#### Scenario: Duplicate launch
- **WHEN** another NoSleep instance is already running
- **THEN** the new launch opens the existing instance without starting another watchdog or observer

#### Scenario: Real profile XML
- **WHEN** a profile uses namespace prefixes and nested AutoReconnectBehavior elements
- **THEN** NoSleep reads the direct AutoReconnect boolean without treating child text as its value and makes no profile changes
