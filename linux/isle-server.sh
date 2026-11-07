#!/usr/bin/env bash
# =============================================================================
#  isle-server.sh - The Isle (Evrima) dedicated server manager for Linux
#
#  Usage: isle-server.sh <command> [args]
#
#  Commands:
#    install      Install SteamCMD + server files and generate config
#    update       Update / validate server files through SteamCMD
#    configure    (Re)generate Game.ini and Engine.ini from server.conf
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
#    info         Print resolved paths and settings
#    help         This text
#
#  Environment:
#    ISLE_CONF          path to server.conf (default: <repo>/config/server.conf)
#    ISLE_NO_SYSTEMD=1  never delegate start/stop/status to systemd
#    ISLE_SERVICE       systemd unit name (default: theisle-server)
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ISLE_CONF="${ISLE_CONF:-$REPO_DIR/config/server.conf}"
ISLE_SERVICE="${ISLE_SERVICE:-theisle-server}"
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
           QUEUE_ENABLED:true EXTRA_ARGS:-log; do
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
}

write_ini() {  # $1 file, $2 render function
  local file="$1" tmp
  tmp="$(mktemp)"
  "$2" > "$tmp"
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
  if is_true "$(cfg RCON_ENABLED)" && [[ -z "$(cfg RCON_PASSWORD)" ]]; then
    warn "RCON_ENABLED=true but RCON_PASSWORD is empty - RCON will not be usable"
  fi
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
read_pid()  { [[ -f "$1" ]] && cat "$1" 2>/dev/null || true; }

cmd_run() {  # foreground; systemd ExecStart
  prepare_launch
  local bin; bin="$(server_binary)"
  local -a args; mapfile -t args < <(server_args)
  log "Launching: $bin ${args[*]}"
  cd "$SERVER_DIR"
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

cmd_start() {
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
  pid_alive "$spid" && kill -TERM "$spid" 2>/dev/null || true
  while { pid_alive "$spid" || pid_alive "$wpid"; } && (( t < timeout )); do sleep 1; t=$((t + 1)); done
  if pid_alive "$spid"; then warn "Graceful stop timed out - killing"; kill -KILL "$spid" 2>/dev/null || true; fi
  pid_alive "$wpid" && kill -TERM "$wpid" 2>/dev/null || true
  rm -f "$STATE_DIR/server.pid" "$STATE_DIR/watchdog.pid"
  ok "Server stopped"
}

cmd_status() {
  if service_installed; then systemctl --no-pager status "$ISLE_SERVICE" || true; return; fi
  if is_running; then ok "Running (server PID $(read_pid "$STATE_DIR/server.pid"), watchdog PID $(read_pid "$STATE_DIR/watchdog.pid"))"
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
Config file   : $ISLE_CONF
SteamCMD dir  : $STEAMCMD_DIR
Server dir    : $SERVER_DIR
Config (ini)  : $INI_DIR
Backup dir    : $BACKUP_DIR
App / branch  : $(cfg STEAM_APP_ID) / $(cfg STEAM_BRANCH)
Ports         : game $(cfg GAME_PORT)/udp, queue $(cfg QUEUE_PORT)/tcp, rcon $(cfg RCON_PORT)/tcp
Server name   : $(cfg SERVER_NAME)
systemd unit  : $(service_installed && echo "$ISLE_SERVICE (installed)" || echo "not installed")
EOF
}

usage() { sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '/^=====/d'; }

main() {
  local cmd="${1:-help}"; shift || true
  if [[ $EUID -eq 0 && "$cmd" =~ ^(install|update|run|_watchdog|backup|restore)$ && -z "${ISLE_ALLOW_ROOT:-}" ]]; then
    die "Do not run the game server as root. Use the service user (e.g. 'sudo -u theisle $0 $cmd') or set ISLE_ALLOW_ROOT=1."
  fi
  case "$cmd" in
    help|-h|--help) usage; return 0 ;;
  esac
  load_config
  case "$cmd" in
    install)   update_server "$@"; configure; ok "Install complete. Start with: $0 start" ;;
    update)    update_server "$@" ;;
    validate)  update_server --validate ;;
    configure) configure --force ;;
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    restart)   cmd_stop; sleep 2; cmd_start ;;
    status)    cmd_status ;;
    run)       cmd_run ;;
    _watchdog) cmd_watchdog ;;
    logs)      cmd_logs "$@" ;;
    backup)    cmd_backup ;;
    restore)   cmd_restore "$@" ;;
    rcon)      cmd_rcon "$@" ;;
    save)      cmd_save ;;
    info)      cmd_info ;;
    *)         usage; die "Unknown command: $cmd" ;;
  esac
}

main "$@"
