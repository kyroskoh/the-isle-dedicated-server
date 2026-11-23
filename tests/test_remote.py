#!/usr/bin/env python3
"""
tests/test_remote.py - provisioning another machine over SSH (tools/isle_remote.py, PRD REM-01..06).
Offline: fake ssh / scp / ssh-keygen programs record their arguments and answer like a Linux or Windows host.
(tests/test_remote_ssh.sh does the same against a real local sshd.)
    python3 -m unittest -v tests/test_remote.py
"""
import base64
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(REPO, "tools", "isle_remote.py")
sys.path.insert(0, os.path.join(REPO, "tools"))
import isle_remote  # noqa: E402

FAKE = r'''#!PYTHON
import json, os, sys
name = os.path.basename(sys.argv[0]); args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps([name] + args) + "\n")
osname = os.environ.get("FAKE_OS", "linux")
if name == "ssh-keygen":
    key = args[args.index("-f") + 1]
    open(key, "w").write("PRIVATE"); open(key + ".pub", "w").write("ssh-ed25519 AAAAFAKE " + args[args.index("-C") + 1])
    sys.exit(0)
if name == "scp":
    sys.exit(int(os.environ.get("FAKE_SCP_RC", "0")))
cmd = args[-1]
if os.environ.get("FAKE_SSH_DOWN"):
    print("Permission denied (publickey)."); sys.exit(255)
if cmd == "echo isle-ok":
    print("isle-ok"); sys.exit(0)
if cmd == "uname -s":
    if osname == "linux": print("Linux"); sys.exit(0)
    print("'uname' is not recognized"); sys.exit(1)
if cmd == "ver":
    if osname == "windows": print("Microsoft Windows [Version 10.0.20348]"); sys.exit(0)
    sys.exit(127)
if "echo arch=" in cmd or "-EncodedCommand" in cmd and os.environ.get("FAKE_PROBE"):
    print(os.environ.get("FAKE_PROBE", "arch=x86_64\ndistro=Ubuntu 24.04\nadmin=yes\ndocker=yes\ndisk_gb=120\ninstalled="))
    sys.exit(0)
print("ran: " + cmd[:60]); sys.exit(int(os.environ.get("FAKE_CMD_RC", "0")))
'''


class RemoteTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="isle-remote-")
        self.cfg = os.path.join(self.dir, "config")
        os.makedirs(self.cfg)
        self.bin = os.path.join(self.dir, "bin")
        os.makedirs(self.bin)
        self.log = os.path.join(self.dir, "calls.log")
        self.saved = dict(os.environ)
        for n in ("ssh", "scp", "ssh-keygen", "ssh-copy-id"):
            p = os.path.join(self.bin, n)
            with open(p, "w") as handle:
                handle.write(FAKE.replace("#!PYTHON", "#!" + sys.executable))
            os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)
            os.environ["ISLE_" + n.upper().replace("-", "_")] = p
        os.environ["FAKE_LOG"] = self.log
        for k in ("FAKE_OS", "FAKE_PROBE", "FAKE_SSH_DOWN", "FAKE_SCP_RC", "FAKE_CMD_RC"):
            os.environ.pop(k, None)
        self.inv = isle_remote.Inventory(self.cfg)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved)
        shutil.rmtree(self.dir, ignore_errors=True)

    def cli(self, *args, inp=None):
        p = subprocess.run([sys.executable, TOOL, "--dir", self.cfg] + list(args), input=inp, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, universal_newlines=True, env=os.environ)
        return p.returncode, p.stdout

    def calls(self, name=None):
        if not os.path.isfile(self.log):
            return []
        with open(self.log) as handle:
            out = [json.loads(l) for l in handle]
        return [c for c in out if name is None or c[0] == name]

    def add(self, name="box", **kw):
        args = ["add", name, "--host", kw.get("host", "game.example.org"), "--user", kw.get("user", "admin")]
        for k in ("os", "mode", "port"):
            if k in kw:
                args += ["--" + k, kw[k]]
        if kw.get("new_key", True):
            args.append("--new-key")
        rc, out = self.cli(*args)
        self.assertEqual(rc, 0, out)
        return out

    # ------------------------------------------------------------- inventory
    def test_add_keygen_and_files(self):
        out = self.add()
        self.assertIn("Public key:", out)
        self.assertIn("administrators_authorized_keys", out, "Windows instructions are shown too")
        kg = self.calls("ssh-keygen")[0]
        self.assertEqual(kg[1:5], ["-q", "-t", "ed25519", "-N"])
        h = self.inv.load("box")
        self.assertEqual(h["KEY"], os.path.join("keys", "box_ed25519"))
        if os.name == "posix":
            self.assertEqual(os.stat(os.path.join(self.cfg, "keys", "box_ed25519")).st_mode & 0o077, 0, "private key is 600")
        rc, out = self.cli("hosts")
        self.assertIn("admin@game.example.org:22", out)
        self.assertNotEqual(self.cli("add", "box", "--host", "x", "--user", "y")[0], 0, "no silent overwrite")

    def test_validation(self):
        for bad in (["--host", "-oProxyCommand=evil", "--user", "a"], ["--host", "a b", "--user", "a"],
                    ["--host", "h", "--user", "a;b"], ["--host", "h", "--user", "a", "--port", "70000"],
                    ["--host", "h", "--user", "a", "--os", "mac"]):
            rc, out = self.cli("add", "x1", *bad)
            self.assertNotEqual(rc, 0, bad)
        self.assertNotEqual(self.cli("add", "Bad Name", "--host", "h", "--user", "u")[0], 0)
        self.assertNotEqual(self.cli("add", "../etc", "--host", "h", "--user", "u")[0], 0)
        with self.assertRaises(isle_remote.RemoteError):
            isle_remote.check_args(["status", "x;rm -rf /"])
        with self.assertRaises(isle_remote.RemoteError):
            isle_remote.check_args(["$(id)"])
        with self.assertRaises(isle_remote.RemoteError):
            isle_remote.check_args(["%PATH%"])

    def test_ssh_options_pin_host_keys(self):
        self.add()
        self.cli("test", "box")
        ssh = self.calls("ssh")[0]
        joined = " ".join(ssh)
        for opt in ("BatchMode=yes", "StrictHostKeyChecking=accept-new", "IdentitiesOnly=yes",
                    "UserKnownHostsFile=" + os.path.join(self.cfg, "keys", "known_hosts")):
            self.assertIn(opt, joined)
        self.assertIn(os.path.join(self.cfg, "keys", "box_ed25519"), ssh)
        self.assertEqual(ssh[ssh.index("-p") + 1], "22")
        self.assertEqual(ssh[-2], "admin@game.example.org")

    # ------------------------------------------------------------------ test
    def test_test_linux_ready_and_problems(self):
        self.add()
        rc, out = self.cli("test", "box", "--json")
        r = json.loads(out)
        self.assertEqual(rc, 0, out)
        self.assertTrue(r["ready"] and r["admin"] and r["docker"])
        self.assertEqual(r["os"], "linux")
        os.environ["FAKE_PROBE"] = "arch=aarch64\ndistro=Debian\nadmin=no\ndocker=no\ndisk_gb=8\ninstalled=native"
        self.cli("add", "dock", "--host", "h2", "--user", "u", "--mode", "docker")
        rc, out = self.cli("test", "dock", "--json")
        r = json.loads(out)
        self.assertEqual(rc, 1)
        text = " ".join(r["problems"])
        for want in ("aarch64", "sudo", "Docker is not installed", "8 GB"):
            self.assertIn(want, text)

    def test_test_unreachable_has_hint(self):
        self.add()
        os.environ["FAKE_SSH_DOWN"] = "1"
        rc, out = self.cli("test", "box")
        self.assertEqual(rc, 1)
        self.assertIn("Permission denied", out)
        self.assertIn("remote copy-id box", out)

    def test_windows_detection(self):
        self.add("win", os="auto")
        os.environ["FAKE_OS"] = "windows"
        os.environ["FAKE_PROBE"] = "arch=AMD64\ndistro=Windows Server 2022\nadmin=yes\ndocker=no\ndisk_gb=200\ninstalled="
        rc, out = self.cli("test", "win", "--json")
        r = json.loads(out)
        self.assertEqual((rc, r["os"], r["ready"]), (0, "windows", True), out)
        probe = [c for c in self.calls("ssh") if "-EncodedCommand" in c[-1]][0][-1]
        script = base64.b64decode(probe.split()[-1]).decode("utf-16-le")
        self.assertIn("IsInRole", script)

    # ------------------------------------------------------------- provision
    def test_bundle_never_ships_secrets(self):
        planted = [os.path.join(REPO, "config", n) for n in ("server.conf", "server.conf.bak_x", "ui-token", ".steam-names.json")]
        made = []
        for p in planted:
            if not os.path.exists(p):
                with open(p, "w") as handle:
                    handle.write("SECRET\n")
                made.append(p)
        try:
            dest = isle_remote.build_bundle(os.path.join(self.dir, "b.tgz"))
        finally:
            for p in made:
                os.remove(p)
        with tarfile.open(dest) as tar:
            names = tar.getnames()
        prefix = "the-isle-dedicated-server/"
        for must in ("linux/install.sh", "windows/Install.ps1", "config/server.conf.example", "tools/isle_remote.py", "VERSION"):
            self.assertIn(prefix + must, names)
        for never in ("config/server.conf", "config/server.conf.bak_x", "config/ui-token", "config/.steam-names.json"):
            self.assertNotIn(prefix + never, names)
        self.assertFalse([n for n in names if "/.git/" in n or "/config/keys" in n or "/config/hosts" in n or "/docs/images/" in n])

    def test_provision_linux_command(self):
        self.add()
        rc, out = self.cli("provision", "box", "--docker", "--start", "--ui", "--branch", "evrima", "--dry-run")
        self.assertEqual(rc, 0, out)
        cmd = json.loads(out)["command"]
        self.assertIn("tar -xzf ~/theisle-installer.tgz", cmd)
        self.assertTrue(cmd.endswith("sudo -n bash ./linux/install.sh --docker --yes --start --ui --branch evrima"), cmd)
        self.assertEqual(self.calls("scp"), [], "a dry run uploads nothing")

    def test_provision_runs_upload_then_installer(self):
        self.add(user="root")
        snap = os.path.join(self.dir, "theisle-snapshot_20261123_120000.tar.gz")
        open(snap, "w").close()
        rc, out = self.cli("provision", "box", "--native", "--from-snapshot", snap, "--setup")
        self.assertEqual(rc, 0, out)
        scps = self.calls("scp")
        self.assertTrue(scps[0][-1].endswith(":theisle-installer.tgz"))
        self.assertTrue(scps[1][-1].endswith(":theisle-installer/theisle-snapshot_20261123_120000.tar.gz"))
        install = [c[-1] for c in self.calls("ssh") if "install.sh" in c[-1]][0]
        self.assertIn("bash ./linux/install.sh --native --yes --from-snapshot $HOME/theisle-installer/theisle-snapshot_20261123_120000.tar.gz", install)
        self.assertNotIn("sudo", install, "root needs no sudo")
        self.assertIn("isle-server setup --yes", self.calls("ssh")[-1][-1])
        self.assertEqual(self.inv.load("box")["OS"], "linux", "the detected OS is remembered")

    def test_provision_failure_is_reported(self):
        self.add()
        os.environ["FAKE_SCP_RC"] = "1"
        rc, out = self.cli("provision", "box")
        self.assertEqual(rc, 1)
        self.assertIn("Upload of theisle-installer.tgz failed", out)
        os.environ["FAKE_SCP_RC"] = "0"
        os.environ["FAKE_CMD_RC"] = "3"
        rc, out = self.cli("provision", "box")
        self.assertIn("installer on box failed (exit 3)", out)

    def test_provision_windows_command(self):
        self.add("win", os="windows", mode="docker")
        rc, out = self.cli("provision", "win", "--start", "--image", "ghcr.io/x/theisle:1.13", "--dry-run")
        self.assertEqual(rc, 0, out)
        cmd = json.loads(out)["command"]
        self.assertTrue(cmd.startswith("powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "))
        script = base64.b64decode(cmd.split()[-1]).decode("utf-16-le")
        self.assertIn("tar.exe -xzf", script)
        self.assertIn("Install.ps1') -Docker -Yes -InstallRoot 'C:\\TheIsle' -Start -Image 'ghcr.io/x/theisle:1.13'", script)
        self.parses(script)

    def test_run_commands(self):
        self.add()
        rc, out = self.cli("run", "box", "--", "status")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.calls("ssh")[-1][-1], "sudo -n -u theisle isle-server status")
        self.cli("add", "dock", "--host", "h2", "--user", "admin", "--mode", "docker", "--os", "linux")
        self.cli("run", "dock", "backup", "status")
        self.assertEqual(self.calls("ssh")[-1][-1], "sudo -n isle-server backup status")
        self.cli("add", "win", "--host", "h3", "--user", "Administrator", "--os", "windows")
        self.cli("run", "win", "status")
        script = base64.b64decode(self.calls("ssh")[-1][-1].split()[-1]).decode("utf-16-le")
        self.assertIn("& 'C:\\TheIsle\\scripts\\windows\\IsleServer.ps1' 'status'", script)
        self.parses(script)
        rc, out = self.cli("run", "box", "status", "a;b")
        self.assertEqual(rc, 1)
        self.assertIn("may only use", out)

    def test_wizard_existing_key(self):
        key = os.path.join(self.dir, "id_test")
        open(key, "w").close()
        answers = "\n".join(["lab", "10.0.0.5", "admin", "2222", "linux", "docker", key, "n", "y", "n"]) + "\n"
        rc, out = self.cli("wizard", inp=answers)
        self.assertEqual(rc, 0, out)
        h = self.inv.load("lab")
        self.assertEqual((h["HOST"], h["PORT"], h["MODE"], h["KEY"]), ("10.0.0.5", "2222", "docker", key))
        install = [c[-1] for c in self.calls("ssh") if "install.sh" in c[-1]][0]
        self.assertTrue(install.endswith("install.sh --docker --yes"), install)
        self.assertIn("isle-server setup --yes", self.calls("ssh")[-1][-1])

    def parses(self, script):
        pwsh = shutil.which("pwsh") or shutil.which("powershell")
        if not pwsh:
            return
        path = os.path.join(self.dir, "remote.ps1")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(script)
        p = subprocess.run([pwsh, "-NoProfile", "-Command",
                            "$e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile('%s', [ref]$null, [ref]$e); $e.Count" % path],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        self.assertEqual(p.stdout.strip().splitlines()[-1:], ["0"], "the PowerShell sent to Windows parses: %s" % p.stdout)


if __name__ == "__main__":
    unittest.main()
