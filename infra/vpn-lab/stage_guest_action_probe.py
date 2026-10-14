#!/usr/bin/env python3
"""Build the explicitly destructive, VM-only stale Cisco control race probe."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    bundle = ROOT / "build/vpn-lab/guest-transfer/NoSleep Lab Action Probe.app"
    executable = bundle / "Contents/MacOS/action-probe"
    executable.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-target", "arm64-apple-macos13.0",
                    str(Path(__file__).with_name("guest_held_action_probe.swift")), "-o", str(executable)],
                   check=True, timeout=60)
    executable.chmod(0o755)
    info = {"CFBundleIdentifier": "local.robert.nosleep.identity-probe.guest-action-probe",
            "CFBundleName": "NoSleep Lab Action Probe", "CFBundleDisplayName": "NoSleep Lab Action Probe",
            "CFBundleExecutable": "action-probe", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "LSMinimumSystemVersion": "13.0", "LSUIElement": True}
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    print(json.dumps({"guestOnlyActionProbe": str(bundle), "unsignedExecutableSHA256":
                      hashlib.sha256(executable.read_bytes()).hexdigest()}))


if __name__ == "__main__":
    main()
