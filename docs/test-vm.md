# Retained macOS 27 test VM

The repository has an existing, stopped local VM for future explicitly authorized
macOS acceptance. This is an inventory, not permission to start it. Retain its
ASIF disk; never upload the VM, cached image, raw logs or user-state backups to Git.
A fresh clone on another computer does not contain this fixture.

## Locate the existing fixture

Resolve the original checkout, including from a linked worktree:

```sh
source_root="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
lab_root="$source_root/build/vpn-lab/idle-lock-macos27-20261015"
tart_tool="$source_root/build/vpn-lab/tools/tart.app/Contents/MacOS/tart"
```

- VM name: `nosleep-idle-lock-macos27`.
- Isolated registry: `$lab_root/vms` (always set this exact `TART_HOME`).
- Retained disk: `$lab_root/vms/vms/nosleep-idle-lock-macos27/disk.img`.
- Format: ASIF, 50 GB virtual capacity; roughly 35 GB allocated at acceptance.
- Guest: macOS 27.0, build 26A428; exact fixture MAC `0a:32:5c:d1:a2:d6`.
- Source: official Cirrus vanilla image, pinned to
  `ghcr.io/cirruslabs/macos-golden-gate-vanilla@sha256:b78a521145ebef24e9916c0b3999e165bb12b587d11524c5fa3ba4fe7bf79bb9`.
- Fixture account: the image's public disposable `admin` account. Never substitute
  a host, corporate or personal password. User-only RPC, no root RPC daemon.
- Signed Tart TeamIdentifier: `9M2P8L4D89`; verify before use.

Read status without starting or downloading anything:

```sh
codesign --verify --strict "$source_root/build/vpn-lab/tools/tart.app"
env TART_HOME="$lab_root/vms" TART_NO_AUTO_PRUNE=1 \
  "$tart_tool" list --source local --format json
```

## Safety and lifecycle

The last acceptance on 2026-10-16 confirmed `Running=false`, retained/detached
ASIF disk and stopped console proxy. Recheck live status; old JSON is historical
proof, not current runtime state. Do not restart after a transport failure until
existing controller, supervisor and registry state are diagnosed.

Use only the existing bounded controller and independent `vm_supervisor.py` under
`$lab_root`: 2 vCPUs, 4096 MiB, lower priority, 600 seconds per generation. The
supervisor refuses low memory/disk headroom, thermal restriction or excessive CPU
load and stops its own VM when its controller disappears. No host keyboard,
pointer, clipboard, USB or audio passthrough. Do not use plain `tart run`, another
`TART_HOME`, a foreign VM, root RPC or a new download as a shortcut.

Every test must capture/restore the guest's original policy and any temporary
power timer. Keep host power settings, installed applications, Cisco/VPN,
Keychains and other agents/VMs untouched. No saved PID may be signalled. Stop only
the exact named VM and confirm `Running=false`, retained disk and detached image
after success, failure or cancellation. When authorized cleanup is necessary:

```sh
env TART_HOME="$lab_root/vms" TART_NO_AUTO_PRUNE=1 \
  "$tart_tool" stop nosleep-idle-lock-macos27 --timeout 20
# Repeat the exact isolated list command and check Running=false.
```

## Proven scenarios and limits

`natural_idle_acceptance.py` passed real protected/off/restored controls with
System Settings absent and unchanged native input counters. Each control observed
20 seconds of actual display sleep and five seconds after wake. The test records
the guest's original display timer, temporarily uses one minute, then restores it.
The fixture originally had displaysleep=0; forced `displaysleepnow` did not
reliably exercise loginwindow inactivity and is not the final acceptance method.

`verify_manual_and_crash.py` passed actual guest Apple-menu Lock Screen while
policy was off: ordinary wake kept the manual lock. It restored the original
policy, then deliberately exited its controller without cleanup (exit 99).
The independent supervisor reported `controller-exited`, stopped the VM and
retained the disk. Reusing that interactive test needs an explicitly authorized
isolated console and a fresh readiness/acknowledgement; do not create its `.done`
file without performing and observing the requested guest action.

Relevant local receipts, all below `$lab_root`:

- `natural-idle-passing-cycle-20261016/automated-result.json` and the three phase JSON files;
- `manual-crash-result.json`, the referenced `supervisor-*.json` and stop receipts;
- `final-safety-confirmation.json` and `final-implementation-receipt.json`.

An asleep screen may have a CGSession shield even with the password policy off;
the receipt proves ordinary wake without authentication, not continuous Computer
plugin operation while the display stays asleep. Physical lid closure, host
shutdown/restart, first admin setup, downloaded-app Gatekeeper and Intel runtime
require separate acceptance. This VM is a local reusable fixture, not CI coverage.
