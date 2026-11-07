#!/usr/bin/env bash
# =============================================================================
#  isle-server.sh - The Isle (Evrima) dedicated server manager for Linux
#
#  Usage: isle-server.sh [--docker|--native] <command> [args]
#
#  The same commands work for a native install and for Docker. The runtime
#  comes from --docker/--native, else $ISLE_RUNTIME, else RUNTIME in server.conf.
#
#  Commands:
#    install      Install SteamCMD + server files and generate config
#    update       Update server files through SteamCMD (server must be stopped)
#    validate     Update + verify every file (server must be stopped)
#    check        Validate server.conf (exit 1 on errors)
#    configure    Validate, then (re)generate Game.ini / Engine.ini
#    start        Start the server (systemd service if installed, else background)
#    stop         Gracefully stop the server
#    restart      Stop + start
#    status       Show whether the server is running
#    run          Run in the foreground (used by systemd)
#    logs [-f]    Show (or follow) the server log
#    backup       Archive save data / config to BACKUP_DIR
#    restore <f>  Restore a backup archive (server must be stopped)
#    rcon <cmd>   Send an RCON command (see tools/isle_rcon.py)
#    save         Ask the server to save via RCON
#    admins       list|add|remove <SteamID64...>         (admins, applied on restart)
#    whitelist    list|add|remove <SteamID64...>|on|off  (live via RCON when running)
#    classes      list|known|set|add|remove <Class...>|reset|preset [roster]
#    ai-classes   list|known|set|add|remove <Class...>|reset  (disabled AI)
#    profile      list|show <name>|apply <name>          (whole play styles)
#    preset       list|show <name>|apply <name...>       (stackable tweaks)
#    plugins      list|search|info|install|remove|enable|disable|update|
#                 preset|run|config|sources ...          (see PLUGINS.md)
#    info         Print resolved paths and settings
#    version      Print the script version
#    help         This text
#
#  Environment:
#    ISLE_CONF          path to server.conf (default: <repo>/config/server.conf)
#    ISLE_NO_SYSTEMD=1  never delegate start/stop/status to systemd
#    ISLE_SERVICE       systemd unit name (default: theisle-server)
#    ISLE_RUNTIME       native | docker (overrides RUNTIME in server.conf)
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ISLE_CONF="${ISLE_CONF:-$REPO_DIR/config/server.conf}"
ISLE_SERVICE="${ISLE_SERVICE:-theisle-server}"
SCRIPT_VERSION="$(cat "$REPO_DIR/VERSION" 2>/dev/null || echo unknown)"
STEAMCMD_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"

