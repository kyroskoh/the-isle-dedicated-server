#!/usr/bin/env bash
# =============================================================================
#  tests/installer-cycle.sh - end-to-end test of linux/install.sh (PRD INS-13..18)
#
#  purge -> native install -> uninstall -> reinstall -> switch to docker ->
#  uninstall -> reinstall -> switch back to native -> purge -> fresh reinstall
#
#  Uses a fake SteamCMD and a fake server binary, so nothing is downloaded from
#  Steam. DESTRUCTIVE for this machine's The Isle install: it purges the
#  'theisle' user, /opt/theisle-scripts and the theisle-data Docker volume.
#  Run only on a disposable machine / CI runner:
#
#    sudo ISLE_TEST_I_UNDERSTAND=1 bash tests/installer-cycle.sh
#
#  Env: TEST_PREBUILT_IMAGE=<tag>  use an existing image instead of building
#       (it is re-tagged as theisle-server:latest before the docker steps)
# =============================================================================
set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root"; exit 2; }
[[ "${ISLE_TEST_I_UNDERSTAND:-}" == 1 ]] || { echo "refusing: set ISLE_TEST_I_UNDERSTAND=1 (this purges the local install)"; exit 2; }

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
LOGS="$(mktemp -d)"
cd "$REPO" || exit 2
unset ISLE_CONF ISLE_ALLOW_ROOT ISLE_RUNTIME
I="$REPO/linux/install.sh"
NC=/home/theisle/theisle-scripts/config/server.conf
DC=/opt/theisle-scripts/config/server.conf
fails=0

