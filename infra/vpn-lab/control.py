"""Internal control utility. Requests contain no passwords or cookies."""
import json
import socket
import sys

request = json.loads(sys.stdin.read(4096))
with socket.socket(socket.AF_UNIX) as s:
    s.settimeout(8)
    s.connect("/run/vpn-lab-control.sock")
    s.sendall(json.dumps(request).encode() + b"\n")
    output = bytearray()
    while not output.endswith(b"\n"):
        part = s.recv(4096)
        if not part:
            break
        output.extend(part)
        if len(output) > 32768:
            raise RuntimeError("response-over-budget")
    print(output.decode().strip())
