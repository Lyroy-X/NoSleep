# NoSleep changes

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
