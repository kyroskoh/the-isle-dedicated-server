#!/usr/bin/env python3
"""Offline tests for tools/isle_snapshot.py (PRD MIG-08).

Two "machines" are simulated with separate config/server folders in a temp dir.
Runs on Linux and Windows:   python3 -m unittest -v tests/test_snapshot.py
"""
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest

SRC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(SRC, "tools", "isle_snapshot.py")
EXAMPLE = os.path.join(SRC, "config", "server.conf.example")


class Machine(object):
    def __init__(self, root, name, extra=""):
        self.root = os.path.join(root, name)
        self.conf = os.path.join(self.root, "config", "server.conf")
        self.server = os.path.join(self.root, "server")
        self.backups = os.path.join(self.root, "backups")
        self.overrides = os.path.join(self.root, "config", "overrides")
        self.marker = os.path.join(self.root, "launcher.log")
        os.makedirs(os.path.dirname(self.conf))
        text = open(EXAMPLE).read()
        text = text.replace("SERVER_DIR=\n", "SERVER_DIR=%s\n" % self.server)
        text = text.replace("BACKUP_DIR=\n", "BACKUP_DIR=%s\n" % self.backups)
        text = text.replace("RCON_PASSWORD=\n", "RCON_PASSWORD=pw-%s\n" % name)
        open(self.conf, "w").write(text + extra)
        self.running = False
        self.launcher = os.path.join(self.root, "launcher.py")

    def write_launcher(self):
        # fake launcher: "status" exits 0 if a flag file exists; logs every call
        flag = os.path.join(self.root, "running.flag")
        open(self.launcher, "w").write(
            "import os, sys\nopen(%r, 'a').write(' '.join(sys.argv[1:]) + '\\n')\n"
            "if sys.argv[1] == 'status': sys.exit(0 if os.path.exists(%r) else 3)\n"
            "if sys.argv[1] == 'stop' and os.path.exists(%r): os.remove(%r)\n" % (self.marker, flag, flag, flag))
        if os.name == "nt":
            wrapper = self.launcher[:-3] + ".cmd"
            open(wrapper, "w").write('@"%s" "%s" %%*\r\n' % (sys.executable, self.launcher))
        else:
            wrapper = self.launcher[:-3] + ".sh"
            open(wrapper, "w").write('#!/bin/sh\nexec "%s" "%s" "$@"\n' % (sys.executable, self.launcher))
            os.chmod(wrapper, 0o755)
        return wrapper

    def set_running(self, on):
        flag = os.path.join(self.root, "running.flag")
        if on:
            open(flag, "w").write("1")
        elif os.path.exists(flag):
            os.remove(flag)

    def conf_value(self, key):
        val = None
        for line in open(self.conf):
            if line.startswith(key + "="):
                val = line.rstrip("\r\n").split("=", 1)[1]
        return val


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        # isolate plugins/installed and snapshots/: run a copy of the repo
        self.repo = os.path.join(self.tmp, "repo")
        shutil.copytree(SRC, self.repo, ignore=shutil.ignore_patterns(".git", "installed", "snapshots", "__pycache__"))
        self.tool = os.path.join(self.repo, "tools", "isle_snapshot.py")
        self.a = Machine(self.tmp, "a")
        self.b = Machine(self.tmp, "b")
        self.la, self.lb = self.a.write_launcher(), self.b.write_launcher()
        # machine A: a world, backups, overrides, plugin state + code
        saved = os.path.join(self.a.server, "TheIsle", "Saved")
        os.makedirs(os.path.join(saved, "SaveGames"))
        os.makedirs(os.path.join(saved, "Logs"))
        open(os.path.join(saved, "SaveGames", "world.sav"), "w").write("world-a")
        open(os.path.join(saved, "Logs", "huge.log"), "w").write("x" * 1000)
        os.makedirs(self.a.backups)
        open(os.path.join(self.a.backups, "theisle-20260101-000000.tar.gz"), "w").write("b")
        os.makedirs(self.a.overrides)
        open(os.path.join(self.a.overrides, "Game.ini"), "w").write("[/Script/TheIsle.TIGameSession]\nGrowthMultiplier=4\n")
        state = os.path.join(os.path.dirname(self.a.conf), "plugins")
        os.makedirs(state)
        open(os.path.join(state, "enabled.txt"), "w").write("discord-notify\n")
        open(os.path.join(state, "discord-notify.conf"), "w").write("DISCORD_WEBHOOK_URL=https://x\n")
        code = os.path.join(self.repo, "plugins", "installed", "discord-notify")
        shutil.copytree(os.path.join(self.repo, "plugins", "available", "discord-notify"), code)
        # A's settings differ from B's
        self.set(self.a.conf, "SERVER_NAME", '"Server A"')
        self.set(self.a.conf, "MAX_PLAYERS", "42")
        self.set(self.a.conf, "MULTIHOME_IP", "10.0.0.5")
        self.set(self.b.conf, "SERVER_NAME", '"Server B"')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    @staticmethod
    def set(conf, key, value):
        lines = open(conf).read().splitlines()
        lines = [("%s=%s" % (key, value)) if l.startswith(key + "=") else l for l in lines]
        open(conf, "w").write("\n".join(lines) + "\n")

    def snap(self, machine, launcher, *args, check=True):
        cmd = [sys.executable, self.tool, "--conf", machine.conf, "--runtime", "native", "--launcher", launcher,
               "--server-dir", machine.server, "--backup-dir", machine.backups] + list(args)
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        out = p.stdout.decode()
        if check and p.returncode != 0:
            self.fail("snapshot %s failed (%d):\n%s" % (" ".join(args), p.returncode, out))
        return p.returncode, out

    def create(self, *args):
        out_file = os.path.join(self.tmp, "snap-%d.tar.gz" % len(os.listdir(self.tmp)))
        self.snap(self.a, self.la, "create", "--output", out_file, *args)
        return out_file

    def manifest(self, path):
        with tarfile.open(path) as t:
            return json.load(io.TextIOWrapper(t.extractfile("snapshot.json"), encoding="utf-8"))

    # -------------------------------------------------------------- create --
    def test_create_default_parts(self):
        f = self.create()
        m = self.manifest(f)
        self.assertEqual(m["format"], 1)
        self.assertEqual(sorted(m["parts"]), ["overrides", "plugins", "settings", "worlds"])
        self.assertEqual(m["server_name"], "Server A")
        with tarfile.open(f) as t:
            names = t.getnames()
        self.assertIn("world/Saved/SaveGames/world.sav", names)
        self.assertFalse(any("Logs" in n for n in names), "logs are excluded")
        if os.name == "posix":
            self.assertEqual(stat.S_IMODE(os.stat(f).st_mode), 0o600)

    def test_create_include_filter_and_all(self):
        self.assertEqual(sorted(self.manifest(self.create("--include", "worlds"))["parts"]), ["worlds"])
        self.assertIn("backups", self.manifest(self.create("--include", "all"))["parts"])
        rc, out = self.snap(self.a, self.la, "create", "--include", "nonsense", check=False)
        self.assertEqual(rc, 1)
        self.assertIn("unknown part", out)

    def test_create_saves_running_server(self):
        self.a.set_running(True)
        self.create()
        self.assertIn("save", open(self.a.marker).read().split())

    # ------------------------------------------------------------- restore --
    def test_restore_to_other_machine(self):
        f = self.create("--include", "all")
        self.snap(self.b, self.lb, "restore", f, "--include", "all")
        self.assertEqual(open(os.path.join(self.b.server, "TheIsle", "Saved", "SaveGames", "world.sav")).read(), "world-a")
        self.assertEqual(self.b.conf_value("SERVER_NAME"), '"Server A"')
        self.assertEqual(self.b.conf_value("MAX_PLAYERS"), "42")
        self.assertEqual(self.b.conf_value("SERVER_DIR"), self.b.server, "machine keys stay")
        self.assertEqual(self.b.conf_value("MULTIHOME_IP"), "", "machine keys stay")
        self.assertEqual(self.b.conf_value("RCON_PASSWORD"), "pw-a", "server settings move")
        self.assertTrue([n for n in os.listdir(os.path.dirname(self.b.conf)) if ".bak-snapshot_" in n])
        self.assertTrue(os.path.isfile(os.path.join(self.b.overrides, "Game.ini")))
        self.assertTrue(os.path.isfile(os.path.join(self.b.backups, "theisle-20260101-000000.tar.gz")))
        self.assertIn("discord-notify", open(os.path.join(os.path.dirname(self.b.conf), "plugins", "enabled.txt")).read())
        self.assertTrue(os.path.isfile(os.path.join(self.repo, "plugins", "installed", "discord-notify", "plugin.json")))

    def test_all_settings_carries_machine_keys(self):
        f = self.create()
        self.snap(self.b, self.lb, "restore", f, "--include", "settings", "--all-settings")
        self.assertEqual(self.b.conf_value("SERVER_DIR"), self.a.server)
        self.assertEqual(self.b.conf_value("MULTIHOME_IP"), "10.0.0.5")

    def test_world_not_overwritten_without_flag(self):
        f = self.create()
        saved = os.path.join(self.b.server, "TheIsle", "Saved", "SaveGames")
        os.makedirs(saved)
        open(os.path.join(saved, "world.sav"), "w").write("world-b")
        _, out = self.snap(self.b, self.lb, "restore", f, "--include", "worlds")
        self.assertIn("already has a world", out)
        self.assertEqual(open(os.path.join(saved, "world.sav")).read(), "world-b")
        self.snap(self.b, self.lb, "restore", f, "--include", "worlds", "--overwrite")
        self.assertEqual(open(os.path.join(saved, "world.sav")).read(), "world-a")
        kept = [n for n in os.listdir(os.path.join(self.b.server, "TheIsle")) if n.startswith("Saved.pre-snapshot_")]
        self.assertEqual(len(kept), 1)

    def test_restore_refused_while_running_unless_stop(self):
        f = self.create()
        self.b.set_running(True)
        rc, out = self.snap(self.b, self.lb, "restore", f, check=False)
        self.assertEqual(rc, 1)
        self.assertIn("running", out)
        self.snap(self.b, self.lb, "restore", f, "--stop")
        self.assertIn("stop", open(self.b.marker).read().split())

    def test_windows_made_snapshot(self):
        """CRLF server.conf with Windows paths, as created by IsleServer.ps1 on Windows."""
        stage = os.path.join(self.tmp, "winstage")
        os.makedirs(os.path.join(stage, "world", "Saved", "SaveGames"))
        os.makedirs(os.path.join(stage, "settings"))
        open(os.path.join(stage, "world", "Saved", "SaveGames", "w.sav"), "w").write("from-windows")
        open(os.path.join(stage, "settings", "server.conf"), "wb").write(
            b'SERVER_NAME="Windows Box"\r\nSERVER_DIR=C:\\TheIsle\\server\r\nRUNTIME=native\r\nMAX_PLAYERS=77\r\n')
        json.dump({"format": 1, "created": "x", "source": {"os": "Windows", "runtime": "native", "host": "win"},
                   "server_name": "Windows Box", "parts": {"worlds": {}, "settings": {}}},
                  open(os.path.join(stage, "snapshot.json"), "w"))
        f = os.path.join(self.tmp, "win.tar.gz")
        with tarfile.open(f, "w:gz") as t:
            for n in os.listdir(stage):
                t.add(os.path.join(stage, n), arcname=n)
        self.snap(self.b, self.lb, "restore", f)
        self.assertEqual(self.b.conf_value("SERVER_NAME"), '"Windows Box"')
        self.assertEqual(self.b.conf_value("MAX_PLAYERS"), "77")
        self.assertEqual(self.b.conf_value("SERVER_DIR"), self.b.server)
        self.assertEqual(open(os.path.join(self.b.server, "TheIsle", "Saved", "SaveGames", "w.sav")).read(), "from-windows")

    # ------------------------------------------------------------- safety --
    def _bad_archive(self, members, manifest=None):
        f = os.path.join(self.tmp, "bad-%d.tar.gz" % len(os.listdir(self.tmp)))
        with tarfile.open(f, "w:gz") as t:
            for name, data in members.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                t.addfile(info, io.BytesIO(data))
            if manifest is not None:
                data = json.dumps(manifest).encode()
                info = tarfile.TarInfo("snapshot.json")
                info.size = len(data)
                t.addfile(info, io.BytesIO(data))
        return f

    def test_unsafe_and_invalid_archives_refused(self):
        cases = [
            (self._bad_archive({"../escape.txt": b"x"}, {"format": 1, "parts": {}}), "unsafe path"),
            (self._bad_archive({"a.txt": b"x"}), "not a snapshot"),
            (self._bad_archive({"a.txt": b"x"}, {"format": 99, "parts": {}}), "unsupported snapshot format"),
        ]
        for path, message in cases:
            rc, out = self.snap(self.b, self.lb, "restore", path, check=False)
            self.assertEqual(rc, 1, out)
            self.assertIn(message, out)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "escape.txt")))

    def test_info_and_list(self):
        self.snap(self.a, self.la, "create")
        _, out = self.snap(self.a, self.la, "list")
        self.assertIn("theisle-snapshot_", out)
        f = self.create()
        _, out = self.snap(self.a, self.la, "info", f)
        self.assertIn('"server_name": "Server A"', out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
