# Verification

The candidate is NoSleep 4.2.0, build 23, based on published main `00830eb3da56d03f46f8dd043d20233d82c49fae`.

The full native regression and universal DMG acceptance passed on macOS 27.0.1 arm64. The regression test transplanted onto main failed at the watchdog behavior assertion. The corrected engine passed, and the ten isolated faulty copies failed at assertions. See `build/lid-independent-release/native.log`, `native-red-proof.log` and `dmg.log` in the same directory.

| Scenario | Implementation | Check |
| --- | --- | --- |
| A separate switch in AppKit, with matching menu state and independent controls | `MenuApp`, `applicationMenu` | `lidSleepAcceptance` and native layout checks |
| Combined actions and unchanged idle and display timer semantics | `GuardEngine` and `Protection` | `lidProtectionTests`, timer engine and native lifecycle fixtures |
| Persistence, migration, ownership and recovery from refusal | `LidProtection` | `lidProtectionTests` and the unowned-override mutation |
| No transient warning after successful recovery | `GuardEngine` | Native red proof on main and the two isolated watchdog mutations |
| Version, signature and both slices | `Resources/Info.plist` and existing DMG scripts | Release acceptance and universal DMG verification |

All automated tests use simulated power. Physical lid closure, real power, first administrative setup, shutdown/restart, downloaded-app Gatekeeper and native Intel execution require separate acceptance. The packaging check covers both executable architectures.
