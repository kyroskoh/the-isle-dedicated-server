#!/usr/bin/env python3
"""
isle_sysinfo.py - this machine's specs and settings that fit them, standard library only.

    isle_sysinfo.py [--conf FILE] [--json]

Reads CPU threads, memory (and a container memory limit), free disk where the server and backups live, OS and
architecture, then recommends MAX_PLAYERS, AI_DENSITY, NET_TICK_RATE, BACKUP_RETENTION and BACKUP_SCHEDULE.

The numbers are estimates from community experience with Evrima servers (the developers publish no official
server requirements): roughly 2.5 GB of memory for an empty server plus about 60 MB per player, a CPU thread per
~25 players, and about 20 GB of disk for the game files. Watch real usage and adjust.

Tests: ISLE_SYSINFO_FAKE='{"cpus": 4, "mem_gb": 8, "disk_free_gb": 100, "arch": "x86_64"}' overrides detection.
"""
import argparse
import json
import os
import platform
import re
import shutil
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
import isle_logs  # noqa: E402

GB = 1024 ** 3
BASE_GB = 2.5            # an empty Evrima server
PER_PLAYER_GB = 0.06     # each connected player
PLAYERS_PER_THREAD = 25
GAME_FILES_GB = 20       # game files + headroom for updates
MAX_SENSIBLE = 100       # most community servers run 50-100 players


def _meminfo():
    total = avail = None
    try:
        with open("/proc/meminfo") as handle:
            for line in handle:
                k, v = line.split(":", 1)
                if k == "MemTotal":
                    total = int(v.split()[0]) * 1024
                elif k == "MemAvailable":
                    avail = int(v.split()[0]) * 1024
    except (OSError, ValueError):
        pass
    if total is None and os.name == "nt":
        import ctypes

        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong), ("ullTotalPhys", ctypes.c_ulonglong),
                        ("ullAvailPhys", ctypes.c_ulonglong), ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                        ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong), ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]
        st = MEMORYSTATUSEX()
        st.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st)):
            total, avail = st.ullTotalPhys, st.ullAvailPhys
    if total is None and sys.platform == "darwin":
        try:
            import subprocess
            total = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"]).strip())
        except (OSError, ValueError):
            pass
    # a container memory limit (cgroup v2, then v1) caps what the server can use
    limit = None
    for path in ("/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory/memory.limit_in_bytes"):
        try:
            with open(path) as handle:
                raw = handle.read().strip()
            if raw.isdigit() and int(raw) < (1 << 60):
                limit = int(raw)
                break
        except OSError:
            continue
    return total, avail, limit


