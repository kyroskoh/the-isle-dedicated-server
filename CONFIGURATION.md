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