# ----------------------------------------------------------------- output ---
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[36m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_RST=""
fi
log()  { printf '%s[%s]%s %s\n' "$C_BLU" "$(date '+%F %T')" "$C_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# ----------------------------------------------------------------- config ---
# Parse KEY=VALUE without executing the file (no "source").
declare -A CFG=()
load_config() {
  local file="$ISLE_CONF"
  if [[ ! -f "$file" ]]; then
    if [[ -f "$REPO_DIR/config/server.conf.example" ]]; then
      warn "No $file found - creating it from server.conf.example"
      cp "$REPO_DIR/config/server.conf.example" "$file"
    else
      die "Config file not found: $file"
    fi
  fi
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"                       # tolerate CRLF files
    line="${line#"${line%%[![:space:]]*}"}"    # ltrim
    [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
    key="${line%%=*}"; value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ ${#value} -ge 2 && ( ( "${value:0:1}" == '"' && "${value: -1}" == '"' ) || ( "${value:0:1}" == "'" && "${value: -1}" == "'" ) ) ]]; then
      value="${value:1:${#value}-2}"
    fi
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && CFG["$key"]="$value"
  done < "$file"

  RAW_SERVER_NAME="${CFG[SERVER_NAME]:-}"
  # Defaults
  local home="${HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}"
  : "${CFG[STEAMCMD_DIR]:=}"; [[ -z "${CFG[STEAMCMD_DIR]}" ]] && CFG[STEAMCMD_DIR]="$home/steamcmd"
  : "${CFG[SERVER_DIR]:=}";   [[ -z "${CFG[SERVER_DIR]}" ]]   && CFG[SERVER_DIR]="$home/theisle-server"
  : "${CFG[BACKUP_DIR]:=}";   [[ -z "${CFG[BACKUP_DIR]}" ]]   && CFG[BACKUP_DIR]="$home/theisle-backups"
  local k
  for k in STEAM_APP_ID:412680 STEAM_BRANCH:evrima GAME_PORT:7777 QUEUE_PORT:10000 RCON_PORT:8888 \
           MAX_PLAYERS:100 MAP_NAME:Gateway STOP_TIMEOUT:60 BACKUP_RETENTION:10 \
           "SERVER_NAME:The Isle Evrima Server" UPDATE_ON_START:true VALIDATE_ON_UPDATE:false \
           AUTO_RESTART:true MANAGE_INI_FILES:true SAVE_BEFORE_STOP:true RCON_ENABLED:true \
           QUEUE_ENABLED:true EXTRA_ARGS:-log RUNTIME:native DOCKER_BUILD:true \
           DOCKER_IMAGE:theisle-server:latest; do
    [[ -z "${CFG[${k%%:*}]:-}" ]] && CFG[${k%%:*}]="${k#*:}"
  done
  STEAMCMD_DIR="${CFG[STEAMCMD_DIR]}"
  SERVER_DIR="${CFG[SERVER_DIR]}"
  BACKUP_DIR="${CFG[BACKUP_DIR]}"
  INI_DIR="$SERVER_DIR/TheIsle/Saved/Config/LinuxServer"
  STATE_DIR="$SERVER_DIR/.isle-scripts"
  LOG_FILE="$SERVER_DIR/TheIsle/Saved/Logs/TheIsle.log"
}
cfg()      { printf '%s' "${CFG[$1]:-${2:-}}"; }
is_true()  { case "${1,,}" in true|yes|1|on) return 0 ;; *) return 1 ;; esac; }
ue_bool()  { if is_true "$1"; then printf 'true'; else printf 'false'; fi; }

set_conf() {  # persist KEY=VALUE into server.conf (value must not contain newlines)
  local key="$1" val="$2" esc owner=""
  [[ "$val" != *$'\n'* ]] || die "Value for $key must not contain newlines"
  owner="$(stat -c '%u:%g' "$ISLE_CONF" 2>/dev/null || true)"
  if grep -qE "^$key=" "$ISLE_CONF"; then
    esc="$(printf '%s' "$val" | sed -e 's/[\\/&|]/\\&/g')"
    sed -i "s|^$key=.*|$key=$esc|" "$ISLE_CONF"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ISLE_CONF"
  fi
  # sed -i recreates the file: keep the original owner (e.g. root editing theisle's config)
  if [[ $EUID -eq 0 && -n "$owner" ]]; then chown "$owner" "$ISLE_CONF" 2>/dev/null || true; fi
  chmod 600 "$ISLE_CONF" 2>/dev/null || true
  CFG[$key]="$val"
}

# ------------------------------------------------------------ validation ---
BOOL_KEYS=(UPDATE_ON_START VALIDATE_ON_UPDATE FIREWALL_OPEN_RCON WHITELIST_ENABLED QUEUE_ENABLED
           RCON_ENABLED GLOBAL_CHAT ENABLE_HUMANS DYNAMIC_WEATHER ENABLE_MUTATIONS ENABLE_DIETS
           ENABLE_PATROL_ZONES ALLOW_RECORDING_REPLAY SPAWN_PLANTS SPAWN_AI ENABLE_MIGRATION
           ENABLE_MASS_MIGRATION MANAGE_INI_FILES AUTO_RESTART SAVE_BEFORE_STOP DOCKER_BUILD
           REGION_SPAWNING REGION_SPAWN_COOLDOWN)
NUMBER_KEYS=(GROWTH_MULTIPLIER CORPSE_DECAY_MULTIPLIER PLANT_SPAWN_MULTIPLIER AI_DENSITY
             DAY_LENGTH_MINUTES NIGHT_LENGTH_MINUTES WEATHER_MIN_INTERVAL WEATHER_MAX_INTERVAL)
INT_KEYS=(MAX_MIGRATION_TIME MASS_MIGRATION_TIME MASS_MIGRATION_DISABLE_TIME STOP_TIMEOUT BACKUP_RETENTION
          REGION_SPAWN_COOLDOWN_SECONDS NET_TICK_RATE)

# Validate server.conf (PRD CFG-05). Prints every problem; returns 1 on errors.
check_config() {
  local -a errors=() warnings=()
  local k v id ids
  for k in GAME_PORT QUEUE_PORT RCON_PORT; do
    v="$(cfg "$k")"
    if ! [[ "$v" =~ ^[0-9]+$ ]] || (( 10#$v < 1 || 10#$v > 65535 )); then
      errors+=("$k='$v' is not a port number (1-65535)")
    fi
  done
  if [[ ${#errors[@]} -eq 0 ]]; then
    is_true "$(cfg QUEUE_ENABLED)" && [[ "$(cfg GAME_PORT)" == "$(cfg QUEUE_PORT)" ]] \
      && errors+=("GAME_PORT and QUEUE_PORT are both $(cfg GAME_PORT)")
    if is_true "$(cfg RCON_ENABLED)"; then
      [[ "$(cfg RCON_PORT)" == "$(cfg GAME_PORT)" ]] && errors+=("RCON_PORT and GAME_PORT are both $(cfg RCON_PORT)")
      is_true "$(cfg QUEUE_ENABLED)" && [[ "$(cfg RCON_PORT)" == "$(cfg QUEUE_PORT)" ]] \
        && errors+=("RCON_PORT and QUEUE_PORT are both $(cfg RCON_PORT)")
    fi
  fi
  case "${RUNTIME:-$(cfg RUNTIME native)}" in
    native|docker) ;;
    *) errors+=("RUNTIME='${RUNTIME:-$(cfg RUNTIME)}' must be native or docker") ;;
  esac
  for k in PUID PGID; do
    v="$(cfg "$k")"
    [[ -z "$v" || "$v" =~ ^[0-9]+$ ]] || errors+=("$k='$v' must be a numeric id")
  done
  v="$(cfg MAX_PLAYERS)"
  if ! [[ "$v" =~ ^[0-9]+$ ]] || (( 10#$v < 1 )); then errors+=("MAX_PLAYERS='$v' must be a positive integer"); fi
  for k in "${BOOL_KEYS[@]}"; do
    v="$(cfg "$k")"
    [[ -z "$v" ]] && continue
    case "${v,,}" in true|false|yes|no|1|0|on|off) ;; *) errors+=("$k='$v' must be true or false") ;; esac
  done
  for k in "${NUMBER_KEYS[@]}"; do
    v="$(cfg "$k")"
    [[ -z "$v" || "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || errors+=("$k='$v' must be a number")
  done
  for k in "${INT_KEYS[@]}"; do
    v="$(cfg "$k")"
    [[ -z "$v" || "$v" =~ ^[0-9]+$ ]] || errors+=("$k='$v' must be a whole number")
  done
  if is_true "$(cfg RCON_ENABLED)" && [[ -z "$(cfg RCON_PASSWORD)" ]]; then
    errors+=("RCON_ENABLED=true but RCON_PASSWORD is empty (set one, or RCON_ENABLED=false)")
  fi
  [[ -n "$(cfg EOS_CLIENT_ID)" && -n "$(cfg EOS_CLIENT_SECRET)" ]] \
    || errors+=("EOS_CLIENT_ID / EOS_CLIENT_SECRET are empty - the server will not be listed")
  [[ -n "$RAW_SERVER_NAME" ]] || warnings+=("SERVER_NAME is empty - using '$(cfg SERVER_NAME)'")
  for k in ADMIN_STEAM_IDS WHITELIST_IDS; do
    IFS=',' read -r -a ids <<< "$(cfg "$k")"
    for id in "${ids[@]}"; do
      id="${id//[[:space:]]/}"
      [[ -z "$id" || "$id" =~ ^7656119[0-9]{10}$ ]] || warnings+=("$k entry '$id' is not a 17-digit SteamID64")
    done
  done
  is_true "$(cfg WHITELIST_ENABLED)" && [[ -z "$(cfg WHITELIST_IDS)" ]] \
    && warnings+=("WHITELIST_ENABLED=true but WHITELIST_IDS is empty - nobody can join")

  for v in "${warnings[@]}"; do warn "config: $v"; done
  for v in "${errors[@]}"; do printf '%s[FAIL]%s config: %s\n' "$C_RED" "$C_RST" "$v" >&2; done
  if (( ${#errors[@]} )); then
    printf '%s[FAIL]%s %d error(s) in %s\n' "$C_RED" "$C_RST" "${#errors[@]}" "$ISLE_CONF" >&2
    return 1
  fi
  return 0
}

ensure_rcon_password() {
  if is_true "$(cfg RCON_ENABLED)" && [[ -z "$(cfg RCON_PASSWORD)" ]]; then
    set_conf RCON_PASSWORD "$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)"
    ok "Generated a random RCON password (saved in $ISLE_CONF)"
  fi
}

# ---------------------------------------------------------------- steamcmd --
install_steamcmd() {
  if [[ -x "$STEAMCMD_DIR/steamcmd.sh" ]]; then
    ok "SteamCMD already present in $STEAMCMD_DIR"
    return
  fi
  log "Installing SteamCMD into $STEAMCMD_DIR"
  mkdir -p "$STEAMCMD_DIR"
  local tmp; tmp="$(mktemp)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$STEAMCMD_URL" -o "$tmp"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$STEAMCMD_URL"
  else
    die "Neither curl nor wget is installed (run linux/install.sh as root first)"
  fi
  tar -xzf "$tmp" -C "$STEAMCMD_DIR"
  rm -f "$tmp"
  ok "SteamCMD installed"
}

run_steamcmd() {
  local attempt rc=0
  for attempt in 1 2 3; do
    "$STEAMCMD_DIR/steamcmd.sh" "$@" && return 0
    rc=$?
    # SteamCMD often exits non-zero right after updating itself; just retry.
    warn "SteamCMD exited with code $rc (attempt $attempt/3) - retrying in 5s"
    sleep 5
  done
  return "$rc"
}

link_steamclient() {
  # The Isle server needs the 64-bit Steam client library at ~/.steam/sdk64.
  local src="" cand
  for cand in "$STEAMCMD_DIR/linux64/steamclient.so" "$SERVER_DIR/linux64/steamclient.so" "$SERVER_DIR/steamclient.so"; do
    [[ -f "$cand" ]] && { src="$cand"; break; }
  done
  if [[ -z "$src" ]]; then
    warn "steamclient.so not found - the server may fail to initialise Steam"
    return
  fi
  mkdir -p "$HOME/.steam/sdk64"
  cp -f "$src" "$HOME/.steam/sdk64/steamclient.so"
  local bindir="$SERVER_DIR/TheIsle/Binaries/Linux"
  [[ -d "$bindir" ]] && cp -f "$src" "$bindir/steamclient.so"
  ok "steamclient.so installed to ~/.steam/sdk64"
}

update_server() {
  install_steamcmd
  mkdir -p "$SERVER_DIR"
  local -a args=(+force_install_dir "$SERVER_DIR" +login anonymous +app_update "$(cfg STEAM_APP_ID)")
  if [[ -n "$(cfg STEAM_BRANCH)" ]]; then
    args+=(-beta "$(cfg STEAM_BRANCH)")
    [[ -n "$(cfg STEAM_BRANCH_PASSWORD)" ]] && args+=(-betapassword "$(cfg STEAM_BRANCH_PASSWORD)")
  fi
  if is_true "$(cfg VALIDATE_ON_UPDATE)" || [[ "${1:-}" == "--validate" ]]; then
    args+=(validate)
  fi
  args+=(+quit)
  log "Updating The Isle server (app $(cfg STEAM_APP_ID), branch '$(cfg STEAM_BRANCH)')"
  run_steamcmd "${args[@]}" || die "SteamCMD update failed"
  link_steamclient
  local bin; bin="$(server_binary)" || die "Server executable not found after update in $SERVER_DIR"
  chmod +x "$bin" "$SERVER_DIR/TheIsleServer.sh" 2>/dev/null || true
  ok "Server files are up to date"
}

# ---------------------------------------------------------- ini rendering ---
ini_list() {  # $1 key name, $2 comma separated values -> one line per entry
  local key="$1" item; local -a items
  IFS=',' read -r -a items <<< "$2"
  for item in "${items[@]}"; do
    item="${item//[[:space:]]/}"
    [[ -n "$item" ]] && printf '%s=%s\n' "$key" "$item"
  done
  return 0
}

render_game_ini() {
  local extra item; local -a extras
  printf '[/Script/TheIsle.TIGameSession]\n'
  printf 'ServerName=%s\n' "$(cfg SERVER_NAME)"
  printf 'MapName=%s\n' "$(cfg MAP_NAME)"
  printf 'MaxPlayerCount=%s\n' "$(cfg MAX_PLAYERS)"
  if [[ -n "$(cfg SERVER_PASSWORD)" ]]; then
    printf 'bServerPassword=true\nServerPassword=%s\n' "$(cfg SERVER_PASSWORD)"
  else
    printf 'bServerPassword=false\nServerPassword=\n'
  fi
  printf 'bQueueEnabled=%s\n' "$(ue_bool "$(cfg QUEUE_ENABLED)")"
  printf 'QueuePort=%s\n' "$(cfg QUEUE_PORT)"
  printf 'bRconEnabled=%s\n' "$(ue_bool "$(cfg RCON_ENABLED)")"
  printf 'RconPassword=%s\n' "$(cfg RCON_PASSWORD)"
  printf 'RconPort=%s\n' "$(cfg RCON_PORT)"
  printf 'bServerWhitelist=%s\n' "$(ue_bool "$(cfg WHITELIST_ENABLED false)")"
  printf 'bEnableGlobalChat=%s\n' "$(ue_bool "$(cfg GLOBAL_CHAT true)")"
  printf 'bEnableHumans=%s\n' "$(ue_bool "$(cfg ENABLE_HUMANS false)")"
  printf 'bServerDynamicWeather=%s\n' "$(ue_bool "$(cfg DYNAMIC_WEATHER true)")"
  printf 'ServerDayLengthMinutes=%s\n' "$(cfg DAY_LENGTH_MINUTES 45)"
  printf 'ServerNightLengthMinutes=%s\n' "$(cfg NIGHT_LENGTH_MINUTES 20)"
  printf 'GrowthMultiplier=%s\n' "$(cfg GROWTH_MULTIPLIER 1)"
  printf 'CorpseDecayMultiplier=%s\n' "$(cfg CORPSE_DECAY_MULTIPLIER 1)"
  printf 'bEnableMutations=%s\n' "$(ue_bool "$(cfg ENABLE_MUTATIONS true)")"
  printf 'bEnableDiets=%s\n' "$(ue_bool "$(cfg ENABLE_DIETS true)")"
  printf 'bEnablePatrolZones=%s\n' "$(ue_bool "$(cfg ENABLE_PATROL_ZONES true)")"
  printf 'bAllowRecordingReplay=%s\n' "$(ue_bool "$(cfg ALLOW_RECORDING_REPLAY true)")"
  printf 'bSpawnPlants=%s\n' "$(ue_bool "$(cfg SPAWN_PLANTS true)")"
  printf 'PlantSpawnMultiplier=%s\n' "$(cfg PLANT_SPAWN_MULTIPLIER 1)"
  printf 'bSpawnAI=%s\n' "$(ue_bool "$(cfg SPAWN_AI true)")"
  printf 'AIDensity=%s\n' "$(cfg AI_DENSITY 1)"
  printf 'bEnableMigration=%s\n' "$(ue_bool "$(cfg ENABLE_MIGRATION true)")"
  printf 'MaxMigrationTime=%s\n' "$(cfg MAX_MIGRATION_TIME 5400)"
  printf 'bEnableMassMigration=%s\n' "$(ue_bool "$(cfg ENABLE_MASS_MIGRATION true)")"
  printf 'MassMigrationTime=%s\n' "$(cfg MASS_MIGRATION_TIME 43200)"
  printf 'MassMigrationDisableTime=%s\n' "$(cfg MASS_MIGRATION_DISABLE_TIME 7200)"
  # Optional keys: only written when set (PRD CFX-03)
  [[ -z "$(cfg REGION_SPAWNING)" ]] || printf 'bUseRegionSpawning=%s\n' "$(ue_bool "$(cfg REGION_SPAWNING)")"
  [[ -z "$(cfg REGION_SPAWN_COOLDOWN)" ]] || printf 'bUseRegionSpawnCooldown=%s\n' "$(ue_bool "$(cfg REGION_SPAWN_COOLDOWN)")"
  [[ -z "$(cfg REGION_SPAWN_COOLDOWN_SECONDS)" ]] || printf 'RegionSpawnCooldownTimeSeconds=%s\n' "$(cfg REGION_SPAWN_COOLDOWN_SECONDS)"
  [[ -z "$(cfg WEATHER_MIN_INTERVAL)" ]] || printf 'MinWeatherVariationInterval=%s\n' "$(cfg WEATHER_MIN_INTERVAL)"
  [[ -z "$(cfg WEATHER_MAX_INTERVAL)" ]] || printf 'MaxWeatherVariationInterval=%s\n' "$(cfg WEATHER_MAX_INTERVAL)"
  ini_list AllowedClasses "$(cfg ALLOWED_CLASSES)"
  ini_list DisallowedAIClasses "$(cfg DISABLED_AI_CLASSES)"
  ini_list AdminsSteamIDs "$(cfg ADMIN_STEAM_IDS)"
  ini_list WhitelistIDs "$(cfg WHITELIST_IDS)"
  extra="$(cfg EXTRA_GAME_SESSION_SETTINGS)"
  if [[ -n "$extra" ]]; then
    IFS='|' read -r -a extras <<< "$extra"
    for item in "${extras[@]}"; do [[ -n "$item" ]] && printf '%s\n' "$item"; done
  fi
  printf '\n[/Script/TheIsle.TIGameStateBase]\n'
  ini_list AdminsSteamIDs "$(cfg ADMIN_STEAM_IDS)"
  ini_list WhitelistIDs "$(cfg WHITELIST_IDS)"
  printf '\n[/Script/Engine.GameSession]\n'
  printf 'MaxPlayers=%s\n' "$(cfg MAX_PLAYERS)"
}

render_engine_ini() {
  printf '[EpicOnlineServices]\n'
  printf 'DedicatedServerClientId=%s\n' "$(cfg EOS_CLIENT_ID)"
  printf 'DedicatedServerClientSecret=%s\n' "$(cfg EOS_CLIENT_SECRET)"
  printf '\n[/Script/OnlineSubsystemUtils.IpNetDriver]\n'
  printf 'MaxClientRate=100000\nMaxInternetClientRate=100000\n'
  [[ -z "$(cfg NET_TICK_RATE)" ]] || printf 'NetServerMaxTickRate=%s\n' "$(cfg NET_TICK_RATE)"
}

write_ini() {  # $1 file, $2 render function
  local file="$1" tmp ovr
  tmp="$(mktemp)"
  "$2" > "$tmp"
  ovr="$(overrides_dir)/$(basename "$file")"
  if [[ -f "$ovr" ]]; then merge_ini_overrides "$tmp" "$ovr"; log "Merged overrides from $ovr"; fi
  if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then
    rm -f "$tmp"; return
  fi
  [[ -f "$file" ]] && cp -f "$file" "$file.bak"
  mv -f "$tmp" "$file"
  chmod 600 "$file"
  ok "Wrote $file"
}

configure() {
  local force="${1:-}"
  check_config || die "Fix the configuration errors above, then try again"
  mkdir -p "$INI_DIR"
  if is_true "$(cfg MANAGE_INI_FILES)" || [[ "$force" == "--force" ]]; then
    write_ini "$INI_DIR/Game.ini" render_game_ini
    write_ini "$INI_DIR/Engine.ini" render_engine_ini
  else
    [[ -f "$INI_DIR/Game.ini" ]]   || write_ini "$INI_DIR/Game.ini" render_game_ini
    [[ -f "$INI_DIR/Engine.ini" ]] || write_ini "$INI_DIR/Engine.ini" render_engine_ini
    log "MANAGE_INI_FILES=false - existing .ini files left untouched"
  fi
}

# --------------------------------------------------------------- process ----
server_binary() {
  local cand
  for cand in "$SERVER_DIR/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping" "$SERVER_DIR/TheIsleServer.sh"; do
    [[ -f "$cand" ]] && { printf '%s' "$cand"; return 0; }
  done
  return 1
}

server_args() {
  local -a a=()
  [[ "$(server_binary)" == *-Shipping ]] && a+=(TheIsle)
  a+=("-Port=$(cfg GAME_PORT)")
  [[ -n "$(cfg MULTIHOME_IP)" ]] && a+=("-MultiHome=$(cfg MULTIHOME_IP)")
  local -a extra=()
  [[ -n "$(cfg EXTRA_ARGS)" ]] && read -r -a extra <<< "$(cfg EXTRA_ARGS)"
  printf '%s\n' "${a[@]}" "${extra[@]}"
}

prepare_launch() {
  if is_true "$(cfg UPDATE_ON_START)" || ! server_binary >/dev/null; then
    update_server || { server_binary >/dev/null || die "No server installed"; warn "Update failed - starting existing build"; }
  fi
  configure
  link_steamclient >/dev/null 2>&1 || true
  mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"
  export LD_LIBRARY_PATH="$SERVER_DIR/TheIsle/Binaries/Linux:$SERVER_DIR/linux64:${LD_LIBRARY_PATH:-}"
  ulimit -n 100000 2>/dev/null || ulimit -n 65535 2>/dev/null || true
}

service_installed() {
  [[ -z "${ISLE_NO_SYSTEMD:-}" ]] && command -v systemctl >/dev/null 2>&1 \
    && systemctl list-unit-files "$ISLE_SERVICE.service" >/dev/null 2>&1 \
    && [[ -n "$(systemctl list-unit-files "$ISLE_SERVICE.service" --no-legend 2>/dev/null)" ]]
}
sysctl_do() {
  if [[ $EUID -eq 0 ]]; then systemctl "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo systemctl "$@"
  else die "Need root (or sudo) to run: systemctl $*"; fi
}

pid_alive() { [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }
read_pid()  { if [[ -f "$1" ]]; then cat "$1" 2>/dev/null || true; fi; }

cmd_run() {  # foreground; systemd ExecStart
  prepare_launch
  local bin; bin="$(server_binary)"
  local -a args; mapfile -t args < <(server_args)
  log "Launching: $bin ${args[*]}"
  cd "$SERVER_DIR"
  # exec keeps this PID, so status/stop/healthchecks can find the server.
  echo $$ > "$STATE_DIR/server.pid"
  exec "$bin" "${args[@]}"
}

cmd_watchdog() {  # background supervisor used by "start" without systemd
  prepare_launch
  local bin; bin="$(server_binary)"
  local -a args; mapfile -t args < <(server_args)
  echo $$ > "$STATE_DIR/watchdog.pid"
  rm -f "$STATE_DIR/stop.flag"
  trap 'touch "$STATE_DIR/stop.flag"; pid_alive "$(read_pid "$STATE_DIR/server.pid")" && kill -TERM "$(read_pid "$STATE_DIR/server.pid")"' INT TERM
  cd "$SERVER_DIR"
  while :; do
    log "Launching: $bin ${args[*]}"
    "$bin" "${args[@]}" &
    echo $! > "$STATE_DIR/server.pid"
    local rc=0; wait "$!" || rc=$?
    # wait returns early when a trapped signal arrives; wait for the real exit.
    while pid_alive "$(read_pid "$STATE_DIR/server.pid")"; do sleep 1; done
    rm -f "$STATE_DIR/server.pid"
    if [[ -f "$STATE_DIR/stop.flag" ]] || ! is_true "$(cfg AUTO_RESTART)"; then
      log "Server exited (code $rc) - watchdog stopping"; break
    fi
    warn "Server exited unexpectedly (code $rc) - restarting in 10s"
    sleep 10
  done
  rm -f "$STATE_DIR/watchdog.pid" "$STATE_DIR/stop.flag"
}

is_running() {
  pid_alive "$(read_pid "$STATE_DIR/server.pid")" || pid_alive "$(read_pid "$STATE_DIR/watchdog.pid")"
}

server_running() {  # any evidence the game server is up (pid files, systemd, process list)
  is_running && return 0
  service_installed && systemctl is-active --quiet "$ISLE_SERVICE" && return 0
  command -v pgrep >/dev/null 2>&1 && pgrep -f "$SERVER_DIR/TheIsle/Binaries/Linux/TheIsleServer" >/dev/null 2>&1 && return 0
  return 1
}
require_stopped() { server_running && die "The server is running - stop it before you $1"; return 0; }

cmd_start() {
  check_config || die "Fix the configuration errors above, then try again"
  if service_installed; then sysctl_do start "$ISLE_SERVICE"; ok "Service $ISLE_SERVICE started"; return; fi
  if is_running; then warn "Server is already running"; return; fi
  mkdir -p "$STATE_DIR"
  local out="$STATE_DIR/console.log"
  log "Starting server in the background (console output: $out)"
  nohup "$SCRIPT_DIR/isle-server.sh" _watchdog >> "$out" 2>&1 < /dev/null &
  sleep 3
  if is_running; then ok "Server starting (watchdog PID $(read_pid "$STATE_DIR/watchdog.pid"))"
  else die "Server failed to start - check $out"; fi
}

cmd_save() {
  if ! is_true "$(cfg RCON_ENABLED)" || [[ -z "$(cfg RCON_PASSWORD)" ]]; then
    warn "RCON disabled or no password - skipping save"; return 0
  fi
  command -v python3 >/dev/null 2>&1 || { warn "python3 not found - skipping RCON save"; return 0; }
  log "Requesting world save via RCON"
  ISLE_RCON_PASSWORD="$(cfg RCON_PASSWORD)" python3 "$REPO_DIR/tools/isle_rcon.py" \
    -p "$(cfg RCON_PORT)" save || { warn "RCON save failed"; return 0; }
  sleep 5
}

cmd_stop() {
  if service_installed; then sysctl_do stop "$ISLE_SERVICE"; ok "Service $ISLE_SERVICE stopped"; return; fi
  if ! is_running; then warn "Server is not running"; return; fi
  is_true "$(cfg SAVE_BEFORE_STOP)" && cmd_save
  touch "$STATE_DIR/stop.flag"
  local spid wpid t=0 timeout; spid="$(read_pid "$STATE_DIR/server.pid")"; wpid="$(read_pid "$STATE_DIR/watchdog.pid")"
  timeout="$(cfg STOP_TIMEOUT 60)"
  log "Stopping server (timeout ${timeout}s)"
  # Unreal treats SIGTERM as a graceful exit request (SIGINT is ignored by
  # background jobs started from a non-interactive shell).
  if pid_alive "$spid"; then kill -TERM "$spid" 2>/dev/null || true; fi
  while { pid_alive "$spid" || pid_alive "$wpid"; } && (( t < timeout )); do sleep 1; t=$((t + 1)); done
  if pid_alive "$spid"; then warn "Graceful stop timed out - killing"; kill -KILL "$spid" 2>/dev/null || true; fi
  if pid_alive "$wpid"; then kill -TERM "$wpid" 2>/dev/null || true; fi
  rm -f "$STATE_DIR/server.pid" "$STATE_DIR/watchdog.pid"
  ok "Server stopped"
}

cmd_status() {
  if service_installed; then systemctl --no-pager status "$ISLE_SERVICE" || true; return; fi
  if is_running; then
    local wd; wd="$(read_pid "$STATE_DIR/watchdog.pid")"
    ok "Running (server PID $(read_pid "$STATE_DIR/server.pid")${wd:+, watchdog PID $wd})"
  else warn "Not running"; return 3; fi
}

cmd_logs() {
  if [[ ! -f "$LOG_FILE" ]]; then
    if service_installed; then exec journalctl -u "$ISLE_SERVICE" -n 200 "$@"; fi
    die "No log file yet at $LOG_FILE"
  fi
  if [[ "${1:-}" == "-f" ]]; then exec tail -n 100 -F "$LOG_FILE"; else tail -n 200 "$LOG_FILE"; fi
}

# ---------------------------------------------------------------- backups ---
cmd_backup() {
  local saved="$SERVER_DIR/TheIsle/Saved"
  [[ -d "$saved" ]] || die "Nothing to back up ($saved does not exist)"
  mkdir -p "$BACKUP_DIR"
  is_running && is_true "$(cfg SAVE_BEFORE_STOP)" && cmd_save
  local file; file="$BACKUP_DIR/theisle-$(date +%Y%m%d-%H%M%S).tar.gz"
  log "Creating backup $file"
  tar -czf "$file" -C "$SERVER_DIR/TheIsle" --exclude='Saved/Logs' --exclude='Saved/Crashes' Saved \
    -C "$(dirname "$ISLE_CONF")" "$(basename "$ISLE_CONF")" 2>/dev/null \
    || tar -czf "$file" -C "$SERVER_DIR/TheIsle" --exclude='Saved/Logs' --exclude='Saved/Crashes' Saved
  ok "Backup written ($(du -h "$file" | cut -f1))"
  local keep; keep="$(cfg BACKUP_RETENTION 10)"
  if [[ "$keep" =~ ^[0-9]+$ ]] && (( keep > 0 )); then
    find "$BACKUP_DIR" -maxdepth 1 -name 'theisle-*.tar.gz' -printf '%T@ %p\n' | sort -rn \
      | tail -n +$((keep + 1)) | cut -d' ' -f2- | while IFS= read -r old; do rm -f -- "$old"; log "Pruned $old"; done
  fi
}

cmd_restore() {
  local file="${1:-}"
  [[ -f "$file" ]] || die "Usage: isle-server.sh restore <backup.tar.gz>"
  is_running && die "Stop the server before restoring"
  local saved="$SERVER_DIR/TheIsle/Saved"
  if [[ -d "$saved" ]]; then mv "$saved" "$saved.pre-restore-$(date +%Y%m%d-%H%M%S)"; fi
  mkdir -p "$SERVER_DIR/TheIsle"
  tar -xzf "$file" -C "$SERVER_DIR/TheIsle" Saved
  ok "Restored $file (previous data kept as Saved.pre-restore-*)"
}

cmd_rcon() {
  [[ $# -gt 0 ]] || die "Usage: isle-server.sh rcon <command> [args]"
  command -v python3 >/dev/null 2>&1 || die "python3 is required for RCON"
  ISLE_RCON_PASSWORD="$(cfg RCON_PASSWORD)" exec python3 "$REPO_DIR/tools/isle_rcon.py" -p "$(cfg RCON_PORT)" "$@"
}

cmd_info() {
  cat <<EOF
Scripts       : v$SCRIPT_VERSION
Runtime       : native
Config file   : $ISLE_CONF
SteamCMD dir  : $STEAMCMD_DIR
Server dir    : $SERVER_DIR
Config (ini)  : $INI_DIR
Backup dir    : $BACKUP_DIR
App / branch  : $(cfg STEAM_APP_ID) / $(cfg STEAM_BRANCH)
Ports         : game $(cfg GAME_PORT)/udp, queue $(cfg QUEUE_PORT)/tcp, rcon $(cfg RCON_PORT)/tcp
Server name   : $(cfg SERVER_NAME)
systemd unit  : $(if service_installed; then echo "$ISLE_SERVICE (installed)"; else echo "not installed"; fi)
EOF
}

# ----------------------------------------------------------- ini overrides --
# config/overrides/{Game,Engine}.ini are merged into the generated files
# (PRD CFX-01): a Key=Value replaces every generated line of that key in that
# section, new keys/sections are appended, +/-/! lines pass through unchanged.
overrides_dir() {
  local d; d="$(cfg INI_OVERRIDES_DIR)"
  printf '%s' "${d:-$(dirname "$ISLE_CONF")/overrides}"
}
merge_ini_overrides() {  # BASE_FILE (edited in place) OVERRIDE_FILE
  [[ -f "$2" ]] || return 0
  awk -v ovr="$2" '
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function key(l,   k) { k = l; sub(/=.*/, "", k); return tolower(trim(k)) }
    function flush(s,   i) { if ((s in seen) && !(s in done)) { for (i = 1; i <= cnt[s]; i++) print lines[s, i]; done[s] = 1 } }
    BEGIN {
      sec = ""
      while ((getline line < ovr) > 0) {
        line = trim(line)
        if (line == "" || line ~ /^[;#]/) continue
        if (line ~ /^\[.*\]$/) { sec = line; if (!(sec in seen)) { seen[sec] = 1; order[++ns] = sec }; continue }
        if (sec == "" || index(line, "=") == 0 && line !~ /^[+!-]/) continue
        lines[sec, ++cnt[sec]] = line
        if (line !~ /^[+!-]/) replace[sec, key(line)] = 1
      }
    }
    /^[ \t]*\[.*\][ \t\r]*$/ { flush(cur); cur = trim($0); print; next }
    {
      l = trim($0)
      if (cur != "" && l != "" && l !~ /^[;#]/ && index(l, "=") > 0 && ((cur, key(l)) in replace)) next
      print
    }
    END {
      flush(cur)
      for (i = 1; i <= ns; i++) { s = order[i]; if (!(s in done)) { print ""; print s; flush(s) } }
    }' "$1" > "$1.merged" && mv -f "$1.merged" "$1"
}

# ------------------------------------------------------- list editing -------
# Admins / whitelist / rosters (PRD CFX-06..08). They edit the HOST server.conf
# and push a live change through RCON when the server is up.
list_norm() { tr ',' '\n' | tr -d ' \t\r' | awk 'NF && !seen[$0]++' | paste -sd, -; }
list_show() { if [[ -z "$1" ]]; then echo "${2:-(empty)}"; else tr ',' '\n' <<< "$1" | sed '/^$/d'; fi; }
list_count() { if [[ -z "$1" ]]; then echo 0; else tr ',' '\n' <<< "$1" | sed '/^$/d' | wc -l | tr -d ' '; fi; }

known_classes() {  # SECTION (playable|ai) -> one name per line
  local file="$REPO_DIR/config/classes.txt"
  [[ -f "$file" ]] || return 0
  awk -v want="[$1]" '/^\[/ { on = ($0 == want); next } on && $1 !~ /^#/ && NF { print $1 }' "$file"
}
check_ids() {
  local id
  for id in "$@"; do
    [[ "$id" =~ ^7656119[0-9]{10}$ ]] || die "'$id' is not a SteamID64 (17 digits starting with 7656119)"
  done
}
check_classes() {  # SECTION names... (unknown names only warn)
  local section="$1"; shift
  local known c; known="$(known_classes "$section")"
  for c in "$@"; do
    [[ "$c" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || die "'$c' is not a valid class name"
    if [[ -n "$known" ]] && ! grep -qxi -- "$c" <<< "$known"; then
      warn "'$c' is not in config/classes.txt - keeping it anyway (new or renamed species?)"
    fi
  done
}

live_rcon() {  # RCON command + args; only when the server is running; never fails
  local pw; pw="$(cfg RCON_PASSWORD)"
  if ! { is_true "$(cfg RCON_ENABLED)" && [[ -n "$pw" ]]; }; then
    log "RCON disabled - the change applies on the next restart"; return 0
  fi
  if [[ "${RUNTIME:-native}" == docker ]]; then
    if ! { command -v docker >/dev/null 2>&1 && docker_running 2>/dev/null; }; then
      log "Server not running - the change applies on the next start"; return 0
    fi
    if dc exec -T theisle isle-server rcon "$@" >/dev/null 2>&1; then ok "Applied live via RCON ($1)"
    else warn "Live RCON update failed - the change applies on the next restart"; fi
  else
    server_running 2>/dev/null || { log "Server not running - the change applies on the next start"; return 0; }
    command -v python3 >/dev/null 2>&1 || { warn "python3 missing - the change applies on the next restart"; return 0; }
    if ISLE_RCON_PASSWORD="$pw" python3 "$REPO_DIR/tools/isle_rcon.py" -p "$(cfg RCON_PORT)" "$@" >/dev/null 2>&1; then
      ok "Applied live via RCON ($1)"
    else
      warn "Live RCON update failed - the change applies on the next restart"
    fi
  fi
}

edit_list() {  # KEY add|remove|set items... -> updates server.conf, prints the new value
  local key="$1" op="$2"; shift 2
  local cur new item
  cur="$(cfg "$key")"
  case "$op" in
    set)    new="$(IFS=,; printf '%s' "$*")" ;;
    add)    new="$cur,$(IFS=,; printf '%s' "$*")" ;;
    remove) new="$cur"; for item in "$@"; do new="$(tr ',' '\n' <<< "$new" | grep -vxi -- "$item" | paste -sd, -)"; done ;;
  esac
  new="$(printf '%s' "$new" | list_norm)"
  set_conf "$key" "$new"
  printf '%s' "$new"
}

cmd_admins() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list) list_show "$(cfg ADMIN_STEAM_IDS)" "(no admins)" ;;
    add|remove)
      [[ $# -gt 0 ]] || die "Usage: isle-server admins $sub <SteamID64> [...]"
      check_ids "$@"
      local v; v="$(edit_list ADMIN_STEAM_IDS "$sub" "$@")"
      ok "Admins: $(list_count "$v") - restart the server to apply (the game reads admins at start)" ;;
    *) die "Usage: isle-server admins list|add|remove <SteamID64> [...]" ;;
  esac
}

cmd_whitelist() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list)
      printf 'Whitelist is %s\n' "$(is_true "$(cfg WHITELIST_ENABLED false)" && echo ON || echo OFF)"
      list_show "$(cfg WHITELIST_IDS)" "(no whitelisted players)" ;;
    add|remove)
      [[ $# -gt 0 ]] || die "Usage: isle-server whitelist $sub <SteamID64> [...]"
      check_ids "$@"
      local v; v="$(edit_list WHITELIST_IDS "$sub" "$@")"
      ok "Whitelist: $(list_count "$v") player(s)"
      if [[ "$sub" == add ]]; then live_rcon addwhitelist "$(IFS=,; printf '%s' "$*")"
      else live_rcon removewhitelist "$(IFS=,; printf '%s' "$*")"; fi ;;
    on|off)
      local was=false want=false
      is_true "$(cfg WHITELIST_ENABLED false)" && was=true
      [[ "$sub" == on ]] && want=true
      set_conf WHITELIST_ENABLED "$want"
      ok "Whitelist turned $sub"
      if [[ "$was" != "$want" ]]; then live_rcon togglewhitelist; fi
      if [[ "$want" == true && -z "$(cfg WHITELIST_IDS)" ]]; then warn "The whitelist is empty - nobody can join"; fi ;;
    *) die "Usage: isle-server whitelist list|add|remove <SteamID64> [...]|on|off" ;;
  esac
}

cmd_classes() {  # KEY SECTION RCON_CMD LABEL sub args...
  local key="$1" section="$2" rcmd="$3" label="$4"; shift 4
  local sub="${1:-list}"; shift || true
  local v
  case "$sub" in
    list)  list_show "$(cfg "$key")" "$([[ "$section" == playable ]] && echo '(all classes allowed)' || echo '(none disabled)')"; return ;;
    known) known_classes "$section"; return ;;
    set|add|remove)
      [[ $# -gt 0 ]] || die "Usage: isle-server $label $sub <Class> [...]"
      check_classes "$section" "$@"
      v="$(edit_list "$key" "$sub" "$@")" ;;
    reset) v=""; set_conf "$key" "" ;;
    preset)
      [[ "$section" == playable ]] || die "Roster presets are for the playable roster (classes)"
      local name="${1:-}" file
      if [[ -z "$name" ]]; then
        for file in "$REPO_DIR"/config/rosters/*.txt; do
          printf '  %-12s %s\n' "$(basename "$file" .txt)" "$(sed -n '1s/^# Roster: [^ ]* - //p' "$file")"
        done; return
      fi
      file="$REPO_DIR/config/rosters/$name.txt"
      [[ -f "$file" ]] || die "Unknown roster '$name' (see: isle-server classes preset)"
      mapfile -t items < <(grep -vE '^\s*(#|$)' "$file" | tr -d '\r ')
      if (( ${#items[@]} )); then check_classes playable "${items[@]}"; v="$(edit_list "$key" set "${items[@]}")"
      else v=""; set_conf "$key" ""; fi ;;
    *) die "Usage: isle-server $label list|known|set|add|remove <Class> [...]|reset$([[ "$section" == playable ]] && echo '|preset [name]')" ;;
  esac
  if [[ -z "$v" ]]; then
    ok "$label: $([[ "$section" == playable ]] && echo 'all classes allowed' || echo 'none disabled')"
    if [[ "$section" == playable ]]; then log "Restart the server to apply an unrestricted roster"; fi
  else
    ok "$label: $v"
    live_rcon "$rcmd" "$v"
  fi
}

# ------------------------------------------------------ profiles / presets --
overlay_desc() { sed -n '1s/^# [A-Za-z]*: [^ ]* - //p' "$1"; }
apply_overlay() {  # FILE... - write their KEY=VALUE lines into server.conf, validate, roll back on error
  local backup line key value file
  backup="$ISLE_CONF.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p "$ISLE_CONF" "$backup"
  for file in "$@"; do
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"; line="${line#"${line%%[![:space:]]*}"}"
      [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
      key="${line%%=*}"; value="${line#*=}"
      [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { warn "Skipping invalid line in $file: $line"; continue; }
      if [[ "$value" == \"*\" ]]; then value="${value:1:${#value}-2}"; fi
      set_conf "$key" "$value"
    done < "$file"
  done
  if check_config >/dev/null 2>&1; then
    ok "Applied $(for f in "$@"; do basename "$f" .conf; done | paste -sd' ' -) (previous config saved as $backup)"
    log "Restart the server to apply: isle-server restart"
  else
    check_config || true
    cp -p "$backup" "$ISLE_CONF"
    die "The result did not validate - server.conf was restored from $backup"
  fi
}
cmd_overlay() {  # KIND(profile|preset) sub args...
  local kind="$1"; shift
  local dir="$REPO_DIR/config/${kind}s" sub="${1:-list}" f
  shift || true
  case "$sub" in
    list)
      for f in "$dir"/*.conf; do printf '  %-18s %s\n' "$(basename "$f" .conf)" "$(overlay_desc "$f")"; done ;;
    show)
      [[ -n "${1:-}" && -f "$dir/$1.conf" ]] || die "Usage: isle-server $kind show <name> (see: isle-server $kind list)"
      printf '%s: %s\n' "$1" "$(overlay_desc "$dir/$1.conf")"
      grep -vE '^\s*(#|$)' "$dir/$1.conf" | while IFS='=' read -r k val; do
        printf '  %-28s %s -> %s\n' "$k" "$(cfg "$k" '(empty)')" "${val:-(empty)}"
      done ;;
    apply)
      [[ $# -gt 0 ]] || die "Usage: isle-server $kind apply <name>$([[ "$kind" == preset ]] && echo ' [<name> ...]')"
      if [[ "$kind" == profile && $# -gt 1 ]]; then die "Apply one profile at a time (combine presets with: isle-server preset apply a b c)"; fi
      local -a files=()
      for f in "$@"; do [[ -f "$dir/$f.conf" ]] || die "Unknown $kind '$f' (see: isle-server $kind list)"; files+=("$dir/$f.conf"); done
      apply_overlay "${files[@]}" ;;
    *) die "Usage: isle-server $kind list|show <name>|apply <name>" ;;
  esac
}

# ------------------------------------------------------------------ plugins --
cmd_plugins() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required for plugins"
  python3 "$REPO_DIR/tools/isle_plugins.py" --conf "$ISLE_CONF" --launcher "$SCRIPT_DIR/isle-server.sh" \
    --runtime "${RUNTIME:-native}" "$@"
}
run_hooks() {  # EVENT - run enabled plugins' hooks; never fails
  local enabled; enabled="$(dirname "$ISLE_CONF")/plugins/enabled.txt"
  [[ -s "$enabled" ]] || return 0
  command -v python3 >/dev/null 2>&1 || { warn "python3 missing - plugin hooks skipped"; return 0; }
  cmd_plugins hook "$1" || warn "A plugin hook for $1 failed"
}

config_tool() {  # dispatch shared by both runtimes; returns 1 if CMD is not a config tool
  local cmd="$1"; shift
  case "$cmd" in
    admins)     cmd_admins "$@" ;;
    whitelist)  cmd_whitelist "$@" ;;
    classes)    cmd_classes ALLOWED_CLASSES playable updateplayables classes "$@" ;;
    ai-classes) cmd_classes DISABLED_AI_CLASSES ai disableaiclasses ai-classes "$@" ;;
    profile)    cmd_overlay profile "$@" ;;
    preset)     cmd_overlay preset "$@" ;;
    plugins)    cmd_plugins "$@" ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------- docker mode ---
# RUNTIME=docker: the same commands drive the container defined in
# docker-compose.yml. The host server.conf is passed in as env_file and used
# for port interpolation, so one config file serves both runtimes.
RUNTIME_FLAG=""
resolve_runtime() {
  RUNTIME="${RUNTIME_FLAG:-${ISLE_RUNTIME:-$(cfg RUNTIME native)}}"
  RUNTIME="${RUNTIME,,}"
}

docker_require() {
  command -v docker >/dev/null 2>&1 \
    || die "RUNTIME=docker but the 'docker' command was not found. Install Docker Engine (https://docs.docker.com/engine/install/) or set RUNTIME=native."
  docker compose version >/dev/null 2>&1 \
    || die "Docker Compose v2 ('docker compose') is required. Install the docker-compose-plugin package."
  docker info >/dev/null 2>&1 \
    || die "Cannot talk to the Docker daemon. Start it (sudo systemctl start docker) or add your user to the 'docker' group."
  [[ -f "$REPO_DIR/docker-compose.yml" ]] || die "docker-compose.yml not found in $REPO_DIR"
}

dc() {  # docker compose bound to this repo and the host server.conf
  local ovr; ovr="$(overrides_dir)"; mkdir -p "$ovr" 2>/dev/null || true
  ISLE_CONF_FILE="$ISLE_CONF" ISLE_OVERRIDES_DIR="$ovr" docker compose --project-directory "$REPO_DIR" \
    -f "$REPO_DIR/docker-compose.yml" --env-file "$ISLE_CONF" "$@"
}

docker_running() { [[ -n "$(dc ps --status running -q theisle 2>/dev/null)" ]]; }
docker_require_stopped() {
  if docker_running; then die "The container is running - stop it before you $1"; fi
}

docker_image() {
  if is_true "$(cfg DOCKER_BUILD)"; then
    log "Building image $(cfg DOCKER_IMAGE) from $REPO_DIR"
    dc build
  elif ! docker image inspect "$(cfg DOCKER_IMAGE)" >/dev/null 2>&1; then
    log "Pulling image $(cfg DOCKER_IMAGE)"
    dc pull
  fi
}

docker_check() { check_config || die "Fix the configuration errors above, then try again"; }

docker_main() {
  local cmd="$1"; shift
  local -a nb=()
  is_true "$(cfg DOCKER_BUILD)" || nb=(--no-build)
  case "$cmd" in
    check) check_config && ok "Configuration OK ($ISLE_CONF, runtime docker)"; return ;;
    info)  docker_info; return ;;
  esac
  if config_tool "$cmd" "$@"; then return; fi
  docker_require
  case "$cmd" in
    install)
      ensure_rcon_password; docker_check
      docker_image
      dc up --no-start "${nb[@]}"
      ok "Install complete (Docker). The game downloads on first start: $0 start" ;;
    update|validate)
      docker_require_stopped "$cmd"; docker_check
      docker_image
      dc run --rm theisle "$cmd"
      run_hooks post-update ;;
    configure)
      docker_check
      dc run --rm theisle configure ;;
    start)
      ensure_rcon_password; docker_check
      dc up -d "${nb[@]}"
      ok "Container started - follow the startup with: $0 logs -f"
      run_hooks post-start ;;
    stop)
      if docker_running; then run_hooks pre-stop; fi
      dc stop
      ok "Container stopped"
      run_hooks post-stop ;;
    restart)
      if docker_running; then run_hooks pre-stop; fi
      dc stop
      run_hooks post-stop
      ensure_rcon_password; docker_check
      dc up -d "${nb[@]}"
      ok "Container restarted"
      run_hooks post-start ;;
    status)
      if docker_running; then dc exec -T theisle isle-server status
      else warn "Not running (container stopped or not created)"; return 3; fi ;;
    run)
      ensure_rcon_password; docker_check
      dc up "${nb[@]}" ;;
    logs)
      if [[ "${1:-}" == "-f" ]]; then dc logs --tail 100 -f theisle; else dc logs --tail 200 theisle; fi ;;
    backup)
      if docker_running; then dc exec -T theisle isle-server backup
      else dc run --rm theisle backup; fi
      run_hooks post-backup ;;
    restore)
      local file="${1:-}" target
      [[ -n "$file" ]] || die "Usage: $0 restore <backup.tar.gz | name in /data/backups>"
      docker_require_stopped restore
      if [[ -f "$file" ]]; then
        dc up --no-start "${nb[@]}"
        # A one-off run lets the entrypoint create the /data layout (fresh volume).
        dc run --rm theisle check >/dev/null
        dc cp "$file" "theisle:/data/backups/$(basename "$file")"
        target="/data/backups/$(basename "$file")"
      elif [[ "$file" == /data/* ]]; then
        target="$file"
      else
        target="/data/backups/$file"
      fi
      dc run --rm theisle restore "$target" ;;
    rcon|save)
      docker_running || die "The container is not running"
      dc exec -T theisle isle-server "$cmd" "$@" ;;
    *) usage; die "Unknown command: $cmd" ;;
  esac
}

docker_info() {
  local state="unknown (docker not available)" image_src="prebuilt"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    state="$(dc ps -a --format '{{.State}} ({{.Status}})' theisle 2>/dev/null | head -n1)"
    [[ -n "$state" ]] || state="not created"
  fi
  is_true "$(cfg DOCKER_BUILD)" && image_src="built from this repo"
  printf '%-14s: %s\n' \
    "Scripts" "v$SCRIPT_VERSION" \
    "Runtime" "docker" \
    "Config file" "$ISLE_CONF (passed to the container)" \
    "Compose file" "$REPO_DIR/docker-compose.yml" \
    "Image" "$(cfg DOCKER_IMAGE) ($image_src)" \
    "Container" "theisle - $state" \
    "Data" "Docker volume theisle-data (mounted at /data)" \
    "Ports" "game $(cfg GAME_PORT)/udp+tcp, queue $(cfg QUEUE_PORT)/tcp, rcon 127.0.0.1:$(cfg RCON_PORT)/tcp" \
    "Server name" "$(cfg SERVER_NAME)"
}

usage() { sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '/^=====/d'; }

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --docker)    RUNTIME_FLAG=docker; shift ;;
      --native)    RUNTIME_FLAG=native; shift ;;
      --runtime=*) RUNTIME_FLAG="${1#*=}"; shift ;;
      *) break ;;
    esac
  done
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    help|-h|--help) usage; return 0 ;;
    version|--version) printf 'isle-server.sh %s\n' "$SCRIPT_VERSION"; return 0 ;;
  esac
  load_config
  resolve_runtime
  case "$RUNTIME" in
    docker) docker_main "$cmd" "$@"; return ;;
    native) ;;
    *) check_config || true; die "Unknown runtime '$RUNTIME' (use native or docker)" ;;
  esac
  if config_tool "$cmd" "$@"; then return; fi
  if [[ $EUID -eq 0 && "$cmd" =~ ^(install|update|run|_watchdog|backup|restore)$ && -z "${ISLE_ALLOW_ROOT:-}" ]]; then
    die "Do not run the game server as root. Use the service user (e.g. 'sudo -u theisle $0 $cmd') or set ISLE_ALLOW_ROOT=1."
  fi
  case "$cmd" in
    install)   require_stopped install; ensure_rcon_password; check_config || die "Fix the configuration errors above, then try again"
               update_server "$@"; configure; ok "Install complete. Start with: $0 start" ;;
    update)    require_stopped update; update_server "$@"; run_hooks post-update ;;
    validate)  require_stopped validate; update_server --validate; run_hooks post-update ;;
    check)     check_config && ok "Configuration OK ($ISLE_CONF)" ;;
    version)   printf 'isle-server.sh %s\n' "$SCRIPT_VERSION" ;;
    configure) configure --force ;;
    start)     cmd_start; run_hooks post-start ;;
    stop)      if server_running; then run_hooks pre-stop; fi; cmd_stop; run_hooks post-stop ;;
    restart)   if server_running; then run_hooks pre-stop; fi; cmd_stop; run_hooks post-stop; sleep 2; cmd_start; run_hooks post-start ;;
    status)    cmd_status ;;
    run)       cmd_run ;;
    _watchdog) cmd_watchdog ;;
    logs)      cmd_logs "$@" ;;
    backup)    cmd_backup; run_hooks post-backup ;;
    restore)   require_stopped restore; cmd_restore "$@" ;;
    rcon)      cmd_rcon "$@" ;;
    save)      cmd_save ;;
    info)      cmd_info ;;
    *)         usage; die "Unknown command: $cmd" ;;
  esac
}

main "$@"
