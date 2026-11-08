#!/usr/bin/env bash
# =============================================================================
#  install.sh - installer for The Isle (Evrima) dedicated server (Linux)
#
#  Two install modes - pick one with a flag, or answer the prompt:
#    --native   SteamCMD + server on this machine, systemd service, service user
#    --docker   the server runs in a Docker container (docker compose)
#  Both use the same launcher afterwards: isle-server <start|stop|status|...>
#
#  Supported distros (native mode): Debian/Ubuntu/Mint/Pop (apt), Fedora/RHEL/
#  Rocky/Alma (dnf/yum), Arch/Manjaro (pacman + [multilib]), openSUSE (zypper).
#  Docker mode needs Docker Engine + the compose plugin on any x86_64 distro.
#
#  Re-running is safe: it updates the scripts and keeps your settings and data.
#  Re-running with the other mode switches modes: the old one is stopped and
#  disabled (its data is kept) and your settings carry over.
#  Uninstall keeps the world; a later reinstall (either mode) picks it up again,
#  importing it from the other mode's retained data when the target has none.
#
#  Usage:
#    sudo ./linux/install.sh [--native|--docker] [options]
#    sudo ./linux/install.sh --uninstall [--native|--docker] [data choice] [--yes]
#
#  Options:
#    --native | --docker  install mode (default: ask; non-interactive: current mode, else native)
#    --start              start the server when finished
#    --image REF          docker: use this prebuilt/registry image instead of building
#    --branch NAME        Steam beta branch (default: evrima; "" = public)
#    --user NAME          native: service user          (default: theisle)
#    --home DIR           native: home of that user     (default: /home/NAME)
#    --no-service         native: no systemd units
#    --no-firewall        native: do not touch ufw/firewalld
#    --no-deps            native: skip package installation
#    --no-sudoers         native: no sudoers rule for the service user
#    --ui                 also run the web UI + REST API as a service (theisle-ui,
#                         127.0.0.1:UI_PORT; see UI.md). Kept on later re-runs
#    --no-ui              remove that service
#    --uninstall          remove the service/container (both modes unless one is
#                         given). What happens to the data: pick below, or answer
#                         the menu (non-interactive default: keep everything)
#      --keep-data          keep game files, worlds, backups and settings
#      --remove-game-files  delete re-downloadable files (server, SteamCMD, image)
#      --remove-worlds      delete worlds (a final backup is taken if backups are kept)
#      --remove-backups     delete backups
#      --remove-settings    delete server.conf and the scripts copy
#      --purge              delete everything above + the service user + Docker volume
#    --yes                do not ask for confirmation (deleting worlds/backups/settings)
#    --data copy|move|fresh   when switching modes (or finding the other mode's data):
#                         copy  = carry the data over, keep the source (default)
#                         move  = carry it over, then clear the source worlds/backups
#                         fresh = carry nothing
#    --carry LIST         parts to carry: worlds,backups,settings,overrides,plugins
#                         (default on a mode switch: worlds,settings,overrides,plugins;
#                          otherwise only a retained world is picked up)
#    --overwrite          replace a world that already exists in the target
#    --from-snapshot FILE restore a snapshot after installing (new machine / other OS)
#    --no-import          same as --data fresh
#    -h | --help          show this help
# =============================================================================
set -Eeuo pipefail

SRC_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
SVC_USER="theisle"
SVC_HOME=""
BRANCH=""; BRANCH_SET=0
MODE=""
DO_SERVICE=1; DO_FIREWALL=1; DO_DEPS=1; DO_SUDOERS=1; DO_START=0
DO_UNINSTALL=0; DO_PURGE=0; ASSUME_YES=0
DATA=copy; CARRY="worlds,settings,overrides,plugins"; CARRY_SET=0; OVERWRITE=0; FROM_SNAPSHOT=""
NO_FINAL_BACKUP=0; IMAGE_REF=""; DO_UI=0
RM_GAME=0; RM_WORLDS=0; RM_BACKUPS=0; RM_SETTINGS=0; DATA_FLAG=0; KEEP_DATA=0
SERVICE="theisle-server"
UI_SERVICE="theisle-ui"
UI_UNIT="/etc/systemd/system/theisle-ui.service"
UI_WAS=0; if [[ -f "$UI_UNIT" ]]; then UI_WAS=1; fi
UI_LINE=""
STATE_DIR="/etc/theisle-server"
STATE_FILE="$STATE_DIR/install.state"
DOCKER_SCRIPTS_DIR="/opt/theisle-scripts"
CONTAINER="theisle"
VOLUME="theisle-data"
VERSION="$(cat "$SRC_DIR/VERSION" 2>/dev/null || echo unknown)"

if [[ -t 1 ]]; then C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[36m'; C_RST=$'\e[0m'
else C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_RST=""; fi
step() { printf '\n%s==>%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
usage() { sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '/^=====/d'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --native)      MODE=native; shift ;;
    --docker)      MODE=docker; shift ;;
    --user)        SVC_USER="${2:?}"; shift 2 ;;
    --home)        SVC_HOME="${2:?}"; shift 2 ;;
    --branch)      BRANCH="${2-}"; BRANCH_SET=1; shift 2 ;;
    --no-service)  DO_SERVICE=0; shift ;;
    --no-firewall) DO_FIREWALL=0; shift ;;
    --no-deps)     DO_DEPS=0; shift ;;
    --no-sudoers)  DO_SUDOERS=0; shift ;;
    --start)       DO_START=1; shift ;;
    --ui)          DO_UI=1; shift ;;
    --no-ui)       DO_UI=-1; shift ;;
    --uninstall)   DO_UNINSTALL=1; shift ;;
    --purge)       DO_PURGE=1; DATA_FLAG=1; shift ;;
    --keep-data)   KEEP_DATA=1; DATA_FLAG=1; shift ;;
    --remove-game-files) RM_GAME=1; DATA_FLAG=1; shift ;;
    --remove-worlds)     RM_WORLDS=1; DATA_FLAG=1; shift ;;
    --remove-backups)    RM_BACKUPS=1; DATA_FLAG=1; shift ;;
    --remove-settings)   RM_SETTINGS=1; DATA_FLAG=1; shift ;;
    --yes|-y)      ASSUME_YES=1; shift ;;
    --no-import)   DATA=fresh; shift ;;
    --data)        DATA="${2:?}"; shift 2 ;;
    --carry)       CARRY="${2:?}"; CARRY_SET=1; shift 2 ;;
    --overwrite)   OVERWRITE=1; shift ;;
    --image)       IMAGE_REF="${2:?}"; shift 2 ;;
    --from-snapshot) FROM_SNAPSHOT="${2:?}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage; die "Unknown option: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Please run as root, e.g.: sudo $0 $*"
[[ "$(uname -m)" == "x86_64" ]] || die "The Isle dedicated server requires x86_64 (detected $(uname -m))"
[[ "$SVC_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid user name: $SVC_USER"
case "$DATA" in copy|move|fresh) ;; *) die "--data must be copy, move or fresh" ;; esac
if [[ -n "$CARRY" ]]; then
  for _p in ${CARRY//,/ }; do
    case "$_p" in worlds|backups|settings|overrides|plugins|all) ;; *) die "--carry: unknown part '$_p' (worlds,backups,settings,overrides,plugins)" ;; esac
  done
  [[ "$CARRY" == all ]] && CARRY="worlds,backups,settings,overrides,plugins"
