# Verification

Base: d360da035b884b9241455eeccafdd5d618144892 (main 3.4.1/12). OpenSpec selection: on. Candidate: 3.4.2/13, a patch for icon packaging only.

- Before: source PNG has transparent corners and no white frame; the live system icon is reduced onto a pale outer tile. The new native background test fails against that prior application as expected.
- After: source is opaque full-bleed RGB, with the crescent and amber spark retained. A private fixture and the signed universal candidate both pass the NSWorkspace system-icon edge test on macOS 27.0.1. Native before/after images are archived in docs/brand/previews.
- Three resource checks pass: high-resolution square RGB source, all ten normal/Retina ICNS sizes, and exact signed bundle resource/version.
- The universal candidate --self-test and safety contract pass; both CPU architectures are present. No production Swift logic was changed.
- The required current-working-copy release acceptance suite passes 28/28 in offline fixtures; its pre-existing release code is not part of this commit.
- A manual system-icon check initially received a relative app path; NSWorkspace returned an unknown-file document icon. The checker now standardizes paths and refuses missing bundles. The corrected candidate check passed.
- git diff --check and asset checksum verification pass.

Not run: Intel hardware runtime, macOS 14–25 icon appearance, new DMG, repeated full UI/resource-budget suite. The existing tested runtime implementation is unchanged. No new Xcode/Icon Composer dependency is introduced.

The user previously authorized main integration and local replacement for this same identity task. Their final post-install receipt is retained in the original repository build/brand-border-fix.
