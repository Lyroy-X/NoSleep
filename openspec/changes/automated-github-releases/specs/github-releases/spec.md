## Purpose
Distribute exact, verified NoSleep versions through GitHub Releases and enforce
reproducible tests for new changes while retaining the complete native regression.

## ADDED Requirements

### Requirement: Agent-selected version before merge
Every update to main SHALL have a valid increasing semantic app version and integer build, selected by the implementing agent before merge. CI SHALL reject missing increases and SHALL NOT call a model or commit metadata.

#### Scenario: New compatible function or fix
- **WHEN** the agent prepares a compatible function or fix
- **THEN** it chooses minor or patch respectively, updates metadata/changelog/docs and provides tests

#### Scenario: Reused version
- **WHEN** main receives a version or build not exceeding its prior state
- **THEN** CI fails and no release is published

### Requirement: Exact-source verified package
Publication SHALL use only a successful complete CI run's universal DMG for the exact event SHA. CI SHALL test both native CPU architectures and verify mounted contents, app/version/signature, architecture slices and stored layout.

#### Scenario: Successful main update
- **WHEN** quality, native regression and package checks succeed for a main update
- **THEN** that run's package and checksum become a downloadable GitHub release for that SHA

#### Scenario: Any check fails
- **WHEN** a required CI check fails
- **THEN** publication does not execute and logs remain available

### Requirement: Retryable publication without overwrite
Publication SHALL verify uploaded assets before publishing a draft. It SHALL resume only matching drafts, retain completed published assets for the same SHA, reject conflicting tags, and SHALL NOT blindly promote an older rerun to Latest.

#### Scenario: Upload or publication response is lost
- **WHEN** an upload fails or the publication response is lost
- **THEN** retry resumes the matching draft or verifies the already published version without duplication

#### Scenario: Another source owns the version
- **WHEN** the version tag resolves to another SHA
- **THEN** publication fails without modifying that release or tag

### Requirement: Evidence-backed new-change CI
New production changes SHALL have exact changed-test ownership, meaningful changelog/docs and focused green tests. Changed Python executable lines and branches SHALL be fully covered. Regression proof SHALL reject setup failures; critical guard mutations SHALL fail assertions after a green copied baseline.

#### Scenario: Missing or unrelated tests
- **WHEN** an evidence declaration misses a production path or names unchanged/missing tests
- **THEN** quality fails before packaging or publication

#### Scenario: Missing measurement or surviving fault
- **WHEN** changed Python code is unmeasured/uncovered/excluded or a critical mutation survives
- **THEN** quality fails with the affected input and retained evidence

### Requirement: Isolated tests and authority boundaries
CI SHALL preserve private visibility and current signing, use read-only build permissions and restrict write credentials to main publication. Automated tests SHALL NOT control real power, network, user credentials or an installed app. External and manual acceptance SHALL be reported separately.

#### Scenario: Local verification
- **WHEN** local checks run
- **THEN** they use isolated bundles/state and simulated API calls, and do not claim remote publication or Intel execution
