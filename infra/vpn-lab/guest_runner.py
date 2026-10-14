#!/usr/bin/env python3
"""Keep the private Tart guest alive; capture only bounded private startup data.

No working credential is passed to Tart. First-boot provisioning uses public
throwaway lab credentials and a host-only network. VNC's generated password
is kept in a mode-0600 file; it is never printed to the terminal.
"""
import json
import os
from pathlib import Path
import re
import select
import subprocess
import urllib.parse

ROOT = Path(__file__).resolve().parents[2] / "build" / "vpn-lab"
meta = json.loads((ROOT / "guest.json").read_text())
if meta["name"] != "nosleep-vpn-lab-20261012" or Path(meta["home"]).resolve() != ROOT.resolve() / "vms":
    raise ValueError("not the owned NoSleep guest")
tool = ROOT / "tools" / "tart.app" / "Contents" / "MacOS" / "tart"
subprocess.run(["codesign", "--verify", "--strict", str(tool.parents[2])],
               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
env = os.environ.copy()
env["TART_HOME"] = str(ROOT / "vms")
env["TART_NO_AUTO_PRUNE"] = "1"
args = [str(tool), "run", meta["name"], "--net-host", "--no-graphics",
        "--no-clipboard", "--no-audio", "--no-usb-accessories",
        "--dir", str(ROOT / "guest-transfer") + ":ro"]
if meta.get("osMajor") == 27:
    args += ["--provisioning-opts", "fullName=NoSleep VPN Lab,username=admin,password=admin,logsInAutomatically=true,enablesRemoteLogin=true"]
signature = subprocess.run(["codesign", "-dv", "--verbose=2", str(tool.parents[2])],
                           capture_output=True).stderr.decode()
if "TeamIdentifier=9M2P8L4D89" not in signature:
    raise ValueError("Tart signer changed")
config = json.loads((ROOT / "vms/vms" / meta["name"] / "config.json").read_text())
mac = config["macAddress"].lower()
if not re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", mac):
    raise ValueError("owned guest MAC is invalid")
identity_file = ROOT / "guest-transfer/guest-owner-mac"
identity_file.write_text(mac + "\n")
identity_file.chmod(0o600)
# Tart prints its startup URL through ordinary stdout. A PTY ensures it is
# flushed while the VM continues running; no host terminal or UI is used.
master, slave = os.openpty()
process = subprocess.Popen(args, env=env, stdin=subprocess.DEVNULL,
                           stdout=slave, stderr=slave, start_new_session=True)
os.close(slave)
runtime = {"pid": process.pid, "name": meta["name"], "mac": mac,
           "network": "host-only", "hostVNCListener": False}
runtime_path = ROOT / "guest-runtime.json"
runtime_path.write_text(json.dumps(runtime, indent=2))
runtime_path.chmod(0o600)
print(json.dumps({"guestRuntimeStarted": True, "privateState": str(runtime_path)}), flush=True)
tail = bytearray()
recorded = False
while True:
    if not select.select([master], [], [], 1)[0]:
        if process.poll() is not None:
            break
        continue
    try:
        line = os.read(master, 8192)
    except OSError:
        break
    if not line:
        break
    tail.extend(line)
    if len(tail) > 262144:
        del tail[:-262144]
    if not recorded:
        text = tail.decode(errors="replace")
        match = re.search(r"vnc://[^\s\x1b]+", text)
        if match:
            url = urllib.parse.urlparse(match[0].rstrip(".,)"))
            if url.hostname not in ("127.0.0.1", "localhost") or not url.port:
                process.terminate()
                raise ValueError("Tart VNC is not restricted to localhost")
            password = urllib.parse.unquote(url.password or url.username or "")
            if not password:
                process.terminate()
                raise ValueError("missing private VNC password")
            password_path = ROOT / "guest-vnc-password.txt"
            password_path.write_text(password + "\n")
            os.chmod(password_path, 0o600)
            ready = {"host": "127.0.0.1", "port": url.port, "pid": process.pid,
                     "name": meta["name"], "passwordFile": str(password_path)}
            (ROOT / "guest-vnc.json").write_text(json.dumps(ready, indent=2))
            os.chmod(ROOT / "guest-vnc.json", 0o600)
            recorded = True
            print(json.dumps({"guestVNCReady": True, "port": url.port,
                              "privateState": str(ROOT / "guest-vnc.json")}), flush=True)
os.close(master)
code = process.wait()
(ROOT / "guest-run-tail.log").write_bytes(tail)
os.chmod(ROOT / "guest-run-tail.log", 0o600)
(ROOT / "guest-run-exit.json").write_text(json.dumps({"exit": code, "vncReady": recorded}))
raise SystemExit(code)
