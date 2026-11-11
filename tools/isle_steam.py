#!/usr/bin/env python3
"""
isle_steam.py - resolve SteamID64s to Steam display names (persona names), standard library only.

    isle_steam.py [--conf FILE] names [--json] [--refresh] [--cached-only] <SteamID64...>

Where the names come from:
  * STEAM_WEB_API_KEY set in server.conf -> the Steam Web API (ISteamUser/GetPlayerSummaries, 100 ids per call)
  * otherwise                            -> each public profile's XML (steamcommunity.com/profiles/<id>?xml=1)
Results are cached in <config dir>/.steam-names.json (names for STEAM_NAME_CACHE_DAYS, default 7; failed
lookups for 1 hour) so lists stay fast and Steam is not asked again on every page load.
STEAM_NAME_LOOKUP=false turns lookups off (the cache is still read). A lookup never fails a command:
unknown names are simply left out.

Tests and air-gapped hosts: ISLE_STEAM_API_URL / ISLE_STEAM_COMMUNITY_URL override the base URLs and
ISLE_STEAM_OFFLINE=1 skips the network.
"""
import argparse
import html
import json
import os
import re
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
import isle_logs  # noqa: E402

STEAMID_RE = re.compile(r"^7656119\d{10}$")
API_URL = "https://api.steampowered.com"
COMMUNITY_URL = "https://steamcommunity.com"
FAIL_TTL = 3600
TIMEOUT = 6
UA = "the-isle-dedicated-server (+https://github.com/kyroskoh/the-isle-dedicated-server)"
_lock = threading.Lock()


def profile_url(steam_id):
    return "https://steamcommunity.com/profiles/%s" % steam_id


def _truthy(value, default=True):
    if value is None or value == "":
        return default
    return str(value).strip().lower() in ("1", "true", "yes", "on")


