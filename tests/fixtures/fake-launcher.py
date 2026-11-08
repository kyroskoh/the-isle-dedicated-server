#!/usr/bin/env python3
"""
Stand-in for linux/isle-server.sh / windows/IsleServer.ps1 in the API tests.
Every call is appended to $FAKE_LAUNCHER_LOG (one JSON list per line).
  status  -> exit 0 when $FAKE_STATE_DIR/running exists, else 3
  start / stop / restart -> touch / remove that file (after FAKE_DELAY seconds)
  check   -> exit 1 when server.conf has MAX_PLAYERS that is not a number
  admins/whitelist/classes ... -> edit server.conf like the real launcher
"""
import json
import os
import re
import sys
import time

args = sys.argv[1:]
conf = os.environ.get("ISLE_CONF", "")
state = os.environ.get("FAKE_STATE_DIR", os.path.dirname(conf))
with open(os.environ.get("FAKE_LAUNCHER_LOG", os.devnull), "a") as log:
    log.write(json.dumps(args) + "\n")


def read():
    return open(conf).read().splitlines() if os.path.isfile(conf) else []


def get(key):
    for line in read():
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip().strip('"')
    return ""


def put(key, value):
    lines = [l for l in read() if not l.startswith(key + "=")] + ["%s=%s" % (key, value)]
    open(conf, "w").write("\n".join(lines) + "\n")


cmd, rest = (args[0] if args else ""), args[1:]
running = os.path.join(state, "running")
if cmd == "status":
    if os.path.exists(running):
        print("[ OK ] Running (server PID 4242)"); sys.exit(0)
    print("[WARN] Not running"); sys.exit(3)
if cmd in ("start", "stop", "restart", "update", "validate", "backup", "save"):
    print("[INFO] %s ..." % cmd, flush=True)
    time.sleep(float(os.environ.get("FAKE_DELAY", "0.3")))
    if cmd in ("start", "restart"):
        open(running, "w").close()
    if cmd == "stop" and os.path.exists(running):
        os.remove(running)
    if os.environ.get("FAKE_FAIL") == cmd:
        print("[FAIL] %s failed" % cmd); sys.exit(1)
    print("[ OK ] %s done" % cmd); sys.exit(0)
if cmd == "check":
    if not re.match(r"^\d+$", get("MAX_PLAYERS") or "1"):
        print("[FAIL] config: MAX_PLAYERS='%s' must be a positive integer" % get("MAX_PLAYERS")); sys.exit(1)
    print("[ OK ] Configuration OK"); sys.exit(0)
if cmd == "info":
    print("Runtime          : native\nServer name      : %s\nGame port        : 7777" % get("SERVER_NAME"))
    if os.environ.get("FAKE_LOG_FILE"):  # fuller output for the documentation screenshots
        print("Server dir       : /home/theisle/theisle-server\nBackup dir       : /home/theisle/theisle-backups\n"
              "App / branch     : 412680 / evrima\nPorts            : 7777/udp+tcp, queue 10000/tcp, rcon 127.0.0.1:8888/tcp\n"
              "Max players      : %s" % get("MAX_PLAYERS"))
    sys.exit(0)
if cmd == "logs":
    if os.environ.get("FAKE_LOG_FILE"):
        sys.stdout.write(open(os.environ["FAKE_LOG_FILE"]).read()); sys.exit(0)
    for i in range(300):
        print("log line %d" % i)
    sys.exit(0)
if cmd in ("admins", "whitelist", "classes", "ai-classes"):
    key = {"admins": "ADMIN_STEAM_IDS", "whitelist": "WHITELIST_IDS", "classes": "ALLOWED_CLASSES",
           "ai-classes": "DISABLED_AI_CLASSES"}[cmd]
    sub, items = (rest[0] if rest else "list"), rest[1:]
    cur = [x for x in get(key).split(",") if x]
    if sub == "add":
        cur += [i for i in items if i not in cur]
    elif sub == "remove":
        cur = [c for c in cur if c not in items]
    elif sub == "set":
        cur = items
    elif sub == "reset":
        cur = []
    elif sub in ("on", "off"):
        put("WHITELIST_ENABLED", "true" if sub == "on" else "false"); print("[ OK ] whitelist %s" % sub); sys.exit(0)
    elif sub == "preset":
        cur = ["Tyrannosaurus", "Carnotaurus"]
    put(key, ",".join(cur)); print("[ OK ] %s: %s" % (cmd, ",".join(cur) or "(none)")); sys.exit(0)
if cmd in ("profile", "preset", "plugins", "snapshot"):
    if cmd == "snapshot" and rest[:1] == ["create"]:
        out = rest[rest.index("--output") + 1]
        import io, tarfile
        with tarfile.open(out, "w:gz") as tar:
            data = json.dumps({"format": 1, "created": "2026-11-08T12:00:00Z", "server_name": get("SERVER_NAME"),
                               "source": {"os": "Linux", "runtime": "native"}, "parts": {"worlds": {}}}).encode()
            info = tarfile.TarInfo("snapshot.json"); info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    print("[ OK ] %s %s" % (cmd, " ".join(rest))); sys.exit(0)
print("[FAIL] unknown command %s" % cmd); sys.exit(1)
