#!/usr/bin/env python3
"""Create only the owned macOS guest from a completed official Apple image.

Use --wait while fetch_restore.py is running. This does not restart, reconfigure
or connect any host VPN. Installation output is retained as a bounded private
tail. The resulting VM can be started by guest_runner.py.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.parse

ROOT = Path(__file__).resolve().parents[2] / "build" / "vpn-lab"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--wait", action="store_true")
    args = parser.parse_args()
    while True:
        progress_path = ROOT / "restore-download-progress.json"
        progress = json.loads(progress_path.read_text()) if progress_path.exists() else {}
        if progress.get("complete"):
            break
        if not args.wait:
            raise SystemExit("Official Apple image is not fully downloaded yet.")
        time.sleep(2)
    image = ROOT / urllib.parse.urlparse(progress["url"]).path.rsplit("/", 1)[1]
    if not image.is_file() or image.stat().st_size != progress["size"]:
        raise ValueError("restore image does not match the completed receipt")
    tool = ROOT / "tools" / "tart.app" / "Contents" / "MacOS" / "tart"
    subprocess.run(["codesign", "--verify", "--strict", str(tool.parents[2])],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    signature = subprocess.run(["codesign", "-dv", "--verbose=2", str(tool.parents[2])],
                               capture_output=True).stderr.decode()
    if "TeamIdentifier=9M2P8L4D89" not in signature:
        raise ValueError("Tart signer is not the verified Cirrus Labs developer")
    name = "nosleep-vpn-lab-20261012"
    env = os.environ.copy()
    env["TART_HOME"] = str(ROOT / "vms")
    env["TART_NO_AUTO_PRUNE"] = "1"
    meta = {"name": name, "source": "official Apple IPSW", "tool": str(tool),
            "home": str(ROOT / "vms"), "autoPrune": False,
            "osMajor": int(progress["version"].split(".")[0]),
            "version": progress["version"], "imageSHA256": progress["imageSHA256"],
            "cpu": 2, "memoryMiB": 6144, "diskGiB": 64}
    (ROOT / "guest.json").write_text(json.dumps(meta, indent=2))
    os.chmod(ROOT / "guest.json", 0o600)
    print(json.dumps({"phase": "installing-owned-guest", "version": progress["version"]}), flush=True)
    process = subprocess.Popen([str(tool), "create", name, "--from-ipsw", str(image), "--disk-size", "64"],
                               env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    tail = bytearray()
    while True:
        chunk = process.stdout.read(4096)
        if not chunk:
            break
        tail.extend(chunk)
        if len(tail) > 262144:
            del tail[:-262144]
    code = process.wait()
    (ROOT / "guest-create-tail.log").write_bytes(tail)
    os.chmod(ROOT / "guest-create-tail.log", 0o600)
    if code:
        print(json.dumps({"phase": "guest-create-failed", "exit": code}), flush=True)
        raise SystemExit(code)
    subprocess.run([str(tool), "set", name, "--cpu", "2", "--memory", "6144",
                    "--display", "1440x900px", "--no-display-refit"], env=env, check=True)
    (ROOT / "guest-created.json").write_text(json.dumps({"created": True, **meta}, indent=2))
    print(json.dumps({"phase": "guest-created", "metadata": str(ROOT / "guest-created.json")}), flush=True)


if __name__ == "__main__":
    main()
