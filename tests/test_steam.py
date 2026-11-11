#!/usr/bin/env python3
"""
tests/test_steam.py - SteamID64 -> Steam name lookups (tools/isle_steam.py, PRD PLY-01..03).
Offline: a fake Steam server (tests/fixtures/fake-steam.py) stands in for steamcommunity.com and the Web API.
    python3 -m unittest -v tests/test_steam.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "tools"))
import isle_steam  # noqa: E402

FAKE = os.path.join(REPO, "tests", "fixtures", "fake-steam.py")
REX, PAL, STEGO, NOBODY = "76561198000000001", "76561198000000002", "76561198000000003", "76561198000000099"


class SteamTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.log = tempfile.NamedTemporaryFile(delete=False).name
        cls.proc = subprocess.Popen([sys.executable, FAKE, "0"], stdout=subprocess.PIPE, env=dict(os.environ, FAKE_STEAM_LOG=cls.log),
                                    universal_newlines=True)
        cls.port = int(cls.proc.stdout.readline().split()[1])

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(10)
        cls.proc.stdout.close()
        os.unlink(cls.log)

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="isle-steam-")
        self.conf = os.path.join(self.dir, "server.conf")
        self.write()
        self.env = {"ISLE_STEAM_COMMUNITY_URL": "http://127.0.0.1:%d" % self.port, "ISLE_STEAM_API_URL": "http://127.0.0.1:%d" % self.port}
        self.saved = {k: os.environ.get(k) for k in list(self.env) + ["ISLE_STEAM_OFFLINE"]}
        os.environ.update(self.env)
        os.environ.pop("ISLE_STEAM_OFFLINE", None)
        open(self.log, "w").close()

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.dir, ignore_errors=True)

    def write(self, **values):
        with open(self.conf, "w") as handle:
            for k, v in values.items():
                handle.write("%s=%s\n" % (k, v))

    def requests(self):
        with open(self.log) as handle:
            return [l for l in handle.read().splitlines() if l]

    def cached(self, sid):
        with open(os.path.join(self.dir, ".steam-names.json"), encoding="utf-8") as handle:
            return json.load(handle)[sid]["name"]

    def names(self, ids, **kw):
        return {k: v["name"] for k, v in isle_steam.Resolver(self.conf).resolve(ids, **kw).items()}

    def test_profile_lookup_and_text_only(self):
        got = self.names([REX, PAL, STEGO, NOBODY])
        self.assertEqual(got, {REX: "RexHunter", PAL: "Ptera <Pal> & Co", STEGO: "ステゴ", NOBODY: None})

    def test_cache_is_used_and_private(self):
        self.names([REX])
        first = len(self.requests())
        self.assertEqual(self.names([REX]), {REX: "RexHunter"})
        self.assertEqual(len(self.requests()), first, "a cached name is not looked up again")
        cache = os.path.join(self.dir, ".steam-names.json")
        self.assertEqual(self.cached(REX), "RexHunter")
        if os.name == "posix":
            self.assertEqual(os.stat(cache).st_mode & 0o077, 0, "cache file is private")
        self.names([REX], refresh=True)
        self.assertGreater(len(self.requests()), first, "--refresh asks Steam again")

    def test_expired_cache_is_refreshed(self):
        cache = os.path.join(self.dir, ".steam-names.json")
        with open(cache, "w") as handle:
            json.dump({REX: {"name": "OldName", "at": time.time() - 30 * 86400}}, handle)
        self.assertEqual(self.names([REX], cached_only=True), {REX: "OldName"})
        self.assertEqual(self.names([REX]), {REX: "RexHunter"})

    def test_web_api_key(self):
        self.write(STEAM_WEB_API_KEY="test-key")
        self.assertEqual(self.names([REX, PAL, NOBODY]), {REX: "RexHunter (api)", PAL: "Ptera <Pal> & Co (api)", NOBODY: None})
        self.assertEqual(len(self.requests()), 1, "one batched Web API call")
        self.assertIn("GetPlayerSummaries", self.requests()[0])

    def test_lookup_off_and_offline(self):
        self.write(STEAM_NAME_LOOKUP="false")
        self.assertEqual(self.names([REX]), {REX: None})
        self.assertEqual(self.requests(), [])
        self.write()
        os.environ["ISLE_STEAM_OFFLINE"] = "1"
        self.assertEqual(self.names([REX]), {REX: None})
        self.assertEqual(self.requests(), [])

    def test_network_error_keeps_old_name(self):
        cache = os.path.join(self.dir, ".steam-names.json")
        with open(cache, "w") as handle:
            json.dump({REX: {"name": "OldName", "at": time.time() - 30 * 86400}}, handle)
        os.environ["ISLE_STEAM_COMMUNITY_URL"] = "http://127.0.0.1:9"   # nothing listens there
        self.assertEqual(self.names([REX]), {REX: "OldName"})
        self.assertEqual(self.cached(REX), "OldName")

    def test_invalid_ids_ignored(self):
        self.assertEqual(self.names(["123", "abc", REX]), {REX: "RexHunter"})

    def test_cli(self):
        out = subprocess.run([sys.executable, os.path.join(REPO, "tools", "isle_steam.py"), "--conf", self.conf, "names", "--json", REX, NOBODY],
                             stdout=subprocess.PIPE, universal_newlines=True, env=os.environ).stdout
        data = json.loads(out)
        self.assertEqual(data[REX]["name"], "RexHunter")
        self.assertEqual(data[REX]["profile"], "https://steamcommunity.com/profiles/" + REX)
        self.assertIsNone(data[NOBODY]["name"])
        bad = subprocess.run([sys.executable, os.path.join(REPO, "tools", "isle_steam.py"), "names", "12"], stderr=subprocess.PIPE)
        self.assertEqual(bad.returncode, 2)


if __name__ == "__main__":
    unittest.main()
