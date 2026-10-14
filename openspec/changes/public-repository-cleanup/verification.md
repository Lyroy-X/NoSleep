# Verification: public-repository-cleanup

Base main: f56cd9c95dd2120f8c814fdcb07ee8951914a28f. Candidate: feature/public-repository-cleanup, version 3.5.1/build 18. Maintenance patch; supported application behavior and signing are unchanged.

- Focused checkout/documentation checks: 5 passed. Transplanting only the focused test into an isolated Git snapshot of the base reproduces assertion failures for retained lab files, personal paths and an absent README target, without setup/import errors.
- Full local quality command: passed; exact production ownership is scripts/test.sh. No Python production executable lines were changed. Existing 13 critical mutation fixtures passed, and their faulty copies failed by assertions.
- Full native command scripts/test.sh --local: passed on macOS 27.0.1 / Apple Silicon / Swift 6.4 / Python 3.12.14, including the diagnostics budget/RSS fixture, current native UI/termination checks and all five retained bridge contracts.
- Universal package: built and passed tests/dmg_acceptance.py --ci with version/build, both architectures, app signature, layout/background and exact candidate bytes. The first acceptance invocation passed content checks but failed ordinary detach with Resource busy; the owned mount had no open files and was normally detached. Acceptance of the same DMG then passed, including detach. This receipt does not supersede or hide the initial failed invocation.
- Preservation comparison: all 19 application-source, icon, bridge and workflow files exactly match base bytes. Deleted VM-operator tests exercised only the removed laboratory dependency closure, not supported app behavior.
- Current non-ignored checkout secret scan: Gitleaks 8.30.1 found no leaks. The working checkout containing unrelated changes was not modified.

Receipts remain in ignored build/public-cleanup-receipts, build/quality and build/ui-acceptance. The final PR head/checks identify the committed source and fresh remote CI result; local package checks alone are not a published release or Intel runtime receipt.

Not performed: installation, real power, first administrative setup, shutdown/restart, lid closure, downloaded-app Gatekeeper or Intel runtime manual acceptance. No installed app, Cisco, user Keychain, repository visibility/settings, licensing or Git history was changed. PR creation is authorized; merge and publication are not.
