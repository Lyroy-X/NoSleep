## ADDED Requirements

### Requirement: Power-only application
NoSleep SHALL expose independent sleep and display protection and SHALL NOT observe or control VPN connections, open Cisco, read credentials, or present VPN settings.

#### Scenario: Native window and menus
- **WHEN** the user opens NoSleep
- **THEN** exactly two feature switches for sleep and display are present and no VPN or Cisco controls are present

#### Scenario: Combined action
- **WHEN** either power feature is requested and the user invokes the combined action
- **THEN** both power features are disabled
- **WHEN** neither is requested and the user invokes the combined action
- **THEN** both power features are enabled

### Requirement: Preserve bounded diagnostics and native controls
NoSleep SHALL retain diagnostics bounded to 200 MB/seven days, manual export, native utility window restoration/resizing, toolbar and standard menu actions. Export SHALL contain no VPN status, recovery or credential metadata.

#### Scenario: Support export
- **WHEN** the user saves a report
- **THEN** summary format 3 contains only app/system/power/storage facts and bounded sanitized events

#### Scenario: Missing power permission
- **WHEN** sleep-control permission is unavailable
- **THEN** sleep control is disabled, display control remains available and setup is visible

### Requirement: Isolated verification
Verification SHALL use separate build output and private UI fixture state without changing the installed application, actual power settings, credentials or network.

#### Scenario: Native UI E2E
- **WHEN** local UI acceptance executes
- **THEN** current production UI routes switches/menu/combined actions into a fail-closed in-memory power model and writes private evidence
