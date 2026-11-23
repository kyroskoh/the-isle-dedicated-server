#!/usr/bin/env python3
"""
isle_remote.py - provision and manage a The Isle server on ANOTHER machine over SSH, standard library only.

    isle_remote.py [--dir CONFIG_DIR] COMMAND ...

    hosts                                      list the remote machines you have added
    add NAME --host H [--user U] [--port 22] [--os auto|linux|windows] [--mode native|docker]
            [--key FILE | --new-key] [--install-root C:\\TheIsle] [--service-user theisle]
    show NAME | remove NAME
    keygen NAME                                create an ed25519 key pair for NAME (config/keys/NAME_ed25519)
    copy-id NAME                               install that public key on a Linux host (asks for the password once)
    test NAME [--json]                         connect, detect OS, admin/sudo, Docker, disk, an existing install
    provision NAME [--native|--docker] [--start] [--ui] [--setup] [--branch B] [--image REF]
                   [--from-snapshot FILE] [--dry-run] [--stage-only]
                                               upload these scripts and run the installer there
                                               (--stage-only: upload and unpack only; --dry-run: show what it would do)
    run NAME [--] ARGS...                      run the launcher there (status, start, backup, setup --yes, ...)
    wizard [--native|--docker] [--start] [--ui] [--setup] ...
                                               guided: add a machine, make and install a key, test, provision

How it connects: the system's OpenSSH client (ssh/scp; built into Linux, macOS and Windows 10/11), key-based
login only (passwords are never stored), and a known_hosts file of its own (config/keys/known_hosts). The first
connection to a host records its key (accept-new) and later connections refuse a changed one.

Remote requirements: Linux - x86_64, a user that can run sudo without a password (or root), tar, bash.
Windows - OpenSSH Server, an account in Administrators, tar.exe (built in since Windows 10 1803 / Server 2019).

Tests: ISLE_SSH / ISLE_SCP / ISLE_SSH_KEYGEN / ISLE_SSH_COPY_ID override the programs.
"""
import argparse
import io
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import time

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)
import isle_logs  # noqa: E402

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
HOST_RE = re.compile(r"^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"
                     r"|^\d{1,3}(?:\.\d{1,3}){3}$|^[0-9A-Fa-f:]{2,39}$")
USER_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$")
WINROOT_RE = re.compile(r"^[A-Za-z]:\\[A-Za-z0-9 _.\\-]{1,120}$")
ARG_RE = re.compile(r"^[A-Za-z0-9_.,:/@=+*# -]{0,200}$")      # launcher arguments sent to a remote shell
KEYS = ("HOST", "PORT", "USER", "OS", "MODE", "KEY", "INSTALL_ROOT", "SERVICE_USER")
STAGE = "theisle-installer"
EXCLUDE_DIRS = {".git", "node_modules", "__pycache__", "logs", ".claude"}
# never uploaded: this machine's config and secrets (the remote creates its own from server.conf.example), the
# remote-host list and keys, local state, and the documentation screenshots
EXCLUDE_CONFIG = re.compile(r"^(config/(server\.conf(\.bak.*|\.tmp)?|ui-token|hosts|keys|\.[^/]*|plugins/(installed|state)(/.*)?)"
                            r"|docs/images(/.*)?)$")


class RemoteError(Exception):
    pass


def prog(name):
    return os.environ.get("ISLE_" + name.upper().replace("-", "_"), name)


