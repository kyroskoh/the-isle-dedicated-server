#!/usr/bin/env python3
"""
tests/test_logs.py - time zone, KIND_yyyymmdd_hhmmss names and log rotation (PRD LOG-01..05).
    python3 -m unittest -v tests/test_logs.py
The launcher tests run linux/isle-server.sh with a fake game binary (Linux only).
"""
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "tools"))
import isle_logs  # noqa: E402

NAME = re.compile(r"^(launcher|server|ui)_\d{8}_\d{6}(_\d+)?\.log$")


class StampTest(unittest.TestCase):
    def test_format(self):
        self.assertRegex(isle_logs.stamp({}), r"^\d{8}_\d{6}$")
        fixed = time.struct_time((2026, 11, 8, 9, 5, 7, 0, 312, 0))
        self.assertEqual(isle_logs.stamp({}, fixed), "20261108_090507")

    @unittest.skipUnless(hasattr(time, "tzset"), "needs time.tzset")
    def test_utc_and_local(self):
        old = os.environ.get("TZ")
        os.environ["TZ"] = "UTC-08"  # POSIX sign: 8 hours EAST of UTC
        time.tzset()
        try:
            self.assertEqual(isle_logs.zone_label({"TIMEZONE": "utc"}), "UTC")
            self.assertEqual(isle_logs.zone_label({"TIMEZONE": "local"}), "UTC+08:00")
            self.assertEqual(isle_logs.utc_offset_minutes({"TIMEZONE": "local"}), 480)
            self.assertEqual(isle_logs.utc_offset_minutes({"TIMEZONE": "UTC"}), 0)
            utc = time.mktime(time.strptime(isle_logs.stamp({"TIMEZONE": "utc"}), "%Y%m%d_%H%M%S"))
            local = time.mktime(time.strptime(isle_logs.stamp({"TIMEZONE": "local"}), "%Y%m%d_%H%M%S"))
            self.assertAlmostEqual(local - utc, 8 * 3600, delta=5)
            self.assertTrue(isle_logs.human({"TIMEZONE": "utc"}).endswith(" UTC"))
        finally:
            if old is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = old
            time.tzset()


class RotationTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="isle-logs-")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def names(self, kind=None):
        return [n for n, _ in isle_logs.files_of(self.dir, kind)]

    def test_rotates_by_size_and_keeps_newest(self):
        log = isle_logs.RotatingLog(self.dir, "server", {}, max_bytes=100, keep=3)
        for i in range(40):
            log.write("line %02d %s\n" % (i, "x" * 20))
        log.close()
        names = self.names("server")
        self.assertEqual(len(names), 3, names)
        for n in names:
            self.assertRegex(n, NAME)
        # the newest file holds the last line, older files were pruned
        with open(os.path.join(self.dir, names[-1])) as handle:
            self.assertIn("line 39", handle.read())
        self.assertFalse(any("line 00" in open(os.path.join(self.dir, n)).read() for n in names))
        # every kept file but the newest reached the size limit
        for n in names[:-1]:
            self.assertGreaterEqual(os.path.getsize(os.path.join(self.dir, n)), 100)

    def test_same_second_gets_a_counter(self):
        a = isle_logs.RotatingLog(self.dir, "ui", {}, keep=0)
        b = isle_logs.RotatingLog(self.dir, "ui", {}, keep=0)
        a.close(); b.close()
        self.assertNotEqual(a.path, b.path)
        self.assertRegex(os.path.basename(b.path), r"^ui_\d{8}_\d{6}_1\.log$")

    def test_current_reuses_until_full(self):
        first = isle_logs.current(self.dir, "launcher", {"LOG_MAX_SIZE_MB": "1"})
        self.assertEqual(isle_logs.current(self.dir, "launcher", {"LOG_MAX_SIZE_MB": "1"}), first)
        with open(first, "w") as handle:
            handle.write("x" * (1024 * 1024 + 1))
        time.sleep(1.1)
        second = isle_logs.current(self.dir, "launcher", {"LOG_MAX_SIZE_MB": "1"})
        self.assertNotEqual(second, first)

    def test_retention_zero_keeps_all_and_kinds_are_separate(self):
        for kind in ("server", "ui"):
            for i in range(4):
                open(os.path.join(self.dir, "%s_2026110%d_000000.log" % (kind, i)), "w").close()
        self.assertEqual(isle_logs.prune(self.dir, "server", 0), [])
        gone = isle_logs.prune(self.dir, "server", 2)
        self.assertEqual(gone, ["server_20261100_000000.log", "server_20261101_000000.log"])
        self.assertEqual(len(self.names("ui")), 4)
        open(os.path.join(self.dir, "notes.txt"), "w").close()
        open(os.path.join(self.dir, "server.log"), "w").close()
        self.assertEqual(len(self.names()), 6, "files that are not KIND_stamp.log are never touched")

    def test_game_backup_logs(self):
        game = os.path.join(self.dir, "Logs")
        os.makedirs(game)
        for i in range(5):
            p = os.path.join(game, "TheIsle-backup-2026.11.0%d-00.00.00.log" % i)
            open(p, "w").close()
            os.utime(p, (1000 + i, 1000 + i))
        open(os.path.join(game, "TheIsle.log"), "w").close()
        gone = isle_logs.prune_game_logs(game, 2)
        self.assertEqual(len(gone), 3)
        self.assertEqual(sorted(os.listdir(game)), ["TheIsle-backup-2026.11.03-00.00.00.log",
                                                    "TheIsle-backup-2026.11.04-00.00.00.log", "TheIsle.log"])

    def test_log_dir(self):
        conf = os.path.join(self.dir, "config", "server.conf")
        self.assertEqual(isle_logs.log_dir(conf, {"LOG_DIR": "/var/log/theisle"}), "/var/log/theisle")
        self.assertEqual(isle_logs.log_dir(conf, {"LOG_DIR": "logs"}), os.path.join(self.dir, "config", "logs"))
        self.assertEqual(isle_logs.log_dir(conf, {}), os.path.join(REPO, "logs"))

    def test_write_cli_tees(self):
        conf = os.path.join(self.dir, "server.conf")
        with open(conf, "w") as handle:
            handle.write("LOG_DIR=%s\nTIMEZONE=utc\n" % self.dir)
        out = subprocess.run([sys.executable, os.path.join(REPO, "tools", "isle_logs.py"), "--conf", conf, "write", "server", "--tee"],
                             input=b"hello\nworld\n", stdout=subprocess.PIPE, check=True).stdout
        self.assertEqual(out.replace(b"\r", b""), b"hello\nworld\n")
        (name,) = self.names("server")
        with open(os.path.join(self.dir, name)) as handle:
            self.assertEqual(handle.read(), "hello\nworld\n")


