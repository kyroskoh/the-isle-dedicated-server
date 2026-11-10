#!/usr/bin/env python3
"""
isle_snapshot.py - portable snapshots of a The Isle server (PRD MIG-01..08).

Python 3.6+, standard library only. One archive format for Linux and Windows,
native and Docker, so a server can move between machines, OSes and runtimes.

    isle_snapshot.py [paths] create  [--include LIST] [--output FILE] [--no-save]
    isle_snapshot.py [paths] restore FILE [--include LIST] [--overwrite] [--all-settings] [--stop]
    isle_snapshot.py [paths] info FILE
    isle_snapshot.py [paths] list

paths (passed by the launchers, which know the resolved locations):
    --conf FILE  --runtime native|docker  --launcher PATH
    --server-dir DIR  --backup-dir DIR  --overrides-dir DIR  --plugins-dir DIR  --owner USER

Parts: worlds, backups, settings, overrides, plugins
(default for create and restore: worlds, settings, overrides, plugins).
"""

import argparse
import datetime
import io
import json
import os
import platform
import re
import shutil
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import time

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)
import isle_rcon  # noqa: E402
import isle_logs  # noqa: E402

FORMAT = 1
PARTS = ("worlds", "backups", "settings", "overrides", "plugins")
DEFAULT_PARTS = ("worlds", "settings", "overrides", "plugins")
# server.conf keys that describe the machine, not the server; not carried over by default
MACHINE_KEYS = {"RUNTIME", "DOCKER_BUILD", "DOCKER_IMAGE", "PUID", "PGID", "STEAMCMD_DIR", "SERVER_DIR",
                "BACKUP_DIR", "INI_OVERRIDES_DIR", "MULTIHOME_IP", "UI_HOST", "UI_PORT", "LOG_DIR",
                "BACKUP_COPY_DIR", "BACKUP_OFFSITE_COMMAND"}
NOT_WORLD = {"Config", "Logs", "Crashes"}
CONTAINER, VOLUME = "theisle", "theisle-data"
PS_NAMES = {"status": "Status", "save": "Save", "stop": "Stop"}


class SnapError(Exception):
    pass


def say(msg):
    print(msg, flush=True)


def ok(msg):
    say("[ OK ] " + msg)


def warn(msg):
    print("[WARN] " + msg, file=sys.stderr, flush=True)


CONF_VALUES = {}


def stamp():
    """yyyymmdd_hhmmss in TIMEZONE (local|utc) - the suffix of every dated file"""
    return isle_logs.stamp(CONF_VALUES)


def version():
    try:
        return open(os.path.join(REPO, "VERSION")).read().strip()
    except OSError:
        return "unknown"


def parse_parts(text, default):
    if not text:
        return list(default)
    parts = [p.strip().lower() for p in text.split(",") if p.strip()]
    if parts == ["all"]:
        return list(PARTS)
    bad = [p for p in parts if p not in PARTS]
    if bad:
        raise SnapError("unknown part(s): %s (valid: %s, or all)" % (", ".join(bad), ", ".join(PARTS)))
    return parts


