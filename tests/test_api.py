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
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = os.path.join(REPO, "tools", "isle_api.py")
FAKE = os.path.join(REPO, "tests", "fixtures", "fake-launcher.py")
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
        env = dict(os.environ, ISLE_UI_TOKEN=TOKEN, FAKE_LAUNCHER_LOG=self.log, FAKE_STATE_DIR=self.dir,
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
