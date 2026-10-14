## ADDED Requirements

### Requirement: Retired lab removal
The current checkout SHALL exclude the retired VPN laboratory and its dependent VM operators while preserving the standalone power bridge.

#### Scenario: Complete regression without old VM tools
- **WHEN** the full regression suite runs
- **THEN** it runs all retained bridge contracts and does not import deleted VM transport modules

### Requirement: Anonymous current documentation
Current project files SHALL contain no personal workstation account paths. Historical Git commits SHALL remain unchanged.

#### Scenario: Personal path detection
- **WHEN** a personal workstation path is present in current project source or documentation
- **THEN** the focused checkout check fails

### Requirement: Release-first installation documentation
README SHALL document release download, application installation, Gatekeeper, first administrative setup, checksum validation, update downtime and removal. Documented local links and Python test paths SHALL exist.

#### Scenario: Missing referenced local file
- **WHEN** a documented local target is absent
- **THEN** the focused documentation check fails, and succeeds again after the target is restored

### Requirement: Preserve supported application behavior
Application sources, icons and signing/release workflows SHALL remain unchanged in this maintenance change. Real-power, first setup, shutdown/restart, lid and Gatekeeper manual acceptance and Intel runtime limitations SHALL remain explicit.

#### Scenario: Package validation
- **WHEN** the candidate is packaged
- **THEN** the universal DMG contains the expected application, both architectures and the incremented patch version/build
