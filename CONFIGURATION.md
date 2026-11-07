# Configuration Reference

All settings live in **`config/server.conf`**, which the installers create from
`config/server.conf.example`. The Linux and Windows scripts share the same file.

Format: `KEY=value`, one per line, `#` for comments, optional double quotes. Lists are
comma-separated. Restart the server after editing.

When `MANAGE_INI_FILES=true` (the default), the scripts regenerate the server's ini files on
every start and keep the previous copy as `*.bak`:

| OS | Path |
|---|---|
| Linux | `<SERVER_DIR>/TheIsle/Saved/Config/LinuxServer/Game.ini` and `Engine.ini` |
| Windows | `<SERVER_DIR>\TheIsle\Saved\Config\WindowsServer\Game.ini` and `Engine.ini` |

If you prefer to edit the `.ini` files by hand, set `MANAGE_INI_FILES=false`. The scripts
then generate them only if they don't exist yet.

## Profiles and presets

**Profiles** are complete play styles. **Presets** are small changes you can stack. Applying either writes
its keys into `server.conf`, keeps a timestamped backup, validates, and rolls back if the result is invalid.
Restart the server afterwards.

| Profile | Style |
|---|---|
| `vanilla` | The standard Evrima defaults |
| `realism` | Slow growth, long days and nights, no global chat |
| `casual` | Fast growth, short nights, more food |
| `hardcore-pvp` | Slow growth, fast corpse decay, 150 players, no global chat |
| `friends-private` | 20 players, whitelist on, no queue |
| `sandbox` | Very fast growth, humans on, no diets or migration |
| `performance` | Fewer AI, plants and players, 30 Hz tick |

Presets: `ai-off`, `ai-low`, `ai-high`, `fast-growth`, `very-fast-growth`, `slow-growth`, `humans-on`,
`humans-off`, `no-migration`, `short-nights`, `long-days`, `static-weather`, `whitelist-on`, `whitelist-off`,
`global-chat-off`, `global-chat-on`, `mutations-off`, `diets-off`, `queue-off`, `more-food`,
`region-spawning`, `replays-off`.

```bash
isle-server profile list
isle-server profile show realism          # current -> new value for every key
isle-server profile apply realism
isle-server preset apply ai-low short-nights fast-growth   # applied left to right
```

Windows: `IsleServer.ps1 Profile apply realism`, `IsleServer.ps1 Preset apply ai-low short-nights`
(or `Manage.bat Profile apply realism`).

Profiles never touch names, passwords or ports. Your own profiles and presets are just `KEY=VALUE` files in
`config/profiles/` and `config/presets/`. The first comment line is the description.

## Admins, whitelist and playable roster

| Linux | Windows | Effect |
|---|---|---|
| `isle-server admins list\|add\|remove <SteamID64...>` | `IsleServer.ps1 Admins add <id...>` | `ADMIN_STEAM_IDS`. Applies on restart |
| `isle-server whitelist list\|add\|remove <id...>\|on\|off` | `IsleServer.ps1 Whitelist add <id...>` | `WHITELIST_IDS` / `WHITELIST_ENABLED`. **Live** via RCON |
| `isle-server classes list\|known\|set\|add\|remove <Class...>\|reset\|preset [roster]` | `IsleServer.ps1 Classes ...` | `ALLOWED_CLASSES`. **Live** via RCON `updateplayables` |
| `isle-server ai-classes list\|known\|set\|add\|remove\|reset` | `IsleServer.ps1 AIClasses ...` | `DISABLED_AI_CLASSES`. **Live** via RCON |

- SteamIDs must be SteamID64s (17 digits starting with `7656119`). Duplicates are dropped.
- Class names are checked against [`config/classes.txt`](config/classes.txt). Unknown names only warn, so new
  species keep working. Edit that file when a patch adds or renames one.
- **Roster presets** live in [`config/rosters/`](config/rosters/): `all`, `carnivores`, `herbivores`,
  `no-apex`, `small-only`, `beginner`.
