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
#    logs [-f] [game|server|launcher|ui|list]
#                 Show (or follow) a log: the game's own log (default), the
#                 rotated server console / launcher / web UI logs, or list them
#    backup       Archive save data / config to BACKUP_DIR (+ second copy and off-site, 3-2-1)
#    backup schedule [show|set "<cron>"|off]   when the scheduled task backs up
#    backup status [--json]                     schedule, last backup and the 3-2-1 check
#    backup strategy [show|copy <dir>|offsite <target>|keep <N>|test]   configure the 3-2-1 strategy
#    backup tick  run by the per-minute timer: backs up when BACKUP_SCHEDULE is due
#    restore <f>  Restore a backup archive (server must be stopped)
#    rcon <cmd>   Send an RCON command (see tools/isle_rcon.py)
#    save         Ask the server to save via RCON
#    admins       list [--refresh]|add|remove <SteamID64...>         (admins, applied on restart)
#    whitelist    list [--refresh]|add|remove <SteamID64...>|on|off  (live via RCON when running)
#                 lists and adds show each player's Steam name (cached; STEAM_NAME_LOOKUP)
#    steam names [--refresh] <SteamID64...>   resolve SteamID64s to Steam names
#    classes      list|known|set|add|remove <Class...>|reset|preset [roster]
#                 types | select|add-type|remove-type <type...> | humans [on|off]
#                 (types: carnivore herbivore omnivore flying aquatic)
#    mutations    list | enable <Name> [value] | disable <Name...> | reset
#    admin        players | player [SteamID64] | dm <id> <text> | kick <id> [reason] |
#                 ban <id> [reason] | announce <text> | save | wipecorpses | details |
#                 queue | playables | pause|migrations|humans|chat|ai-learning|
#                 netupdate on|off | growth on|off|<multiplier> | custom "<command>"
#                 live admin commands over RCON (the server must be running)
#    ai-classes   list|known|set|add|remove <Class...>|reset  (disabled AI)
#    ai           status|on|off|density <n>|interval <s>|preset <name>
#                 AI spawning, density (live via RCON), spawn interval, AI presets
#    maps         list|show [name]|set <name> [--keep-branch]
#                 known maps (config/maps.txt); set also switches STEAM_BRANCH
#    profile      list|show <name>|apply <name>          (whole play styles)
#    preset       list|show <name>|apply <name...>       (stackable tweaks)
#    plugins      list|search|info|install|remove|enable|disable|update|
#                 preset|run|config|sources ...          (see PLUGINS.md)
#    snapshot     create [--include LIST] [--output F] | restore F [--include LIST]
#                 [--overwrite] [--all-settings] [--stop] | info F | list
#                 portable snapshot to move/clone a server (any OS, any runtime)
#    ui [--host H] [--port P] [--open] [--cert F --key F]
#                 Web UI + REST API (OpenAPI docs at /docs); see UI.md
#    ui-token [--rotate]  Show (or replace) the web UI access token
#    setup [--yes]    first-time setup wizard (machine check, name, map, admins, play style, backups)
#    recommend [--json | --apply [KEY...]]   settings that fit this machine's CPU, memory and disk
#    info         Print resolved paths and settings
#    version      Print the script version
#    help         This text
#
#  Environment:
#    ISLE_CONF          path to server.conf (default: <repo>/config/server.conf)
#    ISLE_NO_SYSTEMD=1  never delegate start/stop/status to systemd
#    ISLE_SERVICE       systemd unit name (default: theisle-server)
#    ISLE_RUNTIME       native | docker (overrides RUNTIME in server.conf)
#    ISLE_LOG_DIR       log folder (overrides LOG_DIR in server.conf)
#
#  Logs: <LOG_DIR>/KIND_yyyymmdd_hhmmss.log (launcher, server, ui), rotated at
#  LOG_MAX_SIZE_MB, LOG_RETENTION files kept per kind, in TIMEZONE (local|utc).
#
#  Project: https://github.com/kyroskoh/the-isle-dedicated-server
#  Made with ♥ by Kyros Koh (https://github.com/kyroskoh)
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ISLE_CONF="${ISLE_CONF:-$REPO_DIR/config/server.conf}"
ISLE_SERVICE="${ISLE_SERVICE:-theisle-server}"
SCRIPT_VERSION="$(cat "$REPO_DIR/VERSION" 2>/dev/null || echo unknown)"
PROJECT_URL="https://github.com/kyroskoh/the-isle-dedicated-server"
AUTHOR="Kyros Koh"; AUTHOR_URL="https://github.com/kyroskoh"
version_text() { printf 'isle-server.sh %s\nProject: %s\nMade with ♥ by %s (%s)\n' "$SCRIPT_VERSION" "$PROJECT_URL" "$AUTHOR" "$AUTHOR_URL"; }
STEAMCMD_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"

