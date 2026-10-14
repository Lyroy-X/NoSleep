# NoSleep changes

## [3.4.4]

- Ask before closing NoSleep during Mac shutdown or restart; cancellation retains
  sleep/display protection. Ordinary quit and logout keep their existing behavior.
- Keep shutdown cleanup retryable and reveal errors if normal sleep cannot be restored.
- Run native old/new bug proofs in both macOS CI lanes, preserving Ubuntu quality checks.

## [3.4.3]

- Build and publish a verified universal DMG after each update to main.
- Require a new agent-selected version and build number before merge.
- Add exact test evidence, changed Python coverage, critical mutations and full
  native regression checks to CI; preserve private visibility and current signing.
- Check DMG contents, signatures, both architectures and stored layout in CI
  without requiring Finder automation.

- Compile the isolated power-handoff probe for the native CI runner and assert its architecture before accepting Intel regression.
