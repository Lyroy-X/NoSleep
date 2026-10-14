"""Loopback-only, bounded opaque TCP relay into an internal Docker network.

Each connection uses the already label-verified lab client container. Docker
does not publish internal-network ports. This relay avoids adding an externally
reachable Docker network or manipulating the host's network configuration.
"""
import importlib.util
import json
import os
from pathlib import Path
import signal
import socketserver
import subprocess
import sys
import threading

spec = importlib.util.spec_from_file_location("lab", Path(__file__).with_name("lab.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
lab = module.Lab(sys.argv[1])
lab.own(lab.manifest["client"])
slots = threading.BoundedSemaphore(8)
processes = set()
lock = threading.Lock()


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        if not slots.acquire(blocking=False):
            return
        process = None
        try:
            lab.own(lab.manifest["client"])
            process = subprocess.Popen([
                module.DOCKER, "exec", "--interactive", lab.manifest["client"],
                "python3", "/opt/lab/stream.py",
            ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            with lock:
                processes.add(process)
            self.request.settimeout(90)

            def incoming():
                try:
                    while True:
                        data = process.stdout.read1(16384)
                        if not data:
                            break
                        self.request.sendall(data)
                except (OSError, ValueError):
                    pass
                finally:
                    try:
                        self.request.shutdown(2)
                    except OSError:
                        pass

            reader = threading.Thread(target=incoming, daemon=True)
            reader.start()
            while True:
                data = self.request.recv(16384)
                if not data:
                    break
                process.stdin.write(data)
                process.stdin.flush()
        except (OSError, BrokenPipeError, RuntimeError):
            pass
        finally:
            if process:
                try:
                    process.stdin.close()
                except OSError:
                    pass
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
                with lock:
                    processes.discard(process)
            slots.release()


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = False


def stop(_signal, _frame):
    with lock:
        for process in list(processes):
            process.terminate()
    os._exit(0)


signal.signal(signal.SIGTERM, stop)
with Server(("127.0.0.1", 0), Handler) as server:
    ready = lab.path / "relay-ready.json"
    ready.write_text(json.dumps({"pid": os.getpid(), "host": "127.0.0.1",
                                "port": server.server_address[1]}))
    os.chmod(ready, 0o600)
    server.serve_forever()
