#!/usr/bin/env python3
"""
isle_api.py - REST API (OpenAPI 3.1 at /openapi.json, docs at /docs) and web UI
for The Isle dedicated server scripts (PRD API-01..05, UI-01..05).

Python 3.6+, standard library only. Every action goes through the launcher
(linux/isle-server.sh or windows/IsleServer.ps1), so the API behaves the same on
Linux and Windows, natively and in Docker.

    isle_api.py [--conf FILE] [--launcher PATH] [--runtime native|docker]
                [--host 127.0.0.1] [--port 8090] [--cert FILE --key FILE]
                [--token-file FILE] [--cors ORIGIN] [--open]

Security: binds to 127.0.0.1 by default; every /api/v1 route except /health
needs "Authorization: Bearer <token>" (token in <conf dir>/ui-token, created on
first start, or $ISLE_UI_TOKEN). Use --cert/--key (or a TLS reverse proxy)
before exposing it beyond localhost.
"""

import argparse
import datetime
import hmac
import json
import mimetypes
import os
import re
import secrets
import signal
import socket
import ssl
import stat
import subprocess
import sys
import tarfile
import threading
import time
import uuid
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from urllib.parse import parse_qs, urlparse

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TOOLS)
UI_DIR = os.path.join(REPO, "ui")
sys.path.insert(0, TOOLS)
import isle_rcon  # noqa: E402
import isle_plugins  # noqa: E402
import isle_logs  # noqa: E402

API_VERSION = "1.0.0"
MAX_BODY = 64 * 1024
MASK = "********"
SECRET_KEYS = {"RCON_PASSWORD", "SERVER_PASSWORD", "EOS_CLIENT_SECRET", "STEAM_BRANCH_PASSWORD"}
# never editable through the API: change these with the installer (machine / runtime / paths)
LOCKED_KEYS = {"RUNTIME", "DOCKER_BUILD", "DOCKER_IMAGE", "PUID", "PGID", "STEAMCMD_DIR", "SERVER_DIR",
               "BACKUP_DIR", "INI_OVERRIDES_DIR", "UI_HOST", "UI_PORT", "LOG_DIR"}
ACCESS_LOG = {"log": None, "lock": threading.Lock()}
STEAMID_RE = re.compile(r"^7656119\d{10}$")
CLASS_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,63}$")
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
SNAP_RE = re.compile(r"^theisle-[A-Za-z0-9._-]+\.tar\.gz$")
ACTIONS = ("start", "stop", "restart", "save", "backup", "update", "validate")
LIFECYCLE = {"start", "stop", "restart", "update", "validate", "backup", "snapshot-restore", "snapshot-create"}
PS_NAMES = {"start": "Start", "stop": "Stop", "restart": "Restart", "save": "Save", "backup": "Backup",
            "update": "Update", "validate": "Validate", "status": "Status", "info": "Info", "check": "Check",
            "logs": "Logs", "admins": "Admins", "whitelist": "Whitelist", "classes": "Classes",
            "ai-classes": "AIClasses", "profile": "Profile", "preset": "Preset", "plugins": "Plugins",
            "snapshot": "Snapshot", "version": "Version", "ai": "AI", "maps": "Maps"}


