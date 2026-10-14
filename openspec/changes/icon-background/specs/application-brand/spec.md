## ADDED Requirements

### Requirement: No secondary pale icon tile
The approved app icon SHALL have an opaque navy background that reaches the square source edges. macOS SHALL apply the final rounded mask without shrinking the artwork into a secondary pale tile.

#### Scenario: Modern system icon
- **WHEN** macOS 26+ returns the built application icon via NSWorkspace
- **THEN** the four outer mid-edge samples inside the system mask remain navy, not pale grey or white

#### Scenario: Reference preservation
- **WHEN** the source and ICNS are corrected
- **THEN** the previous padded source and system before/after previews remain in the repository