# ------------------------------------------------------------- environment --
class Env(object):
    def __init__(self, o):
        self.conf = os.path.abspath(o.conf) if o.conf else os.path.join(REPO, "config", "server.conf")
        self.values = isle_rcon.read_conf(self.conf) if os.path.isfile(self.conf) else {}
        CONF_VALUES.clear(); CONF_VALUES.update(self.values)
        self.runtime = (o.runtime or self.values.get("RUNTIME") or "native").lower()
        self.launcher_path = o.launcher or ""
        home = os.path.expanduser("~")
        win = sys.platform.startswith("win")
        self.server_dir = o.server_dir or self.values.get("SERVER_DIR") or (
            r"C:\TheIsle\server" if win else os.path.join(home, "theisle-server"))
        self.backup_dir = o.backup_dir or self.values.get("BACKUP_DIR") or (
            r"C:\TheIsle\backups" if win else os.path.join(home, "theisle-backups"))
        self.overrides_dir = o.overrides_dir or self.values.get("INI_OVERRIDES_DIR") or os.path.join(
            os.path.dirname(self.conf), "overrides")
        self.plugin_state = os.path.join(os.path.dirname(self.conf), "plugins")
        self.plugin_code = o.plugins_dir or os.path.join(REPO, "plugins", "installed")
        self.snap_dir = os.path.join(REPO, "snapshots")
        self.owner = o.owner or ""
        self.image = self.values.get("DOCKER_IMAGE") or "theisle-server:latest"

    # ---- launcher (status/save/stop) ----
    def launcher_cmd(self, command):
        if not self.launcher_path:
            return None
        if self.launcher_path.lower().endswith(".ps1"):
            shell = "powershell" if sys.platform.startswith("win") else "pwsh"
            return [shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", self.launcher_path,
                    PS_NAMES.get(command, command), "-ConfigPath", self.conf]
        return [self.launcher_path, command]

    def launcher(self, command, quiet=True):
        cmd = self.launcher_cmd(command)
        if not cmd:
            return None
        env = dict(os.environ, ISLE_CONF=self.conf, ISLE_RUNTIME=self.runtime)
        out = subprocess.DEVNULL if quiet else None
        return subprocess.call(cmd, env=env, stdout=out, stderr=out)

    def running(self):
        if self.runtime == "docker":
            try:
                out = subprocess.check_output(["docker", "ps", "-q", "--filter", "name=^%s$" % CONTAINER],
                                              stderr=subprocess.DEVNULL).decode().strip()
                return bool(out)
            except (OSError, subprocess.CalledProcessError):
                return False
        rc = self.launcher("status")
        return rc == 0

    # ---- docker helpers ----
    def helper_image(self):
        for img in (self.image, "theisle-server:latest", "debian:bookworm-slim"):
            if subprocess.call(["docker", "image", "inspect", img], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL) == 0:
                return img
        if subprocess.call(["docker", "pull", "-q", "debian:bookworm-slim"], stdout=subprocess.DEVNULL) == 0:
            return "debian:bookworm-slim"
        raise SnapError("no Docker image available to read/write the %s volume" % VOLUME)

    def in_volume(self, script, mounts=(), readonly=False):
        """Run a shell script in a helper container with the data volume at /data."""
        cmd = ["docker", "run", "--rm", "-v", "%s:/data%s" % (VOLUME, ":ro" if readonly else "")]
        for host, target, ro in mounts:
            cmd += ["-v", "%s:%s%s" % (host, target, ":ro" if ro else "")]
        cmd += ["--entrypoint", "sh", self.helper_image(), "-c", script]
        rc = subprocess.call(cmd)
        if rc != 0:
            raise SnapError("docker helper failed (exit %d)" % rc)

    def volume_exists(self):
        return subprocess.call(["docker", "volume", "inspect", VOLUME], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL) == 0


def has_world(path):
    return os.path.isdir(path) and any(n not in NOT_WORLD for n in os.listdir(path))


def copytree_into(src, dst, skip_top=()):
    os.makedirs(dst, exist_ok=True)
    for name in os.listdir(src):
        if name in skip_top:
            continue
        s, d = os.path.join(src, name), os.path.join(dst, name)
        if os.path.isdir(s) and not os.path.islink(s):
            shutil.copytree(s, d, symlinks=False)
        elif os.path.isfile(s):
            shutil.copy2(s, d)


def count(path):
    files = size = 0
    for root, _, names in os.walk(path):
        for n in names:
            files += 1
            size += os.path.getsize(os.path.join(root, n))
    return files, size


def chown_tree(path, owner):
    if not owner or os.name != "posix" or os.geteuid() != 0 or not os.path.exists(path):
        return
    import pwd
    pw = pwd.getpwnam(owner)
    for root, dirs, files in os.walk(path):
        for n in [root] + [os.path.join(root, x) for x in dirs + files]:
            os.lchown(n, pw.pw_uid, pw.pw_gid)


