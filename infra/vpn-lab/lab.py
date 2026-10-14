#!/usr/bin/env python3
"""Owned, loopback-only VPN lab. All fault injection happens in containers.

No operation invokes a host VPN client, edits routes or changes Cisco files.
The state path, container labels and private network are checked before every
destructive operation. CLI output is metadata and receipts, never secrets.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import secrets
import shutil
import signal
import ssl
import subprocess
import sys
import time
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]
LAB_ROOT = ROOT / "build" / "vpn-lab" / "runs"
SOURCE = Path(__file__).resolve().parent
LABEL = "local.nosleep.vpn-lab"
DOCKER = os.environ.get("NOSLEEP_DOCKER") or shutil.which("docker") or \
    "/Users/robertoguzov/.local/share/codex-dev-runtime/bin/docker"


def execute(args, *, data=None, timeout=30):
    result = subprocess.run(args, input=data, capture_output=True, timeout=timeout)
    if result.returncode:
        # Docker failures can contain a path but no password is ever an argument.
        message = result.stderr.decode(errors="replace")[-2048:]
        raise RuntimeError(f"operation failed ({result.returncode}): {message}")
    return result.stdout.decode(errors="replace")


def docker(*args, data=None, timeout=30):
    return execute([DOCKER, *args], data=data, timeout=timeout)


def write_private(path, value):
    path.write_text(value)
    os.chmod(path, 0o600)


class Lab:
    def __init__(self, path):
        self.path = Path(path).resolve()
        if self.path.parent != LAB_ROOT.resolve():
            raise ValueError("lab state must belong to this repository's build/vpn-lab/runs")
        self.manifest = json.loads((self.path / "manifest.json").read_text())
        run = self.manifest["run"]
        if len(run) != 12 or any(c not in "0123456789abcdef" for c in run):
            raise ValueError("invalid lab run id")
        if self.manifest["server"] != f"nosleep-vpn-lab-{run}-server" or \
                self.manifest["client"] != f"nosleep-vpn-lab-{run}-client" or \
                self.manifest["network"] != f"nosleep-vpn-lab-{run}-net":
            raise ValueError("invalid owned object names")

    @classmethod
    def create(cls):
        LAB_ROOT.mkdir(parents=True, exist_ok=True)
        run = uuid.uuid4().hex[:12]
        path = LAB_ROOT / run
        path.mkdir(mode=0o700)
        (path / "server").mkdir(mode=0o700)
        (path / "client").mkdir(mode=0o700)
        secret = secrets.token_urlsafe(32)
        for directory in ("server", "client"):
            write_private(path / directory / "secret.txt", secret + "\n")
        del secret
        write_private(path / "server" / "run-id", run + "\n")
        write_private(path / "server" / "session-timeout", "0\n")
        manifest = {"schema": 1, "run": run,
                    "server": f"nosleep-vpn-lab-{run}-server",
                    "client": f"nosleep-vpn-lab-{run}-client",
                    "network": f"nosleep-vpn-lab-{run}-net",
                    "image": "nosleep-vpn-lab:local", "port": None,
                    "proofAddress": "192.0.2.1", "mainVPNModified": False}
        write_private(path / "manifest.json", json.dumps(manifest, indent=2))
        return cls(path)

    def own(self, object_name, kind="container"):
        if object_name not in (self.manifest["server"], self.manifest["client"],
                               self.manifest["network"]):
            raise ValueError("operation on an unowned object refused")
        inspection = json.loads(docker(kind, "inspect", object_name))[0]
        labels = inspection.get("Labels") if kind == "network" else \
            inspection.get("Config", {}).get("Labels")
        if not labels or labels.get(LABEL) != self.manifest["run"]:
            raise ValueError("missing ownership label; operation refused")
        return inspection

    def save(self):
        write_private(self.path / "manifest.json", json.dumps(self.manifest, indent=2))

    def certificates(self):
        server = self.path / "server"
        execute(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                 "-keyout", str(server / "ca-key.pem"), "-out", str(server / "ca.pem"),
                 "-days", "3", "-subj", "/CN=NoSleep isolated test CA",
                 "-addext", "basicConstraints=critical,CA:TRUE"], timeout=30)
        execute(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
                 "-keyout", str(server / "server-key.pem"),
                 "-out", str(server / "server.csr"), "-subj", "/CN=vpn-lab.invalid"],
                timeout=30)
        write_private(server / "server.ext", "basicConstraints=critical,CA:FALSE\n"
                      "extendedKeyUsage=serverAuth\n"
                      "subjectAltName=DNS:vpn-lab.invalid,DNS:localhost,IP:127.0.0.1\n")
        execute(["openssl", "x509", "-req", "-in", str(server / "server.csr"),
                 "-CA", str(server / "ca.pem"), "-CAkey", str(server / "ca-key.pem"),
                 "-CAcreateserial", "-out", str(server / "server.pem"), "-days", "3",
                 "-extfile", str(server / "server.ext")], timeout=30)
        for file in server.iterdir():
            os.chmod(file, 0o600)
        shutil.copyfile(server / "ca.pem", self.path / "client" / "ca.pem")
        os.chmod(self.path / "client" / "ca.pem", 0o600)

    def up(self, reuse_from_state=None, compile_from_state=None):
        if reuse_from_state and compile_from_state:
            raise ValueError("cannot both reuse and rebuild the prepared lab image")
        self.certificates()
        if reuse_from_state:
            previous = Lab(reuse_from_state)
            previous_container = previous.own(previous.manifest["server"])
            previous_image = previous.manifest["imageId"]
            if previous_container["Image"] != previous_image:
                raise ValueError("previous lab image identity changed")
            image = json.loads(docker("image", "inspect", previous_image))[0]
            assert image["Id"] == previous_image
            self.manifest["reusedPreparedDependenciesFrom"] = previous.manifest["run"]
        else:
            build_args = []
            if compile_from_state:
                previous = Lab(compile_from_state)
                previous_container = previous.own(previous.manifest["server"])
                previous_image = previous.manifest["imageId"]
                if previous_container["Image"] != previous_image:
                    raise ValueError("previous prepared lab image identity changed")
                if (not previous_image.startswith("sha256:") or len(previous_image) != 71
                        or any(value not in "0123456789abcdef" for value in previous_image[7:])):
                    raise ValueError("prepared lab image has an invalid content identity")
                # BuildKit treats a raw sha256:ID in FROM as a registry name.
                # Add an owned immutable-looking tag, then verify its exact ID.
                base_tag = "nosleep-vpn-lab-prepared:" + previous_image[7:]
                docker("image", "tag", previous_image, base_tag)
                if json.loads(docker("image", "inspect", base_tag))[0]["Id"] != previous_image:
                    raise ValueError("owned prepared build tag changed identity")
                build_args = ["--build-arg", "BASE=" + base_tag]
                self.manifest["compiledOnPreparedDependenciesFrom"] = previous.manifest["run"]
            self.manifest["image"] = "nosleep-vpn-lab:ocserv-1.4.2"
            output = docker("build", "--tag", self.manifest["image"], *build_args, str(SOURCE), timeout=600)
            # Build logs are bounded and cannot contain runtime credentials.
            write_private(self.path / "build-tail.log", output[-65536:])
            image = json.loads(docker("image", "inspect", self.manifest["image"]))[0]
            if image.get("Config", {}).get("Labels", {}).get("local.nosleep.vpn-lab.ocserv-release") != "1.4.2":
                raise ValueError("compiled lab image lacks the pinned upstream release marker")
            self.manifest["ocservRelease"] = "1.4.2"
            self.manifest["ocservArchiveSHA256"] = "e35d748a5244b10be3a92ad4df95a534c8280c43680eecaf3cb1b20d2a22b1a5"
        self.manifest["imageId"] = image["Id"]
        docker("network", "create", "--internal", "--label", f"{LABEL}={self.manifest['run']}",
               self.manifest["network"])
        for role in ("server", "client"):
            caps = ["--cap-drop", "ALL", "--cap-add", "NET_ADMIN"]
            if role == "server":
                for cap in ("SETUID", "SETGID", "CHOWN", "DAC_OVERRIDE"):
                    caps += ["--cap-add", cap]
            args = ["run", "--detach", "--name", self.manifest[role],
                    "--label", f"{LABEL}={self.manifest['run']}",
                    "--network", self.manifest["network"],
                    "--memory", "384m", "--cpus", "1", "--pids-limit", "96",
                    "--log-opt", "max-size=2m", "--log-opt", "max-file=2",
                    "--security-opt", "no-new-privileges=true", "--read-only",
                    "--tmpfs", "/run:rw,nosuid,noexec,size=16m",
                    "--tmpfs", "/tmp:rw,nosuid,noexec,size=16m",
                    "--device", "/dev/net/tun:/dev/net/tun", *caps,
                    "--volume", f"{SOURCE}:/opt/lab:ro",
                    "--volume", f"{self.path / role}:/state:{'rw' if role == 'server' else 'ro'}"]
            if role == "server":
                args += ["--network-alias", "vpn-lab.invalid"]
            args += [self.manifest["imageId"], "python3", f"/opt/lab/{role}.py"]
            docker(*args)
        relay = subprocess.Popen([sys.executable, str(SOURCE / "tcp_relay.py"), str(self.path)],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
        self.wait(lambda: (self.path / "relay-ready.json").exists(), 10, "loopback relay startup")
        ready = json.loads((self.path / "relay-ready.json").read_text())
        assert ready["pid"] == relay.pid and ready["host"] == "127.0.0.1"
        self.manifest["port"] = ready["port"]
        self.manifest["relayPID"] = relay.pid
        self.save()
        self.wait(lambda: self.health(), 30, "server health")
        self.wait(lambda: self.client("status").get("phase") == "off", 10, "client control")
        self.invariants()
        return self.public_status()

    def client(self, command, **kwargs):
        self.own(self.manifest["client"])
        output = docker("exec", "--interactive", self.manifest["client"],
                        "python3", "/opt/lab/control.py",
                        data=(json.dumps({"command": command, **kwargs}) + "\n").encode(),
                        timeout=12)
        return json.loads(output)

    def session_expiry_evidence(self, since):
        """Return only typed expiry durations, never raw server log data."""
        if (not isinstance(since, (int, float)) or isinstance(since, bool)
                or not 1_000_000_000 <= since <= time.time() + 5):
            raise ValueError("invalid owned expiry evidence timestamp")
        self.own(self.manifest["server"])
        result = subprocess.run([DOCKER, "logs", "--tail", "200", "--since", str(int(since)),
                                 self.manifest["server"]], capture_output=True, text=True, timeout=10)
        if result.returncode:
            raise RuntimeError("owned expiry evidence is unavailable")
        data = (result.stdout + result.stderr)[-65536:]
        durations = [int(value) for value in re.findall(r"session timeout reached for process \((\d+) secs\)", data)]
        return {"serverSessionExpired": bool(durations), "observedDurationsSeconds": durations[-8:]}

    def health(self):
        try:
            context = ssl.create_default_context(cafile=str(self.path / "server" / "ca.pem"))
            request = urllib.request.Request(f"https://127.0.0.1:{self.manifest['port']}/")
            with urllib.request.urlopen(request, context=context, timeout=2) as response:
                return response.status in (200, 401)
        except urllib.error.HTTPError as error:
            return error.code in (200, 401, 404, 405)
        except Exception:
            return False

    def invariants(self):
        network = self.own(self.manifest["network"], "network")
        if not network["Internal"]:
            raise AssertionError("network must be internal")
        for role in ("server", "client"):
            inspection = self.own(self.manifest[role])
            host = inspection["HostConfig"]
            assert host["Privileged"] is False
            assert host["NetworkMode"] == self.manifest["network"]
            assert host["ReadonlyRootfs"] is True
            assert host["Memory"] <= 384 * 1024 * 1024
            assert host["PidsLimit"] == 96
            # Newer Docker versions serialize capabilities with the CAP_ prefix.
            caps = {cap.removeprefix("CAP_") for cap in host["CapAdd"]}
            expected = {"NET_ADMIN"} | ({"SETUID", "SETGID", "CHOWN", "DAC_OVERRIDE"}
                                      if role == "server" else set())
            assert caps == expected
            assert {cap.removeprefix("CAP_") for cap in host["CapDrop"]} == {"ALL"}
            assert not host["PortBindings"]
            for bindings in (host["PortBindings"] or {}).values():
                assert all(b["HostIp"] == "127.0.0.1" for b in bindings)
            assert all(d["PathOnHost"] == "/dev/net/tun" for d in host["Devices"])
        return {"internalNetwork": True, "loopbackOnly": True, "hostNetwork": False,
                "dockerPublishedPorts": False, "relayMaxConnections": 8,
                "privileged": False, "memoryLimitMiB": 384, "logLimitMiBPerContainer": 4}

    def fault(self, operation, seconds=0):
        server = self.manifest["server"]
        self.own(server)
        if operation == "blackhole-on":
            docker("exec", server, "iptables", "-I", "INPUT", "-p", "tcp", "--dport", "4443", "-j", "DROP")
        elif operation == "blackhole-off":
            docker("exec", server, "iptables", "-D", "INPUT", "-p", "tcp", "--dport", "4443", "-j", "DROP")
        elif operation == "server-stop":
            docker("stop", "--time", "3", server)
        elif operation == "server-start":
            docker("start", server)
            self.wait(self.health, 20, "server restart")
        elif operation == "session-timeout":
            if not 0 <= seconds <= 120:
                raise ValueError("session timeout out of lab bounds")
            docker("stop", "--time", "3", server)
            write_private(self.path / "server" / "session-timeout", str(seconds) + "\n")
            docker("start", server)
            self.wait(self.health, 20, "session-timeout configuration")
        else:
            raise ValueError("unsupported fault")
        return {"operation": operation, "ownedServerOnly": True}

    @staticmethod
    def wait(predicate, timeout, description):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                result = predicate()
                if result:
                    return result
            except (RuntimeError, subprocess.TimeoutExpired, ConnectionError):
                pass
            time.sleep(0.4)
        raise TimeoutError(description)

    def connected(self):
        status = self.client("status")
        return status if status["running"] and status["tunnelRoute"] and \
            status["proof"] == {"run": self.manifest["run"]} else None

    def public_status(self):
        return {"statePath": str(self.path), "run": self.manifest["run"],
                "gateway": f"https://127.0.0.1:{self.manifest['port']}",
                "testCA": str(self.path / "server" / "ca.pem"),
                "invariants": self.invariants()}

    def native_clients(self):
        """A bounded server-side oracle for guest Cisco tunnel continuity.

        occtl can expose session material. Never return its raw output: use
        only an anonymous hash of IDs and the count/status of lab sessions.
        """
        self.own(self.manifest["server"])
        output = docker("exec", self.manifest["server"], "occtl", "--json", "show", "users")
        if len(output.encode()) > 65536:
            raise ValueError("native client metadata exceeds budget")
        users = json.loads(output)
        if not isinstance(users, list) or len(users) > 4:
            raise ValueError("unexpected client metadata from owned server")
        identifiers = []
        states = []
        for user in users:
            if not isinstance(user, dict):
                raise ValueError("invalid native client metadata")
            identifier = user.get("ID")
            if not isinstance(identifier, int) or not 0 < identifier < 2 ** 31:
                raise ValueError("native client metadata lacks a numeric session ID")
            identifiers.append(str(identifier))
            status = str(user.get("State", user.get("Status", "unknown"))).lower()
            states.append(status if status in {"connected", "authenticated", "connecting", "unknown"} else "unknown")
        fingerprint = hashlib.sha256(json.dumps(sorted(identifiers)).encode()).hexdigest() if users else None
        return {"clientCount": len(users), "sessionFingerprint": fingerprint,
                "states": states, "ownedServerOnly": True}

    def down(self):
        pid = self.manifest.get("relayPID")
        if pid:
            result = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True)
            if result.returncode == 0:
                command = result.stdout.decode().strip()
                if str(SOURCE / "tcp_relay.py") not in command or str(self.path) not in command:
                    raise ValueError("relay process identity changed; refusing termination")
                os.kill(pid, signal.SIGTERM)
        for role in ("client", "server"):
            try:
                self.own(self.manifest[role])
            except RuntimeError:
                continue
            docker("rm", "--force", self.manifest[role])
        try:
            self.own(self.manifest["network"], "network")
        except RuntimeError:
            return
        docker("network", "rm", self.manifest["network"])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["up", "status", "native-clients", "down", "start", "stop", "fault"])
    parser.add_argument("--state")
    parser.add_argument("--fault", choices=["blackhole-on", "blackhole-off", "server-stop", "server-start", "session-timeout"])
    parser.add_argument("--seconds", type=int, default=0)
    parser.add_argument("--credential", choices=["valid", "invalid"], default="valid")
    args = parser.parse_args()
    if args.action == "up":
        lab = Lab.create()
        print(json.dumps(lab.up(), indent=2))
        return
    if not args.state:
        parser.error("--state required for existing lab")
    lab = Lab(args.state)
    if args.action == "status":
        result = {**lab.public_status(), "client": lab.client("status")}
    elif args.action == "native-clients":
        result = lab.native_clients()
    elif args.action == "down":
        lab.down()
        result = {"removedOwnedLab": True}
    elif args.action in ("start", "stop"):
        result = lab.client(args.action, credential=args.credential)
    else:
        result = lab.fault(args.fault, args.seconds)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
