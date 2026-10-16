# Proposal

## Why
System sleep prevention does not prevent session auto-lock when the display sleeps. A locked session can pause GUI automation even while background work continues. The user approved a third control with a fresh password for each policy change.

## What Changes
- Add “Не блокировать автоматически” and help text distinguishing system sleep, display sleep and session lock.
- Run screen-lock changes as the current graphical user with a secure in-app password prompt; never persist the password.
- Capture the original lock delay before disabling it and restore that exact value on disable and normal termination. Cancellation or refusal keeps the prior confirmed control state.
- Explain that the setting is system-wide and can survive an app crash.
- Gate production implementation on a real macOS 27 before/off/restored observation, rather than command success or status output alone.

## Capabilities

### New Capabilities
- `automatic-lock-control`: Password-confirmed automatic session-lock control with state restoration, error handling and native UI.

### Modified Capabilities
None in the root capability inventory. This approved change supersedes the exact-two-switch presentation in the historical `remove-all-vpn-features` change and the prompt-free ordinary quit requirement only when an owned lock-policy restoration is pending. It does not reintroduce VPN features.

## Impact
Native application lock-policy adapter, secure prompt, UI, termination integration, focused native tests, evidence, version/changelog and user documentation. No installed-app replacement, host credential storage, Git mutation or release is authorized.