# ----------------------------------------------------------------- inventory
class Inventory(object):
    def __init__(self, config_dir):
        self.dir = os.path.abspath(config_dir)
        self.hosts = os.path.join(self.dir, "hosts")
        self.keys = os.path.join(self.dir, "keys")

    def path(self, name):
        if not NAME_RE.match(name or ""):
            raise RemoteError("Host names are lowercase letters, digits, - and _ (max 32): %r" % name)
        return os.path.join(self.hosts, name + ".conf")

    def names(self):
        if not os.path.isdir(self.hosts):
            return []
        return sorted(f[:-5] for f in os.listdir(self.hosts) if f.endswith(".conf") and NAME_RE.match(f[:-5]))

    def load(self, name):
        p = self.path(name)
        if not os.path.isfile(p):
            raise RemoteError("No remote machine called %r - add it with: remote add %s --host ..." % (name, name))
        v = isle_logs.read_conf(p)
        h = {k: v.get(k, "") for k in KEYS}
        h["NAME"] = name
        h["PORT"] = h["PORT"] or "22"
        h["OS"] = (h["OS"] or "auto").lower()
        h["MODE"] = (h["MODE"] or "native").lower()
        h["INSTALL_ROOT"] = h["INSTALL_ROOT"] or "C:\\TheIsle"
        h["SERVICE_USER"] = h["SERVICE_USER"] or "theisle"
        validate(h)
        return h

    def save(self, h):
        validate(h)
        os.makedirs(self.hosts, exist_ok=True)
        p = self.path(h["NAME"])
        tmp = p + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write("# Remote machine for isle-server remote (tools/isle_remote.py). Key-based SSH only.\n")
            for k in KEYS:
                handle.write("%s=%s\n" % (k, h.get(k, "")))
        os.replace(tmp, p)
        return p

    def key_path(self, h):
        k = h.get("KEY") or ""
        if not k:
            return None
        return k if os.path.isabs(k) else os.path.join(self.dir, k)

    def known_hosts(self):
        os.makedirs(self.keys, exist_ok=True)
        return os.path.join(self.keys, "known_hosts")


def validate(h):
    if not HOST_RE.match(h.get("HOST", "")) or h["HOST"].startswith("-"):
        raise RemoteError("HOST must be a host name or IP address: %r" % h.get("HOST"))
    if not re.match(r"^\d{1,5}$", str(h.get("PORT", "22"))) or not 1 <= int(h["PORT"]) <= 65535:
        raise RemoteError("PORT must be 1-65535")
    if not USER_RE.match(h.get("USER", "")):
        raise RemoteError("USER must be a plain account name (letters, digits, . _ -): %r" % h.get("USER"))
    if h.get("OS", "auto") not in ("auto", "linux", "windows"):
        raise RemoteError("OS must be auto, linux or windows")
    if h.get("MODE", "native") not in ("native", "docker"):
        raise RemoteError("MODE must be native or docker")
    if h.get("INSTALL_ROOT") and not WINROOT_RE.match(h["INSTALL_ROOT"]):
        raise RemoteError("INSTALL_ROOT must be a Windows path such as C:\\TheIsle")
    if h.get("SERVICE_USER") and not re.match(r"^[a-z_][a-z0-9_-]{0,31}$", h["SERVICE_USER"]):
        raise RemoteError("SERVICE_USER must be a Linux user name")
    if h.get("KEY") and (any(ord(c) < 32 for c in h["KEY"]) or h["KEY"].startswith("-")):
        raise RemoteError("KEY must be a path to a private key file")


# ----------------------------------------------------------------------- ssh
class Remote(object):
    def __init__(self, inv, h, verbose=False):
        self.inv, self.h, self.verbose = inv, h, verbose

    def _common(self):
        opts = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "StrictHostKeyChecking=accept-new",
                "-o", "UserKnownHostsFile=" + self.inv.known_hosts(), "-o", "IdentitiesOnly=yes", "-o", "LogLevel=ERROR"]
        key = self.inv.key_path(self.h)
        if key:
            opts += ["-i", key]
        return opts

    def target(self):
        host = self.h["HOST"]
        return "%s@%s" % (self.h["USER"], host)

    def ssh(self, command, tty=False, timeout=None, capture=True):
        args = [prog("ssh")] + self._common() + ["-p", str(self.h["PORT"])] + (["-t"] if tty else []) + [self.target(), command]
        if self.verbose:
            print("+ " + " ".join(shlex.quote(a) for a in args[:-1]) + " " + shlex.quote(command), file=sys.stderr)
        try:
            p = subprocess.run(args, stdout=subprocess.PIPE if capture else None, stderr=subprocess.STDOUT if capture else None,
                               timeout=timeout, universal_newlines=True)
        except subprocess.TimeoutExpired:
            return 124, "timed out"
        except OSError as exc:
            raise RemoteError("Cannot run ssh (%s) - install the OpenSSH client" % exc)
        return p.returncode, (p.stdout or "") if capture else ""

    def scp(self, local, remote_name, timeout=3600):
        host = self.h["HOST"]
        if ":" in host:          # IPv6
            host = "[%s]" % host
        args = [prog("scp")] + self._common() + ["-P", str(self.h["PORT"]), "-q", local, "%s@%s:%s" % (self.h["USER"], host, remote_name)]
        try:
            p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, universal_newlines=True)
        except OSError as exc:
            raise RemoteError("Cannot run scp (%s) - install the OpenSSH client" % exc)
        if p.returncode:
            raise RemoteError("Upload of %s failed (scp exit %d): %s" % (os.path.basename(local), p.returncode, (p.stdout or "").strip()[-400:]))

    def os(self):
        if self.h["OS"] in ("linux", "windows"):
            return self.h["OS"]
        rc, out = self.ssh("uname -s", timeout=30)
        if rc == 0 and "linux" in out.lower():
            return "linux"
        rc, out = self.ssh("ver", timeout=30)
        if rc == 0 and "windows" in out.lower():
            return "windows"
        raise RemoteError("Could not detect the remote OS (connect error? %s) - run: remote test %s" % (out.strip()[-200:], self.h["NAME"]))


