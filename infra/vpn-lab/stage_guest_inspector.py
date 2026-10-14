#!/usr/bin/env python3
"""Compile a read-only native AX schema probe for the owned macOS guest."""
import json
import os
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[2] / "build/vpn-lab"


def main():
    source = Path(__file__).with_name("guest_ax_inspector.swift")
    bundle = ROOT / "guest-transfer/NoSleep Lab Inspector.app"
    executable = bundle / "Contents/MacOS/inspector"
    executable.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-target", "arm64-apple-macos13.0", str(source), "-o", str(executable)],
                   check=True, timeout=60)
    executable.chmod(0o755)
    info = {"CFBundleIdentifier": "local.robert.nosleep.identity-probe.guest-inspector",
            "CFBundleName": "NoSleep Lab Inspector", "CFBundleDisplayName": "NoSleep Lab Inspector",
            "CFBundleExecutable": "inspector", "CFBundlePackageType": "APPL", "CFBundleVersion": "5",
            "CFBundleShortVersionString": "1.3", "LSMinimumSystemVersion": "13.0", "LSUIElement": True}
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(json.dumps({"guestReadOnlyInspector": str(bundle.resolve()), "targetOSMinimum": "13.0"}))


if __name__ == "__main__":
    main()
