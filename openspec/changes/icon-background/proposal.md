## Why
The user reported and rejected a pale rim around NoSleep in the Dock. The previous PNG had no white border, but macOS 27 normalized its padded, pre-rounded ICNS into a smaller icon on a pale system tile.

## What Changes
- Extend the approved navy background to all opaque corners; preserve the crescent and amber spark.
- Rebuild ICNS and let macOS apply its own rounded mask.
- Archive the previous approved source and system before/after previews.
- Add an actual NSWorkspace system-icon edge-colour regression and update source-format checks.
- Increment patch version to 3.4.2/build 13 above main 3.4.1/build 12.

## Scope
No runtime power, menu, diagnostics, termination, network or release-automation behavior changes. Earlier authorization to merge this identity and update the local app remains applicable.
