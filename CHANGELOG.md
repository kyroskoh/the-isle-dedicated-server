# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.10.0] - 2026-11-08

Planned in [PRD.md](PRD.md) as milestone M15 (LOG-01 to LOG-05, UI-06 to UI-08).

### Added
- **`TIMEZONE=local|utc`** in `server.conf`: one clock for log timestamps and dated file names, in both launchers,
  the installers, the API and the snapshot tool. Docker gets the host's UTC offset for `local`.
- **Log files `KIND_yyyymmdd_hhmmss.log` with rotation** in `LOG_DIR` (default `<scripts>/logs`, Docker `/data/logs`):
  - `launcher_*`: every command that changes something, on Linux and Windows;
  - `server_*`: the game console in watchdog, systemd and Docker mode, still also in the journal and docker logs;
  - `ui_*`: the web UI access log.
  - **Rotation:** a new file starts past `LOG_MAX_SIZE_MB`, and the newest `LOG_RETENTION` files per kind are kept.
    The game's `TheIsle-backup-*.log` follow the same retention.
  - **Commands:** `isle-server logs [-f] [game|server|launcher|ui|list]`, `IsleServer.ps1 Logs launcher|ui|list`.
  - **API:** `GET /api/v1/log-files` and `/log-files/{name}`, and a log picker on the Logs page.
- **Dated names end with `_yyyymmdd_hhmmss`:** `theisle-backup_…`, `theisle-final_…`, `theisle-snapshot_…`,
  `Saved.pre-restore_…`, `Saved.pre-snapshot_…`, `server.conf.bak_…`. Older names are still recognised.
- **Web UI Date & time:** time zone (server, this browser or UTC) and date format, with presets showing the month as
  three letters (`08 Nov 2026, 14:30:05`) and custom patterns with a live preview, saved per browser. Hovering any
  date shows the full timestamp with its zone.
- **Instant peek:** cut-off text (dinosaur names, the server name, ...) shows in full immediately on hover, keyboard
  focus or a tap.
- **Layout audit** `tests/test_ui_overflow.mjs`: long data on every page, dialog and toast at 320–1920 px, on phones
  and tablets in both orientations, in light and dark. CI runs it and `tests/test_ui.mjs` on Chromium, Firefox and
  WebKit.
- `/api/v1/status` reports `timezone`, `utc_offset_minutes` and `zone`.
- **Tests:** `tests/test_logs.py`, `tests/test_logs.ps1`, plus API, date-format and peek tests.

### Changed
- **Responsive layout:**
  - Tables turn into labelled cards based on their own width (container queries, with a fallback).
  - Buttons wrap at word boundaries, long values wrap inside their box, and badges stay whole.
  - Touch screens get 44 px targets, mobile browsers use `dvh` and safe areas, and short landscape screens drop
    the sticky bars.
- **Documentation:** screenshots regenerated with MMM dates, including the Date & time dialog, rotated logs, peek,
  a phone in landscape and a tablet in portrait.

### Fixed
- Text overflowing chips, cards and buttons, mid-word breaks, and sideways page scrolling caused by screen-reader
  cells in tables.
- Two log files rotated within the same second could prune the newest one.

## [1.9.0] - 2026-11-08

Planned in [PRD.md](PRD.md) as milestone M14 (requirements API-01 to API-05, UI-01 to UI-05, DEB-01). Guide: [UI.md](UI.md).

### Added
- **REST API** (`tools/isle_api.py`, Python standard library only) wrapping the launcher. It covers status,
  lifecycle actions as jobs, logs, RCON, settings, admins, whitelist, roster, profiles, presets, plugins and
  snapshots.
  - **OpenAPI 3.1:** the document is at `/openapi.json`, with a self-hosted interactive viewer at **`/docs`**
    ("Try it", curl line, filter).
  - **Conventions:** `/api/v1` versioning, RFC 7807 problem details, `202 Accepted` + job polling, `409` for a
    second lifecycle action, `X-Request-ID`, an access log, and an unauthenticated `/health`.
  - **Settings:** PATCH validates with `check` and rolls back on errors, masks secrets, and refuses machine-specific
    keys.
- **Web UI** at `/`: Dashboard, Settings, Players, Roster, Profiles & presets, Plugins, Snapshots & backups, Logs and
  RCON console.
  - **Look:** a jungle-green and amber palette with light, dark and system themes (system follows the OS live; the
    choice is remembered).
  - **Accessibility:** WCAG AA contrast, keyboard and screen-reader friendly, responsive down to phones, and
    reduced motion respected.
  - **Behaviour:** confirmations for disruptive actions, and live job output and toasts.
- **Security:**
  - Binds to 127.0.0.1 by default.
  - Bearer token in `config/ui-token` (mode 600), compared in constant time.
  - Lockout after 10 wrong tokens per minute.
  - Strict CSP and security headers; no cookies, no CORS by default.
  - 64 KB body limit.
  - Optional TLS (`--cert/--key`) and HSTS.
- **Run it optionally:** `isle-server ui [--host --port --open --cert --key]`, `isle-server ui-token [--rotate]`,
  `IsleServer.ps1 UI` / `UiToken`, and `windows\UI.bat`.
  - **At boot:** `install.sh --ui` (systemd `theisle-ui`, as the service user in native mode) and
    `Install.ps1 -UI` (scheduled task `TheIsleServer-UI`). The service is kept on re-runs and mode switches,
    removed with `--no-ui` / `-NoUI` and on uninstall.
