# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.7.0] - 2026-11-07

Planned in [PRD.md](PRD.md) as milestone M12 (requirements CFX-01 to CFX-09, PLG-01 to PLG-07).

### Added
- **Any Game.ini / Engine.ini key** through `config/overrides/{Game,Engine}.ini`, merged into the generated
  files (replace, append, and Unreal `+`/`-`/`!` pass-through), natively and in Docker (read-only mount).
- Annotated key references (`config/reference/`) and override examples (`config/examples/overrides/`).
- Optional keys written only when set: region spawning, weather variation intervals, `NetServerMaxTickRate`.
- **Profiles** (vanilla, realism, casual, hardcore-pvp, friends-private, sandbox, performance) and **22 stackable
  presets**, with `profile`/`preset list|show|apply`. Applying keeps a backup, validates, and rolls back on errors.
- **Admin tools:** `admins`, `whitelist` (including on/off) and `classes` / `ai-classes` (including roster
  presets `all`, `carnivores`, `herbivores`, `no-apex`, `small-only`, `beginner`). They validate SteamID64s and
  class names (`config/classes.txt`) and push whitelist and roster changes live over RCON.
- **Plugin manager** (`plugins list|search|info|install|remove|enable|disable|update|preset|run|config|sources`).
  Standard-library Python, both OSes and runtimes, lifecycle hooks, SHA-256-pinned remote installs, archive
  safety checks, and a third-party code warning. Plugin presets: base, recommended, full.
- First-party plugins: `restart-countdown`, `discord-notify`, `offsite-backup`, `welcome-announcer`.
  `tools/isle_sdk.py` for plugin authors.
- `windows\Manage.bat` to run any command (`Manage.bat Whitelist add <id>`). `IsleServer.ps1` takes command
  arguments directly (`IsleServer.ps1 Admins add <id>`).
- Tests: `tests/test_config_tools.sh`, `tests/test_config_tools.ps1`, `tests/test_plugins.py`, in CI on both OSes.
- `PLUGINS.md`, and CONFIGURATION.md sections on profiles, admin tools and overrides.

### Changed
- Editing `server.conf` as root keeps the file's owner, so a native service user can still read it.

## [1.6.0] - 2026-11-07

Planned in [PRD.md](PRD.md) as milestone M11 (requirement INS-20).

### Added
- **Choose what to keep or delete at uninstall.** Data is grouped as game files (re-downloadable), worlds, backups and
  settings. Flags: `--keep-data`, `--remove-game-files`, `--remove-worlds`, `--remove-backups`, `--remove-settings`,
  `--purge` (Windows: `-KeepData`, `-RemoveGameFiles`, `-RemoveWorlds`, `-RemoveBackups`, `-RemoveSettings`, `-Purge`).
  They can be combined.
- An interactive uninstall menu: keep everything / game files only / game files and worlds / delete everything /
  choose each item. Non-interactive uninstalls with no flag keep everything.
- Deleting worlds, backups or settings needs typed confirmation (`--yes` / `-Yes` to skip) and is refused without a terminal.
  Removing worlds while keeping backups takes a final `theisle-final-*.tar.gz` backup first.
- Safety checks before deleting any folder from `server.conf` (no system, top-level or home folders). In docker mode,
  individual parts are removed inside the `theisle-data` volume.
- The uninstall summary lists what was removed and what was kept. Reinstalling works after any choice.
- Installer cycle test: each data flag, the menu through a pseudo-terminal, the final backup, and a reinstall after
  each choice. Windows CI: data-switch validation, refusal without `-Yes`, game-files-only and worlds-with-final-backup.

## [1.5.0] - 2026-11-07

Planned in [PRD.md](PRD.md) as milestone M10 (requirement INS-19).

### Added
- **Reinstall with retained data, in either mode.** A Docker reinstall reuses the kept `theisle-data` volume and says
  so. If the volume has no world, a retained native world is imported. A native reinstall imports the world from the
  retained volume (with or without a container) when the native server has none. An existing world is never
  overwritten. The installer prints where the other world is instead. Turn the import off with `--no-import` / `-NoImport`.
- The installer cycle test covers importing in both directions, volume reuse after uninstall, reinstalling native from a
  container-less retained volume, the "never overwrite" rule, `--no-import`, and "nothing imported" after a purge.

### Changed
- Switching modes now moves the world automatically (it used to only print a restore command).

## [1.4.0] - 2026-11-07

Planned in [PRD.md](PRD.md) as milestone M9 (requirements INS-13 to INS-18).

### Added
- **Both installers support native and Docker modes**, with `--native` / `--docker` (Linux) and `-Native` / `-Docker`
  (Windows, also through `Install.bat`). With no flag they ask (1 = native, 2 = docker). Non-interactive runs use the
  previous mode, or native on a first install.
- **Safe mode switching:** re-running the installer with the other mode stops and disables the old one (data kept),
  carries `server.conf` over, takes a backup of the old world and prints the `restore` command to move it.
- **Uninstall / reinstall:** uninstall keeps world data, settings and backups and remembers the mode, so running the
  installer again simply reinstalls. Without a mode flag, uninstall removes whatever is installed.
- **Purge:** `--uninstall --purge` / `-Uninstall -Purge` also deletes server files, backups, settings, the Docker volume
  and (Linux) the service user. It asks you to type `yes` (or pass `--yes` / `-Yes`) and refuses when it can't ask.
- Install state in `/etc/theisle-server/install.state` (Linux) and `<InstallRoot>\install-state.txt` (Windows).
- `Restore.bat`. `restore` accepts `.zip` and `.tar.gz` in both runtimes on Windows (repacked for the container as needed).
- `tests/installer-cycle.sh` end-to-end installer test and a CI `installer-cycle` job. Windows CI covers installer
  argument handling, uninstall and purge, and cross-format restore.