# ----------------------------------------------------------------- output ---
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[36m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_RST=""
fi
log()  { printf '%s[%s]%s %s\n' "$C_BLU" "$(date '+%F %T')" "$C_RST" "$*"; file_log INFO "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; file_log OK "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; file_log WARN "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; file_log FAIL "$*"; exit 1; }

# ------------------------------------------------------------------- logs ---
# Every log file is KIND_yyyymmdd_hhmmss.log in LOG_DIR (PRD LOG-01..04).
LOG_TO_FILE=0; LAUNCHER_LOG=""; LOG_DIR=""
LOG_NAME_RE='_[0-9]{8}_[0-9]{6}(_[0-9]+)?\.log$'
stamp() { date +%Y%m%d_%H%M%S; }            # TZ=UTC0 is exported when TIMEZONE=utc
file_log() {  # LEVEL MESSAGE... - append to the current launcher log (commands that change something)
  (( LOG_TO_FILE )) || return 0
  if [[ -z "$LAUNCHER_LOG" ]]; then LAUNCHER_LOG="$(log_file launcher)" || { LOG_TO_FILE=0; return 0; }; fi
  printf '[%s] %-4s %s\n' "$(date '+%F %T %Z')" "$1" "${*:2}" >> "$LAUNCHER_LOG" 2>/dev/null || LOG_TO_FILE=0
}
log_files() {  # KIND - that kind's files, oldest first
  [[ -d "$LOG_DIR" ]] || return 0
  find "$LOG_DIR" -maxdepth 1 -type f -name "$1_*.log" -printf '%f\n' 2>/dev/null | grep -E "^$1$LOG_NAME_RE" | LC_ALL=C sort || true
}
prune_logs() {  # KIND - keep the newest LOG_RETENTION files (0 = keep all)
  local keep f; keep="$(cfg LOG_RETENTION 14)"
  [[ "$keep" =~ ^[0-9]+$ ]] && (( keep > 0 )) || return 0
  log_files "$1" | head -n -"$keep" | while IFS= read -r f; do rm -f -- "$LOG_DIR/$f"; done
}
new_log_name() {  # KIND - a fresh KIND_<stamp>.log path; within one second, _N past the highest N
  local st n=-1 f m; st="$(stamp)"
  while IFS= read -r f; do
    [[ "$f" == "$1_$st.log" ]] && (( n < 0 )) && n=0
    if [[ "$f" =~ ^$1_${st}_([0-9]+)\.log$ ]]; then m="${BASH_REMATCH[1]}"; (( 10#$m > n )) && n=$((10#$m)); fi
  done < <(log_files "$1")
  if (( n < 0 )); then printf '%s' "$LOG_DIR/$1_$st.log"; else printf '%s' "$LOG_DIR/$1_${st}_$((n + 1)).log"; fi
}
log_file() {  # KIND - the file to append to: the newest one under LOG_MAX_SIZE_MB, else a new one
  mkdir -p "$LOG_DIR" 2>/dev/null && [[ -w "$LOG_DIR" ]] || return 1
  local max last f; max="$(cfg LOG_MAX_SIZE_MB 20)"; [[ "$max" =~ ^[0-9]+$ ]] || max=20
  last="$(log_files "$1" | tail -n1)"
  if [[ -n "$last" ]] && { (( max == 0 )) || (( $(wc -c < "$LOG_DIR/$last") < max * 1048576 )); }; then
    printf '%s' "$LOG_DIR/$last"; return 0
  fi
  f="$(new_log_name "$1")"; : > "$f" || return 1
  prune_logs "$1"
  printf '%s' "$f"
}
log_writer() {  # KIND [--tee] - stdin -> rotating KIND logs (python3), else one plain file
  if command -v python3 >/dev/null 2>&1; then
    exec python3 "$REPO_DIR/tools/isle_logs.py" --conf "$ISLE_CONF" write "$@"
  fi
  local f; f="$(new_log_name "$1")"; prune_logs "$1"
  if [[ "${2:-}" == --tee ]]; then exec tee -a "$f"; else exec cat >> "$f"; fi
}
prune_game_logs() {  # the game renames its log to TheIsle-backup-<date>.log on every start
  local keep dir="$SERVER_DIR/TheIsle/Saved/Logs"; keep="$(cfg LOG_RETENTION 14)"
  [[ -d "$dir" && "$keep" =~ ^[0-9]+$ ]] && (( keep > 0 )) || return 0
  find "$dir" -maxdepth 1 -type f -name 'TheIsle-backup-*.log' -printf '%T@ %p\n' | sort -rn | tail -n +$((keep + 1)) \
    | cut -d' ' -f2- | while IFS= read -r f; do rm -f -- "$f"; done
}

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
           DOCKER_IMAGE:theisle-server:latest TIMEZONE:local LOG_RETENTION:14 LOG_MAX_SIZE_MB:20 \
           "BACKUP_SCHEDULE:0 5 * * *"; do
    [[ -z "${CFG[${k%%:*}]:-}" ]] && CFG[${k%%:*}]="${k#*:}"
  done
  STEAMCMD_DIR="${CFG[STEAMCMD_DIR]}"
  SERVER_DIR="${CFG[SERVER_DIR]}"
  BACKUP_DIR="${CFG[BACKUP_DIR]}"
  INI_DIR="$SERVER_DIR/TheIsle/Saved/Config/LinuxServer"
  STATE_DIR="$SERVER_DIR/.isle-scripts"
  LOG_FILE="$SERVER_DIR/TheIsle/Saved/Logs/TheIsle.log"
  LOG_DIR="${ISLE_LOG_DIR:-${CFG[LOG_DIR]:-$REPO_DIR/logs}}"
  # TIMEZONE=utc: every timestamp and dated file name (and child tools) use UTC
  case "${CFG[TIMEZONE],,}" in utc|gmt|z) export TZ=UTC0 ISLE_TIMEZONE=utc ;; *) export ISLE_TIMEZONE=local ;; esac
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
           REGION_SPAWNING REGION_SPAWN_COOLDOWN STEAM_NAME_LOOKUP)
NUMBER_KEYS=(GROWTH_MULTIPLIER CORPSE_DECAY_MULTIPLIER PLANT_SPAWN_MULTIPLIER AI_DENSITY
             DAY_LENGTH_MINUTES NIGHT_LENGTH_MINUTES WEATHER_MIN_INTERVAL WEATHER_MAX_INTERVAL)
INT_KEYS=(MAX_MIGRATION_TIME MASS_MIGRATION_TIME MASS_MIGRATION_DISABLE_TIME STOP_TIMEOUT BACKUP_RETENTION
          REGION_SPAWN_COOLDOWN_SECONDS NET_TICK_RATE AI_SPAWN_INTERVAL STEAM_NAME_CACHE_DAYS)

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
  if command -v python3 >/dev/null 2>&1; then
    v="$(python3 "$REPO_DIR/tools/isle_cron.py" check "$(cfg BACKUP_SCHEDULE)" 2>&1 >/dev/null)" || errors+=("BACKUP_SCHEDULE: $v")
    if [[ -n "$(cfg BACKUP_OFFSITE_TARGET)" ]]; then
      v="$(python3 "$REPO_DIR/tools/isle_offsite.py" parse "$(cfg BACKUP_OFFSITE_TARGET)" 2>&1 >/dev/null)" || errors+=("BACKUP_OFFSITE_TARGET: $v")
    fi
  fi
  v="$(cfg BACKUP_COPY_DIR)"
  if [[ -n "$v" && "$v" != /* ]]; then errors+=("BACKUP_COPY_DIR='$v' must be an absolute path"); fi
  for k in BACKUP_COPY_RETENTION BACKUP_OFFSITE_RETENTION; do
    v="$(cfg "$k")"
    if [[ -n "$v" ]] && ! [[ "$v" =~ ^[0-9]+$ ]]; then errors+=("$k='$v' must be a whole number (0 = keep all, empty = BACKUP_RETENTION)"); fi
  done
  if [[ -n "$(cfg ENABLED_MUTATIONS)" ]]; then
    local _m
    IFS=';' read -ra _m <<< "$(cfg ENABLED_MUTATIONS)"
    for v in "${_m[@]}"; do
      [[ -z "${v// }" ]] && continue
      [[ "$v" =~ ^[A-Za-z][A-Za-z\ \-]*:[0-9]+([.][0-9]+)?$ ]] || { errors+=("ENABLED_MUTATIONS entry '$v' must be Name:value"); continue; }
      mutation_line "${v%:*}" >/dev/null || warnings+=("ENABLED_MUTATIONS: '${v%:*}' is not in config/mutations.txt")
    done
  fi
  case "$(cfg TIMEZONE local)" in local|LOCAL|Local|utc|UTC|Utc) ;; *) errors+=("TIMEZONE='$(cfg TIMEZONE)' must be local or utc") ;; esac
  for k in LOG_RETENTION LOG_MAX_SIZE_MB; do
    v="$(cfg "$k")"; [[ "$v" =~ ^[0-9]+$ ]] || errors+=("$k='$v' must be a whole number (0 = no limit)")
  done
  v="$(cfg UI_PORT)"
  if [[ -n "$v" ]] && { ! [[ "$v" =~ ^[0-9]+$ ]] || (( 10#$v < 1 || 10#$v > 65535 )); }; then
    errors+=("UI_PORT='$v' is not a port number (1-65535)")
  fi
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
  if [[ -n "$(cfg MAP_NAME)" ]] && [[ -f "$REPO_DIR/config/maps.txt" ]] && ! map_line "$(cfg MAP_NAME)" >/dev/null; then
    warnings+=("MAP_NAME='$(cfg MAP_NAME)' is not in config/maps.txt (known: $(map_names | paste -sd, -)) - names are case-sensitive")
  fi
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

# ------------------------------------------------- onboarding (PRD ONB-01..05)
conf_set() { set_conf "$1" "$2"; CFG[$1]="$2"; }   # write and keep the in-memory value current
recommend_pairs() {  # KEY... -> "KEY<TAB>VALUE" for the recommended settings (all, or only the keys given)
  python3 "$REPO_DIR/tools/isle_sysinfo.py" --conf "$ISLE_CONF" --json | python3 -c '
import json, sys
want = set(sys.argv[1:])
for r in json.load(sys.stdin)["recommendations"]:
    if not want or r["key"] in want:
        print("%s\t%s" % (r["key"], r["value"]))' "$@"
}
cmd_recommend() {  # [--json] | [--apply [KEY...]]
  command -v python3 >/dev/null 2>&1 || die "python3 is required for recommendations"
  case "${1:-}" in
    --json) python3 "$REPO_DIR/tools/isle_sysinfo.py" --conf "$ISLE_CONF" --json ;;
    --apply)
      shift
      local k v n=0
      while IFS=$'\t' read -r k v; do
        [[ -n "$k" ]] || continue
        conf_set "$k" "$v"; n=$((n + 1)); ok "$k=$v"
      done < <(recommend_pairs "$@")
      (( n )) || die "Nothing to apply (unknown key?) - see: $0 recommend"
      check_config >/dev/null || warn "Check the configuration: $0 check" ;;
    "") python3 "$REPO_DIR/tools/isle_sysinfo.py" --conf "$ISLE_CONF"
        printf '\nApply them with: %s recommend --apply [KEY...]\n' "$0" ;;
    *) die "Usage: $0 recommend [--json | --apply [KEY...]]" ;;
  esac
}
SETUP_YES=0
ask() {  # QUESTION DEFAULT -> the answer (the default when not interactive)
  local ans=""
  if (( SETUP_YES )); then printf '%s' "$2"; return; fi
  read -r -p "  $1${2:+ [$2]}: " ans || true
  printf '%s' "${ans:-$2}"
}
ask_yes() {  # QUESTION -> 0 for yes (default yes)
  local a; a="$(ask "$1 (Y/n)" "")"; [[ ! "${a,,}" =~ ^n ]]
}
cmd_setup() {  # first-time setup wizard: [--yes] uses the recommendations and defaults without asking
  local v map i names=() ids=() n_step=7
  [[ "${1:-}" == --yes || "${1:-}" == -y ]] && SETUP_YES=1
  [[ -t 0 || -n "${ISLE_SETUP_INTERACTIVE:-}" ]] || SETUP_YES=1   # tests answer through a pipe
  command -v python3 >/dev/null 2>&1 || die "python3 is required for the setup wizard"
  printf '\n%sThe Isle server setup%s - %s\n' "$C_GRN" "$C_RST" "$( (( SETUP_YES )) && echo 'using recommendations and defaults' || echo 'press Enter to keep the value in [brackets]')"
  ensure_rcon_password   # first: later steps (profiles) validate the whole configuration
  printf '\n[1/%d] Your machine\n' "$n_step"
  python3 "$REPO_DIR/tools/isle_sysinfo.py" --conf "$ISLE_CONF" | sed 's/^/  /'
  if ask_yes "Use these recommended settings?"; then
    while IFS=$'\t' read -r i v; do [[ -n "$i" ]] && conf_set "$i" "$v"; done < <(recommend_pairs)
    ok "Recommended settings applied"
  fi
  printf '\n[2/%d] Name and password\n' "$n_step"
  v="$(ask "Server name (shown in the server browser)" "$(cfg SERVER_NAME)")"
  if [[ "$v" != *'"'* && -n "$v" ]]; then conf_set SERVER_NAME "$v"; else warn "Kept the old name (no double quotes allowed)"; fi
  v="$(ask "Join password (empty = public server; '-' keeps the current one)" "-")"
  [[ "$v" == "-" ]] || conf_set SERVER_PASSWORD "$v"
  printf '\n[3/%d] Map and size\n' "$n_step"
  mapfile -t names < <(map_names)
  (( ${#names[@]} )) && printf '  Maps: %s\n' "${names[*]}"
  map="$(ask "Map" "$(cfg MAP_NAME Gateway)")"
  if [[ "$map" != "$(cfg MAP_NAME)" ]]; then
    if (cmd_maps set "$map"); then load_config; else warn "Kept map $(cfg MAP_NAME)"; fi
  fi
  v="$(ask "Max players" "$(cfg MAX_PLAYERS 100)")"
  if [[ "$v" =~ ^[0-9]+$ ]] && (( v > 0 )); then conf_set MAX_PLAYERS "$v"; else warn "Kept MAX_PLAYERS=$(cfg MAX_PLAYERS)"; fi
  printf '\n[4/%d] Admins\n' "$n_step"
  v="$(ask "Your SteamID64 for in-game admin (empty = skip; steamid.io finds it)" "")"
  if [[ -n "$v" ]]; then
    read -ra ids <<< "${v//,/ }"
    if (cmd_admins add "${ids[@]}"); then load_config; else warn "Not added - add admins later with: $0 admins add <SteamID64>"; fi
  fi
  printf '\n[5/%d] Play style\n' "$n_step"
  cmd_overlay profile list | sed 's/^/  /'
  v="$(ask "Profile to apply (empty = keep the current settings)" "")"
  if [[ -n "$v" ]]; then (cmd_overlay profile apply "$v") || warn "Profile not applied"; load_config; fi
  printf '\n[6/%d] Backups (3-2-1)\n' "$n_step"
  v="$(ask "Backup schedule (cron, @daily or off)" "$(cfg BACKUP_SCHEDULE)")"
  if python3 "$REPO_DIR/tools/isle_cron.py" check "$v" >/dev/null 2>&1; then conf_set BACKUP_SCHEDULE "$v"; else warn "Not a valid schedule - kept $(cfg BACKUP_SCHEDULE)"; fi
  v="$(ask "Second copy on another disk (absolute folder, empty = skip)" "$(cfg BACKUP_COPY_DIR)")"
  if [[ -z "$v" || "$v" == /* ]]; then conf_set BACKUP_COPY_DIR "$v"; else warn "Must be an absolute folder - skipped"; fi
  v="$(ask "Off-site target (dir:/path, rclone:remote:path, ssh://user@host/path; empty = skip)" "$(cfg BACKUP_OFFSITE_TARGET)")"
  if [[ -z "$v" ]] || python3 "$REPO_DIR/tools/isle_offsite.py" parse "$v" >/dev/null; then conf_set BACKUP_OFFSITE_TARGET "$v"; else warn "Skipped the off-site target"; fi
  printf '\n[7/%d] Check\n' "$n_step"
  if check_config; then
    printf '%s\n' "$(date '+%F %T')" > "$(state_file setup-done)" 2>/dev/null || true
    ok "Setup complete - settings saved in $ISLE_CONF"
    printf '\nNext steps:\n  %s install        download the game server (first time, ~20 GB)\n  %s start          start it\n' "$0" "$0"
    printf '  %s ui             the web UI (it has a guided tour)\n  %s backup strategy test   check your backup targets\n' "$0" "$0"
  else
    warn "Fix the errors above (edit $ISLE_CONF or run $0 setup again)"; return 1
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
    curl -fsSL "$STEAMCMD_URL" -o "$tmp" || { rm -f "$tmp"; die "Could not download SteamCMD from $STEAMCMD_URL"; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$STEAMCMD_URL" || { rm -f "$tmp"; die "Could not download SteamCMD from $STEAMCMD_URL"; }
  else
    die "Neither curl nor wget is installed (run linux/install.sh as root first)"
  fi
  tar -xzf "$tmp" -C "$STEAMCMD_DIR" || { rm -f "$tmp"; die "The SteamCMD download is not a valid archive"; }
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
  # EnabledMutations: empty = every mutation (game default); otherwise ONLY the listed ones
  local mut name val
  if [[ -n "$(cfg ENABLED_MUTATIONS)" ]]; then
    IFS=';' read -ra mut <<< "$(cfg ENABLED_MUTATIONS)"
    for name in "${mut[@]}"; do
      [[ -n "${name// }" ]] || continue
      val="${name##*:}"; name="${name%:*}"
      printf 'EnabledMutations=%s, %s\n' "$name" "$val"
    done
  fi
  printf 'bEnableDiets=%s\n' "$(ue_bool "$(cfg ENABLE_DIETS true)")"
  printf 'bEnablePatrolZones=%s\n' "$(ue_bool "$(cfg ENABLE_PATROL_ZONES true)")"
  printf 'bAllowRecordingReplay=%s\n' "$(ue_bool "$(cfg ALLOW_RECORDING_REPLAY true)")"
  printf 'bSpawnPlants=%s\n' "$(ue_bool "$(cfg SPAWN_PLANTS true)")"
  printf 'PlantSpawnMultiplier=%s\n' "$(cfg PLANT_SPAWN_MULTIPLIER 1)"
  printf 'bSpawnAI=%s\n' "$(ue_bool "$(cfg SPAWN_AI true)")"
  printf 'AIDensity=%s\n' "$(cfg AI_DENSITY 1)"
  printf 'AISpawnInterval=%s\n' "$(cfg AI_SPAWN_INTERVAL 40)"
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
    # Subshell: a failing update calls die/exit; that must not take the launcher
    # down when a working build is already installed (e.g. Steam is unreachable).
    ( update_server ) || { server_binary >/dev/null || die "No server installed"; warn "Update failed - starting existing build"; }
  fi
  configure
  link_steamclient >/dev/null 2>&1 || true
  mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"
  mkdir -p "$LOG_DIR" 2>/dev/null || warn "Cannot create the log folder $LOG_DIR"
  prune_logs server; prune_logs launcher; prune_logs ui; prune_game_logs
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
  elif command -v sudo >/dev/null 2>&1; then if [[ -t 0 ]]; then sudo systemctl "$@"; else sudo -n systemctl "$@"; fi
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
  # Console output goes to the journal / docker logs AND to rotating server_<stamp>.log files.
  if mkdir -p "$LOG_DIR" 2>/dev/null && [[ -w "$LOG_DIR" ]]; then exec > >(log_writer server --tee) 2>&1; fi
  exec "$bin" "${args[@]}"
}

cmd_watchdog() {  # background supervisor used by "start" without systemd
  # PID file first: the update in prepare_launch can take minutes, and "start"
  # / "status" must see the server as starting meanwhile.
  mkdir -p "$STATE_DIR"; echo $$ > "$STATE_DIR/watchdog.pid"
  prepare_launch
  local bin; bin="$(server_binary)"
  local -a args; mapfile -t args < <(server_args)
  rm -f "$STATE_DIR/stop.flag"
  trap 'touch "$STATE_DIR/stop.flag"; pid_alive "$(read_pid "$STATE_DIR/server.pid")" && kill -TERM "$(read_pid "$STATE_DIR/server.pid")"' INT TERM
  cd "$SERVER_DIR"
  while :; do
    log "Launching: $bin ${args[*]} (console: $LOG_DIR/server_*.log)"
    "$bin" "${args[@]}" > >(log_writer server) 2>&1 &
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
  mkdir -p "$STATE_DIR" "$LOG_DIR"
  # watchdog messages go to launcher_*.log, the game's console to server_*.log
  local out; out="$(log_file launcher)" || out=/dev/null
  log "Starting server in the background (logs: $LOG_DIR)"
  nohup "$SCRIPT_DIR/isle-server.sh" _watchdog >> "$out" 2>&1 < /dev/null &
  sleep 3
  if is_running; then ok "Server starting (watchdog PID $(read_pid "$STATE_DIR/watchdog.pid"))"
  else die "Server failed to start - check $LOG_DIR"; fi
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
  if service_installed; then
    systemctl --no-pager status "$ISLE_SERVICE" || true
    systemctl is-active --quiet "$ISLE_SERVICE" || return 3
    return 0
  fi
  if is_running; then
    local wd; wd="$(read_pid "$STATE_DIR/watchdog.pid")"
    ok "Running (server PID $(read_pid "$STATE_DIR/server.pid")${wd:+, watchdog PID $wd})"
  else warn "Not running"; return 3; fi
}

cmd_logs() {  # [-f] [game|server|launcher|ui|list]
  local follow="" which="game" f
  for f in "$@"; do case "$f" in -f|--follow) follow=1 ;; game|server|launcher|ui|list) which="$f" ;; *) die "Usage: $0 logs [-f] [game|server|launcher|ui|list]" ;; esac; done
  if [[ "$which" == list ]]; then
    [[ -d "$LOG_DIR" ]] || { warn "No logs yet in $LOG_DIR"; return 0; }
    find "$LOG_DIR" -maxdepth 1 -type f -name '*.log' -printf '%f\t%s bytes\n' | grep -E "$LOG_NAME_RE|bytes" | LC_ALL=C sort -r; return 0
  fi
  if [[ "$which" == game ]]; then
    f="$LOG_FILE"
    if [[ ! -f "$f" ]]; then
      f="$(log_files server | tail -n1)"; [[ -n "$f" ]] && f="$LOG_DIR/$f"
    fi
  else
    f="$(log_files "$which" | tail -n1)"; [[ -n "$f" ]] && f="$LOG_DIR/$f"
  fi
  if [[ -z "$f" || ! -f "$f" ]]; then
    if service_installed; then exec journalctl -u "$ISLE_SERVICE" -n 200 ${follow:+-f}; fi
    die "No $which log yet (looked in $LOG_FILE and $LOG_DIR)"
  fi
  if [[ -n "$follow" ]]; then exec tail -n 100 -F "$f"; else tail -n 200 "$f"; fi
}

# ---------------------------------------------------------------- backups ---
cmd_backup() {
  local saved="$SERVER_DIR/TheIsle/Saved"
  [[ -d "$saved" ]] || die "Nothing to back up ($saved does not exist)"
  mkdir -p "$BACKUP_DIR"
  is_running && is_true "$(cfg SAVE_BEFORE_STOP)" && cmd_save
  local file; file="$BACKUP_DIR/theisle-backup_$(stamp).tar.gz"
  log "Creating backup $file"
  tar -czf "$file" -C "$SERVER_DIR/TheIsle" --exclude='Saved/Logs' --exclude='Saved/Crashes' Saved \
    -C "$(dirname "$ISLE_CONF")" "$(basename "$ISLE_CONF")" 2>/dev/null \
    || tar -czf "$file" -C "$SERVER_DIR/TheIsle" --exclude='Saved/Logs' --exclude='Saved/Crashes' Saved
  ok "Backup written ($(du -h "$file" | cut -f1))"
  backup_321 "$file"
  local keep; keep="$(cfg BACKUP_RETENTION 10)"
  if [[ "$keep" =~ ^[0-9]+$ ]] && (( keep > 0 )); then
    find "$BACKUP_DIR" -maxdepth 1 -name 'theisle-*.tar.gz' -printf '%T@ %p\n' | sort -rn \
      | tail -n +$((keep + 1)) | cut -d' ' -f2- | while IFS= read -r old; do rm -f -- "$old"; log "Pruned $old"; done
  fi
}

# -------------------------------------------------- 3-2-1 and the schedule ---
# 3 copies (the live world + BACKUP_DIR + BACKUP_COPY_DIR), 2 media (BACKUP_COPY_DIR on another disk),
# 1 off-site (BACKUP_OFFSITE_COMMAND or the offsite-backup plugin). PRD BAK-06..09.
state_file() { printf '%s/.%s' "$(dirname "$ISLE_CONF")" "$1"; }
backup_321() {  # FILE - second copy + off-site for a finished backup archive
  local file="$1" copy keep cmd rc
  copy="$(cfg BACKUP_COPY_DIR)"
  if [[ -n "$copy" ]]; then
    if mkdir -p "$copy" 2>/dev/null && cp -- "$file" "$copy/"; then
      ok "Second copy: $copy/$(basename "$file")"
      if [[ "$(stat -c %d "$copy" 2>/dev/null)" == "$(stat -c %d "$(dirname "$file")" 2>/dev/null)" ]]; then
        warn "BACKUP_COPY_DIR is on the same disk as the backups - use another disk for the '2 media' of 3-2-1"
      fi
      keep="$(cfg BACKUP_COPY_RETENTION)"; [[ -n "$keep" ]] || keep="$(cfg BACKUP_RETENTION 10)"
      if [[ "$keep" =~ ^[0-9]+$ ]] && (( keep > 0 )); then
        find "$copy" -maxdepth 1 -name 'theisle-*' -printf '%T@ %p\n' | sort -rn | tail -n +$((keep + 1)) | cut -d' ' -f2- \
          | while IFS= read -r old; do rm -f -- "$old"; done
      fi
    else
      warn "Could not copy the backup to BACKUP_COPY_DIR=$copy"
    fi
  fi
  cmd="$(cfg BACKUP_OFFSITE_COMMAND)"
  if [[ -n "$cmd" ]]; then
    # {file} is replaced by the quoted archive path; $BACKUP_FILE is set too (e.g. rclone copy {file} remote:theisle)
    cmd="${cmd//\{file\}/$(printf '%q' "$file")}"
    log "Off-site copy: $cmd"
    rc=0; BACKUP_FILE="$file" timeout 3600 bash -c "$cmd" || rc=$?
    printf '%s %s %s\n' "$(date '+%F %T %Z')" "$rc" "$(basename "$file")" > "$(state_file backup-offsite)" 2>/dev/null || true
    if (( rc == 0 )); then ok "Off-site copy done"; else warn "Off-site copy failed (exit $rc) - the local backups are fine"; fi
  fi
  if [[ -n "$(cfg BACKUP_OFFSITE_TARGET)" ]]; then   # dir: / rclone: / ssh:// - no shell involved (tools/isle_offsite.py)
    local msg
    if ! command -v python3 >/dev/null 2>&1; then warn "python3 is required for BACKUP_OFFSITE_TARGET - off-site copy skipped"; return 0; fi
    log "Off-site copy to $(cfg BACKUP_OFFSITE_TARGET)"
    if msg="$(timeout 4000 python3 "$REPO_DIR/tools/isle_offsite.py" --conf "$ISLE_CONF" send "$file" 2>&1)"; then ok "$msg"
    else warn "${msg:-Off-site copy failed} - the local backups are fine"; fi
  fi
}
docker_backup_321() {  # copy the newest archive out of the volume when a second copy / off-site is configured
  [[ -n "$(cfg BACKUP_COPY_DIR)$(cfg BACKUP_OFFSITE_COMMAND)$(cfg BACKUP_OFFSITE_TARGET)" ]] || return 0
  local name tmp
  name="$(dc run --rm --entrypoint sh theisle -c 'ls -t /data/backups/theisle-*.tar.gz 2>/dev/null | head -n1' 2>/dev/null | tr -d '\r')"
  [[ -n "$name" ]] || { warn "No backup found in the volume for the second copy / off-site step"; return 0; }
  tmp="$(mktemp -d)"
  if docker cp "$(dc ps -aq theisle | head -n1):$name" "$tmp/" >/dev/null 2>&1; then backup_321 "$tmp/$(basename "$name")"
  else warn "Could not copy $name out of the volume"; fi
  rm -rf -- "$tmp"
}
newest_backup() {  # newest archive in BACKUP_DIR (native) - prints "path epoch"
  find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'theisle-*.tar.gz' -o -name 'theisle-*.zip' \) -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1
}
backup_tool() {  # backup schedule|status|tick ...; returns 1 for a plain backup
  case "${1:-}" in
    # these exit with their own status: returning non-zero here would mean "not a subcommand - back up now"
    schedule) shift; backup_schedule "$@"; exit $? ;;
    status)   shift; backup_status "$@"; exit $? ;;
    strategy) shift; backup_strategy "$@"; exit $? ;;
    tick)     backup_tick; exit $? ;;
    ""|now)   return 1 ;;
    *) die "Usage: $0 backup [now|schedule [show|set \"<cron>\"|off]|status [--json]|strategy ...|tick]" ;;
  esac
}
STRATEGY_USAGE="Usage: isle-server backup strategy [show [--json]]
       backup strategy copy <absolute dir>|off [--keep N]          second copy, ideally another disk (the '2 media')
       backup strategy offsite <target>|off [--keep N]             off-site copy (the '1 off-site'):
            dir:/mnt/nas/theisle | rclone:<remote>:<path> | ssh://user@host[:port]/path
       backup strategy keep <N>                                     local backups to keep (BACKUP_RETENTION, 0 = all)
       backup strategy test                                         check both targets (writes and removes a probe)"
backup_strategy() {  # configure the 3-2-1 strategy (PRD BAK-10..12)
  command -v python3 >/dev/null 2>&1 || die "python3 is required for backup strategies"
  local off="$REPO_DIR/tools/isle_offsite.py" sub="${1:-show}" val keep=""
  shift || true
  case "$sub" in
    show)
      if [[ "${1:-}" == --json ]]; then python3 "$off" --conf "$ISLE_CONF" strategy --json; return; fi
      printf 'Local     : %s (keep %s)\n' "$BACKUP_DIR" "$(cfg BACKUP_RETENTION 10)"
      printf 'Copy 2    : %s\n' "$( [[ -n "$(cfg BACKUP_COPY_DIR)" ]] && printf '%s (keep %s)' "$(cfg BACKUP_COPY_DIR)" "$(cfg BACKUP_COPY_RETENTION "$(cfg BACKUP_RETENTION 10)")" || echo 'off  - backup strategy copy /mnt/other-disk/theisle')"
      printf 'Off-site  : %s\n' "$( [[ -n "$(cfg BACKUP_OFFSITE_TARGET)" ]] && printf '%s (keep %s)' "$(cfg BACKUP_OFFSITE_TARGET)" "$(cfg BACKUP_OFFSITE_RETENTION "$(cfg BACKUP_RETENTION 10)")" || echo 'off  - backup strategy offsite rclone:b2:bucket/theisle')"
      [[ -n "$(cfg BACKUP_OFFSITE_COMMAND)" ]] && printf 'Command   : BACKUP_OFFSITE_COMMAND is also set (runs after every backup)\n'
      printf 'Schedule  : %s\n' "$(cfg BACKUP_SCHEDULE)"
      printf '\nCheck it with: %s backup strategy test   (status: %s backup status)\n' "$0" "$0" ;;
    copy|offsite)
      val="${1:-}"; shift || true
      [[ -n "$val" ]] || die "$STRATEGY_USAGE"
      if [[ "${1:-}" == --keep ]]; then keep="${2:-}"; [[ "$keep" =~ ^[0-9]+$ ]] || die "--keep needs a whole number (0 = keep all)"; fi
      if [[ "$sub" == copy ]]; then
        if [[ "$val" == off ]]; then set_conf BACKUP_COPY_DIR ""; ok "Second copy turned off"; return; fi
        [[ "$val" == /* ]] || die "The copy folder must be an absolute path, e.g. /mnt/backup2/theisle"
        [[ "$(readlink -m "$val")" != "$(readlink -m "$BACKUP_DIR")" ]] || die "The copy folder must not be BACKUP_DIR itself"
        set_conf BACKUP_COPY_DIR "$val"; [[ -n "$keep" ]] && set_conf BACKUP_COPY_RETENTION "$keep"
        ok "Second copy: $val${keep:+ (keep $keep)}"
      else
        if [[ "$val" == off ]]; then set_conf BACKUP_OFFSITE_TARGET ""; ok "Off-site target turned off"; return; fi
        python3 "$off" parse "$val" >/dev/null || die "Not a valid off-site target (see: $0 backup strategy help)"
        set_conf BACKUP_OFFSITE_TARGET "$val"; [[ -n "$keep" ]] && set_conf BACKUP_OFFSITE_RETENTION "$keep"
        ok "Off-site: $val${keep:+ (keep $keep)}"
      fi
      log "Check it with: $0 backup strategy test" ;;
    keep)
      [[ "${1:-}" =~ ^[0-9]+$ ]] || die "Usage: $0 backup strategy keep <N>   (0 = keep all)"
      set_conf BACKUP_RETENTION "$1"; ok "Keeping $1 local backup(s)" ;;
    test) python3 "$off" --conf "$ISLE_CONF" test ;;
    help|-h|--help) printf '%s\n' "$STRATEGY_USAGE" ;;
    *) die "$STRATEGY_USAGE" ;;
  esac
}
backup_schedule() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required for schedules"
  local cron="$REPO_DIR/tools/isle_cron.py"
  case "${1:-show}" in
    show)
      printf 'Schedule : %s  (%s)\n' "$(cfg BACKUP_SCHEDULE)" "$(python3 "$cron" describe "$(cfg BACKUP_SCHEDULE)" 2>&1)"
      printf 'Next     :\n'; python3 "$cron" --conf "$ISLE_CONF" next "$(cfg BACKUP_SCHEDULE)" -n 5 | sed 's/^/  /' ;;
    set)
      [[ -n "${2:-}" ]] || die "Usage: $0 backup schedule set \"<minute hour day month weekday>\"   e.g. \"0 5 * * *\", \"0 */6 * * *\", @daily"
      python3 "$cron" check "$2" >/dev/null || die "Not a valid schedule: $2"
      set_conf BACKUP_SCHEDULE "$2"
      ok "Backups scheduled: $(python3 "$cron" describe "$2") - next: $(python3 "$cron" --conf "$ISLE_CONF" next "$2" -n 1)" ;;
    off)
      set_conf BACKUP_SCHEDULE off
      ok "Scheduled backups are off (manual: $0 backup)" ;;
    *) die "Usage: $0 backup schedule [show|set \"<cron>\"|off]" ;;
  esac
}
backup_tick() {  # one minute of the scheduler: back up when BACKUP_SCHEDULE fell due since the last run
  command -v python3 >/dev/null 2>&1 || die "python3 is required for scheduled backups"
  local f due last; f="$(state_file backup-tick)"
  last="$(cat "$f" 2>/dev/null || true)"
  due="$(python3 "$REPO_DIR/tools/isle_cron.py" --conf "$ISLE_CONF" due "$(cfg BACKUP_SCHEDULE)" ${last:+--since "$last"})" || return 0
  printf '%s\n' "$due" > "$f"
  log "Scheduled backup ($due, $(cfg BACKUP_SCHEDULE))"
  "$SCRIPT_DIR/isle-server.sh" backup
}
backup_status() {  # [--json] - schedule, last backup and the 3-2-1 check
  local newest path age copy n_local=0 n_copy=0 other=false off_cfg="" off_last="" copies media offsite
  newest="$(newest_backup)"; path="${newest#* }"
  [[ -d "$BACKUP_DIR" ]] && n_local="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'theisle-*' | wc -l)"
  copy="$(cfg BACKUP_COPY_DIR)"
  if [[ -n "$copy" && -d "$copy" ]]; then
    n_copy="$(find "$copy" -maxdepth 1 -type f -name 'theisle-*' | wc -l)"
    [[ "$(stat -c %d "$copy")" != "$(stat -c %d "$BACKUP_DIR" 2>/dev/null)" ]] && other=true
  fi
  if [[ -n "$(cfg BACKUP_OFFSITE_TARGET)" ]]; then off_cfg="$(cfg BACKUP_OFFSITE_TARGET)"; fi
  if [[ -n "$(cfg BACKUP_OFFSITE_COMMAND)" ]]; then off_cfg="${off_cfg:+$off_cfg+}command"; fi
  if grep -qx offsite-backup "$(dirname "$ISLE_CONF")/plugins/enabled.txt" 2>/dev/null; then off_cfg="${off_cfg:+$off_cfg+}offsite-backup plugin"; fi
  off_last="$(cat "$(state_file backup-offsite)" 2>/dev/null || true)"
  copies=1; (( n_local > 0 )) && copies=$((copies + 1)); (( n_copy > 0 )) && copies=$((copies + 1)); [[ -n "$off_cfg" ]] && copies=$((copies + 1))
  media=1; { [[ "$other" == true ]] || [[ -n "$off_cfg" ]]; } && media=2
  offsite=false; [[ -n "$off_cfg" ]] && offsite=true
  age=""; [[ -n "$newest" ]] && age=$(( $(date +%s) - ${newest%%.*} ))
  if [[ "${1:-}" == --json ]]; then
    python3 - "$(cfg BACKUP_SCHEDULE)" "$path" "${age:-}" "$BACKUP_DIR" "$n_local" "$copy" "$n_copy" "$other" "$off_cfg" "$off_last" \
      "$copies" "$media" "$offsite" "$ISLE_CONF" "$REPO_DIR" <<'PY'
import json, subprocess, sys
a = sys.argv[1:]
cron = [sys.executable, a[14] + "/tools/isle_cron.py", "--conf", a[13]]
nxt = json.loads(subprocess.run(cron + ["next", a[0], "-n", "5", "--json"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout or b"{}")
print(json.dumps({"schedule": a[0], "describe": nxt.get("describe", ""), "zone": nxt.get("zone", ""), "next": nxt.get("next", []),
                  "last": {"file": a[1].rsplit("/", 1)[-1] if a[1] else None, "age_seconds": int(a[2]) if a[2] else None},
                  "local": {"dir": a[3], "count": int(a[4])}, "copy": {"dir": a[5], "count": int(a[6]), "other_disk": a[7] == "true"},
                  "offsite": {"configured": a[8], "last": a[9]},
                  "rule321": {"copies": int(a[10]), "media": int(a[11]), "offsite": a[12] == "true",
                              "ok": int(a[10]) >= 3 and int(a[11]) >= 2 and a[12] == "true"}}))
PY
    return 0
  fi
  backup_schedule show
  printf 'Last     : %s\n' "${path:+$(basename "$path") ($(( ${age:-0} / 3600 ))h $(( ${age:-0} % 3600 / 60 ))m ago)}"
  printf 'Local    : %s backups in %s\n' "$n_local" "$BACKUP_DIR"
  printf 'Copy 2   : %s\n' "${copy:+$n_copy in $copy ($([[ $other == true ]] && echo 'another disk' || echo 'SAME disk'))}"
  printf 'Off-site : %s%s\n' "${off_cfg:-not configured (backup strategy offsite <target>)}" "${off_last:+ - last: $off_last}"
  printf '3-2-1    : %s copies %s, %s media %s, off-site %s\n' "$copies" "$([[ $copies -ge 3 ]] && echo OK || echo '(need 3)')" \
    "$media" "$([[ $media -ge 2 ]] && echo OK || echo '(need 2)')" "$([[ $offsite == true ]] && echo OK || echo '(need 1)')"
}

# Windows native backups are .zip; repack them as .tar.gz (python3, stdlib only).
ensure_targz() {  # FILE -> prints a .tar.gz path (the file itself, or a repacked temp copy)
  local file="$1" out
  case "${file,,}" in
    *.zip)
      command -v python3 >/dev/null 2>&1 || die "python3 is required to restore a .zip backup"
      out="$(mktemp -d)/$(basename "${file%.*}").tar.gz"
      python3 - "$file" "$out" <<'PY' || die "Could not repack $file"
import sys, tarfile, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z, tarfile.open(dst, "w:gz") as t:
    for info in z.infolist():
        name = info.filename.replace("\\", "/")
        if name.startswith("/") or ".." in name.split("/"):
            raise SystemExit("unsafe path in zip: " + name)
        ti = tarfile.TarInfo(name.rstrip("/"))
        if info.is_dir():
            ti.type, ti.mode = tarfile.DIRTYPE, 0o755
            t.addfile(ti)
        else:
            data = z.read(info)
            ti.size, ti.mode = len(data), 0o644
            import io
            t.addfile(ti, io.BytesIO(data))
PY
      log "Repacked $file as $out" >&2
      printf '%s' "$out" ;;
    *) printf '%s' "$file" ;;
  esac
}
backup_has_saved() { tar -tzf "$1" 2>/dev/null | grep -qE '^(\./)?Saved/'; }