@unittest.skipUnless(sys.platform.startswith("linux"), "the bash launcher runs on Linux")
class LauncherTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="isle-launcher-logs-")
        game = os.path.join(self.dir, "srv", "TheIsle", "Binaries", "Linux")
        os.makedirs(game)
        exe = os.path.join(game, "TheIsleServer-Linux-Shipping")
        with open(exe, "w") as handle:
            handle.write('#!/bin/bash\ntrap "exit 0" TERM\ni=0\nwhile :; do echo "game line $i"; i=$((i+1)); sleep 0.05; done\n')
        os.chmod(exe, 0o755)
        logs = os.path.join(self.dir, "srv", "TheIsle", "Saved", "Logs")
        os.makedirs(logs)
        for i in range(5):
            open(os.path.join(logs, "TheIsle-backup-2026.11.0%d-00.00.00.log" % i), "w").close()
        self.conf = os.path.join(self.dir, "server.conf")
        with open(os.path.join(REPO, "config", "server.conf.example")) as src:
            text = src.read()
        for key, value in (("SERVER_DIR", self.dir + "/srv"), ("BACKUP_DIR", self.dir + "/bk"), ("UPDATE_ON_START", "false"),
                           ("SAVE_BEFORE_STOP", "false"), ("RCON_PASSWORD", "x"), ("TIMEZONE", "utc"), ("LOG_DIR", self.dir + "/logs"),
                           ("LOG_RETENTION", "2")):
            text = re.sub(r"(?m)^%s=.*$" % key, "%s=%s" % (key, value), text)
        with open(self.conf, "w") as handle:
            handle.write(text)
        self.env = dict(os.environ, ISLE_CONF=self.conf, ISLE_NO_SYSTEMD="1", ISLE_ALLOW_ROOT="1", TZ="UTC-08")
        self.env.pop("ISLE_LOG_DIR", None)

    def tearDown(self):
        self.launcher("stop")
        shutil.rmtree(self.dir, ignore_errors=True)

    def launcher(self, *args, env=None):
        p = subprocess.run(["bash", os.path.join(REPO, "linux", "isle-server.sh")] + list(args), env=env or self.env,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        return p.returncode, p.stdout.decode()

    def test_logs_names_rotation_and_utc(self):
        self.assertEqual(self.launcher("start")[0], 0)
        time.sleep(3)
        self.assertEqual(self.launcher("backup")[0], 0)
        self.assertEqual(self.launcher("stop")[0], 0)
        logs = sorted(os.listdir(os.path.join(self.dir, "logs")))
        self.assertTrue(logs and all(NAME.match(n) for n in logs), logs)
        server = [n for n in logs if n.startswith("server_")]
        launcher = [n for n in logs if n.startswith("launcher_")]
        self.assertTrue(server and launcher, logs)
        with open(os.path.join(self.dir, "logs", server[-1])) as handle:
            self.assertIn("game line 1", handle.read())
        with open(os.path.join(self.dir, "logs", launcher[-1])) as handle:
            text = handle.read()
        self.assertRegex(text, r"\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d UTC\] CMD  start")
        self.assertIn("CMD  backup", text)
        # TIMEZONE=utc wins over the machine's TZ (UTC+8 here): the stamp is the UTC time
        utc_now = time.strftime("%Y%m%d_%H", time.gmtime())
        self.assertTrue(server[-1].startswith("server_" + utc_now[:8]), server)
        backups = os.listdir(os.path.join(self.dir, "bk"))
        self.assertEqual(len(backups), 1)
        self.assertRegex(backups[0], r"^theisle-backup_\d{8}_\d{6}\.tar\.gz$")
        game = sorted(os.listdir(os.path.join(self.dir, "srv", "TheIsle", "Saved", "Logs")))
        self.assertEqual(len([g for g in game if g.startswith("TheIsle-backup-")]), 2, "LOG_RETENTION applies to the game's own logs")
        code, out = self.launcher("logs", "list")
        self.assertEqual(code, 0)
        self.assertIn(server[-1], out)
        code, out = self.launcher("logs", "server")
        self.assertIn("game line", out)
        # read-only commands do not write the launcher log
        size = os.path.getsize(os.path.join(self.dir, "logs", launcher[-1]))
        self.launcher("status"); self.launcher("info"); self.launcher("check")
        self.assertEqual(os.path.getsize(os.path.join(self.dir, "logs", launcher[-1])), size)

    def test_local_time_zone(self):
        with open(self.conf) as handle:
            text = handle.read().replace("TIMEZONE=utc", "TIMEZONE=local")
        with open(self.conf, "w") as handle:
            handle.write(text)
        self.assertEqual(self.launcher("configure")[0], 0)
        (launcher,) = [n for n in os.listdir(os.path.join(self.dir, "logs")) if n.startswith("launcher_")]
        local_now = time.strftime("%Y%m%d_%H", time.gmtime(time.time() + 8 * 3600))
        self.assertTrue(launcher.startswith("launcher_" + local_now[:8]), launcher)
        with open(os.path.join(self.dir, "logs", launcher)) as handle:
            self.assertRegex(handle.read(), r"\] CMD  configure")

    def test_bad_values_fail_check(self):
        for key, value in (("TIMEZONE", "mars"), ("LOG_RETENTION", "-1"), ("LOG_MAX_SIZE_MB", "big")):
            with open(self.conf) as handle:
                text = re.sub(r"(?m)^%s=.*$" % key, "%s=%s" % (key, value), handle.read())
            bad = self.conf + ".bad"
            with open(bad, "w") as handle:
                handle.write(text)
            code, out = self.launcher("check", env=dict(self.env, ISLE_CONF=bad))
            self.assertEqual(code, 1, key)
            self.assertIn(key, out)


if __name__ == "__main__":
    unittest.main()