- When the server is running and RCON is enabled, whitelist and roster changes are also sent live. Otherwise
  they apply on the next start. In docker mode the live change goes through the container.

## Any Game.ini / Engine.ini key (overrides)

Put `Game.ini` and/or `Engine.ini` in `config/overrides/` (or the folder set in `INI_OVERRIDES_DIR`).
They are merged into the generated files on every start:

- `Key=Value` **replaces every generated line** of that key in that section. Repeat the key for lists.
- New keys are added to their section, and new sections are appended.
- Lines starting with `+`, `-` or `!` (Unreal array syntax) pass through unchanged.

Examples: [`config/examples/overrides/`](config/examples/overrides/). Every known key, with its section, default,
`server.conf` key and status: [`config/reference/Game.ini.md`](config/reference/Game.ini.md) and
[`config/reference/Engine.ini.md`](config/reference/Engine.ini.md). In docker mode the folder is mounted
read-only into the container.

### Optional / advanced keys

Written only when set:

| server.conf | ini key | Notes |
|---|---|---|
| `REGION_SPAWNING` | `bUseRegionSpawning` | community-documented |
| `REGION_SPAWN_COOLDOWN` | `bUseRegionSpawnCooldown` | community-documented |
| `REGION_SPAWN_COOLDOWN_SECONDS` | `RegionSpawnCooldownTimeSeconds` | community-documented |
| `WEATHER_MIN_INTERVAL` / `WEATHER_MAX_INTERVAL` | `Min/MaxWeatherVariationInterval` | community-documented |
| `NET_TICK_RATE` | Engine.ini `NetServerMaxTickRate` | Unreal Engine |
| `INI_OVERRIDES_DIR` | (override folder) | default `config/overrides` |

## Validation (`check`)

Run `isle-server check` (Linux) or `IsleServer.ps1 Check` (Windows) after you edit the file.
`configure`, `run`, `start` and `install` run the same checks and won't launch while there are errors.

| Severity | Condition |
|---|---|
| Error | `GAME_PORT`, `QUEUE_PORT` or `RCON_PORT` isn't 1–65535, or two enabled ports are the same |
| Error | `MAX_PLAYERS` isn't a positive integer |
| Error | A true/false setting has another value (allowed: true, false, yes, no, 1, 0, on, off) |
| Error | A multiplier, density or day/night length isn't a number, or a time/retention value isn't a whole number |
| Error | `RCON_ENABLED=true` and `RCON_PASSWORD` is empty |
| Error | `EOS_CLIENT_ID` or `EOS_CLIENT_SECRET` is empty |
| Warning | An `ADMIN_STEAM_IDS` / `WHITELIST_IDS` entry isn't a 17-digit SteamID64 |
| Warning | `SERVER_NAME` is empty, or the whitelist is on with no IDs |

Exit code: `0` = OK (warnings allowed), `1` = errors.

## Runtime

| Key | Default | Description |
|---|---|---|
| `RUNTIME` | `native` | `native` = run on this machine. `docker` = the launcher manages a container ([DOCKER.md](DOCKER.md)) |
| `DOCKER_BUILD` | `true` | Docker: build the image from this repo. `false` = use `DOCKER_IMAGE` as is (pulled if missing) |
| `DOCKER_IMAGE` | `theisle-server:latest` | Docker: image name / reference |
| `PUID` / `PGID` | `1000` | Docker: uid/gid the server runs as inside the container |

To override per command: `isle-server.sh --docker|--native <cmd>`, `IsleServer.ps1 <Cmd> -Runtime Docker|Native`,
or the `ISLE_RUNTIME` environment variable (precedence: flag > env > config).
In docker mode, `STEAMCMD_DIR`, `SERVER_DIR` and `BACKUP_DIR` are ignored. The container always uses `/data`.

## Install and update