def _cpu_model():
    try:
        with open("/proc/cpuinfo") as handle:
            for line in handle:
                if line.lower().startswith("model name"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return os.environ.get("PROCESSOR_IDENTIFIER") or platform.processor() or ""


def _existing(path):
    path = os.path.abspath(os.path.expanduser(path or "."))
    while path and not os.path.exists(path):
        parent = os.path.dirname(path)
        if parent == path:
            break
        path = parent
    return path if os.path.exists(path) else os.path.abspath(".")


def _newest_backup_bytes(backup_dir):
    try:
        sizes = [(e.stat().st_mtime, e.stat().st_size) for e in os.scandir(os.path.expanduser(backup_dir))
                 if e.is_file() and e.name.startswith("theisle-")]
        return max(sizes)[1] if sizes else None
    except OSError:
        return None


def machine(values):
    fake = os.environ.get("ISLE_SYSINFO_FAKE")
    server_dir = values.get("SERVER_DIR") or "~/theisle-server"
    backup_dir = values.get("BACKUP_DIR") or "~/theisle-backups"
    if fake:
        f = json.loads(fake)
        return {"cpus": f.get("cpus", 4), "cpu_model": f.get("cpu_model", "test CPU"), "mem_total_gb": f.get("mem_gb", 8),
                "mem_available_gb": f.get("mem_available_gb", f.get("mem_gb", 8) * 0.7), "mem_limit_gb": f.get("mem_limit_gb"),
                "disk_free_gb": f.get("disk_free_gb", 100), "disk_path": server_dir, "backup_size_mb": f.get("backup_size_mb"),
                "os": f.get("os", "Linux"), "arch": f.get("arch", "x86_64"), "runtime": values.get("RUNTIME") or "native"}
    total, avail, limit = _meminfo()
    disk_path = _existing(server_dir)
    try:
        free = shutil.disk_usage(disk_path).free
    except OSError:
        free = None
    size = _newest_backup_bytes(backup_dir)
    rnd = lambda b: round(b / GB, 1) if b else None  # noqa: E731
    return {"cpus": os.cpu_count() or 1, "cpu_model": _cpu_model(), "mem_total_gb": rnd(total), "mem_available_gb": rnd(avail),
            "mem_limit_gb": rnd(limit), "disk_free_gb": rnd(free), "disk_path": disk_path,
            "backup_size_mb": round(size / 1024 ** 2) if size else None, "os": platform.system() or sys.platform,
            "arch": platform.machine() or "", "runtime": values.get("RUNTIME") or "native"}


def recommend(values, m):
    recs, warnings = [], []
    mem = m["mem_total_gb"] or 0
    if m.get("mem_limit_gb"):
        mem = min(mem or m["mem_limit_gb"], m["mem_limit_gb"])
    reserve = 1.5 if mem <= 8 else 2.0          # the OS, SteamCMD during updates, the web UI
    usable = max(0.0, mem - reserve)
    by_mem = int((usable - BASE_GB) / PER_PLAYER_GB) if usable > BASE_GB else 0
    by_cpu = (m["cpus"] or 1) * PLAYERS_PER_THREAD
    players = max(10, min(by_mem, by_cpu, MAX_SENSIBLE))
    players -= players % 5
    limited_by = "memory" if by_mem <= by_cpu else "CPU threads"
    arch = (m.get("arch") or "").lower()
    if arch and arch not in ("x86_64", "amd64", "x64"):
        warnings.append("This machine is %s: the Evrima server only runs on x86_64 (64-bit Intel/AMD)." % m["arch"])
    if mem and mem < 6:
        warnings.append("%.1f GB of memory is below the practical minimum (about 6 GB): expect a small, laggy server." % mem)
    if (m["cpus"] or 0) < 2:
        warnings.append("One CPU thread is not enough for a smooth server - 4 or more are recommended.")
    free = m.get("disk_free_gb")
    if free is not None and free < GAME_FILES_GB:
        warnings.append("Only %.0f GB free at %s - the game files and updates need about %d GB." % (free, m["disk_path"], GAME_FILES_GB))

    def rec(key, value, reason):
        recs.append({"key": key, "value": str(value), "current": values.get(key, ""), "reason": reason})

    rec("MAX_PLAYERS", players, "About %d players fit %s GB of memory and %d CPU threads (limited by %s); raise it if usage stays low."
        % (players, ("%.1f" % mem).rstrip("0").rstrip("."), m["cpus"], limited_by))
    density = 1 if players >= 60 and (m["cpus"] or 1) >= 4 else (0.75 if players >= 30 else 0.5)
    rec("AI_DENSITY", density, "Full AI needs headroom; fewer AI creatures save CPU and memory on smaller machines." if density < 1
        else "The machine has room for the default amount of AI.")
    rec("NET_TICK_RATE", 30 if (m["cpus"] or 1) >= 4 else 20, "A lower server tick rate eases the CPU on machines with few threads."
        if (m["cpus"] or 1) < 4 else "30 Hz is smooth and affordable with 4+ CPU threads.")
    size_gb = (m.get("backup_size_mb") or 300) / 1024.0
    if free is not None:
        budget = max(0.0, (free - GAME_FILES_GB) * 0.25)      # use at most a quarter of the remaining disk for backups
        keep = int(max(3, min(30, budget / size_gb))) if size_gb else 10
        rec("BACKUP_RETENTION", keep, "%d backups of ~%d MB use at most a quarter of the free disk after the game files."
            % (keep, round(size_gb * 1024)))
    rec("BACKUP_SCHEDULE", "0 */6 * * *" if players >= 40 else "0 5 * * *",
        "Busy servers lose less progress with a backup every 6 hours." if players >= 40 else "A daily backup is enough for a small server.")
    tier = "small" if players < 40 else ("medium" if players < 80 else "large")
    return {"tier": tier, "players": players, "recommendations": recs, "warnings": warnings}


def report(conf):
    values = isle_logs.read_conf(conf) if conf else {}
    m = machine(values)
    r = recommend(values, m)
    r["machine"] = m
    return r


def main(argv=None):
    ap = argparse.ArgumentParser(description="Machine specs and recommended server settings")
    ap.add_argument("--conf", default=os.environ.get("ISLE_CONF"))
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    r = report(args.conf)
    if args.json:
        print(json.dumps(r))
        return 0
    m = r["machine"]
    mem = "%s GB" % m["mem_total_gb"] + (" (container limit %s GB)" % m["mem_limit_gb"] if m.get("mem_limit_gb") else "")
    print("Machine   : %s %s, %d CPU threads%s" % (m["os"], m["arch"], m["cpus"], " (%s)" % m["cpu_model"] if m["cpu_model"] else ""))
    print("Memory    : %s, %s GB available" % (mem, m["mem_available_gb"]))
    print("Disk      : %s GB free at %s" % (m["disk_free_gb"], m["disk_path"]))
    print("Fits      : a %s server, about %d players\n" % (r["tier"], r["players"]))
    for w in r["warnings"]:
        print("WARNING   : " + w)
    if r["warnings"]:
        print()
    print("%-18s %-14s %-14s %s" % ("Setting", "Recommended", "Current", "Why"))
    for x in r["recommendations"]:
        print("%-18s %-14s %-14s %s" % (x["key"], x["value"], x["current"] or "(default)", x["reason"]))
    print("\nEstimates from community experience - watch real usage and adjust.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
