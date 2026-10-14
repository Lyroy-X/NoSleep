## Change and compatibility

Describe the outcome and why the chosen SemVer bump fits the change.

## Verification

- [ ] Version/build increased; exact-version changelog and documentation updated.
- [ ] Focused positive, failure, boundary and retry tests cover changed behavior.
- [ ] Changed `tests/evidence/*.json` exactly owns the complete production diff.
- [ ] Bug tests fail on the isolated base for behavior, then pass on this revision.
- [ ] Changed Python lines/branches are covered; critical guards have a mutation.
- [ ] Full quality, native regression and universal DMG checks passed.
- [ ] Manual scenarios and unverified platform/external behavior are stated honestly.

This checklist does not replace the CI evidence or authorize publication.
