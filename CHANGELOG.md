# NoSleep changes

## [3.5.0]

- Redesign the native NoSleep window as a compact 440×430 utility with one grouped pair of independent protection switches.
- Add an overall status that distinguishes confirmed protection, applying commands, permission checking and failure; keep retry and first-run feedback visible.
- Correct the native Shift-Command-A declaration so the existing shortcut reaches its action.
- Keep the combined action under the controls and report export in the toolbar, preserving standard menu commands and close-to-background behavior.
- Keep the document width aligned with the actual viewport after native legacy/overlay scrollbar tiling.
- Verify status boundaries and isolated AppKit interactions/layout in light, dark and high-contrast appearances; record universal-package and regression evidence separately.

Real power, first administrative setup, shutdown/restart, lid closure and downloaded-app Gatekeeper behavior require explicitly authorized manual acceptance. Local Apple Silicon checks do not prove native Intel execution or a published GitHub release.

## [3.4.4]

- Wait for actual isolated UI completion with a bounded monotonic deadline on loaded CI runners; verify delayed and missing completions.

## [3.4.3]

- Build and publish a verified universal DMG after each update to main.
- Require a new agent-selected version and build number before merge.
- Add exact test evidence, changed Python coverage, critical mutations and full
  native regression checks to CI; preserve private visibility and current signing.
- Check DMG contents, signatures, both architectures and stored layout in CI
  without requiring Finder automation.

- Compile the isolated power-handoff probe for the native CI runner and assert its architecture before accepting Intel regression.
