# Design

## Context

HEAD: 0beea41c337a3e773cfd6eec76d3e35f213a2b7f; the working tree already contains unrelated power-only changes. MenuApp currently shuts down GuardEngine immediately for every applicationShouldTerminate callback. Baseline copies/digests are in .taskflow/confirm-termination.

## Goals / Non-Goals

Handle shutdown/restart confirmation at the single existing termination delegate boundary. Keep ordinary menu, Dock, command and keyboard quit behavior. Do not alter real power, installed binaries, networking or global preferences during acceptance.

## Decisions

- Parse the current core quit Apple Event, validating event class/id before reading kAEQuitReason. Read the reason attribute and parameter to accommodate descriptors; recognise shutdown/restart (including their dialog variants). Never cache the event or approval. Logout and unknown values use existing cleanup.
- Use a native synchronous NSAlert with Cancel first/default and Escape assigned to Cancel. The background GuardEngine queue continues while the modal UI is active. A local reentrancy guard rejects overlapping requests before cleanup. An asynchronous sheet/terminateLater would add reply lifecycle state without benefit for this bounded confirmation.
- Keep cleanup in GuardEngine.shutdownNow, logging successful shutdown only after cleanup succeeds. Show the existing app window on cleanup failure.
- Test parsing independently, test actual GuardEngine failure recovery using FakePower, and extend the existing extracted-production UI harness. Model shutdown only with explicit fixture permission; count cleanup and shutdown diagnostic calls. Exercise actual native buttons without sending a host shutdown event.

## Risks / Trade-offs

- Forced termination and system requests without a shutdown/restart reason cannot be distinguished by this contract; they do not produce confirmation. Validate reasons against installed Apple SDK; actual OS shutdown remains a separate manual scenario.
- Confirmation can delay shutdown; Cancel intentionally aborts NoSleep termination.
- If another app cancels shutdown after the user has already confirmed NoSleep exit, NoSleep has permission to exit; this patch does not automatically relaunch it.
- Existing working changes must survive: compare task diff to a frozen starting copy, not only HEAD.

## Migration Plan

Build a separate candidate and run isolated checks. No install, Git mutation or publication is requested. The OpenSpec change remains active.

## Release integration

The operator explicitly requested a patch bump, universal DMG, release/DMG checks, commit, push and PR, after waiting for completed automated release work. The dependency chat completed; its reviewed changes were imported into an isolated feature/confirm-system-termination checkout from ffcd093827c158a5b95c29658dac9dca94a6ef1f. Unfinished redesign-native-ui remains outside scope.

Version 3.4.5/build16 follows the completed 3.4.3/build14 automation candidate and exceeds actual main 3.4.2/build13. Both the fix and release/CI maintenance use a patch bump.

The regression test dispatches a quit Apple Event through NSAppleEventManager in its own test process. Its handler calls the unchanged public delegate API, so the same fixture compiles on the old revision. Old code permits termination and cleans up; fixed code cancels and retains both protections. A copied faulty confirmation guard must fail the same assertion. It links no real power, Keychain or accessibility actions.

Quality runs on Ubuntu and can validate ownership, Python coverage and workflows, but cannot execute AppKit. It explicitly defers native red-green proofs; both macOS lanes check out full history, run the native proof CLI, then complete regression. Packaging still depends on quality and both native lanes. Targeted runner/workflow tests and a critical deferral mutation prevent silently routing native proofs to Ubuntu.

Final integration: automation was merged into main during verification. The candidate was rebased on a5589e08f11e7394b42db7b7ec7a5981822a415b; incoming automation/Intel contracts and changelog history are retained. Existing application/package input hashes match the verified DMG. Quality and full native checks are refreshed on this base; release/DMG metadata will bind to the final commit.