fi
if [[ -n "$FROM_SNAPSHOT" ]]; then
  [[ -f "$FROM_SNAPSHOT" ]] || die "--from-snapshot: no such file $FROM_SNAPSHOT"
  FROM_SNAPSHOT="$(readlink -f "$FROM_SNAPSHOT")"
fi
if (( DATA_FLAG && ! DO_UNINSTALL )); then die "--purge/--keep-data/--remove-* are only valid together with --uninstall"; fi
if (( KEEP_DATA && (DO_PURGE || RM_GAME || RM_WORLDS || RM_BACKUPS || RM_SETTINGS) )); then
  die "--keep-data cannot be combined with --purge or --remove-*"
fi

# ------------------------------------------------------------------ state ---
# KEY=VALUE file written by every install; parsed, never sourced.
ST_MODE=""; ST_SCRIPTS_DIR=""; ST_USER=""; ST_HOME=""; ST_STATUS=""
read_state() {
  [[ -f "$STATE_FILE" ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      MODE) ST_MODE="$v" ;; SCRIPTS_DIR) ST_SCRIPTS_DIR="$v" ;;
      USER) ST_USER="$v" ;; HOME) ST_HOME="$v" ;; STATUS) ST_STATUS="$v" ;;
    esac
  done < "$STATE_FILE"
}
write_state() {  # MODE SCRIPTS_DIR [STATUS]
  # After an uninstall the file is kept with STATUS=uninstalled, so a reinstall
  # without a mode flag defaults to the previous mode. Only --purge deletes it.
  mkdir -p "$STATE_DIR"
  {
    printf 'MODE=%s\nSCRIPTS_DIR=%s\nSTATUS=%s\nVERSION=%s\nUPDATED=%s\n' \
      "$1" "$2" "${3:-installed}" "$VERSION" "$(date -u +%FT%TZ)"
    if [[ "$1" == native ]]; then printf 'USER=%s\nHOME=%s\n' "$SVC_USER" "$SVC_HOME"; fi
  } > "$STATE_FILE"
  chmod 644 "$STATE_FILE"
}
read_state
# Reuse the user/home of an existing native install unless overridden.
if [[ -n "$ST_USER" && "$SVC_USER" == theisle ]]; then SVC_USER="$ST_USER"; fi
if [[ -z "$SVC_HOME" ]]; then
  if id "$SVC_USER" >/dev/null 2>&1; then SVC_HOME="$(getent passwd "$SVC_USER" | cut -d: -f6)"
  elif [[ -n "$ST_HOME" ]]; then SVC_HOME="$ST_HOME"
  else SVC_HOME="/home/$SVC_USER"; fi
fi
NATIVE_SCRIPTS_DIR="$SVC_HOME/theisle-scripts"

have_docker_cli() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
native_installed() {
  [[ -f "/etc/systemd/system/$SERVICE.service" || -f "$NATIVE_SCRIPTS_DIR/linux/isle-server.sh" || "$ST_MODE" == native ]]
}
native_active() {  # an installed (not uninstalled) native setup that must be retired on a mode switch
  [[ -f "/etc/systemd/system/$SERVICE.service" ]] || [[ "$ST_MODE" == native && "$ST_STATUS" != uninstalled ]]
}
docker_installed() {
  have_docker_cli && [[ -n "$(docker ps -aq --filter "name=^${CONTAINER}\$" 2>/dev/null)" ]]
}

