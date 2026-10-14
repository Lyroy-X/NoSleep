# Persistent actual CLI lab session

This is an opt-in extension for the owned VirtualMac/UID501 guest and its frozen
NoSleep Lab profile and signed official CLI. It is prepared outside `Sources`
so current candidate acceptance can finish unchanged. There is no host VPN,
Cisco GUI automation, power, disconnect, route, service, certificate, install,
or general clipboard operation here.

## Integration after the current frozen candidate finishes

Copy `infra/vpn-lab/NoSleepCLILabSession.swift` unchanged to
`Sources/NoSleepCLILabSession.swift`. At the beginning of the existing
`officialConnectionLabAcceptance()` function in `Sources/CLIRealAcceptance.swift`,
before its existing preflight/fixture work, add:

```swift
if CommandLine.arguments.contains("--lab-session") {
    try officialConnectionPersistentLabSession()
    return
}
```

Keep the existing `--verify-official-connection-lab` dispatch in
`Sources/NoSleep.swift` unchanged, including its UI source hash. Do not add a
normal application startup path. The existing build source glob
then includes the new file. Advance the source receipt, build a new isolated
candidate once, and use that exact binary/path for every generation of a
session. The guardian verifies all source/binary/Info receipt bindings before
using the existing virtio-vsock transport. Integration/build and actual guest
execution are owned by the lead agent.

## Actual collaborators and lifetime

The mode creates actual `CiscoGUIRecovery`, `CiscoObserver`,
`CiscoConnectionClient`, `CiscoNativeConnectionProcess`, `VPNCredentialStore`
and a private `DiagnosticStore`. The production clock, physical-network checks,
session checks, profile reader, signature checks, automatic polling, parser,
submission, retry/backoff, durable intent and cleanup are used without overrides.
Wrappers count public calls and completed results; they never retain CLI reads
or input. Durable bookkeeping adds laboratory I/O overhead. There is no injected
clock, client result or timing barrier in actual authentication paths.

Hardware/MAC/UID, profile SHA, CLI signature/SHA, candidate canonical path,
binary/Info SHA and signature, lab-root/private-directory ownership/modes, and
the fixture's private file stat are checked before any credential item access
or secret read. Setup saves once into one unique owned account and one owned
preferences suite. The private 0700 session directory holds a 0600 descriptor
with account/suite/revisions, candidate binding and cumulative counters; it
contains no password. Each running process holds an exclusive session lease.

`resume` uses the same descriptor/account/suite/revision and budgets. It makes
no Save, Authorize or Enable call. Production bootstrap may restore the prior
explicit persisted ON preference. The current native Connected observation must
veto any new launch/input; this is measured, not simulated. Stop preserves the
production preference and credential item. Only explicit Finish deletes the
owned item/suite. Lifetime is bounded to 45 minutes, 16 process generations and
64 commands; expiry stops only the controller and its owned child.

## Guardian commands and recovery

`tests/cli_lab_session_acceptance.py` runs contracts by default. Actual use
requires `--run-owned-lab`, a caller-chosen 32-character lower-case hexadecimal
`--session`, and `--app`, `--source-receipt`, `--source-receipt-sha256` for the
integrated candidate. All subsequent invocations reuse those bindings.

| Invocation suffix | Meaning and strict result |
| --- | --- |
| `--start setup --expect ready` | Transfer one immutable candidate; private fixture save once; no authentication. |
| `--op enable --expect new-connected --wait 120` | Actual controller ON; one new child, actual UW1/PW1, one saved-password read, connected/reaped result, cleared in-flight, fresh native Connected, independent server1 and fresh utun nonce. |
| `--op stop --expect stopped` | Stop only NoSleep recovery; own child released; retain same item/preferences. A current tunnel must remain independently proved. |
| `--start resume --expect preserved-connected` | New NoSleep generation, same binary/path/store; no additional Save/PW/Authorize/child; independent same server session and a different fresh nonce. |
| `--op off --expect off` | Synchronous public OFF request, eventually no owned child/in-flight. A Connected or Disconnected native result is independently checked. |
| `--op replaceWrong --expect replaced` | Explicit save of the fixed synthetic wrong value, new revision, OFF, no auth. |
| `--op enable --expect wrong-password --wait 120` | Actual UW1/PW1/reaped rejection and latched revision, native Disconnected/server0. |
| `--op enable --expect rejected` | Previously rejected revision stays latched with no new child/PW/read. Also usable for a resumed rejected session. |
| `--op replaceValid --expect replaced` | Read the same private synthetic fixture and explicitly replace; new revision, OFF, no auth. Requires a separate Enable for authentication. |
| `--op delete --expect deleted` | Delete only this session's item through the public controller API, OFF, no new authentication. A current tunnel must retain the same server fingerprint and fresh data proof. |
| `--op finish --expect finished` | Bounded release, delete own item/suite, terminal private descriptor; no tunnel disconnect. |
| No `--start`/`--op` | Read existing role/checkpoint/server state; cannot start or repeat a process or command. |

