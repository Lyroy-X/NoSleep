#!/usr/bin/env python3
"""Run a bounded command only in the owned, host-only Tart guest.

The public throwaway guest account is admin/admin. Before every remote
command, require VirtualMac hardware and the random MAC address of this
specific guest. Never use the host Keychain, host account, or its password.
"""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import selectors
import shlex
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2] / "build" / "vpn-lab"
NAME = "nosleep-vpn-lab-20261012"


def owned(path):
    path = Path(path).resolve()
    if not path.is_relative_to(ROOT.resolve()):
        raise ValueError("guest artifact must belong to build/vpn-lab")
    return path


def identity():
    meta = json.loads((ROOT / "guest-created.json").read_text())
    home = ROOT.resolve() / "vms"
    tool = ROOT.resolve() / "tools/tart.app/Contents/MacOS/tart"
    if (meta.get("name") != NAME or Path(meta["home"]).resolve() != home
            or Path(meta["tool"]).resolve() != tool):
        raise ValueError("metadata does not identify the owned NoSleep guest")
    config = json.loads((home / "vms" / NAME / "config.json").read_text())
    mac = config["macAddress"].lower()
    if not re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", mac):
        raise ValueError("invalid guest MAC address")
    vnc = json.loads((ROOT / "guest-runtime.json").read_text())
    command = subprocess.check_output(["ps", "-p", str(vnc["pid"]), "-o", "command="], text=True)
    if NAME not in command or str(tool) not in command or "--net-host" not in command:
        raise ValueError("guest is not running with the approved host-only network")
    env = os.environ.copy()
    env.update(TART_HOME=str(home), TART_NO_AUTO_PRUNE="1")
    ip = subprocess.check_output([str(tool), "ip", NAME], env=env, text=True, timeout=10).strip()
    address = ipaddress.ip_address(ip)
    if (address.version != 4 or not address.is_private or address.is_loopback
            or address.is_link_local or address.is_unspecified):
        raise ValueError("Tart did not identify a private guest IPv4 endpoint")
    return str(address), mac


def ssh_base():
    # A corporate scoped route can point the private guest IP at another SSH
    # endpoint. Never authenticate over an unbound socket, enable legacy KEX,
    # or fall back from the isolated transport to a normal host route.
    raise ValueError("IP-based SSH is disabled; use the owned virtio-vsock RPC channel")


def vsock_base():
    meta = json.loads((ROOT / "guest-created.json").read_text())
    home = ROOT.resolve() / "vms"
    tool = ROOT.resolve() / "tools/tart.app/Contents/MacOS/tart"
    if (meta.get("name") != NAME or Path(meta["home"]).resolve() != home
            or Path(meta["tool"]).resolve() != tool):
        raise ValueError("metadata does not identify the owned NoSleep guest")
    runtime = json.loads((ROOT / "guest-runtime.json").read_text())
    command = subprocess.check_output(["ps", "-p", str(runtime["pid"]), "-o", "command="], text=True)
    if (NAME not in command or str(tool) not in command or "--net-host" not in command
            or runtime.get("network") != "host-only" or runtime.get("name") != NAME):
        raise ValueError("guest is not running with the approved host-only network")
    config = json.loads((home / "vms" / NAME / "config.json").read_text())
    mac = config["macAddress"].lower()
    if runtime.get("mac") != mac:
        raise ValueError("owned guest runtime MAC does not match configuration")
    control = home / "vms" / NAME / "control.sock"
    if (not control.is_socket() or control.stat().st_uid != os.getuid()):
        raise ValueError("owned guest control socket is unavailable")
    env = os.environ.copy()
    env.update(TART_HOME=str(home), TART_NO_AUTO_PRUNE="1")
    # No username, password, host key, IP address or host route is used.
    return [str(tool), "exec", "-i", NAME], env, remote_guard(mac)


def remote_guard(mac):
    if not re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", mac):
        raise ValueError("invalid owned guest MAC")
    return ("case $(/usr/sbin/sysctl -n hw.model) in VirtualMac*) ;; *) exit 64 ;; esac\n"
            "task_lab_mac=$(/sbin/ifconfig en0 | /usr/bin/awk '/ether / {print $2}')\n"
            "test \"$task_lab_mac\" = " + shlex.quote(mac) + " || exit 65\n")


def run(script, timeout=60, output_limit=262144):
    if len(script.encode()) > 65536 or not 1 <= timeout <= 600:
        raise ValueError("guest command exceeds input or time budget")
    command, env, guard = vsock_base()
    process = subprocess.Popen(command + ["/bin/bash", "-s"], env=env,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=True)
    process.stdin.write((guard + script).encode())
    process.stdin.close()
    tail = bytearray()
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    try:
        while selector.get_map():
            if time.monotonic() >= deadline:
                raise TimeoutError("isolated guest command exceeded deadline")
            for key, _ in selector.select(min(1, deadline - time.monotonic())):
                chunk = os.read(key.fileobj.fileno(), 4096)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                tail.extend(chunk)
                if len(tail) > output_limit:
                    del tail[:-output_limit]
        code = process.wait(timeout=max(0.1, deadline - time.monotonic()))
    finally:
        selector.close()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
    return code, tail.decode(errors="replace")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--script", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--timeout", type=int, default=60)
    args = parser.parse_args()
    path = owned(args.script)
    if path.stat().st_size > 65536:
        raise ValueError("guest script exceeds budget")
    code, output = run(path.read_text(), timeout=args.timeout)
    destination = owned(args.out)
    destination.write_text(output)
    destination.chmod(0o600)
    print(json.dumps({"guestCommandExit": code, "privateOutput": str(destination)}))
    raise SystemExit(code)


if __name__ == "__main__":
    main()
