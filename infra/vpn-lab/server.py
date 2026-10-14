"""Ephemeral AnyConnect protocol server. No host VPN configuration is used."""
import http.server
import json
import os
from pathlib import Path
import re
import subprocess
import threading
from urllib.parse import parse_qs, urlsplit

CONFIG = '''auth = "plain[passwd=/state/ocpasswd]"
tcp-port = 4443
udp-port = 0
run-as-user = nobody
run-as-group = nogroup
socket-file = /run/ocserv-socket
server-cert = /state/server.pem
server-key = /state/server-key.pem
max-clients = 4
max-same-clients = 2
keepalive = 2
dpd = 2
cookie-timeout = 60
auth-timeout = 180
max-ban-score = 0
device = labvpn
ipv4-network = 192.0.2.0/24
route = 192.0.2.0/24
try-mtu-discovery = false
isolate-workers = false
use-occtl = true
cisco-client-compat = true
select-group = "lab[NoSleep Lab]"
'''


class FreshProofOracle:
    """One-shot, bounded challenges for this owned server lifetime.

    Existing /proof clients retain their run receipt. Fresh acceptance uses a
    new 256-bit random challenge on each request and verifies both echoed fields.
    Admission refuses at capacity instead of evicting old challenges and making
    them replayable. No credential, session ID or wire data is retained.
    """

    def __init__(self, run, capacity=512):
        if not re.fullmatch(r"[0-9a-f]{12}", run) or not 1 <= capacity <= 4096:
            raise ValueError("invalid owned proof configuration")
        self.run, self.capacity = run, capacity
        self.seen = set()
        self.lock = threading.Lock()

    def reply(self, target):
        if len(target) > 256:
            return 414, None
        if target == "/proof":
            return 200, {"run": self.run}
        try:
            url = urlsplit(target)
            if url.path != "/proof":
                return 404, None
            query = parse_qs(url.query, strict_parsing=True, keep_blank_values=True,
                             max_num_fields=2, errors="strict")
        except (ValueError, UnicodeError):
            return 400, None
        if url.scheme or url.netloc or url.fragment or set(query) != {"run", "nonce"}:
            return 400, None
        if any(len(values) != 1 for values in query.values()):
            return 400, None
        run, nonce = query["run"][0], query["nonce"][0]
        if not re.fullmatch(r"[0-9a-f]{12}", run) or not re.fullmatch(r"[0-9a-f]{64}", nonce):
            return 400, None
        if run != self.run:
            return 409, None
        with self.lock:
            if nonce in self.seen:
                return 409, None
            if len(self.seen) >= self.capacity:
                return 503, None
            self.seen.add(nonce)
        return 200, {"run": self.run, "nonce": nonce}


class Proof(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        status, receipt = self.server.oracle.reply(self.path)
        body = json.dumps(receipt if receipt is not None else {"error": status}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class ProofServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, oracle):
        self.oracle = oracle
        self.capacity = threading.BoundedSemaphore(8)
        super().__init__(address, Proof)

    def process_request(self, request, client_address):
        request.settimeout(3)
        if not self.capacity.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.capacity.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.capacity.release()


def main():
    state = Path("/state")
    state.mkdir(mode=0o700, exist_ok=True)
    password = (state / "secret.txt").read_text().strip()
    subprocess.run(
        ["ocpasswd", "-c", str(state / "ocpasswd"), "-g", "lab", "lab-user"],
        input=(password + "\n" + password + "\n").encode(),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True,
    )
    del password
    os.chmod(state / "ocpasswd", 0o600)
    timeout = int((state / "session-timeout").read_text().strip())
    config = CONFIG + (f"session-timeout = {timeout}\n" if timeout else "")
    (state / "ocserv.conf").write_text(config)
    server = ProofServer(("0.0.0.0", 8080), FreshProofOracle((state / "run-id").read_text().strip()))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        return subprocess.call(["ocserv", "--foreground", "--log-stderr", "--debug", "3",
                                "-c", str(state / "ocserv.conf")])
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    raise SystemExit(main())
