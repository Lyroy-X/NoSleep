#!/usr/bin/env python3
"""Build an owned-guest VNC keyboard receiver; never launch a host window."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import string
import subprocess
import uuid

REPO = Path(__file__).resolve().parents[3]
SOURCE = Path(__file__).with_name("InputReceiver.swift")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--guest-mac", required=True, help="Exact MAC of the explicitly owned VirtualMac guest")
    parser.add_argument("--output", type=Path, help="A new directory under build/ or .taskflow/")
    args = parser.parse_args()
    if not re.fullmatch(r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", args.guest_mac):
        parser.error("A complete guest MAC is required")
    if not shutil.which("swiftc"):
        parser.error("Building requires macOS Command Line Tools")
    output = (args.output or REPO / "build/vnc-input-probes" / ("run-" + uuid.uuid4().hex)).resolve()
    if not any(output.is_relative_to((REPO / name).resolve()) and output != (REPO / name).resolve() for name in ("build", ".taskflow")):
        parser.error("Output must be a dedicated directory inside build/ or .taskflow/")
    if output.exists():
        parser.error("Output must be new; an existing package is never overwritten")
    output.mkdir(parents=True, mode=0o700)
    package = output / "package"
    app = package / "VNCInputProbe.app"
    contents = app / "Contents"
    binary = contents / "MacOS/input-receiver"
    binary.parent.mkdir(parents=True)
    dummy = "Aa_Zz-09" + "".join(secrets.choice(string.ascii_letters + string.digits + "_-") for _ in range(34))
    dummy_file = output / "dummy.txt"
    with os.fdopen(os.open(dummy_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as handle:
        handle.write(dummy)
    config = {"expectedHash": hashlib.sha256(dummy.encode()).hexdigest(), "expectedLength": len(dummy), "mac": args.guest_mac.lower()}
    (package / "public-config.json").write_text(json.dumps(config, indent=2) + "\n")
    info = {"CFBundleIdentifier": "local.nosleep.vnc-input." + uuid.uuid4().hex, "CFBundleExecutable": "input-receiver",
            "CFBundleName": "VNCInputProbe", "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "LSMinimumSystemVersion": "13.0"}
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    with (output / "compile.log").open("w") as log:
        subprocess.run(["swiftc", "-target", "arm64-apple-macosx13.0", "-parse-as-library", str(SOURCE), "-o", str(binary)], check=True, stdout=log, stderr=subprocess.STDOUT, timeout=60)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True, timeout=15)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], check=True, capture_output=True, timeout=15)
    receipt = {"result": "built", "nativeInputExecuted": False, "sourceSHA256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
               "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(), "package": str(package.relative_to(REPO)),
               "dummyFile": str(dummy_file.relative_to(REPO)), "expectedSHA256": config["expectedHash"], "expectedLength": 42,
               "dummyPrinted": False, "dummyIncludedInGuestPackage": False, "clipboardUsed": False}
    (output / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
