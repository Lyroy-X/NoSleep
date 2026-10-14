"""Container-side opaque TCP pipe; TLS is not terminated or logged here."""
import os
import socket
import threading

socket_connection = socket.create_connection(("vpn-lab.invalid", 4443), timeout=8)
socket_connection.settimeout(None)


def incoming():
    try:
        while True:
            data = socket_connection.recv(16384)
            if not data:
                break
            os.write(1, data)
    finally:
        os._exit(0)


threading.Thread(target=incoming, daemon=True).start()
try:
    while True:
        data = os.read(0, 16384)
        if not data:
            break
        socket_connection.sendall(data)
finally:
    socket_connection.close()
