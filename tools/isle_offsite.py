#!/usr/bin/env python3
"""
isle_offsite.py - the "1 off-site" and "2 media" parts of a 3-2-1 backup strategy, standard library only.

    isle_offsite.py parse  "<target>" [--json]          check a target (exit 2 if invalid)
    isle_offsite.py send   --conf FILE ARCHIVE           copy one finished backup to BACKUP_OFFSITE_TARGET,
                                                         then prune it there to BACKUP_OFFSITE_RETENTION
    isle_offsite.py test   --conf FILE [--json]          check BACKUP_COPY_DIR and BACKUP_OFFSITE_TARGET without
                                                         sending a backup (writes and removes a small probe)
    isle_offsite.py strategy --conf FILE [--json]        the configured strategy and which tools are installed

BACKUP_OFFSITE_TARGET takes one of:
    dir:<absolute path>           another disk, a mounted network share (NFS/SMB) or a synced folder
                                  e.g. dir:/mnt/nas/theisle   dir:D:\\IsleBackups   dir:\\\\nas\\share\\theisle
    rclone:<remote>:<path>        any rclone remote (S3, B2, Google Drive, OneDrive, SFTP, ...) set up with
                                  "rclone config" for the user the server runs as, e.g. rclone:b2:my-bucket/theisle
    ssh://[user@]host[:port]/path another machine over SSH (scp, key-based login), e.g. ssh://backup@nas.lan/srv/isle

Nothing is run through a shell: each kind calls its tool with an argument list, and targets are validated
strictly (no option-like or shell-special characters), because the web UI can set them. BACKUP_OFFSITE_COMMAND
(free-form, server.conf only) still works for anything else.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
import isle_logs  # noqa: E402

ARCHIVE_RE = re.compile(r"^theisle-[A-Za-z0-9._-]+\.(?:tar\.gz|zip)$")
STAMP_RE = re.compile(r"(\d{8}_\d{6})")
RCLONE_RE = re.compile(r"^rclone:(?P<remote>[A-Za-z0-9_][A-Za-z0-9_. -]{0,63}):(?P<path>[A-Za-z0-9_./ ~+@=,-]{0,400})$")
SSH_RE = re.compile(r"^ssh://(?:(?P<user>[A-Za-z0-9._-]{1,32})@)?(?P<host>[A-Za-z0-9.-]{1,253}|\[[0-9A-Fa-f:.]{2,45}\])"
                    r"(?::(?P<port>\d{1,5}))?(?P<path>/[A-Za-z0-9_./~+-]{0,400})$")
TIMEOUT_SEND = 3600
TIMEOUT_TEST = 45
SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "StrictHostKeyChecking=accept-new"]


class TargetError(ValueError):
    pass


def is_abs_path(path):
    return bool(path) and (path.startswith("/") or re.match(r"^[A-Za-z]:[\\/]", path) is not None or path.startswith("\\\\"))


def check_dir(path, label):
    if not path:
        raise TargetError("%s is empty" % label)
    if any(ord(c) < 32 for c in path) or len(path) > 400:
        raise TargetError("%s has control characters or is too long" % label)
    if not is_abs_path(path):
        raise TargetError("%s must be an absolute path (e.g. /mnt/backup or D:\\Backups), not %r" % (label, path))
    if ".." in re.split(r"[\\/]", path):
        raise TargetError("%s must not contain '..'" % label)
    return path


def parse(target):
    """'dir:..', 'rclone:..', 'ssh://..' -> dict(kind, ...); raises TargetError"""
    t = (target or "").strip()
    if not t:
        raise TargetError("no off-site target")
    if t.startswith("dir:"):
        return {"kind": "dir", "path": check_dir(t[4:], "the off-site folder"), "label": t[4:]}
    if t.startswith("rclone:"):
        m = RCLONE_RE.match(t)
        if not m or m.group("path").startswith("-") or ".." in m.group("path").split("/"):
            raise TargetError("rclone target: rclone:<remote>:<path>, e.g. rclone:b2:my-bucket/theisle (letters, digits and ._-/ only)")
        return {"kind": "rclone", "remote": m.group("remote"), "path": m.group("path").strip("/"),
                "dest": "%s:%s" % (m.group("remote"), m.group("path").strip("/")), "label": "rclone %s:%s" % (m.group("remote"), m.group("path"))}
    if t.startswith("ssh://"):
        m = SSH_RE.match(t)
        if not m or ".." in m.group("path").split("/"):
            raise TargetError("SSH target: ssh://[user@]host[:port]/absolute/path, e.g. ssh://backup@nas.lan/srv/theisle")
        port = int(m.group("port") or 22)
        if not 1 <= port <= 65535:
            raise TargetError("SSH port must be 1-65535")
        host = m.group("host")
        login = "%s@%s" % (m.group("user"), host) if m.group("user") else host
        if login.startswith("-"):
            raise TargetError("SSH host must not start with '-'")
        return {"kind": "ssh", "login": login, "port": port, "path": m.group("path").rstrip("/") or "/", "label": t}
    raise TargetError("unknown target %r - use dir:/path, rclone:remote:path or ssh://user@host/path" % t)


def tool_for(kind):
    return {"dir": None, "rclone": "rclone", "ssh": "scp"}[kind]


def which(name):
    return shutil.which(name) or (shutil.which(name + ".exe") if os.name == "nt" else None)


def run(args, timeout):
    """(rc, combined output) without a shell"""
    try:
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, universal_newlines=True)
        return p.returncode, (p.stdout or "").strip()
    except subprocess.TimeoutExpired:
        return 124, "timed out after %d s" % timeout
    except OSError as exc:
        return 127, str(exc)


def stamp_key(name):
    m = STAMP_RE.search(name)
    return (m.group(1) if m else "", name)


def keep_count(values, key):
    raw = (values.get(key) or "").strip() or (values.get("BACKUP_RETENTION") or "10").strip()
    try:
        return max(0, int(raw))
    except ValueError:
        return 10


# ------------------------------------------------------------------- per kind
def send_dir(t, archive, keep):
    os.makedirs(t["path"], exist_ok=True)
    shutil.copy2(archive, os.path.join(t["path"], os.path.basename(archive)))
    pruned = 0
    if keep > 0:
        names = sorted((n for n in os.listdir(t["path"]) if ARCHIVE_RE.match(n)), key=stamp_key, reverse=True)
        for old in names[keep:]:
            os.remove(os.path.join(t["path"], old))
            pruned += 1
    return pruned


def send_rclone(t, archive, keep):
    exe = which("rclone")
    if not exe:
        raise RuntimeError("rclone is not installed (https://rclone.org/install/)")
    rc, out = run([exe, "copyto", archive, "%s/%s" % (t["dest"], os.path.basename(archive))], TIMEOUT_SEND)
    if rc:
        raise RuntimeError("rclone failed (exit %d): %s" % (rc, out[-500:]))
    pruned = 0
    if keep > 0:
        rc, out = run([exe, "lsf", "--files-only", t["dest"]], 300)
        if rc == 0:
            names = sorted((n for n in out.splitlines() if ARCHIVE_RE.match(n)), key=stamp_key, reverse=True)
            for old in names[keep:]:
                if run([exe, "deletefile", "%s/%s" % (t["dest"], old)], 300)[0] == 0:
                    pruned += 1
    return pruned


def send_ssh(t, archive, keep):
    scp, ssh = which("scp"), which("ssh")
    if not scp or not ssh:
        raise RuntimeError("scp/ssh are not installed (OpenSSH client)")
    base = os.path.basename(archive)
    if not ARCHIVE_RE.match(base):
        raise RuntimeError("unexpected archive name %r" % base)
    rc, out = run([scp, "-B", "-q", "-P", str(t["port"])] + SSH_OPTS + [archive, "%s:%s/%s" % (t["login"], t["path"], base)], TIMEOUT_SEND)
    if rc:
        raise RuntimeError("scp failed (exit %d): %s" % (rc, out[-500:]))
    pruned = 0
    if keep > 0:
        # the remote command line is interpreted by the remote shell: path and names are validated to safe characters
        rc, out = run([ssh, "-p", str(t["port"])] + SSH_OPTS + [t["login"], "ls -1 -- %s" % t["path"]], 120)
        if rc == 0:
            names = sorted((n for n in out.splitlines() if ARCHIVE_RE.match(n)), key=stamp_key, reverse=True)
            old = names[keep:]
            if old:
                if run([ssh, "-p", str(t["port"])] + SSH_OPTS + [t["login"], "rm -f -- " + " ".join("%s/%s" % (t["path"], n) for n in old)], 120)[0] == 0:
                    pruned = len(old)
    return pruned


def send(conf, archive):
    values = isle_logs.read_conf(conf)
    t = parse(values.get("BACKUP_OFFSITE_TARGET"))
    keep = keep_count(values, "BACKUP_OFFSITE_RETENTION")
    pruned = {"dir": send_dir, "rclone": send_rclone, "ssh": send_ssh}[t["kind"]](t, archive, keep)
    return t, pruned


# ----------------------------------------------------------------------- test
def probe_dir(path):
    os.makedirs(path, exist_ok=True)
    fd, probe = tempfile.mkstemp(prefix=".isle-probe-", dir=path)
    os.close(fd)
    os.remove(probe)


def same_device(a, b):
    try:
        return os.stat(a).st_dev == os.stat(b).st_dev
    except OSError:
        return None


def test(conf):
    values = isle_logs.read_conf(conf)
    out = {"copy": None, "offsite": None, "command": bool((values.get("BACKUP_OFFSITE_COMMAND") or "").strip())}
    backup_dir = os.path.expanduser(values.get("BACKUP_DIR") or "")
    copy = (values.get("BACKUP_COPY_DIR") or "").strip()
    if copy:
        r = {"target": copy, "ok": False, "detail": ""}
        try:
            check_dir(copy, "BACKUP_COPY_DIR")
            probe_dir(copy)
            same = same_device(copy, backup_dir) if backup_dir and os.path.isdir(backup_dir) else None
            r.update(ok=True, other_disk=(same is False),
                     detail="writable" + (" - but on the same disk as BACKUP_DIR (not a second medium)" if same else ""))
        except (TargetError, OSError) as exc:
            r["detail"] = str(exc)
        out["copy"] = r
    target = (values.get("BACKUP_OFFSITE_TARGET") or "").strip()
    if target:
        r = {"target": target, "ok": False, "detail": ""}
        try:
            t = parse(target)
            r["kind"] = t["kind"]
            if t["kind"] == "dir":
                probe_dir(t["path"])
                same = same_device(t["path"], backup_dir) if backup_dir and os.path.isdir(backup_dir) else None
                r.update(ok=True, detail="writable" + (" - but it is on this machine's backup disk, so it is not off-site" if same else ""))
            elif t["kind"] == "rclone":
                exe = which("rclone")
                if not exe:
                    raise RuntimeError("rclone is not installed (https://rclone.org/install/)")
                rc, msg = run([exe, "mkdir", t["dest"]], TIMEOUT_TEST)
                if rc == 0:
                    rc, msg = run([exe, "lsf", "--max-depth", "1", t["dest"]], TIMEOUT_TEST)
                r.update(ok=(rc == 0), detail="reachable" if rc == 0 else "rclone exit %d: %s" % (rc, msg[-300:]))
            else:
                ssh = which("ssh")
                if not ssh or not which("scp"):
                    raise RuntimeError("scp/ssh are not installed (OpenSSH client)")
                rc, msg = run([ssh, "-p", str(t["port"])] + SSH_OPTS + [t["login"], "mkdir -p -- %s && test -w %s" % (t["path"], t["path"])], TIMEOUT_TEST)
                r.update(ok=(rc == 0), detail="reachable and writable" if rc == 0 else
                         "ssh exit %d: %s (key-based login for the server's user is needed)" % (rc, msg[-300:]))
        except (TargetError, RuntimeError, OSError) as exc:
            r["detail"] = str(exc)
        out["offsite"] = r
    out["ok"] = all(x["ok"] for x in (out["copy"], out["offsite"]) if x)
    return out


def strategy(conf):
    v = isle_logs.read_conf(conf)
    target = (v.get("BACKUP_OFFSITE_TARGET") or "").strip()
    kind, err = None, None
    if target:
        try:
            kind = parse(target)["kind"]
        except TargetError as exc:
            err = str(exc)
    return {"copy_dir": (v.get("BACKUP_COPY_DIR") or "").strip(), "copy_retention": (v.get("BACKUP_COPY_RETENTION") or "").strip(),
            "offsite_target": target, "offsite_kind": kind, "offsite_error": err,
            "offsite_retention": (v.get("BACKUP_OFFSITE_RETENTION") or "").strip(), "retention": (v.get("BACKUP_RETENTION") or "10").strip(),
            "offsite_command": bool((v.get("BACKUP_OFFSITE_COMMAND") or "").strip()),
            "tools": {"rclone": bool(which("rclone")), "scp": bool(which("scp") and which("ssh"))}}


def state_path(conf):
    return os.path.join(os.path.dirname(os.path.abspath(conf)), ".backup-offsite")


def main(argv=None):
    ap = argparse.ArgumentParser(description="Off-site backup targets (3-2-1)")
    ap.add_argument("--conf", default=os.environ.get("ISLE_CONF"))
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("parse"); p.add_argument("target"); p.add_argument("--json", action="store_true")
    s = sub.add_parser("send"); s.add_argument("archive")
    t = sub.add_parser("test"); t.add_argument("--json", action="store_true")
    g = sub.add_parser("strategy"); g.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    if args.cmd == "parse":
        try:
            r = parse(args.target)
        except TargetError as exc:
            print(str(exc), file=sys.stderr)
            return 2
        print(json.dumps(r) if args.json else "%s: %s" % (r["kind"], r["label"]))
        return 0
    if not args.conf:
        ap.error("--conf is required")
    if args.cmd == "send":
        try:
            t, pruned = send(args.conf, args.archive)
            rc, msg = 0, "Off-site copy done (%s)%s" % (t["label"], ", %d old one(s) removed there" % pruned if pruned else "")
        except (TargetError, RuntimeError, OSError) as exc:
            rc, msg = 1, "Off-site copy failed: %s" % exc
        vals = isle_logs.read_conf(args.conf)
        try:
            with open(state_path(args.conf), "w") as handle:
                handle.write("%s %s %d %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S", isle_logs.now(vals)), isle_logs.zone_label(vals), rc,
                                                os.path.basename(args.archive)))
        except OSError:
            pass
        print(msg)
        return rc
    if args.cmd == "test":
        r = test(args.conf)
        if args.json:
            print(json.dumps(r))
        else:
            if not r["copy"] and not r["offsite"]:
                print("Nothing to test: set BACKUP_COPY_DIR and/or BACKUP_OFFSITE_TARGET (isle-server backup strategy ...)")
            for name, x in (("Second copy", r["copy"]), ("Off-site", r["offsite"])):
                if x:
                    print("%-12s: %s %s - %s" % (name, "OK  " if x["ok"] else "FAIL", x["target"], x["detail"]))
        return 0 if r["ok"] else 1
    if args.cmd == "strategy":
        r = strategy(args.conf)
        print(json.dumps(r) if args.json else json.dumps(r, indent=2))
        return 0
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