cmd_restore() {
  local file="${1:-}"
  [[ -f "$file" ]] || die "Usage: isle-server.sh restore <backup.tar.gz|backup.zip>"
  is_running && die "Stop the server before restoring"
  file="$(ensure_targz "$file")"
  backup_has_saved "$file" || die "$file does not contain a Saved/ folder - not a server backup? Nothing was changed."
  local saved="$SERVER_DIR/TheIsle/Saved"
  if [[ -d "$saved" ]]; then mv "$saved" "$saved.pre-restore_$(stamp)"; fi
  mkdir -p "$SERVER_DIR/TheIsle"
  tar -xzf "$file" -C "$SERVER_DIR/TheIsle" Saved
  ok "Restored $file (previous data kept as Saved.pre-restore_*)"
}

cmd_rcon() {
  [[ $# -gt 0 ]] || die "Usage: isle-server.sh rcon <command> [args]"
  command -v python3 >/dev/null 2>&1 || die "python3 is required for RCON"
  ISLE_RCON_PASSWORD="$(cfg RCON_PASSWORD)" exec python3 "$REPO_DIR/tools/isle_rcon.py" -p "$(cfg RCON_PORT)" "$@"
}

cmd_info() {
  cat <<EOF
Scripts       : v$SCRIPT_VERSION ($PROJECT_URL)
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
# SteamID64 -> Steam name (tools/isle_steam.py: cached, STEAM_NAME_LOOKUP / STEAM_WEB_API_KEY); never fails a command
steam_names() {  # [--refresh] ID... -> "ID<TAB>name" lines (name may be empty)
  local extra=()
  [[ "${1:-}" == --refresh ]] && { extra=(--refresh); shift; }
  [[ $# -gt 0 ]] || return 0
  if command -v python3 >/dev/null 2>&1; then
    timeout 60 python3 "$REPO_DIR/tools/isle_steam.py" --conf "$ISLE_CONF" names "${extra[@]}" "$@" 2>/dev/null && return 0
  fi
  printf '%s\t\n' "$@"
}
ids_show() {  # LIST EMPTY_TEXT [--refresh] - one "SteamID64  name" line per id
  [[ -n "$1" ]] || { echo "${2:-(empty)}"; return 0; }
  local ids; mapfile -t ids < <(tr ',' '\n' <<< "$1" | sed '/^$/d')
  steam_names ${3:+"$3"} "${ids[@]}" | awk -F'\t' '{ printf "%s  %s\n", $1, ($2 == "" ? "(name unknown)" : $2) }'
}
cmd_steam() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    names)
      local refresh=""; [[ "${1:-}" == --refresh ]] && { refresh=--refresh; shift; }
      [[ $# -gt 0 ]] || die "Usage: isle-server steam names [--refresh] <SteamID64...>"
      check_ids "$@"
      ids_show "$(IFS=,; printf '%s' "$*")" "" "$refresh" ;;
    *) die "Usage: isle-server steam names [--refresh] <SteamID64...>   (Steam names; see STEAM_NAME_LOOKUP)" ;;
  esac
}
list_count() { if [[ -z "$1" ]]; then echo 0; else tr ',' '\n' <<< "$1" | sed '/^$/d' | wc -l | tr -d ' '; fi; }

# ------------------------------------------------------------------ maps ---
map_names() { [[ -f "$REPO_DIR/config/maps.txt" ]] && awk '$1 !~ /^#/ && NF { print $1 }' "$REPO_DIR/config/maps.txt"; return 0; }
map_line() {  # NAME -> "name branch status description" (exit 1 if unknown)
  [[ -f "$REPO_DIR/config/maps.txt" ]] || return 1
  awk -v want="$1" '$1 !~ /^#/ && $1 == want { print; found = 1 } END { exit !found }' "$REPO_DIR/config/maps.txt"
}
cmd_maps() {  # list | show [name] | set <name> [--keep-branch]
  local sub="${1:-list}" name line branch status desc cur
  shift || true
  cur="$(cfg MAP_NAME)"
  case "$sub" in
    list)
      [[ -f "$REPO_DIR/config/maps.txt" ]] || die "config/maps.txt is missing"
      awk -v cur="$cur" '$1 !~ /^#/ && NF { d = ""; for (i = 4; i <= NF; i++) d = d (i > 4 ? " " : "") $i;
        printf "%s %-12s %-18s %-9s %s\n", ($1 == cur ? "*" : " "), $1, $2, $3, d }' "$REPO_DIR/config/maps.txt"
      printf '\n  * = current (MAP_NAME=%s, STEAM_BRANCH=%s)\n' "$cur" "$(cfg STEAM_BRANCH)" ;;
    show)
      name="${1:-$cur}"
      line="$(map_line "$name")" || die "Unknown map '$name' (known: $(map_names | paste -sd' ' -))"
      read -r name branch status desc <<< "$line"
      printf 'Map          : %s%s\nSteam branch : %s\nStatus       : %s\nAbout        : %s\n' "$name" \
        "$([[ "$name" == "$cur" ]] && echo ' (current)')" "$branch" "$status" "$desc" ;;
    set)
      name="${1:-}"; [[ -n "$name" ]] || die "Usage: $0 maps set <name> [--keep-branch]"
      line="$(map_line "$name")" || die "Unknown map '$name' (known: $(map_names | paste -sd' ' -)). Names are case-sensitive; add new maps to config/maps.txt"
      read -r name branch status desc <<< "$line"
      set_conf MAP_NAME "$name"
      if [[ "${2:-}" != --keep-branch && "$branch" != "-" && "$branch" != "$(cfg STEAM_BRANCH)" ]]; then
        set_conf STEAM_BRANCH "$branch"
        ok "Map set to $name and Steam branch to $branch"
        warn "Different branch: stop the server, then run '$0 validate' to download that build before starting"
      else
        ok "Map set to $name"
      fi
      [[ "$status" == archived ]] && warn "$name is an archived build: it receives no updates or new species"
      log "Restart the server to load the new map" ;;
    *) die "Usage: $0 maps list|show [name]|set <name> [--keep-branch]" ;;
  esac
}