| Key | Default | Description |
|---|---|---|
| `STEAMCMD_DIR` | `~/steamcmd` / `C:\TheIsle\steamcmd` | SteamCMD location |
| `SERVER_DIR` | `~/theisle-server` / `C:\TheIsle\server` | Server install directory |
| `BACKUP_DIR` | `~/theisle-backups` / `C:\TheIsle\backups` | Backup destination |
| `STEAM_APP_ID` | `412680` | The Isle Dedicated Server app |
| `STEAM_BRANCH` | `evrima` | Beta branch; empty for public/Legacy |
| `STEAM_BRANCH_PASSWORD` | | Only for password-protected branches |
| `VALIDATE_ON_UPDATE` | `false` | Verify all files on each update |
| `UPDATE_ON_START` | `true` | Run SteamCMD before every start |

## Network

| Key | Default | Description |
|---|---|---|
| `GAME_PORT` | `7777` | Passed as `-Port=`; open UDP (and TCP) |
| `QUEUE_PORT` | `10000` | `QueuePort`; TCP |
| `RCON_PORT` | `8888` | `RconPort`; TCP. Keep it private |
| `MULTIHOME_IP` | | Passed as `-MultiHome=` to bind one interface |
| `FIREWALL_OPEN_RCON` | `false` | Also open RCON in the OS firewall |

## Server settings → `[/Script/TheIsle.TIGameSession]`

| server.conf | Game.ini key | Default |
|---|---|---|
| `SERVER_NAME` | `ServerName` | `My Evrima Server` |
| `MAP_NAME` | `MapName` | `Gateway` |
| `MAX_PLAYERS` | `MaxPlayerCount` (+ `[/Script/Engine.GameSession] MaxPlayers`) | `100` |
| `SERVER_PASSWORD` | `bServerPassword` + `ServerPassword` | empty (public) |
| `QUEUE_ENABLED` | `bQueueEnabled` | `true` |
| `RCON_ENABLED` | `bRconEnabled` | `true` |
| `RCON_PASSWORD` | `RconPassword` | random (installer) |
| `WHITELIST_ENABLED` | `bServerWhitelist` | `false` |
| `GLOBAL_CHAT` | `bEnableGlobalChat` | `true` |
| `ENABLE_HUMANS` | `bEnableHumans` | `false` |
| `DYNAMIC_WEATHER` | `bServerDynamicWeather` | `true` |
| `DAY_LENGTH_MINUTES` | `ServerDayLengthMinutes` | `45` |
| `NIGHT_LENGTH_MINUTES` | `ServerNightLengthMinutes` | `20` |
| `GROWTH_MULTIPLIER` | `GrowthMultiplier` | `1` |
| `CORPSE_DECAY_MULTIPLIER` | `CorpseDecayMultiplier` | `1` |
| `ENABLE_MUTATIONS` | `bEnableMutations` | `true` |
| `ENABLE_DIETS` | `bEnableDiets` | `true` |
| `ENABLE_PATROL_ZONES` | `bEnablePatrolZones` | `true` |
| `ALLOW_RECORDING_REPLAY` | `bAllowRecordingReplay` | `true` |
| `SPAWN_PLANTS` | `bSpawnPlants` | `true` |
| `PLANT_SPAWN_MULTIPLIER` | `PlantSpawnMultiplier` | `1` |
| `SPAWN_AI` | `bSpawnAI` | `true` |
| `AI_DENSITY` | `AIDensity` | `1` |
| `DISABLED_AI_CLASSES` | `DisallowedAIClasses=` (one line each) | empty |
| `ENABLE_MIGRATION` | `bEnableMigration` | `true` |
| `MAX_MIGRATION_TIME` | `MaxMigrationTime` | `5400` |
| `ENABLE_MASS_MIGRATION` | `bEnableMassMigration` | `true` |
| `MASS_MIGRATION_TIME` | `MassMigrationTime` | `43200` |
| `MASS_MIGRATION_DISABLE_TIME` | `MassMigrationDisableTime` | `7200` |
| `ALLOWED_CLASSES` | `AllowedClasses=` (one line each) | empty = all |
| `ADMIN_STEAM_IDS` | `AdminsSteamIDs=` (one line each) | empty |
| `WHITELIST_IDS` | `WhitelistIDs=` (one line each) | empty |
| `EXTRA_GAME_SESSION_SETTINGS` | appended verbatim, `|`-separated | empty |