class ApiError(Exception):
    def __init__(self, status, title, detail="", extra=None):
        Exception.__init__(self, detail or title)
        self.status, self.title, self.detail, self.extra = status, title, detail, extra or {}


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# ------------------------------------------------------------- environment --
class Env(object):
    def __init__(self, o):
        self.conf = os.path.abspath(o.conf or os.environ.get("ISLE_CONF") or os.path.join(REPO, "config", "server.conf"))
        self.launcher = o.launcher or os.environ.get("ISLE_LAUNCHER") or self.default_launcher()
        self.runtime_flag = o.runtime
        self.example = os.path.join(REPO, "config", "server.conf.example")
        self.snap_dir = os.path.abspath(o.snapshot_dir or os.environ.get("ISLE_SNAPSHOT_DIR") or os.path.join(REPO, "snapshots"))

    @staticmethod
    def default_launcher():
        if sys.platform.startswith("win"):
            return os.path.join(REPO, "windows", "IsleServer.ps1")
        return os.path.join(REPO, "linux", "isle-server.sh")

    def values(self):
        return isle_rcon.read_conf(self.conf) if os.path.isfile(self.conf) else {}

    def runtime(self):
        return (self.runtime_flag or os.environ.get("ISLE_RUNTIME") or self.values().get("RUNTIME") or "native").lower()

    def command(self, name, args=()):
        """argument list for a launcher command (never a shell string)"""
        args = [str(a) for a in args]
        if self.launcher.lower().endswith(".ps1"):
            shell = "powershell" if sys.platform.startswith("win") else "pwsh"
            return [shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", self.launcher,
                    PS_NAMES.get(name, name)] + args + ["-ConfigPath", self.conf]
        if self.launcher.lower().endswith(".py"):  # test doubles / custom launchers
            return [sys.executable, self.launcher, name] + args
        return [self.launcher, name] + args

    def run(self, name, args=(), timeout=180):
        env = dict(os.environ, ISLE_CONF=self.conf, ISLE_NOPAUSE="1")
        if self.runtime_flag:
            env["ISLE_RUNTIME"] = self.runtime_flag
        try:
            p = subprocess.run(self.command(name, args), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               env=env, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise ApiError(504, "Launcher timed out", "'%s' did not finish within %ds" % (name, timeout))
        except OSError as exc:
            raise ApiError(500, "Launcher could not be started", str(exc))
        return p.returncode, strip_ansi(p.stdout.decode("utf-8", "replace"))


def strip_ansi(text):
    return re.sub(r"\x1b\[[0-9;]*m", "", text)


# -------------------------------------------------------------------- jobs ---
class Jobs(object):
    """Long-running launcher actions run in threads; one lifecycle action at a time."""

    def __init__(self, env):
        self.env, self.lock, self.items, self.busy = env, threading.Lock(), {}, None

    def start(self, kind, name, args=()):
        with self.lock:
            if kind in LIFECYCLE and self.busy:
                raise ApiError(409, "Another action is running", "'%s' (job %s) must finish first" % (
                    self.items[self.busy]["action"], self.busy), {"running_job": self.busy})
            job_id = uuid.uuid4().hex[:12]
            job = {"id": job_id, "action": kind, "state": "running", "created": now_iso(), "finished": None,
                   "exit_code": None, "output": ""}
            self.items[job_id] = job
            if kind in LIFECYCLE:
                self.busy = job_id
            while len(self.items) > 50:  # keep the newest 50
                oldest = min(self.items.values(), key=lambda j: j["created"])
                if oldest["state"] == "running":
                    break
                del self.items[oldest["id"]]
        threading.Thread(target=self._run, args=(job, name, list(args)), daemon=True).start()
        return job

    def _run(self, job, name, args):
        env = dict(os.environ, ISLE_CONF=self.env.conf, ISLE_NOPAUSE="1")
        if self.env.runtime_flag:
            env["ISLE_RUNTIME"] = self.env.runtime_flag
        try:
            proc = subprocess.Popen(self.env.command(name, args), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
            for raw in iter(proc.stdout.readline, b""):
                job["output"] = (job["output"] + strip_ansi(raw.decode("utf-8", "replace")))[-200000:]
            job["exit_code"] = proc.wait(timeout=7200)
            job["state"] = "succeeded" if job["exit_code"] == 0 else "failed"
        except Exception as exc:  # noqa: BLE001 - a job must always finish
            job["output"] += "\n[api] %s" % exc
            job["state"], job["exit_code"] = "failed", -1
        finally:
            job["finished"] = now_iso()
            with self.lock:
                if self.busy == job["id"]:
                    self.busy = None

    def get(self, job_id):
        job = self.items.get(job_id)
        if not job:
            raise ApiError(404, "Job not found", "no job %s" % job_id)
        return job


# ------------------------------------------------------------ config model ---
def parse_example(path):
    """server.conf.example -> ordered key metadata (group, default, description)."""
    keys, group, comments = [], "General", []
    if not os.path.isfile(path):
        return keys
    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip("\n")
        m = re.match(r"^# -+ ([A-Za-z /&-]+?) -*$", line)
        if m:
            group, comments = m.group(1).strip(), []
            continue
        if line.startswith("#"):
            text = line.lstrip("#").strip()
            if text and not text.startswith("===") and not text.startswith("---"):
                comments.append(text)
            continue
        if "=" in line and re.match(r"^[A-Z_][A-Z0-9_]*=", line):
            key, default = line.split("=", 1)
            default = default.strip().strip('"')
            keys.append({"key": key, "group": group, "default": default, "description": " ".join(comments)[:400],
                         "secret": key in SECRET_KEYS, "editable": key not in LOCKED_KEYS})
            comments = []
        elif not line.strip():
            comments = []
    return keys


def write_conf_values(path, updates):
    with open(path, "r", encoding="utf-8-sig") as handle:
        lines = handle.read().splitlines()
    for key, value in updates.items():
        rx = re.compile(r"^%s=" % re.escape(key))
        idx = [i for i, l in enumerate(lines) if rx.match(l)]
        quoted = '"%s"' % value if (value != value.strip() or " " in value) and '"' not in value else value
        if idx:
            for i in idx:
                lines[i] = "%s=%s" % (key, quoted)
        else:
            lines.append("%s=%s" % (key, quoted))
    tmp = path + ".tmp-api"
    with open(tmp, "w", encoding="utf-8", newline="\r\n" if sys.platform.startswith("win") else "\n") as handle:
        handle.write("\n".join(lines) + "\n")
    try:
        st = os.stat(path)
        os.chmod(tmp, stat.S_IMODE(st.st_mode))
        if hasattr(os, "chown") and os.geteuid() == 0:
            os.chown(tmp, st.st_uid, st.st_gid)
    except (OSError, AttributeError):
        pass
    os.replace(tmp, path)


def list_value(values, key):
    return [x.strip() for x in values.get(key, "").split(",") if x.strip()]


def known_classes(section):
    path = os.path.join(REPO, "config", "classes.txt")
    names, on = [], False
    if os.path.isfile(path):
        for line in open(path, encoding="utf-8"):
            t = line.strip()
            if t.startswith("["):
                on = t == "[%s]" % section
                continue
            if on and t and not t.startswith("#"):
                parts = t.split()
                names.append({"name": parts[0], "diet": parts[1] if len(parts) > 1 else None})
    return names


def overlay_files(kind):
    folder = os.path.join(REPO, "config", "%ss" % kind)
    items = []
    if os.path.isdir(folder):
        for name in sorted(os.listdir(folder)):
            if not name.endswith(".conf"):
                continue
            path = os.path.join(folder, name)
            lines = open(path, encoding="utf-8").read().splitlines()
            desc = re.sub(r"^# [A-Za-z]+: \S+ - ", "", lines[0]) if lines else ""
            settings = dict(l.split("=", 1) for l in lines if re.match(r"^[A-Z_][A-Z0-9_]*=", l))
            items.append({"name": name[:-5], "description": desc, "settings": settings})
    return items


def map_catalog():
    """config/maps.txt -> [{name, branch, status, description}]"""
    path = os.path.join(REPO, "config", "maps.txt")
    out = []
    if os.path.isfile(path):
        for line in open(path, encoding="utf-8"):
            t = line.strip()
            if t and not t.startswith("#"):
                parts = t.split(None, 3)
                out.append({"name": parts[0], "branch": parts[1] if len(parts) > 1 else "-",
                            "status": parts[2] if len(parts) > 2 else "", "description": parts[3] if len(parts) > 3 else ""})
    return out


def number(value, default):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def snapshot_manifest(path):
    try:
        with tarfile.open(path, "r:*") as tar:
            return json.load(tar.extractfile("snapshot.json"))
    except (KeyError, OSError, tarfile.TarError, ValueError):
        return None


# ------------------------------------------------------------------ routing --
ROUTES = []


def route(method, pattern, op_id, tag, summary, auth=True, body=None, params=None, responses=None, status=200):
    def wrap(fn):
        ROUTES.append({"method": method, "pattern": pattern, "regex": re.compile("^" + re.sub(
            r"\{(\w+)\}", r"(?P<\1>[^/]+)", pattern) + "$"), "fn": fn, "op_id": op_id, "tag": tag,
            "summary": summary, "auth": auth, "body": body, "params": params or [], "responses": responses or {},
            "status": status, "doc": (fn.__doc__ or "").strip()})
        return fn
    return wrap


def specificity(r):
    """literal path segments win over {parameters}: /plugins/presets/x is not /plugins/{name}/{op}"""
    return [0 if seg.startswith("{") else -1 for seg in r["pattern"].split("/")]


def obj(props, required=None):
    s = {"type": "object", "properties": props, "additionalProperties": False}
    if required:
        s["required"] = required
    return s


STR = {"type": "string"}
STR_LIST = {"type": "array", "items": STR}
IDS_BODY = obj({"ids": {"type": "array", "items": {"type": "string", "pattern": STEAMID_RE.pattern}, "minItems": 1, "maxItems": 100}}, ["ids"])
CLASSES_BODY = obj({"classes": {"type": "array", "items": {"type": "string", "pattern": CLASS_RE.pattern}, "maxItems": 100}}, ["classes"])
JOB = {"$ref": "#/components/schemas/Job"}
OUTPUT = {"$ref": "#/components/schemas/CommandResult"}


def need(body, key, kind):
    if not isinstance(body, dict) or key not in body:
        raise ApiError(422, "Validation failed", "'%s' is required" % key)
    value = body[key]
    if kind == "list" and not (isinstance(value, list) and all(isinstance(v, str) for v in value)):
        raise ApiError(422, "Validation failed", "'%s' must be a list of strings" % key)
    if kind == "bool" and not isinstance(value, bool):
        raise ApiError(422, "Validation failed", "'%s' must be true or false" % key)
    if kind == "str" and not isinstance(value, str):
        raise ApiError(422, "Validation failed", "'%s' must be a string" % key)
    return value


def check_ids(ids):
    bad = [i for i in ids if not STEAMID_RE.match(i)]
    if bad or not ids or len(ids) > 100:
        raise ApiError(422, "Invalid SteamID64", "not a SteamID64 (17 digits starting with 7656119): %s" % ", ".join(bad[:5]))


def check_classes(names):
    bad = [n for n in names if not CLASS_RE.match(n)]
    if bad or len(names) > 100:
        raise ApiError(422, "Invalid class name", "invalid: %s" % ", ".join(bad[:5]))


def result(code, out):
    return {"ok": code == 0, "exit_code": code, "output": out}


def ensure_ok(code, out, title="Launcher command failed", status=422):
    if code != 0:
        raise ApiError(status, title, out.strip()[-2000:], {"exit_code": code})
    return result(code, out)


class Api(object):
    def __init__(self, env):
        self.env, self.jobs = env, Jobs(env)

    # ---------------------------------------------------------------- system
    @route("GET", "/api/v1/health", "getHealth", "System", "Liveness check (no authentication)", auth=False,
           responses={"200": obj({"status": STR, "version": STR, "api_version": STR})})
    def health(self, req):
        version = open(os.path.join(REPO, "VERSION")).read().strip() if os.path.isfile(os.path.join(REPO, "VERSION")) else "unknown"
        return {"status": "ok", "version": version, "api_version": API_VERSION}

    @route("GET", "/api/v1/status", "getStatus", "Server", "Is the game server running?",
           responses={"200": obj({"running": {"type": "boolean"}, "runtime": STR, "server_name": STR, "detail": STR,
                                  "busy_job": {"type": ["string", "null"]}, "timezone": {"type": "string", "enum": ["local", "utc"]},
                                  "utc_offset_minutes": {"type": "integer"}, "zone": STR})})
    def status(self, req):
        code, out = self.env.run("status", timeout=60)
        if code not in (0, 3):
            raise ApiError(502, "Status unavailable", out.strip()[-1000:])
        v = self.env.values()
        return {"running": code == 0, "runtime": self.env.runtime(), "server_name": v.get("SERVER_NAME", ""),
                "detail": out.strip()[-1000:], "busy_job": self.jobs.busy,
                "timezone": "utc" if isle_logs.is_utc(v) else "local", "utc_offset_minutes": isle_logs.utc_offset_minutes(v),
                "zone": isle_logs.zone_label(v)}

    @route("GET", "/api/v1/info", "getInfo", "Server", "Resolved paths, ports and runtime",
           responses={"200": {"type": "object", "additionalProperties": STR}})
    def info(self, req):
        code, out = self.env.run("info", timeout=60)
        ensure_ok(code, out, status=502)
        info = {}
        for line in out.splitlines():
            m = re.match(r"^([A-Za-z ()/]+?)\s*:\s*(.*)$", line)
            if m:
                info[m.group(1).strip()] = m.group(2).strip()
        return info

    @route("POST", "/api/v1/server/{action}", "runServerAction", "Server",
           "Start a lifecycle action (start, stop, restart, save, backup, update, validate)",
           params=[{"name": "action", "in": "path", "required": True, "schema": {"type": "string", "enum": list(ACTIONS)}}],
           responses={"202": JOB, "409": {"$ref": "#/components/schemas/Problem"}}, status=202)
    def server_action(self, req, action):
        if action not in ACTIONS:
            raise ApiError(404, "Unknown action", "use one of: %s" % ", ".join(ACTIONS))
        return self.jobs.start(action, action)

    @route("GET", "/api/v1/jobs", "listJobs", "Jobs", "Recent jobs (newest first)",
           responses={"200": {"type": "array", "items": JOB}})
    def jobs_list(self, req):
        return sorted(self.jobs.items.values(), key=lambda j: j["created"], reverse=True)

    @route("GET", "/api/v1/jobs/{job_id}", "getJob", "Jobs", "One job with its output",
           params=[{"name": "job_id", "in": "path", "required": True, "schema": STR}], responses={"200": JOB})
    def job_get(self, req, job_id):
        return self.jobs.get(job_id)

    @route("GET", "/api/v1/logs", "getLogs", "Server", "Last lines of the server log",
           params=[{"name": "lines", "in": "query", "schema": {"type": "integer", "minimum": 1, "maximum": 2000, "default": 200}}],
           responses={"200": obj({"lines": STR_LIST})})
    def logs(self, req):
        try:
            n = max(1, min(2000, int(req.query.get("lines", ["200"])[0])))
        except ValueError:
            raise ApiError(422, "Validation failed", "'lines' must be an integer")
        code, out = self.env.run("logs", timeout=60)
        return {"lines": out.splitlines()[-n:], "exit_code": code}

    def _log_dir(self):
        return isle_logs.log_dir(self.env.conf, self.env.values())

    @route("GET", "/api/v1/log-files", "listLogFiles", "Server",
           "This project's log files (launcher, server console, web UI), newest first",
           responses={"200": {"type": "array", "items": obj({"name": STR, "kind": STR, "bytes": {"type": "integer"}, "modified": STR})}})
    def log_files(self, req):
        return isle_logs.listing(self._log_dir())

    @route("GET", "/api/v1/log-files/{name}", "getLogFile", "Server", "Last lines of one log file",
           params=[{"name": "name", "in": "path", "required": True, "schema": {"type": "string", "pattern": isle_logs.NAME_RE.pattern}},
                   {"name": "lines", "in": "query", "schema": {"type": "integer", "minimum": 1, "maximum": 5000, "default": 200}}],
           responses={"200": obj({"name": STR, "lines": STR_LIST})})
    def log_file(self, req, name):
        if not isle_logs.NAME_RE.match(name):
            raise ApiError(404, "Log file not found", name)
        path = os.path.join(self._log_dir(), name)
        if not os.path.isfile(path):
            raise ApiError(404, "Log file not found", name)
        try:
            n = max(1, min(5000, int(req.query.get("lines", ["200"])[0])))
        except ValueError:
            raise ApiError(422, "Validation failed", "'lines' must be an integer")
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - 512 * 1024))
            text = handle.read().decode("utf-8", "replace")
        return {"name": name, "lines": text.splitlines()[-n:]}

    @route("POST", "/api/v1/rcon", "sendRcon", "Server", "Send an RCON command to the running server",
           body=obj({"command": {"type": "string", "enum": sorted(isle_rcon.COMMANDS)}, "args": STR_LIST}, ["command"]),
           responses={"200": obj({"reply": STR})})
    def rcon(self, req):
        command = need(req.body, "command", "str")
        if command not in isle_rcon.COMMANDS:
            raise ApiError(422, "Unknown RCON command", "use one of: %s" % ", ".join(sorted(isle_rcon.COMMANDS)))
        args = req.body.get("args", [])
        if not isinstance(args, list) or not all(isinstance(a, str) and len(a) <= 500 for a in args):
            raise ApiError(422, "Validation failed", "'args' must be a list of short strings")
        v = self.env.values()
        if not v.get("RCON_PASSWORD"):
            raise ApiError(409, "RCON is not configured", "RCON_PASSWORD is empty")
        try:
            reply = isle_rcon.send_command("127.0.0.1", int(v.get("RCON_PORT") or 8888), v["RCON_PASSWORD"],
                                           isle_rcon.COMMANDS[command], " ".join(args))
        except (OSError, PermissionError) as exc:
            raise ApiError(502, "RCON failed", "%s (is the server running?)" % exc)
        return {"reply": reply.strip()}

    # ---------------------------------------------------------------- config
    @route("GET", "/api/v1/config", "getConfig", "Settings", "All settings with metadata (secrets masked)",
           responses={"200": obj({"settings": {"type": "array", "items": {"$ref": "#/components/schemas/Setting"}}})})
    def config_get(self, req):
        values = self.env.values()
        out = []
        for meta in parse_example(self.env.example):
            item = dict(meta)
            val = values.get(meta["key"], "")
            item["value"] = MASK if (meta["secret"] and val) else val
            out.append(item)
        return {"settings": out}

    @route("PATCH", "/api/v1/config", "patchConfig", "Settings",
           "Change settings (validated with the launcher's check, rolled back on errors)",
           body=obj({"values": {"type": "object", "additionalProperties": STR}}, ["values"]),
           responses={"200": obj({"changed": STR_LIST, "check": OUTPUT}), "422": {"$ref": "#/components/schemas/Problem"}})
    def config_patch(self, req):
        values = req.body.get("values") if isinstance(req.body, dict) else None
        if not isinstance(values, dict) or not values:
            raise ApiError(422, "Validation failed", "'values' must be a non-empty object")
        known = {m["key"]: m for m in parse_example(self.env.example)}
        updates = {}
        for key, value in values.items():
            if key not in known:
                raise ApiError(422, "Unknown setting", "'%s' is not a server.conf key" % key)
            if not known[key]["editable"]:
                raise ApiError(403, "Setting is locked", "'%s' is machine-specific; change it with the installer" % key)
            if not isinstance(value, str) or "\n" in value or "\r" in value or len(value) > 1000:
                raise ApiError(422, "Validation failed", "'%s' must be a single-line string (max 1000 chars)" % key)
            if value == MASK:
                continue  # masked secret sent back unchanged
            updates[key] = value
        if not updates:
            return {"changed": [], "check": result(0, "nothing to change")}
        backup = self.env.conf + ".bak-api"
        with open(self.env.conf, "rb") as src, open(backup, "wb") as dst:
            dst.write(src.read())
        write_conf_values(self.env.conf, updates)
        code, out = self.env.run("check", timeout=60)
        if code != 0:
            os.replace(backup, self.env.conf)
            raise ApiError(422, "Invalid configuration - nothing was changed", out.strip()[-2000:])
        os.remove(backup)
        return {"changed": sorted(updates), "check": result(code, out)}

    @route("GET", "/api/v1/config/check", "checkConfig", "Settings", "Validate server.conf",
           responses={"200": OUTPUT})
    def config_check(self, req):
        return result(*self.env.run("check", timeout=60))

    # --------------------------------------------------------------- players
    @route("GET", "/api/v1/admins", "listAdmins", "Players", "Admin SteamID64s", responses={"200": obj({"ids": STR_LIST})})
    def admins_list(self, req):
        return {"ids": list_value(self.env.values(), "ADMIN_STEAM_IDS")}

    @route("POST", "/api/v1/admins", "addAdmins", "Players", "Add admins (applied on restart)", body=IDS_BODY,
           responses={"200": OUTPUT})
    def admins_add(self, req):
        ids = need(req.body, "ids", "list"); check_ids(ids)
        return ensure_ok(*self.env.run("admins", ["add"] + ids))

    @route("DELETE", "/api/v1/admins/{steam_id}", "removeAdmin", "Players", "Remove an admin",
           params=[{"name": "steam_id", "in": "path", "required": True, "schema": {"type": "string", "pattern": STEAMID_RE.pattern}}],
           responses={"200": OUTPUT})
    def admins_remove(self, req, steam_id):
        check_ids([steam_id])
        return ensure_ok(*self.env.run("admins", ["remove", steam_id]))

    @route("GET", "/api/v1/whitelist", "getWhitelist", "Players", "Whitelist state and SteamID64s",
           responses={"200": obj({"enabled": {"type": "boolean"}, "ids": STR_LIST})})
    def whitelist_get(self, req):
        v = self.env.values()
        return {"enabled": v.get("WHITELIST_ENABLED", "false").lower() in ("true", "yes", "1", "on"),
                "ids": list_value(v, "WHITELIST_IDS")}

    @route("POST", "/api/v1/whitelist", "addWhitelist", "Players", "Whitelist players (live via RCON when running)",
           body=IDS_BODY, responses={"200": OUTPUT})
    def whitelist_add(self, req):
        ids = need(req.body, "ids", "list"); check_ids(ids)
        return ensure_ok(*self.env.run("whitelist", ["add"] + ids))

    @route("DELETE", "/api/v1/whitelist/{steam_id}", "removeWhitelist", "Players", "Remove a player from the whitelist",
           params=[{"name": "steam_id", "in": "path", "required": True, "schema": {"type": "string", "pattern": STEAMID_RE.pattern}}],
           responses={"200": OUTPUT})
    def whitelist_remove(self, req, steam_id):
        check_ids([steam_id])
        return ensure_ok(*self.env.run("whitelist", ["remove", steam_id]))

    @route("PUT", "/api/v1/whitelist/enabled", "setWhitelistEnabled", "Players", "Turn the whitelist on or off",
           body=obj({"enabled": {"type": "boolean"}}, ["enabled"]), responses={"200": OUTPUT})
    def whitelist_enabled(self, req):
        on = need(req.body, "enabled", "bool")
        return ensure_ok(*self.env.run("whitelist", ["on" if on else "off"]))

    def _classes_get(self, key, section):
        return {"classes": list_value(self.env.values(), key), "known": known_classes(section)}

    @route("GET", "/api/v1/classes", "getClasses", "Roster", "Playable roster (empty = all) and known classes",
           responses={"200": obj({"classes": STR_LIST, "known": {"type": "array", "items": obj({"name": STR, "diet": {"type": ["string", "null"]}})}})})
    def classes_get(self, req):
        return self._classes_get("ALLOWED_CLASSES", "playable")

    @route("PUT", "/api/v1/classes", "setClasses", "Roster", "Set the playable roster (empty list = all classes)",
           body=CLASSES_BODY, responses={"200": OUTPUT})
    def classes_set(self, req):
        names = need(req.body, "classes", "list"); check_classes(names)
        return ensure_ok(*self.env.run("classes", ["set"] + names if names else ["reset"]))

    @route("POST", "/api/v1/classes/preset", "applyRoster", "Roster", "Apply a roster preset",
           body=obj({"name": STR}, ["name"]), responses={"200": OUTPUT})
    def classes_preset(self, req):
        name = need(req.body, "name", "str")
        if not NAME_RE.match(name) or not os.path.isfile(os.path.join(REPO, "config", "rosters", name + ".txt")):
            raise ApiError(404, "Unknown roster", name)
        return ensure_ok(*self.env.run("classes", ["preset", name]))

    @route("GET", "/api/v1/rosters", "listRosters", "Roster", "Roster presets",
           responses={"200": {"type": "array", "items": obj({"name": STR, "description": STR, "classes": STR_LIST})}})
    def rosters(self, req):
        folder, out = os.path.join(REPO, "config", "rosters"), []
        for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
            if name.endswith(".txt"):
                lines = open(os.path.join(folder, name), encoding="utf-8").read().splitlines()
                out.append({"name": name[:-4], "description": re.sub(r"^# Roster: \S+ - ", "", lines[0]) if lines else "",
                            "classes": [l.strip() for l in lines if l.strip() and not l.startswith("#")]})
        return out

    @route("GET", "/api/v1/ai-classes", "getAiClasses", "Roster", "Disabled AI classes and known AI classes",
           responses={"200": obj({"classes": STR_LIST, "known": {"type": "array", "items": obj({"name": STR, "diet": {"type": ["string", "null"]}})}})})
    def ai_get(self, req):
        return self._classes_get("DISABLED_AI_CLASSES", "ai")

    @route("PUT", "/api/v1/ai-classes", "setAiClasses", "Roster", "Set the disabled AI classes (empty = none)",
           body=CLASSES_BODY, responses={"200": OUTPUT})
    def ai_set(self, req):
        names = need(req.body, "classes", "list"); check_classes(names)
        return ensure_ok(*self.env.run("ai-classes", ["set"] + names if names else ["reset"]))

    # ------------------------------------------------------ profiles/presets
    @route("GET", "/api/v1/profiles", "listProfiles", "Profiles", "Play-style profiles",
           responses={"200": {"type": "array", "items": {"$ref": "#/components/schemas/Overlay"}}})
    def profiles(self, req):
        return overlay_files("profile")

    @route("POST", "/api/v1/profiles/{name}/apply", "applyProfile", "Profiles", "Apply a profile (validated, rolled back on errors)",
           params=[{"name": "name", "in": "path", "required": True, "schema": STR}], responses={"200": OUTPUT})
    def profile_apply(self, req, name):
        if name not in [p["name"] for p in overlay_files("profile")]:
            raise ApiError(404, "Unknown profile", name)
        return ensure_ok(*self.env.run("profile", ["apply", name]))

    @route("GET", "/api/v1/presets", "listPresets", "Profiles", "Stackable presets",
           responses={"200": {"type": "array", "items": {"$ref": "#/components/schemas/Overlay"}}})
    def presets(self, req):
        return overlay_files("preset")

    @route("POST", "/api/v1/presets/apply", "applyPresets", "Profiles", "Apply presets left to right",
           body=obj({"names": {"type": "array", "items": STR, "minItems": 1}}, ["names"]), responses={"200": OUTPUT})
    def presets_apply(self, req):
        names = need(req.body, "names", "list")
        known = [p["name"] for p in overlay_files("preset")]
        bad = [n for n in names if n not in known]
        if bad or not names:
            raise ApiError(404, "Unknown preset", ", ".join(bad) or "no presets given")
        return ensure_ok(*self.env.run("preset", ["apply"] + names))

    # ------------------------------------------------------------- map & AI
    @route("GET", "/api/v1/maps", "listMaps", "World", "Known maps (config/maps.txt) and the current map",
           responses={"200": obj({"current": STR, "branch": STR, "maps": {"type": "array", "items": obj({
               "name": STR, "branch": STR, "status": STR, "description": STR, "current": {"type": "boolean"}})}})})
    def world_maps(self, req):
        v = self.env.values()
        cur = v.get("MAP_NAME", "Gateway")
        items = map_catalog()
        for m in items:
            m["current"] = m["name"] == cur
        return {"current": cur, "branch": v.get("STEAM_BRANCH", ""), "maps": items}

    @route("PUT", "/api/v1/map", "setMap", "World", "Switch the map (and its Steam branch; update before the next start)",
           body=obj({"name": STR, "keep_branch": {"type": "boolean"}}, ["name"]), responses={"200": OUTPUT})
    def world_map_set(self, req):
        name = need(req.body, "name", "str")
        if name not in [m["name"] for m in map_catalog()]:
            raise ApiError(404, "Unknown map", "%s (names are case-sensitive; see GET /api/v1/maps)" % name)
        args = ["set", name] + (["--keep-branch"] if req.body.get("keep_branch") is True else [])
        return ensure_ok(*self.env.run("maps", args))

    @route("GET", "/api/v1/ai", "getAi", "World", "AI spawning, density, spawn interval, disabled classes and AI presets",
           responses={"200": obj({"spawn": {"type": "boolean"}, "density": {"type": "number"}, "interval": {"type": "integer"},
                                  "disabled": STR_LIST, "known": {"type": "array", "items": obj({"name": STR, "diet": {"type": ["string", "null"]}})},
                                  "presets": {"type": "array", "items": {"$ref": "#/components/schemas/Overlay"}}})})
    def world_ai(self, req):
        v = self.env.values()
        return {"spawn": v.get("SPAWN_AI", "true").lower() in ("true", "yes", "1", "on"),
                "density": number(v.get("AI_DENSITY"), 1.0), "interval": int(number(v.get("AI_SPAWN_INTERVAL"), 40)),
                "disabled": list_value(v, "DISABLED_AI_CLASSES"), "known": known_classes("ai"),
                "presets": [p for p in overlay_files("preset") if p["name"].startswith("ai-")]}

    @route("PATCH", "/api/v1/ai", "setAi", "World", "Change AI spawning, density (live via RCON) and spawn interval",
           body=obj({"spawn": {"type": "boolean"}, "density": {"type": "number", "minimum": 0, "maximum": 10},
                     "interval": {"type": "integer", "minimum": 1, "maximum": 86400}}), responses={"200": OUTPUT})
    def world_ai_patch(self, req):
        body = req.body if isinstance(req.body, dict) else {}
        if not body:
            raise ApiError(422, "Validation failed", "send spawn, density and/or interval")
        unknown = [k for k in body if k not in ("spawn", "density", "interval")]
        if unknown:
            raise ApiError(422, "Validation failed", "unknown field(s): %s" % ", ".join(unknown))
        steps = []
        if "spawn" in body:
            if not isinstance(body["spawn"], bool):
                raise ApiError(422, "Validation failed", "'spawn' must be true or false")
            steps.append(["on" if body["spawn"] else "off"])
        if "density" in body:
            d = body["density"]
            if isinstance(d, bool) or not isinstance(d, (int, float)) or not 0 <= d <= 10:
                raise ApiError(422, "Validation failed", "'density' must be a number from 0 to 10")
            steps.append(["density", ("%g" % d)])
        if "interval" in body:
            i = body["interval"]
            if isinstance(i, bool) or not isinstance(i, int) or not 1 <= i <= 86400:
                raise ApiError(422, "Validation failed", "'interval' must be whole seconds from 1 to 86400")
            steps.append(["interval", str(i)])
        out = []
        for args in steps:
            code, text = self.env.run("ai", args)
            ensure_ok(code, text)
            out.append(text.strip())
        return result(0, "\n".join(out))

    @route("POST", "/api/v1/ai/preset", "applyAiPreset", "World", "Apply an AI preset (ai-*)",
           body=obj({"name": STR}, ["name"]), responses={"200": OUTPUT})
    def world_ai_preset(self, req):
        name = need(req.body, "name", "str")
        if not name.startswith("ai-") or name not in [p["name"] for p in overlay_files("preset")]:
            raise ApiError(404, "Unknown AI preset", name)
        return ensure_ok(*self.env.run("ai", ["preset", name]))

    # --------------------------------------------------------------- plugins
    def _plugin_ctx(self):
        return isle_plugins.Context(self.env.conf, self.env.launcher, self.env.runtime())

    @route("GET", "/api/v1/plugins", "listPlugins", "Plugins", "Installed and available plugins, and presets",
           responses={"200": obj({"plugins": {"type": "array", "items": {"$ref": "#/components/schemas/Plugin"}},
                                  "presets": {"type": "object", "additionalProperties": STR_LIST}})})
    def plugins(self, req):
        ctx = self._plugin_ctx()
        entries, presets = isle_plugins.load_catalogs(ctx, quiet=True)
        inst, enabled = isle_plugins.installed(ctx), set(ctx.enabled())
        out = []
        for name in sorted(set(entries) | set(inst)):
            m = inst.get(name) or entries.get(name, {})
            out.append({"name": name, "version": m.get("version", ""), "description": m.get("description", ""),
                        "installed": name in inst, "enabled": name in enabled,
                        "source": entries.get(name, {}).get("catalog", "local"), "tags": entries.get(name, {}).get("tags", [])})
        return {"plugins": out, "presets": presets}

    @route("GET", "/api/v1/plugins/sources", "listPluginSources", "Plugins", "Extra plugin catalogs (JSON over HTTPS)",
           responses={"200": obj({"sources": STR_LIST})})
    def plugin_sources(self, req):
        return {"sources": self._plugin_ctx().sources()}

    @route("POST", "/api/v1/plugins/sources", "addPluginSource", "Plugins", "Add a plugin catalog URL (third-party code: add only catalogs you trust)",
           body=obj({"url": {"type": "string", "pattern": "^https://"}}, ["url"]), responses={"200": OUTPUT})
    def plugin_source_add(self, req):
        url = need(req.body, "url", "str").strip()
        if not re.match(r"^https://[^\s]+$", url) or len(url) > 500:
            raise ApiError(422, "Validation failed", "a catalog must be an https:// URL")
        return ensure_ok(*self.env.run("plugins", ["sources", "add", url]))

    @route("DELETE", "/api/v1/plugins/sources", "removePluginSource", "Plugins", "Remove a plugin catalog URL",
           params=[{"name": "url", "in": "query", "required": True, "schema": STR}], responses={"200": OUTPUT})
    def plugin_source_remove(self, req):
        url = (req.query.get("url") or [""])[0]
        if url not in self._plugin_ctx().sources():
            raise ApiError(404, "Unknown catalog", url)
        return ensure_ok(*self.env.run("plugins", ["sources", "remove", url]))

    @route("GET", "/api/v1/plugins/community", "listCommunity", "Plugins",
           "Community tools, libraries and guides (third-party, listed not endorsed) and notes on mods",
           responses={"200": {"type": "object"}})
    def plugin_community(self, req):
        return isle_plugins.community_data()

    @route("GET", "/api/v1/plugins/{name}", "getPlugin", "Plugins", "Plugin details and settings (secrets masked)",
           params=[{"name": "name", "in": "path", "required": True, "schema": STR}],
           responses={"200": {"type": "object"}})
    def plugin_get(self, req, name):
        ctx = self._plugin_ctx()
        m = isle_plugins.installed(ctx).get(name)
        if not m:
            raise ApiError(404, "Plugin not installed", name)
        cur = ctx.settings(m)
        settings = [{"key": k, "value": MASK if spec.get("secret") and cur.get(k) else cur.get(k, ""),
                     "description": spec.get("description", ""), "secret": bool(spec.get("secret")),
                     "required": bool(spec.get("required"))} for k, spec in sorted(m.get("settings", {}).items())]
        return {"name": name, "version": m["version"], "description": m["description"], "enabled": name in ctx.enabled(),
                "hooks": sorted(m.get("hooks", {})), "commands": sorted(m.get("commands", {})), "settings": settings,
                "usage": m.get("usage", [])}

    @route("POST", "/api/v1/plugins/{name}/{op}", "pluginAction", "Plugins", "install, remove, enable, disable or update a plugin",
           params=[{"name": "name", "in": "path", "required": True, "schema": STR},
                   {"name": "op", "in": "path", "required": True, "schema": {"type": "string", "enum": ["install", "remove", "enable", "disable", "update"]}}],
           responses={"200": OUTPUT})
    def plugin_action(self, req, name, op):
        if op not in ("install", "remove", "enable", "disable", "update") or not NAME_RE.match(name):
            raise ApiError(404, "Unknown plugin action", "%s %s" % (op, name))
        return ensure_ok(*self.env.run("plugins", [op, name], timeout=600))

    @route("PATCH", "/api/v1/plugins/{name}/config", "configurePlugin", "Plugins", "Change plugin settings",
           params=[{"name": "name", "in": "path", "required": True, "schema": STR}],
           body=obj({"settings": {"type": "object", "additionalProperties": STR}}, ["settings"]), responses={"200": OUTPUT})
    def plugin_config(self, req, name):
        settings = req.body.get("settings") if isinstance(req.body, dict) else None
        if not isinstance(settings, dict) or not settings or not NAME_RE.match(name):
            raise ApiError(422, "Validation failed", "'settings' must be a non-empty object")
        pairs = []
        for k, v in settings.items():
            if not re.match(r"^[A-Z_][A-Z0-9_]*$", k) or not isinstance(v, str) or "\n" in v or len(v) > 2000:
                raise ApiError(422, "Validation failed", "bad setting %s" % k)
            if v != MASK:
                pairs.append("%s=%s" % (k, v))
        if not pairs:
            return result(0, "nothing to change")
        return ensure_ok(*self.env.run("plugins", ["config", name] + pairs))

    @route("POST", "/api/v1/plugins/presets/{preset}", "applyPluginPreset", "Plugins", "Install and enable a plugin preset",
           params=[{"name": "preset", "in": "path", "required": True, "schema": STR}], responses={"200": OUTPUT})
    def plugin_preset(self, req, preset):
        if not NAME_RE.match(preset):
            raise ApiError(404, "Unknown preset", preset)
        return ensure_ok(*self.env.run("plugins", ["preset", preset], timeout=600))

    # ------------------------------------------------------------- snapshots
    @route("GET", "/api/v1/snapshots", "listSnapshots", "Snapshots", "Snapshots in the snapshots folder",
           responses={"200": {"type": "array", "items": {"$ref": "#/components/schemas/Snapshot"}}})
    def snapshots(self, req):
        out = []
        if os.path.isdir(self.env.snap_dir):
            for name in sorted(os.listdir(self.env.snap_dir), reverse=True):
                path = os.path.join(self.env.snap_dir, name)
                if SNAP_RE.match(name) and os.path.isfile(path):
                    m = snapshot_manifest(path) or {}
                    out.append({"name": name, "bytes": os.path.getsize(path), "created": m.get("created"),
                                "server_name": m.get("server_name"), "source": m.get("source"), "parts": sorted(m.get("parts", {}))})
        return out

    @route("POST", "/api/v1/snapshots", "createSnapshot", "Snapshots", "Create a snapshot (job)",
           body=obj({"include": {"type": "array", "items": {"type": "string", "enum": ["worlds", "backups", "settings", "overrides", "plugins"]}}}),
           responses={"202": JOB}, status=202)
    def snapshot_create(self, req):
        parts = (req.body or {}).get("include") or ["worlds", "settings", "overrides", "plugins"]
        if not isinstance(parts, list) or any(p not in ("worlds", "backups", "settings", "overrides", "plugins") for p in parts):
            raise ApiError(422, "Validation failed", "include: worlds, backups, settings, overrides, plugins")
        os.makedirs(self.env.snap_dir, exist_ok=True)
        out = os.path.join(self.env.snap_dir, "theisle-snapshot_%s.tar.gz" % isle_logs.stamp(self.env.values()))
        return self.jobs.start("snapshot-create", "snapshot", ["create", "--include", ",".join(parts), "--output", out])

    def _snap_path(self, name):
        if not SNAP_RE.match(name):
            raise ApiError(404, "Snapshot not found", name)
        path = os.path.join(self.env.snap_dir, name)
        if not os.path.isfile(path):
            raise ApiError(404, "Snapshot not found", name)
        return path

    @route("POST", "/api/v1/snapshots/{name}/restore", "restoreSnapshot", "Snapshots", "Restore a snapshot (job)",
           params=[{"name": "name", "in": "path", "required": True, "schema": STR}],
           body=obj({"include": STR_LIST, "overwrite": {"type": "boolean"}, "stop": {"type": "boolean"}}),
           responses={"202": JOB}, status=202)
    def snapshot_restore(self, req, name):
        path, body = self._snap_path(name), req.body or {}
        args = ["restore", path]
        parts = body.get("include")
        if parts:
            if not isinstance(parts, list) or any(p not in ("worlds", "backups", "settings", "overrides", "plugins") for p in parts):
                raise ApiError(422, "Validation failed", "include: worlds, backups, settings, overrides, plugins")
            args += ["--include", ",".join(parts)]
        if body.get("overwrite") is True:
            args.append("--overwrite")
        if body.get("stop") is True:
            args.append("--stop")
        return self.jobs.start("snapshot-restore", "snapshot", args)

    @route("DELETE", "/api/v1/snapshots/{name}", "deleteSnapshot", "Snapshots", "Delete a snapshot file",
           params=[{"name": "name", "in": "path", "required": True, "schema": STR}], responses={"204": {}}, status=204)
    def snapshot_delete(self, req, name):
        os.remove(self._snap_path(name))
        return None