# -------------------------------------------------------------------- AI ---
cmd_ai() {  # status | on | off | density <n> | interval <s> | preset <name>
  local sub="${1:-status}" v
  shift || true
  case "$sub" in
    status)
      printf 'Spawn AI       : %s\nDensity        : %s\nSpawn interval : %s s\nDisabled       : %s\n' \
        "$(cfg SPAWN_AI true)" "$(cfg AI_DENSITY 1)" "$(cfg AI_SPAWN_INTERVAL 40)" "$(cfg DISABLED_AI_CLASSES)"
      [[ -n "$(cfg DISABLED_AI_CLASSES)" ]] || printf '                 (none - every AI class spawns)\n' ;;
    on|off)
      set_conf SPAWN_AI "$([[ "$sub" == on ]] && echo true || echo false)"
      ok "AI spawning $sub - applied on the next restart (RCON 'toggleai' only flips the current state)" ;;
    density)
      v="${1:-}"
      [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "Usage: $0 ai density <number>, e.g. 0.5 (half), 1 (default), 2 (double)"
      awk -v x="$v" 'BEGIN { exit !(x > 5) }' && warn "AI density $v is very high - expect server load"
      set_conf AI_DENSITY "$v"
      ok "AI density $v"
      live_rcon aidensity "$v" ;;
    interval)
      v="${1:-}"
      if ! [[ "$v" =~ ^[0-9]+$ ]] || (( 10#$v < 1 )); then die "Usage: $0 ai interval <seconds>, e.g. 40 (default)"; fi
      set_conf AI_SPAWN_INTERVAL "$v"
      ok "AI spawn interval ${v}s - applied on the next restart" ;;
    preset)
      [[ -n "${1:-}" ]] || die "Usage: $0 ai preset <name>  (AI presets: $(find "$REPO_DIR/config/presets" -name 'ai-*.conf' -printf '%f\n' | sed 's/\.conf$//' | sort | paste -sd' ' -))"
      [[ "$1" == ai-* ]] || die "AI presets start with ai- (see: $0 preset list)"
      cmd_overlay preset apply "$1" ;;
    *) die "Usage: $0 ai status|on|off|density <n>|interval <s>|preset <name>" ;;
  esac
}