def ps(command):
    """a PowerShell command line for a Windows OpenSSH session. -EncodedCommand (base64 of UTF-16LE) reaches
    PowerShell unchanged whether the session's shell is cmd.exe (the default) or PowerShell: nothing in it is
    seen by the remote shell's own quoting or variable expansion."""
    import base64
    return "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + base64.b64encode(command.encode("utf-16-le")).decode("ascii")


def check_args(args):
    bad = [a for a in args if not ARG_RE.match(a)]
    if bad:
        raise RemoteError("Arguments for the remote launcher may only use letters, digits, spaces and . , : / @ = + * # _ - (got %r)" % bad[0])
    return args


def win_quote(a):
    return "'" + a.replace("'", "''") + "'"


# -------------------------------------------------------------------- staging
def build_bundle(dest):
    """a tar.gz of these scripts (no server.conf, tokens, keys, host list, logs or git data)"""
    with tarfile.open(dest, "w:gz") as tar:
        for root, dirs, files in os.walk(REPO):
            rel_root = os.path.relpath(root, REPO).replace(os.sep, "/")
            rel_root = "" if rel_root == "." else rel_root
            dirs[:] = sorted(d for d in dirs if d not in EXCLUDE_DIRS and not EXCLUDE_CONFIG.match((rel_root + "/" + d).lstrip("/")))
            for f in sorted(files):
                rel = (rel_root + "/" + f).lstrip("/")
                if EXCLUDE_CONFIG.match(rel) or f.endswith((".pyc", ".bak")) or "/.bak" in rel:
                    continue
                full = os.path.join(root, f)
                if os.path.islink(full) or not os.path.isfile(full):
                    continue
                info = tar.gettarinfo(full, arcname="the-isle-dedicated-server/" + rel)
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                with open(full, "rb") as handle:
                    tar.addfile(info, handle)
    return dest


def install_command(osname, h, opts, snapshot_name):
    mode = opts.get("mode") or h["MODE"]
    if osname == "linux":
        args = ["--" + mode, "--yes"]
        if opts.get("start"):
            args.append("--start")
        if opts.get("ui"):
            args.append("--ui")
        if opts.get("branch") is not None:
            args += ["--branch", opts["branch"]]
        if opts.get("image"):
            args += ["--image", opts["image"]]
        if snapshot_name:
            args += ["--from-snapshot", "$HOME/%s/%s" % (STAGE, snapshot_name)]
        check_args([a for a in args if not a.startswith("$HOME/")])
        quoted = " ".join(a if a.startswith("$HOME/") else shlex.quote(a) for a in args)
        sudo = "" if h["USER"] == "root" else "sudo -n "
        unpack = "set -e; rm -rf ~/{s}; mkdir -p ~/{s}; tar -xzf ~/{s}.tgz -C ~/{s}; cd ~/{s}/the-isle-dedicated-server; chmod +x linux/*.sh".format(s=STAGE)
        if opts.get("stage_only"):
            return unpack + "; echo staged: $PWD"
        return unpack + "; {sudo}bash ./linux/install.sh {a}".format(sudo=sudo, a=quoted)
    args = ["-" + mode.capitalize(), "-Yes", "-InstallRoot", win_quote(h["INSTALL_ROOT"])]
    if opts.get("start"):
        args.append("-Start")
    if opts.get("ui"):
        args.append("-UI")
    if opts.get("branch") is not None:
        check_args([opts["branch"]])
        args += ["-Branch", win_quote(opts["branch"])]
    if opts.get("image"):
        check_args([opts["image"]])
        args += ["-Image", win_quote(opts["image"])]
    if snapshot_name:
        args += ["-FromSnapshot", "(Join-Path $HOME '%s\\%s')" % (STAGE, snapshot_name)]
    unpack = ("$ErrorActionPreference = 'Stop'; $d = Join-Path $HOME '{s}'; if (Test-Path $d) {{ Remove-Item -Recurse -Force $d }}; "
              "New-Item -ItemType Directory -Force -Path $d | Out-Null; "
              "tar.exe -xzf (Join-Path $HOME '{s}.tgz') -C $d; if ($LASTEXITCODE) {{ exit $LASTEXITCODE }}; ").format(s=STAGE)
    if opts.get("stage_only"):
        return ps(unpack + "'staged: ' + (Join-Path $d 'the-isle-dedicated-server')")
    return ps(unpack + "& (Join-Path $d 'the-isle-dedicated-server\\windows\\Install.ps1') {a}; exit $LASTEXITCODE".format(a=" ".join(args)))