# ------------------------------------------------------------- OpenAPI spec --
def build_spec():
    paths = {}
    for r in ROUTES:
        op = {"operationId": r["op_id"], "tags": [r["tag"]], "summary": r["summary"], "responses": {}}
        if r["doc"]:
            op["description"] = r["doc"]
        if r["params"]:
            op["parameters"] = r["params"]
        if r["body"]:
            op["requestBody"] = {"required": True, "content": {"application/json": {"schema": r["body"]}}}
        for code, schema in (r["responses"] or {"200": {}}).items():
            op["responses"][code] = {"description": {"200": "OK", "202": "Accepted - poll the job", "204": "Deleted",
                                                     "409": "Conflict", "422": "Validation failed"}.get(code, "Response")}
            if schema and code != "204":
                ctype = "application/problem+json" if schema == {"$ref": "#/components/schemas/Problem"} else "application/json"
                op["responses"][code]["content"] = {ctype: {"schema": schema}}
        problem = {"description": "Error", "content": {"application/problem+json": {"schema": {"$ref": "#/components/schemas/Problem"}}}}
        op["responses"].setdefault("default", problem)
        if r["auth"]:
            op["responses"].setdefault("401", {"description": "Missing or wrong token",
                                               "content": problem["content"]})
            op["responses"].setdefault("429", {"description": "Too many failed logins", "content": problem["content"]})
        else:
            op["security"] = []
        paths.setdefault(r["pattern"], {})[r["method"].lower()] = op
    return {
        "openapi": "3.1.0",
        "info": {"title": "The Isle Dedicated Server API", "version": API_VERSION,
                 "description": "Manage a The Isle (Evrima) dedicated server - natively or in Docker, on Linux or Windows. "
                                "Every action goes through the same launcher as the command line. Authenticate with "
                                "`Authorization: Bearer <token>` (see `isle-server ui-token`). Errors use RFC 7807 problem details.",
                 "license": {"name": "MIT", "identifier": "MIT"}},
        "servers": [{"url": "/"}],
        "security": [{"bearerAuth": []}],
        "tags": [{"name": t} for t in ("System", "Server", "Jobs", "Settings", "Players", "Roster", "World", "Profiles", "Plugins", "Snapshots")],
        "paths": paths,
        "components": {
            "securitySchemes": {"bearerAuth": {"type": "http", "scheme": "bearer"}},
            "schemas": {
                "Problem": obj({"type": STR, "title": STR, "status": {"type": "integer"}, "detail": STR, "instance": STR,
                                "request_id": STR}, ["title", "status"]),
                "Job": obj({"id": STR, "action": STR, "state": {"type": "string", "enum": ["running", "succeeded", "failed"]},
                            "created": STR, "finished": {"type": ["string", "null"]},
                            "exit_code": {"type": ["integer", "null"]}, "output": STR}, ["id", "action", "state"]),
                "CommandResult": obj({"ok": {"type": "boolean"}, "exit_code": {"type": "integer"}, "output": STR}),
                "Setting": obj({"key": STR, "value": STR, "default": STR, "group": STR, "description": STR,
                                "secret": {"type": "boolean"}, "editable": {"type": "boolean"}}),
                "Overlay": obj({"name": STR, "description": STR, "settings": {"type": "object", "additionalProperties": STR}}),
                "Plugin": obj({"name": STR, "version": STR, "description": STR, "installed": {"type": "boolean"},
                               "enabled": {"type": "boolean"}, "source": STR, "tags": STR_LIST}),
                "Snapshot": obj({"name": STR, "bytes": {"type": "integer"}, "created": {"type": ["string", "null"]},
                                 "server_name": {"type": ["string", "null"]}, "source": {"type": ["object", "null"]},
                                 "parts": STR_LIST}),
            },
        },
    }


