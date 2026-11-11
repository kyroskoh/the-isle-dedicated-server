"""
isle_sdk.py - tiny helper library for plugins (on PYTHONPATH when a plugin runs).

    import isle_sdk as isle
    isle.conf("SERVER_NAME")          # value from server.conf
    isle.setting("MY_KEY", "default")  # this plugin's setting
    isle.rcon("announce", "Hello")     # RCON to the local server (native or Docker)
    isle.launcher("restart")           # run a launcher command (isle-server / IsleServer.ps1)
    isle.log("message")
"""

import os
import subprocess
import sys

import isle_rcon

_CONF_CACHE = None

# launcher command names on Windows (PowerShell uses PascalCase)
_PS_NAMES = {"start": "Start", "stop": "Stop", "restart": "Restart", "status": "Status",
             "backup": "Backup", "save": "Save", "update": "Update", "info": "Info"}


def conf(key, default=""):
    global _CONF_CACHE
    if _CONF_CACHE is None:
        path = os.environ.get("ISLE_CONF", "")
        _CONF_CACHE = isle_rcon.read_conf(path) if path and os.path.isfile(path) else {}
    value = _CONF_CACHE.get(key, "")
    return value if value != "" else default


def setting(key, default=""):
    value = os.environ.get(key, "")
    return value if value != "" else default


def runtime():
    return os.environ.get("ISLE_RUNTIME", "native")


def log(msg):
    print("[%s] %s" % (os.environ.get("ISLE_PLUGIN", "plugin"), msg), flush=True)


def rcon(command, *args):
    """Send an RCON command. The RCON port is reachable on 127.0.0.1 in both runtimes."""
    if conf("RCON_ENABLED", "true").lower() not in ("true", "yes", "1", "on"):
        raise RuntimeError("RCON is disabled (RCON_ENABLED=false)")
    password = conf("RCON_PASSWORD")
    if not password:
        raise RuntimeError("RCON_PASSWORD is empty")
    cmd_byte = isle_rcon.COMMANDS[command]
    return isle_rcon.send_command("127.0.0.1", int(conf("RCON_PORT", "8888")), password, cmd_byte, " ".join(args))


def launcher(command):
    """Run a launcher command such as 'restart'. Returns the exit code."""
    path = os.environ.get("ISLE_LAUNCHER", "")
    if not path:
        raise RuntimeError("ISLE_LAUNCHER is not set")
    env = dict(os.environ)
    if path.lower().endswith(".ps1"):
        shell = "powershell" if sys.platform.startswith("win") else "pwsh"
        cmd = [shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path,
               _PS_NAMES.get(command, command), "-ConfigPath", os.environ.get("ISLE_CONF", "")]
    else:
        cmd = [path, command]
    return subprocess.call(cmd, env=env)


def detach(args):
    """Start a background copy of this plugin script (e.g. for delayed actions)."""
    kwargs = {}
    if sys.platform.startswith("win"):
        kwargs["creationflags"] = 0x00000008 | 0x00000200  # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
    else:
        kwargs["start_new_session"] = True
    devnull = open(os.devnull, "wb")
    subprocess.Popen([sys.executable, sys.argv[0]] + list(args), stdout=devnull, stderr=devnull,
                     stdin=subprocess.DEVNULL, **kwargs)
