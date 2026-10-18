# NoSleep changes

## [4.1.0]

- Add independent sleep/display duration popovers with presets, custom hours/minutes, remaining time and explicit baseline-return text.
- Remember five recent unique custom durations per feature, with accessible removal crosses; removal does not interrupt an active timer. Failed activation does not save a choice.
- Reconcile continuous deadlines on the existing power queue, preserving the display prerequisite, manual commands, refusal/retry and original launch preferences. Interrupted temporary sessions restore their baseline at the next ready launch instead of restarting a full timer.
- Identify duration actions with the native timer symbol and a clear label; retain the icon beside running countdowns.
- Keep timer-row switches aligned across regular, small and mini native AppKit metrics on supported macOS versions.
- Keep automatic-lock manual under its existing fresh-password contract. Add isolated engine, history, native popover and critical mutation tests.
- Use a compatible minor bump from the prepared 4.0.1 interface; build 21 exceeds prepared build 20 and current main. Existing breaking dependency changes remain represented by major version 4. No installation or publication is implied.

## [4.0.1]

- Restore the status icon, confirmed headline and per-control symbols omitted from the local 4.0.0 build.
- Animate meaningful status-symbol changes with finite native SF Symbol transitions; honor Reduce Motion, hidden windows and unchanged state.
- Drain power-command output while waiting with bounded time and bytes; recognize existing permissions instead of leaving controls disabled after a blocked child.
- Route quit outside the main-dispatch notification callback so asynchronous restoration can deliver its password dialog. Serialize a fresh request until a cancelled AppKit termination unwinds.
- Patch corrective behavior; build 20 exceeds the locally installed build 19 and all prior prepared builds. Local installation is requested; no publication is implied.

## [4.0.0]

- Make display protection acquire confirmed system sleep protection. Turning sleep
  protection off turns both off; turning display protection off retains sleep protection.
- Require initial power setup before enabling either protection, including direct commands.
  Normalize legacy display-only saved preferences during serialized startup.
- Retain saved display selection after initial power setup and keep status-menu
  availability under the same explicit readiness guards as the window.
- Attempt complete power cleanup on every diagnostic display-probe exit and
  report refused cleanup; verify the actual CLI branch with fake power and retry.
- Persist retained protection after partial failures and flag every selected but
  unconfirmed protection in the common status; preserve refusal and retry behavior.
- Add exhaustive transition, isolated native UI and critical mutation checks.
- Replace the long modal help with a small contextual card for downloads,
  presentations and GUI automation; keep restoration details available separately.
- Animate switches and changed status text using native 0.2-second transitions;
  honor Reduce Motion and avoid animation for hidden windows or unchanged state.
- Close contextual help without animation when the app is inactive, avoiding a
  dependency on taking foreground focus; run native acceptance in a real AppKit lifecycle.
- Use a major bump because independent display-only operation is removed. Build 16
  exceeds main's build 13 and the pre-existing prepared build 15. This includes the
  compatible automatic-lock, termination and release work already in the checkout.

## [3.6.0]

- Add independent automatic-lock control inside the compact native UI, with a secure password prompt for each required policy change.
- Save the original system delay before changing it and restore it on disable and normal quit; cancellation/refusal preserves confirmed state and remains retryable.
- Keep interrupted-run recovery, combined-action serialization and existing shutdown/restart confirmation. Passwords are not saved.
- Document the retained, stopped local macOS 27 ASIF fixture, resource limits, reuse rules and real idle/manual-lock/controller-crash evidence without committing its disk or raw state.
- Add focused native outcome tests and five assertion-based safety mutations. Version 3.6.0 is a compatible new capability; build 19 exceeds main build 18.

Local VM acceptance proves ordinary wake without a password and manual-lock preservation. Continuous Computer-plugin operation while the display remains asleep, Intel runtime, host lid/shutdown, first admin setup and downloaded-app Gatekeeper need separate acceptance.

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
