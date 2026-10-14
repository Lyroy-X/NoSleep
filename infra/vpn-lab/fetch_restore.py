#!/usr/bin/env python3
"""Resume an official Apple restore image download with bounded parallel I/O.

Only HTTPS URLs from Apple's restore catalog/CDN are accepted. Each chunk is
range-checked, hashed and recorded atomically; existing chunks are rehashed
before reuse. The Apple Virtualization framework separately verifies the
restore image when installing it. No host software or network is changed.
"""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import threading
import time
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[2] / "build" / "vpn-lab"
CATALOG = "https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml"
CHUNK = 128 * 1024 * 1024


def candidates(value, path=()):
    if isinstance(value, dict):
        if any(str(part).startswith("VirtualMac") for part in path) and "Restore" in value:
            yield value["Restore"]
        for key, child in value.items():
            yield from candidates(child, (*path, key))
    elif isinstance(value, list):
        for i, child in enumerate(value):
            yield from candidates(child, (*path, i))


def main():
    import plistlib
    ROOT.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(CATALOG, timeout=30) as response:
        catalog_bytes = response.read(1048576)
    catalog = plistlib.loads(catalog_bytes)
    restore = max(candidates(catalog), key=lambda entry: tuple(
        int(v) for v in entry["ProductVersion"].split(".")))
    url = restore["FirmwareURL"]
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != "updates.cdn-apple.com":
        raise ValueError("restore image is not on the official HTTPS Apple CDN")
    name = parsed.path.rsplit("/", 1)[1]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+\.ipsw", name):
        raise ValueError("unsafe restore image filename")
    with urllib.request.urlopen(urllib.request.Request(url, headers={"Range": "bytes=0-0"}), timeout=30) as response:
        content_range = response.headers.get("Content-Range", "")
        match = re.fullmatch(r"bytes 0-0/(\d+)", content_range)
        if response.status != 206 or not match:
            raise ValueError("Apple CDN did not honor a byte range")
        size = int(match[1])
    if not 1_000_000 < size < 64 * 1024 ** 3:
        raise ValueError("restore image size exceeds budget")
    progress_path = ROOT / "restore-download-progress.json"
    if progress_path.exists():
        progress = json.loads(progress_path.read_text())
        if progress["url"] != url or progress["size"] != size:
            raise ValueError("catalog changed; keep the old download and select a new run explicitly")
    else:
        progress = {"url": url, "size": size, "chunks": {}, "version": restore["ProductVersion"],
                    "catalogSHA256": hashlib.sha256(catalog_bytes).hexdigest()}
    destination = ROOT / name
    partial = ROOT / (name + ".partial")
    if destination.exists():
        if destination.stat().st_size != size:
            raise ValueError("finished restore image has an invalid length")
        print(json.dumps({"image": str(destination), "complete": True, "version": restore["ProductVersion"]}))
        return
    file = os.open(partial, os.O_RDWR | os.O_CREAT, 0o600)
    os.ftruncate(file, size)
    lock = threading.Lock()
    started = time.monotonic()
    count = (size + CHUNK - 1) // CHUNK

    def save():
        temporary = progress_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(progress, indent=2))
        os.chmod(temporary, 0o600)
        temporary.replace(progress_path)

    def get_chunk(index):
        start = index * CHUNK
        end = min(size, start + CHUNK)
        prior = progress["chunks"].get(str(index))
        if prior:
            digest = hashlib.sha256()
            position = start
            while position < end:
                data = os.pread(file, min(1024 * 1024, end - position), position)
                if not data:
                    break
                digest.update(data)
                position += len(data)
            if position == end and digest.hexdigest() == prior:
                return
        expected_range = f"bytes {start}-{end - 1}/{size}"
        for attempt in range(3):
            try:
                request = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end - 1}"})
                with urllib.request.urlopen(request, timeout=60) as response:
                    if response.status != 206 or response.headers.get("Content-Range") != expected_range:
                        raise ValueError("restore chunk returned an unexpected byte range")
                    digest = hashlib.sha256()
                    position = start
                    while position < end:
                        data = response.read(min(65536, end - position))
                        if not data:
                            raise EOFError("short Apple restore chunk")
                        os.pwrite(file, data, position)
                        digest.update(data)
                        position += len(data)
                with lock:
                    progress["chunks"][str(index)] = digest.hexdigest()
                    progress["elapsedSeconds"] = round(time.monotonic() - started, 1)
                    save()
                    if len(progress["chunks"]) % 8 == 0 or len(progress["chunks"]) == count:
                        print(json.dumps({"chunksDone": len(progress["chunks"]), "chunksTotal": count,
                                          "elapsedSeconds": progress["elapsedSeconds"]}), flush=True)
                return
            except (OSError, EOFError) as error:
                if attempt == 2:
                    raise
                time.sleep(1 + attempt)
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            list(executor.map(get_chunk, range(count)))
        os.fsync(file)
    finally:
        os.close(file)
    partial.replace(destination)
    digest = hashlib.sha256()
    with destination.open("rb") as stream:
        while data := stream.read(1024 * 1024):
            digest.update(data)
    progress["imageSHA256"] = digest.hexdigest()
    progress["complete"] = True
    save()
    print(json.dumps({"image": str(destination), "complete": True,
                      "version": restore["ProductVersion"], "sha256": progress["imageSHA256"]}))


if __name__ == "__main__":
    main()