def launcher_command(osname, h, args):
    check_args(args)
    if osname == "linux":
        quoted = " ".join(shlex.quote(a) for a in args)
        if h["MODE"] == "docker":
            prefix = "" if h["USER"] == "root" else "sudo -n "
        else:
            prefix = ("sudo -n -u %s " % h["SERVICE_USER"]) if h["USER"] != h["SERVICE_USER"] else ""
        return "%sisle-server %s" % (prefix, quoted)
    script = "%s\\scripts\\windows\\IsleServer.ps1" % h["INSTALL_ROOT"]
    return ps("& %s %s; exit $LASTEXITCODE" % (win_quote(script), " ".join(win_quote(a) for a in args)))


# ------------------------------------------------------------------- actions
def do_test(inv, h):
    r = Remote(inv, h)
    out = {"name": h["NAME"], "target": "%s:%s" % (r.target(), h["PORT"]), "reachable": False}
    rc, msg = r.ssh("echo isle-ok", timeout=40)
    if rc != 0 or "isle-ok" not in msg:
        out["error"] = msg.strip()[-400:] or "ssh exit %d" % rc
        if "host key" in msg.lower() or "identification has changed" in msg.lower():
            host = h["HOST"] if str(h["PORT"]) == "22" else "[%s]:%s" % (h["HOST"], h["PORT"])
            out["hint"] = ("The machine's SSH identity changed since the first connection. If you reinstalled it, forget the old "
                           "key with: ssh-keygen -R '%s' -f %s - otherwise do not connect: someone may be in between."
                           % (host, inv.known_hosts()))
        elif rc == 255:
            out["hint"] = ("Key-based login failed. Create a key with 'remote keygen %s' and install it with 'remote copy-id %s' "
                           "(Linux) or the steps it prints (Windows)." % (h["NAME"], h["NAME"]))
        else:
            out["hint"] = ""
        return out
    out["reachable"] = True
    osname = r.os()
    out["os"] = osname
    if osname == "linux":
        script = ("echo arch=$(uname -m); . /etc/os-release 2>/dev/null; echo distro=${PRETTY_NAME:-unknown}; "
                  "if [ \"$(id -u)\" = 0 ] || sudo -n true 2>/dev/null; then echo admin=yes; else echo admin=no; fi; "
                  "if command -v docker >/dev/null 2>&1; then echo docker=yes; else echo docker=no; fi; "
                  "echo disk_gb=$(df -Pk / | awk 'NR==2{printf \"%.0f\", $4/1048576}'); "
                  "if [ -f /etc/theisle-server/install.state ]; then echo installed=$(sed -n 's/^MODE=//p' /etc/theisle-server/install.state | head -n1); "
                  "else echo installed=; fi")
        rc, msg = r.ssh(script, timeout=60)
    else:
        script = ps("$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); "
                    "'arch=' + $env:PROCESSOR_ARCHITECTURE; 'distro=' + (Get-CimInstance Win32_OperatingSystem).Caption; "
                    "'admin=' + $(if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {'yes'} else {'no'}); "
                    "'docker=' + $(if (Get-Command docker -ErrorAction SilentlyContinue) {'yes'} else {'no'}); "
                    "'disk_gb=' + [math]::Round((Get-PSDrive C).Free / 1GB); "
                    "'installed=' + $(if (Test-Path '%s\\scripts\\windows\\IsleServer.ps1') {'yes'} else {''})" % h["INSTALL_ROOT"])
        rc, msg = r.ssh(script, timeout=90)
    for line in msg.splitlines():
        if "=" in line:
            k, v = line.strip().split("=", 1)
            if k in ("arch", "distro", "admin", "docker", "disk_gb", "installed"):
                out[k] = v.strip()
    out["admin"] = out.get("admin") == "yes"
    out["docker"] = out.get("docker") == "yes"
    problems = []
    arch = (out.get("arch") or "").lower()
    if arch and arch not in ("x86_64", "amd64"):
        problems.append("%s is not x86_64: the Evrima server does not run there" % out["arch"])
    if not out["admin"]:
        problems.append("the account cannot run sudo without a password" if osname == "linux" else "the account is not in Administrators")
    if (h["MODE"] == "docker") and not out["docker"]:
        problems.append("Docker is not installed (docker mode needs Docker Engine / Docker Desktop)")
    try:
        if int(out.get("disk_gb") or 0) < 25:
            problems.append("only %s GB free - the game files need about 20 GB" % out.get("disk_gb"))
    except ValueError:
        pass
    out["problems"] = problems
    out["ready"] = not problems
    return out