# ------------------------------------------------------------------ server --
ROUTES_BY_SPECIFICITY = sorted(ROUTES, key=specificity)


class Request(object):
    def __init__(self, query, body):
        self.query, self.body = query, body


class Limiter(object):
    """Lock an address out after too many bad tokens (per minute)."""

    def __init__(self, limit=10, window=60):
        self.limit, self.window, self.fails, self.lock = limit, window, {}, threading.Lock()

    def blocked(self, ip):
        with self.lock:
            hits = [t for t in self.fails.get(ip, []) if time.time() - t < self.window]
            self.fails[ip] = hits
            return len(hits) >= self.limit

    def fail(self, ip):
        with self.lock:
            self.fails.setdefault(ip, []).append(time.time())


CSP = ("default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; "
       "font-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")


def make_handler(api, token, cors, tls, spec):
    limiter = Limiter()

    class Handler(BaseHTTPRequestHandler):
        server_version = "TheIsleAPI"
        sys_version = ""
        # One request per connection: no idle keep-alive threads, and browsers never reuse a connection
        # this threaded server has stopped reading (seen as stuck navigations in Firefox).
        protocol_version = "HTTP/1.0"

        def log_message(self, fmt, *args):  # replaced by structured access log
            pass

        def _headers(self, status, ctype, length, rid, extra=None):
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(length))
            self.send_header("X-Request-ID", rid)
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            if tls:
                self.send_header("Strict-Transport-Security", "max-age=31536000")
            origin = self.headers.get("Origin")
            if cors and origin == cors:
                self.send_header("Access-Control-Allow-Origin", cors)
                self.send_header("Vary", "Origin")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()

        def _json(self, status, payload, rid, extra=None, ctype="application/json"):
            data = b"" if payload is None else json.dumps(payload, indent=None).encode("utf-8")
            headers = {"Cache-Control": "no-store"}
            headers.update(extra or {})
            self._headers(status, ctype + "; charset=utf-8" if data else ctype, len(data), rid, headers)
            if data and self.command != "HEAD":
                self.wfile.write(data)

        def _problem(self, err, rid, path):
            body = {"type": "about:blank", "title": err.title, "status": err.status, "detail": err.detail,
                    "instance": path, "request_id": rid}
            body.update(err.extra)
            extra = {"Retry-After": "60"} if err.status == 429 else None
            if err.status == 401:
                extra = {"WWW-Authenticate": 'Bearer realm="theisle"'}
            self._json(err.status, body, rid, extra, ctype="application/problem+json")

        def _static(self, rel, rid):
            base = os.path.realpath(UI_DIR)
            path = os.path.realpath(os.path.join(base, rel))
            if not (path == base or path.startswith(base + os.sep)) or not os.path.isfile(path):
                raise ApiError(404, "Not found", rel)
            data = open(path, "rb").read()
            ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
            if ctype.startswith("text/") or ctype in ("application/javascript", "image/svg+xml"):
                ctype += "; charset=utf-8"
            self._headers(200, ctype, len(data), rid, {"Content-Security-Policy": CSP, "Cache-Control": "no-cache"})
            if self.command != "HEAD":
                self.wfile.write(data)

        def _dispatch(self):
            rid = (self.headers.get("X-Request-ID") or uuid.uuid4().hex)[:64]
            if not re.match(r"^[A-Za-z0-9._-]+$", rid):
                rid = uuid.uuid4().hex
            start, status = time.time(), 500
            url = urlparse(self.path)
            path = url.path
            try:
                if self.command == "OPTIONS":
                    if not cors:
                        raise ApiError(405, "Method not allowed")
                    self._headers(204, "text/plain", 0, rid, {"Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, DELETE",
                                                             "Access-Control-Allow-Headers": "Authorization, Content-Type, X-Request-ID",
                                                             "Access-Control-Max-Age": "600"})
                    status = 204
                    return
                if path in ("/", "/index.html") and self.command in ("GET", "HEAD"):
                    status = 200; return self._static("index.html", rid)
                if path == "/docs" and self.command in ("GET", "HEAD"):
                    status = 200; return self._static("docs.html", rid)
                if path == "/openapi.json" and self.command in ("GET", "HEAD"):
                    status = 200; return self._json(200, spec, rid, {"Cache-Control": "no-cache"})
                if path.startswith("/assets/") and self.command in ("GET", "HEAD"):
                    status = 200; return self._static(path[len("/assets/"):], rid)
                if not path.startswith("/api/"):
                    raise ApiError(404, "Not found", path)
                match, allowed = None, []
                for r in ROUTES_BY_SPECIFICITY:
                    m = r["regex"].match(path)
                    if m:
                        allowed.append(r["method"])
                        if r["method"] == self.command or (self.command == "HEAD" and r["method"] == "GET"):
                            match = (r, m)
                            break
                if not match:
                    if allowed:
                        raise ApiError(405, "Method not allowed", "allowed: %s" % ", ".join(sorted(set(allowed))))
                    raise ApiError(404, "Not found", path)
                r, m = match
                ip = self.client_address[0]
                if r["auth"]:
                    if limiter.blocked(ip):
                        raise ApiError(429, "Too many failed logins", "try again in a minute")
                    sent = self.headers.get("Authorization", "")
                    supplied = sent[7:].strip() if sent.lower().startswith("bearer ") else ""
                    if not supplied or not hmac.compare_digest(supplied.encode(), token.encode()):
                        limiter.fail(ip)
                        raise ApiError(401, "Authentication required", "send Authorization: Bearer <token>")
                body = None
                length = int(self.headers.get("Content-Length") or 0)
                if length > MAX_BODY:
                    raise ApiError(413, "Request too large", "max %d bytes" % MAX_BODY)
                if length:
                    if "application/json" not in (self.headers.get("Content-Type") or ""):
                        raise ApiError(415, "Unsupported media type", "send application/json")
                    try:
                        body = json.loads(self.rfile.read(length).decode("utf-8"))
                    except ValueError:
                        raise ApiError(400, "Malformed JSON")
                elif r["body"] and r["body"].get("required"):
                    raise ApiError(422, "Validation failed", "a JSON body is required")
                payload = r["fn"](api, Request(parse_qs(url.query), body), **m.groupdict())
                status = r["status"]
                self._json(status, payload, rid, {"Location": "/api/v1/jobs/%s" % payload["id"]} if status == 202 else None)
            except ApiError as err:
                status = err.status
                self._problem(err, rid, path)
            except Exception as exc:  # noqa: BLE001 - never leak a traceback to the client
                status = 500
                sys.stderr.write("[api] %s %s failed: %r\n" % (self.command, path, exc))
                self._problem(ApiError(500, "Internal error", "see the server log (request %s)" % rid), rid, path)
            finally:
                line = '%s %s "%s %s" %d %dms rid=%s\n' % (now_iso(), self.client_address[0], self.command,
                                                           path, status, (time.time() - start) * 1000, rid)
                sys.stdout.write(line)
                sys.stdout.flush()
                if ACCESS_LOG["log"]:
                    with ACCESS_LOG["lock"]:
                        try:
                            ACCESS_LOG["log"].write(line)
                        except OSError:
                            ACCESS_LOG["log"] = None

        do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = _dispatch

    return Handler


