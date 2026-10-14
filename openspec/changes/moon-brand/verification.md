# Verification

Base: `facc0abcf3175958fc6e615d1438824aa18d566a` (origin/main). Candidate: patch **3.4.1**, build **12**. OpenSpec selection: on. Work was isolated from pre-existing termination and release-automation edits.

Passed:
- `./scripts/test.sh --core`: 6 build-safety tests, 18 historical handoff contracts, 3 helper contracts, power/diagnostics/UI self-tests and the new menu geometry test. These contracts do not exercise real VPN operations.
- `python3 tests/brand_assets_acceptance.py`: three checks, including source alpha, all ten standard/Retina ICNS representations and exact signed bundle resource/version identity.
- `python3 tests/ui_acceptance.py --no-screenshots`: actual native UI with private in-memory power dependencies; receipt in `build/ui-acceptance/cbd75440c03241ca82ab427dc16b5ab6/receipt.json`.
- Universal candidate build and its `--self-test`; `lipo` confirms arm64 and x86_64. Resource/signature checks passed on this candidate too.
- The actual AppKit template was rendered at 18/36/256 px and visually inspected enlarged. Pixel connected-component tests at 18/36 px verify separate crescent and spark and transparent corners.
- SVG audit reports no issues; one colour, no font/raster dependencies.
- `git diff --check`.

Not performed: real power-toggle acceptance, physical lid tests, Intel runtime, a new DMG, full 200-MB resource suite, trademark clearance. The isolated UI test did not change the running application, power settings or network. The helper SVG renderer was unavailable; actual AppKit rendering was used for menu previews.

Local replacement and remote Git delivery are separate post-verification operations explicitly requested by the user. Their final receipt is retained locally under the original repository `build/brand-update/` with saved settings, installed version and final main SHA; no claim of publication is made by these tests.

Design assets and references are pinned by `docs/brand/assets.sha256`.
