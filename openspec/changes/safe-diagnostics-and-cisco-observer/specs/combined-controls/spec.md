## ADDED Requirements

### Requirement: Contextual all-on and all-off
NoSleep SHALL show Включить всё when every owned feature is off, and Выключить всё when any owned feature is on. The control SHALL affect only NoSleep-owned features and preserve independent power/display toggles.

#### Scenario: Everything off
- **WHEN** all owned functions are off and the user activates the combined control
- **THEN** both protections and available observation become enabled and the action changes to Выключить всё

#### Scenario: Partial or full activation
- **WHEN** any owned feature is enabled and the user activates the combined control
- **THEN** owned features become disabled and the action changes to Включить всё

#### Scenario: Corporate VPN isolation
- **WHEN** the user operates power controls or exports support information
- **THEN** NoSleep sends no VPN authentication or connection command
