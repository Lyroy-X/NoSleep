# Verification: automatic lock and release

Implementation is ported onto current main669cb6e71432c6dbed668be5e110671f7b724c78
(3.5.1/build18), preserving compact UI and ARM-only CI. Release candidate is
3.6.0/build19, a compatible new capability. The original working checkout and
its unrelated pending work are preserved.

- Native policy/store/password parser, cancellation/refusal/boundary/retry/recovery and five critical mutation contracts passed on the original implementation; re-run on this candidate.
- Actual macOS27.0/26A428 natural-idle before/off/restored passed, System Settings absent, input counters unchanged; original policy and guest timer restored.
- Actual manual Lock Screen under off stayed locked after wake. Controller exit99 triggered independent supervisor shutdown; exact VM stopped and disk retained.
- Current local fixtures and exact historical native receipts are described in docs/test-vm.md; no host credentials or raw guest state are published.
- Final current-base quality, native UI/regression, universal DMG, strict OpenSpec, PR CI, merged-head release and downloaded artifact acceptance remain delivery checks. Record their actual terminal results before reporting completion.

The earlier forced virtual-display trials were inconsistent; only the natural
idle route is final native evidence. An asleep CGSession shield is possible even
with password policy off. Computer-plugin continuity while asleep, Intel runtime,
first admin setup, physical lid, real host shutdown and downloaded Gatekeeper are
not inferred from this evidence.
