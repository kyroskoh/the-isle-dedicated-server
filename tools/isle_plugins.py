#!/usr/bin/env python3
"""
isle_plugins.py - plugin manager for The Isle dedicated server scripts (PRD PLG-01..07).

Python 3.6+, standard library only. Used by linux/isle-server.sh and
windows/IsleServer.ps1 in both runtimes (native and docker).

    isle_plugins.py [--conf FILE] [--launcher PATH] [--runtime native|docker] <command> ...

Commands:
    list [--installed|--available]     installed and available plugins
    search <text>                      search all catalogs (name, description, tags)
    info <name>                        details, settings and hooks
    install <name|dir|archive|url#sha256> [--yes]
    remove <name> [--purge]            --purge also deletes its settings
    enable <name> | disable <name>
    update [name]                      update one or all installed plugins
    preset [base|recommended|full]     list presets, or install + enable one
    run <name> [command] [args...]     run a plugin command (default: "run")
    config <name> [KEY=VALUE ...]      show or change a plugin's settings
    sources [add <url>|remove <url>]   extra catalogs (JSON over HTTPS)
    community [--json]                 community tools, libraries and guides (plugins/community.json)
    hook <event>                       run hooks of enabled plugins (used by the launchers)

Layout:
    <repo>/plugins/catalog.json        first-party catalog (+ presets)
    <repo>/plugins/available/<name>/   first-party plugins
    <repo>/plugins/installed/<name>/   installed plugins
    <conf dir>/plugins/enabled.txt     enabled plugin names
    <conf dir>/plugins/<name>.conf     plugin settings (KEY=VALUE, mode 600)
    <conf dir>/plugins/sources.txt     extra catalog URLs
"""

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGINS = os.path.join(REPO, "plugins")
AVAILABLE = os.path.join(PLUGINS, "available")
INSTALLED = os.path.join(PLUGINS, "installed")
CATALOG = os.path.join(PLUGINS, "catalog.json")
HOOK_EVENTS = ("post-start", "pre-stop", "post-stop", "post-backup", "post-update")
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")


class PluginError(Exception):
    pass


# ------------------------------------------------------------------ helpers --
def say(msg):
    print(msg, flush=True)


def ok(msg):
    say("[ OK ] " + msg)


def warn(msg):
    print("[WARN] " + msg, file=sys.stderr, flush=True)


def read_kv(path):
    values = {}
    if not os.path.isfile(path):
        return values
    with open(path, "r", encoding="utf-8-sig") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            values[key.strip()] = value
    return values