- `UI_HOST` / `UI_PORT` in `server.conf` (`UI_PORT` validated by `check`).
- **Tests:**
  - `tests/test_api.py`: 26 offline tests with a fake launcher, covering auth, lockout, validation, rollback,
    jobs/409, spec covers every route, headers and path traversal.
  - `tests/test_ui.mjs`: Playwright test with 40+ checks, covering sign-in, every page, themes, actions, settings,
    phone layout, `/docs` "Try it", CSP and console errors.
- **Screenshots** of every UI page (light and dark, phone, API docs) in `docs/images/ui/`, shown in README,
  UI.md, CONFIGURATION.md, PLUGINS.md, MIGRATION.md and INSTALL.md. `tests/ui_screenshots.mjs` regenerates them.
- **Debian verification (DEB-01):** every Linux suite also runs on Debian bookworm.
  - New CI job `debian-native` runs a real native install with apt dependencies in `debian:bookworm`
    (`tests/test_native_debian.sh`, including the web UI as the service user).
  - The unit suites also run inside the Debian-based image.

### Fixed
- `isle-server status` returned 0 for a stopped systemd service. It now returns 3 like the other modes.
- With a systemd service, the launcher uses `sudo -n` when there is no terminal, so it never waits for a password.
- `tests/installer-cycle.sh` helpers no longer depend on a removed image (they use `debian:bookworm-slim`).
- Windows CI steps that end with an expected non-zero exit code no longer fail the job.

## [1.8.0] - 2026-11-08

Planned in [PRD.md](PRD.md) as milestone M13 (requirements MIG-01 to MIG-08). Guide: [MIGRATION.md](MIGRATION.md).

### Added
- **Portable snapshots:** `snapshot create|restore|info|list` in both launchers (`IsleServer.ps1 Snapshot ...`).
  One `.tar.gz` format with a manifest, shared by Linux and Windows, native and Docker. Choose the parts (worlds,
  backups, settings, overrides, plugins). Restore merges settings without machine-specific keys, never overwrites a
  world without `--overwrite` (the old world is kept aside), refuses while running (or `--stop`), and refuses unsafe archives.
- **Mode switch data choices** in both installers: `--data copy|move|fresh`, `--carry LIST`, `--overwrite`. Mode
  switches now carry worlds, settings, overrides and plugins through the snapshot engine. `move` clears only what
  was restored and keeps the snapshot as a safety copy.
- **New machine from a snapshot:** `install.sh --from-snapshot FILE` / `Install.ps1 -FromSnapshot FILE`, in either mode.
- `--image REF` / `-Image` to install docker mode from a prebuilt or registry image.
- Python 3 is now installed in both modes (Windows) or when a snapshot needs it (Linux docker mode).
- Tests: `tests/test_snapshot.py`, `tests/test_snapshot.ps1` (including a Linux-made snapshot restored by
  PowerShell), and installer-cycle steps for move, fresh, overwrite and two machine migrations
  (native -> docker and docker -> native via `--from-snapshot`).

### Fixed
- **A server with a working install failed to start when SteamCMD couldn't update** (for example, Steam down):
  the "start the existing build" fallback was cut short by `exit`. A failed SteamCMD download is now also
  reported at once.
- **`start` reported "failed to start" during a long update** (background mode): the watchdog wrote its PID file
  only after the update.
- **On Windows, output from Python tools and Docker couldn't be captured or redirected** (`Out-Host`). It now
  goes through `Write-Host`. Also avoided a Windows PowerShell 5.1 trap where stderr from native tools stops the script.

## [1.7.1] - 2026-11-08

Found by new end-to-end container testing (an RCON-speaking fake server, real `tini`, the real package list).

### Fixed
- **Docker mode changed some `server.conf` values.** Compose expanded `$VARS` (leaking host variables such as
  `$HOME`), collapsed `$$`, and cut off ` #...` as a comment. A server password like `pa$$w0rd #x` silently
  became `pa$w0rd`. Both launchers now give Compose a generated, escaped `config/.compose.env`, so the container
  sees exactly what native mode sees.
- **Restore moved the current world aside before checking the archive.** A wrong file left the server without a
  world. Restore now checks for `Saved/` first and changes nothing if it's missing.
- **The Linux launcher couldn't restore `.zip` backups** (made by native Windows), natively or into Docker. It now
  repacks them.
- **Container logs grew without limit.** They are now capped at 5 × 10 MB.

### Added
- `tests/test_container_e2e.sh` with `tests/fixtures/fake-isle-server.py`, a fake game server that speaks the RCON
  protocol. Runs in CI against the real image. Covers health, the non-root uid, overrides, live whitelist and roster
  pushes, RCON, all plugins against the container, restart-countdown, crash recovery, `.zip` restore, special
  characters in settings, and save-before-SIGTERM.

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

[Unreleased]: https://github.com/kyroskoh/the-isle-dedicated-server/compare/v1.8.0...HEAD
[1.8.0]: https://github.com/kyroskoh/the-isle-dedicated-server/compare/v1.7.1...v1.8.0
[1.7.1]: https://github.com/kyroskoh/the-isle-dedicated-server/compare/v1.7.0...v1.7.1
[1.7.0]: https://github.com/kyroskoh/the-isle-dedicated-server/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/kyroskoh/the-isle-dedicated-server/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/kyroskoh/the-isle-dedicated-server/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/kyroskoh/the-isle-dedicated-server/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/kyroskoh/the-isle-dedicated-server/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/kyroskoh/the-isle-dedicated-server/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/kyroskoh/the-isle-dedicated-server/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/kyroskoh/the-isle-dedicated-server/releases/tag/v1.0.0