class Resolver(object):
    def __init__(self, conf=None, values=None, cache_path=None):
        self.values = values if values is not None else isle_logs.read_conf(conf)
        base = os.path.dirname(os.path.abspath(conf)) if conf else tempfile.gettempdir()
        self.cache_path = cache_path or os.path.join(base, ".steam-names.json")
        self.key = (self.values.get("STEAM_WEB_API_KEY") or "").strip()
        self.enabled = _truthy(self.values.get("STEAM_NAME_LOOKUP"), True) and os.environ.get("ISLE_STEAM_OFFLINE") != "1"
        try:
            self.ttl = max(0, float(self.values.get("STEAM_NAME_CACHE_DAYS") or 7)) * 86400
        except ValueError:
            self.ttl = 7 * 86400
        self.api = os.environ.get("ISLE_STEAM_API_URL", API_URL).rstrip("/")
        self.community = os.environ.get("ISLE_STEAM_COMMUNITY_URL", COMMUNITY_URL).rstrip("/")

    # ------------------------------------------------------------------ cache
    def _load(self):
        try:
            with open(self.cache_path, encoding="utf-8") as handle:
                data = json.load(handle)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def _save(self, cache):
        tmp = self.cache_path + ".tmp"
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(cache, handle, indent=0, sort_keys=True)
            os.replace(tmp, self.cache_path)
        except OSError:
            pass  # a read-only config dir only costs a fresh lookup next time

    def _fresh(self, entry, now):
        if not isinstance(entry, dict):
            return False
        ttl = self.ttl if entry.get("name") else FAIL_TTL
        return now - float(entry.get("at", 0)) < ttl

    # ---------------------------------------------------------------- network
    def _get(self, url):
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return resp.read(512 * 1024).decode("utf-8", "replace")

    def _from_api(self, ids):
        out = {}
        for i in range(0, len(ids), 100):
            chunk = ids[i:i + 100]
            url = "%s/ISteamUser/GetPlayerSummaries/v2/?%s" % (self.api, urllib.parse.urlencode({"key": self.key, "steamids": ",".join(chunk)}))
            data = json.loads(self._get(url))
            for p in (data.get("response") or {}).get("players") or []:
                sid = str(p.get("steamid", ""))
                if STEAMID_RE.match(sid) and p.get("personaname"):
                    out[sid] = str(p["personaname"])[:64]
        return out

    def _from_profile(self, steam_id):
        text = self._get("%s/profiles/%s/?xml=1" % (self.community, steam_id))
        # plain text extraction (no XML parser: nothing in the reply is ever interpreted as markup or entities)
        m = re.search(r"<steamID>\s*(?:<!\[CDATA\[(.*?)\]\]>|([^<]*))\s*</steamID>", text, re.S)
        if not m:
            return None
        name = (m.group(1) if m.group(1) is not None else html.unescape(m.group(2) or "")).strip()
        return name[:64] or None

    # ------------------------------------------------------------------ public
    def resolve(self, ids, refresh=False, cached_only=False):
        """{steam_id: {"name": str|None, "profile": url, "source": "cache"|"steam"|"none"}}"""
        ids = [i for i in dict.fromkeys(str(x).strip() for x in ids) if STEAMID_RE.match(i)]
        now = time.time()
        with _lock:
            cache = self._load()
        result, todo = {}, []
        for sid in ids:
            entry = cache.get(sid)
            if entry and (self._fresh(entry, now) and not refresh or cached_only or not self.enabled):
                result[sid] = {"name": entry.get("name"), "profile": profile_url(sid), "source": "cache"}
            elif cached_only or not self.enabled:
                result[sid] = {"name": None, "profile": profile_url(sid), "source": "none"}
            else:
                todo.append(sid)
        if todo:
            found, failed = {}, set()
            try:
                if self.key:
                    found = self._from_api(todo)
                else:
                    def one(sid):
                        try:
                            return sid, self._from_profile(sid)
                        except (OSError, ValueError, urllib.error.URLError):
                            return sid, False
                    with ThreadPoolExecutor(max_workers=min(8, len(todo))) as pool:
                        for sid, name in pool.map(one, todo):
                            if name is False:
                                failed.add(sid)
                            elif name:
                                found[sid] = name
            except (OSError, ValueError, urllib.error.URLError):
                failed.update(todo)
            with _lock:
                cache = self._load()
                for sid in todo:
                    if sid in found:
                        cache[sid] = {"name": found[sid], "at": now}
                    elif sid not in failed:          # Steam answered: no such (or no public) profile
                        cache[sid] = {"name": None, "at": now}
                    # network errors are not cached as "no name": an older name is kept and shown
                self._save(cache)
            for sid in todo:
                name = found.get(sid) or (cache.get(sid) or {}).get("name")
                result[sid] = {"name": name, "profile": profile_url(sid), "source": "steam" if sid in found else ("cache" if name else "none")}
        return {sid: result[sid] for sid in ids}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Resolve SteamID64s to Steam names")
    ap.add_argument("--conf", default=os.environ.get("ISLE_CONF"))
    sub = ap.add_subparsers(dest="cmd")
    n = sub.add_parser("names", help="print 'SteamID64<TAB>name' (or JSON)")
    n.add_argument("ids", nargs="+")
    n.add_argument("--json", action="store_true")
    n.add_argument("--refresh", action="store_true", help="ignore the cache")
    n.add_argument("--cached-only", action="store_true", help="never touch the network")
    args = ap.parse_args(argv)
    if args.cmd != "names":
        ap.print_help()
        return 2
    bad = [i for i in args.ids if not STEAMID_RE.match(i)]
    if bad:
        print("Not a SteamID64: %s" % ", ".join(bad), file=sys.stderr)
        return 2
    res = Resolver(args.conf).resolve(args.ids, refresh=args.refresh, cached_only=args.cached_only)
    if args.json:
        print(json.dumps(res))
    else:
        for sid, r in res.items():
            print("%s\t%s" % (sid, r["name"] or ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
