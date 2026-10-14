#!/usr/bin/env python3
"""Stage installed, signed Cisco CODE for a private local macOS guest.

This reads installation receipt paths and copies only application/binary code.
Working VPN profiles, policy, logs, cookies, certificates and Keychain items
are excluded. The result stays in ignored build/ and is never redistributed.
This script must never install or register a Cisco service on the host.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
STAGE = ROOT / "build" / "vpn-lab" / "guest-transfer"
PREFIXES = (
    "Applications/Cisco/Cisco Secure Client.app/",
    "Applications/Cisco/Cisco Secure Client - Socket Filter.app/",
    "opt/cisco/secureclient/bin/",
    "opt/cisco/secureclient/lib/",
    "opt/cisco/secureclient/install/",
    "opt/cisco/secureclient/kdf/bin/",
    "opt/cisco/secureclient/kdf/lib/",
)
STATIC_LINKS = {"opt/cisco/secureclient/ACManifestVPN.xml"}
STATIC_SCHEMAS = {
    "opt/cisco/secureclient/AnyConnectLocalPolicy.xsd",
    "opt/cisco/secureclient/vpn/profile/AnyConnectProfile.xsd",
    "opt/cisco/secureclient/vpn/profile/mgmttun/AnyConnectProfile.xsd",
}
DEPENDENCY_PREFIXES = ("opt/cisco/secureclient/kdf/bin/", "opt/cisco/secureclient/kdf/lib/")
APPLICATIONS = [
    Path("/Applications/Cisco/Cisco Secure Client.app"),
    Path("/Applications/Cisco/Cisco Secure Client - Socket Filter.app"),
    Path("/opt/cisco/secureclient/bin/Cisco Secure Client - AnyConnect VPN Service.app"),
]
MANIFEST_INPUTS = {
    "manifestToolSHA256": "opt/cisco/secureclient/bin/Cisco Secure Client - AnyConnect VPN Service.app/Contents/Helpers/manifesttool",
    "staticManifestSHA256": "opt/cisco/secureclient/bin/Cisco Secure Client - AnyConnect VPN Service.app/Contents/Resources/ACManifestVPN.xml",
}


def run(*args):
    result = subprocess.run(args, capture_output=True, check=True)
    return result.stdout.decode(errors="replace")


def selected_code_path(relative, dependencies_only=False):
    path = Path(relative)
    if path.is_absolute() or ".." in path.parts:
        return False
    prefixes = DEPENDENCY_PREFIXES if dependencies_only else PREFIXES
    return relative in STATIC_LINKS | STATIC_SCHEMAS or any(relative.startswith(prefix) for prefix in prefixes)


def verify_macho(source):
    with source.open("rb") as file:
        magic = file.read(4)
    if magic not in (b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        return
    run("codesign", "--verify", "--strict", str(source))
    signature = subprocess.run(["codesign", "-dv", "--verbose=2", str(source)], capture_output=True)
    if "TeamIdentifier=DE8Y96K9QP" not in signature.stderr.decode():
        raise RuntimeError("raw Mach-O dependency is not signed by Cisco")


def registration_input_hashes(records):
    by_path = {item["path"]: item.get("sha256") for item in records}
    result = {key: by_path.get(path) for key, path in MANIFEST_INPUTS.items()}
    if any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value)
           for value in result.values()):
        raise ValueError("verified code-only installer manifest inputs are missing")
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--supplement-dependencies", action="store_true")
    args = parser.parse_args()
    STAGE.mkdir(parents=True, exist_ok=True, mode=0o700)
    payload = STAGE / "cisco-code"
    report_path = STAGE / "cisco-code-manifest.json"
    previous = None
    if args.supplement_dependencies:
        previous = json.loads(report_path.read_text())
        if (not payload.is_dir() or previous.get("teamIdentifier") != "DE8Y96K9QP"
                or previous.get("hostChanges") is not False or previous.get("configurationCopied") is not False):
            raise ValueError("not the owned previous Cisco code stage")
    elif payload.exists():
        raise SystemExit("Already staged; inspect or remove only this owned staging directory explicitly.")
    else:
        payload.mkdir(mode=0o700)
    for app in APPLICATIONS:
        run("codesign", "--verify", "--strict", "--deep", str(app))
        signature = subprocess.run(["codesign", "-dv", "--verbose=2", str(app)], capture_output=True)
        if "TeamIdentifier=DE8Y96K9QP" not in signature.stderr.decode():
            raise RuntimeError("installed application is not signed by Cisco")
    receipt_paths = run("pkgutil", "--files", "com.cisco.pkg.anyconnect.vpn").splitlines()
    copied = []
    for relative in sorted(receipt_paths):
        if not selected_code_path(relative, args.supplement_dependencies):
            continue
        source = Path("/") / relative
        target = payload / relative
        if not source.exists() and not source.is_symlink():
            continue
        if source.is_symlink():
            target.parent.mkdir(parents=True, exist_ok=True)
            link = os.readlink(source)
            if relative in STATIC_LINKS and source.resolve() != APPLICATIONS[2] / "Contents/Resources/ACManifestVPN.xml":
                raise ValueError("static VPN manifest is not linked to signed Cisco resources")
            if target.exists() or target.is_symlink():
                if not target.is_symlink() or os.readlink(target) != link:
                    raise ValueError("previous staged symlink differs")
            else:
                target.symlink_to(link)
            copied.append({"path": relative, "symlink": link})
        elif source.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            shutil.copystat(source, target, follow_symlinks=False)
        else:
            verify_macho(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target, follow_symlinks=False)
            verify_macho(target)
            copied.append({"path": relative, "sha256": hashlib.sha256(target.read_bytes()).hexdigest()})
    for app in APPLICATIONS:
        run("codesign", "--verify", "--strict", "--deep", str(payload / str(app).lstrip("/")))
    report = {"schema": 1, "source": "installed Cisco receipt and signed code",
              "teamIdentifier": "DE8Y96K9QP", "hostChanges": False,
              "configurationCopied": False, "credentialsCopied": False,
              "redistributable": False, "files": copied}
    if previous:
        merged = {value["path"]: value for value in previous["files"]}
        merged.update({value["path"]: value for value in copied})
        report["files"] = list(merged.values())
        report["dependenciesSupplemented"] = True
    (STAGE / "cisco-code-manifest.json").write_text(json.dumps(report, indent=2))
    os.chmod(STAGE / "cisco-code-manifest.json", 0o600)
    inputs = registration_input_hashes(report["files"])
    for key, relative in MANIFEST_INPUTS.items():
        if hashlib.sha256((payload / relative).read_bytes()).hexdigest() != inputs[key]:
            raise ValueError("staged installer input does not match its receipt")
    (STAGE / "manifest-inputs.plist").write_bytes(plistlib.dumps(inputs))
    shutil.copy2(Path(__file__).with_name("guest-register-cisco-manifest.sh"),
                 STAGE / "guest-register-cisco-manifest.sh")
    print(json.dumps({"payload": str(payload), "fileCount": len(copied),
                      "signedCodeVerified": True, "hostChanges": False}))


if __name__ == "__main__":
    main()
