#!/usr/bin/env bash
# =============================================================================
#  install.sh - one-shot installer for The Isle (Evrima) dedicated server
#
#  Run as root (or with sudo) on any mainstream 64-bit Linux distribution:
#    Debian / Ubuntu / Mint / Pop!_OS        (apt)
#    Fedora / RHEL / Rocky / Alma / CentOS   (dnf / yum)
#    Arch / Manjaro / EndeavourOS            (pacman, needs [multilib])
#    openSUSE Leap / Tumbleweed / SLES       (zypper)
#    Others                                  (install deps manually, see INSTALL.md)
#
#  What it does:
#    1. Installs dependencies (curl, tar, python3, 32-bit libs for SteamCMD)
#    2. Creates an unprivileged service user (default: theisle)
#    3. Copies these scripts to the user's home and creates config/server.conf
#    4. Installs SteamCMD + the server (app 412680, branch evrima)
#    5. Opens firewall ports (ufw / firewalld) when a firewall is active
#    6. Installs + enables a systemd service and a daily backup timer
#
#  Options:
#    --user NAME        service user                     (default: theisle)
#    --home DIR         home directory of that user      (default: /home/NAME)
#    --branch NAME      Steam beta branch                (default: evrima)
#    --no-service       do not install the systemd units
#    --no-firewall      do not touch the firewall
#    --no-deps          skip package installation
#    --no-sudoers       do not let the user control its own service via sudo
#    --start            start the server when finished
#    --uninstall        remove service/timer/sudoers/firewall rules (keeps files)
#    -h | --help        show this help
# =============================================================================
set -Eeuo pipefail

SRC_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
SVC_USER="theisle"
SVC_HOME=""
BRANCH=""; BRANCH_SET=0
DO_SERVICE=1; DO_FIREWALL=1; DO_DEPS=1; DO_SUDOERS=1; DO_START=0; DO_UNINSTALL=0
SERVICE="theisle-server"

if [[ -t 1 ]]; then C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[36m'; C_RST=$'\e[0m'
else C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_RST=""; fi
step() { printf '\n%s==>%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
usage() { sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '/^=====/d'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)        SVC_USER="${2:?}"; shift 2 ;;
    --home)        SVC_HOME="${2:?}"; shift 2 ;;
    --branch)      BRANCH="${2-}"; BRANCH_SET=1; shift 2 ;;
    --no-service)  DO_SERVICE=0; shift ;;
    --no-firewall) DO_FIREWALL=0; shift ;;
    --no-deps)     DO_DEPS=0; shift ;;
    --no-sudoers)  DO_SUDOERS=0; shift ;;
    --start)       DO_START=1; shift ;;
    --uninstall)   DO_UNINSTALL=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage; die "Unknown option: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Please run as root, e.g.: sudo $0 $*"