ck()    { if eval "$2"; then echo "  PASS $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }
state() { grep -E "^$1=" /etc/theisle-server/install.state 2>/dev/null | cut -d= -f2; }
nstat() { sudo -u theisle isle-server status >/dev/null 2>&1; }
dstat() { isle-server status >/dev/null 2>&1; }
run()   { local n="$1"; shift; bash "$I" "$@" </dev/null > "$LOGS/$n.log" 2>&1; local rc=$?; [[ $rc -eq 0 ]] || { echo "  install.sh $* exited $rc:"; tail -15 "$LOGS/$n.log"; }; return $rc; }
waitfor() { local i; for i in $(seq 1 30); do eval "$1" && return 0; sleep 2; done; return 1; }

prep_native() {  # fake SteamCMD that "installs" a fake server
  mkdir -p /home/theisle/steamcmd/linux64
  cat > /home/theisle/steamcmd/steamcmd.sh <<'EOF'
#!/bin/bash
dir=""; while [ $# -gt 0 ]; do [ "$1" = "+force_install_dir" ] && dir="$2"; shift; done
mkdir -p "$dir/TheIsle/Binaries/Linux"
printf '%s\n' '#!/bin/bash' 'echo "FAKE SERVER $*"' 'trap "exit 0" TERM' 'while :; do sleep 1; done' \
  > "$dir/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"
chmod +x "$dir/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"
EOF
  chmod 755 /home/theisle/steamcmd/steamcmd.sh
  touch /home/theisle/steamcmd/linux64/steamclient.so
}
use_prebuilt() {
  if [[ -n "${TEST_PREBUILT_IMAGE:-}" ]]; then docker tag "$TEST_PREBUILT_IMAGE" theisle-server:latest; fi
}
seed_volume() {  # the real image would download the game; seed a fake server instead
  docker run --rm -v theisle-data:/data --entrypoint bash theisle-server:latest -c '
    mkdir -p /data/server/TheIsle/Binaries/Linux
    printf "%s\n" "#!/bin/bash" "trap \"exit 0\" TERM" "while :; do sleep 1; done" > /data/server/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping
    chmod +x /data/server/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping'
}

echo "## 0 purge (start clean)"; run 0 --uninstall --purge --yes
ck "user removed"              "! id theisle >/dev/null 2>&1"
ck "state removed"             "[ ! -e /etc/theisle-server/install.state ]"
ck "volumes removed"           "! docker volume ls -q | grep -q theisle-data"
ck "/opt copy removed"         "[ ! -e /opt/theisle-scripts ]"

echo "## 1 native install"; prep_native; run 1 --native --no-deps --start
ck "installed"                 "grep -q 'installed (native)' $LOGS/1.log"
ck "state native/installed"    "[ \"\$(state MODE)\" = native ] && [ \"\$(state STATUS)\" = installed ]"
ck "RUNTIME=native"            "grep -q '^RUNTIME=native' $NC"
ck "paths pinned"              "grep -q '^SERVER_DIR=/home/theisle/theisle-server' $NC"
ck "server running"            "waitfor nstat"
ck "root status agrees"        "isle-server status >/dev/null 2>&1"
PW="$(grep '^RCON_PASSWORD=' "$NC" | cut -d= -f2)"
sed -i 's/^UPDATE_ON_START=true/UPDATE_ON_START=false/' "$NC"
if [[ -n "${TEST_PREBUILT_IMAGE:-}" ]]; then sed -i 's/^DOCKER_BUILD=true/DOCKER_BUILD=false/' "$NC"; fi

echo "## 2 uninstall"; run 2 --uninstall
ck "stopped"                   "! nstat"
ck "state uninstalled, mode kept" "[ \"\$(state STATUS)\" = uninstalled ] && [ \"\$(state MODE)\" = native ]"
ck "data kept"                 "[ -x /home/theisle/theisle-server/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping ]"

echo "## 3 reinstall (no flag -> previous mode)"; run 3 --no-deps --start
ck "mode native"               "grep -q 'Install mode: native' $LOGS/3.log"
ck "settings kept"             "[ \"\$(grep '^RCON_PASSWORD=' $NC | cut -d= -f2)\" = \"$PW\" ]"
ck "running"                   "waitfor nstat"

echo "## 4 switch to docker"; use_prebuilt; run 4 --docker
seed_volume; isle-server start >/dev/null 2>&1
ck "switched"                  "grep -q 'Switching from native to docker' $LOGS/4.log"
ck "native stopped"            "! pgrep -u theisle -f TheIsleServer-Linux-Shipping >/dev/null"
ck "native backup offered"     "grep -q 'native world was backed up' $LOGS/4.log"
ck "settings carried over"     "[ \"\$(grep '^RCON_PASSWORD=' $DC | cut -d= -f2)\" = \"$PW\" ]"
ck "RUNTIME=docker"            "grep -q '^RUNTIME=docker' $DC"
ck "state docker"              "[ \"\$(state MODE)\" = docker ]"
ck "container running"         "waitfor dstat"
ck "native world restorable"   "isle-server stop >/dev/null 2>&1 && isle-server restore \"\$(ls -t /home/theisle/theisle-backups/*.tar.gz | head -1)\" >/dev/null 2>&1 && isle-server start >/dev/null 2>&1"

echo "## 5 uninstall docker, reinstall (no flag -> docker)"; run 5 --uninstall
ck "container removed"         "[ -z \"\$(docker ps -aq --filter name=^theisle\$)\" ]"
ck "volume kept"               "docker volume inspect theisle-data >/dev/null 2>&1"
ck "state docker/uninstalled"  "[ \"\$(state MODE)\" = docker ] && [ \"\$(state STATUS)\" = uninstalled ]"
run 5b --start
ck "reinstalled as docker"     "grep -q 'Install mode: docker' $LOGS/5b.log"
ck "running again"             "waitfor dstat"

echo "## 6 switch back to native"; run 6 --native --no-deps --start
ck "switched"                  "grep -q 'Switching from docker to native' $LOGS/6.log"
ck "container removed"         "[ -z \"\$(docker ps -aq --filter name=^theisle\$)\" ]"
ck "docker world copied out"   "grep -q 'Docker world was backed up' $LOGS/6.log && ls /home/theisle/theisle-backups/*.tar.gz >/dev/null"
ck "native running"            "waitfor nstat"
ck "RUNTIME=native"            "grep -q '^RUNTIME=native' $NC"

echo "## 7 purge, then fresh reinstall"; run 7 --uninstall --purge --yes
ck "user removed"              "! id theisle >/dev/null 2>&1"
ck "state removed"             "[ ! -e /etc/theisle-server/install.state ]"
prep_native; run 7b --native --no-deps --start
ck "fresh install"             "grep -q 'installed (native)' $LOGS/7b.log"
ck "new RCON password"         "[ \"\$(grep '^RCON_PASSWORD=' $NC | cut -d= -f2)\" != \"$PW\" ]"
ck "running"                   "waitfor nstat"

echo "## 8 purge without --yes is refused when non-interactive"; run 8 --uninstall --purge
ck "refused, nothing removed"  "grep -q 'without confirmation' $LOGS/8.log && id theisle >/dev/null 2>&1"

echo "## cleanup"; run 9 --uninstall --purge --yes >/dev/null 2>&1
echo "logs: $LOGS"
echo "RESULT: $fails failure(s)"
exit $(( fails > 0 ))
