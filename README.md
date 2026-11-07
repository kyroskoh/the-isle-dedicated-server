# The Isle (Evrima) Dedicated Server Scripts

Scripts to install, configure, run, update and back up a **The Isle – Evrima**
dedicated server on **Windows** and **Linux**, all driven from one shared config file.

| Platform | Supported | Entry point |
|---|---|---|
| Windows 10 / 11 (x64) | ✅ | `windows\Install.bat` |
| Windows Server 2019 / 2022 / 2025 (Desktop or Core) | ✅ | `windows\Install.bat` |
| Debian / Ubuntu / Mint / Pop!_OS | ✅ | `sudo linux/install.sh` |
| Fedora / RHEL / Rocky / Alma / CentOS Stream | ✅ | `sudo linux/install.sh` |
| Arch / Manjaro / EndeavourOS | ✅ (enables `[multilib]`) | `sudo linux/install.sh` |
| openSUSE Leap / Tumbleweed / SLES | ✅ | `sudo linux/install.sh` |
| Other glibc x86_64 distros | ⚠️ Manual dependencies | `linux/isle-server.sh install` |
| Alpine / musl, ARM | ❌ Not supported (the server is x86_64 glibc only) | — |

## Features

- **One config for both OSes.** `config/server.conf` produces `Game.ini` and `Engine.ini` for you.
- **Installers** that set up the dependencies, SteamCMD, the server (Steam app `412680`, branch `evrima`), firewall rules, and a service that starts at boot.
- **Launchers** for start, stop, restart, status, logs and a console mode.
- **Watchdog** that restarts the server if it crashes. On Linux this is systemd `Restart=on-failure` or the built-in watchdog. On Windows it's a scheduled task plus a watchdog loop.
- **Auto-update** through SteamCMD before each start (optional).
- **Graceful stop.** The scripts save the world over RCON, then stop the server cleanly.
- **Backups** run daily, keep a set number of copies, and can be restored.
- **RCON client** (`tools/isle_rcon.py`). It's pure Python and runs on both OSes: announce, kick, ban, save, playerlist, whitelist and more.
- **Least privilege.** On Linux the server runs as a dedicated `theisle` user. On Windows it runs as `LOCAL SERVICE`.

## Quick start

### Windows

1. Download or clone this repository.
2. Double-click **`windows\Install.bat`** and accept the Administrator prompt.
3. Edit **`C:\TheIsle\scripts\config\server.conf`**: set the server name, admins and so on.
4. Run **`C:\TheIsle\scripts\windows\Restart.bat`**, or reboot. The server starts at boot.

### Linux

```bash
git clone https://github.com/kyroskoh/the-isle-dedicated-server.git
cd the-isle-dedicated-server
sudo ./linux/install.sh            # add --start to start right away
sudo nano /home/theisle/theisle-scripts/config/server.conf
sudo systemctl restart theisle-server
```

Then forward these ports on your router or cloud firewall:

| Port | Protocol | Purpose | Expose publicly? |
|---|---|---|---|
| 7777 | UDP (+TCP) | Game traffic | **Yes** |
| 10000 | TCP | Join queue | **Yes** (if queue enabled) |
| 8888 | TCP | RCON | **No.** Keep it private or behind a VPN |

## Everyday commands

| Task | Linux | Windows |
|---|---|---|
| Start | `sudo systemctl start theisle-server` or `isle-server start` | `Start.bat` / `IsleServer.ps1 Start` |
| Stop (saves first) | `sudo systemctl stop theisle-server` or `isle-server stop` | `Stop.bat` |
| Restart | `isle-server restart` | `Restart.bat` |
| Status | `isle-server status` | `Status.bat` |
| Follow the log | `isle-server logs -f` | `IsleServer.ps1 Logs -Follow` |
| Update the game | `isle-server stop && isle-server update && isle-server start` | `Stop.bat`, then `Update.bat`, then `Start.bat` |
| Backup | `isle-server backup` | `Backup.bat` |
| Restore | `isle-server restore <file.tar.gz>` | `IsleServer.ps1 Restore -Path <file.zip>` |
| RCON announce | `isle-server rcon announce "Restart in 5 min"` | `IsleServer.ps1 Rcon -RconArgs announce,'Restart in 5 min'` |
| Re-generate ini | `isle-server configure` | `IsleServer.ps1 Configure` |
| Paths & settings | `isle-server info` | `IsleServer.ps1 Info` |

On Linux, run `isle-server` as the service user: `sudo -u theisle isle-server <cmd>`.

## Repository layout

```
config/server.conf.example   Shared settings (copied to server.conf by the installers)
linux/install.sh             Root installer: deps, user, SteamCMD, server, firewall, systemd
linux/isle-server.sh         Manager: install/update/start/stop/status/logs/backup/rcon ...
windows/Install.ps1 (.bat)   Elevated installer: VC++ runtime, SteamCMD, server, firewall, task
windows/IsleServer.ps1       Manager with the same commands as the Linux script
windows/*.bat                Double-click launchers (Start, Stop, Restart, Update, Backup, ...)
tools/isle_rcon.py           Cross-platform Evrima RCON client
```

## Documentation

- [INSTALL.md](INSTALL.md): step-by-step installation, manual installs, and uninstalling
- [CONFIGURATION.md](CONFIGURATION.md): every `server.conf` key and the `Game.ini` key it maps to
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md): common problems and fixes
- [PRD.md](PRD.md): product requirements and design
- [CHANGELOG.md](CHANGELOG.md): release history
- [SECURITY.md](SECURITY.md): hardening advice
- [CONTRIBUTING.md](CONTRIBUTING.md): how to contribute
- [LICENSE.md](LICENSE.md): MIT

## References

- Setup approach based on the community guide
  [How to set up a The Isle Evrima dedicated server (XGamingServer)](https://xgamingserver.com/blog/how-to-set-up-a-the-isle-evrima-dedicated-server/).
- [SteamCMD documentation (Valve Developer Wiki)](https://developer.valvesoftware.com/wiki/SteamCMD)

## Disclaimer

This is a community project. It is not affiliated with or endorsed by Afterthought LLC
(the developers of The Isle) or by Valve. "The Isle" is a trademark of its owners. Game
settings change between Evrima updates. If a key stops working, check the official
patch notes and adjust `server.conf` (or use `EXTRA_GAME_SESSION_SETTINGS`).
