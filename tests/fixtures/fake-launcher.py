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
if cmd == "backup" and rest[:1] in (["status"], ["schedule"]):
    if rest[0] == "schedule":
        if rest[1:2] == ["off"]:
            put("BACKUP_SCHEDULE", "off")
        elif rest[1:2] == ["set"]:
            put("BACKUP_SCHEDULE", '"%s"' % rest[2])
        print("[ OK ] Backup schedule: %s" % get("BACKUP_SCHEDULE")); sys.exit(0)
    sched = get("BACKUP_SCHEDULE") or "0 5 * * *"
    copy, off = get("BACKUP_COPY_DIR"), get("BACKUP_OFFSITE_COMMAND")
    copies = 1 + (1 if copy else 0) + (1 if off else 0)
    print(json.dumps({"schedule": sched, "describe": "every day at 05:00" if sched == "0 5 * * *" else sched,
                      "zone": "UTC+00:00", "next": [] if sched == "off" else ["2026-11-09T05:00:00", "2026-11-10T05:00:00"],
                      "last": {"file": "theisle-backup_20261108_050012.tar.gz", "age_seconds": 25200},
                      "local": {"dir": "/home/theisle/theisle-backups", "count": 7},
                      "copy": {"dir": copy, "count": 7 if copy else 0, "other_disk": bool(copy)},
                      "offsite": {"configured": off, "last": "2026-11-08T05:01:40" if off else ""},
                      "rule321": {"copies": copies, "media": 2 if copy else 1, "offsite": bool(off),
                                  "ok": bool(copy and off)}}))
    sys.exit(0)
if cmd == "admin":
    if os.environ.get("FAKE_FAIL") == "admin":
        print("[FAIL] RCON connection refused (is the server running?)"); sys.exit(1)
    if rest[:1] == ["players"]:
        print("76561198000000001 Rex\n76561198000000002 Trike"); sys.exit(0)
    print("[ OK ] admin %s" % " ".join(rest)); sys.exit(0)
if cmd == "classes" and rest[:1] and rest[0] in ("select", "add-type", "remove-type", "humans"):
    if rest[0] == "humans":
        put("ENABLE_HUMANS", "true" if rest[1:2] == ["on"] else "false")
    else:
        put("ALLOWED_CLASSES", "Tyrannosaurus,Carnotaurus" if "carnivore" in rest else "Triceratops")
    print("[ OK ] classes %s" % " ".join(rest)); sys.exit(0)
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
if cmd == "maps" and rest[:1] == ["set"]:
    branches = {"Gateway": "evrima", "Isla_Spiro": "spiro0.11.59.04"}
    put("MAP_NAME", rest[1])
    if "--keep-branch" not in rest:
        put("STEAM_BRANCH", branches.get(rest[1], get("STEAM_BRANCH")))
    print("[ OK ] Map set to %s" % rest[1]); sys.exit(0)
if cmd == "ai":
    sub = rest[0] if rest else "status"
    if sub in ("on", "off"):
        put("SPAWN_AI", "true" if sub == "on" else "false")
    elif sub == "density":
        put("AI_DENSITY", rest[1])
    elif sub == "interval":
        put("AI_SPAWN_INTERVAL", rest[1])
    elif sub == "preset":
        put("DISABLED_AI_CLASSES", "Compsognathus,Pterodactylus") if rest[1] == "ai-prey-only" else None
    print("[ OK ] ai %s" % " ".join(rest)); sys.exit(0)
if cmd == "plugins" and rest[:1] == ["sources"]:
    state = os.path.join(os.path.dirname(conf), "plugins")
    os.makedirs(state, exist_ok=True)
    path = os.path.join(state, "sources.txt")
    cur = [l.strip() for l in open(path)] if os.path.isfile(path) else []
    if rest[1] == "add" and rest[2] not in cur:
        cur.append(rest[2])
    if rest[1] == "remove":
        cur = [c for c in cur if c != rest[2]]
    open(path, "w").write("".join(c + "\n" for c in cur))
    print("[ OK ] Catalog sources: %d" % len(cur)); sys.exit(0)
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