# ------------------------------------------------------------------- create --
def collect(env, parts, stage):
    found = {}
    if "worlds" in parts:
        dest = os.path.join(stage, "world")
        if env.runtime == "docker":
            if env.volume_exists():
                os.makedirs(dest, exist_ok=True)
                env.in_volume("d=/data/server/TheIsle; [ -d $d/Saved ] || exit 0; cd $d && "
                              "tar -cf - --exclude=Saved/Logs --exclude=Saved/Crashes Saved | tar -xf - -C /out "
                              "&& chmod -R a+rX /out", mounts=[(dest, "/out", False)], readonly=True)
        else:
            saved = os.path.join(env.server_dir, "TheIsle", "Saved")
            if os.path.isdir(saved):
                copytree_into(saved, os.path.join(dest, "Saved"), skip_top=("Logs", "Crashes"))
        if os.path.isdir(os.path.join(dest, "Saved")):
            found["worlds"] = count(dest)
    if "backups" in parts:
        dest = os.path.join(stage, "backups")
        if env.runtime == "docker":
            if env.volume_exists():
                os.makedirs(dest, exist_ok=True)
                env.in_volume("[ -d /data/backups ] && cp /data/backups/theisle-* /out/ 2>/dev/null; "
                              "chmod -R a+rX /out; exit 0", mounts=[(dest, "/out", False)], readonly=True)
        elif os.path.isdir(env.backup_dir):
            os.makedirs(dest, exist_ok=True)
            for n in os.listdir(env.backup_dir):
                if n.startswith("theisle-") and os.path.isfile(os.path.join(env.backup_dir, n)):
                    shutil.copy2(os.path.join(env.backup_dir, n), dest)
        if os.path.isdir(dest) and os.listdir(dest):
            found["backups"] = count(dest)
    if "settings" in parts and os.path.isfile(env.conf):
        os.makedirs(os.path.join(stage, "settings"))
        shutil.copy2(env.conf, os.path.join(stage, "settings", "server.conf"))
        found["settings"] = count(os.path.join(stage, "settings"))
    if "overrides" in parts and os.path.isdir(env.overrides_dir):
        inis = [n for n in os.listdir(env.overrides_dir) if n.lower().endswith(".ini")]
        if inis:
            os.makedirs(os.path.join(stage, "overrides"))
            for n in inis:
                shutil.copy2(os.path.join(env.overrides_dir, n), os.path.join(stage, "overrides", n))
            found["overrides"] = count(os.path.join(stage, "overrides"))
    if "plugins" in parts:
        if os.path.isdir(env.plugin_state):
            copytree_into(env.plugin_state, os.path.join(stage, "plugins", "state"))
        if os.path.isdir(env.plugin_code) and os.listdir(env.plugin_code):
            copytree_into(env.plugin_code, os.path.join(stage, "plugins", "installed"))
        if os.path.isdir(os.path.join(stage, "plugins")):
            found["plugins"] = count(os.path.join(stage, "plugins"))
    return found


