# Owned stock-server session stimulus (future guarded use; historical intent retained)

`owned_session_stimulus.py` is separate from the frozen persistent guardian and
all production Sources. Default execution only verifies public stock source;
it invokes neither Docker nor guest commands. This preparation does not prove
expiry, fresh authentication, retry budgets or actual reconnect.

The existing pinned [official ocserv 1.4.2 archive](https://www.infradead.org/ocserv/download/ocserv-1.4.2.tar.xz)
has SHA256 `e35d748a5244b10be3a92ad4df95a534c8280c43680eecaf3cb1b20d2a22b1a5`.
Its `src/occtl/occtl.c` and `src/main-ctl-unix.c:1030` implement `terminate id`
for one numeric connection ID and request invalidation of its associated cookie.
`disconnect id` preserves that cookie, so it is unsuitable for proving a new
saved-password authentication. The daemon's termination reply acknowledges
disconnect even if the later cookie invalidation fails. The runner therefore
always records `cookieInvalidationProven=false` and `actualReconnectProven=false`;
the subsequent production PW1/reaped/server/fresh-nonce oracle is mandatory.

Actual invocation is exclusively the lead's later action:

```text
python3 infra/vpn-lab/owned_session_stimulus.py --run-owned-lab \
  --expire-current-session --session <existing-session-hex32> \
  --expected-server-fingerprint <existing-anonymous-server-sha256>
```

Required before dispatch: current runtime-import frozen guardian SHA
`554d39adbaaccfab1a1d48c155f2556a3915303eb3577f4b531f795f5da99635`; same private
session/candidate state with no pending command/launch; a previous fresh nonce
and that exact server fingerprint; owned stock1.4.2 container/image/run/internal
network; current guest MAC/VirtualMac/UID/console/profile/signed CLI/candidate
guards; fresh Connected, configured/confirmed explicit ON, same revision binding
and generation/cumulative counters, no owned NoSleep connect child/in-flight,
GUI absent; independent server1 and another fresh tunnel nonce. The selected
positive numeric ID remains only in private memory/command argv. Server rows,
usernames, CLI responses and the ID are never written into receipts.

The current import freeze includes the reviewed failed-Stop acknowledgement
(independent receipt `build/confirmed-recovery-review/failed-stop-ack-review/receipt.json`,
SHA256 `6e3b9a0b060bb214a18db6fd4217f3eecc84e4bf5ce90b498d2ece026516b89b`).
It retains the original Stop preservation FAIL and causes no actor action.
REMOTE and ordinary typed/preservation/nonce predicates remain unchanged.
Historical receipt runner attestations use an explicit whitelist containing
only reviewed fccef9b1... and current 554d39ad...; their full file hash/private
session/build/Source/command/nonce/attribution checks still apply. This does not
allow importing fccef/6dee as current runtime or trusting another receipt runner.
The pin refresh neither re-attests nor replays the original acknowledged
stimulus: every existing durable intent remains inspect-only, even with an
explicit expire flag. Original incomplete/failed evidence remains unchanged.

The refreshed guardian binding includes the reviewed acknowledgement-only
`--resolve-failed-expectation` change (independent review receipt
`build/confirmed-recovery-review/guardian-resolution-review/final-fccef9b1-review.json`,
SHA256 `7e7f0ef65f0c0105d95b1b9288f3fc027ec928b48e1d406fa2d4cbfa50dbf57b`).
That operation durably audits the original failed expectation before clearing
pending, retains the old FAILED result and performs no session command or
authentication. A fresh native Connected/server1/nonce from that acknowledgement
is insufficient for this stimulus: its paused, disabled, unconfirmed controller
still fails `before_ready`. The lead must first obtain an actual production
PW1/reaped ConfirmedConnected result for the same saved account, role, revision
and budget, with the independent server and nonce baseline. No positive
authentication, generation, counter, preservation or transport-replay gate was
relaxed by the pin refresh. Hash mismatch refuses before module import.

Healthy history admission is explicit and separate from ordinary confirmed
readiness. The frozen controller `CiscoGUIRecovery.swift`
(`4ba478e85f07c8438166676173bb5cf46ae9e9e366fce24d3702ed513ebb4a6d`,
lines 547–551) removes submitted/attempt/confirmed/budget after its real
30-second healthy interval. To admit that state, provide `--auth-receipt` and
`--auth-receipt-sha256`; for the single supported generation1→2 preserved resume,
also provide `--resume-receipt` and `--resume-receipt-sha256`. Each is an explicit
absolute path to an existing `receipt-<hex32>.json` in this same private session
directory. Hash, owner, mode0600, no symlink/hardlink, size131072, exact schema,
same build/source freeze, typed observations/server/nonce and original PW1
controller oracle are checked. A `passed` string alone is insufficient.

The original receipt must prove first-generation initial Enable, one actual
PW1/reaped ConfirmedConnected login and unchanged initial saved revision. Resume
must directly follow one completed Stop, prove generation2/new PID with same
server and a different nonce, and add only one metadata read; no password/read,
authentication, save, delete or authorization count can change. Current healthy
admission requires live same owner/generation/revision, explicit/persisted ON,
stageConnected, configured/nativeFresh, GUI absent, no child/busy/in-flight,
submitted/confirmed/rejected/budgetPresent false and budget0/0. Its command,
challenge and every counter must equal the authenticated/resumed baseline.
The independently rechecked server must match the original authenticated
fingerprint and the new nonce must differ from both historical nonces. No fake
clock, forced confirmation, extra Enable or arbitrary generation chain exists.
Only the two validated receipt hashes enter the separate stimulus journal.
The historical files are never written, and failed/acknowledged attempts cannot
be substituted for either proof.

The runner rechecks the unique client/fingerprint and container immediately
before one `docker exec <exact-container-ID> occtl terminate id <positive-ID>`.
No name wildcard, terminate-user command, server restart, network fault, profile,
certificate, route, Cisco GUI, Keychain, power, host Cisco or MAIN operation exists.
The host shares the guardian's lease and writes only a separate private journal,
not the persistent account/preferences or frozen guardian state.

One fsynced intent is keyed by the original anonymous fingerprint. A timeout,
failed reply or transport problem is unresolved evidence. Repeat invocation
never sends another termination for that fingerprint, including a repeat with
`--expire-current-session`; use `--inspect-existing-stimulus` to inspect the same
journal and existing server/guest state. A crash before the intent can leave a
prepared journal; it also refuses a new mutation. Nothing restores, relaunches
or repairs the VM/forward/server automatically.

Only actually observed server0 plus native Disconnected yields
`stimulus-observed`. The production controller remains enabled and its real
clock/backoff continues throughout; the runner cannot hold it at Disconnected.
If native recovery or authentication wins that sampling race, the result is
`observation-incomplete`, never guessed success and never a repeated stimulus.
Afterwards the lead uses the existing persistent guardian's `--expect
new-connected` against the original checkpoint. One new owned PW1/reaped login,
cleared in-flight, fresh native Connected, server1 and a different fresh utun
nonce prove saved-account recovery; native cookie reconnect with zero PW does
not satisfy that oracle.

Use the real 30/120-second retry backoff and 30-second healthy reset. Preparation
and observation consume real time. Inspect checkpoint budgets and do not call a
post-healthy-reset attempt a retained-budget short flap. No timing override or
fake client/clock is introduced.

Limit: stock numeric connection ID is a worker PID, not an atomic generation
token. Exact prechecks/pinned container/one unique client bound the operation to
the owned lab, but stock occtl has no compare-and-terminate fingerprint API;
PID reuse between the last observation and dispatch cannot be mathematically
excluded. OS/server samples are sequential. No stronger episode-identity claim
is made. Cookie invalidation/fresh login still requires actual subsequent proof.

Pure checks: `python3 tests/owned_session_stimulus_contract.py`. These use self-contained
in-memory archive fixtures and synthetic private temporary JSON; no cached
archive or actual ignored session/receipt is needed. Production archive e35 remains
pinned. The common scripts/test.sh runner includes this pure suite before build.
Checks use no server/VM/native commands and verify ownership-target selection,
strict typing, durable intent, failure-before-dispatch and no replay after uncertainty.
