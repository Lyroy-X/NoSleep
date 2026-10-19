# Design

## Context
See proposal.md. The current dirty main checkout contains unrelated automatic-lock, termination, UI and release work. Power ownership is in Protection; GuardEngine serializes commands and persistence; MenuApp supplies readiness and password orchestration.

## Goals / Non-Goals
Implement the selected dependency once in the real power model, with all entry points respecting it. Keep ordinary native controls, existing password/restoration boundaries and the one-second watchdog. No new system API, background timer, host acceptance, VM use, commit or external delivery.

## Decisions
- Acquire system protection before display. Keep successfully acquired system protection if display acquisition fails; preserve both guards if system-off is refused. Display-off does not undo system protection.
- Persist retained owned flags after both success and failure, without hiding the action error. Test partial success separately from refusal and retry.
- Treat any wanted-but-unconfirmed power flag as an overall problem, even when another selected protection succeeds.
- Normalize old display-only saved values to both-on. Gate startup once on readiness and restore through the same busy path; do not run a separate unsynchronized display request.
- Refuse sleep/display/all enable before readiness; disabled controls and direct commands share the guard. Refuse combined enable before lock readiness to avoid an unnecessary password request. Allow retry/off paths for retained active state.
- Keep the existing lock-first combined workflow and password cancellation guard. A successful lock change followed by a power refusal remains explicitly partial and retryable; do not silently request a second password for rollback.
- Add model regression tests using existing APIs, so their transplant into base main compiles and fails by assertion. Use isolated native UI routes and safety mutants for readiness/refusal. Do not use fixture-only model success as proof of real power behavior.
- Approved UI supplement: transient NSPopover anchored to the help button, three short use cases and a separate restoration-details action. Use the system popover animation; InterfaceMotion animates NSSwitch state and changed status text for 0.2s via NSAnimationContext. Commit text/state immediately, suppress hidden/reduced-motion/unchanged transitions and introduce no timer. Existing alert semantics stay in the details action.
- Native fixture diagnosis exposed a foreground dependency in popover animation: recorded AppKit running=true/active=false with close never settling. Normal AppKit lifecycle/event dispatch and LaunchServices alone did not establish activation. The product now enables popover animation only in a visible active window, recalculating on close; background closure needs no focus. Native acceptance uses a direct child process, main RunLoop waits, real NSAlert.runModal, separate preferences suite and owned-process timeout cleanup. The experimental NSApplication.run/LaunchServices/event-pump changes were reverted. Synthetic keyboard delivery still requires AppKit activation; a timeout remains a failed E2E. No external window or installed app is activated to satisfy the check.

## Risks / Trade-offs
- The former independent display-only capability is removed: initial setup is now necessary for display protection. Document the behavior and prepare 4.0.0/build 16.
- A partial failure can retain useful system protection. Show the failure and persist retained ownership rather than falsely reporting an all-or-nothing result.
- Actual power, lid closure, admin setup, lock policy, shutdown/restart and downloaded Gatekeeper behavior remain explicit manual acceptance. Local ARM native tests and universal assembly are not Intel runtime or remote CI proof.

## Verification
Current baseline core suite passed. Five named candidate assertions are recorded in build/control-dependencies/before-receipt.json. Run focused model, critical mutation, full quality, complete local native regression and DMG checks after implementation; compare the same initial cases. User selected local E2E and no personal review.

First full quality failed at base-proof classification because a Swift assert crashed without the standard self-test ERROR channel. The test now throws its named behavioral assertion through that channel; targeted archive proof passed without changing the gate. A copied full UI fixture timed out once before mutation. A diagnostic full UI rerun passed; readiness mutants now execute only their targeted UI path, while mandatory full E2E remains separate. Preserve both limitations in receipts rather than treating them as product behavior evidence.


## Reopened local acceptance: icon and live readiness
The user rejected the missing status icon and requested motion specifically on it, then reported both power controls unavailable and explicitly requested autonomous repair and local installation. Preserve prior no-personal-review/local-E2E/no-memory/no-Git choices; this direct instruction approves the concrete corrective scope without another questionnaire.

Confirmed installed 3.6.0 had a summary SF Symbol plus per-row symbols in the retained automatic-lock-release source. Prepared 4.0.0 omitted that presentation. Restore the summary and row symbols while keeping the approved display/sleep dependency. Animate the status icon on meaningful changes using finite native transitions, with no added polling/idle loop and reduced-motion/hidden suppression.

The host already grants both exact pmset operations NOPASSWD. Live 4.0.0 falsely reports no readiness and leaves sudo -n -l children running. Reproduce the production process runner using safe fake commands, then use bounded concurrent output reading. Verify the actual GUI launch/readiness path with fake dependencies rather than assuming model-only E2E covers it. A real read-only sudo probe is permitted; real setup/security prompts must not be accepted automatically. Preserve lock journal and current host settings during installation.

Prepare patch 4.0.1/build20: restores omitted UI/motion and repairs permission readiness, exceeding installed 3.6.0/build19 as well as main. No publication is authorized. Add focused normal/failure/boundary/retry/large-output tests and a critical faulty runner copy. Complete quality/native/package checks before replacing the app.