def write_kv(path, values, header=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        if header:
            handle.write(header)
        for key in sorted(values):
            handle.write("%s=%s\n" % (key, values[key]))
    try:
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
    except OSError:
        pass


def version_tuple(v):
    return tuple(int(x) if x.isdigit() else x for x in re.split(r"[.\-+]", str(v or "0")))


def check_name(name):
    if not NAME_RE.match(name or ""):
        raise PluginError("invalid plugin name '%s' (lowercase letters, digits, . _ -)" % name)
    return name


def load_manifest(directory):
    path = os.path.join(directory, "plugin.json")
    if not os.path.isfile(path):
        raise PluginError("%s has no plugin.json" % directory)
    with open(path, "r", encoding="utf-8") as handle:
        try:
            data = json.load(handle)
        except ValueError as exc:
            raise PluginError("invalid plugin.json in %s: %s" % (directory, exc))
    check_name(data.get("name", ""))
    data.setdefault("version", "0.0.0")
    data.setdefault("description", "")
    data.setdefault("type", "python")
    data.setdefault("hooks", {})
    data.setdefault("commands", {})
    data.setdefault("settings", {})
    for event in data["hooks"]:
        if event not in HOOK_EVENTS:
            raise PluginError("%s: unknown hook '%s' (allowed: %s)" % (data["name"], event, ", ".join(HOOK_EVENTS)))
    return data


# ------------------------------------------------------------------- context --
class Context(object):
    def __init__(self, conf, launcher, runtime):
        self.conf = os.path.abspath(conf) if conf else os.path.join(REPO, "config", "server.conf")
        self.launcher = launcher or ""
        self.runtime = runtime or "native"
        self.state = os.path.join(os.path.dirname(self.conf), "plugins")
        self.enabled_file = os.path.join(self.state, "enabled.txt")
        self.sources_file = os.path.join(self.state, "sources.txt")

    # enabled set
    def enabled(self):
        if not os.path.isfile(self.enabled_file):
            return []
        with open(self.enabled_file, "r", encoding="utf-8") as handle:
            return [l.strip() for l in handle if l.strip() and not l.startswith("#")]

    def set_enabled(self, names):
        os.makedirs(self.state, exist_ok=True)
        with open(self.enabled_file, "w", encoding="utf-8") as handle:
            for n in sorted(set(names)):
                handle.write(n + "\n")

    # settings
    def settings_path(self, name):
        return os.path.join(self.state, name + ".conf")

    def settings(self, manifest):
        values = {k: str(v.get("default", "")) for k, v in manifest.get("settings", {}).items()}
        values.update(read_kv(self.settings_path(manifest["name"])))
        return values

    def ensure_settings(self, manifest):
        path = self.settings_path(manifest["name"])
        if os.path.isfile(path) or not manifest.get("settings"):
            return
        values = {k: str(v.get("default", "")) for k, v in manifest["settings"].items()}
        header = "# Settings for plugin %s - edit, or: isle-server plugins config %s KEY=VALUE\n" % (
            manifest["name"], manifest["name"])
        for key, spec in sorted(manifest["settings"].items()):
            header += "#   %s: %s\n" % (key, spec.get("description", ""))
        write_kv(path, values, header)

    # sources
    def sources(self):
        if not os.path.isfile(self.sources_file):
            return []
        with open(self.sources_file, "r", encoding="utf-8") as handle:
            return [l.strip() for l in handle if l.strip() and not l.startswith("#")]

    def server_conf(self):
        return read_kv(self.conf)


# ------------------------------------------------------------------ catalogs --
def fetch(url, timeout=30):
    if not re.match(r"^https?://", url):
        raise PluginError("only http(s) URLs are supported: %s" % url)
    req = urllib.request.Request(url, headers={"User-Agent": "theisle-server-plugins/1"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def load_catalogs(ctx, quiet=False):
    """Returns (entries, presets). entries: name -> entry dict with 'catalog'."""
    entries, presets = {}, {}
    catalogs = []
    if os.path.isfile(CATALOG):
        with open(CATALOG, "r", encoding="utf-8") as handle:
            catalogs.append(("builtin", json.load(handle)))
    for url in ctx.sources():
        try:
            catalogs.append((url, json.loads(fetch(url).decode("utf-8"))))
        except Exception as exc:  # a broken third-party catalog must not break the tool
            if not quiet:
                warn("catalog %s could not be read: %s" % (url, exc))
    for origin, data in catalogs:
        for entry in data.get("plugins", []):
            name = entry.get("name", "")
            if not NAME_RE.match(name):
                continue
            entry = dict(entry, catalog=origin)
            if name in entries and origin != "builtin":
                if not quiet:
                    warn("%s from %s ignored: a plugin with that name is already listed" % (name, origin))
                continue
            entries[name] = entry
        for pname, members in data.get("presets", {}).items():
            presets.setdefault(pname, members)
    return entries, presets


def installed(ctx):
    result = {}
    if os.path.isdir(INSTALLED):
        for name in sorted(os.listdir(INSTALLED)):
            directory = os.path.join(INSTALLED, name)
            if os.path.isdir(directory):
                try:
                    result[name] = load_manifest(directory)
                except PluginError as exc:
                    warn(str(exc))
    return result


# ----------------------------------------------------------------- installing --
def safe_extract(data, filename, dest):
    """Extract a zip/tar.gz into dest, refusing absolute paths, '..' and links."""
    def check(member):
        norm = os.path.normpath(member)
        if member.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:", member) or norm.startswith("..") \
                or os.sep + ".." + os.sep in os.sep + norm + os.sep:
            raise PluginError("unsafe path in archive: %s" % member)

    lower = filename.lower()
    if lower.endswith(".zip"):
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            for info in z.infolist():
                check(info.filename)
            z.extractall(dest)
    elif lower.endswith((".tar.gz", ".tgz", ".tar")):
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as t:
            for m in t.getmembers():
                check(m.name)
                if m.issym() or m.islnk() or m.isdev():
                    raise PluginError("links/devices are not allowed in plugin archives: %s" % m.name)
            t.extractall(dest)
    else:
        raise PluginError("unsupported archive type: %s (use .zip or .tar.gz)" % filename)


def find_plugin_root(directory):
    if os.path.isfile(os.path.join(directory, "plugin.json")):
        return directory
    subdirs = [os.path.join(directory, d) for d in os.listdir(directory) if os.path.isdir(os.path.join(directory, d))]
    if len(subdirs) == 1 and os.path.isfile(os.path.join(subdirs[0], "plugin.json")):
        return subdirs[0]
    raise PluginError("no plugin.json found in the archive")


def place(ctx, source_dir, third_party):
    manifest = load_manifest(source_dir)
    name = manifest["name"]
    target = os.path.join(INSTALLED, name)
    os.makedirs(INSTALLED, exist_ok=True)
    if os.path.isdir(target):
        shutil.rmtree(target)
    shutil.copytree(source_dir, target)
    ctx.ensure_settings(manifest)
    ctx.set_enabled(ctx.enabled() + [name])
    if manifest.get("type") == "files":
        install_files(ctx, manifest, target)
    ok("Installed and enabled %s %s" % (name, manifest["version"]))
    if third_party:
        warn("%s is third-party code: plugins run with the server user's rights. Only install code you trust." % name)
    missing = [k for k, v in manifest.get("settings", {}).items() if v.get("required") and not ctx.settings(manifest).get(k)]
    if missing:
        say("       Configure it: isle-server plugins config %s %s" % (name, " ".join(k + "=..." for k in missing)))
    return manifest


def install_files(ctx, manifest, plugin_dir):
    """type=files: copy listed files into the server folder (PLG-06, untested with Evrima)."""
    warn("'%s' installs files into the game folder. Evrima has no official mod support - this is untested "
         "and may be rejected by the game or break joining." % manifest["name"])
    if ctx.runtime == "docker":
        warn("file add-ons are only applied natively; in docker mode copy them with 'docker cp'")
        return
    server_dir = ctx.server_conf().get("SERVER_DIR") or os.path.join(os.path.expanduser("~"), "theisle-server")
    root = os.path.realpath(server_dir)
    for item in manifest.get("files", []):
        src = os.path.join(plugin_dir, item["src"])
        dest = os.path.realpath(os.path.join(server_dir, item["dest"]))
        if not (dest + os.sep).startswith(root + os.sep):
            raise PluginError("file destination escapes the server folder: %s" % item["dest"])
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copy2(src, dest)
        ok("Copied %s -> %s" % (item["src"], dest))


def install_from_url(ctx, url, sha256):
    if not sha256:
        raise PluginError("remote installs need a SHA-256: use <url>#sha256=<hex> or a catalog entry with sha256")
    if not re.match(r"^[0-9a-fA-F]{64}$", sha256):
        raise PluginError("not a SHA-256 hex digest: %s" % sha256)
    say("Downloading %s" % url)
    data = fetch(url, timeout=120)
    digest = hashlib.sha256(data).hexdigest()
    if digest.lower() != sha256.lower():
        raise PluginError("SHA-256 mismatch for %s\n  expected %s\n  got      %s" % (url, sha256.lower(), digest))
    ok("SHA-256 verified")
    tmp = tempfile.mkdtemp(prefix="isle-plugin-")
    try:
        safe_extract(data, url.split("?")[0].split("#")[0], tmp)
        return place(ctx, find_plugin_root(tmp), third_party=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def install(ctx, target):
    entries, _ = load_catalogs(ctx)
    # url#sha256=...
    if re.match(r"^https?://", target):
        url, _, frag = target.partition("#")
        sha = frag.split("=", 1)[1] if frag.startswith("sha256=") else frag
        return install_from_url(ctx, url, sha)
    # local directory or archive
    if os.path.isdir(target):
        return place(ctx, os.path.abspath(target), third_party=not os.path.abspath(target).startswith(AVAILABLE))
    if os.path.isfile(target):
        tmp = tempfile.mkdtemp(prefix="isle-plugin-")
        try:
            with open(target, "rb") as handle:
                safe_extract(handle.read(), target, tmp)
            return place(ctx, find_plugin_root(tmp), third_party=True)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    # catalog name
    entry = entries.get(target)
    if not entry:
        raise PluginError("'%s' is not a known plugin, folder, archive or URL (try: isle-server plugins search %s)" % (target, target))
    if entry.get("source", "").startswith("builtin:"):
        directory = os.path.join(AVAILABLE, entry["source"].split(":", 1)[1])
        return place(ctx, directory, third_party=False)
    return install_from_url(ctx, entry.get("url", ""), entry.get("sha256", ""))


# ------------------------------------------------------------------- running --
def plugin_env(ctx, manifest, event=""):
    env = dict(os.environ)
    env.update(ctx.settings(manifest))
    env.update({
        "ISLE_EVENT": event,
        "ISLE_CONF": ctx.conf,
        "ISLE_LAUNCHER": ctx.launcher,
        "ISLE_RUNTIME": ctx.runtime,
        "ISLE_PLUGIN": manifest["name"],
        "ISLE_PLUGIN_DIR": os.path.join(INSTALLED, manifest["name"]),
        "ISLE_REPO": REPO,
    })
    tools = os.path.join(REPO, "tools")
    env["PYTHONPATH"] = tools + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
    return env


def run_entry(ctx, manifest, entry, args, event="", timeout=None):
    script = os.path.join(INSTALLED, manifest["name"], entry)
    if not os.path.isfile(script):
        raise PluginError("%s: entry point %s not found" % (manifest["name"], entry))
    cmd = [sys.executable, script] + list(args)
    return subprocess.call(cmd, env=plugin_env(ctx, manifest, event), timeout=timeout)


def run_hooks(ctx, event):
    if event not in HOOK_EVENTS:
        raise PluginError("unknown event %s" % event)
    plugins = installed(ctx)
    failures = 0
    for name in ctx.enabled():
        manifest = plugins.get(name)
        if not manifest or event not in manifest["hooks"]:
            continue
        try:
            rc = run_entry(ctx, manifest, manifest["hooks"][event], [event], event=event, timeout=600)
        except Exception as exc:
            rc = 1
            warn("%s: %s" % (name, exc))
        if rc != 0:
            failures += 1
            warn("plugin %s failed on %s (exit %s) - continuing" % (name, event, rc))
    return 0  # hooks never block the server (PLG-03)


# ------------------------------------------------------------------ commands --
def cmd_list(ctx, opts):
    entries, _ = load_catalogs(ctx, quiet=True)
    inst, enabled = installed(ctx), set(ctx.enabled())
    names = set(inst) | set(entries)
    if opts.installed:
        names = set(inst)
    if opts.available:
        names = set(entries)
    if not names:
        say("No plugins.")
        return 0
    say("%-20s %-9s %-10s %-9s %s" % ("NAME", "VERSION", "INSTALLED", "ENABLED", "DESCRIPTION"))
    for n in sorted(names):
        m = inst.get(n) or entries.get(n, {})
        say("%-20s %-9s %-10s %-9s %s" % (n, m.get("version", ""), "yes" if n in inst else "-",
                                          "yes" if n in enabled else "-", m.get("description", "")))
    return 0


def cmd_search(ctx, opts):
    entries, _ = load_catalogs(ctx)
    text = " ".join(opts.text).lower()
    hits = [e for e in entries.values()
            if text in (e["name"] + " " + e.get("description", "") + " " + " ".join(e.get("tags", []))).lower()]
    for e in sorted(hits, key=lambda e: e["name"]):
        say("%-20s %-9s [%s] %s" % (e["name"], e.get("version", ""), e["catalog"], e.get("description", "")))
    if not hits:
        say("No plugins match '%s'." % text)
    return 0


def cmd_info(ctx, opts):
    entries, _ = load_catalogs(ctx, quiet=True)
    inst = installed(ctx)
    m = inst.get(opts.name)
    if not m and opts.name in entries and entries[opts.name].get("source", "").startswith("builtin:"):
        m = load_manifest(os.path.join(AVAILABLE, entries[opts.name]["source"].split(":", 1)[1]))
    if not m:
        e = entries.get(opts.name)
        if not e:
            raise PluginError("unknown plugin %s" % opts.name)
        say(json.dumps(e, indent=2))
        return 0
    say("%s %s - %s" % (m["name"], m["version"], m["description"]))
    say("  installed: %s   enabled: %s" % ("yes" if m["name"] in inst else "no",
                                           "yes" if m["name"] in ctx.enabled() else "no"))
    if m.get("hooks"):
        say("  hooks:     %s" % ", ".join(sorted(m["hooks"])))
    if m.get("commands"):
        say("  commands:  %s" % ", ".join(sorted(m["commands"])))
    if m.get("settings"):
        say("  settings:")
        current = ctx.settings(m)
        for k, spec in sorted(m["settings"].items()):
            val = current.get(k, "")
            if spec.get("secret") and val:
                val = "********"
            say("    %-24s %-18s %s" % (k, val, spec.get("description", "")))
    for line in m.get("usage", []):
        say("  " + line)
    return 0


def cmd_install(ctx, opts):
    install(ctx, opts.target)
    return 0


def cmd_remove(ctx, opts):
    check_name(opts.name)
    target = os.path.join(INSTALLED, opts.name)
    if not os.path.isdir(target):
        raise PluginError("%s is not installed" % opts.name)
    shutil.rmtree(target)
    ctx.set_enabled([n for n in ctx.enabled() if n != opts.name])
    if opts.purge and os.path.isfile(ctx.settings_path(opts.name)):
        os.remove(ctx.settings_path(opts.name))
    ok("Removed %s%s" % (opts.name, " and its settings" if opts.purge else " (settings kept)"))
    return 0


def cmd_enable(ctx, opts, on):
    if opts.name not in installed(ctx):
        raise PluginError("%s is not installed (isle-server plugins install %s)" % (opts.name, opts.name))
    names = [n for n in ctx.enabled() if n != opts.name] + ([opts.name] if on else [])
    ctx.set_enabled(names)
    ok("%s %s" % ("Enabled" if on else "Disabled", opts.name))
    return 0


def cmd_update(ctx, opts):
    entries, _ = load_catalogs(ctx)
    inst = installed(ctx)
    names = [opts.name] if opts.name else sorted(inst)
    updated = 0
    for n in names:
        if n not in inst:
            raise PluginError("%s is not installed" % n)
        e = entries.get(n)
        if not e:
            say("%s: not in any catalog - skipped" % n)
            continue
        latest = e.get("version", "0")
        if e.get("source", "").startswith("builtin:"):
            latest = load_manifest(os.path.join(AVAILABLE, e["source"].split(":", 1)[1]))["version"]
        if version_tuple(latest) > version_tuple(inst[n]["version"]):
            was_enabled = n in ctx.enabled()
            install(ctx, n)
            if not was_enabled:
                ctx.set_enabled([x for x in ctx.enabled() if x != n])
            updated += 1
        else:
            say("%s %s is up to date" % (n, inst[n]["version"]))
    ok("%d plugin(s) updated" % updated)
    return 0


def cmd_preset(ctx, opts):
    entries, presets = load_catalogs(ctx, quiet=True)
    if not opts.name:
        for p, members in presets.items():
            say("  %-12s %s" % (p, ", ".join(members)))
        return 0
    if opts.name not in presets:
        raise PluginError("unknown preset %s (available: %s)" % (opts.name, ", ".join(presets)))
    for n in presets[opts.name]:
        if n in installed(ctx):
            ctx.set_enabled(ctx.enabled() + [n])
            ok("%s already installed - enabled" % n)
        else:
            install(ctx, n)
    ok("Preset %s applied" % opts.name)
    return 0


def cmd_run(ctx, opts):
    m = installed(ctx).get(opts.name)
    if not m:
        raise PluginError("%s is not installed" % opts.name)
    command = opts.plugin_command or "run"
    if command not in m.get("commands", {}):
        raise PluginError("%s has no command '%s' (commands: %s)" % (opts.name, command, ", ".join(m.get("commands", {})) or "none"))
    return run_entry(ctx, m, m["commands"][command], [command] + list(opts.args))


def cmd_config(ctx, opts):
    inst = installed(ctx)
    m = inst.get(opts.name)
    if not m:
        raise PluginError("%s is not installed" % opts.name)
    path = ctx.settings_path(opts.name)
    if not opts.pairs:
        current = ctx.settings(m)
        for k in sorted(set(current) | set(m.get("settings", {}))):
            spec = m.get("settings", {}).get(k, {})
            val = current.get(k, "")
            if spec.get("secret") and val:
                val = "********"
            say("%s=%s" % (k, val))
        return 0
    values = read_kv(path) or {k: str(v.get("default", "")) for k, v in m.get("settings", {}).items()}
    for pair in opts.pairs:
        if "=" not in pair:
            raise PluginError("use KEY=VALUE, got %s" % pair)
        k, v = pair.split("=", 1)
        if k not in m.get("settings", {}):
            raise PluginError("%s has no setting %s (settings: %s)" % (opts.name, k, ", ".join(sorted(m.get("settings", {})))))
        if "\n" in v:
            raise PluginError("values must be a single line")
        values[k] = v
    write_kv(path, values, "# Settings for plugin %s\n" % opts.name)
    ok("Saved %s" % path)
    return 0


def cmd_sources(ctx, opts):
    current = ctx.sources()
    if opts.source_action is None:
        for s in current:
            say(s)
        if not current:
            say("No extra catalogs. Add one with: isle-server plugins sources add <https-url>")
        return 0
    if not opts.url or not re.match(r"^https?://", opts.url):
        raise PluginError("give an http(s) catalog URL")
    if opts.source_action == "add":
        current = current + ([opts.url] if opts.url not in current else [])
        warn("Plugins from third-party catalogs run with the server user's rights - add only catalogs you trust.")
    else:
        current = [s for s in current if s != opts.url]
    os.makedirs(ctx.state, exist_ok=True)
    with open(ctx.sources_file, "w", encoding="utf-8") as handle:
        handle.write("".join(s + "\n" for s in current))
    ok("Catalog sources: %d" % len(current))
    return 0


def community_data():
    path = os.path.join(REPO, "plugins", "community.json")
    if not os.path.isfile(path):
        return {"links": [], "catalogs": [], "mods": "", "catalog_help": ""}
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def cmd_community(ctx, opts):
    data = community_data()
    if getattr(opts, "json", False):
        print(json.dumps(data, indent=2))
        return 0
    say("Community resources (third-party - listed, not installed or endorsed):")
    for item in data.get("links", []):
        say("  %-34s %-13s %s" % (item["name"], item.get("kind", ""), item["url"]))
        if item.get("description"):
            say("      " + item["description"])
    for cat in data.get("catalogs", []):
        say("  catalog: %s  (add with: isle-server plugins sources add %s)" % (cat.get("name", ""), cat.get("url", "")))
    if data.get("mods"):
        say("")
        say("Mods: " + data["mods"])
    if data.get("catalog_help"):
        say("Catalogs: " + data["catalog_help"])
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="isle-server plugins", description="Plugin manager")
    parser.add_argument("--conf", default=os.environ.get("ISLE_CONF"))
    parser.add_argument("--launcher", default=os.environ.get("ISLE_LAUNCHER", ""))
    parser.add_argument("--runtime", default=os.environ.get("ISLE_RUNTIME", "native"))
    sub = parser.add_subparsers(dest="action")
    p = sub.add_parser("list"); p.add_argument("--installed", action="store_true"); p.add_argument("--available", action="store_true")
    p = sub.add_parser("search"); p.add_argument("text", nargs="+")
    p = sub.add_parser("info"); p.add_argument("name")
    p = sub.add_parser("install"); p.add_argument("target"); p.add_argument("--yes", action="store_true")
    p = sub.add_parser("remove"); p.add_argument("name"); p.add_argument("--purge", action="store_true")
    p = sub.add_parser("enable"); p.add_argument("name")
    p = sub.add_parser("disable"); p.add_argument("name")
    p = sub.add_parser("update"); p.add_argument("name", nargs="?")
    p = sub.add_parser("preset"); p.add_argument("name", nargs="?")
    p = sub.add_parser("run"); p.add_argument("name"); p.add_argument("plugin_command", nargs="?"); p.add_argument("args", nargs=argparse.REMAINDER)
    p = sub.add_parser("config"); p.add_argument("name"); p.add_argument("pairs", nargs="*")
    p = sub.add_parser("sources"); p.add_argument("source_action", nargs="?", choices=["add", "remove"]); p.add_argument("url", nargs="?")
    p = sub.add_parser("community"); p.add_argument("--json", action="store_true")
    p = sub.add_parser("hook"); p.add_argument("event")
    opts = parser.parse_args(argv)
    ctx = Context(opts.conf, opts.launcher, opts.runtime)
    handlers = {
        "list": cmd_list, "search": cmd_search, "info": cmd_info, "install": cmd_install,
        "remove": cmd_remove, "update": cmd_update, "preset": cmd_preset, "run": cmd_run,
        "config": cmd_config, "sources": cmd_sources, "community": cmd_community,
        "enable": lambda c, o: cmd_enable(c, o, True), "disable": lambda c, o: cmd_enable(c, o, False),
        "hook": lambda c, o: run_hooks(c, o.event),
    }
    if not opts.action:
        parser.print_help()
        return 0
    try:
        return handlers[opts.action](ctx, opts) or 0
    except PluginError as exc:
        print("[FAIL] %s" % exc, file=sys.stderr)
        return 1
    except (OSError, urllib.error.URLError) as exc:
        print("[FAIL] %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
