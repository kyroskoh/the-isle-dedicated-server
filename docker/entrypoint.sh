#!/usr/bin/env bash
# =============================================================================
#  Container entrypoint for The Isle (Evrima) dedicated server
#
#  1. Creates /data/{config,server,steamcmd,backups,home} and server.conf
#  2. Writes any env var named like a server.conf key into server.conf
#  3. As root: remaps the theisle user to PUID/PGID, fixes /data ownership,
#     then re-executes itself unprivileged (setpriv)
#  4. "run" (default): validates config, runs the server, and on SIGTERM
#     saves via RCON before stopping it. Any other isle-server command is
#     passed through (e.g. `docker run ... check`); other programs are exec'd.
# =============================================================================
set -Eeuo pipefail

SCRIPTS=/opt/theisle-scripts
MANAGER="$SCRIPTS/linux/isle-server.sh"
EXAMPLE="$SCRIPTS/config/server.conf.example"
CONF="${ISLE_CONF:-/data/config/server.conf}"
export ISLE_CONF="$CONF" ISLE_NO_SYSTEMD=1 ISLE_RUNTIME=native

log()  { printf '[entrypoint] %s\n' "$*"; }
fail() { printf '[entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }

conf_set() {  # KEY VALUE -> server.conf (literal, escaped for sed)
  local key="$1" val="$2" esc
  [[ "$val" == *$'\n'* ]] && fail "Environment variable $key must not contain newlines"
  if grep -qE "^$key=" "$CONF"; then
    esc="$(printf '%s' "$val" | sed -e 's/[\\/&|]/\\&/g')"
    sed -i "s|^$key=.*|$key=$esc|" "$CONF"
  else
    printf '%s=%s\n' "$key" "$val" >> "$CONF"
  fi
}

prepare_data() {
  mkdir -p /data/config /data/server /data/steamcmd /data/backups /data/home "$(dirname "$CONF")"
  if [[ ! -f "$CONF" ]]; then
    cp "$EXAMPLE" "$CONF"
    log "Created $CONF"
  fi
  # Env overrides: every KEY present in the example file may be set as an env var.
  local key applied=()
  while IFS= read -r key; do
    case "$key" in
      # Host-side launcher keys; paths are fixed to the /data volume below.
      RUNTIME|DOCKER_BUILD|DOCKER_IMAGE|PUID|PGID|STEAMCMD_DIR|SERVER_DIR|BACKUP_DIR) continue ;;
    esac
    if [[ -v "$key" ]]; then
      conf_set "$key" "${!key}"
      applied+=("$key")
    fi
  done < <(grep -oE '^[A-Z_][A-Z0-9_]*=' "$EXAMPLE" | tr -d '=' | sort -u)
  if (( ${#applied[@]} )) && [[ "${1:-}" != "--quiet" ]]; then
    if (( ${#applied[@]} > 8 )); then log "Applied ${#applied[@]} settings from the environment"
    else log "Applied env overrides: ${applied[*]}"; fi
  fi
  # Inside the container the manager always runs natively on the /data volume.
  conf_set RUNTIME native
  conf_set STEAMCMD_DIR /data/steamcmd
  conf_set SERVER_DIR /data/server
  conf_set BACKUP_DIR /data/backups
  # Generate an RCON password on first start (needed for save-before-stop).
  local rcon_enabled rcon_pw
  rcon_enabled="$(grep -E '^RCON_ENABLED=' "$CONF" | tail -n1 | cut -d= -f2- | tr -d '"' | tr '[:upper:]' '[:lower:]')"
  rcon_pw="$(grep -E '^RCON_PASSWORD=' "$CONF" | tail -n1 | cut -d= -f2- | tr -d '"')"
  case "$rcon_enabled" in false|no|0|off) ;; *)
    if [[ -z "$rcon_pw" ]]; then
      conf_set RCON_PASSWORD "$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)"
      log "Generated a random RCON password (stored in $CONF)"
    fi ;;
  esac
  chmod 600 "$CONF" 2>/dev/null || true
}

# ------------------------------------------------------------- privileges ---
if [[ $EUID -eq 0 ]]; then
  [[ "$PUID" =~ ^[0-9]+$ && "$PGID" =~ ^[0-9]+$ ]] || fail "PUID/PGID must be numeric"
  [[ "$PUID" -ne 0 ]] || fail "PUID=0 is not allowed - the game server must not run as root"
  prepare_data --quiet
  if [[ "$(id -u theisle)" != "$PUID" || "$(id -g theisle)" != "$PGID" ]]; then
    groupmod -o -g "$PGID" theisle
    usermod -o -u "$PUID" -g "$PGID" theisle
    log "Mapped user theisle to $PUID:$PGID"
  fi
  # Only walk the whole tree when ownership is actually wrong (it can be large).
  if [[ "$(stat -c '%u:%g' /data)" != "$PUID:$PGID" || "$(stat -c '%u:%g' "$CONF")" != "$PUID:$PGID" ]] \
     || find /data -xdev \( ! -user "$PUID" -o ! -group "$PGID" \) -print -quit | grep -q .; then
    log "Fixing ownership of /data (this can take a moment)"
    chown -R "$PUID:$PGID" /data
  fi
  exec setpriv --reuid "$PUID" --regid "$PGID" --init-groups "$0" "$@"
fi

# Running unprivileged from here on (either dropped above or `docker run --user`).
[[ -w /data ]] || fail "/data is not writable by uid $(id -u). Fix the volume permissions or set PUID/PGID."
prepare_data
export HOME=/data/home

# PIDs are per container: PID files left by a previous container are always stale.
rm -f /data/server/.isle-scripts/server.pid /data/server/.isle-scripts/watchdog.pid \
      /data/server/.isle-scripts/stop.flag 2>/dev/null || true

cmd="${1:-run}"
case "$cmd" in
  run) ;;
  install|update|validate|check|configure|start|stop|restart|status|logs|backup|restore|rcon|save|info|version|help)
    exec "$MANAGER" "$@" ;;
  *) exec "$@" ;;
esac

# ---------------------------------------------------------------- run -------
"$MANAGER" check || fail "Invalid configuration - fix the env vars or $CONF"

conf_get() { grep -E "^$1=" "$CONF" | tail -n1 | cut -d= -f2- | tr -d '"' || true; }
STOP_TIMEOUT="$(conf_get STOP_TIMEOUT)"; [[ "$STOP_TIMEOUT" =~ ^[0-9]+$ ]] || STOP_TIMEOUT=60

server_pid=""
stopping=0
# shellcheck disable=SC2329  # invoked via trap
on_term() {
  (( stopping )) && return
  stopping=1
  log "Stop requested"
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    case "$(conf_get SAVE_BEFORE_STOP | tr '[:upper:]' '[:lower:]')" in
      false|no|0|off) ;;
      *) "$MANAGER" save || true ;;
    esac
    kill -TERM "$server_pid" 2>/dev/null || true
    local t=0
    while kill -0 "$server_pid" 2>/dev/null && (( t < STOP_TIMEOUT )); do sleep 1; t=$((t + 1)); done
    if kill -0 "$server_pid" 2>/dev/null; then
      log "Server did not exit within ${STOP_TIMEOUT}s - killing"
      kill -KILL "$server_pid" 2>/dev/null || true
    fi
  fi
}
trap on_term TERM INT

"$MANAGER" run &
server_pid=$!
rc=0
# `wait` returns early when a trapped signal arrives; keep waiting for the real exit.
while kill -0 "$server_pid" 2>/dev/null; do
  if wait "$server_pid"; then rc=0; else rc=$?; fi
done
if (( stopping )); then
  log "Server stopped"
  exit 0
fi
log "Server exited with code $rc"
exit "$rc"
