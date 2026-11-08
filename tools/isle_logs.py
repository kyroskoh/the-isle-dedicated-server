#!/usr/bin/env python3
"""
isle_logs.py - time zone, timestamped names and log rotation for The Isle server scripts.

Every log file of this project is named KIND_yyyymmdd_hhmmss.log (launcher, server, ui) in
LOG_DIR (default <scripts>/logs; Docker: /data/logs). A new file starts when the current one is
bigger than LOG_MAX_SIZE_MB, and only the newest LOG_RETENTION files of each kind are kept
(0 = keep all). TIMEZONE=local|utc in server.conf picks the clock for timestamps and names.

    isle_logs.py [--conf FILE] write KIND [--tee]   stdin -> rotating KIND_*.log (and stdout with --tee)
    isle_logs.py [--conf FILE] current KIND         print the file to append to (rotates when too big)
    isle_logs.py [--conf FILE] prune [--game-dir D] apply LOG_RETENTION (also the game's TheIsle-backup-*.log)
    isle_logs.py [--conf FILE] list [--json]        log files, newest first
    isle_logs.py [--conf FILE] stamp | now          yyyymmdd_hhmmss | "yyyy-mm-dd hh:mm:ss <zone>"

Python 3.6+, standard library only.
"""
import argparse
import json
import os
import re
import sys
import time

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TOOLS)
STAMP = "%Y%m%d_%H%M%S"
KINDS = ("launcher", "server", "ui")
NAME_RE = re.compile(r"^(?P<kind>[a-z][a-z0-9-]*)_(?P<stamp>\d{8}_\d{6})(?:_(?P<n>\d+))?\.log$")
GAME_BACKUP_RE = re.compile(r"^TheIsle-backup-.*\.log$")


def read_conf(path):
    values = {}
    if path and os.path.isfile(path):
        with open(path, encoding="utf-8-sig", errors="replace") as handle:
            for line in handle:
                m = re.match(r"^\s*([A-Z_][A-Z0-9_]*)=(.*)$", line.rstrip("\r\n"))
                if m:
                    values[m.group(1)] = m.group(2).strip().strip('"')
    return values


def is_utc(values):
    return (values.get("TIMEZONE") or os.environ.get("ISLE_TIMEZONE") or "local").strip().lower() in ("utc", "gmt", "z")


def now(values):
    return time.gmtime() if is_utc(values) else time.localtime()


def stamp(values, when=None):
    """yyyymmdd_hhmmss in the configured time zone (the suffix of every dated file)."""
    return time.strftime(STAMP, when or now(values))


