## ADDED Requirements

### Requirement: Approved application identity
The application SHALL use concept 01 from the four-column moon reference sheet: an ivory crescent and amber spark on a navy rounded tile.

#### Scenario: App bundle
- **WHEN** NoSleep is built
- **THEN** the bundle icon includes the approved artwork at standard and Retina sizes

### Requirement: Menu bar identity
The menu bar SHALL use a monochrome template crescent-and-spark mark with the same silhouette, accessible name and 18-point size.

#### Scenario: Appearance and scaling
- **WHEN** the menu mark is drawn at standard and Retina scale
- **THEN** its crescent and spark remain separate visible components and the background is transparent

### Requirement: Design history and local update
The repository SHALL retain all presented reference sheets, approved source artwork and usage guidance. The local update SHALL preserve saved feature preferences and unrelated work.

#### Scenario: Versioned delivery
- **WHEN** the approved change is merged into main
- **THEN** semantic patch version and build number exceed the previous main and the local application uses that version
