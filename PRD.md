# Product Requirements Document: The Isle Dedicated Server Scripts

| | |
|---|---|
| **Status** | v1.0.0, released |
| **Owner** | kyroskoh |
| **Last updated** | 2026-11-07 |

## 1. Summary

A free, open-source toolkit that turns a fresh Windows or Linux machine into a working
**The Isle – Evrima** dedicated server in a few minutes. It also covers the day-two work:
updates, restarts, crash recovery, backups and admin commands.

## 2. Problem

Hosting Evrima by hand means:

- installing SteamCMD and the right 32-bit libraries, which differ on every Linux distro
- knowing the app ID (`412680`), the `evrima` beta branch, and that `steamclient.so` must go in `~/.steam/sdk64`
- writing `Game.ini` and `Engine.ini` from scratch, including the EOS credentials the server needs to appear in the browser
- opening the right ports (UDP game port, TCP queue port, and RCON kept private)
- keeping the server running through crashes and reboots, and updating it after every patch
- stopping it without losing player progress

Community guides cover the first run but not ongoing operation, and most target only one OS.

## 3. Goals

| # | Goal | Measure |
|---|---|---|
| G1 | One-command install on supported OSes | Installer finishes without manual steps on a clean VM |
| G2 | Same configuration on both platforms | One `server.conf` drives Windows and Linux |
| G3 | Survives crashes and reboots | Service auto-starts at boot and restarts after a crash |
| G4 | No progress loss on routine stop/update | RCON `save` before every scripted stop or backup |
| G5 | Secure by default | Non-root/non-admin runtime account, RCON not exposed, random RCON password |
| G6 | Few dependencies | Bash + coreutils on Linux; built-in PowerShell 5.1 on Windows; Python only for RCON |

### Non-goals

- A web panel or GUI (a possible later addition)
- Docker or Kubernetes images (the scripts work inside a glibc container, but no image ships)
- Mod or workshop management
- The Legacy branch as a first-class target (it works with `STEAM_BRANCH=` but isn't tested)
- ARM or musl hosts (the game server binary doesn't support them)

## 4. Users

- **Hobby admin:** runs a server for friends on a home PC (Windows 10/11). Wants double-click scripts.
- **Community admin:** rents a VPS (Ubuntu/Debian/Rocky). Wants systemd, backups and RCON.
- **Hosting tinkerer:** runs Windows Server 2019–2025 or an unusual distro. Wants the scripts to stay understandable and changeable.

## 5. Functional requirements

| ID | Requirement | Linux | Windows |
|---|---|---|---|
| F1 | Install OS dependencies | `install.sh` (apt/dnf/yum/pacman/zypper) | VC++ runtime, optional Python via winget |
| F2 | Install SteamCMD | `~/steamcmd` | `C:\TheIsle\steamcmd` |
| F3 | Install and update the server (app 412680, configurable branch, optional validate, 3x retry) | ✅ | ✅ |
| F4 | Generate `Game.ini` and `Engine.ini` from `server.conf` and keep a `.bak` | ✅ | ✅ |
| F5 | Start, stop, restart, status, foreground run | ✅ | ✅ |
| F6 | Auto-start at boot and auto-restart after a crash | systemd unit | Scheduled task + watchdog |
| F7 | Graceful stop: RCON save, then SIGTERM/close, then force after timeout | ✅ | ✅ (save + close/kill) |
| F8 | Firewall configuration | ufw / firewalld | Windows Defender Firewall |
| F9 | Backups with retention, plus restore | tar.gz + systemd timer | zip + scheduled task |
| F10 | RCON client | `tools/isle_rcon.py` | same |
| F11 | Uninstall that keeps data | `--uninstall` | `-Uninstall` |
| F12 | Idempotent re-runs that keep user config | ✅ | ✅ |

## 6. Non-functional requirements

- **Compatibility:** Bash 4.2+ and GNU coreutils/findutils. Windows PowerShell 5.1, with no
  PowerShell 7-only syntax. Script files are ASCII-only so 5.1 parses them correctly.
- **Safety:** the config file is parsed, never `source`d or executed. The Linux manager refuses to run the game as root.
  Config and ini files are created with mode `600` on Linux.
- **Quality:** CI runs ShellCheck, the Windows PowerShell 5.1 parser, PSScriptAnalyzer, Python compile,
  and a smoke test with a fake server binary on Ubuntu and Windows.
- **Transparency:** every action is logged to the console with timestamps. There are no hidden downloads beyond
  SteamCMD, the VC++ runtime and (optionally) Python.

## 7. Architecture

```
            config/server.conf  (KEY=VALUE, shared)
                     |
      +--------------+---------------+
      |                              |
linux/isle-server.sh          windows/IsleServer.ps1
  | install/update -> steamcmd.sh   | install/update -> steamcmd.exe
  | configure -> LinuxServer/*.ini  | configure -> WindowsServer/*.ini
  | run (exec) <- systemd           | Run (watchdog loop) <- Scheduled Task
  | start/stop (watchdog + pid)     | Start/Stop (task or window + pid)
  | backup/restore (tar.gz)         | Backup/Restore (zip, robocopy)
  +--------------+------------------+
                 |
          tools/isle_rcon.py  (save before stop, admin commands)
```

Installers (`linux/install.sh`, `windows/Install.ps1`) handle privileged one-time setup: packages,
user/ACLs, firewall, service registration. After that they hand over to the unprivileged manager.

## 8. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Game update renames ini keys or RCON bytes | `EXTRA_GAME_SESSION_SETTINGS`, `MANAGE_INI_FILES=false`, `rcon raw`; documented in CONFIGURATION.md |
| EOS credentials change | Exposed as `EOS_CLIENT_ID/SECRET` in server.conf |
| SteamCMD is flaky | 3 retries with back-off; the existing build starts if an update fails |
| Distro package names drift | Each package is installed separately with warnings, never fatal; manual fallback documented |
| No graceful signal on Windows | RCON save before close/kill |

## 9. Future ideas

- Discord webhook notifications (start, stop, crash, update available)
- Scheduled restarts with in-game RCON countdown announcements
- Update check that compares the Steam build ID and restarts only when needed
- Docker image and docker-compose example
- Multiple instances on one host (per-instance config and unit names)
