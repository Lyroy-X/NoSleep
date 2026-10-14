#!/usr/bin/env python3
"""Read/click/type only the owned localhost macOS guest's VNC screen.

This never captures or controls the host desktop. Text input is read from a
private file in build/vpn-lab (not from argv). The host working password and
clipboard are not used. RFB raw frames are bounded to six million pixels.
"""
import argparse
import hashlib
import json
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2] / "build" / "vpn-lab"


class RFBStreamUnusable(RuntimeError):
    """A failed/partial stream needs explicitly authorized replacement."""


def owned(path):
    path = Path(path).resolve()
    if not path.is_relative_to(ROOT.resolve()):
        raise ValueError("guest artifact must belong to build/vpn-lab")
    return path


class Screen:
    def __init__(self, state, *, pixel_bits=16):
        # Fixed RFC 6143 true-color formats only. RGB565 halves a full Raw
        # frame's wire payload; BGRX remains an explicit compatibility option.
        if type(pixel_bits) is not int or pixel_bits not in (16, 32):
            raise ValueError("unsupported guest RFB pixel format")
        self.bytes_per_pixel = pixel_bits // 8
        self.raw_pixel_mode = "BGR;16" if pixel_bits == 16 else "BGRX"
        self.usable = True
        self._frame_diagnostics = None
        state = json.loads(owned(state).read_text())
        permitted_host = state["host"] == "127.0.0.1" or (
            state.get("mode") == "owned-networkless-console" and state["host"] == "::1")
        if not permitted_host or not 1024 <= state["port"] <= 65535:
            raise ValueError("only the owned localhost VNC endpoint is permitted")
        command = subprocess.check_output(["ps", "-p", str(state["pid"]), "-o", "command="], text=True)
        if state.get("mode") == "owned-guest-screen-sharing":
            relay = str(ROOT.resolve().parents[1] / "infra/vpn-lab/guest_vnc_relay.py")
            runtime = json.loads((ROOT / "guest-runtime.json").read_text())
            current = subprocess.check_output([
                "ps", "-p", str(runtime["pid"]), "-o", "command=",
            ], text=True)
            configured = json.loads((ROOT / "vms/vms/nosleep-vpn-lab-20261012/config.json").read_text())
            tool = str(ROOT / "tools/tart.app/Contents/MacOS/tart")
            if (state["name"] != "nosleep-vpn-lab-20261012" or relay not in command
                    or state.get("transport") != "owned-virtio-vsock"
                    or state.get("runtimePID") != runtime["pid"]
                    or state.get("mac") != runtime["mac"] or runtime["mac"] != configured["macAddress"].lower()
                    or runtime.get("network") != "host-only" or tool not in current
                    or state["name"] not in current or "--net-host" not in current or "--no-clipboard" not in current):
                raise ValueError("Screen Sharing relay does not belong to the owned isolated guest")
        elif state.get("mode") == "owned-networkless-console":
            helper = str(ROOT.resolve() / "tools/guest-console")
            images = subprocess.check_output([
                "lsof", "-a", "-p", str(state["pid"]), "-d", "txt", "-Fn",
            ], text=True)
            executables = {line[1:] for line in images.splitlines() if line.startswith("n")}
            if (state["name"] != "nosleep-vpn-lab-20261012" or helper not in executables
                    or str(ROOT.resolve() / "tools/guest-console-bind.dylib") not in executables
                    or state["name"] not in command or state.get("networkDevices") != 0):
                raise ValueError("VNC owner is not the networkless owned guest console")
        elif (state["name"] not in command or "tart" not in command
              or "--vnc-experimental" not in command or "--net-host" not in command):
            raise ValueError("VNC owner is not the isolated Tart lab guest")
        listeners = subprocess.check_output([
            "lsof", "-nP", "-a", "-p", str(state["pid"]),
            f"-iTCP:{state['port']}", "-sTCP:LISTEN", "-Fpn",
        ], text=True)
        if {line[1:] for line in listeners.splitlines() if line.startswith("p")} != {str(state["pid"])}:
            raise ValueError("VNC listener does not belong to the owned Tart process")
        endpoints = {line[1:] for line in listeners.splitlines() if line.startswith("n")}
        permitted = {f"127.0.0.1:{state['port']}", f"[::1]:{state['port']}"}
        if not endpoints or not endpoints.issubset(permitted):
            raise ValueError("guest VNC listener is not bound only to loopback")
        self.deadline = time.monotonic() + 20
        self.socket = socket.create_connection((state["host"], state["port"]), timeout=10)
        version = self.receive(12)
        if not version.startswith(b"RFB "):
            raise ValueError("unexpected VNC protocol")
        self.socket.sendall(b"RFB 003.008\n")
        security_count = self.receive(1)[0]
        security = self.receive(security_count)
        if state.get("mode") == "owned-guest-screen-sharing" and 30 in security:
            # Apple ARD user authentication, as specified by the primary
            # LibVNCClient HandleARDAuth implementation. Only the public
            # throwaway guest account is used, over the verified local relay.
            self.socket.sendall(b"\x1e")
            generator, key_length = struct.unpack(">HH", self.receive(4))
            if not 32 <= key_length <= 1024:
                raise ValueError("ARD authentication key exceeds bounds")
            modulus = int.from_bytes(self.receive(key_length), "big")
            peer = int.from_bytes(self.receive(key_length), "big")
            if not 2 <= generator < modulus or not 1 < peer < modulus - 1:
                raise ValueError("invalid ARD authentication parameters")
            private = secrets.randbelow(modulus - 3) + 2
            public = pow(generator, private, modulus).to_bytes(key_length, "big")
            shared = pow(peer, private, modulus).to_bytes(key_length, "big")
            key = hashlib.md5(shared, usedforsecurity=False).digest()
            username = state.get("username", "").encode()
            password = owned(state["passwordFile"]).read_text().strip().encode()
            if username != b"admin" or password != b"admin":
                raise ValueError("only the public throwaway guest account is permitted")
            plain = bytearray(secrets.token_bytes(128))
            plain[:len(username) + 1] = username + b"\0"
            plain[64:64 + len(password) + 1] = password + b"\0"
            from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
            encryptor = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
            self.socket.sendall(encryptor.update(bytes(plain)) + encryptor.finalize() + public)
            del plain, key, shared, private, username, password
        elif 2 in security and state.get("mode") != "owned-guest-screen-sharing":
            self.socket.sendall(b"\x02")
            challenge = self.receive(16)
            password = owned(state["passwordFile"]).read_text().strip().encode()[:8].ljust(8, b"\0")
            reverse = bytes(int(f"{byte:08b}"[::-1], 2) for byte in password)
            # TripleDES with an 8-byte key is DES, as required by VNC auth.
            from cryptography.hazmat.primitives.ciphers import Cipher, modes
            from cryptography.hazmat.decrepit.ciphers.algorithms import TripleDES
            cipher = Cipher(TripleDES(reverse * 3), modes.ECB()).encryptor()
            self.socket.sendall(cipher.update(challenge) + cipher.finalize())
            del password, reverse
        elif 1 in security and state.get("mode") != "owned-guest-screen-sharing":
            self.socket.sendall(b"\x01")
        else:
            raise ValueError("VNC server requires an unsupported authentication method")
        if struct.unpack(">I", self.receive(4))[0] != 0:
            raise ValueError("VNC authentication rejected")
        self.socket.sendall(b"\x01")  # shared connection: don't evict another lab viewer.
        self.width, self.height = struct.unpack(">HH", self.receive(4))
        self.receive(16)
        name_length = struct.unpack(">I", self.receive(4))[0]
        if name_length > 65536:
            raise ValueError("VNC name exceeds budget")
        self.receive(name_length)
        self.check_size()
        if pixel_bits == 16:
            pixel = struct.pack(">BBBBHHHBBB3x", 16, 16, 0, 1, 31, 63, 31, 11, 5, 0)
        else:
            pixel = struct.pack(">BBBBHHHBBB3x", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
        self.socket.sendall(b"\x00\x00\x00\x00" + pixel)
        # Apple's built-in VM VNC backend requires desktop-size capability.
        # Advertise only pseudo-encodings that we bound and parse below.
        encodings = (5, 0, -223, -308, -239, -232, -224)
        self.socket.sendall(struct.pack(">BBH", 2, 0, len(encodings))
                            + struct.pack(">" + "i" * len(encodings), *encodings))

    def check_size(self):
        if not 0 < self.width * self.height <= 6_000_000:
            raise ValueError("VNC frame exceeds pixel budget")

    def require_usable(self):
        if not self.usable:
            raise RFBStreamUnusable("guest RFB stream requires explicit recovery")

    def invalidate(self):
        self.usable = False
        try:
            self.socket.close()
        except OSError:
            pass

    def send_bytes(self, data):
        self.require_usable()
        try:
            self.socket.sendall(data)
        except OSError:
            self.invalidate()
            raise

    def frame_diagnostics(self):
        # An explicit whitelist; no wire bytes, strings supplied by the peer,
        # output/input paths, clipboard contents or exception messages.
        value = getattr(self, "_frame_diagnostics", None)
        return dict(value) if value is not None else None

    def frame_stage(self, stage):
        self._frame_diagnostics["stage"] = stage
        if stage in ("clipboardHeader", "clipboardDiscard"):
            # Do not expose clipboard length or partial-discard size.
            self._frame_diagnostics["receiveExpectedBytes"] = 0
            self._frame_diagnostics["receivePartialBytes"] = 0

    def receive(self, length):
        self.require_usable()
        try:
            if length > 24_000_000:
                raise ValueError("VNC message exceeds budget")
            diagnostics = getattr(self, "_frame_diagnostics", None)
            frame_receive = diagnostics is not None
            if diagnostics is not None and diagnostics["stage"] in ("clipboardHeader", "clipboardDiscard"):
                diagnostics = None
            if diagnostics is not None:
                diagnostics["receiveExpectedBytes"] = length
                diagnostics["receivePartialBytes"] = 0
            output = bytearray()
            while len(output) < length:
                remaining = self.deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("guest VNC message exceeded deadline")
                # Frame reads share their original absolute 15-second budget.
                # A ten-second idle gap must not abort a still-admitted frame;
                # handshake reads retain their existing ten-second idle cap.
                self.socket.settimeout(remaining if frame_receive else min(10, remaining))
                part = self.socket.recv(min(65536, length - len(output)))
                if not part:
                    raise EOFError("guest VNC connection closed")
                output.extend(part)
                if getattr(self, "_frame_wire_bytes", None) is not None:
                    self._frame_wire_bytes += len(part)
                    if self._frame_wire_bytes > 48 * 1024 * 1024:
                        raise ValueError("VNC frame exceeds encoded byte budget")
                if diagnostics is not None:
                    diagnostics["receivePartialBytes"] = len(output)
                    size = diagnostics["receivedBytes"] + len(part)
                    diagnostics["receivedBytes"] = min(size, 96 * 1024 * 1024)
                    diagnostics["byteCounterSaturated"] |= size > 96 * 1024 * 1024
            return bytes(output)
        except (OSError, EOFError, ValueError):
            # No resumable parser state is retained after a partial read.
            self.invalidate()
            raise

    def screenshot(self, destination):
        self.require_usable()
        destination = owned(destination)
        self._frame_wire_bytes = 0
        self._frame_diagnostics = {"stage": "request", "messageKind": None,
                                   "declaredRectangleCount": 0, "parsedRectangleCount": 0,
                                   "rawPixels": 0, "coveredPixels": 0,
                                   "hextilePixels": 0, "hextileTiles": 0,
                                   "lastPixelEncoding": None,
                                   "canvasPixels": self.width * self.height,
                                   "receivedBytes": 0, "receiveExpectedBytes": 0,
                                   "receivePartialBytes": 0, "byteCounterSaturated": False,
                                   "complete": False}
        try:
            return self.read_frame(destination)
        except Exception:
            # Conservatively close on any frame failure, including a timeout
            # after part of a header/payload. Never treat a later read as a
            # fresh message, and never reuse this stream for keyboard/mouse.
            self.invalidate()
            raise

    def read_color(self):
        pixel = self.receive(self.bytes_per_pixel)
        if self.bytes_per_pixel == 2:
            value = int.from_bytes(pixel, "little")
            return ((value >> 11) * 255 // 31,
                    ((value >> 5) & 63) * 255 // 63,
                    (value & 31) * 255 // 31)
        return (pixel[2], pixel[1], pixel[0])

    def read_hextile(self, width, height):
        """RFC 6143 7.7.4; colors are scoped to this fresh rectangle.

        Reserved mask bits are conservatively refused. Raw ignores every
        other defined bit; it invalidates both carried colors. No previous
        screenshot supplies pixels or color state.
        """
        from PIL import Image
        image = Image.new("RGB", (width, height))
        background = foreground = None
        for y in range(0, height, 16):
            for x in range(0, width, 16):
                if time.monotonic() >= self.deadline:
                    raise TimeoutError("guest frame exceeds time budget")
                tw, th = min(16, width - x), min(16, height - y)
                self.frame_stage("hextileTile")
                flags = self.receive(1)[0]
                if flags & ~31:
                    raise ValueError("reserved Hextile mask bits")
                self._frame_diagnostics["hextileTiles"] += 1
                if flags & 1:
                    self.frame_stage("hextileRaw")
                    pixels = self.receive(tw * th * self.bytes_per_pixel)
                    image.paste(Image.frombytes("RGB", (tw, th), pixels, "raw", self.raw_pixel_mode), (x, y))
                    self._frame_diagnostics["rawPixels"] += tw * th
                    background = foreground = None
                    continue
                if flags & 4 and flags & 16:
                    raise ValueError("conflicting Hextile foreground flags")
                if flags & 2:
                    self.frame_stage("hextileBackground")
                    background = self.read_color()
                if background is None:
                    raise ValueError("missing Hextile background")
                if flags & 4:
                    self.frame_stage("hextileForeground")
                    foreground = self.read_color()
                image.paste(background, (x, y, x + tw, y + th))
                if flags & 8:
                    self.frame_stage("hextileSubrectHeader")
                    count = self.receive(1)[0]
                    if count and not flags & 16 and foreground is None:
                        raise ValueError("missing Hextile foreground")
                    for _ in range(count):
                        if time.monotonic() >= self.deadline:
                            raise TimeoutError("guest frame exceeds time budget")
                        self.frame_stage("hextileSubrect")
                        color = foreground
                        if flags & 16:
                            color = self.read_color()
                        position, size = self.receive(2)
                        sx, sy = position >> 4, position & 15
                        sw, sh = (size >> 4) + 1, (size & 15) + 1
                        if sx + sw > tw or sy + sh > th:
                            raise ValueError("Hextile subrectangle outside tile")
                        image.paste(color, (x + sx, y + sy, x + sx + sw, y + sy + sh))
                if flags & 16:
                    foreground = None
        return image

    def read_frame(self, destination):
        from PIL import Image
        self.send_bytes(struct.pack(">BBHHHH", 3, 0, 0, 0, self.width, self.height))
        canvas = Image.new("RGB", (self.width, self.height))
        coverage = bytearray(self.width * self.height)
        covered_pixels = 0
        total_pixels = 0
        total_rectangles = 0
        deadline = time.monotonic() + 15
        self.deadline = deadline
        while time.monotonic() < deadline:
            self.frame_stage("messageKind")
            kind = self.receive(1)[0]
            self._frame_diagnostics["messageKind"] = kind
            if kind == 0:
                self.frame_stage("updateHeader")
                self.receive(1)
                count = struct.unpack(">H", self.receive(2))[0]
                total_rectangles += count
                self._frame_diagnostics["declaredRectangleCount"] = total_rectangles
                if total_rectangles > 4096:
                    raise ValueError("VNC rectangle count exceeds budget")
                for _ in range(count):
                    if time.monotonic() >= deadline:
                        raise TimeoutError("guest frame exceeds time budget")
                    self.frame_stage("rectangleHeader")
                    x, y, width, height, encoding = struct.unpack(">HHHHi", self.receive(12))
                    self._frame_diagnostics["parsedRectangleCount"] += 1
                    if encoding == -224:  # LastRect: no pixel payload.
                        break
                    if encoding in (-223, -308):  # DesktopSize / ExtendedDesktopSize
                        if encoding == -308:
                            self.frame_stage("resizeMetadata")
                            displays = self.receive(4)[0]
                            if displays > 16:
                                raise ValueError("VNC display count exceeds budget")
                            self.receive(displays * 16)
                        self.width, self.height = width, height
                        self.check_size()
                        canvas = Image.new("RGB", (width, height))
                        coverage = bytearray(width * height)
                        covered_pixels = 0
                        self._frame_diagnostics["canvasPixels"] = width * height
                        self._frame_diagnostics["coveredPixels"] = 0
                        continue
                    if encoding == -232:  # PointerPosition
                        continue
                    if encoding == -239:  # RichCursor (not included in screen capture)
                        if width * height > 65536:
                            raise ValueError("VNC cursor exceeds budget")
                        self.frame_stage("cursorPayload")
                        self.receive(width * height * self.bytes_per_pixel + ((width + 7) // 8) * height)
                        continue
                    if (encoding not in (0, 5) or not width or not height
                            or x + width > self.width or y + height > self.height):
                        raise ValueError("unsupported VNC rectangle")
                    total_pixels += width * height
                    self._frame_diagnostics["lastPixelEncoding"] = encoding
                    if total_pixels > min(6_000_000, self.width * self.height * 4):
                        raise ValueError("VNC update exceeds aggregate pixel budget")
                    if encoding == 0:
                        self._frame_diagnostics["rawPixels"] += width * height
                        self.frame_stage("rawPayload")
                        pixels = self.receive(width * height * self.bytes_per_pixel)
                        decoded = Image.frombytes("RGB", (width, height), pixels, "raw", self.raw_pixel_mode)
                    else:
                        self._frame_diagnostics["hextilePixels"] += width * height
                        decoded = self.read_hextile(width, height)
                    canvas.paste(decoded, (x, y))
                    # A fresh full request may arrive as several updates.
                    # Prove the union of fully decoded rectangles covers the current
                    # entire canvas; pseudo-rectangles and old pixels cannot
                    # make an empty/partial screenshot look successful.
                    for row in range(y, y + height):
                        start = row * self.width + x
                        end = start + width
                        covered_pixels += coverage[start:end].count(0)
                        coverage[start:end] = b"\x01" * width
                    self._frame_diagnostics["coveredPixels"] = covered_pixels
                    self.frame_stage("coverage")
                if covered_pixels == self.width * self.height:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("guest frame exceeds time budget")
                    canvas.save(owned(destination))
                    self._frame_diagnostics["complete"] = True
                    self.frame_stage("complete")
                    return {"screenshot": str(owned(destination)), "width": self.width, "height": self.height}
                # Keep reading the same request within its original deadline,
                # without requerying or reusing a previous frame's canvas.
                continue
            if kind == 2:  # Bell
                continue
            if kind == 3:  # Clipboard notification: discard; never transfer clipboard.
                self.frame_stage("clipboardHeader")
                self.receive(3)
                length = struct.unpack(">I", self.receive(4))[0]
                if length > 65536:
                    raise ValueError("guest clipboard exceeds discard budget")
                self.frame_stage("clipboardDiscard")
                self.receive(length)
                continue
            raise ValueError("unsupported VNC message")
        raise TimeoutError("guest frame")

    def click(self, x, y):
        self.require_usable()
        if not 0 <= x < self.width or not 0 <= y < self.height:
            raise ValueError("click outside guest frame")
        for mask in (0, 1, 0):
            self.send_bytes(struct.pack(">BBHH", 5, mask, x, y))
            time.sleep(0.05)

    def key(self, code, down):
        self.send_bytes(struct.pack(">BBHI", 4, int(down), 0, code))

    def chord(self, keys):
        self.require_usable()
        table = {"enter": 0xff0d, "escape": 0xff1b, "tab": 0xff09, "space": 0x20,
                 "backspace": 0xff08, "delete": 0xffff, "shift": 0xffe1,
                 "ctrl": 0xffe3, "alt": 0xffe9, "cmd": 0xffe7,
                 "left": 0xff51, "up": 0xff52, "right": 0xff53, "down": 0xff54}
        codes = [table[k] if k in table else ord(k) if len(k) == 1 else None for k in keys.split("+")]
        if any(c is None for c in codes):
            raise ValueError("unsupported key chord")
        for code in codes:
            self.key(code, True)
        for code in reversed(codes):
            self.key(code, False)

    def text(self, path):
        self.require_usable()
        data = owned(path).read_text().rstrip("\n")
        if len(data) > 1024:
            raise ValueError("guest text exceeds input budget")
        for character in data:
            code = ord(character)
            if code < 0x20:
                raise ValueError("control characters are not text")
            if code > 0xff:
                code |= 0x01000000
            shifted = character.isascii() and (character.isupper()
                      or character in '~!@#$%^&*()_+{}|:"<>?')
            if shifted:
                self.key(0xffe1, True)
            self.key(code, True)
            self.key(code, False)
            if shifted:
                self.key(0xffe1, False)
            time.sleep(0.005)
        del data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["screenshot", "click", "key", "text"])
    parser.add_argument("--state", required=True)
    parser.add_argument("--out")
    parser.add_argument("--x", type=int)
    parser.add_argument("--y", type=int)
    parser.add_argument("--keys")
    parser.add_argument("--from-file")
    args = parser.parse_args()
    screen = Screen(args.state)
    try:
        if args.action == "screenshot":
            print(json.dumps(screen.screenshot(args.out)))
        elif args.action == "click":
            screen.click(args.x, args.y)
            print(json.dumps({"guestClick": True}))
        elif args.action == "key":
            screen.chord(args.keys)
            print(json.dumps({"guestKeys": True}))
        else:
            screen.text(args.from_file)
            print(json.dumps({"guestText": True}))
    finally:
        screen.socket.close()


if __name__ == "__main__":
    main()
