## Context
Stable baseline is e8bb21c3810d16955eeff8188d3bc255da080958. The old experiment is backed up privately and inactive. Its diagnostic history proves recurring connectionFailed outcomes, but not the underlying Cisco failure or causality of the first disconnect.

## Goals / Non-Goals
Restore useful bounded diagnostics and combined controls without coupling them to VPN authentication. The user approved native recovery and state-only observation. Do not reproduce the original authentication loop.

## Decisions
Use a typed event allowlist, 4 files of 256 KiB, 7-day per-record retention, 32 queued records and 120 accepted events per minute. Coalesce repeated observations; retain distinct user actions. Export only typed data, version, platform and boolean feature state after explicit user action. Serialize exports. Disk failures must not stop power protection. Preserve stable power guard implementation.

## Risks / Trade-offs
Full automatic fresh VPN authentication is intentionally not claimed by the proposed native recovery path. Cisco policy controls native reconnect. Physical lid closure and Intel runtime are outside locally automated acceptance. New session authentication is handled by Cisco and may require user action; no claim of automatic fresh login.

## Migration Plan
Build and test a candidate independently of installed stable NoSleep. Preserve desired power preferences. No production VPN interruption. Keep the stable app and DMG available for rollback.

## Open Questions
No unresolved scope choice. Observe out of the box when Cisco exists, respect persisted off/pause, use fixed signed local state command with EOF input and conservative profile parsing. One six-second/16-KiB query at a time with a 60-second cooldown with a one-shot timer; EOF stdin, no outgoing input; failures persist a pause until explicit user rearming. Use only explicit GUI opening, after Cisco signature validation.
