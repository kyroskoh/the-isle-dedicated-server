#!/usr/bin/env python3
"""
isle_rcon.py - minimal RCON client for The Isle (Evrima) dedicated servers.

Pure Python 3 standard library, works on Linux and Windows.

The Evrima RCON protocol is a small custom binary protocol over TCP
(it is NOT Source/Valve RCON):

    login   : 0x01 + <password> + 0x00
    command : 0x02 + <command byte> + <argument> + 0x00

The command bytes below are the ones documented by the community. They may
change with game updates; use "raw" to send an arbitrary command byte.

Examples:
    python3 isle_rcon.py -H 127.0.0.1 -p 8888 -P secret save
    python3 isle_rcon.py -P secret announce "Restart in 5 minutes"
    python3 isle_rcon.py -P secret playerlist
    python3 isle_rcon.py -P secret raw 0x12
    python3 isle_rcon.py --config ../config/server.conf save
"""

import argparse
import os
import socket
import sys

COMMANDS = {
    "announce": 0x10,           # <message>
    "directmessage": 0x11,      # <steamid>,<message>
    "serverdetails": 0x12,
    "wipecorpses": 0x13,
    "updateplayables": 0x15,    # <class list>
    "ban": 0x20,                # <steamid>,<reason>
    "kick": 0x30,               # <steamid>,<reason>
    "playerlist": 0x40,
    "save": 0x50,
    "playerdata": 0x77,
    "togglewhitelist": 0x81,
    "addwhitelist": 0x82,       # <steamid,steamid,...>
    "removewhitelist": 0x83,    # <steamid,steamid,...>
    "toggleglobalchat": 0x84,
    "togglehumans": 0x86,
    "toggleai": 0x90,
    "disableaiclasses": 0x91,   # <class,class,...>
    "aidensity": 0x92,          # <float>
    # from the community-documented Evrima protocol (isle-evrima-rcon); may change with game updates
    "getplayables": 0x14,
    "togglemigrations": 0x19,   # 1|0
    "togglegrowthmultiplier": 0x21,  # 1|0
    "setgrowthmultiplier": 0x22,     # <float>
    "togglenetupdate": 0x23,    # 1|0  network update distance checks
    "pause": 0x60,              # 1|0
    "custom": 0x70,             # <command> - experimental, may not be functional
    "queuestatus": 0x93,
    "toggleailearning": 0x94,   # 1|0
}


def read_conf(path):
    """Parse the shared KEY=VALUE server.conf file."""
    values = {}
    with open(path, "r", encoding="utf-8-sig") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            values[key.strip()] = value
    return values


def recv_some(sock, timeout):
    sock.settimeout(timeout)
    chunks = []
    try:
        while True:
            data = sock.recv(65535)
            if not data:
                break
            chunks.append(data)
            sock.settimeout(0.3)  # drain anything that follows quickly
    except socket.timeout:
        pass
    return b"".join(chunks)


def send_command(host, port, password, cmd_byte, argument="", timeout=5.0):
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.sendall(b"\x01" + password.encode("utf-8") + b"\x00")
        reply = recv_some(sock, timeout).decode("utf-8", "replace")
        if "denied" in reply.lower() or "invalid" in reply.lower():
            raise PermissionError("RCON login rejected: " + reply.strip())
        payload = b"\x02" + bytes([cmd_byte]) + argument.encode("utf-8") + b"\x00"
        sock.sendall(payload)
        return recv_some(sock, timeout).decode("utf-8", "replace")


def main(argv=None):
    parser = argparse.ArgumentParser(description="The Isle Evrima RCON client")
    parser.add_argument("-H", "--host", default=None, help="server address (default 127.0.0.1)")
    parser.add_argument("-p", "--port", type=int, default=None, help="RCON port (default 8888)")
    parser.add_argument("-P", "--password", default=None,
                        help="RCON password (or env ISLE_RCON_PASSWORD)")
    parser.add_argument("-c", "--config", default=None, help="read port/password from server.conf")
    parser.add_argument("-t", "--timeout", type=float, default=5.0)
    parser.add_argument("command", help="one of: %s, raw" % ", ".join(sorted(COMMANDS)))
    parser.add_argument("args", nargs="*", help="command argument(s)")
    opts = parser.parse_args(argv)

    conf = read_conf(opts.config) if opts.config else {}
    host = opts.host or "127.0.0.1"
    port = opts.port or int(conf.get("RCON_PORT") or 8888)
    password = opts.password or os.environ.get("ISLE_RCON_PASSWORD") or conf.get("RCON_PASSWORD", "")
    if not password:
        parser.error("no RCON password given (-P, ISLE_RCON_PASSWORD or --config)")

    name = opts.command.lower()
    args = list(opts.args)
    if name == "raw":
        if not args:
            parser.error("raw needs a command byte, e.g. raw 0x50")
        cmd_byte = int(args.pop(0), 0)
    elif name in COMMANDS:
        cmd_byte = COMMANDS[name]
    else:
        parser.error("unknown command '%s'" % opts.command)

    try:
        reply = send_command(host, port, password, cmd_byte, " ".join(args), opts.timeout)
    except (OSError, PermissionError) as exc:
        print("RCON error: %s" % exc, file=sys.stderr)
        return 1
    if reply.strip():
        print(reply.strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
