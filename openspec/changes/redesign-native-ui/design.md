# Design

## Context

See proposal.md. The current production window is AppKit, with independent requested/actual fields in LiveState and a background GuardEngine. The operator selected compact concept 1, local E2E and no personal implementation review. The concrete solution was accepted on 2026-10-14.

## Goals / Non-Goals

**Goals:** implement the selected hierarchy using existing native control semantics; make compact and exceptional states usable; independently verify current source.

**Non-Goals:** change power/setup/export/termination logic; include uncommitted release or termination work in the UI PR; merge or publish a release.

## Decisions

- Keep AppKit and native NSWindow/NSSwitch/NSButton/menu APIs. The utility already uses these and requires no new dependency or web glass effect.
- Use an approximately 440×430 content window, semantic colors, SF Symbols and one grouped protection card. A scroll view handles setup/error content. The selected compact design replaces the large card and sidebar alternatives shown during intake.
- Add a small deterministic status presentation mapping. Give checking/applying/error states priority over a positive headline, and use confirmed actual state together with the app's request before describing active protection.
- Keep engine queue, one-second polling, command routing and permission gates unchanged. No performance improvement is claimed; use narrow isolated rendering/idle observations if available.
- Correct the existing Shift-Command-A native key equivalent to uppercase A. A private diagnostic proved lowercase a with a correct shifted event remains unmatched and uppercase A reaches the fake action; keep the intended shortcut and handlers unchanged. Run the full quality lane on macOS to execute native base-snapshot regression proof without bypassing any gate.
- Keep the combined action under the controls and diagnostics in the toolbar; retain all actions in menus. Preserve native window restoration, keyboard access and accessibility labels.
- Prepare an isolated feature branch, updated to verified remote main 385fa5e7cc90aae50e681e7486f30b8413b0407d after the release workflow landed. Do not stage or publish the original checkout's unrelated dirty files.
- Proposed version: 3.5.0/build 17, reflecting the compatible compact presentation capability and exceeding current main 3.4.5/build 16. Recompute if main moves.

## Risks / Trade-offs

- [First-run/error content exceeds compact height] → native scrolling, wrapping and focused minimum-size checks.
- [Headline accidentally reports intent as success] → state matrix tests and isolated assertion-based mutation of the confirmation condition.
- [Restored older window sizes] → preserve restoration, permit expansion and test both fresh and restored-size behavior.
- [Comparison base moved during implementation] → update the private feature branch to the exact new main SHA, preserve its release pipeline and rerun the complete quality/native/package gates.
- [Local ARM checks cannot prove hosted Intel runtime or real power behavior] → retain explicit manual/remote limitations.

## Verification

Focused state/layout tests, isolated local native E2E, current-main complete regression, release acceptance where available, universal DMG and package acceptance. Record exact source/config/runtime/command identities; an unavailable or failed gate is not replaced by a targeted success. Agent review occurs in this conversation; the operator selected no personal implementation review.

User follow-up: disable Intel CI completely in the shared workflow for all future PRs and main verification until explicitly re-enabled. Keep ARM quality/native/package checks and universal DMG cross-compilation.
