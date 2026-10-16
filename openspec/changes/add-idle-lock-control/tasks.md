## 1. Mandatory feasibility gate

- [x] 1.1 Inspect current code/specs and record applicable constraints in design.md.
- [x] 1.2 Diagnose the isolated Apple restore failure and preserve exact restore/download receipts.
- [x] 1.3 Compile the separate manual probe, pass parser/refusal self-tests and verify its no-action native UI.
- [x] 1.3a Finish pinned isolated macOS27 image preparation and run autonomous protected/off/restored guest acceptance without host input devices; preserve generated receipts.
- [x] 1.3b Verify resource refusal, normal/error/timeout cleanup, independent controller-crash cleanup and final VM stopped/disk-retained evidence.
- [x] 1.4 Obtain a successful macOS 27 before/off/restored behavioral receipt; do not begin production implementation before it passes.

- [x] 1.5 Independently repeat acceptance with System Settings closed; the first complete untraced receipt passed with that process present.

## 2. Policy adapter and state ownership

- [x] 2.1 Implement an injected runner/store with bounded policy parsing and stdin-only passwords; pass normal, invalid-password, refusal and timeout native tests.
- [x] 2.2 Implement original-policy capture and retry/recovery journaling; pass boundary, interrupted-operation and external-change tests and document the persistence limit.

## 3. Native UI and termination

- [x] 3.1 Add the independent control, secure prompt, help and combined-action route; pass isolated native cancellation, retry, concurrency, layout and accessibility acceptance.
- [x] 3.2 Integrate restoration before termination cleanup; pass fake shutdown/restart/quit/logout and duplicate-request tests, preserving existing work and documenting cancellation behavior.

## 4. Integrated verification and delivery

- [x] 4.1 Declare exact test ownership and critical mutations; pass the repository quality command with the complete scoped diff.
- [x] 4.2 Select a minor version/build greater than current main and update its changelog/testing docs; pass release acceptance.
- [x] 4.3 Pass strict document validation, complete native regression and applicable universal package/DMG checks; record actual source/runtime identities and platform limits.
- [x] 4.4 Complete explicit manual lock preservation and restoration acceptance with a native receipt.
- [x] 4.5 Review the final scoped diff; do not commit, install, push or release without explicit authorization.

## 5. Current-main delivery authorized by user

- [ ] 5.1 Port onto current main while preserving compact UI and ARM-only CI; pass fresh focused, quality and complete native checks.
- [ ] 5.2 Record the retained, stopped local VM in agent-facing repository documentation without uploading its disk/state.
- [ ] 5.3 Create the authorized feature PR, confirm all actual checks pass on its final head, merge and confirm merged-head release success.
- [ ] 5.4 Download and checksum-verify the published DMG on this computer, report its actual path and retained VM status.