### Changed
- Docker compose project and volume names are fixed (`theisle`, `theisle-data`). The Linux installer copies a pre-1.4
  `<folder>_theisle-data` volume over once.
- Linux docker mode installs the scripts to `/opt/theisle-scripts` (it used to run from the clone).
- The Linux native installer writes resolved `STEAMCMD_DIR`/`SERVER_DIR`/`BACKUP_DIR` into `server.conf`, so `sudo isle-server`
  and `sudo -u theisle isle-server` see the same paths. The native installer always sets `RUNTIME=native`.

### Fixed
- Restoring a host backup into a fresh Docker install failed because `/data/backups` didn't exist yet (both launchers).
- The Windows scripts used `$env:TEMP`, which isn't set in every environment. They now use the .NET temp path.

## [1.3.0] - 2026-11-07

Planned in [PRD.md](PRD.md) as milestone M8 (requirements LCH-01 to LCH-08).

### Added
- **The launcher supports native and Docker runtimes.** `RUNTIME=native|docker` in `server.conf`, overridden with
  `isle-server.sh --docker|--native`, `IsleServer.ps1 -Runtime Docker|Native` (so the `.bat` launchers work too), or
  `ISLE_RUNTIME`. Every command (install, update, validate, check, configure, start, stop, restart, status, run, logs,
  backup, restore, rcon, save, info, version) works in both modes, with the same exit codes.
- The host `server.conf` drives the container through compose `env_file` / `--env-file` (including port mappings).
  The RCON password is generated into the host file.
- `DOCKER_BUILD` / `DOCKER_IMAGE` settings for using a prebuilt or registry image, plus `PUID` / `PGID` in `server.conf`.
- `install.sh --docker` (checks Docker, enables the daemon at boot, builds, links `isle-server`) and
  `install.sh --docker --uninstall`. `Install.ps1 -Docker` for Docker Desktop.
- `check` validates `RUNTIME`, `DOCKER_BUILD` and `PUID`/`PGID`.
- CI: a launcher-in-docker-mode test on Linux, and docker-mode Info/Check/error tests on Windows.

### Changed
- The container entrypoint always runs its manager natively and pins `STEAMCMD_DIR`/`SERVER_DIR`/`BACKUP_DIR` to `/data`.
  With more than 8 env overrides it logs a count instead of every key.

## [1.2.0] - 2026-11-07

Planned in [PRD.md](PRD.md) as milestone M7 (requirements DKR-01 to DKR-10).

### Added
- **Docker support**
  - `docker/Dockerfile`: Debian bookworm-slim (`linux/amd64`) with the SteamCMD 32-bit libraries, Python and tini.
    The game downloads into the `/data` volume and isn't baked into the image.
  - `docker/entrypoint.sh`: saves env vars named like `server.conf` keys into `/data/config/server.conf`, generates
    an RCON password, remaps the user to `PUID`/`PGID`, fixes `/data` ownership, drops root with `setpriv`, validates
    the config, and on `docker stop` saves via RCON before stopping the server.
  - `docker/isle-server`: `docker exec` wrapper that drops to the `/data` owner. Points `start`/`stop`/`restart`
    to `docker compose`.
  - `docker-compose.yml`: game UDP/TCP and queue ports, RCON bound to localhost only, a named volume,
    `stop_grace_period: 90s` and `restart: unless-stopped`.
  - `HEALTHCHECK` using `isle-server status`, with a 30-minute start period for the first download.
  - `DOCKER.md` guide, and a CI `docker` job (hadolint, build, size limit, fake-server smoke test for env overrides,
    health, non-root uid, exec, backup, graceful stop, volume persistence, and bad-config failure).

### Changed
- `isle-server.sh run` writes its PID file before `exec`, so `status` works in foreground, systemd and Docker modes.
- `status` no longer prints an empty watchdog PID.

## [1.1.0] - 2026-11-07

The scope for this release was planned in [PRD.md](PRD.md) (milestone M5).

### Added
- `check` / `Check` command that validates `server.conf` (PRD CFG-05). It reports invalid or colliding
  ports, non-boolean flags, non-numeric multipliers, an empty RCON password while RCON is enabled, and missing
  EOS keys. It warns about malformed SteamID64s, an empty server name, and an empty whitelist. `configure`, `run`,
  `start` and `install` run it automatically and won't launch with errors.
- `version` / `Version` command and a top-level `VERSION` file. `info` also shows the version (CLI-03).
- The Linux `install` command generates a random RCON password when none is set, as Windows already did.
- CI: positive and negative `check` tests on both OSes, and an update-while-running test on Linux.

### Changed
- Linux `update`, `validate`, `install` and `restore` refuse to run while the server is running. This uses the
  PID files, systemd and the process list (UPD-03, now the same as Windows).
- Re-running either installer while the server is running stops it, updates, and starts it again.
- Linux help text now lists every command (CLI-02).
- PRD rewritten as the planning source of truth, with requirement IDs, acceptance criteria and a traceability matrix.

### Fixed
- `install.sh` didn't escape backslashes when writing values to `server.conf`.

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

[Unreleased]: https://github.com/kyroskoh/the-isle-dedicated-server/compare/v1.7.0...HEAD
[1.7.0]: https://github.com/kyroskoh/the-isle-dedicated-server/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/kyroskoh/the-isle-dedicated-server/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/kyroskoh/the-isle-dedicated-server/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/kyroskoh/the-isle-dedicated-server/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/kyroskoh/the-isle-dedicated-server/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/kyroskoh/the-isle-dedicated-server/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/kyroskoh/the-isle-dedicated-server/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/kyroskoh/the-isle-dedicated-server/releases/tag/v1.0.0
