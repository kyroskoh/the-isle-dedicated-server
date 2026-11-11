#!/usr/bin/env python3
"""
tests/test_api.py - REST API and web UI server (PRD API-01..05, UI-04/05).
Offline: tools/isle_api.py runs against a temporary server.conf and a fake
launcher (tests/fixtures/fake-launcher.py), so nothing is installed or started.
    python3 -m unittest -v tests/test_api.py
"""
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = os.path.join(REPO, "tools", "isle_api.py")
FAKE = os.path.join(REPO, "tests", "fixtures", "fake-launcher.py")
FAKE_STEAM = os.path.join(REPO, "tests", "fixtures", "fake-steam.py")
TOKEN = "test-token-0123456789abcdef"
ADMIN = "76561198000000001"


def slurp(path, mode="r"):
    with open(path, mode) as handle:
        return handle.read()


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class ApiServer(object):
    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="isle-api-")
        self.conf = os.path.join(self.dir, "config", "server.conf")
        os.makedirs(os.path.dirname(self.conf))
        with open(os.path.join(REPO, "config", "server.conf.example"), encoding="utf-8") as src:
            text = src.read()
        text = re.sub(r"(?m)^RCON_PASSWORD=.*$", "RCON_PASSWORD=supersecret", text)
        text = re.sub(r"(?m)^SERVER_NAME=.*$", 'SERVER_NAME="API Test"', text)
        with open(self.conf, "w", encoding="utf-8") as dst:
            dst.write(text)
        self.log = os.path.join(self.dir, "launcher.log")
        self.snaps = os.path.join(self.dir, "snapshots")
        self.port = free_port()
        self.logs = os.path.join(self.dir, "logs")
        os.makedirs(self.logs)
        with open(os.path.join(self.logs, "launcher_20261108_120000.log"), "w") as handle:
            handle.write("".join("[2026-11-08 12:00:%02d UTC] INFO line %d\n" % (i % 60, i) for i in range(300)))
        self.steam = subprocess.Popen([sys.executable, FAKE_STEAM, "0"], stdout=subprocess.PIPE, universal_newlines=True)
        steam_url = "http://127.0.0.1:%s" % self.steam.stdout.readline().split()[1]
        env = dict(os.environ, ISLE_SYSINFO_FAKE='{"cpus": 4, "mem_gb": 8, "disk_free_gb": 100, "arch": "x86_64"}', ISLE_STEAM_COMMUNITY_URL=steam_url, ISLE_STEAM_API_URL=steam_url, ISLE_UI_TOKEN=TOKEN, ISLE_LOG_DIR=self.logs, FAKE_LAUNCHER_LOG=self.log, FAKE_STATE_DIR=self.dir,
                   FAKE_DELAY="0.4", PYTHONUNBUFFERED="1")
        self.out = open(os.path.join(self.dir, "api.log"), "w")
        self.proc = subprocess.Popen([sys.executable, API, "--conf", self.conf, "--launcher", FAKE, "--port", str(self.port),
                                      "--snapshot-dir", self.snaps], stdout=self.out, stderr=subprocess.STDOUT, env=env)
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", self.port), 0.2).close()
                return
            except OSError:
                time.sleep(0.1)
        raise RuntimeError("API did not start: %s" % slurp(os.path.join(self.dir, "api.log")))

    def stop(self):
        self.steam.terminate()
        self.steam.wait(10)
        self.steam.stdout.close()
        self.proc.terminate()
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.out.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def call(self, method, path, body=None, token=TOKEN, headers=None, raw=None):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (self.port, path), data=data, method=method)
        if token:
            req.add_header("Authorization", "Bearer " + token)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        try:
            resp = urllib.request.urlopen(req, timeout=20)
        except urllib.error.HTTPError as err:
            resp = err
        payload = resp.read()
        ctype = resp.headers.get("Content-Type", "")
        parsed = json.loads(payload) if payload and "json" in ctype else payload
        return resp.status, parsed, resp.headers

    def calls(self):
        if not os.path.isfile(self.log):
            return []
        return [json.loads(l) for l in slurp(self.log).splitlines()]

    def wait_job(self, job_id):
        for _ in range(100):
            _, job, _ = self.call("GET", "/api/v1/jobs/" + job_id)
            if job["state"] != "running":
                return job
            time.sleep(0.1)
        raise AssertionError("job %s did not finish" % job_id)


class ApiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = ApiServer()

    @classmethod
    def tearDownClass(cls):
        cls.s.stop()

    def conf(self, key):
        val = None
        for line in slurp(self.s.conf).splitlines(True):
            if line.startswith(key + "="):
                val = line.rstrip("\n").split("=", 1)[1]
        return val

    # ---------------------------------------------------------------- security
    def test_health_needs_no_token(self):
        code, body, _ = self.s.call("GET", "/api/v1/health", token=None)
        self.assertEqual(code, 200)
        self.assertEqual(body["status"], "ok")

    def test_token_required(self):
        code, body, headers = self.s.call("GET", "/api/v1/config", token=None)
        self.assertEqual(code, 401)
        self.assertIn("application/problem+json", headers["Content-Type"])
        self.assertEqual(body["status"], 401)
        self.assertIn("Bearer", headers["WWW-Authenticate"])
        self.assertEqual(self.s.call("GET", "/api/v1/config", token="wrong-token-xxxxxxxx")[0], 401)

    def test_security_headers(self):
        for path in ("/", "/docs", "/api/v1/health"):
            code, _, h = self.s.call("GET", path, token=None)
            self.assertEqual(code, 200, path)
            self.assertEqual(h["X-Content-Type-Options"], "nosniff")
            self.assertEqual(h["X-Frame-Options"], "DENY")
            self.assertEqual(h["Referrer-Policy"], "no-referrer")
            self.assertTrue(h["X-Request-ID"])
        _, _, h = self.s.call("GET", "/", token=None)
        self.assertIn("default-src 'self'", h["Content-Security-Policy"])
        self.assertIn("frame-ancestors 'none'", h["Content-Security-Policy"])
        self.assertNotIn("Access-Control-Allow-Origin", h)
        self.assertNotIn("Set-Cookie", h)

    def test_request_id_echoed(self):
        _, body, h = self.s.call("GET", "/api/v1/nope", headers={"X-Request-ID": "abc-123"})
        self.assertEqual(h["X-Request-ID"], "abc-123")
        self.assertEqual(body["request_id"], "abc-123")
        self.assertEqual(body["status"], 404)

    def test_static_traversal_blocked(self):
        for path in ("/assets/../tools/isle_api.py", "/assets/%2e%2e/config/server.conf", "/assets/..%2fVERSION"):
            code, _, _ = self.s.call("GET", path, token=None)
            self.assertEqual(code, 404, path)

    def test_body_limits(self):
        code, body, _ = self.s.call("POST", "/api/v1/admins", raw=b"x" * (70 * 1024))
        self.assertEqual(code, 413)
        code, _, _ = self.s.call("POST", "/api/v1/admins", raw=b"{not json")
        self.assertEqual(code, 400)
        req_code, _, _ = self.s.call("POST", "/api/v1/admins", raw=b"ids=1", headers={"Content-Type": "text/plain"})
        self.assertEqual(req_code, 415)

    def test_method_not_allowed(self):
        code, body, _ = self.s.call("DELETE", "/api/v1/config")
        self.assertEqual(code, 405)
        self.assertIn("GET", body["detail"])

    # ----------------------------------------------------------------- OpenAPI
    def test_openapi_matches_routes(self):
        code, spec, _ = self.s.call("GET", "/openapi.json", token=None)
        self.assertEqual(code, 200)
        self.assertEqual(spec["openapi"], "3.1.0")
        sys.path.insert(0, os.path.join(REPO, "tools"))
        import isle_api
        routes = {(r["method"].lower(), r["pattern"]) for r in isle_api.ROUTES}
        documented = {(m, p) for p, ops in spec["paths"].items() for m in ops}
        self.assertEqual(routes, documented)
        ids = [op["operationId"] for ops in spec["paths"].values() for op in ops.values()]
        self.assertEqual(len(ids), len(set(ids)), "operationIds must be unique")
        for p, ops in spec["paths"].items():
            for m, op in ops.items():
                self.assertIn("default", op["responses"], "%s %s" % (m, p))
                for ref in re.findall(r'"\$ref": "#/components/schemas/(\w+)"', json.dumps(op)):
                    self.assertIn(ref, spec["components"]["schemas"])
        self.assertEqual(spec["paths"]["/api/v1/health"]["get"]["security"], [])

    def test_docs_page(self):
        code, html, h = self.s.call("GET", "/docs", token=None)
        self.assertEqual(code, 200)
        self.assertIn(b"/assets/docs.js", html)
        self.assertIn(b"/openapi.json", slurp(os.path.join(REPO, "ui", "docs.js"), "rb"))

    # ------------------------------------------------------------------ config
    def test_config_masks_secrets(self):
        code, body, _ = self.s.call("GET", "/api/v1/config")
        self.assertEqual(code, 200)
        items = {s["key"]: s for s in body["settings"]}
        self.assertEqual(items["RCON_PASSWORD"]["value"], "********")
        self.assertTrue(items["RCON_PASSWORD"]["secret"])
        self.assertFalse(items["SERVER_DIR"]["editable"])
        self.assertEqual(items["SERVER_NAME"]["value"], "API Test")
        self.assertNotIn(b"supersecret", json.dumps(body).encode())

    def test_config_patch(self):
        code, body, _ = self.s.call("PATCH", "/api/v1/config", {"values": {"MAX_PLAYERS": "77", "SERVER_NAME": "Big Swamp",
                                                                         "RCON_PASSWORD": "********"}})
        self.assertEqual(code, 200, body)
        self.assertEqual(body["changed"], ["MAX_PLAYERS", "SERVER_NAME"])
        self.assertEqual(self.conf("MAX_PLAYERS"), "77")
        self.assertEqual(self.conf("SERVER_NAME"), '"Big Swamp"')
        self.assertEqual(self.conf("RCON_PASSWORD"), "supersecret", "a masked secret is not written back")

    def test_config_patch_rolls_back(self):
        before = slurp(self.s.conf, "rb")
        code, body, _ = self.s.call("PATCH", "/api/v1/config", {"values": {"MAX_PLAYERS": "lots"}})
        self.assertEqual(code, 422)
        self.assertIn("MAX_PLAYERS", body["detail"])
        self.assertEqual(slurp(self.s.conf, "rb"), before)

    def test_config_patch_rejects(self):
        self.assertEqual(self.s.call("PATCH", "/api/v1/config", {"values": {"SERVER_DIR": "/tmp/x"}})[0], 403)
        self.assertEqual(self.s.call("PATCH", "/api/v1/config", {"values": {"RUNTIME": "docker"}})[0], 403)
        self.assertEqual(self.s.call("PATCH", "/api/v1/config", {"values": {"NOPE_KEY": "1"}})[0], 422)
        self.assertEqual(self.s.call("PATCH", "/api/v1/config", {"values": {"SERVER_NAME": "a\nRUNTIME=docker"}})[0], 422)
        self.assertEqual(self.s.call("PATCH", "/api/v1/config", {"values": {"MAX_PLAYERS": 5}})[0], 422)
        self.assertEqual(self.s.call("PATCH", "/api/v1/config", {"values": {}})[0], 422)
        self.assertEqual(self.s.call("PATCH", "/api/v1/config", {})[0], 422)

    def test_config_check(self):
        code, body, _ = self.s.call("GET", "/api/v1/config/check")
        self.assertEqual(code, 200)
        self.assertTrue(body["ok"])

    # ----------------------------------------------------------------- players
    def test_admins(self):
        code, body, _ = self.s.call("POST", "/api/v1/admins", {"ids": [ADMIN]})
        self.assertEqual(code, 200, body)
        self.assertIn(ADMIN, self.s.call("GET", "/api/v1/admins")[1]["ids"])
        self.assertIn(["admins", "add", ADMIN], self.s.calls())
        self.assertEqual(self.s.call("DELETE", "/api/v1/admins/" + ADMIN)[0], 200)
        self.assertNotIn(ADMIN, self.s.call("GET", "/api/v1/admins")[1]["ids"])

    def test_admins_validation(self):
        for bad in (["123"], ["76561198000000001; rm -rf /"], [], "76561198000000001", [5]):
            code, body, _ = self.s.call("POST", "/api/v1/admins", {"ids": bad})
            self.assertEqual(code, 422, bad)
        self.assertEqual(self.s.call("DELETE", "/api/v1/admins/notanid")[0], 422)
        self.assertFalse(any("rm -rf /" in " ".join(c) for c in self.s.calls()))

    def test_whitelist(self):
        self.assertEqual(self.s.call("POST", "/api/v1/whitelist", {"ids": [ADMIN]})[0], 200)
        self.assertEqual(self.s.call("PUT", "/api/v1/whitelist/enabled", {"enabled": True})[0], 200)
        body = self.s.call("GET", "/api/v1/whitelist")[1]
        self.assertTrue(body["enabled"])
        self.assertIn(ADMIN, body["ids"])
        self.assertEqual(self.s.call("PUT", "/api/v1/whitelist/enabled", {"enabled": "yes"})[0], 422)
        self.assertEqual(self.s.call("PUT", "/api/v1/whitelist/enabled", {"enabled": False})[0], 200)

    def test_roster(self):
        code, body, _ = self.s.call("PUT", "/api/v1/classes", {"classes": ["Tyrannosaurus", "Pteranodon"]})
        self.assertEqual(code, 200, body)
        got = self.s.call("GET", "/api/v1/classes")[1]
        self.assertEqual(got["classes"], ["Tyrannosaurus", "Pteranodon"])
        self.assertTrue(any(k["name"] == "Tyrannosaurus" for k in got["known"]))
        self.assertEqual(self.s.call("PUT", "/api/v1/classes", {"classes": []})[0], 200)
        self.assertIn(["classes", "reset"], self.s.calls())
        self.assertEqual(self.s.call("PUT", "/api/v1/classes", {"classes": ["Rex;reboot"]})[0], 422)
        rosters = self.s.call("GET", "/api/v1/rosters")[1]
        self.assertTrue(rosters)
        self.assertEqual(self.s.call("POST", "/api/v1/classes/preset", {"name": rosters[0]["name"]})[0], 200)
        self.assertEqual(self.s.call("POST", "/api/v1/classes/preset", {"name": "../../etc/passwd"})[0], 404)
        self.assertEqual(self.s.call("PUT", "/api/v1/ai-classes", {"classes": ["Compsognathus"]})[0], 200)

    def test_profiles_presets(self):
        profiles = self.s.call("GET", "/api/v1/profiles")[1]
        self.assertTrue(profiles and profiles[0]["settings"])
        self.assertEqual(self.s.call("POST", "/api/v1/profiles/%s/apply" % profiles[0]["name"])[0], 200)
        self.assertEqual(self.s.call("POST", "/api/v1/profiles/nope/apply")[0], 404)
        presets = self.s.call("GET", "/api/v1/presets")[1]
        self.assertTrue(presets)
        self.assertEqual(self.s.call("POST", "/api/v1/presets/apply", {"names": [presets[0]["name"]]})[0], 200)
        self.assertEqual(self.s.call("POST", "/api/v1/presets/apply", {"names": ["nope"]})[0], 404)

    def test_plugins(self):
        code, body, _ = self.s.call("GET", "/api/v1/plugins")
        self.assertEqual(code, 200)
        self.assertTrue(any(p["name"] == "offsite-backup" for p in body["plugins"]))
        self.assertTrue(body["presets"])
        self.assertEqual(self.s.call("POST", "/api/v1/plugins/offsite-backup/install")[0], 200)
        self.assertIn(["plugins", "install", "offsite-backup"], self.s.calls())
        self.assertEqual(self.s.call("POST", "/api/v1/plugins/offsite-backup/explode")[0], 404)
        preset = sorted(body["presets"])[0]
        self.assertEqual(self.s.call("POST", "/api/v1/plugins/presets/%s" % preset)[0], 200)
        self.assertIn(["plugins", "preset", preset], self.s.calls())
        self.assertEqual(self.s.call("PATCH", "/api/v1/plugins/offsite-backup/config", {"settings": {"DEST_DIR": "/x"}})[0], 200)
        self.assertEqual(self.s.call("PATCH", "/api/v1/plugins/offsite-backup/config", {"settings": {"bad key": "1"}})[0], 422)
        self.assertEqual(self.s.call("GET", "/api/v1/plugins/not-installed")[0], 404)

    # -------------------------------------------------------------- lifecycle
    def test_jobs_and_conflict(self):
        code, job, h = self.s.call("POST", "/api/v1/server/start")
        self.assertEqual(code, 202)
        self.assertEqual(h["Location"], "/api/v1/jobs/" + job["id"])
        code, body, _ = self.s.call("POST", "/api/v1/server/stop")
        self.assertEqual(code, 409, "a second lifecycle action must wait")
        self.assertEqual(body["running_job"], job["id"])
        done = self.s.wait_job(job["id"])
        self.assertEqual(done["state"], "succeeded")
        self.assertIn("start done", done["output"])
        self.assertTrue(self.s.call("GET", "/api/v1/status")[1]["running"])
        stop = self.s.call("POST", "/api/v1/server/stop")[1]
        self.assertEqual(self.s.wait_job(stop["id"])["state"], "succeeded")
        self.assertFalse(self.s.call("GET", "/api/v1/status")[1]["running"])
        self.assertTrue(any(j["id"] == stop["id"] for j in self.s.call("GET", "/api/v1/jobs")[1]))
        self.assertEqual(self.s.call("POST", "/api/v1/server/format-disk")[0], 404)
        self.assertEqual(self.s.call("GET", "/api/v1/jobs/doesnotexist")[0], 404)

    def test_info_and_logs(self):
        info = self.s.call("GET", "/api/v1/info")[1]
        self.assertEqual(info.get("Runtime"), "native")
        logs = self.s.call("GET", "/api/v1/logs?lines=5")[1]
        self.assertEqual(logs["lines"], ["log line %d" % i for i in range(295, 300)])
        self.assertEqual(self.s.call("GET", "/api/v1/logs?lines=many")[0], 422)

    def test_status_reports_timezone(self):
        body = self.s.call("GET", "/api/v1/status")[1]
        self.assertIn(body["timezone"], ("local", "utc"))
        self.assertIsInstance(body["utc_offset_minutes"], int)
        self.assertTrue(body["zone"].startswith("UTC"))

    def test_log_files(self):
        code, items, _ = self.s.call("GET", "/api/v1/log-files")
        self.assertEqual(code, 200)
        names = [i["name"] for i in items]
        self.assertIn("launcher_20261108_120000.log", names)
        self.assertTrue(any(re.match(r"^ui_\d{8}_\d{6}(_\d+)?\.log$", n) for n in names), "the API writes its own access log")
        body = self.s.call("GET", "/api/v1/log-files/launcher_20261108_120000.log?lines=3")[1]
        self.assertEqual(body["lines"], ["[2026-11-08 12:00:%02d UTC] INFO line %d" % (i % 60, i) for i in (297, 298, 299)])
        for bad in ("..%2fserver.conf", "launcher.log", "launcher_20261108_120000.txt", "nope_20990101_000000.log"):
            self.assertEqual(self.s.call("GET", "/api/v1/log-files/" + bad)[0], 404, bad)
        self.assertEqual(self.s.call("GET", "/api/v1/log-files/launcher_20261108_120000.log?lines=x")[0], 422)

    def test_snapshot_name_has_stamp_suffix(self):
        code, job, _ = self.s.call("POST", "/api/v1/snapshots", {"include": ["worlds"]})
        self.assertEqual(code, 202)
        self.s.wait_job(job["id"])
        names = [x["name"] for x in self.s.call("GET", "/api/v1/snapshots")[1]]
        self.assertTrue(any(re.match(r"^theisle-snapshot_\d{8}_\d{6}\.tar\.gz$", n) for n in names), names)
        for n in names:
            self.s.call("DELETE", "/api/v1/snapshots/" + n)

    def test_maps(self):
        body = self.s.call("GET", "/api/v1/maps")[1]
        names = [m["name"] for m in body["maps"]]
        self.assertIn("Gateway", names)
        self.assertIn("Isla_Spiro", names)
        self.assertEqual([m["name"] for m in body["maps"] if m["current"]], [body["current"]])
        code, out, _ = self.s.call("PUT", "/api/v1/map", {"name": "Isla_Spiro"})
        self.assertEqual(code, 200, out)
        self.assertEqual(self.conf("MAP_NAME"), "Isla_Spiro")
        self.assertEqual(self.conf("STEAM_BRANCH"), "spiro0.11.59.04")
        self.assertEqual(self.s.call("PUT", "/api/v1/map", {"name": "gateway"})[0], 404, "names are case-sensitive")
        self.assertEqual(self.s.call("PUT", "/api/v1/map", {"name": "Gateway; rm -rf /"})[0], 404)
        self.assertEqual(self.s.call("PUT", "/api/v1/map", {})[0], 422)
        self.assertEqual(self.s.call("PUT", "/api/v1/map", {"name": "Gateway", "keep_branch": True})[0], 200)
        self.assertEqual(self.conf("STEAM_BRANCH"), "spiro0.11.59.04", "keep_branch leaves the branch alone")
        self.s.call("PUT", "/api/v1/map", {"name": "Gateway"})
        self.assertEqual(self.conf("STEAM_BRANCH"), "evrima")

    def test_ai(self):
        body = self.s.call("GET", "/api/v1/ai")[1]
        self.assertIn(body["spawn"], (True, False))
        self.assertEqual(body["interval"], 40)
        self.assertTrue(any(k["name"] == "Compsognathus" and k["diet"] == "carnivore" for k in body["known"]))
        self.assertTrue(any(p["name"] == "ai-prey-only" for p in body["presets"]))
        self.assertTrue(all(p["name"].startswith("ai-") for p in body["presets"]))
        code, out, _ = self.s.call("PATCH", "/api/v1/ai", {"spawn": False, "density": 0.5, "interval": 25})
        self.assertEqual(code, 200, out)
        self.assertEqual((self.conf("SPAWN_AI"), self.conf("AI_DENSITY"), self.conf("AI_SPAWN_INTERVAL")), ("false", "0.5", "25"))
        for bad in ({"density": "lots"}, {"density": -1}, {"interval": 0}, {"interval": 2.5}, {"spawn": "yes"}, {"colour": "red"}, {}):
            self.assertEqual(self.s.call("PATCH", "/api/v1/ai", bad)[0], 422, bad)
        self.assertEqual(self.s.call("POST", "/api/v1/ai/preset", {"name": "ai-prey-only"})[0], 200)
        self.assertEqual(self.conf("DISABLED_AI_CLASSES"), "Compsognathus,Pterodactylus")
        self.assertEqual(self.s.call("POST", "/api/v1/ai/preset", {"name": "casual"})[0], 404, "only ai-* presets")
        self.s.call("PATCH", "/api/v1/ai", {"spawn": True, "density": 1, "interval": 40})

    def test_plugin_sources_and_community(self):
        self.assertEqual(self.s.call("GET", "/api/v1/plugins/sources")[1], {"sources": []})
        url = "https://example.org/isle/catalog.json"
        self.assertEqual(self.s.call("POST", "/api/v1/plugins/sources", {"url": url})[0], 200)
        self.assertEqual(self.s.call("GET", "/api/v1/plugins/sources")[1]["sources"], [url])
        for bad in ("http://example.org/c.json", "file:///etc/passwd", "https://a b", "ftp://x"):
            self.assertEqual(self.s.call("POST", "/api/v1/plugins/sources", {"url": bad})[0], 422, bad)
        self.assertEqual(self.s.call("DELETE", "/api/v1/plugins/sources?url=https%3A%2F%2Fnope.example%2Fx.json")[0], 404)
        self.assertEqual(self.s.call("DELETE", "/api/v1/plugins/sources?url=" + urllib.parse.quote(url, safe=""))[0], 200)
        self.assertEqual(self.s.call("GET", "/api/v1/plugins/sources")[1]["sources"], [])
        community = self.s.call("GET", "/api/v1/plugins/community")[1]
        self.assertTrue(community["links"])
        for link in community["links"]:
            self.assertTrue(link["url"].startswith("https://"), link)
            self.assertTrue(link["name"] and link["description"], link)
        self.assertIn("mods", community)

    def test_backups(self):
        code, body, _ = self.s.call("GET", "/api/v1/backups")
        self.assertEqual(code, 200, body)
        self.assertEqual(body["schedule"], "0 5 * * *")
        self.assertFalse(body["rule321"]["ok"])
        code, out, _ = self.s.call("PUT", "/api/v1/backups/schedule", {"schedule": "30 */6 * * 1-5"})
        self.assertEqual(code, 200, out)
        self.assertEqual(self.conf("BACKUP_SCHEDULE"), '"30 */6 * * 1-5"')
        self.assertEqual(self.s.call("PUT", "/api/v1/backups/schedule", {"schedule": "off"})[0], 200)
        self.assertEqual(self.conf("BACKUP_SCHEDULE"), "off")
        self.assertEqual(self.s.calls()[-1], ["backup", "schedule", "off"])
        for bad in ("61 * * * *", "* * *", "0 5 * * 8", "@sometimes", "0 5 * * *; rm -rf /", ""):
            self.assertEqual(self.s.call("PUT", "/api/v1/backups/schedule", {"schedule": bad})[0], 422, bad)
        self.s.call("PUT", "/api/v1/backups/schedule", {"schedule": "0 5 * * *"})

    def test_system_and_recommendations(self):
        r = self.s.call("GET", "/api/v1/system")[1]
        self.assertEqual((r["machine"]["cpus"], r["machine"]["mem_total_gb"], r["players"], r["tier"]), (4, 8, 65, "medium"))
        keys = {x["key"]: x for x in r["recommendations"]}
        self.assertEqual(keys["MAX_PLAYERS"]["value"], "65")
        self.assertTrue(all(x["reason"] for x in r["recommendations"]))
        old = self.conf("MAX_PLAYERS")
        code, out, _ = self.s.call("POST", "/api/v1/recommendations/apply", {"keys": ["MAX_PLAYERS", "NET_TICK_RATE"]})
        self.assertEqual(code, 200, out)
        self.assertEqual(sorted(out["changed"]), ["MAX_PLAYERS", "NET_TICK_RATE"])
        self.assertEqual((self.conf("MAX_PLAYERS"), self.conf("NET_TICK_RATE")), ("65", "30"))
        for bad in ({"keys": ["RCON_PASSWORD"]}, {"keys": "MAX_PLAYERS"}, {"keys": [1]}):
            self.assertEqual(self.s.call("POST", "/api/v1/recommendations/apply", bad)[0], 422, bad)
        self.s.call("PATCH", "/api/v1/config", {"values": {"MAX_PLAYERS": old, "NET_TICK_RATE": ""}})

    def test_setup_state(self):
        marker = os.path.join(os.path.dirname(self.s.conf), ".setup-done")
        if os.path.exists(marker):
            os.remove(marker)
        self.assertEqual(self.s.call("GET", "/api/v1/setup")[1], {"done": False, "at": None})
        with open(self.s.conf) as handle:
            original = handle.read()
        with open(self.s.conf, "w") as handle:
            handle.write(re.sub(r"(?m)^MAX_PLAYERS=.*$", "MAX_PLAYERS=lots", original))
        self.assertEqual(self.s.call("POST", "/api/v1/setup/complete")[0], 422, "a failing check blocks it")
        self.assertFalse(self.s.call("GET", "/api/v1/setup")[1]["done"])
        with open(self.s.conf, "w") as handle:
            handle.write(original)
        code, body, _ = self.s.call("POST", "/api/v1/setup/complete")
        self.assertEqual(code, 200, body)
        self.assertTrue(body["done"] and body["at"])
        self.assertTrue(self.s.call("GET", "/api/v1/setup")[1]["done"])

    def test_backup_strategy(self):
        s = self.s.call("GET", "/api/v1/backups/strategy")[1]
        self.assertEqual((s["copy_dir"], s["offsite_target"]), ("", ""))
        self.assertIn("rclone", s["tools"])
        copy = os.path.join(self.s.dir, "copy2")
        code, out, _ = self.s.call("PUT", "/api/v1/backups/strategy", {"copy_dir": copy, "copy_retention": "3",
                                                                        "offsite_target": "dir:" + os.path.join(self.s.dir, "nas"), "offsite_retention": ""})
        self.assertEqual(code, 200, out)
        self.assertEqual((self.conf("BACKUP_COPY_DIR"), self.conf("BACKUP_COPY_RETENTION")), (copy, "3"))
        self.assertTrue(self.conf("BACKUP_OFFSITE_TARGET").startswith("dir:"))
        t = self.s.call("POST", "/api/v1/backups/strategy/test")[1]
        self.assertTrue(t["ok"], t)
        self.assertTrue(os.path.isdir(copy), "the test creates the folder")
        for bad in ({"offsite_target": "rclone copy {file} remote:x"}, {"offsite_target": "ssh://h/p;rm -rf /"}, {"offsite_target": "dir:../x"},
                    {"copy_dir": "relative"}, {"copy_retention": "lots"}, {"retention": ""}, {"offsite_command": "rm -rf /"}, {}):
            self.assertEqual(self.s.call("PUT", "/api/v1/backups/strategy", bad)[0], 422, bad)
        locked = [k for k in self.s.call("GET", "/api/v1/config")[1]["settings"] if k["key"] in ("BACKUP_OFFSITE_TARGET", "BACKUP_OFFSITE_COMMAND")]
        self.assertTrue(locked and all(not k["editable"] for k in locked), "only the validated strategy endpoint sets these")
        self.assertEqual(self.s.call("PUT", "/api/v1/backups/strategy", {"copy_dir": "", "offsite_target": ""})[0], 200)
        self.assertEqual((self.conf("BACKUP_COPY_DIR"), self.conf("BACKUP_OFFSITE_TARGET")), ("", ""))

    def test_cron_preview(self):
        code, body, _ = self.s.call("GET", "/api/v1/cron/preview?expr=" + urllib.parse.quote("15 3 * * SUN"))
        self.assertEqual(code, 200, body)
        self.assertEqual(len(body["next"]), 5)
        for t in body["next"]:
            self.assertTrue(t.endswith("T03:15:00"), t)
        self.assertTrue(body["describe"])
        self.assertEqual(self.s.call("GET", "/api/v1/cron/preview?expr=nope")[0], 422)
        self.assertEqual(self.s.call("GET", "/api/v1/cron/preview?expr=off")[1]["next"], [])

    def test_mutations(self):
        body = self.s.call("GET", "/api/v1/mutations")[1]
        self.assertEqual(body["mode"], "all")
        self.assertGreater(len(body["mutations"]), 30)
        self.assertTrue(all(m["enabled"] for m in body["mutations"]))
        fixed = [m["name"] for m in body["mutations"] if m["fixed"]]
        free = [m["name"] for m in body["mutations"] if not m["fixed"]]
        self.assertTrue(fixed and free)
        code, out, _ = self.s.call("PUT", "/api/v1/mutations", {"mode": "custom", "mutations": {free[1]: "1.5", free[0]: "2"}})
        self.assertEqual(code, 200, out)
        self.assertEqual(self.conf("ENABLED_MUTATIONS"), "%s:2;%s:1.5" % (free[0], free[1]), "catalog order")
        body = self.s.call("GET", "/api/v1/mutations")[1]
        self.assertEqual(body["mode"], "custom")
        self.assertEqual([m["name"] for m in body["mutations"] if m["enabled"]], free[:2])
        for bad in ({"mode": "custom", "mutations": {fixed[0]: "2"}}, {"mode": "custom", "mutations": {"Wings": "1"}},
                    {"mode": "custom", "mutations": {free[0]: "lots"}}, {"mode": "custom", "mutations": {}}, {"mode": "some"}):
            self.assertEqual(self.s.call("PUT", "/api/v1/mutations", bad)[0], 422, bad)
        self.assertEqual(self.s.call("PUT", "/api/v1/mutations", {"mode": "all"})[0], 200)
        self.assertEqual(self.conf("ENABLED_MUTATIONS"), "")

    def test_admin_commands(self):
        code, out, _ = self.s.call("POST", "/api/v1/admin/players", {})
        self.assertEqual(code, 200, out)
        self.assertIn("Rex", out["output"])
        self.assertEqual(self.s.call("POST", "/api/v1/admin/kick", {"steam_id": ADMIN, "text": "spam"})[0], 200)
        self.assertEqual(self.s.calls()[-1], ["admin", "kick", ADMIN, "spam"])
        self.assertEqual(self.s.call("POST", "/api/v1/admin/growth", {"value": "1.5"})[0], 200)
        self.assertEqual(self.s.calls()[-1], ["admin", "growth", "1.5"])
        self.assertEqual(self.s.call("POST", "/api/v1/admin/pause", {"value": "ON"})[0], 200)
        self.assertEqual(self.s.calls()[-1], ["admin", "pause", "on"])
        for path, bad in (("kick", {"steam_id": "123"}), ("dm", {"steam_id": ADMIN}), ("announce", {"text": " "}),
                          ("announce", {"text": "a\nb"}), ("announce", {"text": "x" * 501}), ("pause", {"value": "maybe"}),
                          ("growth", {"value": "fast"}), ("player", {"steam_id": "abc"})):
            self.assertEqual(self.s.call("POST", "/api/v1/admin/" + path, bad)[0], 422, (path, bad))
        self.assertEqual(self.s.call("POST", "/api/v1/admin/godmode", {})[0], 404)
        self.assertIn(["admin", "players"], self.s.calls())

    def test_roster_types_and_humans(self):
        known = self.s.call("GET", "/api/v1/classes")[1]["known"]
        rex = [k for k in known if k["name"] == "Tyrannosaurus"][0]
        self.assertIn("carnivore", rex["types"])
        self.assertEqual(self.s.call("POST", "/api/v1/classes/select", {"types": ["Carnivore"]})[0], 200)
        self.assertEqual(self.s.calls()[-1], ["classes", "select", "carnivore"])
        self.assertEqual(self.s.call("POST", "/api/v1/classes/select", {"types": ["flying"], "mode": "remove"})[0], 200)
        self.assertEqual(self.s.calls()[-1], ["classes", "remove-type", "flying"])
        for bad in ({"types": ["egg"]}, {"types": ["human"]}, {"types": []}, {"types": ["aquatic"], "mode": "toggle"}):
            self.assertEqual(self.s.call("POST", "/api/v1/classes/select", bad)[0], 422, bad)
        self.assertEqual(self.s.call("PUT", "/api/v1/humans", {"enabled": False})[0], 200)
        self.assertEqual(self.conf("ENABLE_HUMANS"), "false")
        self.assertEqual(self.s.call("PUT", "/api/v1/humans", {"enabled": "no"})[0], 422)
        self.s.call("PUT", "/api/v1/humans", {"enabled": True})
        self.s.call("PUT", "/api/v1/classes", {"classes": []})

    def test_steam_names(self):
        rex, nobody = "76561198000000001", "76561198000000099"
        code, body, _ = self.s.call("GET", "/api/v1/steam/names?ids=%s,%s" % (rex, nobody))
        self.assertEqual(code, 200, body)
        self.assertTrue(body["lookup"])
        self.assertEqual([(p["steam_id"], p["name"]) for p in body["players"]], [(rex, "RexHunter"), (nobody, None)])
        self.assertEqual(body["players"][0]["profile"], "https://steamcommunity.com/profiles/" + rex)
        # lists carry cached names without asking Steam
        self.s.call("POST", "/api/v1/whitelist", {"ids": [rex, nobody]})
        wl = self.s.call("GET", "/api/v1/whitelist")[1]
        self.assertEqual({p["steam_id"]: p["name"] for p in wl["players"]}, {rex: "RexHunter", nobody: None})
        for bad in ("", "?ids=123", "?ids=" + ",".join([rex] * 101), "?ids=%s;rm" % rex):
            self.assertEqual(self.s.call("GET", "/api/v1/steam/names" + bad)[0], 422, bad)
        self.s.call("DELETE", "/api/v1/whitelist/" + rex)
        self.s.call("DELETE", "/api/v1/whitelist/" + nobody)
        key = [k for k in self.s.call("GET", "/api/v1/config")[1]["settings"] if k["key"] == "STEAM_WEB_API_KEY"]
        self.assertEqual(len(key), 1)
        self.assertTrue(key[0]["secret"], "the Web API key is masked like a password")

    def test_rcon_validation(self):
        self.assertEqual(self.s.call("POST", "/api/v1/rcon", {"command": "rm -rf"})[0], 422)
        code, body, _ = self.s.call("POST", "/api/v1/rcon", {"command": "announce", "args": ["hi"]})
        self.assertEqual(code, 502, body)  # nothing listens on the RCON port

    def test_snapshots(self):
        code, job, _ = self.s.call("POST", "/api/v1/snapshots", {"include": ["worlds"]})
        self.assertEqual(code, 202, job)
        self.assertEqual(self.s.wait_job(job["id"])["state"], "succeeded")
        snaps = self.s.call("GET", "/api/v1/snapshots")[1]
        self.assertEqual(len(snaps), 1)
        self.assertEqual(snaps[0]["parts"], ["worlds"])
        name = snaps[0]["name"]
        code, job, _ = self.s.call("POST", "/api/v1/snapshots/%s/restore" % name, {"overwrite": True})
        self.assertEqual(code, 202)
        self.s.wait_job(job["id"])
        self.assertTrue(any(c[:2] == ["snapshot", "restore"] and "--overwrite" in c for c in self.s.calls()))
        self.assertEqual(self.s.call("POST", "/api/v1/snapshots", {"include": ["passwords"]})[0], 422)
        self.assertEqual(self.s.call("POST", "/api/v1/snapshots/..%2fserver.conf/restore")[0], 404)
        self.assertEqual(self.s.call("DELETE", "/api/v1/snapshots/" + name)[0], 204)
        self.assertEqual(self.s.call("GET", "/api/v1/snapshots")[1], [])

    # last: locks this client out
    def test_zz_lockout(self):
        for _ in range(10):
            self.s.call("GET", "/api/v1/status", token="bad-token-xxxxxxxxxx")
        code, body, h = self.s.call("GET", "/api/v1/status")
        self.assertEqual(code, 429, "even the right token is refused during the lockout")
        self.assertEqual(h["Retry-After"], "60")
        self.assertEqual(self.s.call("GET", "/api/v1/health", token=None)[0], 200)


class TokenTest(unittest.TestCase):
    def test_token_file_created_private(self):
        d = tempfile.mkdtemp(prefix="isle-tok-")
        try:
            conf = os.path.join(d, "server.conf")
            open(conf, "w").close()
            env = dict(os.environ)
            env.pop("ISLE_UI_TOKEN", None)
            out = subprocess.check_output([sys.executable, API, "--conf", conf, "--print-token"], env=env).decode().strip()
            path = os.path.join(d, "ui-token")
            self.assertEqual(slurp(path).strip(), out)
            self.assertGreaterEqual(len(out), 32)
            if os.name == "posix":
                self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            again = subprocess.check_output([sys.executable, API, "--conf", conf, "--print-token"], env=env).decode().strip()
            self.assertEqual(again, out)
            rotated = subprocess.check_output([sys.executable, API, "--conf", conf, "--rotate-token"], env=env).decode().strip()
            self.assertNotEqual(rotated, out)
        finally:
            shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
