# Product Requirements Document: The Isle Dedicated Server Scripts

| | |
|---|---|
| **Document version** | 1.4 |
| **Product version** | 1.6.0 (planned), 1.5.0 (released) |
| **Status** | Approved. This is the source of truth for scope and acceptance |
| **Owner** | kyroskoh |
| **Last updated** | 2026-11-07 |

This PRD defines **what** the toolkit must do and **how we know it's done**. All code, docs and
tests trace back to a requirement ID here (see [§12 Traceability](#12-traceability-matrix)).
Change the PRD first, then the code.

---

## 1. Overview

A free, open-source toolkit that turns a clean Windows or Linux machine into a working
**The Isle – Evrima** dedicated server with one command. It then keeps the server running:
updates, restarts, crash recovery, backups and admin (RCON) commands, all driven by one shared
configuration file.

## 2. Problem statement

Hosting Evrima by hand means you have to:

1. Install SteamCMD and the 32-bit runtime libraries it needs. Package names differ on every Linux distro.
2. Know the Steam app ID (`412680`) and the `evrima` beta branch, and know that Linux needs `steamclient.so` in `~/.steam/sdk64`.
3. Write `Game.ini` and `Engine.ini` from scratch, including the Epic Online Services (EOS) credentials
   the server needs to appear in the in-game browser.
4. Open the right ports: UDP game port and TCP queue port public, RCON private.
5. Keep the process alive through crashes and reboots, and update it after every game patch.
6. Stop it without losing player progress.

Community guides (for example the XGamingServer Evrima guide) cover the first run on one OS. They don't
cover ongoing operation or offer a single workflow for both Windows and Linux.

## 3. Goals and non-goals

### 3.1 Goals

| ID | Goal | Success metric |
|---|---|---|
| G1 | One-command install | On a clean VM of each Tier-1 OS (§5), the installer finishes with no manual steps and the server reaches the "listening" state |
| G2 | One configuration for both OSes | The same `server.conf` produces equivalent `Game.ini` and `Engine.ini` on Windows and Linux |
| G3 | Unattended operation | The server starts at boot and is back within 60 s of a crash |
| G4 | No progress loss on routine operations | Every scripted stop, restart, update and backup asks the server to save via RCON first |
| G5 | Secure by default | Runs without root/admin rights, RCON not exposed, random RCON password, config readable only by its owner |
| G6 | Few dependencies | Linux: bash + coreutils. Windows: built-in PowerShell 5.1. Python 3 only for RCON features |
| G7 | Fail early on bad config | Invalid settings are reported with the key name **before** the server launches |

### 3.2 Non-goals (v1.x)

- Web panel or GUI
- Kubernetes manifests or Helm charts (the Docker image (§6.10) can be used as a base)
- Mod or workshop management
- Treating the Legacy branch as a target (it works with `STEAM_BRANCH=` but isn't tested)
- ARM or musl (Alpine) hosts. The game server binary is x86_64 glibc only
- Several server instances on one host (see §15)

## 4. Users and user stories

| Persona | Context | Needs |
|---|---|---|
| **P1 Hobby admin** | Home PC, Windows 10/11, hosting for friends | Double-click install and start, no command line |
| **P2 Community admin** | Rented VPS (Ubuntu, Debian or Rocky) with 50–150 players | systemd, backups, RCON, auto-update |
| **P3 Infra tinkerer** | Windows Server 2019–2025 (incl. Core) or a less common distro | Readable, changeable scripts with no hidden behaviour |

| ID | As a… | I want to… | So that… |
|---|---|---|---|
| US-1 | P1 | double-click an installer and get a running server | I don't need to learn SteamCMD |
| US-2 | P1/P2 | edit one well-commented file to change name, password, admins and gameplay | I don't hand-edit Unreal ini files |
| US-3 | P2 | have the server start at boot and restart after a crash | it runs while I'm asleep |
| US-4 | P2 | update the game with one command, or automatically on restart | patches don't need manual steps |
| US-5 | P2 | take daily backups and restore one | a bad patch or griefing can be rolled back |
| US-6 | P2 | send announcements, kicks, bans and saves from the shell | I can moderate without joining the game |
| US-7 | P1/P2 | be told clearly when a setting is wrong | I don't wonder why the server isn't listed |
| US-8 | P3 | use the same commands on Windows and Linux | my runbooks work on both |
| US-9 | P3 | uninstall cleanly while keeping my data | I can migrate or rebuild safely |
| US-10 | P1/P2 | use the **same launcher commands and `server.conf`** whether the server runs natively or in Docker | I can switch runtimes without learning a second workflow |
| US-11 | P1/P2 | choose native or Docker when I install, and switch later by re-running the installer | I'm not locked into my first choice |
| US-12 | P1/P2/P3 | uninstall and later reinstall (or wipe everything and start fresh) | a broken or abandoned setup can always be recovered |
| US-13 | P1/P2 | choose at uninstall what to keep and what to delete (game files, worlds, backups, settings) | I can free disk space without losing my world, or wipe only what I want |

## 5. Platform support

| Tier | Platform | Meaning |
|---|---|---|
| **1** | Windows 10 22H2, Windows 11, Windows Server 2019 / 2022 / 2025 (Desktop + Core) | Fully supported. Tested by CI on the parser, linter and smoke level, plus the manual checklist (§10.2) |
| **1** | Ubuntu 22.04/24.04, Debian 12, Rocky/Alma 9, Fedora (current) | Fully supported. Tested by CI and the manual checklist |
| **1** | Docker Engine 24+ / Docker Desktop (Windows, macOS, Linux) on an **x86_64** host, Linux containers | Fully supported. Image built and smoke-tested in CI (§6.10) |
| **2** | Arch/Manjaro/EndeavourOS, openSUSE Leap/Tumbleweed, RHEL 8/9, Mint, Pop!_OS | Installer supports them. Tested by the community |
| **3** | Other x86_64 glibc distros | Manager works. Install dependencies manually (INSTALL.md) |
| ✗ | Alpine/musl, ARM, 32-bit (including Docker on ARM hosts such as Apple Silicon, except through slow, unsupported amd64 emulation) | Rejected with a clear message |

## 6. Functional requirements

Priority: **M** = must, **S** = should, **C** = could.

### 6.1 Installation (INS)

| ID | Pri | Requirement | Acceptance criteria |
|---|---|---|---|
| INS-01 | M | Linux installer detects the distro and installs the dependencies (curl/wget, tar, python3, CA certs, 32-bit glibc/libgcc/libstdc++) | Works with apt, dnf, yum, pacman (turns on `[multilib]` and backs up `pacman.conf`) and zypper. A package that fails to install gives a warning, not a fatal error. Alpine exits with an explanation |
| INS-02 | M | Linux installer creates an unprivileged service user (default `theisle`) | User exists with its own home. The server never runs as root |
| INS-03 | M | Windows installer self-elevates and checks the OS | Shows a UAC prompt. Refuses 32-bit Windows. Warns on builds older than 17763 |
| INS-04 | M | Windows installer installs the Visual C++ 2015-2022 x64 runtime if missing | Checks the registry first. Exit codes 0, 1638 and 3010 count as success |
| INS-05 | M | Both install SteamCMD from Valve's official URL | Skipped if already present |
| INS-06 | M | Both install the server: app `412680`, branch from config (default `evrima`) | Server executable present afterwards. SteamCMD retried up to 3 times |
| INS-07 | M | Linux places `steamclient.so` in `~/.steam/sdk64` | File present after install and after every update |
| INS-08 | M | Installers copy the scripts to a stable location and create `server.conf` from the example | Linux: `/home/<user>/theisle-scripts`. Windows: `<root>\scripts`. An existing `server.conf` is never overwritten |
| INS-09 | M | Installers generate a random RCON password if none is set | 24 characters, alphanumeric, from a secure RNG |
| INS-10 | S | Windows installer installs Python 3 with winget when it's available | Skipped with a warning when winget is missing (Server Core) |
| INS-11 | M | Installers are idempotent | Re-running keeps the config and data and updates the scripts |
| INS-12 | M | Installers have an uninstall mode | Removes services, tasks, sudoers rule and firewall rules. Keeps all files and the user |
| INS-13 | M | **Installers offer both modes** | Linux `install.sh --native\|--docker`, Windows `Install.ps1 -Native\|-Docker` (and `Install.bat` with the same switches). With neither flag on an interactive terminal, ask: 1 = native, 2 = docker (default: previous mode, else native). Non-interactive runs use the previous mode, else native. The installer always writes the chosen `RUNTIME` into `server.conf` |
| INS-14 | M | **Install state is recorded** | Linux `/etc/theisle-server/install.state`, Windows `<InstallRoot>\install-state.txt`: mode, scripts dir, user, version, date. Uninstall and mode switches read it |
| INS-15 | M | **Switching modes is safe** | Installing docker over native stops and disables the native service/task. Installing native over docker stops and removes the container. Data is kept on both sides, and settings carry over (the previous `server.conf` seeds the new one). The installer prints how to move the world (backup → restore) |
| INS-16 | M | **Reinstall after uninstall** | `uninstall` followed by `install` (same or other mode) succeeds with no manual cleanup and reuses kept data. Uninstall keeps the state file with `STATUS=uninstalled`, so a reinstall without a flag uses the previous mode. Uninstall without a mode flag removes whatever is installed (both modes if both are present) |
| INS-17 | M | **Purge** | `--uninstall --purge` / `-Uninstall -Purge` also deletes server files, backups, the docker volume, the scripts copy and (Linux) the service user. It asks for confirmation unless `--yes` / `-Yes` is given. After a purge, a reinstall starts from scratch |
| INS-18 | M | **Stable Docker identity** | Compose project `theisle` and volume `theisle-data` are fixed names, so a reinstall from another folder or clone finds the same world |
| INS-19 | M | **Reinstall with retained data** | A reinstall uses the world kept by an earlier uninstall, in **either** mode. Docker reinstall: reuses volume `theisle-data` and says so. If the volume has no world but a retained native world exists, it is imported. Native reinstall: if the native server has no world but `theisle-data` holds one (with or without a container), it is exported to the native backups folder and restored. An existing world is never overwritten (the installer prints the restore command instead). `--no-import` / `-NoImport` turns this off. "World" means `TheIsle/Saved` with anything besides `Config`, `Logs` and `Crashes` |
| INS-20 | M | **Choose what to keep at uninstall** | Data is split into: **game files** (server install, SteamCMD, Docker image: re-downloadable), **worlds** (`TheIsle/Saved`), **backups**, **settings** (`server.conf`, scripts copy). Flags: `--keep-data`, `--remove-game-files`, `--remove-worlds`, `--remove-backups`, `--remove-settings`, `--purge` (all of them + service user + Docker volume). Windows: `-KeepData`, `-RemoveGameFiles`, `-RemoveWorlds`, `-RemoveBackups`, `-RemoveSettings`, `-Purge`. With no data flag on an interactive terminal, a menu offers: 1 keep everything (default), 2 remove game files only, 3 remove game files + worlds (keep backups and settings), 4 delete everything, 5 choose each item. Non-interactive with no flag keeps everything. Removing worlds, backups or settings needs typed confirmation unless `--yes` / `-Yes`, and is refused when it can't ask. Removing worlds while keeping backups takes a final backup first. Paths from `server.conf` are only deleted after safety checks (absolute, not a system or top-level directory). A summary lists what was kept and removed, and a reinstall works after any choice |

### 6.2 Configuration (CFG)

| ID | Pri | Requirement | Acceptance criteria |
|---|---|---|---|
| CFG-01 | M | One `KEY=value` file shared by both OSes | Same parsing rules everywhere: `#` comments, optional quotes, CRLF tolerated, unknown keys ignored |
| CFG-02 | M | The config file is **parsed, never executed** | No `source` or `Invoke-Expression`. Values with `$()` stay literal |
| CFG-03 | M | Generate `Game.ini` (`TIGameSession`, `TIGameStateBase`, `Engine.GameSession`) and `Engine.ini` (`EpicOnlineServices`) | Output matches CONFIGURATION.md. List keys become one line per entry |
| CFG-04 | M | `MANAGE_INI_FILES` switch | `true`: regenerate on each start and keep `.bak`. `false`: create only if missing |
| CFG-05 | M | **Validate config before launch** (`check` command, also run automatically by `configure`, `run`, `start` and `install`) | Errors (non-zero exit, launch blocked) when: a port isn't 1–65535; game, queue and RCON ports collide; `MAX_PLAYERS` isn't a positive integer; a boolean isn't true/false/yes/no/1/0/on/off; a numeric setting isn't a number; `RCON_ENABLED=true` with an empty password; EOS keys are empty. Warnings when: an admin or whitelist ID isn't a 17-digit SteamID64; the server name is empty |
| CFG-06 | S | Escape hatch for keys the scripts don't know | `EXTRA_GAME_SESSION_SETTINGS` (`|`-separated) and `EXTRA_ARGS` |
| CFG-07 | M | Defaults for every key | An empty or missing key falls back to the documented default |
| CFG-08 | M | Restrictive permissions | Linux `server.conf` and ini files use mode `600` |

### 6.3 Server lifecycle (RUN)

| ID | Pri | Requirement | Acceptance criteria |
|---|---|---|---|
| RUN-01 | M | `start` uses the service if one is installed, otherwise a background watchdog | Linux: `systemctl` (with sudo if needed) or `nohup` + PID files. Windows: scheduled task, or a minimized console |
| RUN-02 | M | `run` runs in the foreground | Linux `exec`s the binary (systemd gets the real PID). Windows runs a watchdog loop |
| RUN-03 | M | Watchdog restarts after a crash when `AUTO_RESTART=true` | Restart within 10 s. A stop flag prevents a restart after an intentional stop |
| RUN-04 | M | Graceful `stop` | RCON save → SIGTERM (Linux) or close-window (Windows) → force kill after `STOP_TIMEOUT` |
| RUN-05 | M | `status` with standard exit codes | 0 = running, 3 = not running |
| RUN-06 | M | `logs` shows the server log, `-f` / `-Follow` tails it | Falls back to journald on Linux when there's no log file |
| RUN-07 | M | Linux manager refuses to run the game as root | Overridable only with `ISLE_ALLOW_ROOT=1` |
| RUN-08 | M | Raise the open-file limit on Linux | `ulimit -n` in the manager. `LimitNOFILE=100000` in the unit |

### 6.4 Service and boot (SVC)

| ID | Pri | Requirement | Acceptance criteria |
|---|---|---|---|
| SVC-01 | M | Linux systemd unit `theisle-server.service` | Enabled at boot, `Restart=on-failure`, runs as the service user, `ExecStop` saves via RCON |
| SVC-02 | M | Windows scheduled task `TheIsleServer` | Runs at startup as `LOCAL SERVICE` by default (or `SYSTEM`), restarts on failure, no time limit |
| SVC-03 | S | Linux sudoers rule so the service user can control only its own unit | Checked with `visudo -c` and removed if invalid |
| SVC-04 | M | Fallback when there's no systemd | Installer warns. The manager's background watchdog works |

### 6.5 Networking and firewall (NET)

| ID | Pri | Requirement | Acceptance criteria |
|---|---|---|---|
| NET-01 | M | Open the game port (UDP+TCP) and the queue port (TCP) | Linux: ufw or firewalld when active, otherwise print the ports. Windows: Defender rules in one group |
| NET-02 | M | RCON stays closed by default | Opened only when `FIREWALL_OPEN_RCON=true` |
| NET-03 | S | Bind to one interface | `MULTIHOME_IP` → `-MultiHome=` |

### 6.6 Updates (UPD)

| ID | Pri | Requirement | Acceptance criteria |
|---|---|---|---|
| UPD-01 | M | `update` / `validate` commands | `validate` re-checks every file |
| UPD-02 | M | Optional update on every start (`UPDATE_ON_START`) | If the update fails, the server starts on the existing build and logs a warning |
| UPD-03 | M | **`update` / `validate` refuse to run while the server is running** (both OSes) | Clear error with exit 1. No partial updates under a live process |

### 6.7 Backup and restore (BAK)

| ID | Pri | Requirement | Acceptance criteria |
|---|---|---|---|
| BAK-01 | M | `backup` archives `TheIsle/Saved` (minus Logs/Crashes) plus `server.conf` | Linux `.tar.gz`, Windows `.zip`. Timestamped name |
| BAK-02 | M | RCON save before backing up a running server | |
| BAK-03 | M | Retention | Keeps the newest `BACKUP_RETENTION` archives. `0` keeps all |
| BAK-04 | M | Scheduled daily backup | systemd timer / scheduled task at 05:00 |
| BAK-05 | M | `restore` | Refuses while running. Moves current data to `Saved.pre-restore-<ts>` first |

### 6.8 RCON (RCN)

| ID | Pri | Requirement | Acceptance criteria |
|---|---|---|---|
| RCN-01 | M | Cross-platform client using only the standard library | Python 3.6+ on both OSes |
| RCN-02 | M | Named commands plus `raw <byte>` | announce, directmessage, serverdetails, wipecorpses, updateplayables, ban, kick, playerlist, save, playerdata, whitelist toggles and add/remove, toggleglobalchat, togglehumans, toggleai, disableaiclasses, aidensity |
| RCN-03 | M | Password never on the command line when called by the managers | Passed through the `ISLE_RCON_PASSWORD` environment variable |
| RCN-04 | M | Manager wrappers `rcon` and `save` | `save` is a warning (not an error) when RCON or Python isn't available |

### 6.9 CLI and usability (CLI)

| ID | Pri | Requirement | Acceptance criteria |
|---|---|---|---|
| CLI-01 | M | The same command set on both OSes (§7) | Names match, case-insensitive on Windows |
| CLI-02 | M | `help` lists **every** public command | Checked against the dispatcher in review |
| CLI-03 | S | `version` command and a `VERSION` file | Prints the script version. `info` shows it too |
| CLI-04 | M | `info` prints the resolved paths, ports and service state | |
| CLI-05 | M | Double-click `.bat` launchers on Windows | Pause at the end unless `ISLE_NOPAUSE` is set. Pass the exit code through |
| CLI-06 | M | Coloured, timestamped output. Colour only on a TTY | |

### 6.10 Container (DKR)

| ID | Pri | Requirement | Acceptance criteria |
|---|---|---|---|
| DKR-01 | M | `linux/amd64` image on Debian stable-slim (glibc) with all runtime deps. The game is **not** baked into the image | `docker build` succeeds. The first start downloads the server into the volume. The image stays under 500 MB |
| DKR-02 | M | One persistent volume `/data` holds the server, SteamCMD, backups and config | Deleting and recreating the container keeps the world, config and backups |
| DKR-03 | M | Configure through environment variables | Any `server.conf` key set as an env var (for example `SERVER_NAME`) overrides the file and is saved to `/data/config/server.conf`. The config is created and the RCON password generated automatically. `check` runs before launch |
| DKR-04 | M | Never runs the game as root | The entrypoint maps `PUID`/`PGID` (default 1000), fixes `/data` ownership, then drops privileges. Also works with `docker run --user` |
| DKR-05 | M | Graceful `docker stop` | SIGTERM → RCON save → SIGTERM to the server → exit within `STOP_TIMEOUT`. Compose sets `stop_grace_period` to at least `STOP_TIMEOUT` + 30 s |
| DKR-06 | M | `HEALTHCHECK` | Healthy while the server process is alive. A start period covers the first download |
| DKR-07 | M | Manager commands inside the container | `docker compose exec theisle isle-server <cmd>` (status, backup, rcon, check, ...) works as root and drops to the service user automatically |
| DKR-08 | M | `docker-compose.yml` | Publishes game UDP+TCP and the queue port. RCON is bound to `127.0.0.1` only. `restart: unless-stopped` |
| DKR-09 | S | Backups | `isle-server backup` writes to `/data/backups`. The compose docs show a host cron example |
| DKR-10 | M | Game updates without rebuilding the image | A container restart updates the game (`UPDATE_ON_START`) |

### 6.11 Launcher runtime modes (LCH)

| ID | Pri | Requirement | Acceptance criteria |
|---|---|---|---|
| LCH-01 | M | `RUNTIME=native\|docker` setting in `server.conf` (default `native`) | `check` rejects any other value |
| LCH-02 | M | Per-command override | Linux: `isle-server.sh --docker\|--native <cmd>` or `ISLE_RUNTIME`. Windows: `-Runtime Docker\|Native` or `ISLE_RUNTIME`. Precedence: flag > env > config |
| LCH-03 | M | Same commands in both modes (Linux and Windows launchers, so `.bat` files work too) | In docker mode: install = build image + create container; start = `compose up -d` (applies config changes); stop, restart, status (exit 0/3), run (foreground), logs [-f], update/validate (refuse while running, then rebuild the image + SteamCMD in a one-off container), configure, backup, restore, rcon, save, check, info, version |
| LCH-04 | M | One config file drives the container | The host `server.conf` goes to the container through compose `env_file` and `--env-file` (ports). Path keys are forced to `/data/...` inside the container. The container always runs its own manager in native mode |
| LCH-05 | M | Secrets stay on the host | In docker mode the launcher generates the RCON password into the **host** `server.conf`, so it's stable across restarts and visible to the admin |
| LCH-06 | M | Clear errors | Missing Docker / compose v2 / daemon gives one actionable message and exit 1. Native-only commands (`Firewall`, `InstallService` on Windows) still work. The root check is skipped in docker mode |
| LCH-07 | M | Installers have a docker mode | Linux `install.sh --docker`: checks Docker, enables the daemon at boot, sets `RUNTIME=docker`, builds. Windows `Install.ps1 -Docker`: checks Docker Desktop (Linux containers), sets `RUNTIME=docker`, builds. No SteamCMD, service user or scheduled task in this mode |
| LCH-08 | S | Prebuilt images | `DOCKER_BUILD=false` + `DOCKER_IMAGE=<ref>` uses an existing or registry image instead of building |

## 7. CLI contract

| Command | Linux (`isle-server.sh`) | Windows (`IsleServer.ps1`) | Exit codes |
|---|---|---|---|
| install | ✅ | ✅ `Install` | 0 / 1 |
| update | ✅ | ✅ `Update` | 0 / 1 (also when running) |
| validate | ✅ | ✅ `Validate` | 0 / 1 |
| check | ✅ | ✅ `Check` | 0 ok/warnings, 1 errors |
| configure | ✅ | ✅ `Configure` | 0 / 1 |
| start / stop / restart | ✅ | ✅ | 0 / 1 |
| status | ✅ | ✅ | 0 running, 3 stopped |
| run | ✅ | ✅ `Run` | server exit code |
| logs [-f] | ✅ | ✅ `Logs [-Follow]` | 0 / 1 |
| backup / restore | ✅ | ✅ (`-Path`) | 0 / 1 |
| rcon / save | ✅ | ✅ (`-RconArgs`) | RCON client code |
| info / version / help | ✅ | ✅ | 0 |
| firewall / service management | `install.sh` | `Firewall`, `RemoveFirewall`, `InstallService`, `RemoveService` | 0 / 1 |

With `RUNTIME=docker` (or `--docker` / `-Runtime Docker`) the **same commands** drive the Docker container
(§6.11). Inside a container every Linux command is also available as
`docker compose exec theisle isle-server <command>`.

## 8. Non-functional requirements

| ID | Area | Requirement |
|---|---|---|
| NFR-01 | Compatibility | Bash 4.2+, GNU coreutils/findutils. Windows PowerShell 5.1 with no PS7-only syntax |
| NFR-02 | Encoding | `.ps1` files are ASCII-only. Line endings enforced by `.gitattributes` (LF for sh/py/conf, CRLF for ps1/bat) |
| NFR-03 | Security | Least privilege (G5). Secrets never passed as process arguments by the managers. `server.conf` git-ignored |
| NFR-04 | Reliability | SteamCMD retried 3 times. Watchdog restart. systemd `Restart=on-failure`. Task `RestartCount` |
| NFR-05 | Observability | All actions logged with timestamps. Console output kept in `.isle-scripts/console.log` (Linux background mode) |
| NFR-06 | Maintainability | Any new config key goes into both renderers + the example + CONFIGURATION.md (CONTRIBUTING.md) |
| NFR-07 | Quality gates | ShellCheck clean, PS 5.1 parser clean, PSScriptAnalyzer (Error) clean, CI smoke tests pass |
| NFR-08 | Transparency | The only downloads are SteamCMD, the VC++ runtime, Python (optional) and the game via SteamCMD |

## 9. Architecture

```
                 config/server.conf  (KEY=VALUE, shared, parsed - never executed)
                          |
        +-----------------+------------------+
        |                                    |
 linux/install.sh (root, one-time)    windows/Install.ps1 (admin, one-time)
   deps, user, firewall, systemd,       VC++, Python, firewall, scheduled
   sudoers -> hands off to:             task, ACLs -> hands off to:
        |                                    |
 linux/isle-server.sh (service user)  windows/IsleServer.ps1 (LOCAL SERVICE / user)
   check -> configure -> run/start      Check -> Configure -> Run/Start
   update (steamcmd.sh)                 Update (steamcmd.exe)
   backup/restore (tar.gz)              Backup/Restore (zip via robocopy)
        |                                    |
        +-----------------+------------------+
                          |
              tools/isle_rcon.py  (save before stop/backup, admin commands)

 docker/Dockerfile (debian:stable-slim + deps + scripts)
   docker/entrypoint.sh (PID 1 via tini): env -> server.conf, PUID/PGID, chown /data,
   drop privileges -> isle-server.sh run (supervised); SIGTERM -> RCON save -> stop
   volume /data = { config/, server/, steamcmd/, backups/ }
```

## 10. Verification plan

### 10.1 Automated (GitHub Actions, `.github/workflows/lint.yml`)

| Job | Checks |
|---|---|
| linux (ubuntu-latest) | ShellCheck. Python compile. Fake-server smoke test: `version`, `check`, `configure`, `start`, `status`, `stop`, `backup`. `check` must fail on a bad port. `update` must fail while running |
| launcher-docker (ubuntu-latest) | Build the image. Seed a fake server. With `RUNTIME=docker` via the Linux launcher: `install`, `start`, `status` = 0, the host `server.conf` setting reaches `Game.ini`, `backup`, `update` refused while running, `stop`, `status` = 3, `restore`, `start` again |
| docker (ubuntu-latest) | hadolint. `docker build`. Run the container with a fake server binary in `/data` and `UPDATE_ON_START=false`. Assert: env override reaches `Game.ini`, health turns `healthy`, `exec isle-server status` returns 0, `docker stop` exits cleanly within the grace period, data survives a new container. A bad env value (`GAME_PORT=99999`) makes the container exit non-zero |
| windows (windows-latest) | PS 5.1 `Parser::ParseFile` on every `.ps1`. PSScriptAnalyzer (Error). Smoke test: `Version`, `Check`, `Configure`, `Info`, `Backup`. `Check` must fail on a bad port |

| installer-cycle (ubuntu-latest, root) | `tests/installer-cycle.sh`: native install (`--no-deps`, a fake `steamcmd.sh` placed in `STEAMCMD_DIR`, so no test hooks in the product) → uninstall → reinstall → switch to docker → switch back → `--uninstall --purge --yes` → reinstall. Each step checks the state file, `RUNTIME`, and that only one mode is active |

### 10.2 Manual release checklist (per Tier-1 OS, real game server)

1. Clean VM → run the installer → the server appears in the in-game browser within 5 minutes.
2. Join, change something in-world, run `stop` → the change survives `start`.
3. Kill the server process → it's back within 60 s.
4. Reboot → the server is running with nobody logged in.
5. `backup`, then `restore` the archive → the world state matches.
6. `rcon announce test` → the message shows in game.
7. Uninstall → no services, tasks or firewall rules left. Data still present.
8. Docker: `docker compose up -d` on a clean x86_64 host → listed in the browser. `docker compose down && up -d` → world preserved.

## 11. Delivery plan

| Milestone | Scope | Status |
|---|---|---|
| M0 Requirements | This PRD | ✅ Done |
| M1 Linux core | INS-01/02/05–09/11/12, CFG-01–04/06–08, RUN-*, SVC-01/03/04, NET-*, UPD-01/02, BAK-* | ✅ Done (v1.0.0) |
| M2 Windows core | INS-03–06/08–12, CFG-01–04/06/07, RUN-01–06, SVC-02, NET-*, UPD-01–03, BAK-* | ✅ Done (v1.0.0). Real-hardware run pending (§10.2) |
| M3 RCON | RCN-* | ✅ Done (v1.0.0). Mock-tested only |
| M4 Docs and CI | README, INSTALL, CONFIGURATION, TROUBLESHOOTING, SECURITY, CONTRIBUTING, CHANGELOG, LICENSE, CI | ✅ Done (v1.0.0) |
| M5 Hardening (v1.1.0) | CFG-05 config validation, UPD-03 on Linux, CLI-02 help completeness, CLI-03 version | ✅ Done (v1.1.0) |
| M6 Field validation | §10.2 checklist on each Tier-1 OS | ⏳ Planned. Needs real hosts |
| M7 Docker (v1.2.0) | DKR-01 – DKR-10: Dockerfile, entrypoint, compose file, CI job, DOCKER.md | ✅ Done (v1.2.0). Full image build verified in CI only |
| M8 Launcher runtime modes (v1.3.0) | LCH-01 – LCH-08: native/docker in both launchers and installers, compose `env_file`, CI job | ✅ Done (v1.3.0). Windows docker mode tested with PowerShell 7 on Linux; Docker Desktop field test pending (M6) |
| M9 Installer modes & reinstall (v1.4.0) | INS-13 – INS-18: mode prompt and flags, install state, safe mode switching, uninstall/reinstall/purge, fixed compose names, CI reinstall cycle | ✅ Done (v1.4.0). Linux cycle verified locally (no systemd) and in CI. Windows installer covered by CI for arguments, uninstall and purge only |
| M10 Reinstall with retained data (v1.5.0) | INS-19: import retained worlds across modes on reinstall, both installers, CI | ✅ Done (v1.5.0). Linux verified by the cycle test. Windows import paths parse-checked only (they need Docker Desktop with Linux containers) |
| **M11 Uninstall data choices (v1.6.0)** | **INS-20**: keep/remove per data category, menu, safety backup, both installers, CI | 🔜 In progress |

## 12. Traceability matrix

| Req | Implementation | Verification | Status |
|---|---|---|---|
| INS-01 | `linux/install.sh` `install_deps` | Manual §10.2 | Done, field test pending |
| INS-02 | `linux/install.sh` user section | Manual | Done |
| INS-03 | `windows/Install.ps1` elevation + OS check | Parser CI, manual | Done, field test pending |
| INS-04 | `IsleServer.ps1` `Install-VcRedist` | Manual | Done, field test pending |
| INS-05/06 | `install_steamcmd`/`update_server`, `Install-SteamCmd`/`Update-Server` | Manual | Done, field test pending |
| INS-07 | `isle-server.sh` `link_steamclient` | Manual | Done |
| INS-08/09/11 | both installers | Manual | Done |
| INS-10 | `Install.ps1` Python section | Manual | Done |
| INS-12 | `install.sh --uninstall`, `Install.ps1 -Uninstall` | Manual | Done |
| INS-13/14 | `install.sh` (`choose_mode`, `write_state`), `Install.ps1` (`Select-Mode`, `Write-InstallState`) | CI (non-interactive default, flags) | Done (v1.4) |
| INS-15 | `install.sh` `retire_native`/`retire_docker`, `Install.ps1` equivalents | CI (Linux switch cycle), manual | Done (v1.4) |
| INS-16/17 | uninstall paths in both installers | CI (Linux: full cycle; Windows: clean uninstall, purge refusal, purge -Yes) | Done (v1.4) |
| INS-18 | `docker-compose.yml` `name:` + volume `name:` | CI | Done (v1.4) |
| INS-19 | `install.sh` (`volume_has_world`, `export_volume_world`, `native_has_world`), `Install.ps1` equivalents | CI (Linux cycle steps 4-8 check world markers), manual (Windows) | Done (v1.5) |
| INS-20 | `install.sh` (`choose_removals`, `remove_native_data`, `remove_docker_data`, `safe_rm`), `Install.ps1` equivalents | CI (Linux cycle: each flag, menu via a pseudo-terminal, safety backup, reinstall after each), Windows CI (flag validation, refusal) | **Planned v1.6** |
| CFG-01/02/07 | `load_config`, `Import-ServerConfig` | CI smoke | Done |
| CFG-03/04 | `render_*_ini`/`configure`, `Get-*Ini`/`Set-ServerConfig` | CI smoke (grep sections) | Done |
| CFG-05 | `check_config` / `Test-ServerConfig`, called by configure/run/start/install | CI smoke (positive + negative) | Done (v1.1) |
| CFG-06/08 | renderers, `write_ini` chmod | Review | Done |
| RUN-01–08 | `cmd_*` / `Invoke-*` | CI smoke (Linux start/stop), manual | Done |
| SVC-01–04 | unit files in `install.sh`, `Install-ServerService` | Manual | Done |
| NET-01–03 | `firewall_rules`, `Set-Firewall`, `server_args` | Manual | Done |
| UPD-01/02 | `update_server`, `Update-Server`, `prepare_launch`/`Invoke-Run` | Manual | Done |
| UPD-03 | Windows dispatcher; Linux `require_stopped` (PID files, systemd, pgrep) | CI smoke (Linux), review | Done (v1.1) |
| BAK-01–05 | `cmd_backup`/`cmd_restore`, `Invoke-Backup`/`Invoke-Restore`, timers | CI smoke | Done |
| RCN-01–04 | `tools/isle_rcon.py`, `cmd_rcon`/`cmd_save`, `Invoke-PyRcon` | Mock test, manual | Done, field test pending |
| CLI-01/04/05/06 | managers, `.bat` launchers | Review | Done |
| CLI-02 | Usage headers list every dispatcher command | Review | Done (v1.1) |
| CLI-03 | `VERSION` file, `version` / `Version` commands, shown in `info` | CI smoke | Done (v1.1) |
| DKR-01/02 | `docker/Dockerfile`, `/data` volume | CI docker build + volume reuse | Done (v1.2) |
| DKR-03 | `docker/entrypoint.sh` env → `server.conf` | CI (env reaches Game.ini, bad value fails) | Done (v1.2) |
| DKR-04 | entrypoint PUID/PGID + `setpriv` | CI (process uid ≠ 0) | Done (v1.2) |
| DKR-05 | entrypoint TERM trap, compose `stop_grace_period` | CI (`docker stop` exit) | Done (v1.2) |
| DKR-06 | Dockerfile `HEALTHCHECK` | CI (healthy) | Done (v1.2) |
| DKR-07 | `docker/isle-server` wrapper | CI (`exec isle-server status`) | Done (v1.2) |
| DKR-08/09/10 | `docker-compose.yml`, DOCKER.md | Review, manual §10.2-8 | Done (v1.2) |
| LCH-01/02 | `resolve_runtime` (Linux), `Get-Runtime` (Windows), `check_config`/`Test-ServerConfig` | CI (bad value rejected) | Done (v1.3) |
| LCH-03 | `docker_*` dispatch in `isle-server.sh`, `Invoke-Docker*` in `IsleServer.ps1` | CI launcher-docker job (Linux), parser (Windows) | Done (v1.3) |
| LCH-04 | `docker-compose.yml` `env_file`, entrypoint path/runtime forcing | CI launcher-docker (setting reaches Game.ini) | Done (v1.3) |
| LCH-05/06 | launchers | CI, review | Done (v1.3) |
| LCH-07 | `install.sh --docker`, `Install.ps1 -Docker` | Manual | Done (v1.3) |
| LCH-08 | compose `image:`, `--no-build` | CI (local image, `DOCKER_BUILD=false`) | Done (v1.3) |

## 13. Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| A game patch renames ini keys or changes RCON bytes | Medium | Medium | `EXTRA_GAME_SESSION_SETTINGS`, `MANAGE_INI_FILES=false`, `rcon raw`. Documented |
| EOS credentials rotate | Low | High (server not listed) | `EOS_CLIENT_ID`/`SECRET` in config. `check` errors when empty |
| SteamCMD is flaky | High | Low | 3 retries. Start the existing build if the update fails |
| Distro package names drift | Medium | Low | Per-package, non-fatal installs. Manual fallback in INSTALL.md |
| No graceful exit signal for a detached Windows process | Certain | Medium | RCON save before close or kill |
| Windows scripts not yet run on real hardware | — | Medium | CI parser, linter and smoke on windows-latest. M6 field validation |
| Docker NAT hides the public IP or port from EOS | Medium | High (not listed) | Host and container ports must be the same. `network_mode: host` documented as a fallback |
| Wrong volume ownership (bind mounts, rootless Docker) | Medium | Medium | PUID/PGID, chown on start, `--user` path |

## 14. Assumptions and open questions

| # | Item | Current assumption | Resolution |
|---|---|---|---|
| Q1 | Reference guide (xgamingserver.com) wasn't reachable when this was written | Values follow the commonly documented Evrima setup (app 412680, `evrima`, ports 7777/10000/8888) | Owner to compare with the guide. Changes go into `server.conf.example` |
| Q2 | Section holding `AdminsSteamIDs`/`WhitelistIDs` | Written to both `TIGameSession` and `TIGameStateBase` | Confirm on a live server (M6) |
| Q3 | RCON command bytes | Community-documented values | Confirm on a live server (M6) |
| Q4 | Does Evrima need TCP on the game port? | Opened to be safe | Confirm (M6), then close it if not needed |
| Q5 | Does the server register the right public address with EOS from Docker bridge networking? | Yes, when host port = container port | Confirm (M6). Fallback: `network_mode: host` |

## 15. Future (v1.2+)

- Scheduled restarts with RCON countdown announcements (S)
- Restart only when Steam reports a new build ID (S)
- Discord webhook notifications for start, stop, crash and update (C)
- Several instances per host: per-instance config, unit and task names (C)
