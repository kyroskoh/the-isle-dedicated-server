#!/usr/bin/env python3
"""Offline tests for tools/isle_plugins.py and the first-party plugins (PRD PLG-07).

Runs against a throwaway copy of the repo, with a local HTTP server (remote
catalogs, archives, Discord webhook) and a mock RCON server. Nothing leaves
the machine.

    python3 -m unittest -v tests/test_plugins.py
"""
import hashlib
import http.server
import io
import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest

SRC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class Http(object):
    """Serves files from a dict and records POST bodies."""

    def __init__(self):
        self.files, self.posts = {}, []
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = outer.files.get(self.path)
                self.send_response(200 if body is not None else 404)
                self.end_headers()
                if body is not None:
                    self.wfile.write(body)

            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                outer.posts.append((self.path, self.rfile.read(length)))
                self.send_response(204)
                self.end_headers()

            def log_message(self, *args):
                pass

        self.server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()


class Rcon(object):
    """Mock Evrima RCON: accepts any login, records commands (byte, text)."""

    def __init__(self):
        self.commands = []
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(5)
        self.port = self.sock.getsockname()[1]
        threading.Thread(target=self.loop, daemon=True).start()

    def loop(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            with conn:
                conn.recv(1024)
                conn.sendall(b"Password Accepted")
                data = conn.recv(4096)
                if data[:1] == b"\x02":
                    self.commands.append((data[1], data[2:].rstrip(b"\x00").decode()))
                conn.sendall(b"OK")


def make_plugin_tar(name, version="1.0.0", hook_code="import sys; sys.exit(0)", extra=None):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        files = {
            "%s/plugin.json" % name: json.dumps({"name": name, "version": version, "description": "test plugin",
                                                 "hooks": {"post-backup": "p.py"}, "commands": {"run": "p.py"}}),
            "%s/p.py" % name: hook_code,
        }
        files.update(extra or {})
        for path, text in files.items():
            data = text.encode()
            info = tarfile.TarInfo(path)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


class PluginTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.http = Http()
        cls.rcon = Rcon()

    @classmethod
    def tearDownClass(cls):
        cls.http.close()

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.repo = os.path.join(self.tmp, "repo")
        shutil.copytree(SRC, self.repo, ignore=shutil.ignore_patterns(".git", "installed", "__pycache__"))
        self.conf = os.path.join(self.tmp, "conf", "server.conf")
        os.makedirs(os.path.dirname(self.conf))
        self.backups = os.path.join(self.tmp, "backups")
        os.makedirs(self.backups)
        self.marker = os.path.join(self.tmp, "launcher-called")
        self.launcher = os.path.join(self.tmp, "fake-launcher.sh")
        with open(self.launcher, "w") as f:
            f.write("#!/bin/sh\necho \"$@\" >> '%s'\n" % self.marker)
        os.chmod(self.launcher, 0o755)
        with open(self.conf, "w") as f:
            f.write("SERVER_NAME=\"Test Server\"\nRCON_ENABLED=true\nRCON_PASSWORD=pw\nRCON_PORT=%d\nBACKUP_DIR=%s\n"
                    % (self.rcon.port, self.backups))
        self.rcon.commands.clear()
        self.http.posts.clear()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def pl(self, *args, check=True):
        proc = subprocess.run([sys.executable, os.path.join(self.repo, "tools", "isle_plugins.py"),
                               "--conf", self.conf, "--launcher", self.launcher] + list(args),
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        out = proc.stdout.decode()
        if check and proc.returncode != 0:
            self.fail("plugins %s failed (%d):\n%s" % (" ".join(args), proc.returncode, out))
        return proc.returncode, out

    def installed_dir(self, name):
        return os.path.join(self.repo, "plugins", "installed", name)

    def enabled(self):
        path = os.path.join(self.tmp, "conf", "plugins", "enabled.txt")
        return open(path).read().split() if os.path.exists(path) else []

    # ------------------------------------------------------------ catalog --
    def test_list_and_search(self):
        _, out = self.pl("list")
        for name in ("restart-countdown", "discord-notify", "offsite-backup", "welcome-announcer"):
            self.assertIn(name, out)
        _, out = self.pl("search", "discord")
        self.assertIn("discord-notify", out)
        self.assertNotIn("offsite-backup", out)
        _, out = self.pl("info", "offsite-backup")
        self.assertIn("DEST_DIR", out)

    # ------------------------------------------------------- install etc. --
    def test_install_enable_disable_remove(self):
        self.pl("install", "discord-notify")
        self.assertTrue(os.path.isfile(os.path.join(self.installed_dir("discord-notify"), "plugin.json")))
        self.assertIn("discord-notify", self.enabled())
        settings = os.path.join(self.tmp, "conf", "plugins", "discord-notify.conf")
        self.assertTrue(os.path.isfile(settings))
        if os.name == "posix":
            self.assertEqual(stat.S_IMODE(os.stat(settings).st_mode), 0o600)
        self.pl("disable", "discord-notify")
        self.assertNotIn("discord-notify", self.enabled())
        self.pl("enable", "discord-notify")
        self.assertIn("discord-notify", self.enabled())
        self.pl("remove", "discord-notify")
        self.assertFalse(os.path.exists(self.installed_dir("discord-notify")))
        self.assertTrue(os.path.isfile(settings), "settings are kept without --purge")
        self.pl("install", "discord-notify")
        self.pl("remove", "discord-notify", "--purge")
        self.assertFalse(os.path.isfile(settings))

    def test_config_and_secret_masking(self):
        self.pl("install", "discord-notify")
        self.pl("config", "discord-notify", "DISCORD_WEBHOOK_URL=https://example.invalid/hook")
        _, out = self.pl("config", "discord-notify")
        self.assertIn("DISCORD_WEBHOOK_URL=********", out)
        rc, out = self.pl("config", "discord-notify", "NOPE=1", check=False)
        self.assertEqual(rc, 1)

    def test_presets(self):
        _, out = self.pl("preset")
        self.assertIn("recommended", out)
        self.pl("preset", "recommended")
        self.assertEqual(sorted(self.enabled()), ["discord-notify", "offsite-backup", "restart-countdown"])
        self.pl("preset", "full")
        self.assertIn("welcome-announcer", self.enabled())

    def test_update_detects_new_builtin_version(self):
        self.pl("install", "welcome-announcer")
        manifest = os.path.join(self.repo, "plugins", "available", "welcome-announcer", "plugin.json")
        data = json.load(open(manifest))
        data["version"] = "9.0.0"
        json.dump(data, open(manifest, "w"))
        _, out = self.pl("update")
        self.assertIn("1 plugin(s) updated", out)
        self.assertEqual(json.load(open(os.path.join(self.installed_dir("welcome-announcer"), "plugin.json")))["version"], "9.0.0")

    # ------------------------------------------------------------ remote --
    def test_remote_install_requires_and_checks_sha256(self):
        blob = make_plugin_tar("remote-thing")
        self.http.files["/remote-thing.tar.gz"] = blob
        url = self.http.url + "/remote-thing.tar.gz"
        rc, out = self.pl("install", url, check=False)
        self.assertEqual(rc, 1)
        self.assertIn("need a SHA-256", out)
        rc, out = self.pl("install", url + "#sha256=" + "0" * 64, check=False)
        self.assertEqual(rc, 1)
        self.assertIn("mismatch", out)
        self.assertFalse(os.path.exists(self.installed_dir("remote-thing")))
        _, out = self.pl("install", url + "#sha256=" + hashlib.sha256(blob).hexdigest())
        self.assertIn("third-party code", out)
        self.assertTrue(os.path.isdir(self.installed_dir("remote-thing")))

    def test_path_traversal_rejected(self):
        blob = make_plugin_tar("evil", extra={"../../escaped.txt": "x"})
        self.http.files["/evil.tar.gz"] = blob
        rc, out = self.pl("install", self.http.url + "/evil.tar.gz#" + hashlib.sha256(blob).hexdigest(), check=False)
        self.assertEqual(rc, 1)
        self.assertIn("unsafe path", out)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "escaped.txt")))
        self.assertFalse(os.path.exists(self.installed_dir("evil")))

    def test_third_party_catalog(self):
        blob = make_plugin_tar("catalog-plugin", version="2.0.0")
        self.http.files["/cp.tar.gz"] = blob
        self.http.files["/catalog.json"] = json.dumps({"plugins": [{
            "name": "catalog-plugin", "version": "2.0.0", "description": "from a third-party catalog",
            "url": self.http.url + "/cp.tar.gz", "sha256": hashlib.sha256(blob).hexdigest()}]}).encode()
        self.pl("sources", "add", self.http.url + "/catalog.json")
        _, out = self.pl("search", "third-party")
        self.assertIn("catalog-plugin", out)
        self.pl("install", "catalog-plugin")
        self.assertIn("catalog-plugin", self.enabled())
        self.pl("sources", "remove", self.http.url + "/catalog.json")
        _, out = self.pl("sources")
        self.assertIn("No extra catalogs", out)

    # ------------------------------------------------------------- hooks --
    def test_failing_hook_never_blocks(self):
        blob = make_plugin_tar("crashy", hook_code="import sys; sys.exit(3)")
        path = os.path.join(self.tmp, "crashy.tar.gz")
        open(path, "wb").write(blob)
        self.pl("install", path)
        rc, out = self.pl("hook", "post-backup", check=False)
        self.assertEqual(rc, 0)
        self.assertIn("crashy failed on post-backup", out)

    def test_offsite_backup_hook_copies_and_prunes(self):
        dest = os.path.join(self.tmp, "nas")
        for i in range(3):
            p = os.path.join(self.backups, "theisle-2026010%d-000000.tar.gz" % i)
            open(p, "w").write(str(i))
            os.utime(p, (1000 + i, 1000 + i))
        self.pl("install", "offsite-backup")
        self.pl("config", "offsite-backup", "DEST_DIR=" + dest, "KEEP=2")
        for i in range(3):  # three backup events, newest file changes each time
            p = os.path.join(self.backups, "theisle-2026020%d-000000.tar.gz" % i)
            open(p, "w").write("new%d" % i)
            os.utime(p, (2000 + i, 2000 + i))
            self.pl("hook", "post-backup")
        self.assertEqual(sorted(os.listdir(dest)), ["theisle-20260201-000000.tar.gz", "theisle-20260202-000000.tar.gz"])

    def test_discord_notify_posts_to_webhook(self):
        self.pl("install", "discord-notify")
        self.pl("config", "discord-notify", "DISCORD_WEBHOOK_URL=%s/hook" % self.http.url, "EVENTS=post-start")
        self.pl("hook", "post-start")
        self.pl("hook", "post-stop")  # not in EVENTS -> nothing sent
        self.assertEqual(len(self.http.posts), 1)
        body = json.loads(self.http.posts[0][1])
        self.assertIn("Test Server", body["content"])
        self.pl("run", "discord-notify", "test")
        self.assertEqual(len(self.http.posts), 2)

    def test_restart_countdown_announces_saves_restarts(self):
        self.pl("install", "restart-countdown")
        self.pl("run", "restart-countdown", "run", "0")
        texts = [t for b, t in self.rcon.commands if b == 0x10]
        self.assertTrue(any("Restarting now" in t for t in texts), self.rcon.commands)
        self.assertIn(0x50, [b for b, _ in self.rcon.commands], "save was sent")
        self.assertEqual(open(self.marker).read().strip(), "restart")

    def test_welcome_announcer_run(self):
        self.pl("install", "welcome-announcer")
        self.pl("run", "welcome-announcer")
        self.assertTrue(any(b == 0x10 and "Test Server" in t for b, t in self.rcon.commands), self.rcon.commands)


if __name__ == "__main__":
    unittest.main(verbosity=2)
