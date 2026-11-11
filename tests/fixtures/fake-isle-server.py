#!/usr/bin/env python3
"""
Stand-in for TheIsleServer-Linux-Shipping in tests: it speaks the Evrima RCON
protocol (login 0x01, commands 0x02 <byte> <text>) on RconPort from the
generated Game.ini, checks RconPassword, and logs everything to
TheIsle/Saved/fake-server.log so tests can assert what reached the "game".
"""
import os
import signal
import socket
import sys
import threading

ROOT = os.getcwd()  # the launcher starts the server in SERVER_DIR
INI = os.path.join(ROOT, "TheIsle", "Saved", "Config", "LinuxServer", "Game.ini")
LOG = os.path.join(ROOT, "TheIsle", "Saved", "fake-server.log")
NAMES = {0x10: "announce", 0x11: "directmessage", 0x12: "serverdetails", 0x13: "wipecorpses",
         0x15: "updateplayables", 0x20: "ban", 0x30: "kick", 0x40: "playerlist", 0x50: "save",
         0x77: "playerdata", 0x81: "togglewhitelist", 0x82: "addwhitelist", 0x83: "removewhitelist",
         0x84: "toggleglobalchat", 0x86: "togglehumans", 0x90: "toggleai", 0x91: "disableaiclasses",
         0x92: "aidensity"}
lock = threading.Lock()


def log(line):
    with lock, open(LOG, "a") as handle:
        handle.write(line + "\n")
        handle.flush()


def ini_value(key, default):
    try:
        for line in open(INI):
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return default


def client(conn, password):
    with conn:
        conn.settimeout(10)
        data = conn.recv(4096)
        if data[:1] != b"\x01" or data[1:].rstrip(b"\x00").decode() != password:
            log("LOGIN denied")
            conn.sendall(b"Password Denied")
            return
        conn.sendall(b"Password Accepted")
        data = conn.recv(4096)
        if data[:1] == b"\x02" and len(data) >= 2:
            name = NAMES.get(data[1], "0x%02x" % data[1])
            text = data[2:].rstrip(b"\x00").decode("utf-8", "replace")
            log("RCON %s %s" % (name, text))
            conn.sendall(("%s OK" % name).encode())


def main():
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    log("STARTED uid=%d args=%s" % (os.getuid(), " ".join(sys.argv[1:])))
    signal.signal(signal.SIGTERM, lambda *_: (log("SIGTERM"), os._exit(0)))
    port = int(ini_value("RconPort", "8888"))
    password = ini_value("RconPassword", "")
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(16)
    log("RCON listening on %d" % port)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=client, args=(conn, password), daemon=True).start()


if __name__ == "__main__":
    main()