# ------------------------------------------------------------- mutations ---
mutation_line() {  # NAME (case-insensitive) -> "Name<TAB>default<TAB>flag"
  [[ -f "$REPO_DIR/config/mutations.txt" ]] || return 1
  awk -F'\t' -v want="$(tr '[:upper:]' '[:lower:]' <<< "$1")" '$1 !~ /^#/ && NF >= 2 && tolower($1) == want { print; found = 1; exit } END { exit !found }' "$REPO_DIR/config/mutations.txt"
}
mutation_catalog() { awk -F'\t' '$1 !~ /^#/ && NF >= 2 { print $1 ":" $2 }' "$REPO_DIR/config/mutations.txt"; }
cmd_mutations() {  # list | enable <Name> [value] | disable <Name...> | reset
  local sub="${1:-list}" cur line name def val entry
  shift || true
  [[ -f "$REPO_DIR/config/mutations.txt" ]] || die "config/mutations.txt is missing"
  cur="$(cfg ENABLED_MUTATIONS)"
  case "$sub" in
    list)
      [[ -z "$cur" ]] && printf 'All mutations are available (ENABLED_MUTATIONS is empty - the game default).\n\n'
      while IFS=$'\t' read -r name def flag; do
        [[ "$name" == \#* || -z "$name" ]] && continue
        if [[ -z "$cur" ]]; then val="$def"; state=on
        elif entry="$(tr ';' '\n' <<< "$cur" | grep -i "^$name:")"; then val="${entry##*:}"; state=on
        else val="-"; state=off; fi
        printf '  %-3s %-34s %-6s %s\n' "$state" "$name" "$val" "${flag:+(value must be 1)}"
      done < "$REPO_DIR/config/mutations.txt" ;;
    enable|disable)
      [[ $# -gt 0 ]] || die "Usage: $0 mutations $sub <Name> ...   (see: $0 mutations list)"
      # first change: start from every mutation at its default, then edit
      [[ -n "$cur" ]] || cur="$(mutation_catalog | paste -sd';' -)"
      if [[ "$sub" == enable ]]; then
        line="$(mutation_line "$1")" || die "Unknown mutation '$1' (see: $0 mutations list)"
        name="$(cut -f1 <<< "$line")"; def="$(cut -f2 <<< "$line")"; val="${2:-$def}"
        [[ "$val" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "The value must be a number, e.g. $def"
        [[ "$(cut -f3 <<< "$line")" == fixed && "$val" != 1 ]] && die "$name only takes 1 (leave it out to disable it)"
        [[ "$val" != "$def" ]] && warn "$name: $val differs from the default $def - changed values may produce unstable gameplay"
        cur="$(tr ';' '\n' <<< "$cur" | grep -vi "^$name:" | grep . ; printf '%s:%s' "$name" "$val")"
        cur="$(tr '\n' ';' <<< "$cur" | sed 's/;*$//')"
        set_conf ENABLED_MUTATIONS "$cur"; ok "Mutation $name enabled ($val)"
      else
        for entry in "$@"; do
          line="$(mutation_line "$entry")" || die "Unknown mutation '$entry' (see: $0 mutations list)"
          name="$(cut -f1 <<< "$line")"
          cur="$(tr ';' '\n' <<< "$cur" | grep -vi "^$name:" | paste -sd';' -)"
          ok "Mutation $name disabled"
        done
        [[ -n "$cur" ]] || die "Disabling every mutation: set ENABLE_MUTATIONS=false instead"
        set_conf ENABLED_MUTATIONS "$cur"
      fi
      log "$(tr ';' '\n' <<< "$cur" | grep -c .) of $(mutation_catalog | wc -l) mutations available - restart the server to apply" ;;
    reset) set_conf ENABLED_MUTATIONS ""; ok "Every mutation is available again (game default) - restart to apply" ;;
    *) die "Usage: $0 mutations list|enable <Name> [value]|disable <Name...>|reset" ;;
  esac
}

# ----------------------------------------------------------- class types ---
classes_of_type() {  # SECTION TYPE... -> class names whose diet or traits match any TYPE
  awk -v want="[$1]" -v types=" ${*:2} " 'BEGIN { types = tolower(types) }
    /^\[/ { on = ($0 == want); next }
    on && $1 !~ /^#/ && NF { for (i = 2; i <= NF; i++) if (index(types, " " tolower($i) " ")) { print $1; break } }' "$REPO_DIR/config/classes.txt"
}
class_types() {  # SECTION -> "type: names" lines
  awk -v want="[$1]" '/^\[/ { on = ($0 == want); next }
    on && $1 !~ /^#/ && NF > 1 { for (i = 2; i <= NF; i++) t[$i] = t[$i] (t[$i] ? ", " : "") $1 }
    END { for (k in t) printf "  %-10s %s\n", k, t[k] }' "$REPO_DIR/config/classes.txt" | sort
}

# ----------------------------------------------------------------- admin ---
rcon_now() {  # COMMAND [ARGS] - live RCON; the server must be running
  command -v python3 >/dev/null 2>&1 || die "python3 is required for RCON"
  if ! is_true "$(cfg RCON_ENABLED)" || [[ -z "$(cfg RCON_PASSWORD)" ]]; then die "RCON is disabled or has no password (RCON_ENABLED, RCON_PASSWORD)"; fi
  if [[ "${RUNTIME:-native}" == docker ]]; then
    docker_running 2>/dev/null || die "The server is not running"
    dc exec -T theisle isle-server rcon "$@"
  else
    ISLE_RCON_PASSWORD="$(cfg RCON_PASSWORD)" python3 "$REPO_DIR/tools/isle_rcon.py" -p "$(cfg RCON_PORT)" "$@"
  fi
}
onoff() { case "${1:-}" in on|1|true|yes) echo 1 ;; off|0|false|no) echo 0 ;; *) return 1 ;; esac; }
cmd_admin() {
  local sub="${1:-}" id v
  shift || true
  case "$sub" in
    players)   rcon_now playerlist ;;
    player)    rcon_now playerdata "$@" ;;
    details)   rcon_now serverdetails ;;
    queue)     rcon_now queuestatus ;;
    playables) rcon_now getplayables ;;
    save)      rcon_now save ;;
    wipecorpses) rcon_now wipecorpses; ok "Corpses wiped" ;;
    announce)  [[ $# -gt 0 ]] || die "Usage: $0 admin announce <text>"; rcon_now announce "$*" ;;
    dm|kick|ban)
      id="${1:-}"; shift || true
      [[ "$id" =~ ^7656119[0-9]{10}$ ]] || die "Usage: $0 admin $sub <SteamID64> $([[ $sub == dm ]] && echo '<text>' || echo '[reason]')"
      if [[ "$sub" == dm ]]; then [[ $# -gt 0 ]] || die "Usage: $0 admin dm <SteamID64> <text>"; rcon_now directmessage "$id,$*"
      else rcon_now "$sub" "$id,${*:-Removed by an admin}"; ok "$sub: $id"; fi ;;
    pause|migrations|humans|chat|ai-learning|netupdate)
      v="$(onoff "${1:-}")" || die "Usage: $0 admin $sub on|off"
      case "$sub" in
        pause)       rcon_now pause "$v" ;;
        migrations)  rcon_now togglemigrations "$v"; set_conf ENABLE_MIGRATION "$([[ $v == 1 ]] && echo true || echo false)" ;;
        humans)      rcon_now togglehumans "$v"; set_conf ENABLE_HUMANS "$([[ $v == 1 ]] && echo true || echo false)" ;;
        chat)        rcon_now toggleglobalchat "$v"; set_conf GLOBAL_CHAT "$([[ $v == 1 ]] && echo true || echo false)" ;;
        ai-learning) rcon_now toggleailearning "$v" ;;
        netupdate)   rcon_now togglenetupdate "$v" ;;
      esac
      ok "$sub $1" ;;
    growth)
      case "${1:-}" in
        on|off) rcon_now togglegrowthmultiplier "$(onoff "$1")"; ok "Growth multiplier $1" ;;
        *)
          [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "Usage: $0 admin growth on|off|<multiplier e.g. 1.5>"
          rcon_now setgrowthmultiplier "$1"; set_conf GROWTH_MULTIPLIER "$1"; ok "Growth multiplier $1 (live and in server.conf)" ;;
      esac ;;
    custom)
      [[ $# -gt 0 ]] || die "Usage: $0 admin custom \"<command>\"   (experimental: the game may ignore it)"
      warn "custom RCON commands are experimental - the game may ignore them"
      rcon_now custom "$*" ;;
    *) die "Usage: $0 admin players|player [id]|dm|kick|ban|announce|save|wipecorpses|details|queue|playables|pause|migrations|humans|chat|ai-learning|netupdate on|off|growth on|off|<n>|custom <cmd>
Note: Evrima's RCON has no commands to change a player's size, skin or mutations, give god mode, teleport or heal -
in-game admins (ADMIN_STEAM_IDS) use the game's own admin panel for those." ;;
  esac
}

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
    list) ids_show "$(cfg ADMIN_STEAM_IDS)" "(no admins)" "${1:-}" ;;
    add|remove)
      [[ $# -gt 0 ]] || die "Usage: isle-server admins $sub <SteamID64> [...]"
      check_ids "$@"
      local v; v="$(edit_list ADMIN_STEAM_IDS "$sub" "$@")"
      ok "Admins: $(list_count "$v") - restart the server to apply (the game reads admins at start)"
      if [[ "$sub" == add ]]; then ids_show "$(IFS=,; printf '%s' "$*")" | sed 's/^/  /'; fi ;;
    *) die "Usage: isle-server admins list [--refresh]|add|remove <SteamID64> [...]" ;;
  esac
}