def zone_label(values):
    if is_utc(values):
        return "UTC"
    off = -time.altzone if time.daylight and time.localtime().tm_isdst > 0 else -time.timezone
    sign = "+" if off >= 0 else "-"
    return "UTC%s%02d:%02d" % (sign, abs(off) // 3600, abs(off) % 3600 // 60)


def utc_offset_minutes(values):
    if is_utc(values):
        return 0
    lt = time.localtime()
    return int((-time.altzone if (time.daylight and lt.tm_isdst > 0) else -time.timezone) / 60)


def human(values):
    return time.strftime("%Y-%m-%d %H:%M:%S", now(values)) + " " + zone_label(values)


def int_value(values, key, default):
    try:
        return max(0, int(str(values.get(key, default)).strip() or default))
    except ValueError:
        return default


def log_dir(conf, values):
    d = os.environ.get("ISLE_LOG_DIR") or values.get("LOG_DIR") or os.path.join(REPO, "logs")
    if not os.path.isabs(d):
        d = os.path.join(os.path.dirname(os.path.abspath(conf)) if conf else REPO, d)
    return d


def files_of(directory, kind=None):
    """[(name, kind)] of this project's log files, oldest first (the stamp sorts by time)."""
    if not os.path.isdir(directory):
        return []
    out = []
    for name in os.listdir(directory):
        m = NAME_RE.match(name)
        if m and (kind is None or m.group("kind") == kind):
            out.append((m.group("stamp"), int(m.group("n") or 0), name, m.group("kind")))
    return [(n, k) for _, _, n, k in sorted(out)]


def prune(directory, kind, keep):
    """Delete all but the newest `keep` files of `kind` (keep=0: delete nothing). Returns deleted names."""
    if keep <= 0:
        return []
    names = [n for n, _ in files_of(directory, kind)]
    gone = []
    for name in names[:-keep]:
        try:
            os.remove(os.path.join(directory, name))
            gone.append(name)
        except OSError:
            pass
    return gone


def prune_game_logs(game_dir, keep):
    """The game rotates its own log to TheIsle-backup-<date>.log; keep the newest `keep` of those."""
    if keep <= 0 or not game_dir or not os.path.isdir(game_dir):
        return []
    names = sorted((os.path.getmtime(os.path.join(game_dir, n)), n) for n in os.listdir(game_dir) if GAME_BACKUP_RE.match(n))
    gone = []
    for _, name in names[:-keep]:
        try:
            os.remove(os.path.join(game_dir, name))
            gone.append(name)
        except OSError:
            pass
    return gone


class RotatingLog(object):
    """Appends to KIND_<stamp>.log; starts a new file past max_bytes and prunes to `keep` files."""

    def __init__(self, directory, kind, values, max_bytes=None, keep=None, fresh=True):
        self.directory, self.kind, self.values = directory, kind, values
        self.max_bytes = max_bytes if max_bytes is not None else int_value(values, "LOG_MAX_SIZE_MB", 20) * 1024 * 1024
        self.keep = keep if keep is not None else int_value(values, "LOG_RETENTION", 14)
        self.handle, self.path = None, None
        os.makedirs(directory, exist_ok=True)
        if not fresh:
            existing = files_of(directory, kind)
            if existing:
                last = os.path.join(directory, existing[-1][0])
                if not self.max_bytes or os.path.getsize(last) < self.max_bytes:
                    self._open(last)
        if not self.handle:
            self.rotate()

    def _open(self, path):
        old = os.umask(0o027)
        try:
            self.handle = open(path, "a", encoding="utf-8", errors="replace")
            self.handle.seek(0, os.SEEK_END)  # tell() = current size, also for a reopened file
        finally:
            os.umask(old)
        self.path = path

    def new_name(self):
        """KIND_<stamp>.log, or KIND_<stamp>_N.log numbered past every file of the same second,
        so a new file always sorts after the older ones even when some were pruned."""
        st = stamp(self.values)
        taken = [m for m in (NAME_RE.match(n) for n, _ in files_of(self.directory, self.kind)) if m and m.group("stamp") == st]
        if not taken:
            return "%s_%s.log" % (self.kind, st)
        return "%s_%s_%d.log" % (self.kind, st, max(int(m.group("n") or 0) for m in taken) + 1)

    def rotate(self):
        if self.handle:
            self.handle.close()
        self._open(os.path.join(self.directory, self.new_name()))
        prune(self.directory, self.kind, self.keep)
        return self.path

    def write(self, text):
        # rotate lazily, before writing, so no empty file is left behind
        if self.max_bytes and self.handle.tell() >= self.max_bytes:
            self.rotate()
        self.handle.write(text)
        self.handle.flush()

    def close(self):
        if self.handle:
            self.handle.close()
            self.handle = None


def current(directory, kind, values):
    """Path to append to: the newest KIND file while it is under the size limit, else a new one."""
    log = RotatingLog(directory, kind, values, fresh=False)
    log.close()
    return log.path


def listing(directory):
    out = []
    for name, kind in reversed(files_of(directory)):
        path = os.path.join(directory, name)
        st = os.stat(path)
        out.append({"name": name, "kind": kind, "bytes": st.st_size,
                    "modified": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(st.st_mtime))})
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description="Log files and timestamps for The Isle server scripts")
    ap.add_argument("--conf", default=os.environ.get("ISLE_CONF") or os.path.join(REPO, "config", "server.conf"))
    sub = ap.add_subparsers(dest="action")
    w = sub.add_parser("write"); w.add_argument("kind"); w.add_argument("--tee", action="store_true")
    c = sub.add_parser("current"); c.add_argument("kind")
    p = sub.add_parser("prune"); p.add_argument("--game-dir")
    l = sub.add_parser("list"); l.add_argument("--json", action="store_true")
    sub.add_parser("stamp"); sub.add_parser("now"); sub.add_parser("dir")
    o = ap.parse_args(argv)
    values = read_conf(o.conf)
    directory = log_dir(o.conf, values)
    if o.action == "stamp":
        print(stamp(values))
    elif o.action == "now":
        print(human(values))
    elif o.action == "dir":
        print(directory)
    elif o.action == "current":
        print(current(directory, o.kind, values))
    elif o.action == "prune":
        keep = int_value(values, "LOG_RETENTION", 14)
        for kind in sorted({k for _, k in files_of(directory)}):
            for name in prune(directory, kind, keep):
                print("pruned " + name)
        for name in prune_game_logs(o.game_dir, keep):
            print("pruned " + name)
    elif o.action == "list":
        items = listing(directory)
        if o.json:
            print(json.dumps(items, indent=2))
        else:
            for i in items:
                print("%-40s %10d  %s" % (i["name"], i["bytes"], i["modified"]))
    elif o.action == "write":
        log = RotatingLog(directory, o.kind, values)
        stdin = sys.stdin.buffer if hasattr(sys.stdin, "buffer") else sys.stdin
        try:
            for raw in iter(stdin.readline, b""):
                line = raw.decode("utf-8", "replace") if isinstance(raw, bytes) else raw
                log.write(line)
                if o.tee:
                    sys.stdout.write(line)
                    sys.stdout.flush()
        except KeyboardInterrupt:
            pass
        finally:
            log.close()
    else:
        ap.print_help()
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
