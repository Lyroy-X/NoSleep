## Purpose
Help people choose NoSleep's protection combinations using short scenarios and native transitions without interrupting their work or delaying confirmed state.

## ADDED Requirements

### Requirement: Short contextual guidance
The help control SHALL show three short use cases with their required protection selections in a compact nonmodal card.

#### Scenario: Person opens help
- **WHEN** the help button is activated
- **THEN** the card explains downloads/calculations, presentations/reading and GUI automation while the main controls remain available

#### Scenario: Person opens help again
- **WHEN** the same help command is activated with the card open
- **THEN** it closes the existing card without changing protection

### Requirement: Restoration remains discoverable
The card SHALL retain a separate action for original-policy restoration details and disclose password-confirmed policy changes and manual locking.

#### Scenario: Person requests details
- **WHEN** restoration details are requested
- **THEN** the card closes and help explains restoration, cancellation and crash persistence

### Requirement: Native state transitions
Visible switch and changed-status updates SHALL use short native transitions while committing model and accessible state immediately.

#### Scenario: Dependent switches change
- **WHEN** display protection enables system protection
- **THEN** both control states update immediately and animate toward their confirmed values

#### Scenario: Rapid reversal
- **WHEN** a person reverses a recent action
- **THEN** the latest confirmed state wins and status appearance returns to full opacity

### Requirement: Motion follows accessibility and visibility
NoSleep SHALL suppress added motion for Reduce Motion, hidden windows and unchanged state.

#### Scenario: Reduced motion or hidden window
- **WHEN** Reduce Motion is active or the main window is hidden
- **THEN** state and text update directly without the added transitions

#### Scenario: Unchanged observation
- **WHEN** the watchdog delivers the same state
- **THEN** it does not restart animations or add polling

#### Scenario: Help in an inactive window
- **WHEN** the application is inactive while help is opened or closed
- **THEN** the card uses no transition and closes without requiring foreground focus

### Requirement: Native visual acceptance
Local acceptance SHALL inspect light/dark guidance and the dependent selections with fake power and policy.

#### Scenario: Isolated rendering
- **WHEN** UI acceptance captures the states
- **THEN** it records real rendered native views and source identities without changing real settings or claiming an FPS or idle-energy measurement


### Requirement: Retained status icon and finite motion
The main window SHALL retain its status symbol, confirmed title/detail and per-control symbols from the previously installed UI. Meaningful status changes SHALL animate the icon without restarting motion on unchanged watchdog updates.

#### Scenario: Confirmed state changes
- **WHEN** an operation changes the confirmed status
- **THEN** the summary symbol and accessible text reflect the new state immediately and a finite native transition settles to the final image

#### Scenario: Reduced motion and repeated status
- **WHEN** Reduce Motion is enabled, the window is hidden, or status is unchanged
- **THEN** no added icon animation is started and stale motion is removed where necessary
