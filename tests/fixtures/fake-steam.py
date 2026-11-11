#!/usr/bin/env python3
"""
Stand-in for steamcommunity.com and api.steampowered.com in the tests.
    fake-steam.py PORT        (prints "ready" once listening; every request is appended to $FAKE_STEAM_LOG)
  /profiles/<id>/?xml=1                       -> profile XML with <steamID> (unknown ids: the "not found" error XML)
  /ISteamUser/GetPlayerSummaries/v2/?key=K&steamids=a,b  -> JSON (key must be "test-key", else 403)
"""
import json
import os
import re
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

NAMES = {
    "76561198000000001": "RexHunter",
    "76561198000000002": "Ptera <Pal> & Co",          # markup in a name stays text
    "76561198000000003": "ステゴ",                      # non-ASCII
    "76561198000000042": "NewAdmin",
    # the documentation screenshots (tests/ui_screenshots.mjs)
    "76561198012345678": "Gondwa Warden",
    "76561198087654321": "NightRaptor",
    "76561198011112222": "RexHunter",
    "76561198033334444": "Ptera_Pal",
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, body, ctype):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if os.environ.get("FAKE_STEAM_LOG"):
            with open(os.environ["FAKE_STEAM_LOG"], "a") as log:
                log.write(url.path + "?" + url.query + "\n")
        m = re.match(r"^/profiles/(\d{17})/?$", url.path)
        if m:
            name = NAMES.get(m.group(1))
            if not name:
                return self._send(200, "<?xml version=\"1.0\"?><response><error><![CDATA[The specified profile could not be found.]]></error></response>", "text/xml")
            return self._send(200, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<profile>\n<steamID64>%s</steamID64>\n"
                                   "<steamID><![CDATA[%s]]></steamID>\n<privacyState>public</privacyState>\n</profile>" % (m.group(1), name), "text/xml")
        if url.path.rstrip("/") == "/ISteamUser/GetPlayerSummaries/v2":
            q = urllib.parse.parse_qs(url.query)
            if q.get("key") != ["test-key"]:
                return self._send(403, "<html>Forbidden</html>", "text/html")
            ids = (q.get("steamids") or [""])[0].split(",")
            players = [{"steamid": i, "personaname": NAMES[i] + " (api)"} for i in ids if i in NAMES]
            return self._send(200, json.dumps({"response": {"players": players}}), "application/json")
        self._send(404, "not found", "text/plain")


if __name__ == "__main__":
    srv = HTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 0), Handler)
    print("ready %d" % srv.server_address[1], flush=True)
    srv.serve_forever()