def cmd_create(env, o):
    parts = parse_parts(o.include, DEFAULT_PARTS)
    if not o.no_save and env.running():
        say("Server is running - asking it to save first")
        if env.launcher("save") not in (0, None):
            warn("save request failed - the snapshot may miss the last few minutes")
    out = o.output or os.path.join(env.snap_dir, "theisle-snapshot_%s.tar.gz" % stamp())
    if os.path.isdir(out):
        out = os.path.join(out, "theisle-snapshot_%s.tar.gz" % stamp())
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    stage = tempfile.mkdtemp(prefix="isle-snap-")
    try:
        found = collect(env, parts, stage)
        if not found:
            raise SnapError("nothing to snapshot (asked for: %s)" % ", ".join(parts))
        manifest = {
            "format": FORMAT,
            "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "tool_version": version(),
            "source": {"os": platform.system(), "runtime": env.runtime, "host": socket.gethostname()},
            "server_name": env.values.get("SERVER_NAME", ""),
            "parts": {k: {"files": v[0], "bytes": v[1]} for k, v in found.items()},
        }
        with open(os.path.join(stage, "snapshot.json"), "w") as handle:
            json.dump(manifest, handle, indent=2)
        old = os.umask(0o077)
        try:
            with tarfile.open(out, "w:gz") as tar:
                for name in sorted(os.listdir(stage)):
                    tar.add(os.path.join(stage, name), arcname=name)
        finally:
            os.umask(old)
        try:
            os.chmod(out, stat.S_IRUSR | stat.S_IWUSR)
        except OSError:
            pass
        chown_tree(out, env.owner)
        ok("Snapshot written: %s" % out)
        for k in PARTS:
            if k in found:
                say("       %-10s %6d file(s) %10s" % (k, found[k][0], human(found[k][1])))
        missing = [p for p in parts if p not in found]
        if missing:
            say("       (nothing found for: %s)" % ", ".join(missing))
        if "settings" in found:
            warn("the snapshot contains server.conf with passwords - keep it private")
        return 0
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return ("%d %s" % (n, unit)) if unit == "B" else ("%.1f %s" % (n, unit))
        n /= 1024.0


# ------------------------------------------------------------------ restore --
def open_snapshot(path, dest):
    if not os.path.isfile(path):
        raise SnapError("no such snapshot: %s" % path)
    with tarfile.open(path, "r:*") as tar:
        for m in tar.getmembers():
            name = m.name.replace("\\", "/")
            if name.startswith("/") or re.match(r"^[A-Za-z]:", name) or ".." in name.split("/"):
                raise SnapError("unsafe path in snapshot: %s" % m.name)
            if m.issym() or m.islnk() or m.isdev():
                raise SnapError("links/devices are not allowed in snapshots: %s" % m.name)
        tar.extractall(dest)
    mpath = os.path.join(dest, "snapshot.json")
    if not os.path.isfile(mpath):
        raise SnapError("%s is not a snapshot (no snapshot.json)" % path)
    manifest = json.load(open(mpath))
    if manifest.get("format") != FORMAT:
        raise SnapError("unsupported snapshot format %r (this tool reads format %d)" % (manifest.get("format"), FORMAT))
    return manifest


def read_raw_conf(path):
    """KEY -> raw right-hand side exactly as written (last occurrence wins)."""
    raw = {}
    with open(path, "r", encoding="utf-8-sig") as handle:
        for line in handle.read().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key.strip()):
                raw[key.strip()] = value.strip()
    return raw


def merge_settings(env, src_conf, all_settings):
    incoming = read_raw_conf(src_conf)
    if not os.path.isfile(env.conf):
        raise SnapError("no server.conf at %s to merge into" % env.conf)
    backup = "%s.bak-snapshot_%s" % (env.conf, stamp())
    shutil.copy2(env.conf, backup)
    with open(env.conf, "r", encoding="utf-8-sig") as handle:
        lines = handle.read().splitlines()
    applied, skipped = [], []
    for key, value in incoming.items():
        if key in MACHINE_KEYS and not all_settings:
            skipped.append(key)
            continue
        if "\n" in value:
            continue
        pattern = re.compile(r"^%s=" % re.escape(key))
        idx = [i for i, l in enumerate(lines) if pattern.match(l)]
        if idx:
            for i in idx:
                lines[i] = "%s=%s" % (key, value)
        else:
            lines.append("%s=%s" % (key, value))
        applied.append(key)
    with open(env.conf, "w", encoding="utf-8", newline="\r\n" if sys.platform.startswith("win") else "\n") as handle:
        handle.write("\n".join(lines) + "\n")
    try:
        os.chmod(env.conf, stat.S_IRUSR | stat.S_IWUSR)
    except OSError:
        pass
    chown_tree(env.conf, env.owner)
    ok("Settings merged: %d key(s) (previous server.conf saved as %s)" % (len(applied), backup))
    if skipped:
        say("       kept this machine's: %s" % ", ".join(sorted(skipped)))


