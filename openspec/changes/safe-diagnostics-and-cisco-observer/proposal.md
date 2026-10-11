## Why
The reverted VPN implementation retried unknown connection failures and activated recovery immediately after saving credentials before real Cisco authentication acceptance. Restoring a safe useful application requires separating support logging and power controls from Cisco authentication.

## What Changes
- Restore previously approved bounded, typed, user-exported diagnostics with no credentials or arbitrary command output.
- Restore the contextual all-on/all-off control for owned features.
- Reuse native Cisco recovery and provide a bounded state-only observer. The user explicitly authorized this safe mechanism; no stored-password or connection-command automation is reinstated.

## Capabilities
### New Capabilities
- `support-diagnostics`: bounded logs and private manual support export.
- `combined-controls`: contextual all-on/all-off owned-feature control.
- `native-cisco-observer`: bounded observation of the existing native session, policy and explicit manual GUI opening.
### Modified Capabilities
None.

## Impact
Local NoSleep application, tests, README and DMG. No Cisco profile changes, agent restart, password submissions, network outage tests, external publication or push.