def do_provision(inv, h, opts, workdir):
    r = Remote(inv, h, verbose=opts.get("verbose"))
    osname = r.os()
    if opts.get("mode"):
        h["MODE"] = opts["mode"]
    bundle = build_bundle(os.path.join(workdir, STAGE + ".tgz"))
    snap = opts.get("from_snapshot")
    if snap and not os.path.isfile(snap):
        raise RemoteError("--from-snapshot: no such file %s" % snap)
    snap_name = os.path.basename(snap) if snap else None
    if snap_name and not re.match(r"^[A-Za-z0-9_.-]+$", snap_name):
        raise RemoteError("The snapshot file name may only use letters, digits, . _ - (rename it first)")
    cmd = install_command(osname, h, opts, snap_name)
    if opts.get("dry_run"):
        return {"os": osname, "bundle": bundle, "command": cmd, "snapshot": snap_name}
    print("Uploading the scripts to %s (%s) ..." % (h["NAME"], osname), flush=True)
    r.scp(bundle, STAGE + ".tgz")
    if snap:
        if osname == "linux":
            r.ssh("mkdir -p ~/%s" % STAGE, timeout=60)
        else:
            r.ssh(ps("New-Item -ItemType Directory -Force -Path (Join-Path $HOME '%s') | Out-Null" % STAGE), timeout=60)
        r.scp(snap, "%s/%s" % (STAGE, snap_name))
    if opts.get("stage_only"):
        rc, out = r.ssh(cmd, timeout=600)
        if rc:
            raise RemoteError("Unpacking on %s failed (exit %d): %s" % (h["NAME"], rc, out.strip()[-400:]))
        return {"os": osname, "mode": h["MODE"], "host": h["NAME"], "staged": out.strip().splitlines()[-1] if out.strip() else ""}
    print("Running the %s installer (%s mode) on %s - this takes a while the first time ..." % (osname, h["MODE"], h["NAME"]), flush=True)
    rc, _ = r.ssh(cmd, tty=opts.get("tty", False), capture=False)
    if rc:
        raise RemoteError("The installer on %s failed (exit %d) - see its output above" % (h["NAME"], rc))
    if not h.get("OS") or h["OS"] == "auto":
        h["OS"] = osname
    inv.save(h)
    if opts.get("setup"):
        print("Applying recommended settings for that machine (setup --yes) ...", flush=True)
        rc, _ = r.ssh(launcher_command(osname, h, ["setup", "--yes"]), capture=False)
        if rc:
            raise RemoteError("setup --yes on %s failed (exit %d)" % (h["NAME"], rc))
    return {"os": osname, "mode": h["MODE"], "host": h["NAME"]}