def restore_world(env, src, overwrite):
    ts = stamp()
    if env.runtime == "docker":
        subprocess.call(["docker", "volume", "create", VOLUME], stdout=subprocess.DEVNULL)
        check = ("d=/data/server/TheIsle/Saved; [ -d $d ] && find $d -mindepth 1 -maxdepth 1 "
                 "! -name Config ! -name Logs ! -name Crashes | grep -q . && echo yes || true")
        img = env.helper_image()
        has = subprocess.check_output(["docker", "run", "--rm", "-v", "%s:/data:ro" % VOLUME, "--entrypoint", "sh",
                                       img, "-c", check]).decode().strip() == "yes"
        if has and not overwrite:
            warn("the Docker volume already has a world - kept it (use --overwrite to replace it)")
            return False
        env.in_volume("mkdir -p /data/server/TheIsle && cd /data/server/TheIsle && "
                      "{ [ ! -d Saved ] || mv Saved Saved.pre-snapshot_%s; } && cp -a /in/Saved ." % ts,
                      mounts=[(src, "/in", True)])
        ok("World restored into Docker volume %s%s" % (VOLUME, " (previous world kept as Saved.pre-snapshot_%s)" % ts if has else ""))
        return True
    isle = os.path.join(env.server_dir, "TheIsle")
    saved = os.path.join(isle, "Saved")
    has = has_world(saved)
    if has and not overwrite:
        warn("this server already has a world in %s - kept it (use --overwrite to replace it)" % saved)
        return False
    os.makedirs(isle, exist_ok=True)
    if os.path.isdir(saved):
        os.rename(saved, "%s.pre-snapshot_%s" % (saved, ts))
    shutil.copytree(os.path.join(src, "Saved"), saved)
    chown_tree(saved, env.owner)
    ok("World restored into %s%s" % (saved, " (previous world kept as Saved.pre-snapshot_%s)" % ts if has else ""))
    return True


def restore_backups(env, src):
    names = [n for n in os.listdir(src) if os.path.isfile(os.path.join(src, n))]
    if env.runtime == "docker":
        subprocess.call(["docker", "volume", "create", VOLUME], stdout=subprocess.DEVNULL)
        env.in_volume("mkdir -p /data/backups && for f in /in/*; do b=$(basename \"$f\"); "
                      "[ -e /data/backups/$b ] || cp \"$f\" /data/backups/; done", mounts=[(src, "/in", True)])
    else:
        os.makedirs(env.backup_dir, exist_ok=True)
        for n in names:
            if not os.path.exists(os.path.join(env.backup_dir, n)):
                shutil.copy2(os.path.join(src, n), env.backup_dir)
        chown_tree(env.backup_dir, env.owner)
    ok("Backups restored: %d file(s)" % len(names))


def copy_with_backup(src_dir, dst_dir, owner, label):
    os.makedirs(dst_dir, exist_ok=True)
    n = 0
    for name in os.listdir(src_dir):
        s, d = os.path.join(src_dir, name), os.path.join(dst_dir, name)
        if not os.path.isfile(s):
            continue
        if name == "enabled.txt" and os.path.isfile(d):  # union of enabled plugins
            names = set(open(d).read().split()) | set(open(s).read().split())
            open(d, "w").write("".join(x + "\n" for x in sorted(names)))
        else:
            if os.path.isfile(d):
                shutil.copy2(d, d + ".bak")
            shutil.copy2(s, d)
        n += 1
    chown_tree(dst_dir, owner)
    ok("%s restored: %d file(s)" % (label, n))


