#!/usr/bin/env python3
"""Fetch only the pinned, signed Tart release into the private lab directory."""
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2] / "build" / "vpn-lab"
VERSION = "2.40.1"
DIGEST = "363e2701154a8155cbc1bb6d845430c9b42697d2a186bc49574471ca2877db46"


def verify(app):
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    result = subprocess.run(["codesign", "-dv", "--verbose=2", str(app)], capture_output=True)
    if "TeamIdentifier=9M2P8L4D89" not in result.stderr.decode():
        raise ValueError("Tart developer identity did not match Cirrus Labs")


def main():
    directory = ROOT / "tools"
    app = directory / "tart.app"
    if app.exists():
        verify(app)
        version = subprocess.check_output([str(app / "Contents/MacOS/tart"), "--version"], text=True).strip()
        if version != VERSION:
            raise ValueError("existing owned Tart version changed; do not overwrite it")
        print(json.dumps({"signedToolReady": True, "version": VERSION, "path": str(app.resolve())}))
        return
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    request = urllib.request.Request("https://api.github.com/repos/cirruslabs/tart/releases/tags/" + VERSION,
                                     headers={"Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        release = json.loads(response.read(1048576))
    asset = next(item for item in release["assets"] if item["name"] == "tart.tar.gz")
    if asset.get("digest") != "sha256:" + DIGEST or not 0 < asset["size"] < 64 * 1024 * 1024:
        raise ValueError("official release metadata does not match the pinned artifact")
    archive = ROOT / "tart.tar.gz"
    if not archive.exists():
        temporary = archive.with_suffix(".partial")
        digest = hashlib.sha256()
        total = 0
        with urllib.request.urlopen(asset["browser_download_url"], timeout=60) as response, temporary.open("wb") as file:
            while data := response.read(65536):
                total += len(data)
                if total > asset["size"]:
                    raise ValueError("Tart archive exceeded the release size")
                digest.update(data)
                file.write(data)
        if total != asset["size"] or digest.hexdigest() != DIGEST:
            raise ValueError("Tart archive hash mismatch")
        temporary.chmod(0o600)
        temporary.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != DIGEST:
        raise ValueError("preserved Tart archive did not match the release digest")
    with tarfile.open(archive) as bundle:
        bundle.extractall(directory, filter="data")
    verify(app)
    print(json.dumps({"signedToolReady": True, "version": VERSION, "path": str(app.resolve())}))


if __name__ == "__main__":
    main()
