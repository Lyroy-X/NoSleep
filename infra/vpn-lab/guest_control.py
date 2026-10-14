#!/usr/bin/env python3
"""Keep one VNC connection to the owned guest and expose bounded local commands.

Repeated connections trigger an assertion in Apple's experimental VM VNC
backend on the tested host build. This private Unix socket keeps the actual
guest-screen connection open. No host window, clipboard or screen API is used.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import struct
import time

from guest_screen import Screen, owned


def message(connection, timeout=30):
    deadline = time.monotonic() + timeout

    def receive(length):
        result = bytearray()
        while len(result) < length:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("guest control request exceeded deadline")
            connection.settimeout(remaining)
            chunk = connection.recv(length - len(result))
            if not chunk:
                raise EOFError("short guest control request")
            result.extend(chunk)
        return bytes(result)

    length = struct.unpack(">I", receive(4))[0]
    if not 0 < length <= 65536:
        raise ValueError("guest control JSON exceeds budget")
    return json.loads(receive(length))


def send(connection, value):
    data = json.dumps(value).encode()
    if len(data) > 65536:
        raise ValueError("guest control response exceeds budget")
    connection.sendall(struct.pack(">I", len(data)) + data)


def serve(state, path):
    path = owned(path)
    if len(os.fsencode(path)) > 100 or path.exists():
        raise ValueError("guest control path is long or already exists")
    screen = Screen(state)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(path))
    path.chmod(0o600)
    server.listen(4)
    server.settimeout(1)
    running = True

    def stop(*_):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(json.dumps({"ownedGuestControlReady": True, "socket": str(path),
                      "pid": os.getpid(), "hostScreenUsed": False}), flush=True)
    deadline = time.monotonic() + 3 * 3600
    try:
        while running and time.monotonic() < deadline:
            try:
                connection, _ = server.accept()
            except socket.timeout:
                continue
            with connection:
                try:
                    request = message(connection)
                    action = request["action"]
                    if action == "screenshot":
                        result = screen.screenshot(request["out"])
                    elif action == "click":
                        screen.click(request["x"], request["y"])
                        result = {"guestClick": True}
                    elif action == "key":
                        screen.chord(request["keys"])
                        result = {"guestKeys": True}
                    elif action == "text":
                        screen.text(request["file"])
                        result = {"guestText": True}
                    elif action == "ping":
                        result = {"guestControl": True, "width": screen.width, "height": screen.height,
                                  "streamUsable": screen.usable,
                                  "recoveryRequired": not screen.usable}
                    elif action == "close":
                        running = False
                        result = {"guestControlClosed": True}
                    else:
                        raise ValueError("unsupported guest control action")
                    # A metadata ping may inspect a failed controller, but it
                    # must not report transport readiness for an unusable RFB.
                    send(connection, {"ok": action == "close" or screen.usable, **result})
                except Exception as error:
                    # Do not echo request text or a credential-bearing path.
                    send(connection, {"ok": False, "error": type(error).__name__,
                                      "streamUsable": screen.usable,
                                      "recoveryRequired": not screen.usable,
                                      "retryAllowed": False,
                                      "frameDiagnostics": screen.frame_diagnostics()})
    finally:
        server.close()
        screen.socket.close()
        path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["serve", "send"])
    parser.add_argument("--socket", required=True)
    parser.add_argument("--state")
    parser.add_argument("--action", choices=["screenshot", "click", "key", "text", "ping", "close"])
    parser.add_argument("--out")
    parser.add_argument("--x", type=int)
    parser.add_argument("--y", type=int)
    parser.add_argument("--keys")
    parser.add_argument("--from-file")
    args = parser.parse_args()
    if args.mode == "serve":
        serve(args.state, args.socket)
        return
    path = owned(args.socket)
    if not path.is_socket() or path.stat().st_uid != os.getuid() or path.stat().st_mode & 0o077:
        raise ValueError("guest control is not an owned private Unix socket")
    request = {"action": args.action, "out": args.out, "x": args.x, "y": args.y,
               "keys": args.keys, "file": args.from_file}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(30)
        connection.connect(str(path))
        send(connection, request)
        result = message(connection)
    print(json.dumps(result))
    if not result.get("ok"):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
