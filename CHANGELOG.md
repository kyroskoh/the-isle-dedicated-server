# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-11-07

### Added
- Shared `config/server.conf` that drives both platforms and generates `Game.ini` and `Engine.ini`
  (TIGameSession, TIGameStateBase, Engine.GameSession, EpicOnlineServices).
- **Linux**
  - `linux/install.sh`: installer for apt, dnf, yum, pacman and zypper distros. Installs 32-bit SteamCMD
    libraries, creates the `theisle` service user, sets up the firewall (ufw/firewalld), adds the systemd
    service and daily backup timer, a sudoers rule, and `--uninstall`.
  - `linux/isle-server.sh`: manager with `install`, `update`, `validate`, `configure`, `start`, `stop`,
    `restart`, `status`, `run`, `logs`, `backup`, `restore`, `rcon`, `save` and `info`. Includes a crash watchdog
    when systemd isn't used, and copies `steamclient.so` to `~/.steam/sdk64`.
- **Windows** (10/11, Server 2019/2022/2025, PowerShell 5.1+)
  - `windows/Install.ps1`: self-elevating installer. Installs the VC++ runtime, optional Python through winget,
    SteamCMD and the server, adds Windows Defender Firewall rules, a boot-time scheduled task (`LOCAL SERVICE`)
    and a daily backup task, and supports `-Uninstall`.
  - `windows/IsleServer.ps1`: manager with the same commands as the Linux script, plus `Firewall` and
    `InstallService`/`RemoveService`.
  - `.bat` launchers: Install, Start, Stop, Restart, Update, Backup, Status and Console.
- `tools/isle_rcon.py`: cross-platform RCON client for Evrima, standard library only.
- RCON `save` before every scripted stop and backup, and an auto-generated random RCON password.
- Documentation: README, INSTALL, CONFIGURATION, TROUBLESHOOTING, PRD, SECURITY, CONTRIBUTING and LICENSE.
- GitHub Actions lint and smoke-test workflow (ShellCheck, PowerShell 5.1 parser, PSScriptAnalyzer).

[Unreleased]: https://github.com/kyroskoh/the-isle-dedicated-server/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/kyroskoh/the-isle-dedicated-server/releases/tag/v1.0.0