To test repeated fresh authentication, the lead independently applies an
explicitly authorized **guest-only** disconnection/expiry stimulus. This script
does not supply that stimulus. Each new recovery is proved with
`--expect new-connected` against the previous checkpoint (the lead may use a
read-only invocation to establish the exact baseline before the stimulus).
Short-session budget tests must use the real production backoff and retain the
same session/account; do not wait past the production healthy-session reset
then claim a retained-budget result.

The host guardian fsyncs a pending command, original checkpoint/native/server
baseline and challenge before the
guest command write. The guest fsyncs accepted sequence before the actual
operation and completed sequence after its completion. Exact replay is a no-op;
changed/reordered/duplicate commands are refused. A process crash between
acceptance and completion makes resume refuse before Keychain access, never
replay a mutation. Transport failure is unresolved evidence: retry the same
operation/expectation or invoke read-only observation. The original sequence,
challenge and original native/server baseline remain unchanged. OFF, replacement,
delete, stop and finish from an originally Connected tunnel must still end with
fresh native Connected, the same independent server fingerprint and a fresh
utun nonce. Disconnected/server0 is a failed preservation result, never a
negative-case fallback. Existing live execution is reused;
an uncertain launch is never relaunched. Resume requires a separate explicit
`--start resume` after the old process is gone and no connect child remains.

Roles are bound to private ownership/mode, exact process argv/path/hash, birth
and generation. Child roles are read-only; a reused PID is not ownership and
no persisted PID is ever killed by the guardian. The existing forward PID/cwd/
argv and RPC argv are checked; failed transport never starts replacement
forward/RPC/VM processes.

## Acknowledge a completed failed expectation without replay

A completed Enable can fail the strict `new-connected` expectation even when
the native client actually reaches Connected: for example, the driver returns
`manualRequired/reaped` and the controller durably pauses/rejects the submitted
revision. Its original acceptance remains **FAILED**. Keeping that expectation
pending must not prevent an explicit later Stop/Finish cleanup.

The lead may invoke a separate read-only acknowledgement, using the same session
and frozen candidate arguments:

```text
--resolve-failed-expectation \
--failed-expectation-receipt <existing-private-session/receipt-hex32.json> \
--failed-expectation-receipt-sha256 <exact-original-failed-receipt-sha256>
```

This cannot be combined with Start, an operation, or a changed expectation. It
requires an existing pending Enable/`new-connected`, its exact completed sequence
and challenge, the same live owner generation, a fixed non-Connected terminal
driver outcome, proven released child, no credential/connection/in-flight work,
and a durably disabled paused controller. Fresh native/server facts must agree;
actual Connected additionally requires server1 and a fresh utun nonce. It reads
only existing role/checkpoint/native/server evidence and writes no guest command,
starts no session/authentication process, sends no signal, and calls no credential
item API.

Before clearing host guardian pending state, it fsyncs an immutable
`failed-expectation-<original-challenge>.json` audit containing the original
command/expectation/checkpoint/native/server baseline, unchanged original FAILED
receipt and its hash, typed terminal failure and current observations. Original
server baselines are never rebased and the guest's credential/rejection/consent
state is never changed. The new result is `failed-expectation-resolved`, explicitly
acknowledgement only; it is not ordinary/reconnect PASS. The historical failed
receipt is never edited.

If fresh facts, transport, nonce or audit persistence fail, pending stays
unresolved. If host state persistence fails after the rename, the guardian tries
to durably restore the exact original pending state and reports
`resolution-state-write-rolled-back`. If that rollback also fails, it reports
`resolution-state-commit-uncertain`: the on-disk state may show pending cleared,
but the immutable audit already durably authorized that clear. This is never
reported as a successful acknowledgement or an old-attempt PASS; inspect the
existing state/audit before any later explicit cleanup, without replaying Enable.
If audit succeeded and pending remains after a failed state clear, retry
validates and re-fsyncs that same complete immutable audit, obtains fresh current
facts/nonce, and may finish clearing pending without rewriting the audit. Partial,
foreign or altered audits are refused. A completed acknowledgement cannot be
replayed once pending is clear. Normal explicit Stop/Finish can then use the next
sequence while the production rejection latch remains intact.

## Receipts and verification limits

Checkpoints contain only fixed stage/issue/outcome/cleanup/phase/operation enums,
bounded counters, booleans and a random command challenge. No account, revision,
profile/group/username, password, raw error, transcript or per-secret length/hash
enters receipts. Candidate/source/signature bindings and anonymous independent
server/nonce fingerprints are public acceptance evidence. The exact whitelist
rejects duplicate JSON keys, extra fields, raw strings, type spoofing, count
overflows, rollback/equivocation and nonce replay.

`python3 tests/cli_lab_session_acceptance.py` validates this schema and meaningful
strict oracles, command retry behavior and actual extracted Swift private-file/
fsync ledger helpers. The latter touches only a new ignored build directory;
it uses no controller, CLI, credential item, native UI or lab runtime. Full Swift
type checking with the current sources checks integration types without app
launch. These checks are not actual Cisco authentication or persistent-session
E2E. Actual reconnect/restart/wrong/replacement/delete/GUI tests remain pending
until the lead integrates and executes the new frozen candidate.
