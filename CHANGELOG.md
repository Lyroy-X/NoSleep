# NoSleep changes

## [3.5.1]

- Remove the retired VPN laboratory and its dependent VM handoff runner, retaining the standalone power bridge and its isolated contracts.
- Remove personal workstation paths from current project documentation.
- Put release installation, checksum verification, first setup, updates and removal first in the README; remove commands for an absent signing test.
- Add focused repository cleanup and documentation checks to the existing regression runner.

Application sources and icons are unchanged. Real power, first administrative setup, shutdown/restart, lid closure and downloaded-app Gatekeeper behavior still require explicitly authorized manual acceptance; this maintenance update adds no Intel runtime acceptance.

## [3.5.0]

- Temporarily disable Intel CI execution repository-wide for future PRs and main release verification; retain ARM gates and universal DMG cross-compilation.

- Redesign the native NoSleep window as a compact 440×430 utility with one grouped pair of independent protection switches.
- Add an overall status that distinguishes confirmed protection, applying commands, permission checking and failure; keep retry and first-run feedback visible.
- Correct the native Shift-Command-A declaration so the existing shortcut reaches its action.
- Keep the combined action under the controls and report export in the toolbar, preserving standard menu commands and close-to-background behavior.
- Keep the document width aligned with the actual viewport after native legacy/overlay scrollbar tiling.
- Verify status boundaries and isolated AppKit interactions/layout in light, dark and high-contrast appearances; record universal-package and regression evidence separately.

Real power, first administrative setup, shutdown/restart, lid closure and downloaded-app Gatekeeper behavior require explicitly authorized manual acceptance. Local Apple Silicon checks do not prove native Intel execution or a published GitHub release.

## [3.4.5]

- Ask before closing NoSleep during Mac shutdown or restart; cancellation retains
  sleep/display protection and failed cleanup remains retryable.
- Run native old/new bug proofs in macOS CI lanes, with safe Enter/Escape defaults
  and a critical confirmation-bypass mutation.
- Avoid repeating compiler-based regression checks inside the bounded UI fixture;
  keep them in the complete native suite and retain every dialog assertion.

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