cmd_whitelist() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list)
      printf 'Whitelist is %s\n' "$(is_true "$(cfg WHITELIST_ENABLED false)" && echo ON || echo OFF)"
      ids_show "$(cfg WHITELIST_IDS)" "(no whitelisted players)" "${1:-}" ;;
    add|remove)
      [[ $# -gt 0 ]] || die "Usage: isle-server whitelist $sub <SteamID64> [...]"
      check_ids "$@"
      local v; v="$(edit_list WHITELIST_IDS "$sub" "$@")"
      ok "Whitelist: $(list_count "$v") player(s)"
      if [[ "$sub" == add ]]; then ids_show "$(IFS=,; printf '%s' "$*")" | sed 's/^/  /'; fi
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
    *) die "Usage: isle-server whitelist list [--refresh]|add|remove <SteamID64> [...]|on|off" ;;
  esac
}

cmd_classes() {  # KEY SECTION RCON_CMD LABEL sub args...
  local key="$1" section="$2" rcmd="$3" label="$4"; shift 4
  local sub="${1:-list}"; shift || true
  local v
  case "$sub" in
    list)  list_show "$(cfg "$key")" "$([[ "$section" == playable ]] && echo '(all classes allowed)' || echo '(none disabled)')"; return ;;
    known) known_classes "$section"; return ;;
    types)
      printf 'Types (%s):\n' "$section"; class_types "$section"
      [[ "$section" == playable ]] && printf '\n  Humans are not a class: %s humans on|off (ENABLE_HUMANS, live via RCON).\n  Eggs/hatchlings are not a class either and have no server setting.\n' "$0 classes"
      return ;;
    select|add-type|remove-type)
      [[ $# -gt 0 ]] || die "Usage: isle-server $label $sub <type> [...]   (see: isle-server $label types)"
      mapfile -t items < <(classes_of_type "$section" "$@")
      (( ${#items[@]} )) || die "No $section class has type: $* (see: isle-server $label types)"
      case "$sub" in
        select)      v="$(edit_list "$key" set "${items[@]}")" ;;
        add-type)    v="$(edit_list "$key" add "${items[@]}")" ;;
        remove-type)
          local base
          if [[ -z "$(cfg "$key")" && "$section" == playable ]]; then base="$(known_classes "$section")"   # "all allowed": start from every class
          else base="$(tr ',' '
' <<< "$(cfg "$key")")"; fi
          mapfile -t keep < <(grep -vxF -f <(printf '%s
' "${items[@]}") <<< "$base" | grep .)
          (( ${#keep[@]} )) || die "That would leave no playable class"
          v="$(edit_list "$key" set "${keep[@]}")" ;;
      esac ;;
    humans)
      [[ "$section" == playable ]] || die "Usage: isle-server classes humans [on|off]"
      case "${1:-}" in
        "") printf 'Humans: %s\n' "$(cfg ENABLE_HUMANS false)"; return ;;
        on|off)
          set_conf ENABLE_HUMANS "$([[ $1 == on ]] && echo true || echo false)"; ok "Humans $1"
          live_rcon togglehumans "$(onoff "$1")"; return ;;
        *) die "Usage: isle-server classes humans [on|off]" ;;
      esac ;;
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
    *) die "Usage: isle-server $label list|known|types|set|add|remove <Class> [...]|select|add-type|remove-type <type> [...]|reset$([[ "$section" == playable ]] && echo '|preset [name]|humans [on|off]')" ;;
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
  backup="$ISLE_CONF.bak_$(stamp)"
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
cmd_snapshot() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required for snapshots"
  local -a owner=()
  # root working on a service user's native install: keep restored files owned by that user
  if [[ $EUID -eq 0 && "${RUNTIME:-native}" == native ]]; then
    local u; u="$(stat -c %U "$ISLE_CONF" 2>/dev/null || true)"
    [[ -n "$u" && "$u" != root ]] && owner=(--owner "$u")
  fi
  python3 "$REPO_DIR/tools/isle_snapshot.py" --conf "$ISLE_CONF" --runtime "${RUNTIME:-native}" \
    --launcher "$SCRIPT_DIR/isle-server.sh" --server-dir "$SERVER_DIR" --backup-dir "$BACKUP_DIR" \
    --overrides-dir "$(overrides_dir)" "${owner[@]}" "$@"
}

api_tool() {  # args... - tools/isle_api.py bound to this config and runtime
  command -v python3 >/dev/null 2>&1 || die "python3 is required for the web UI"
  python3 "$REPO_DIR/tools/isle_api.py" --conf "$ISLE_CONF" --launcher "$SCRIPT_DIR/isle-server.sh" \
    --runtime "${RUNTIME:-native}" "$@"
}

cmd_ui() {  # web UI + REST API in the foreground (Ctrl+C stops it)
  local a
  for a in "$@"; do
    case "$a" in -h|--help) python3 "$REPO_DIR/tools/isle_api.py" --help; return ;; esac
  done
  if [[ $EUID -eq 0 && "${RUNTIME:-native}" == native && -z "${ISLE_ALLOW_ROOT:-}" ]]; then
    die "Run the web UI as the service user (e.g. 'sudo -u theisle $0 ui') or set ISLE_ALLOW_ROOT=1."
  fi
  api_tool "$@"
}