`AdminsSteamIDs` and `WhitelistIDs` are also written to `[/Script/TheIsle.TIGameStateBase]`,
because different Evrima builds have read them from either section.

Use **SteamID64** values (17 digits, starting with `7656119`). You can look them up on steamid.io.

### Example generated `Game.ini`

```ini
[/Script/TheIsle.TIGameSession]
ServerName=My Evrima Server
MapName=Gateway
MaxPlayerCount=100
bServerPassword=false
ServerPassword=
bQueueEnabled=true
QueuePort=10000
bRconEnabled=true
RconPassword=ChangeMe123
RconPort=8888
bServerWhitelist=false
bEnableGlobalChat=true
bEnableHumans=false
bServerDynamicWeather=true
ServerDayLengthMinutes=45
ServerNightLengthMinutes=20
GrowthMultiplier=1
CorpseDecayMultiplier=1
bEnableMutations=true
bEnableDiets=true
bEnablePatrolZones=true
bAllowRecordingReplay=true
bSpawnPlants=true
PlantSpawnMultiplier=1
bSpawnAI=true
AIDensity=1
bEnableMigration=true
MaxMigrationTime=5400
bEnableMassMigration=true
MassMigrationTime=43200
MassMigrationDisableTime=7200
AdminsSteamIDs=76561198000000001

[/Script/TheIsle.TIGameStateBase]
AdminsSteamIDs=76561198000000001

[/Script/Engine.GameSession]
MaxPlayers=100
```

## Epic Online Services → `Engine.ini`

Evrima servers register through EOS. Without these keys the server starts but doesn't show
up in the server browser.

| server.conf | Engine.ini |
|---|---|
| `EOS_CLIENT_ID` | `[EpicOnlineServices] DedicatedServerClientId` |
| `EOS_CLIENT_SECRET` | `[EpicOnlineServices] DedicatedServerClientSecret` |

The defaults are the public dedicated-server credentials that community guides publish.
Replace them only if the developers announce new values.

## Script behaviour

| Key | Default | Description |
|---|---|---|
| `MANAGE_INI_FILES` | `true` | Regenerate ini files from server.conf on every start |
| `EXTRA_ARGS` | `-log` | Extra command-line arguments for the server |
| `STOP_TIMEOUT` | `60` | Seconds to wait for a graceful exit before killing |
| `AUTO_RESTART` | `true` | Restart after a crash (watchdog mode) |
| `BACKUP_RETENTION` | `10` | Number of backup archives to keep (0 = all) |
| `SAVE_BEFORE_STOP` | `true` | Send RCON `save` before stopping or backing up |

## RCON

`tools/isle_rcon.py` speaks the Evrima binary RCON protocol. It needs Python 3.6+ and no extra packages.

```
isle-server rcon announce "Server restart in 10 minutes"     # Linux wrapper
python3 tools/isle_rcon.py -c config/server.conf playerlist  # direct
python3 tools/isle_rcon.py -P secret kick 76561198000000001,AFK
python3 tools/isle_rcon.py -P secret raw 0x12                # arbitrary command byte
```

Commands: `announce`, `directmessage`, `serverdetails`, `wipecorpses`, `updateplayables`, `ban`,
`kick`, `playerlist`, `save`, `playerdata`, `togglewhitelist`, `addwhitelist`, `removewhitelist`,
`toggleglobalchat`, `togglehumans`, `toggleai`, `disableaiclasses`, `aidensity`, `raw`.

The command bytes come from community documentation and may change with game updates.

## Scheduled restarts (optional)

- **Linux:** `sudo systemctl edit theisle-server`, or add a root cron entry:
  `0 6 * * * systemctl restart theisle-server`
- **Windows:** create a daily task that runs
  `C:\TheIsle\scripts\windows\Restart.bat` with the environment variable `ISLE_NOPAUSE=1` set.
