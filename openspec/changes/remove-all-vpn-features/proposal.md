## Why
The user explicitly requests removal of every VPN feature, including Cisco observation, while retaining unrelated NoSleep changes. Prior authentication drafts are not a required capability anymore.

## What Changes
- Remove all VPN observation, connection, credential, settings and command handling from the application and its exports.
- Retain independent sleep/display protection, the native utility layout, toolbar, menus, diagnostics bounded to 200 MB, and isolated builds/packaging.
- Update focused safety and native UI acceptance tests; exclude historical VPN scenarios from the runner.
- Do not install, commit, publish, control Cisco, or delete existing user credentials/preferences.

## Capabilities
### New Capabilities
- `power-only-utility`: NoSleep exposes only power protection and support diagnostics.
### Modified Capabilities
None. Existing specs under changes are historical; this change supersedes their VPN requirements for the current application.

## Impact
Application source, diagnostic summary format 3, focused tests, README and current testing documentation. Power-handoff VM tooling remains historical infrastructure outside the production application.
