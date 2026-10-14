#!/usr/bin/env python3
"""Owned guest localhost:4443 -> owned localhost ocserv through virtio-vsock.

Opaque frames are multiplexed over supported Tart exec stdin/stdout. No SSH,
host route, VPN command, TLS termination or raw wire logging. Max eight peers,
64KiB frames, bounded queues and three-hour process lifetime.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import selectors
import signal
import shlex
import socket
import struct
import subprocess
import time

HERE = Path(__file__).resolve().parent
MAX_FRAME = 65536
MAX_BUFFER = MAX_FRAME * 16


def read_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def frame(kind, identifier, data=b""):
    if (kind not in (1, 2, 3, 4) or not 0 <= identifier <= 1000000
            or len(data) > MAX_FRAME or (kind in (1, 3, 4) and data)
            or (kind == 4) != (identifier == 0)):
        raise ValueError("invalid or oversized opaque guest TCP frame")
    return struct.pack(">BII", kind, identifier, len(data)) + data


def parse(buffer):
    if len(buffer) < 9:
        return None
    kind, identifier, length = struct.unpack(">BII", buffer[:9])
    # Validate the header BEFORE waiting for any oversized payload.
    frame(kind, identifier, b"" if not length else bytes(min(length, MAX_FRAME + 1)))
    if len(buffer) < 9 + length:
        return None
    data = bytes(buffer[9:9 + length])
    del buffer[:9 + length]
    return kind, identifier, data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True)
    parser.add_argument("--guest-interface", action="store_true")
    args = parser.parse_args()
    lab_module = read_module("lab", "lab.py")
    guest = read_module("guest", "guest_command.py")
    lab = lab_module.Lab(args.state)
    lab.invariants()
    port = lab.manifest["port"]
    if not isinstance(port, int) or not 1024 <= port <= 65535 or not lab.health():
        raise ValueError("owned loopback lab server is not healthy")
    code, output = guest.run("printf 'owned-guest-ready\\n'\n", timeout=15)
    if code or output.strip() != "owned-guest-ready":
        raise ValueError("guest ownership check did not pass")
    command, env, guard = guest.vsock_base()
    runtime = json.loads((guest.ROOT / "guest-runtime.json").read_text())
    mux = "exec /Users/admin/NoSleepLab/guest-tcp-mux --owner-mac " + shlex.quote(runtime["mac"])
    if args.guest_interface:
        mux += " --guest-interface"
    command += ["/bin/bash", "-c", guard + mux + "\n"]
    process = subprocess.Popen(command, env=env, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               start_new_session=True)
    selector = selectors.DefaultSelector()
    for file in (process.stdin, process.stdout):
        os.set_blocking(file.fileno(), False)
    selector.register(process.stdout, selectors.EVENT_READ, "guest")
    channels = {}
    incoming, outgoing = bytearray(), bytearray()
    running, ready = True, False
    deadline = time.monotonic() + 3 * 3600
    ready_deadline = time.monotonic() + 20

    def stop(*_):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    def close(identifier, notify=False):
        channel = channels.pop(identifier, None)
        if channel:
            selector.unregister(channel["socket"])
            channel["socket"].close()
        if notify:
            outgoing.extend(frame(3, identifier))

    try:
        while running and time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError("owned guest forwarding process stopped")
            if not ready and time.monotonic() > ready_deadline:
                raise TimeoutError("guest localhost forwarding did not become ready")
            if len(outgoing) > MAX_BUFFER or len(incoming) > MAX_BUFFER:
                raise ValueError("guest forward queue exceeds budget")
            try:
                if outgoing:
                    selector.modify(process.stdin, selectors.EVENT_WRITE, "input")
                else:
                    selector.unregister(process.stdin)
            except KeyError:
                if outgoing:
                    selector.register(process.stdin, selectors.EVENT_WRITE, "input")
            for key, events in selector.select(0.5):
                if key.data == "input":
                    count = os.write(process.stdin.fileno(), outgoing[:MAX_FRAME])
                    del outgoing[:count]
                elif key.data == "guest":
                    data = os.read(process.stdout.fileno(), MAX_FRAME)
                    if not data:
                        raise EOFError("owned guest forwarding stream closed")
                    incoming.extend(data)
                    while (item := parse(incoming)) is not None:
                        kind, identifier, payload = item
                        if kind == 4:
                            ready = True
                            state = {"pid": os.getpid(), "rpcPID": process.pid,
                                     "run": lab.manifest["run"], "guestPort": 4443,
                                     "hostPort": port, "bind": "owned-guest-en0" if args.guest_interface else "127.0.0.1",
                                     "transport": "owned-virtio-vsock", "started": time.time()}
                            path = guest.ROOT / "guest-forward.json"
                            path.write_text(json.dumps(state, indent=2)); path.chmod(0o600)
                            print(json.dumps({"guestLocalhostForwardReady": True,
                                              "privateState": str(path)}), flush=True)
                        elif kind == 1:
                            if identifier in channels or len(channels) >= 8:
                                raise ValueError("guest forward peer limit exceeded")
                            client = socket.create_connection(("127.0.0.1", port), timeout=5)
                            if client.getpeername() != ("127.0.0.1", port):
                                client.close(); raise ValueError("forwarded server is not owned loopback")
                            client.setblocking(False)
                            channels[identifier] = {"socket": client, "output": bytearray()}
                            selector.register(client, selectors.EVENT_READ, identifier)
                        elif kind == 3:
                            close(identifier)
                        elif identifier in channels:
                            queue = channels[identifier]["output"]
                            queue.extend(payload)
                            if len(queue) > MAX_BUFFER:
                                raise ValueError("guest peer output exceeds budget")
                            selector.modify(channels[identifier]["socket"], selectors.EVENT_READ | selectors.EVENT_WRITE, identifier)
                else:
                    identifier = key.data
                    channel = channels.get(identifier)
                    if not channel:
                        continue
                    try:
                        if events & selectors.EVENT_READ:
                            data = channel["socket"].recv(MAX_FRAME)
                            if not data:
                                close(identifier, notify=True); continue
                            outgoing.extend(frame(2, identifier, data))
                        if events & selectors.EVENT_WRITE:
                            count = channel["socket"].send(channel["output"][:MAX_FRAME])
                            del channel["output"][:count]
                            if not channel["output"]:
                                selector.modify(channel["socket"], selectors.EVENT_READ, identifier)
                    except (ConnectionError, OSError):
                        close(identifier, notify=True)
    finally:
        for identifier in list(channels):
            close(identifier)
        selector.close()
        process.stdin.close()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait(timeout=3)


if __name__ == "__main__":
    main()
