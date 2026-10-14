# Public repository cleanup

User selection: on. The user selected removal of the retired VPN laboratory, removal of personal workstation paths, and a README focused on convenient release installation. The user explicitly retained Git history and deferred licensing, community documents and repository protection/settings.

Base: main f56cd9c95dd2120f8c814fdcb07ee8951914a28f. Prepare feature/public-repository-cleanup and a pull request for review; do not merge or change visibility.

Remove infra/vpn-lab and the three power-handoff VM modules that import or require it. Retain the standalone bridge and its five isolated contracts. Update current documentation and install/update/removal/checksum instructions. Preserve application source, icons, current signing, release workflows and live user state.

Use patch 3.5.1/build 18 because this is maintenance with no change to supported app behavior. Add focused checkout/documentation tests to the existing runner, run complete quality/native/package verification, and record manual/platform limitations.
