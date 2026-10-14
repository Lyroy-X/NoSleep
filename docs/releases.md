# GitHub releases

Every update to main runs the complete reusable CI workflow. A successful run
publishes `vMAJOR.MINOR.PATCH` for its exact SHA with `NoSleep-universal.dmg` and
`SHA256SUMS.txt`. Download from the repository's latest GitHub Release. Access
follows repository visibility; NoSleep remains private until its owner changes it.

The implementing agent chooses SemVer before merge under `AGENTS.md`, updates
`Resources/Info.plist` and adds meaningful notes for that version to `CHANGELOG.md`.
CI refuses a non-increasing version/build or a malformed version. It never calls
a model or makes a version-update commit. A push containing several commits
produces one release for its final SHA. Direct pushes have the same requirements.

Build/test/package jobs have read permissions. Only publication receives the
ephemeral `GITHUB_TOKEN` with `contents: write`. No personal token, signing key or
model key is added. Existing ad-hoc signing stays in place; macOS may require
Open Anyway when opening a downloaded copy.

Release runs queue without cancelling earlier work (`queue: max`, at most 100
pending runs). Exceeding GitHub's queue limit cancels additional runs; inspect
Actions and retry them. A tag already pointing to another SHA is an error.
GitHub selects Latest using its legacy semantic-version/date policy rather than
blindly marking an older rerun latest.

Publication creates a draft, uploads and verifies both assets by GitHub's SHA-256
and size, then publishes it. On failure, rerun the failed workflow from Actions:
the matching draft is resumed. Rebuilding a DMG may change container timestamps;
the first completed release for that SHA is retained and verified by its original
checksum receipt. Published assets and tags are never replaced. An incomplete or
unmanaged existing release fails with an explanation instead of being overwritten.

Local checks verify packaging and simulated API behavior. The first real main
run and authenticated download verify external publication. Workflow files must
first reach main through an explicitly authorized commit/push/merge; editing them
locally does not activate GitHub Actions.