def keygen(inv, h):
    os.makedirs(inv.keys, exist_ok=True)
    try:
        os.chmod(inv.keys, 0o700)
    except OSError:
        pass
    key = os.path.join(inv.keys, "%s_ed25519" % h["NAME"])
    if os.path.exists(key):
        raise RemoteError("%s already exists - remove it first to make a new one" % key)
    p = subprocess.run([prog("ssh-keygen"), "-q", "-t", "ed25519", "-N", "", "-C", "the-isle-server %s" % h["NAME"], "-f", key],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    if p.returncode:
        raise RemoteError("ssh-keygen failed: %s" % p.stdout.strip())
    try:
        os.chmod(key, 0o600)
    except OSError:
        pass
    h["KEY"] = os.path.relpath(key, inv.dir)
    inv.save(h)
    with open(key + ".pub", encoding="utf-8") as handle:
        return key, handle.read().strip()


def key_instructions(h, pub):
    return "\n".join([
        "Public key:", "  " + pub, "",
        "Install it on the remote machine (once):",
        "  Linux   : isle-server remote copy-id %s        (asks for %s's password once)" % (h["NAME"], h["USER"]),
        "            or append the line above to ~%s/.ssh/authorized_keys" % h["USER"],
        "  Windows : as an administrator, append it to C:\\ProgramData\\ssh\\administrators_authorized_keys",
        "            (for admin accounts; others use %%USERPROFILE%%\\.ssh\\authorized_keys), then restart sshd:",
        "            Restart-Service sshd",
        "Then check it: isle-server remote test %s" % h["NAME"]])


# -------------------------------------------------------------------- wizard
def ask(question, default="", choices=None):
    hint = " [%s]" % default if default else ""
    while True:
        try:
            ans = input("  %s%s: " % (question, hint)).strip()
        except EOFError:
            ans = ""
        ans = ans or default
        if not choices or ans.lower() in choices:
            return ans
        print("    Please answer one of: %s" % ", ".join(choices))


def yes(question, default=True):
    ans = ask(question + (" (Y/n)" if default else " (y/N)"), "", ["", "y", "yes", "n", "no"]).lower()
    return ans in (("", "y", "yes") if default else ("y", "yes"))


def wizard(inv, preset):
    """guided: describe the machine, make and install a key, test, provision"""
    print("\nInstall The Isle server on another machine over SSH (key-based login; no password is stored).\n")
    names = inv.names()
    if names:
        print("  Machines you added before: %s" % ", ".join(names))
    while True:
        name = ask("A short name for that machine (letters, digits, - _)", names[0] if names else "server1").lower()
        if NAME_RE.match(name):
            break
        print("    Use lowercase letters, digits, - and _ (max 32).")
    if name in names:
        h = inv.load(name)
        print("  Using %s: %s@%s:%s" % (name, h["USER"], h["HOST"], h["PORT"]))
    else:
        while True:
            h = {"NAME": name, "HOST": ask("Host name or IP address"),
                 "USER": ask("SSH user (Linux: root or a sudo user; Windows: an administrator)"),
                 "PORT": ask("SSH port", "22"),
                 "OS": ask("Operating system (auto, linux, windows)", "auto", ["auto", "linux", "windows"]).lower(),
                 "MODE": preset.get("mode") or ask("Run the server natively or in Docker (native, docker)", "native", ["native", "docker"]).lower(),
                 "KEY": "", "INSTALL_ROOT": "C:\\TheIsle", "SERVICE_USER": "theisle"}
            try:
                validate(h)
                break
            except RemoteError as exc:
                print("    %s - let's try again." % exc)
        existing = ask("Path to an existing private key (empty = create a new one for this machine)", "")
        if existing:
            h["KEY"] = os.path.abspath(os.path.expanduser(existing))
            if not os.path.isfile(h["KEY"]):
                raise RemoteError("No such key file: %s" % h["KEY"])
        inv.save(h)
        if not existing:
            key, pub = keygen(inv, h)
            print("\n  Created %s" % key)
            if (h["OS"] != "windows" and shutil.which(prog("ssh-copy-id"))
                    and yes("Install the public key on %s now (asks for %s's password once)?" % (h["HOST"], h["USER"]))):
                subprocess.call([prog("ssh-copy-id"), "-i", key + ".pub", "-p", str(h["PORT"]), "-o", "UserKnownHostsFile=" + inv.known_hosts(),
                                 "-o", "StrictHostKeyChecking=accept-new", "%s@%s" % (h["USER"], h["HOST"])])
            else:
                print("\n" + key_instructions(h, pub))
                ask("Press Enter once the key is installed", "")
    if preset.get("mode"):
        h["MODE"] = preset["mode"]
    while True:
        print("\n  Checking %s ..." % name)
        t = do_test(inv, h)
        if t["reachable"]:
            print("  %s, %s (%s) - admin: %s, Docker: %s, free disk: %s GB" % (
                t.get("os"), t.get("distro", "?"), t.get("arch", "?"), "yes" if t["admin"] else "no",
                "yes" if t["docker"] else "no", t.get("disk_gb", "?")))
        else:
            print("  Cannot log in: %s" % t.get("error", ""))
        for prob in t.get("problems", []):
            print("  Problem: " + prob)
        if t.get("ready"):
            break
        if not yes("Fix that on %s, then try again?" % name):
            raise RemoteError("Stopped before provisioning %s (run 'remote test %s' when it is ready)" % (name, name))
    opts = dict(preset)
    opts["mode"] = h["MODE"]
    if "start" not in preset:
        opts["start"] = yes("Start the server when the install finishes?")
    if "setup" not in preset:
        opts["setup"] = yes("Apply settings recommended for that machine's CPU, memory and disk?")
    if "ui" not in preset:
        opts["ui"] = yes("Also run the web UI there (localhost only; reach it through an SSH tunnel)?", False)
    import tempfile
    work = tempfile.mkdtemp(prefix="isle-remote-")
    try:
        res = do_provision(inv, h, opts, work)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("\nDone: The Isle server is installed on %s (%s, %s mode)." % (name, res["os"], res["mode"]))
    print("Manage it from here:  isle-server remote run %s -- status | start | logs | backup" % name)
    if opts.get("ui"):
        print("Web UI: ssh -L 8090:127.0.0.1:8090 -p %s %s@%s  then open http://127.0.0.1:8090/" % (h["PORT"], h["USER"], h["HOST"]))
    return 0


# ----------------------------------------------------------------------- cli
def main(argv=None):
    ap = argparse.ArgumentParser(description="Provision and manage a The Isle server on another machine over SSH")
    ap.add_argument("--dir", default=os.path.join(REPO, "config"), help="config folder holding hosts/ and keys/")
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("hosts")
    a = sub.add_parser("add")
    a.add_argument("name"); a.add_argument("--host", required=True); a.add_argument("--user", required=True)
    a.add_argument("--port", default="22"); a.add_argument("--os", default="auto", choices=["auto", "linux", "windows"])
    a.add_argument("--mode", default="native", choices=["native", "docker"]); a.add_argument("--key", default="")
    a.add_argument("--new-key", action="store_true"); a.add_argument("--install-root", default="C:\\TheIsle")
    a.add_argument("--service-user", default="theisle")
    for n in ("show", "remove", "keygen", "copy-id"):
        sub.add_parser(n).add_argument("name")
    t = sub.add_parser("test"); t.add_argument("name"); t.add_argument("--json", action="store_true")
    p = sub.add_parser("provision"); p.add_argument("name")
    g = p.add_mutually_exclusive_group(); g.add_argument("--native", dest="mode", action="store_const", const="native")
    g.add_argument("--docker", dest="mode", action="store_const", const="docker")
    for f in ("start", "ui", "setup", "dry-run", "stage-only", "tty", "verbose"):
        p.add_argument("--" + f, action="store_true")
    p.add_argument("--branch"); p.add_argument("--image"); p.add_argument("--from-snapshot")
    r = sub.add_parser("run"); r.add_argument("name"); r.add_argument("args", nargs=argparse.REMAINDER)
    w = sub.add_parser("wizard")
    gw = w.add_mutually_exclusive_group(); gw.add_argument("--native", dest="mode", action="store_const", const="native")
    gw.add_argument("--docker", dest="mode", action="store_const", const="docker")
    for f in ("start", "ui", "setup"):
        w.add_argument("--" + f, action="store_true", default=None)
    w.add_argument("--branch"); w.add_argument("--image"); w.add_argument("--from-snapshot")
    args = ap.parse_args(argv)
    inv = Inventory(args.dir)
    try:
        if args.cmd == "wizard":
            preset = {k: v for k, v in (("mode", args.mode), ("start", args.start), ("ui", args.ui), ("setup", args.setup),
                                        ("branch", args.branch), ("image", args.image), ("from_snapshot", args.from_snapshot)) if v is not None}
            return wizard(inv, preset)
        if args.cmd == "hosts":
            names = inv.names()
            if not names:
                print("No remote machines yet. Add one: isle-server remote add NAME --host HOST --user USER [--new-key]")
            for n in names:
                h = inv.load(n)
                print("%-16s %s@%s:%s  os=%s mode=%s key=%s" % (n, h["USER"], h["HOST"], h["PORT"], h["OS"], h["MODE"], h["KEY"] or "(ssh default)"))
            return 0
        if args.cmd == "add":
            h = {"NAME": args.name, "HOST": args.host, "PORT": args.port, "USER": args.user, "OS": args.os, "MODE": args.mode,
                 "KEY": args.key, "INSTALL_ROOT": args.install_root, "SERVICE_USER": args.service_user}
            inv.path(args.name)
            if os.path.exists(inv.path(args.name)):
                raise RemoteError("%s already exists - remove it first, or edit %s" % (args.name, inv.path(args.name)))
            if args.key and not os.path.isfile(inv.key_path(h)):
                raise RemoteError("--key: no such file %s" % args.key)
            print("Saved %s" % inv.save(h))
            if args.new_key:
                key, pub = keygen(inv, h)
                print("Created %s\n" % key)
                print(key_instructions(h, pub))
            else:
                print("Next: isle-server remote test %s   (or create a key first: remote keygen %s)" % (args.name, args.name))
            return 0
        h = inv.load(args.name)
        if args.cmd == "show":
            for k in KEYS:
                print("%-13s: %s" % (k, h[k]))
            return 0
        if args.cmd == "remove":
            os.remove(inv.path(args.name))
            print("Removed %s (its key, if any, stays in %s)" % (args.name, inv.keys))
            return 0
        if args.cmd == "keygen":
            key, pub = keygen(inv, h)
            print("Created %s\n" % key)
            print(key_instructions(h, pub))
            return 0
        if args.cmd == "copy-id":
            key = inv.key_path(h)
            if not key or not os.path.isfile(key + ".pub"):
                raise RemoteError("No key for %s yet - run: remote keygen %s" % (args.name, args.name))
            return subprocess.call([prog("ssh-copy-id"), "-i", key + ".pub", "-p", str(h["PORT"]),
                                    "-o", "UserKnownHostsFile=" + inv.known_hosts(), "-o", "StrictHostKeyChecking=accept-new",
                                    "%s@%s" % (h["USER"], h["HOST"])])
        if args.cmd == "test":
            out = do_test(inv, h)
            if args.json:
                print(json.dumps(out))
            else:
                print("Connection : %s - %s" % (out["target"], "OK" if out["reachable"] else "FAILED: " + out.get("error", "")))
                if out.get("hint"):
                    print("Hint       : " + out["hint"])
                if out["reachable"]:
                    print("System     : %s, %s (%s)" % (out.get("os"), out.get("distro", "?"), out.get("arch", "?")))
                    print("Admin      : %s   Docker: %s   Free disk: %s GB   Installed: %s" % (
                        "yes" if out["admin"] else "no", "yes" if out["docker"] else "no", out.get("disk_gb", "?"), out.get("installed") or "no"))
                    for prob in out["problems"]:
                        print("Problem    : " + prob)
                    print("Ready to provision" if out["ready"] else "Fix the problems above before provisioning")
            return 0 if out.get("ready") else 1
        if args.cmd == "provision":
            import tempfile
            work = tempfile.mkdtemp(prefix="isle-remote-")
            try:
                res = do_provision(inv, h, {"mode": args.mode, "start": args.start, "ui": args.ui, "setup": args.setup,
                                            "branch": args.branch, "image": args.image, "from_snapshot": args.from_snapshot,
                                            "dry_run": args.dry_run, "stage_only": args.stage_only, "tty": args.tty,
                                            "verbose": args.verbose}, work)
            finally:
                if not args.dry_run:
                    shutil.rmtree(work, ignore_errors=True)
            if args.dry_run:
                print(json.dumps(res, indent=2))
            elif args.stage_only:
                print("Staged the scripts on %s (not installed). Install later: remote provision %s" % (args.name, args.name))
            else:
                print("\nDone: %s is installed on %s (%s, %s mode)." % ("The Isle server", args.name, res["os"], res["mode"]))
                print("Manage it from here:  isle-server remote run %s -- status | start | logs | backup | setup --yes" % args.name)
            return 0
        if args.cmd == "run":
            rest = args.args[1:] if args.args[:1] == ["--"] else args.args
            if not rest:
                raise RemoteError("Usage: remote run NAME -- <launcher command> [args]   e.g. remote run %s -- status" % args.name)
            r = Remote(inv, h)
            osname = r.os()
            rc, _ = r.ssh(launcher_command(osname, h, rest), capture=False)
            return rc
        ap.print_help()
        return 2
    except RemoteError as exc:
        print("[FAIL] %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