# ------------------------------------------------------------ helpers -------
CONF=""   # path of the server.conf being edited
conf_get() { grep -E "^$1=" "${CONF:-}" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"\r' || true; }
stamp() {  # [CONF] - yyyymmdd_hhmmss in that install's TIMEZONE (local|utc), the suffix of dated files
  local tz; tz="$(grep -E '^TIMEZONE=' "${1:-${CONF:-}}" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"\r ' | tr '[:upper:]' '[:lower:]')"
  if [[ "$tz" == utc ]]; then date -u +%Y%m%d_%H%M%S; else date +%Y%m%d_%H%M%S; fi
}
conf_set() {
  local key="$1" val="$2" esc
  if grep -qE "^$key=" "$CONF"; then
    esc="$(printf '%s' "$val" | sed -e 's/[\\/&|]/\\&/g')"
    sed -i "s|^$key=.*|$key=$esc|" "$CONF"
  else
    printf '%s=%s\n' "$key" "$val" >> "$CONF"
  fi
}

as_user() {  # run a command as the service user with a login-like env
  ( cd "$SVC_HOME" 2>/dev/null || cd /
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "$SVC_USER" -- env HOME="$SVC_HOME" USER="$SVC_USER" "$@"
    elif command -v sudo >/dev/null 2>&1; then
      sudo -u "$SVC_USER" -H "$@"
    else
      su -s /bin/bash "$SVC_USER" -c "$(printf '%q ' "$@")"
    fi )
}

copy_scripts() {  # DEST - copy this repo (minus .git and server.conf) to DEST
  local dest="$1"
  if [[ "$(readlink -f "$SRC_DIR")" != "$(readlink -f "$dest" 2>/dev/null || echo /nonexistent)" ]]; then
    mkdir -p "$dest"
    (cd "$SRC_DIR" && tar --exclude='.git' --exclude='config/server.conf' --exclude='config/*.bak' --exclude='config/ui-token' --exclude='config/*.bak-api' -cf - .) \
      | (cd "$dest" && tar -xf -)
  fi
  sed -i 's/\r$//' "$dest"/linux/*.sh "$dest"/docker/entrypoint.sh "$dest"/docker/isle-server
  chmod 755 "$dest"/linux/*.sh "$dest"/tools/*.py "$dest"/docker/entrypoint.sh "$dest"/docker/isle-server
}

seed_conf() {  # DEST [--fresh] - create DEST/config/server.conf, carrying settings over
  local dest="$1" cand
  CONF="$dest/config/server.conf"
  if [[ -f "$CONF" ]]; then ok "Keeping existing $CONF"; return; fi
  if [[ "${2:-}" == --fresh ]]; then
    cp "$dest/config/server.conf.example" "$CONF"; ok "Created $CONF from the example (settings not carried)"; return
  fi
  for cand in "$ST_SCRIPTS_DIR/config/server.conf" "$NATIVE_SCRIPTS_DIR/config/server.conf" \
              "$DOCKER_SCRIPTS_DIR/config/server.conf" "$SRC_DIR/config/server.conf"; do
    if [[ -n "$cand" && -f "$cand" && "$cand" != "$CONF" ]]; then
      cp "$cand" "$CONF"; ok "Carried settings over from $cand"; return
    fi
  done
  cp "$dest/config/server.conf.example" "$CONF"
  ok "Created $CONF from the example"
}

finish_conf() {  # MODE
  sed -i 's/\r$//' "$CONF"
  conf_set RUNTIME "$1"
  if (( BRANCH_SET )); then conf_set STEAM_BRANCH "$BRANCH"; fi
  if [[ -z "$(conf_get RCON_PASSWORD)" ]]; then
    conf_set RCON_PASSWORD "$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)"
    ok "Generated a random RCON password (in $CONF)"
  fi
  chmod 600 "$CONF"
}

link_launcher() { ln -sf "$1/linux/isle-server.sh" /usr/local/bin/isle-server 2>/dev/null || true; }
unlink_launcher() {  # remove /usr/local/bin/isle-server if it points into DIR
  local target; target="$(readlink -f /usr/local/bin/isle-server 2>/dev/null || true)"
  if [[ -n "$target" && "$target" == "$1"/* ]]; then rm -f /usr/local/bin/isle-server; fi
}

confirm() {  # PROMPT - require typing "yes" unless --yes
  (( ASSUME_YES )) && return 0
  [[ -t 0 ]] || die "Refusing to $1 without confirmation - re-run with --yes"
  local ans; read -r -p "$1? Type 'yes' to continue: " ans
  [[ "$ans" == yes ]] || die "Aborted"
}

# ------------------------------------------------------------- firewall ----
firewall_rules() {  # add | remove  (uses $CONF for the ports)
  local action="$1" gp qp rp open_rcon
  gp="$(conf_get GAME_PORT)"; gp="${gp:-7777}"
  qp="$(conf_get QUEUE_PORT)"; qp="${qp:-10000}"
  rp="$(conf_get RCON_PORT)"; rp="${rp:-8888}"
  open_rcon="$(conf_get FIREWALL_OPEN_RCON)"
  local -a rules=("$gp/udp" "$gp/tcp" "$qp/tcp")
  if [[ "${open_rcon,,}" == "true" ]]; then rules+=("$rp/tcp"); fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    local r
    for r in "${rules[@]}"; do
      if [[ "$action" == add ]]; then ufw allow "$r" comment 'The Isle server' >/dev/null
      else ufw delete allow "$r" >/dev/null 2>&1 || true; fi
    done
    ok "ufw: ${action} ${rules[*]}"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    local r flag="--remove-port"
    if [[ "$action" == add ]]; then flag="--add-port"; fi
    for r in "${rules[@]}"; do firewall-cmd --permanent "$flag=$r" >/dev/null 2>&1 || true; done
    firewall-cmd --reload >/dev/null
    ok "firewalld: ${action} ${rules[*]}"
  elif [[ "$action" == add ]]; then
    warn "No active ufw/firewalld found. If you use iptables/nftables or a cloud firewall, open: ${rules[*]}"
  fi
}

# ---------------------------------------------------------------- web UI ----
has_systemd() { command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }
remove_ui() {
  [[ -f "$UI_UNIT" ]] || return 0
  systemctl disable --now "$UI_SERVICE.service" >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/theisle-ui.service
  systemctl daemon-reload >/dev/null 2>&1 || true
  ok "Removed the web UI service"
}
setup_ui() {  # MODE SCRIPTS_DIR - the web UI service (PRD UI-04)
  local mode="$1" dir="$2" conf="$2/config/server.conf" user=root group=root home=/root py port who=""
  if (( DO_UI < 0 )); then remove_ui; return 0; fi
  (( DO_UI || UI_WAS )) || return 0
  ensure_python || { warn "python3 is missing - web UI not installed"; return 0; }
  port="$(conf_get UI_PORT)"; port="${port:-8090}"
  if [[ "$mode" == native ]]; then user="$SVC_USER"; group="$(id -gn "$SVC_USER")"; home="$SVC_HOME"; who="sudo -u $SVC_USER "; fi
  py="$(command -v python3)"
  # the token is created by the user who runs the UI (file mode 600)
  if [[ "$mode" == native ]]; then
    as_user "$py" "$dir/tools/isle_api.py" --conf "$conf" --print-token >/dev/null
  else
    "$py" "$dir/tools/isle_api.py" --conf "$conf" --print-token >/dev/null
  fi
  if ! has_systemd; then
    warn "systemd not detected - no web UI service. Run it when needed: ${who}isle-server ui"
    UI_LINE="Web UI      : run '${who}isle-server ui', then open http://127.0.0.1:$port/ (token: ${who}isle-server ui-token)"
    return 0
  fi
  step "Installing the web UI service ($UI_SERVICE)"
  local after="network-online.target"; if [[ "$mode" == docker ]]; then after="network-online.target docker.service"; fi
  cat > "$UI_UNIT" <<EOF
[Unit]
Description=The Isle server web UI and REST API
Documentation=file://$dir/UI.md
Wants=network-online.target
After=$after

[Service]
Type=simple
User=$user
Group=$group
WorkingDirectory=$home
Environment=HOME=$home
Environment=ISLE_CONF=$conf
Environment=ISLE_RUNTIME=$mode
Environment=PYTHONUNBUFFERED=1
ExecStart=$py $dir/tools/isle_api.py --conf $conf --launcher $dir/linux/isle-server.sh --runtime $mode
Restart=on-failure
RestartSec=5
# a game server started from the UI (without the theisle-server service) survives a UI restart
KillMode=process
UMask=0077
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$UI_SERVICE.service" >/dev/null 2>&1
  systemctl restart "$UI_SERVICE.service"
  ok "Web UI on http://127.0.0.1:$port/ (API docs at /docs)"
  UI_LINE="Web UI      : http://127.0.0.1:$port/  (token: ${who}isle-server ui-token; remote: ssh -L $port:127.0.0.1:$port <host>)"
}

# ------------------------------------------------- retire (keeps data) ------
retire_native() {
  step "Stopping and disabling the native server (data is kept)"
  remove_ui
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$SERVICE.service" "$SERVICE-backup.timer" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$SERVICE.service" "/etc/systemd/system/$SERVICE-backup.service" \
          "/etc/systemd/system/$SERVICE-backup.timer"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  if id "$SVC_USER" >/dev/null 2>&1 && [[ -x "$NATIVE_SCRIPTS_DIR/linux/isle-server.sh" ]]; then
    as_user env ISLE_NO_SYSTEMD=1 ISLE_RUNTIME=native ISLE_CONF="$NATIVE_SCRIPTS_DIR/config/server.conf" \
      "$NATIVE_SCRIPTS_DIR/linux/isle-server.sh" stop >/dev/null 2>&1 || true
  fi
  rm -f "/etc/sudoers.d/$SERVICE"
  if [[ -f "$NATIVE_SCRIPTS_DIR/config/server.conf" ]]; then
    local saved="$CONF"; CONF="$NATIVE_SCRIPTS_DIR/config/server.conf"; firewall_rules remove; CONF="$saved"
  fi
  unlink_launcher "$NATIVE_SCRIPTS_DIR"
  ok "Native service removed"
}

retire_docker() {
  step "Stopping and removing the container (the $VOLUME volume is kept)"
  remove_ui
  if have_docker_cli; then
    docker stop -t 90 "$CONTAINER" >/dev/null 2>&1 || true
    docker rm "$CONTAINER" >/dev/null 2>&1 || true
  fi
  unlink_launcher "$DOCKER_SCRIPTS_DIR"
  ok "Container removed"
}

# ------------------------------------------------- retained world data ------
# A "world" is TheIsle/Saved with anything besides Config, Logs and Crashes.
# Reinstalls import a retained world from the other runtime when the target has
# none, and never overwrite an existing world (PRD INS-19).
native_saved_dir() {
  local conf="$NATIVE_SCRIPTS_DIR/config/server.conf" dir=""
  if [[ -f "$conf" ]]; then dir="$(grep -E '^SERVER_DIR=' "$conf" | tail -n1 | cut -d= -f2- | tr -d '"\r')"; fi
  printf '%s/TheIsle/Saved' "${dir:-$SVC_HOME/theisle-server}"
}
native_has_world() {
  local saved; saved="$(native_saved_dir)"
  [[ -d "$saved" ]] && find "$saved" -mindepth 1 -maxdepth 1 ! -name Config ! -name Logs ! -name Crashes -print -quit | grep -q .
}

helper_image() {  # an image with sh + tar to look inside the volume
  local img
  for img in "$(conf_get DOCKER_IMAGE 2>/dev/null)" theisle-server:latest debian:bookworm-slim; do
    if [[ -n "$img" ]] && docker image inspect "$img" >/dev/null 2>&1; then printf '%s' "$img"; return 0; fi
  done
  docker pull -q debian:bookworm-slim >/dev/null 2>&1 && printf 'debian:bookworm-slim'
}
volume_has_world() {
  have_docker_cli && docker volume inspect "$VOLUME" >/dev/null 2>&1 || return 1
  local img; img="$(helper_image)" || return 1
  [[ -n "$img" ]] || return 1
  docker run --rm -v "$VOLUME:/data:ro" --entrypoint sh "$img" -c \
    'd=/data/server/TheIsle/Saved; [ -d "$d" ] && find "$d" -mindepth 1 -maxdepth 1 ! -name Config ! -name Logs ! -name Crashes | grep -q .' \
    >/dev/null 2>&1
}


# ---------------------------------------------------------- dependencies ----
detect_distro() {
  DISTRO_ID="unknown"; DISTRO_NAME="Unknown Linux"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"; DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"
  fi
}

pkg_try() {  # install packages one by one; returns non-zero if any failed
  local mgr="$1"; shift
  local p failed=0
  for p in "$@"; do
    if case "$mgr" in
         apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$p" >/dev/null 2>&1 ;;
         dnf)    dnf install -y -q "$p" >/dev/null 2>&1 ;;
         yum)    yum install -y -q "$p" >/dev/null 2>&1 ;;
         pacman) pacman -S --noconfirm --needed "$p" >/dev/null 2>&1 ;;
         zypper) zypper --non-interactive install -y "$p" >/dev/null 2>&1 ;;
         *)      false ;;
       esac; then
      ok "package $p"
    else
      warn "could not install package $p"; failed=1
    fi
  done
  return "$failed"
}

install_deps() {
  detect_distro
  step "Installing dependencies for $DISTRO_NAME"
  if command -v apt-get >/dev/null 2>&1; then
    dpkg --add-architecture i386 2>/dev/null || true
    # Ubuntu ships i386 libs in "multiverse"/"universe"; make sure they are on.
    if [[ "$DISTRO_ID" == "ubuntu" ]] && command -v add-apt-repository >/dev/null 2>&1; then
      add-apt-repository -y multiverse >/dev/null 2>&1 || true
    fi
    apt-get update -q >/dev/null || warn "apt-get update reported errors"
    pkg_try apt ca-certificates curl wget tar gzip python3 procps locales || true
    pkg_try apt lib32gcc-s1 || pkg_try apt lib32gcc1 || true
    pkg_try apt lib32stdc++6 libsdl2-2.0-0 || true
  elif command -v dnf >/dev/null 2>&1; then
    pkg_try dnf ca-certificates curl wget tar gzip python3 procps-ng glibc.i686 libstdc++.i686 libgcc.i686 || true
  elif command -v yum >/dev/null 2>&1; then
    pkg_try yum ca-certificates curl wget tar gzip python3 procps-ng glibc.i686 libstdc++.i686 libgcc.i686 || true
  elif command -v pacman >/dev/null 2>&1; then
    if ! grep -qE '^\[multilib\]' /etc/pacman.conf; then
      warn "[multilib] is not enabled in /etc/pacman.conf - enabling it (needed for lib32-gcc-libs)"
      cp /etc/pacman.conf /etc/pacman.conf.bak-theisle
      sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
    fi
    pacman -Sy --noconfirm >/dev/null 2>&1 || warn "pacman -Sy failed"
    pkg_try pacman ca-certificates curl wget tar gzip python procps-ng lib32-gcc-libs lib32-glibc || true
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive refresh >/dev/null 2>&1 || true
    pkg_try zypper ca-certificates curl wget tar gzip python3 procps libgcc_s1-32bit glibc-32bit libstdc++6-32bit || true
  elif command -v apk >/dev/null 2>&1; then
    die "Alpine (musl) is not supported natively: SteamCMD and the server need glibc. Use --docker instead."
  else
    warn "Unknown package manager. Make sure these are installed: curl tar python3 and 32-bit glibc + libgcc + libstdc++."
  fi
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "curl or wget is required"
  command -v tar  >/dev/null 2>&1 || die "tar is required"
}


# ------------------------------------------------- carry data (snapshots) ---
# Mode switches and --from-snapshot move data with tools/isle_snapshot.py, the
# same engine as "isle-server snapshot" (PRD MIG-05/06).
ensure_python() {
  command -v python3 >/dev/null 2>&1 && return 0
  if (( DO_DEPS )); then
    if command -v apt-get >/dev/null 2>&1; then apt-get update -q >/dev/null 2>&1 || true; pkg_try apt python3 || true
    elif command -v dnf >/dev/null 2>&1; then pkg_try dnf python3 || true
    elif command -v yum >/dev/null 2>&1; then pkg_try yum python3 || true
    elif command -v pacman >/dev/null 2>&1; then pkg_try pacman python || true
    elif command -v zypper >/dev/null 2>&1; then pkg_try zypper python3 || true; fi
  fi
  command -v python3 >/dev/null 2>&1
}
snap_tool() {  # SCRIPTS_DIR args... - the install's own copy of the tool (or this repo's)
  local dir="$1"; shift
  local tool="$dir/tools/isle_snapshot.py"
  [[ -f "$tool" ]] || tool="$SRC_DIR/tools/isle_snapshot.py"
  python3 "$tool" "$@"
}
has_part() { [[ ",$1," == *",$2,"* ]]; }
drop_part() { local out="" p; for p in ${1//,/ }; do [[ "$p" == "$2" ]] || out="${out:+$out,}$p"; done; printf '%s' "$out"; }

SNAP_FILE=""; SNAP_PARTS=""
make_carry_snapshot() {  # SOURCE(native|docker) PARTS - sets SNAP_FILE/SNAP_PARTS on success
  local src="$1" parts="$2" out log rc=0
  [[ -n "$parts" ]] || return 0
  if ! ensure_python; then
    warn "python3 is not available - the $src data was not carried over (it is kept; carry it later with: isle-server snapshot)"
    return 0
  fi
  out="/var/tmp/theisle-carry-${src}_$(stamp).tar.gz"; log="$(mktemp)"
  step "Taking a snapshot of the $src data to carry over ($parts)"
  if [[ "$src" == native ]]; then
    snap_tool "$SRC_DIR" --conf "$NATIVE_SCRIPTS_DIR/config/server.conf" --runtime native \
      --server-dir "$(native_path SERVER_DIR "$SVC_HOME/theisle-server")" \
      --backup-dir "$(native_path BACKUP_DIR "$SVC_HOME/theisle-backups")" \
      --overrides-dir "$NATIVE_SCRIPTS_DIR/config/overrides" --plugins-dir "$NATIVE_SCRIPTS_DIR/plugins/installed" \
      create --include "$parts" --output "$out" --no-save > "$log" 2>&1 || rc=$?
  else
    snap_tool "$SRC_DIR" --conf "$DOCKER_SCRIPTS_DIR/config/server.conf" --runtime docker \
      --overrides-dir "$DOCKER_SCRIPTS_DIR/config/overrides" --plugins-dir "$DOCKER_SCRIPTS_DIR/plugins/installed" \
      create --include "$parts" --output "$out" --no-save > "$log" 2>&1 || rc=$?
  fi
  sed 's/^/  /' "$log"
  if (( rc == 0 )); then SNAP_FILE="$out"; SNAP_PARTS="$parts"
  elif grep -q 'nothing to snapshot' "$log"; then ok "Nothing to carry over from $src"
  else warn "The snapshot failed - the $src data was not carried over (it is kept)"; fi
  rm -f "$log"
}

RESTORED_WORLD=0; RESTORED_BACKUPS=0
restore_snapshot() {  # TARGET(native|docker) SCRIPTS_DIR LAUNCHER FILE PARTS
  local tgt="$1" dir="$2" launcher_path="$3" file="$4" parts="$5" log rc=0
  [[ -n "$parts" && -f "$file" ]] || return 0
  if ! ensure_python; then warn "python3 is not available - restore $file later with: isle-server snapshot restore"; return 0; fi
  local -a args=(--conf "$CONF" --runtime "$tgt" --launcher "$launcher_path"
                 --overrides-dir "$dir/config/overrides" --plugins-dir "$dir/plugins/installed")
  if [[ "$tgt" == native ]]; then
    args+=(--server-dir "$(conf_get SERVER_DIR)" --backup-dir "$(conf_get BACKUP_DIR)" --owner "$SVC_USER")
  fi
  local -a extra=(); if (( OVERWRITE )); then extra=(--overwrite); fi
  log="$(mktemp)"
  step "Restoring $(basename "$file") into $tgt ($parts)"
  snap_tool "$dir" "${args[@]}" restore "$file" --include "$parts" "${extra[@]}" > "$log" 2>&1 || rc=$?
  sed 's/^/  /' "$log"
  grep -q 'World restored' "$log" && RESTORED_WORLD=1
  grep -q 'Backups restored' "$log" && RESTORED_BACKUPS=1
  rm -f "$log"
  if (( rc != 0 )); then MIGRATE_HINT="Restoring $file failed - retry with: sudo isle-server snapshot restore $file"; fi
  return 0
}

finish_carry() {  # SOURCE TARGET_SCRIPTS_DIR - "move" cleanup + keep the carry snapshot
  local src="$1" dir="$2"
  [[ -n "$SNAP_FILE" ]] || return 0
  if [[ "$DATA" == move ]]; then
    RM_GAME=0; RM_SETTINGS=0
    RM_WORLDS=$RESTORED_WORLD
    RM_BACKUPS=0; if has_part "$SNAP_PARTS" backups && (( RESTORED_BACKUPS )); then RM_BACKUPS=1; fi
    NO_FINAL_BACKUP=1
    if (( RM_WORLDS || RM_BACKUPS )); then
      step "Moving: clearing the $src copy of $(removal_list)"
      if [[ "$src" == native ]]; then remove_native_data; else remove_docker_data; fi
    else
      warn "Nothing was restored, so nothing was removed from $src"
    fi
  fi
  mkdir -p "$dir/snapshots"
  mv "$SNAP_FILE" "$dir/snapshots/" && SNAP_FILE="$dir/snapshots/$(basename "$SNAP_FILE")"
  if [[ "$dir" == "$NATIVE_SCRIPTS_DIR" ]] && id "$SVC_USER" >/dev/null 2>&1; then chown -R "$SVC_USER:" "$dir/snapshots"; fi
  ok "The carry snapshot is kept at $SNAP_FILE"
}

# ------------------------------------------------------- uninstall choices --
# Data categories (PRD INS-20). RM_*=1 means delete on uninstall.
#   game files : server install + SteamCMD (+ Docker image)  - re-downloadable
#   worlds     : TheIsle/Saved
#   backups    : BACKUP_DIR / volume /data/backups
#   settings   : server.conf + the scripts copy
choose_removals() {
  if (( DO_PURGE )); then RM_GAME=1; RM_WORLDS=1; RM_BACKUPS=1; RM_SETTINGS=1; return; fi
  if (( DATA_FLAG )) || [[ ! -t 0 ]]; then return; fi
  printf '\nWhat should happen to the server data?\n'
  printf '  1) Keep everything                 - a reinstall picks it up again (default)\n'
  printf '  2) Remove game files only          - frees disk space; worlds, backups and settings are kept\n'
  printf '  3) Remove game files and worlds    - backups and settings are kept (a final backup is taken)\n'
  printf '  4) Delete everything (purge)       - game files, worlds, backups, settings, service user, Docker volume\n'
  printf '  5) Choose each item\n'
  local ans; read -r -p "Choose 1-5 [1]: " ans
  case "${ans:-1}" in
    1) ;;
    2) RM_GAME=1 ;;
    3) RM_GAME=1; RM_WORLDS=1 ;;
    4) DO_PURGE=1; RM_GAME=1; RM_WORLDS=1; RM_BACKUPS=1; RM_SETTINGS=1 ;;
    5) ask_yn "Remove game files (server install, SteamCMD, Docker image - re-downloadable)?" && RM_GAME=1
       ask_yn "Remove worlds (TheIsle/Saved)?" && RM_WORLDS=1
       ask_yn "Remove backups?" && RM_BACKUPS=1
       ask_yn "Remove settings (server.conf and the scripts copy)?" && RM_SETTINGS=1
       return 0 ;;
    *) die "Please answer 1-5" ;;
  esac
}
ask_yn() { local a; read -r -p "$1 [y/N]: " a; [[ "${a,,}" == y || "${a,,}" == yes ]]; }

removal_list() {
  local -a l=()
  (( RM_GAME )) && l+=("game files"); (( RM_WORLDS )) && l+=("worlds")
  (( RM_BACKUPS )) && l+=("backups"); (( RM_SETTINGS )) && l+=("settings")
  if (( ${#l[@]} )); then local IFS=,; printf '%s' "${l[*]}" | sed 's/,/, /g'; else printf 'nothing'; fi
}
kept_list() {
  local -a l=()
  (( RM_GAME )) || l+=("game files"); (( RM_WORLDS )) || l+=("worlds")
  (( RM_BACKUPS )) || l+=("backups"); (( RM_SETTINGS )) || l+=("settings")
  if (( ${#l[@]} )); then local IFS=,; printf '%s' "${l[*]}" | sed 's/,/, /g'; else printf 'nothing'; fi
}

safe_rm() {  # delete a directory from server.conf only if the path is clearly not a system dir
  local p="$1"
  [[ -n "$p" && "$p" == /* ]] || { warn "Not deleting '$p' (not an absolute path)"; return 0; }
  p="$(readlink -m "$p")"
  if [[ "$p" =~ ^/(bin|boot|dev|etc|lib|lib32|lib64|libx32|proc|run|sbin|sys|usr)(/|$) ]] \
     || [[ "$(dirname "$p")" == / || "$(dirname "$p")" == /home || "$p" == "$(readlink -m "$SVC_HOME")" ]]; then
    warn "Not deleting '$p' (looks like a system or home directory) - remove it by hand if you really want to"
    return 0
  fi
  if [[ -e "$p" ]]; then rm -rf -- "$p"; ok "Removed $p"; fi
}

native_path() {  # KEY DEFAULT - value from the native server.conf
  local conf="$NATIVE_SCRIPTS_DIR/config/server.conf" v=""
  if [[ -f "$conf" ]]; then v="$(grep -E "^$1=" "$conf" | tail -n1 | cut -d= -f2- | tr -d '"\r')"; fi
  printf '%s' "${v:-$2}"
}

remove_native_data() {
  (( RM_GAME || RM_WORLDS || RM_BACKUPS || RM_SETTINGS )) || return 0
  local sdir scdir bdir
  sdir="$(native_path SERVER_DIR "$SVC_HOME/theisle-server")"
  scdir="$(native_path STEAMCMD_DIR "$SVC_HOME/steamcmd")"
  bdir="$(native_path BACKUP_DIR "$SVC_HOME/theisle-backups")"
  step "Removing native data: $(removal_list)"
  if (( RM_WORLDS && ! RM_BACKUPS && ! NO_FINAL_BACKUP )) && native_has_world; then
    mkdir -p "$bdir"
    local f; f="$bdir/theisle-final_$(stamp "$NATIVE_SCRIPTS_DIR/config/server.conf").tar.gz"
    if tar -czf "$f" -C "$sdir/TheIsle" --exclude=Saved/Logs --exclude=Saved/Crashes Saved; then
      chown -R "$SVC_USER:" "$bdir" 2>/dev/null || true
      ok "Final backup of the world: $f"
    else
      die "Could not take a final backup - nothing was deleted"
    fi
  fi
  if (( RM_GAME && RM_WORLDS )); then
    safe_rm "$sdir"
  else
    if (( RM_GAME )) && [[ -d "$sdir" ]]; then
      find "$sdir" -mindepth 1 -maxdepth 1 ! -name TheIsle -exec rm -rf -- {} +
      if [[ -d "$sdir/TheIsle" ]]; then find "$sdir/TheIsle" -mindepth 1 -maxdepth 1 ! -name 'Saved*' -exec rm -rf -- {} +; fi
      ok "Removed game files in $sdir (worlds kept)"
    fi
    if (( RM_WORLDS )) && [[ -d "$sdir/TheIsle" ]]; then
      find "$sdir/TheIsle" -mindepth 1 -maxdepth 1 -name 'Saved*' -exec rm -rf -- {} +
      ok "Removed worlds in $sdir/TheIsle"
    fi
  fi
  if (( RM_GAME )); then safe_rm "$scdir"; rm -rf -- "${SVC_HOME:?}/.steam"; fi
  if (( RM_BACKUPS )); then safe_rm "$bdir"; fi
  if (( RM_SETTINGS )); then safe_rm "$NATIVE_SCRIPTS_DIR"; fi
}

remove_docker_data() {
  (( RM_GAME || RM_WORLDS || RM_BACKUPS || RM_SETTINGS )) || return 0
  step "Removing Docker data: $(removal_list)"
  if ! have_docker_cli; then warn "Docker is not available - Docker data was not touched"; return 0; fi
  if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
    if (( RM_GAME && RM_WORLDS && RM_BACKUPS && RM_SETTINGS )); then
      docker volume rm "$VOLUME" >/dev/null && ok "Removed volume $VOLUME"
    else
      local img; img="$(helper_image)" || img=""
      [[ -n "$img" ]] || die "No image available to edit volume $VOLUME - nothing was deleted"
      local cmd="set -e"
      if (( RM_WORLDS && ! RM_BACKUPS && ! NO_FINAL_BACKUP )) && volume_has_world; then
        cmd+="; mkdir -p /data/backups; tar -czf /data/backups/theisle-final_$(stamp "$DOCKER_SCRIPTS_DIR/config/server.conf").tar.gz -C /data/server/TheIsle --exclude=Saved/Logs --exclude=Saved/Crashes Saved"
        ok "Taking a final backup of the world into /data/backups"
      fi
      if (( RM_GAME )); then
        cmd+="; [ -d /data/server ] && find /data/server -mindepth 1 -maxdepth 1 ! -name TheIsle -exec rm -rf {} + || true"
        cmd+="; [ -d /data/server/TheIsle ] && find /data/server/TheIsle -mindepth 1 -maxdepth 1 ! -name 'Saved*' -exec rm -rf {} + || true"
        cmd+="; rm -rf /data/steamcmd /data/home"
      fi
      if (( RM_WORLDS )); then cmd+="; rm -rf /data/server/TheIsle/Saved /data/server/TheIsle/Saved.pre-restore[-_]*"; fi
      if (( RM_BACKUPS )); then cmd+="; rm -rf /data/backups"; fi
      if (( RM_SETTINGS )); then cmd+="; rm -rf /data/config"; fi
      if docker run --rm -v "$VOLUME:/data" --entrypoint sh "$img" -c "$cmd"; then
        ok "Updated volume $VOLUME (kept: $(kept_list))"
      else
        die "Editing volume $VOLUME failed"
      fi
    fi
  fi
  if (( DO_PURGE )); then
    local vol
    for vol in $(docker volume ls -q | grep -E '_theisle-data$' || true); do
      if docker volume rm "$vol" >/dev/null 2>&1; then ok "Removed legacy volume $vol"; fi
    done
  fi
  if (( RM_GAME )) && docker image rm theisle-server:latest >/dev/null 2>&1; then ok "Removed image theisle-server:latest"; fi
  if (( RM_SETTINGS )); then safe_rm "$DOCKER_SCRIPTS_DIR"; fi
}

# --------------------------------------------------------------- uninstall --
do_uninstall() {
  local want="$MODE" any=0 do_native=0 do_docker=0
  choose_removals
  if [[ -z "$want" || "$want" == native ]] && native_installed; then do_native=1; fi
  if [[ -z "$want" || "$want" == docker ]] && { docker_installed || [[ "$ST_MODE" == docker || -d "$DOCKER_SCRIPTS_DIR" ]] \
       || { have_docker_cli && docker volume inspect "$VOLUME" >/dev/null 2>&1; }; }; then do_docker=1; fi
  if (( DO_PURGE )); then
    confirm "PURGE: delete ALL server files, worlds, backups, settings and the service user"
  elif (( RM_WORLDS || RM_BACKUPS || RM_SETTINGS )); then
    confirm "Delete $(removal_list)"
  fi
  if (( do_native )); then
    any=1; retire_native
    remove_native_data
    if (( DO_PURGE )) && id "$SVC_USER" >/dev/null 2>&1; then
      userdel -r "$SVC_USER" >/dev/null 2>&1 || userdel "$SVC_USER" || true
      if [[ -d "$SVC_HOME" && "$SVC_HOME" == /home/* ]]; then rm -rf -- "$SVC_HOME"; fi
      ok "Removed user $SVC_USER and its home ($SVC_HOME)"
    fi
  fi
  if (( do_docker )); then
    any=1; retire_docker
    remove_docker_data
  fi
  if (( DO_PURGE )); then
    rm -f "$STATE_FILE"; rmdir "$STATE_DIR" 2>/dev/null || true
  elif [[ -n "$ST_MODE" ]]; then
    write_state "$ST_MODE" "$ST_SCRIPTS_DIR" uninstalled
  fi
  remove_ui
  (( any )) || warn "Nothing to uninstall was found"
  if (( DO_PURGE )); then
    ok "Purged. A reinstall starts from scratch."
  else
    ok "Uninstalled. Removed: $(removal_list). Kept: $(kept_list)."
    echo "  Re-run this installer to reinstall$( (( RM_WORLDS )) || echo ' - kept worlds are picked up again')."
  fi
}

if (( DO_UNINSTALL )); then do_uninstall; exit 0; fi

# ------------------------------------------------------------- choose mode --
if [[ -z "$MODE" ]]; then
  default="${ST_MODE:-native}"
  if [[ -t 0 ]]; then
    printf '\nHow should the server run?\n  1) native  - SteamCMD + systemd service on this machine\n  2) docker  - in a Docker container\n'
    read -r -p "Choose 1 or 2 [$([[ "$default" == docker ]] && echo 2 || echo 1)]: " answer
    case "${answer:-}" in
      1|native) MODE=native ;; 2|docker) MODE=docker ;; "") MODE="$default" ;;
      *) die "Please answer 1 or 2" ;;
    esac
  else
    MODE="$default"
  fi
fi
ok "Install mode: $MODE${ST_MODE:+ (previously: $ST_MODE)}"
MIGRATE_HINT=""

# ==================================================================== DOCKER
if [[ "$MODE" == docker ]]; then
  step "Checking Docker"
  command -v docker >/dev/null 2>&1 \
    || die "Docker is not installed. Install Docker Engine + the compose plugin (https://docs.docker.com/engine/install/), then re-run: sudo $0 --docker"
  docker compose version >/dev/null 2>&1 \
    || die "Docker Compose v2 is missing. Install the 'docker-compose-plugin' (or 'docker-compose-v2') package, then re-run."
  boot_note="make sure the Docker daemon starts at boot (no systemd detected)"
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    if systemctl enable --now docker >/dev/null 2>&1; then boot_note="the docker service is enabled at boot"
    else warn "Could not enable the docker service at boot"; fi
  fi
  docker info >/dev/null 2>&1 || die "The Docker daemon is not running (try: systemctl start docker)"
  ok "$(docker --version)"

  switching=0
  if native_active; then switching=1; step "Switching from native to docker"; retire_native; fi
  # What to carry from the native side (PRD MIG-05; INS-19 for a retained world).
  parts=""; reused=0
  if [[ "$DATA" != fresh ]]; then
    if (( switching || CARRY_SET )); then parts="$CARRY"; elif native_has_world; then parts="worlds"; fi
  fi
  if has_part "$parts" worlds; then
    if ! native_has_world; then parts="$(drop_part "$parts" worlds)"
    elif volume_has_world && (( ! OVERWRITE )); then
      ok "Reusing the world kept in Docker volume $VOLUME (the native world is kept too; --overwrite replaces it)"
      parts="$(drop_part "$parts" worlds)"; reused=1
    fi
  fi
  if [[ -n "$parts" ]]; then make_carry_snapshot native "$parts"; fi

  step "Installing scripts to $DOCKER_SCRIPTS_DIR"
  copy_scripts "$DOCKER_SCRIPTS_DIR"
  if [[ "$DATA" == fresh ]] || { (( CARRY_SET )) && ! has_part "$CARRY" settings; }; then seed_conf "$DOCKER_SCRIPTS_DIR" --fresh
  else seed_conf "$DOCKER_SCRIPTS_DIR"; fi
  finish_conf docker
  if [[ -n "$IMAGE_REF" ]]; then conf_set DOCKER_BUILD false; conf_set DOCKER_IMAGE "$IMAGE_REF"; ok "Using prebuilt image $IMAGE_REF"; fi
  link_launcher "$DOCKER_SCRIPTS_DIR"
  launcher="$DOCKER_SCRIPTS_DIR/linux/isle-server.sh"
  export ISLE_CONF="$CONF"

  was_running=0
  if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" == true ]]; then was_running=1; fi
  "$launcher" --docker stop >/dev/null 2>&1 || true
  # Containers from older versions used another compose project name; recreate.
  docker rm "$CONTAINER" >/dev/null 2>&1 || true

  step "Building the image and creating the container"
  "$launcher" --docker install

  # Pre-1.4 installs stored the world in "<folder>_theisle-data"; move it once.
  if ! docker volume inspect "$VOLUME" >/dev/null 2>&1 || \
     [[ -z "$(docker run --rm -v "$VOLUME:/v" --entrypoint sh "$(conf_get DOCKER_IMAGE)" -c 'ls -A /v/server 2>/dev/null' 2>/dev/null)" ]]; then
    mapfile -t legacy < <(docker volume ls -q | grep -E '_theisle-data$' || true)
    if (( ${#legacy[@]} == 1 )); then
      step "Copying world data from legacy volume ${legacy[0]} to $VOLUME"
      docker volume create "$VOLUME" >/dev/null
      docker run --rm -v "${legacy[0]}:/from:ro" -v "$VOLUME:/to" --entrypoint sh "$(conf_get DOCKER_IMAGE)" \
        -c 'cp -a /from/. /to/' && ok "Copied (the old volume was left in place)"
    fi
  fi

  if [[ -n "$SNAP_FILE" ]]; then
    restore_snapshot docker "$DOCKER_SCRIPTS_DIR" "$launcher" "$SNAP_FILE" "$SNAP_PARTS"
    finish_carry native "$DOCKER_SCRIPTS_DIR"
  elif [[ -z "$FROM_SNAPSHOT" ]] && (( ! reused )) && volume_has_world; then
    ok "Reusing the world kept in Docker volume $VOLUME"
  fi
  if [[ -n "$FROM_SNAPSHOT" ]]; then
    fs_parts="worlds,settings,overrides,plugins"; if (( CARRY_SET )); then fs_parts="$CARRY"; fi
    restore_snapshot docker "$DOCKER_SCRIPTS_DIR" "$launcher" "$FROM_SNAPSHOT" "$fs_parts"
  fi

  if (( DO_START || was_running )); then step "Starting the container"; "$launcher" --docker start; fi
  write_state docker "$DOCKER_SCRIPTS_DIR"
  setup_ui docker "$DOCKER_SCRIPTS_DIR"

  cat <<EOF

${C_GRN}The Isle dedicated server is installed (Docker).${C_RST}

  Config file : $CONF   (edit, then: sudo isle-server restart)
  Manage      : sudo isle-server <start|stop|restart|status|logs -f|update|backup|rcon>
  Boot        : $boot_note; the container uses restart: unless-stopped
  Data        : Docker volume $VOLUME (kept on uninstall; removed only with --purge)
  Ports       : $(conf_get GAME_PORT)/udp+tcp (game), $(conf_get QUEUE_PORT)/tcp (queue); RCON only on 127.0.0.1:$(conf_get RCON_PORT)
${UI_LINE:+  $UI_LINE
}
  Docker publishes ports through its own iptables rules (no ufw/firewalld rules needed).
  Remember to forward the game and queue ports on your router / cloud firewall.
EOF
  if [[ -n "$MIGRATE_HINT" ]]; then printf '\n  %s\n' "$MIGRATE_HINT"; fi
  exit 0
fi

# ==================================================================== NATIVE
[[ "$MODE" == native ]] || die "Unknown mode: $MODE"

if (( DO_DEPS )); then install_deps; fi

switching=0
if docker_installed; then
  switching=1
  step "Switching from docker to native"
  docker stop -t 90 "$CONTAINER" >/dev/null 2>&1 || true
fi
# What to carry from the Docker side (PRD MIG-05; INS-19 for a retained world).
parts=""
if [[ "$DATA" != fresh ]]; then
  if (( switching || CARRY_SET )); then parts="$CARRY"; elif volume_has_world; then parts="worlds"; fi
fi
if has_part "$parts" worlds; then
  if ! volume_has_world; then parts="$(drop_part "$parts" worlds)"
  elif native_has_world && (( ! OVERWRITE )); then
    ok "Keeping the native world (the Docker world stays in volume $VOLUME; --overwrite replaces it)"
    parts="$(drop_part "$parts" worlds)"
  fi
fi
if [[ -n "$parts" ]]; then make_carry_snapshot docker "$parts"; fi
if docker_installed; then retire_docker; fi

# ------------------------------------------------------------------ user ----
step "Preparing service user '$SVC_USER'"
if id "$SVC_USER" >/dev/null 2>&1; then
  ok "User $SVC_USER already exists"
  SVC_HOME="$(getent passwd "$SVC_USER" | cut -d: -f6)"; NATIVE_SCRIPTS_DIR="$SVC_HOME/theisle-scripts"
else
  useradd --create-home --home-dir "$SVC_HOME" --shell /bin/bash --comment "The Isle dedicated server" "$SVC_USER" \
    || die "useradd failed"
  ok "Created user $SVC_USER ($SVC_HOME)"
fi
mkdir -p "$SVC_HOME"; chown "$SVC_USER:" "$SVC_HOME"

# -------------------------------------------------------- copy scripts ------
step "Installing management scripts to $NATIVE_SCRIPTS_DIR"
copy_scripts "$NATIVE_SCRIPTS_DIR"
if [[ "$DATA" == fresh ]] || { (( CARRY_SET )) && ! has_part "$CARRY" settings; }; then seed_conf "$NATIVE_SCRIPTS_DIR" --fresh
else seed_conf "$NATIVE_SCRIPTS_DIR"; fi
finish_conf native
# Pin the paths to the service user's home so every caller (root, sudo -u,
# systemd) resolves the same directories.
[[ -n "$(conf_get STEAMCMD_DIR)" ]] || conf_set STEAMCMD_DIR "$SVC_HOME/steamcmd"
[[ -n "$(conf_get SERVER_DIR)" ]]   || conf_set SERVER_DIR "$SVC_HOME/theisle-server"
[[ -n "$(conf_get BACKUP_DIR)" ]]   || conf_set BACKUP_DIR "$SVC_HOME/theisle-backups"
chown -R "$SVC_USER:" "$NATIVE_SCRIPTS_DIR"
link_launcher "$NATIVE_SCRIPTS_DIR"
native_run() { as_user env ISLE_RUNTIME=native ISLE_CONF="$CONF" "$NATIVE_SCRIPTS_DIR/linux/isle-server.sh" "$@"; }

# -------------------------------------------------------- install server ----
step "Installing SteamCMD and The Isle server (this can take a while)"
WAS_RUNNING=0
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
  warn "$SERVICE is running - stopping it for the update (it will be started again)"
  systemctl stop "$SERVICE"; WAS_RUNNING=1
elif ISLE_NO_SYSTEMD=1 native_run status >/dev/null 2>&1; then
  warn "Server is running - stopping it for the update (it will be started again)"
  ISLE_NO_SYSTEMD=1 native_run stop; WAS_RUNNING=1
fi
native_run install
if (( WAS_RUNNING )); then DO_START=1; fi
if [[ -n "$SNAP_FILE" ]]; then
  restore_snapshot native "$NATIVE_SCRIPTS_DIR" "$NATIVE_SCRIPTS_DIR/linux/isle-server.sh" "$SNAP_FILE" "$SNAP_PARTS"
  finish_carry docker "$NATIVE_SCRIPTS_DIR"
fi
if [[ -n "$FROM_SNAPSHOT" ]]; then
  fs_parts="worlds,settings,overrides,plugins"; if (( CARRY_SET )); then fs_parts="$CARRY"; fi
  restore_snapshot native "$NATIVE_SCRIPTS_DIR" "$NATIVE_SCRIPTS_DIR/linux/isle-server.sh" "$FROM_SNAPSHOT" "$fs_parts"
fi
chown -R "$SVC_USER:" "$NATIVE_SCRIPTS_DIR"

# -------------------------------------------------------------- firewall ----
if (( DO_FIREWALL )); then step "Configuring firewall"; firewall_rules add; fi

# --------------------------------------------------------------- systemd ----
if (( DO_SERVICE )); then
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    step "Installing systemd units"
    stop_timeout="$(conf_get STOP_TIMEOUT)"; stop_timeout="${stop_timeout:-60}"
    cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=The Isle (Evrima) Dedicated Server
Documentation=file://$NATIVE_SCRIPTS_DIR/README.md
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$SVC_USER
Group=$(id -gn "$SVC_USER")
WorkingDirectory=$SVC_HOME
Environment=HOME=$SVC_HOME
Environment=ISLE_CONF=$CONF
Environment=ISLE_RUNTIME=native
ExecStart=$NATIVE_SCRIPTS_DIR/linux/isle-server.sh run
ExecStop=$NATIVE_SCRIPTS_DIR/linux/isle-server.sh save
KillSignal=SIGTERM
TimeoutStartSec=1800
TimeoutStopSec=$((stop_timeout + 30))
Restart=on-failure
RestartSec=15
LimitNOFILE=100000
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    cat > "/etc/systemd/system/$SERVICE-backup.service" <<EOF
[Unit]
Description=Backup The Isle server save data

[Service]
Type=oneshot
User=$SVC_USER
Environment=HOME=$SVC_HOME
Environment=ISLE_CONF=$CONF
Environment=ISLE_RUNTIME=native
Environment=ISLE_NO_SYSTEMD=1
ExecStart=$NATIVE_SCRIPTS_DIR/linux/isle-server.sh backup
EOF
    cat > "/etc/systemd/system/$SERVICE-backup.timer" <<EOF
[Unit]
Description=Daily backup of The Isle server

[Timer]
OnCalendar=*-*-* 05:00:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE.service" >/dev/null 2>&1
    systemctl enable --now "$SERVICE-backup.timer" >/dev/null 2>&1
    ok "Enabled $SERVICE.service (starts on boot) and $SERVICE-backup.timer (daily 05:00)"

    if (( DO_SUDOERS )) && [[ -d /etc/sudoers.d ]]; then
      sc="$(command -v systemctl)"
      cat > "/etc/sudoers.d/$SERVICE" <<EOF
# Allow $SVC_USER to control its own game server service
$SVC_USER ALL=(root) NOPASSWD: $sc start $SERVICE, $sc stop $SERVICE, $sc restart $SERVICE, $sc status $SERVICE
EOF
      chmod 440 "/etc/sudoers.d/$SERVICE"
      if command -v visudo >/dev/null 2>&1 && ! visudo -cf "/etc/sudoers.d/$SERVICE" >/dev/null; then
        rm -f "/etc/sudoers.d/$SERVICE"; warn "sudoers rule invalid - removed"
      fi
    fi
  else
    warn "systemd not detected - skipping service. Use 'isle-server.sh start' (background watchdog) instead."
    DO_SERVICE=0
  fi
fi

if (( DO_START )); then
  step "Starting server"
  if (( DO_SERVICE )); then systemctl start "$SERVICE"; else native_run start; fi
fi
write_state native "$NATIVE_SCRIPTS_DIR"
setup_ui native "$NATIVE_SCRIPTS_DIR"

# --------------------------------------------------------------- summary ----
cat <<EOF

${C_GRN}The Isle dedicated server is installed (native).${C_RST}

  Config file : $CONF   (edit, then restart)
  Server files: $(native_run info | sed -n 's/^Server dir *: //p')
  Manage      : sudo -u $SVC_USER isle-server <start|stop|restart|status|logs -f|update|backup|rcon>
EOF
if (( DO_SERVICE )); then
  cat <<EOF
  systemd     : systemctl start|stop|status $SERVICE ; journalctl -u $SERVICE -f
EOF
fi
cat <<EOF
  Ports       : $(conf_get GAME_PORT)/udp+tcp (game), $(conf_get QUEUE_PORT)/tcp (queue), $(conf_get RCON_PORT)/tcp (RCON, keep private)
${UI_LINE:+  $UI_LINE
}
  Remember to forward the game and queue ports on your router / cloud firewall.
EOF
if [[ -n "$MIGRATE_HINT" ]]; then printf '\n  %s\n' "$MIGRATE_HINT"; fi