[[ "$(uname -m)" == "x86_64" ]] || die "The Isle dedicated server requires x86_64 (detected $(uname -m))"
[[ "$SVC_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid user name: $SVC_USER"
[[ -n "$SVC_HOME" ]] || SVC_HOME="/home/$SVC_USER"
SCRIPTS_DIR="$SVC_HOME/theisle-scripts"

as_user() {  # run a command as the service user with a login-like env
  cd "$SVC_HOME" 2>/dev/null || cd /
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$SVC_USER" -- env HOME="$SVC_HOME" USER="$SVC_USER" "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -u "$SVC_USER" -H "$@"
  else
    su -s /bin/bash "$SVC_USER" -c "$(printf '%q ' "$@")"
  fi
}

conf_get() { grep -E "^$1=" "$SCRIPTS_DIR/config/server.conf" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"\r' || true; }
conf_set() {
  local key="$1" val="$2" file="$SCRIPTS_DIR/config/server.conf"
  if grep -qE "^$key=" "$file"; then
    local esc; esc="$(printf '%s' "$val" | sed -e 's/[\\/&|]/\\&/g')"
    sed -i "s|^$key=.*|$key=$esc|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

# ------------------------------------------------------------- uninstall ----
firewall_rules() {  # $1 = add | remove
  local action="$1" gp qp rp open_rcon
  gp="$(conf_get GAME_PORT)"; gp="${gp:-7777}"
  qp="$(conf_get QUEUE_PORT)"; qp="${qp:-10000}"
  rp="$(conf_get RCON_PORT)"; rp="${rp:-8888}"
  open_rcon="$(conf_get FIREWALL_OPEN_RCON)"
  local -a rules=("$gp/udp" "$gp/tcp" "$qp/tcp")
  [[ "${open_rcon,,}" == "true" ]] && rules+=("$rp/tcp")

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    local r
    for r in "${rules[@]}"; do
      if [[ "$action" == add ]]; then ufw allow "$r" comment 'The Isle server' >/dev/null
      else ufw delete allow "$r" >/dev/null 2>&1 || true; fi
    done
    ok "ufw: ${action} ${rules[*]}"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    local r flag; [[ "$action" == add ]] && flag="--add-port" || flag="--remove-port"
    for r in "${rules[@]}"; do firewall-cmd --permanent "$flag=$r" >/dev/null 2>&1 || true; done
    firewall-cmd --reload >/dev/null
    ok "firewalld: ${action} ${rules[*]}"
  else
    [[ "$action" == add ]] && warn "No active ufw/firewalld found. If you use iptables/nftables or a cloud firewall, open: ${rules[*]}"
  fi
}

if (( DO_UNINSTALL )); then
  step "Removing systemd units, sudoers rule and firewall rules"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$SERVICE.service" "$SERVICE-backup.timer" 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE.service" "/etc/systemd/system/$SERVICE-backup.service" "/etc/systemd/system/$SERVICE-backup.timer"
    systemctl daemon-reload || true
  fi
  rm -f "/etc/sudoers.d/$SERVICE"
  firewall_rules remove
  ok "Uninstalled. Server files in $SVC_HOME and the user '$SVC_USER' were kept."
  echo "To remove everything: userdel -r $SVC_USER"
  exit 0
fi

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
    die "Alpine (musl) is not supported: SteamCMD and the server need glibc. Use a glibc distro or a container image such as debian:stable."
  else
    warn "Unknown package manager. Make sure these are installed: curl tar python3 and 32-bit glibc + libgcc + libstdc++."
  fi
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "curl or wget is required"
  command -v tar  >/dev/null 2>&1 || die "tar is required"
}

(( DO_DEPS )) && install_deps

# ------------------------------------------------------------------ user ----
step "Preparing service user '$SVC_USER'"
if id "$SVC_USER" >/dev/null 2>&1; then
  ok "User $SVC_USER already exists"
  SVC_HOME="$(getent passwd "$SVC_USER" | cut -d: -f6)"; SCRIPTS_DIR="$SVC_HOME/theisle-scripts"
else
  useradd --create-home --home-dir "$SVC_HOME" --shell /bin/bash --comment "The Isle dedicated server" "$SVC_USER" \
    || die "useradd failed"
  ok "Created user $SVC_USER ($SVC_HOME)"
fi
mkdir -p "$SVC_HOME"; chown "$SVC_USER:" "$SVC_HOME"

# -------------------------------------------------------- copy scripts ------
step "Installing management scripts to $SCRIPTS_DIR"
if [[ "$(readlink -f "$SRC_DIR")" != "$(readlink -f "$SCRIPTS_DIR" 2>/dev/null || echo /nonexistent)" ]]; then
  mkdir -p "$SCRIPTS_DIR"
  # copy everything except git metadata and an existing server.conf
  (cd "$SRC_DIR" && tar --exclude='.git' --exclude='config/server.conf' -cf - .) | (cd "$SCRIPTS_DIR" && tar -xf -)
fi
if [[ ! -f "$SCRIPTS_DIR/config/server.conf" ]]; then
  if [[ -f "$SRC_DIR/config/server.conf" ]]; then cp "$SRC_DIR/config/server.conf" "$SCRIPTS_DIR/config/server.conf"
  else cp "$SCRIPTS_DIR/config/server.conf.example" "$SCRIPTS_DIR/config/server.conf"; fi
  ok "Created config/server.conf"
fi
sed -i 's/\r$//' "$SCRIPTS_DIR"/linux/*.sh "$SCRIPTS_DIR/config/server.conf"
chmod 755 "$SCRIPTS_DIR"/linux/*.sh "$SCRIPTS_DIR"/tools/*.py
chmod 600 "$SCRIPTS_DIR/config/server.conf"
if (( BRANCH_SET )); then conf_set STEAM_BRANCH "$BRANCH"; fi
if [[ -z "$(conf_get RCON_PASSWORD)" ]]; then
  pw="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)"
  conf_set RCON_PASSWORD "$pw"
  ok "Generated a random RCON password (see config/server.conf)"
fi
chown -R "$SVC_USER:" "$SCRIPTS_DIR"
ln -sf "$SCRIPTS_DIR/linux/isle-server.sh" /usr/local/bin/isle-server 2>/dev/null || true

# -------------------------------------------------------- install server ----
step "Installing SteamCMD and The Isle server (this can take a while)"
WAS_RUNNING=0
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
  warn "$SERVICE is running - stopping it for the update (it will be started again)"
  systemctl stop "$SERVICE"; WAS_RUNNING=1
elif as_user env ISLE_NO_SYSTEMD=1 "$SCRIPTS_DIR/linux/isle-server.sh" status >/dev/null 2>&1; then
  warn "Server is running - stopping it for the update (it will be started again)"
  as_user env ISLE_NO_SYSTEMD=1 "$SCRIPTS_DIR/linux/isle-server.sh" stop; WAS_RUNNING=1
fi
as_user "$SCRIPTS_DIR/linux/isle-server.sh" install
(( WAS_RUNNING )) && DO_START=1

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
Documentation=file://$SCRIPTS_DIR/README.md
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$SVC_USER
Group=$(id -gn "$SVC_USER")
WorkingDirectory=$SVC_HOME
Environment=HOME=$SVC_HOME
Environment=ISLE_CONF=$SCRIPTS_DIR/config/server.conf
ExecStart=$SCRIPTS_DIR/linux/isle-server.sh run
ExecStop=$SCRIPTS_DIR/linux/isle-server.sh save
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
Environment=ISLE_CONF=$SCRIPTS_DIR/config/server.conf
Environment=ISLE_NO_SYSTEMD=1
ExecStart=$SCRIPTS_DIR/linux/isle-server.sh backup
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
  if (( DO_SERVICE )); then systemctl start "$SERVICE"; else as_user "$SCRIPTS_DIR/linux/isle-server.sh" start; fi
fi

# --------------------------------------------------------------- summary ----
cat <<EOF

${C_GRN}The Isle dedicated server is installed.${C_RST}

  Config file : $SCRIPTS_DIR/config/server.conf   (edit, then restart)
  Server files: $(as_user "$SCRIPTS_DIR/linux/isle-server.sh" info | sed -n 's/^Server dir *: //p')
  Manage      : sudo -u $SVC_USER isle-server <start|stop|restart|status|logs -f|update|backup|rcon>
EOF
if (( DO_SERVICE )); then
  cat <<EOF
  systemd     : systemctl start|stop|status $SERVICE ; journalctl -u $SERVICE -f
EOF
fi
cat <<EOF
  Ports       : $(conf_get GAME_PORT)/udp+tcp (game), $(conf_get QUEUE_PORT)/tcp (queue), $(conf_get RCON_PORT)/tcp (RCON, keep private)

  Remember to forward the game and queue ports on your router / cloud firewall.
EOF
