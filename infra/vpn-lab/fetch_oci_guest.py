#!/usr/bin/env python3
"""Resume a pinned official Cirrus macOS guest without Apple's DFU restore.

The public OCI image has independent Apple LZ4 disk layers. HTTP ranges and
each compressed/uncompressed SHA-256 are verified before registering the
owned guest. A preserved Tart partial disk is reused only where its layer
hash matches. This script never alters host VPN, USB or shared Tart VMs.
"""
import concurrent.futures
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[2] / "build" / "vpn-lab"
DIRECTORY = ROOT / "oci"
REPO = "cirruslabs/macos-sonoma-vanilla"
MANIFEST_SHA = "7ea0d508380b63f13c94ee72cd22ca3dd9ec5cdf4a5ae14b2ae2ce6a6603fba6"
NAME = "nosleep-vpn-lab-20261012"
SEGMENT = 32 * 1024 * 1024


def hash_file(path, offset=0, length=None):
    digest = hashlib.sha256()
    with path.open("rb") as file:
        file.seek(offset)
        while length is None or length > 0:
            data = file.read(min(1048576, length) if length is not None else 1048576)
            if not data:
                break
            digest.update(data)
            if length is not None:
                length -= len(data)
    if length:
        raise EOFError("short local OCI layer")
    return digest.hexdigest()


def validate_manifest(manifest):
    layers = manifest["layers"]
    if not 3 <= len(layers) <= 200:
        raise ValueError("OCI layer count exceeds budget")
    groups = {}
    for layer in layers:
        kind = layer["mediaType"]
        if kind not in {"application/vnd.cirruslabs.tart.config.v1",
                        "application/vnd.cirruslabs.tart.nvram.v1",
                        "application/vnd.cirruslabs.tart.disk.v2"}:
            raise ValueError("unsupported OCI guest layer")
        if (not re.fullmatch(r"sha256:[a-f0-9]{64}", layer["digest"])
                or not 0 < layer["size"] <= 537919488):
            raise ValueError("invalid OCI layer digest or size")
        if kind.endswith("config.v1") and layer["size"] > 1048576:
            raise ValueError("OCI guest configuration exceeds budget")
        if kind.endswith("nvram.v1") and layer["size"] > 64 * 1024 * 1024:
            raise ValueError("OCI guest NVRAM exceeds budget")
        groups.setdefault(kind, []).append(layer)
    if any(len(groups.get("application/vnd.cirruslabs.tart." + kind + ".v1", [])) != 1
           for kind in ("config", "nvram")):
        raise ValueError("OCI guest requires exactly one config and NVRAM")
    disk = groups.get("application/vnd.cirruslabs.tart.disk.v2", [])
    size = 0
    for layer in disk:
        annotations = layer["annotations"]
        unpacked = int(annotations["org.cirruslabs.tart.uncompressed-size"])
        digest = annotations["org.cirruslabs.tart.uncompressed-content-digest"]
        if not 0 < unpacked <= 536870912 or not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
            raise ValueError("uncompressed OCI layer exceeds budget or lacks digest")
        size += unpacked
    if not 1_000_000 < size <= 64 * 1024 ** 3:
        raise ValueError("OCI guest disk exceeds budget")
    if size != int(manifest["annotations"]["org.cirruslabs.tart.uncompressed-disk-size"]):
        raise ValueError("OCI disk size annotations disagree")
    return groups, size


