#!/usr/bin/env python3
"""
tests/test_offsite.py - 3-2-1 off-site targets (tools/isle_offsite.py, PRD BAK-10..12).
Offline: fake rclone / scp / ssh programs on PATH record their arguments and act on a local folder.
    python3 -m unittest -v tests/test_offsite.py
"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "tools"))
import isle_offsite  # noqa: E402

# A fake for rclone, scp and ssh: logs argv as JSON and emulates them on $FAKE_REMOTE (a local folder).
FAKE = r'''#!/usr/bin/env python3
import json, os, shutil, sys
name = os.path.basename(sys.argv[0]); args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps([name] + args) + "\n")
root = os.environ["FAKE_REMOTE"]
if os.environ.get("FAKE_FAIL") == name:
    print("permission denied"); sys.exit(1)
def local(p):  # "remote:path" or "user@host:path" -> folder under root
    return os.path.join(root, p.split(":", 1)[1].lstrip("/"))
if name == "rclone":
    cmd = args[0]
    if cmd == "copyto":
        os.makedirs(os.path.dirname(local(args[2])), exist_ok=True); shutil.copy(args[1], local(args[2]))
    elif cmd == "lsf":
        d = local(args[-1]); print("\n".join(sorted(os.listdir(d))) if os.path.isdir(d) else "")
    elif cmd == "deletefile":
        os.remove(local(args[1]))
    elif cmd == "mkdir":
        os.makedirs(local(args[1]), exist_ok=True)
elif name == "scp":
    src, dst = args[-2], args[-1]
    os.makedirs(os.path.dirname(local(dst)), exist_ok=True); shutil.copy(src, local(dst))
elif name == "ssh":
    cmd = args[-1]
    if cmd.startswith("ls -1 -- "):
        d = os.path.join(root, cmd[9:].lstrip("/")); print("\n".join(sorted(os.listdir(d))) if os.path.isdir(d) else "")
    elif cmd.startswith("rm -f -- "):
        for p in cmd[9:].split():
            os.remove(os.path.join(root, p.lstrip("/")))
'''


class OffsiteTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="isle-off-")
        self.bin = os.path.join(self.dir, "bin")
        os.makedirs(self.bin)
        for name in ("rclone", "scp", "ssh"):
            path = os.path.join(self.bin, name)
            with open(path, "w") as handle:
                handle.write(FAKE.replace("#!/usr/bin/env python3", "#!" + sys.executable))
            os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
        self.remote = os.path.join(self.dir, "remote")
        self.log = os.path.join(self.dir, "calls.log")
        self.env_saved = dict(os.environ)
        os.environ.update(PATH=self.bin + os.pathsep + os.environ.get("PATH", ""), FAKE_LOG=self.log, FAKE_REMOTE=self.remote)
        os.environ.pop("FAKE_FAIL", None)
        self.conf = os.path.join(self.dir, "server.conf")
        self.bk = os.path.join(self.dir, "bk")
        os.makedirs(self.bk)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.env_saved)
        shutil.rmtree(self.dir, ignore_errors=True)

    def write(self, **values):
        values.setdefault("BACKUP_DIR", self.bk)
        with open(self.conf, "w") as handle:
            handle.write("".join("%s=%s\n" % kv for kv in values.items()))

    def archive(self, stamp):
        path = os.path.join(self.bk, "theisle-backup_%s.tar.gz" % stamp)
        with open(path, "w") as handle:
            handle.write("x")
        return path

    def calls(self):
        if not os.path.isfile(self.log):
            return []
        with open(self.log) as handle:
            return [json.loads(l) for l in handle]

    # ------------------------------------------------------------------ parse
    def test_parse_valid(self):
        self.assertEqual(isle_offsite.parse("dir:/mnt/nas/theisle")["kind"], "dir")
        self.assertEqual(isle_offsite.parse("dir:D:\\Backups")["kind"], "dir")
        self.assertEqual(isle_offsite.parse("dir:\\\\nas\\share\\isle")["kind"], "dir")
        r = isle_offsite.parse("rclone:b2:my-bucket/theisle")
        self.assertEqual((r["kind"], r["dest"]), ("rclone", "b2:my-bucket/theisle"))
        s = isle_offsite.parse("ssh://backup@nas.lan:2222/srv/isle")
        self.assertEqual((s["login"], s["port"], s["path"]), ("backup@nas.lan", 2222, "/srv/isle"))
        self.assertEqual(isle_offsite.parse("ssh://nas/srv")["port"], 22)

    def test_parse_rejects_unsafe(self):
        for bad in ("", "dir:relative/path", "dir:/a/../etc", "dir:/a\nb", "rclone:-x:y", "rclone:b2:-delete", "rclone:b2:a/../b",
                    "rclone:b2:a;rm -rf /", "ssh://h/p;rm", "ssh://h/p$(id)", "ssh://-oProxyCommand=x/p", "ssh://h:99999/p",
                    "ssh://h/a b", "ssh://h/a/../b", "ftp://host/p", "rclone copy {file} x", "s3://bucket"):
            with self.assertRaises(isle_offsite.TargetError, msg=bad):
                isle_offsite.parse(bad)

    # ------------------------------------------------------------------- send
    def test_send_dir_with_retention(self):
        off = os.path.join(self.dir, "nas")
        self.write(BACKUP_OFFSITE_TARGET="dir:" + off, BACKUP_OFFSITE_RETENTION="2")
        for stamp in ("20261101_050000", "20261102_050000", "20261103_050000"):
            isle_offsite.send(self.conf, self.archive(stamp))
        with open(os.path.join(off, "keep.txt"), "w") as handle:
            handle.write("not a backup")
        isle_offsite.send(self.conf, self.archive("20261104_050000"))
        self.assertEqual(sorted(os.listdir(off)), ["keep.txt", "theisle-backup_20261103_050000.tar.gz", "theisle-backup_20261104_050000.tar.gz"],
                         "only the newest 2 backups are kept, other files are left alone")

    def test_send_rclone_args_and_retention(self):
        self.write(BACKUP_OFFSITE_TARGET="rclone:b2:bucket/isle", BACKUP_RETENTION="2")
        for stamp in ("20261101_050000", "20261102_050000", "20261103_050000"):
            isle_offsite.send(self.conf, self.archive(stamp))
        first = self.calls()[0]
        self.assertEqual(first, ["rclone", "copyto", os.path.join(self.bk, "theisle-backup_20261101_050000.tar.gz"),
                                 "b2:bucket/isle/theisle-backup_20261101_050000.tar.gz"])
        self.assertIn(["rclone", "deletefile", "b2:bucket/isle/theisle-backup_20261101_050000.tar.gz"], self.calls())
        self.assertEqual(sorted(os.listdir(os.path.join(self.remote, "bucket/isle"))),
                         ["theisle-backup_20261102_050000.tar.gz", "theisle-backup_20261103_050000.tar.gz"])

    def test_send_ssh_args(self):
        self.write(BACKUP_OFFSITE_TARGET="ssh://backup@nas.lan:2222/srv/isle", BACKUP_OFFSITE_RETENTION="1")
        isle_offsite.send(self.conf, self.archive("20261101_050000"))
        isle_offsite.send(self.conf, self.archive("20261102_050000"))
        scp = [c for c in self.calls() if c[0] == "scp"][0]
        self.assertEqual(scp[:5], ["scp", "-B", "-q", "-P", "2222"])
        self.assertIn("BatchMode=yes", scp)
        self.assertEqual(scp[-1], "backup@nas.lan:/srv/isle/theisle-backup_20261101_050000.tar.gz")
        self.assertIn(["ssh", "-p", "2222"], [c[:3] for c in self.calls() if c[0] == "ssh"])
        self.assertEqual(os.listdir(os.path.join(self.remote, "srv/isle")), ["theisle-backup_20261102_050000.tar.gz"])

    def test_send_failure_is_reported(self):
        self.write(BACKUP_OFFSITE_TARGET="rclone:b2:bucket/isle")
        os.environ["FAKE_FAIL"] = "rclone"
        with self.assertRaises(RuntimeError) as ctx:
            isle_offsite.send(self.conf, self.archive("20261101_050000"))
        self.assertIn("permission denied", str(ctx.exception))

    def test_cli_send_writes_state(self):
        self.write(BACKUP_OFFSITE_TARGET="dir:" + os.path.join(self.dir, "nas"))
        p = subprocess.run([sys.executable, os.path.join(REPO, "tools", "isle_offsite.py"), "--conf", self.conf, "send", self.archive("20261101_050000")],
                           stdout=subprocess.PIPE, universal_newlines=True)
        self.assertEqual(p.returncode, 0, p.stdout)
        with open(os.path.join(self.dir, ".backup-offsite")) as handle:
            state = handle.read().split()
        self.assertEqual(state[-2:], ["0", "theisle-backup_20261101_050000.tar.gz"])

    # ------------------------------------------------------------------- test
    def test_test_reports_each_part(self):
        self.write(BACKUP_COPY_DIR=os.path.join(self.dir, "copy"), BACKUP_OFFSITE_TARGET="ssh://nas/srv/isle")
        r = isle_offsite.test(self.conf)
        self.assertTrue(r["copy"]["ok"])
        self.assertIn("same disk", r["copy"]["detail"])
        self.assertTrue(r["offsite"]["ok"], r)
        self.assertTrue(r["ok"])
        os.environ["FAKE_FAIL"] = "ssh"
        r = isle_offsite.test(self.conf)
        self.assertFalse(r["offsite"]["ok"])
        self.assertIn("key-based login", r["offsite"]["detail"])
        self.assertFalse(r["ok"])

    def test_test_missing_tool(self):
        self.write(BACKUP_OFFSITE_TARGET="rclone:b2:x")
        os.remove(os.path.join(self.bin, "rclone"))
        os.environ["PATH"] = self.bin
        r = isle_offsite.test(self.conf)
        self.assertFalse(r["offsite"]["ok"])
        self.assertIn("not installed", r["offsite"]["detail"])

    def test_strategy(self):
        self.write(BACKUP_COPY_DIR="/mnt/b", BACKUP_OFFSITE_TARGET="rclone:b2:x", BACKUP_OFFSITE_RETENTION="5")
        s = isle_offsite.strategy(self.conf)
        self.assertEqual((s["copy_dir"], s["offsite_kind"], s["offsite_retention"], s["retention"]), ("/mnt/b", "rclone", "5", "10"))
        self.assertTrue(s["tools"]["rclone"])
        self.write(BACKUP_OFFSITE_TARGET="nope")
        self.assertTrue(isle_offsite.strategy(self.conf)["offsite_error"])


if __name__ == "__main__":
    unittest.main()