cmd_ui_token() {
  case "${1:-}" in
    "")       api_tool --print-token ;;
    --rotate) api_tool --rotate-token; warn "Restart the web UI (theisle-ui service) to use the new token" ;;
    *)        die "Usage: $0 ui-token [--rotate]" ;;
  esac
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
    ai)         cmd_ai "$@" ;;
    maps)       cmd_maps "$@" ;;
    mutations)  cmd_mutations "$@" ;;
    admin)      cmd_admin "$@" ;;
    steam)      cmd_steam "$@" ;;
    recommend)  cmd_recommend "$@" ;;
    setup)      cmd_setup "$@" ;;
    profile)    cmd_overlay profile "$@" ;;
    preset)     cmd_overlay preset "$@" ;;
    plugins)    cmd_plugins "$@" ;;
    snapshot)   cmd_snapshot "$@" ;;
    ui)         cmd_ui "$@" ;;
    ui-token)   cmd_ui_token "$@" ;;
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

# Docker Compose would interpolate $VARS, collapse $$ and cut " #..." off
# values if it read server.conf directly. Write a compose-safe copy that holds
# exactly what the native parser sees: every value double-quoted with \ \" $$
# escaped, so Compose passes it through literally.
compose_env_file() {
  local f k v; f="$(dirname "$ISLE_CONF")/.compose.env"
  ( umask 077
    { printf '# Generated from %s by isle-server.sh - do not edit (it is rewritten on every docker command)\n' "$ISLE_CONF"
      for k in $(printf '%s\n' "${!CFG[@]}" | sort); do
        v="${CFG[$k]}"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//\$/\$\$}"
        printf '%s="%s"\n' "$k" "$v"
      done
      # TIMEZONE=local: give the container this host's UTC offset as a POSIX TZ (no tzdata needed)
      if [[ "${CFG[TIMEZONE],,}" != utc ]]; then
        local z sign; z="$(date +%z)"; sign="-"; [[ "${z:0:1}" == "-" ]] && sign="+"
        printf 'TZ="<%s>%s%s:%s"\n' "$z" "$sign" "${z:1:2}" "${z:3:2}"
      fi; } > "$f" )
  printf '%s' "$f"
}