class PublicRegistry:
    def __init__(self):
        self.lock = threading.Lock()
        self.token = ""
        self.expires = 0

    def authorization(self):
        with self.lock:
            if time.monotonic() >= self.expires:
                url = "https://ghcr.io/token?service=ghcr.io&scope=" + urllib.parse.quote("repository:" + REPO + ":pull")
                with urllib.request.urlopen(url, timeout=30) as response:
                    data = response.read(65536)
                value = json.loads(data)
                self.token = value["token"]
                self.expires = time.monotonic() + min(300, int(value.get("expires_in", 300)) * 0.8)
            return "Bearer " + self.token

    def request(self, path, start=None, end=None):
        headers = {"Authorization": self.authorization(), "Accept": "application/vnd.oci.image.manifest.v1+json"}
        if start is not None:
            headers["Range"] = f"bytes={start}-{end}"
        return urllib.request.Request("https://ghcr.io/v2/" + REPO + "/" + path, headers=headers)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--concurrency", type=int, default=16, choices=(8, 16, 32))
    args = parser.parse_args()
    DIRECTORY.mkdir(parents=True, exist_ok=True, mode=0o700)
    tool = ROOT / "tools/tart.app/Contents/MacOS/tart"
    subprocess.run(["codesign", "--verify", "--strict", str(tool.parents[2])], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    signature = subprocess.run(["codesign", "-dv", "--verbose=2", str(tool.parents[2])],
                               capture_output=True).stderr.decode()
    if "TeamIdentifier=9M2P8L4D89" not in signature:
        raise ValueError("Tart signer changed")
    guest = ROOT / "vms/vms" / NAME
    if guest.exists():
        raise ValueError("owned guest already exists; do not overwrite it")
    registry = PublicRegistry()
    with urllib.request.urlopen(registry.request("manifests/sha256:" + MANIFEST_SHA), timeout=30) as response:
        data = response.read(1048576)
    if hashlib.sha256(data).hexdigest() != MANIFEST_SHA:
        raise ValueError("official OCI manifest did not match the pinned digest")
    manifest = json.loads(data)
    groups, disk_size = validate_manifest(manifest)
    (DIRECTORY / "manifest.json").write_bytes(data)
    progress_path = DIRECTORY / "progress.json"
    progress = json.loads(progress_path.read_text()) if progress_path.exists() else {
        "manifestSHA256": MANIFEST_SHA, "segments": {}, "verifiedLayers": {}, "complete": False}
    if progress["manifestSHA256"] != MANIFEST_SHA:
        raise ValueError("preserved OCI download belongs to another manifest")
    disk_path = DIRECTORY / "disk.img"
    disk = os.open(disk_path, os.O_RDWR | os.O_CREAT, 0o600)
    os.ftruncate(disk, disk_size)
    os.close(disk)
    unpacker = ROOT / "tools/unpack-oci-layer"
    source = Path(__file__).with_name("unpack_oci_layer.swift")
    subprocess.run(["swiftc", str(source), "-o", str(unpacker)], check=True)
    lock = threading.Lock()
    started = time.monotonic()
    done_bytes = 0
    completed_segments = 0

    def save():
        temporary = progress_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(progress, indent=2))
        temporary.chmod(0o600)
        temporary.replace(progress_path)

    disk_layers = groups["application/vnd.cirruslabs.tart.disk.v2"]
    pending = []
    offset = 0
    for index, layer in enumerate(disk_layers):
        length = int(layer["annotations"]["org.cirruslabs.tart.uncompressed-size"])
        expected = layer["annotations"]["org.cirruslabs.tart.uncompressed-content-digest"].split(":")[1]
        if hash_file(disk_path, offset, length) == expected:
            progress["verifiedLayers"][str(index)] = expected
        else:
            progress["verifiedLayers"].pop(str(index), None)
            pending.append((index, layer, offset, length, expected))
        offset += length
    save()
    print(json.dumps({"phase": "oci-checkpoint", "verifiedLayers": len(progress["verifiedLayers"]),
                      "diskLayers": len(disk_layers), "compressedGiB": round(sum(x["size"] for x in manifest["layers"]) / 1073741824, 2)}), flush=True)

    def fetch_segment(layer, path, index):
        nonlocal done_bytes, completed_segments
        start = index * SEGMENT
        end = min(layer["size"], start + SEGMENT)
        digest_key = layer["digest"].split(":")[1]
        prior = progress["segments"].get(digest_key, {}).get(str(index))
        if prior and path.exists() and hash_file(path, start, end - start) == prior:
            return
        for attempt in range(3):
            try:
                request = registry.request("blobs/" + layer["digest"], start, end - 1)
                with urllib.request.urlopen(request, timeout=60) as response:
                    if response.status != 206 or response.headers.get("Content-Range") != f"bytes {start}-{end - 1}/{layer['size']}":
                        raise ValueError("OCI CDN returned an unexpected byte range")
                    descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
                    try:
                        digest = hashlib.sha256()
                        position = start
                        while position < end:
                            data = response.read(min(65536, end - position))
                            if not data:
                                raise EOFError("short OCI blob range")
                            os.pwrite(descriptor, data, position)
                            digest.update(data)
                            position += len(data)
                    finally:
                        os.close(descriptor)
                with lock:
                    progress["segments"].setdefault(digest_key, {})[str(index)] = digest.hexdigest()
                    done_bytes += end - start
                    completed_segments += 1
                    progress["elapsedSeconds"] = round(time.monotonic() - started, 1)
                    save()
                    if completed_segments % 16 == 0:
                        print(json.dumps({"phase": "oci-download", "completedSegments": completed_segments,
                                          "verifiedLayers": len(progress["verifiedLayers"]),
                                          "downloadMiB": round(done_bytes / 1048576),
                                          "elapsedSeconds": progress["elapsedSeconds"]}), flush=True)
                return
            except (OSError, EOFError):
                if attempt == 2:
                    raise
                time.sleep(1 + attempt)

    jobs = []
    for index, layer, offset, length, expected in pending:
        path = DIRECTORY / (layer["digest"].split(":")[1] + ".blob")
        for segment in range((layer["size"] + SEGMENT - 1) // SEGMENT):
            jobs.append((layer, path, segment))
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        futures = [executor.submit(fetch_segment, *job) for job in jobs]
        for future in concurrent.futures.as_completed(futures):
            future.result()
    # Decompression is separate from networking: at most one 4 MiB output
    # buffer is active and completed compressed checkpoints remain reusable.
    for index, layer, offset, length, expected in pending:
        path = DIRECTORY / (layer["digest"].split(":")[1] + ".blob")
        if path.stat().st_size != layer["size"] or hash_file(path) != layer["digest"].split(":")[1]:
            raise ValueError("compressed OCI blob hash mismatch")
        subprocess.run([str(unpacker), str(path.resolve()), str(disk_path.resolve()),
                        str(offset), str(length), expected], check=True,
                       stdout=subprocess.DEVNULL, timeout=120)
        progress["verifiedLayers"][str(index)] = expected
        save()
    for kind, filename in (("config", "config.json"), ("nvram", "nvram.bin")):
        layer = groups["application/vnd.cirruslabs.tart." + kind + ".v1"][0]
        target = DIRECTORY / filename
        if target.exists() and target.stat().st_size == layer["size"] and hash_file(target) == layer["digest"].split(":")[1]:
            continue
        partial = target.with_suffix(".partial")
        digest = hashlib.sha256()
        total = 0
        with urllib.request.urlopen(registry.request("blobs/" + layer["digest"]), timeout=60) as response, partial.open("wb") as file:
            while content := response.read(65536):
                total += len(content)
                if total > layer["size"]:
                    raise ValueError("guest metadata exceeded the pinned length")
                digest.update(content)
                file.write(content)
        if total != layer["size"] or digest.hexdigest() != layer["digest"].split(":")[1]:
            raise ValueError("guest configuration digest mismatch")
        partial.chmod(0o600)
        partial.replace(target)
    config = json.loads((DIRECTORY / "config.json").read_text())
    if config.get("os", "darwin") != "darwin" or config.get("arch", "arm64") != "arm64" or config.get("diskFormat", "raw") != "raw":
        raise ValueError("OCI image is not a raw Apple Silicon macOS guest")
    guest.parent.mkdir(parents=True, exist_ok=True)
    guest.mkdir(mode=0o700)
    for filename in ("config.json", "nvram.bin", "disk.img", "manifest.json"):
        (DIRECTORY / filename).replace(guest / filename)
    env = os.environ.copy()
    env.update(TART_HOME=str(ROOT / "vms"), TART_NO_AUTO_PRUNE="1")
    subprocess.run([str(tool), "set", NAME, "--cpu", "4", "--memory", "6144",
                    "--display", "1440x900px", "--no-display-refit", "--random-mac", "--random-serial"], env=env, check=True)
    meta = {"created": True, "name": NAME, "source": "ghcr.io/" + REPO + "@sha256:" + MANIFEST_SHA,
            "tool": str(tool.resolve()), "home": str((ROOT / "vms").resolve()),
            "cpu": 4, "memoryMiB": 6144, "diskGiB": 50, "osMajor": 14, "autoPrune": False}
    for filename in ("guest.json", "guest-created.json"):
        path = ROOT / filename
        path.write_text(json.dumps(meta, indent=2))
        path.chmod(0o600)
    progress["complete"] = True
    save()
    print(json.dumps({"phase": "owned-guest-created", "metadata": str(ROOT / "guest-created.json")}), flush=True)


if __name__ == "__main__":
    main()
