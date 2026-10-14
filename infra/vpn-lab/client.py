"""Real OpenConnect, controlled through a container-local Unix socket.

The password is supplied only on stdin. Raw client output, cookies and HTTP
traffic are never written to the receipt or Docker logs. A bounded tail is
kept in process memory exclusively to recognize a few non-sensitive phases.
"""
import json
import os
from pathlib import Path
import signal
import socketserver
import subprocess
import threading
import time
import urllib.request


class Client:
    def __init__(self):
        self.lock = threading.RLock()
        self.process = None
        self.phase = "off"
        self.starts = 0
        self.generation = 0
        self.started_at = None
        self.auth_failed = False
        self.events = []

    def event(self, phase):
        with self.lock:
            self.phase = phase
            self.events.append({"phase": phase, "at": time.monotonic()})
            self.events = self.events[-64:]

    def start(self, credential="valid", reconnect_timeout=20):
        assert credential in ("valid", "invalid")
        assert 1 <= reconnect_timeout <= 120
        with self.lock:
            if self.process and self.process.poll() is None:
                return {"started": False, "reason": "already-running"}
            secret = Path("/state/secret.txt").read_text().strip()
            if credential == "invalid":
                secret += "-invalid"
            self.generation += 1
            generation = self.generation
            self.starts += 1
            self.started_at = time.monotonic()
            self.auth_failed = False
            self.event("connecting")
            self.process = subprocess.Popen([
                "openconnect", "--protocol", "anyconnect", "--no-dtls",
                "--non-inter", "--passwd-on-stdin", "--force-dpd=2",
                f"--reconnect-timeout={reconnect_timeout}", "--user", "lab-user",
                "--authgroup", "lab",
                "--cafile", "/state/ca.pem", "--interface", "labvpn",
                "--script", "/usr/share/vpnc-scripts/vpnc-script",
                "https://vpn-lab.invalid:4443",
            ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            process = self.process
            process.stdin.write((secret + "\n").encode())
            process.stdin.close()
            del secret
            threading.Thread(target=self.read, args=(process, generation), daemon=True).start()
            return {"started": True, "generation": generation}

    def read(self, process, generation):
        tail = bytearray()
        # readline is bounded: an unexpected huge line cannot allocate endlessly.
        while True:
            chunk = process.stdout.readline(4096)
            if not chunk:
                break
            tail.extend(chunk)
            if len(tail) > 16384:
                del tail[:-16384]
            with self.lock:
                if generation != self.generation:
                    continue
                text = chunk.decode(errors="replace").lower()
                if "authentication failed" in text or "login failed" in text:
                    self.auth_failed = True
                    self.event("authentication-failed")
                elif "connected as " in text or "cstp connected" in text:
                    self.event("connected")
                elif "reconnect" in text or "ssl connection failure" in text:
                    self.event("reconnecting")
        code = process.wait()
        with self.lock:
            if generation == self.generation and self.phase != "off":
                self.event("authentication-failed" if self.auth_failed else "ended")
                self.events[-1]["exitCode"] = code
        del tail

    def stop(self):
        with self.lock:
            process = self.process
            self.event("off")
            self.generation += 1
        if process and process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        return {"stopped": True}

    def status(self):
        # Interface + route + nonce response prove packets traverse the tunnel.
        route = subprocess.run(
            ["ip", "-json", "route", "get", "192.0.2.1"],
            capture_output=True, timeout=2,
        )
        routes = json.loads(route.stdout or b"[]")
        tunnel_route = bool(routes and routes[0].get("dev") == "labvpn")
        proof = None
        if tunnel_route:
            try:
                req = urllib.request.Request("http://192.0.2.1:8080/proof")
                with urllib.request.urlopen(req, timeout=1) as r:
                    proof = json.loads(r.read(1024))
            except Exception:
                pass
        with self.lock:
            process = self.process
            return {"running": bool(process and process.poll() is None),
                    "phase": self.phase, "starts": self.starts,
                    "generation": self.generation, "tunnelRoute": tunnel_route,
                    "proof": proof, "events": list(self.events),
                    "pid": process.pid if process and process.poll() is None else None}


client = Client()


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        data = self.rfile.readline(4097)
        if len(data) > 4096:
            return
        request = json.loads(data)
        if request["command"] == "start":
            result = client.start(request.get("credential", "valid"),
                                  int(request.get("reconnectTimeout", 20)))
        elif request["command"] == "stop":
            result = client.stop()
        elif request["command"] == "status":
            result = client.status()
        else:
            result = {"error": "unsupported-command"}
        self.wfile.write(json.dumps(result).encode() + b"\n")


path = "/run/vpn-lab-control.sock"
if os.path.exists(path):
    os.unlink(path)
with socketserver.ThreadingUnixStreamServer(path, Handler) as server:
    os.chmod(path, 0o600)
    server.serve_forever()