dc() {  # docker compose bound to this repo and the host server.conf
  local ovr envf; ovr="$(overrides_dir)"; mkdir -p "$ovr" 2>/dev/null || true
  envf="$(compose_env_file)"
  ISLE_CONF_FILE="$envf" ISLE_OVERRIDES_DIR="$ovr" docker compose --project-directory "$REPO_DIR" \
    -f "$REPO_DIR/docker-compose.yml" --env-file "$envf" "$@"
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
      if backup_tool "$@"; then return; fi
      if docker_running; then dc exec -T theisle isle-server backup
      else dc run --rm theisle backup; fi
      docker_backup_321
      run_hooks post-backup ;;
    restore)
      local file="${1:-}" target
      [[ -n "$file" ]] || die "Usage: $0 restore <backup.tar.gz | name in /data/backups>"
      docker_require_stopped restore
      if [[ -f "$file" ]]; then
        dc up --no-start "${nb[@]}"
        # A one-off run lets the entrypoint create the /data layout (fresh volume).
        dc run --rm theisle check >/dev/null
        file="$(ensure_targz "$file")"
        backup_has_saved "$file" || die "$file does not contain a Saved/ folder - not a server backup? Nothing was changed."
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
    "Scripts" "v$SCRIPT_VERSION ($PROJECT_URL)" \
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
    version|--version) version_text; return 0 ;;
  esac
  load_config
  case "$cmd" in
    status|info|logs|check|version|help|ui|ui-token|_watchdog) ;;   # read-only (the watchdog's output is already a launcher log)
    *) LOG_TO_FILE=1; file_log CMD "$cmd ${1:-}" ;;                 # only the first argument: values may be secrets
  esac
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
    version)   version_text ;;
    configure) configure --force ;;
    start)     cmd_start; run_hooks post-start ;;
    stop)      if server_running; then run_hooks pre-stop; fi; cmd_stop; run_hooks post-stop ;;
    restart)   if server_running; then run_hooks pre-stop; fi; cmd_stop; run_hooks post-stop; sleep 2; cmd_start; run_hooks post-start ;;
    status)    cmd_status ;;
    run)       cmd_run ;;
    _watchdog) cmd_watchdog ;;
    logs)      cmd_logs "$@" ;;
    backup)    if backup_tool "$@"; then return; fi; cmd_backup; run_hooks post-backup ;;
    restore)   require_stopped restore; cmd_restore "$@" ;;
    rcon)      cmd_rcon "$@" ;;
    save)      cmd_save ;;
    info)      cmd_info ;;
    *)         usage; die "Unknown command: $cmd" ;;
  esac
}

main "$@"