class Server(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64   # browsers open several connections at once


def load_token(path):
    env_token = os.environ.get("ISLE_UI_TOKEN")
    if env_token:
        return env_token, False
    if os.path.isfile(path):
        tok = open(path).read().strip()
        if len(tok) >= 16:
            return tok, False
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tok = secrets.token_urlsafe(32)
    old = os.umask(0o077)
    try:
        with open(path, "w") as handle:
            handle.write(tok + "\n")
    finally:
        os.umask(old)
    return tok, True


def main(argv=None):
    ap = argparse.ArgumentParser(description="The Isle server API and web UI")
    ap.add_argument("--conf"); ap.add_argument("--launcher"); ap.add_argument("--runtime")
    ap.add_argument("--host"); ap.add_argument("--port", type=int)
    ap.add_argument("--cert"); ap.add_argument("--key")
    ap.add_argument("--token-file"); ap.add_argument("--cors"); ap.add_argument("--snapshot-dir")
    ap.add_argument("--open", action="store_true", help="open the UI in a browser")
    ap.add_argument("--print-token", action="store_true", help="print the token and exit")
    ap.add_argument("--rotate-token", action="store_true", help="replace the token and exit")
    ap.add_argument("--print-spec", action="store_true", help="print the OpenAPI document and exit")
    o = ap.parse_args(argv)
    env = Env(o)
    values = env.values()
    token_file = o.token_file or os.path.join(os.path.dirname(env.conf), "ui-token")
    if o.print_spec:
        print(json.dumps(build_spec(), indent=2)); return 0
    if o.rotate_token and os.path.isfile(token_file):
        os.remove(token_file)
    token, created = load_token(token_file)
    if o.print_token or o.rotate_token:
        print(token); return 0
    host = o.host or values.get("UI_HOST") or "127.0.0.1"
    port = o.port or int(values.get("UI_PORT") or 8090)
    tls = bool(o.cert and o.key)
    loopback = host in ("127.0.0.1", "::1", "localhost")
    if not loopback and not tls:
        print("[WARN] Listening on %s without TLS - put it behind a TLS reverse proxy or use --cert/--key" % host, file=sys.stderr)
    api = Api(env)
    try:  # access log in <LOG_DIR>/ui_<stamp>.log, rotated like the other logs
        ACCESS_LOG["log"] = isle_logs.RotatingLog(isle_logs.log_dir(env.conf, values), "ui", values)
    except OSError as exc:
        print("[WARN] No access log file (%s) - logging to the console only" % exc, file=sys.stderr)
    httpd = Server((host, port), make_handler(api, token, o.cors, tls, build_spec()))
    if tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(o.cert, o.key)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    url = "%s://%s:%d/" % ("https" if tls else "http", "localhost" if loopback else host, port)
    print("[ OK ] The Isle web UI on %s  (API docs: %sdocs)" % (url, url), flush=True)
    print("       Token: %s%s" % (token_file if not os.environ.get("ISLE_UI_TOKEN") else "$ISLE_UI_TOKEN",
                                  "  (new token created: %s)" % token if created else ""), flush=True)
    if o.open:
        print("       Sign in with: %s" % token, flush=True)
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()

    def stop(*_):
        threading.Thread(target=httpd.shutdown, daemon=True).start()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(sig, stop)
        except (ValueError, OSError):
            pass
    try:
        httpd.serve_forever()
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