def cmd_restore(env, o):
    parts = parse_parts(o.include, DEFAULT_PARTS)
    if env.running():
        if not o.stop:
            raise SnapError("the server is running - stop it first (or add --stop)")
        say("Stopping the server")
        env.launcher("stop", quiet=False)
    stage = tempfile.mkdtemp(prefix="isle-snaprestore-")
    try:
        manifest = open_snapshot(o.file, stage)
        src = manifest.get("source", {})
        say("Snapshot of '%s' from %s/%s (%s), created %s" % (manifest.get("server_name", ""), src.get("os"),
                                                              src.get("runtime"), src.get("host"), manifest.get("created")))
        done, missing = [], []
        for part in parts:
            if part not in manifest.get("parts", {}):
                missing.append(part)
                continue
            if part == "worlds":
                if restore_world(env, os.path.join(stage, "world"), o.overwrite):
                    done.append(part)
            elif part == "backups":
                restore_backups(env, os.path.join(stage, "backups")); done.append(part)
            elif part == "settings":
                merge_settings(env, os.path.join(stage, "settings", "server.conf"), o.all_settings); done.append(part)
            elif part == "overrides":
                copy_with_backup(os.path.join(stage, "overrides"), env.overrides_dir, env.owner, "Overrides"); done.append(part)
            elif part == "plugins":
                state = os.path.join(stage, "plugins", "state")
                if os.path.isdir(state):
                    copy_with_backup(state, env.plugin_state, env.owner, "Plugin settings")
                code = os.path.join(stage, "plugins", "installed")
                if os.path.isdir(code):
                    os.makedirs(env.plugin_code, exist_ok=True)
                    for name in os.listdir(code):
                        target = os.path.join(env.plugin_code, name)
                        if os.path.isdir(target):
                            shutil.rmtree(target)
                        shutil.copytree(os.path.join(code, name), target)
                    chown_tree(env.plugin_code, env.owner)
                    warn("plugin code from the snapshot was installed - plugins run with the server user's rights")
                done.append(part)
        if missing:
            say("       (not in this snapshot: %s)" % ", ".join(missing))
        ok("Restored: %s" % (", ".join(done) or "nothing"))
        if done:
            say("       Start the server to use it.")
        return 0
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def cmd_info(env, o):
    stage = tempfile.mkdtemp(prefix="isle-snapinfo-")
    try:
        with tarfile.open(o.file, "r:*") as tar:
            member = tar.extractfile("snapshot.json")
            if member is None:
                raise SnapError("%s is not a snapshot" % o.file)
            manifest = json.load(io.TextIOWrapper(member, encoding="utf-8"))
        say(json.dumps(manifest, indent=2))
        return 0
    except KeyError:
        raise SnapError("%s is not a snapshot (no snapshot.json)" % o.file)
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def cmd_list(env, o):
    if not os.path.isdir(env.snap_dir) or not os.listdir(env.snap_dir):
        say("No snapshots in %s" % env.snap_dir)
        return 0
    for n in sorted(os.listdir(env.snap_dir)):
        p = os.path.join(env.snap_dir, n)
        say("%-48s %10s" % (p, human(os.path.getsize(p))))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="isle-server snapshot", description="Portable snapshots")
    for flag in ("--conf", "--runtime", "--launcher", "--server-dir", "--backup-dir", "--overrides-dir",
                 "--plugins-dir", "--owner"):
        ap.add_argument(flag)
    sub = ap.add_subparsers(dest="action")
    p = sub.add_parser("create"); p.add_argument("--include"); p.add_argument("--output"); p.add_argument("--no-save", action="store_true")
    p = sub.add_parser("restore"); p.add_argument("file"); p.add_argument("--include"); p.add_argument("--overwrite", action="store_true")
    p.add_argument("--all-settings", action="store_true"); p.add_argument("--stop", action="store_true")
    p = sub.add_parser("info"); p.add_argument("file")
    sub.add_parser("list")
    o = ap.parse_args(argv)
    if not o.action:
        ap.print_help()
        return 0
    try:
        env = Env(o)
        return {"create": cmd_create, "restore": cmd_restore, "info": cmd_info, "list": cmd_list}[o.action](env, o)
    except SnapError as exc:
        print("[FAIL] %s" % exc, file=sys.stderr)
        return 1
    except (OSError, tarfile.TarError, ValueError) as exc:
        print("[FAIL] %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
