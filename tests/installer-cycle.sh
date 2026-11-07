#!/usr/bin/env bash
# Most helpers are only called through eval in ck()/waitfor():
# shellcheck disable=SC2317,SC2329
# =============================================================================
#  tests/installer-cycle.sh - end-to-end test of linux/install.sh (PRD INS-13..18)
#
#  purge -> native install -> uninstall -> reinstall -> switch to docker (native
#  world imported) -> uninstall -> reinstall (retained volume reused) -> switch
#  to native (Docker world imported) -> uninstall -> reinstall native from the
#  retained volume -> purge -> fresh reinstall (nothing imported)
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
waitfor() { local _; for _ in $(seq 1 30); do eval "$1" && return 0; sleep 2; done; return 1; }

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

NSAVED=/home/theisle/theisle-server/TheIsle/Saved
vol_has() { docker run --rm -v theisle-data:/data:ro --entrypoint sh theisle-server:latest -c "[ -f /data/server/TheIsle/Saved/SaveGames/$1 ]"; }
vol_put() { docker run --rm -v theisle-data:/data --entrypoint sh theisle-server:latest -c "mkdir -p /data/server/TheIsle/Saved/SaveGames && echo $1 > /data/server/TheIsle/Saved/SaveGames/$1"; }
nat_put() { sudo -u theisle mkdir -p "$NSAVED/SaveGames" && echo "$1" | sudo -u theisle tee "$NSAVED/SaveGames/$1" >/dev/null; }

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

echo "## 4 switch to docker: retained native world is imported"; nat_put native-world.txt
use_prebuilt; run 4 --docker
seed_volume; isle-server start >/dev/null 2>&1
ck "switched"                  "grep -q 'Switching from native to docker' $LOGS/4.log"
ck "native stopped"            "! pgrep -u theisle -f TheIsleServer-Linux-Shipping >/dev/null"
ck "settings carried over"     "[ \"\$(grep '^RCON_PASSWORD=' $DC | cut -d= -f2)\" = \"$PW\" ]"
ck "RUNTIME=docker"            "grep -q '^RUNTIME=docker' $DC"
ck "state docker"              "[ \"\$(state MODE)\" = docker ]"
ck "native world imported"     "grep -q 'Imported' $LOGS/4.log && vol_has native-world.txt"
ck "container running"         "waitfor dstat"

echo "## 5 uninstall docker, reinstall (no flag): retained volume reused"; run 5 --uninstall
ck "container removed"         "[ -z \"\$(docker ps -aq --filter name=^theisle\$)\" ]"
ck "volume kept"               "docker volume inspect theisle-data >/dev/null 2>&1"
ck "state docker/uninstalled"  "[ \"\$(state MODE)\" = docker ] && [ \"\$(state STATUS)\" = uninstalled ]"
run 5b --start
ck "reinstalled as docker"     "grep -q 'Install mode: docker' $LOGS/5b.log"
ck "retained volume reused"    "grep -q 'Reusing the world kept in Docker volume' $LOGS/5b.log && vol_has native-world.txt"
ck "running again"             "waitfor dstat"
isle-server stop >/dev/null 2>&1; vol_put docker-world.txt; isle-server start >/dev/null 2>&1

echo "## 6 switch to native (container present): Docker world imported"
rm -rf -- "${NSAVED:?}"
run 6 --native --no-deps --start
ck "switched"                  "grep -q 'Switching from docker to native' $LOGS/6.log"
ck "container removed"         "[ -z \"\$(docker ps -aq --filter name=^theisle\$)\" ]"
ck "docker world imported"     "grep -q 'Imported' $LOGS/6.log && [ -f $NSAVED/SaveGames/docker-world.txt ]"
ck "native running"            "waitfor nstat"
ck "RUNTIME=native"            "grep -q '^RUNTIME=native' $NC"

echo "## 7 uninstall native, reinstall native from the retained volume (no container)"; run 7 --uninstall
rm -rf -- "${NSAVED:?}"
run 7b --no-deps --start
ck "imported from retained volume" "grep -q 'Exporting the world kept in Docker volume' $LOGS/7b.log && [ -f $NSAVED/SaveGames/docker-world.txt ]"
ck "running"                   "waitfor nstat"
run 7c --no-deps
ck "existing world not overwritten" "grep -q 'native world was left as is' $LOGS/7c.log"
run 7d --no-deps --no-import
ck "--no-import respected"     "! grep -q 'Exporting the world' $LOGS/7d.log"

echo "## 8 purge, then fresh reinstall (nothing to import)"; run 8 --uninstall --purge --yes
ck "user removed"              "! id theisle >/dev/null 2>&1"
ck "state removed"             "[ ! -e /etc/theisle-server/install.state ]"
ck "volume removed"            "! docker volume inspect theisle-data >/dev/null 2>&1"
prep_native; run 8b --native --no-deps --start
ck "fresh install"             "grep -q 'installed (native)' $LOGS/8b.log"
ck "nothing imported"          "! grep -q 'Import' $LOGS/8b.log && [ ! -e $NSAVED/SaveGames ]"
ck "new RCON password"         "[ \"\$(grep '^RCON_PASSWORD=' $NC | cut -d= -f2)\" != \"$PW\" ]"
ck "running"                   "waitfor nstat"

echo "## 9 purge without --yes is refused when non-interactive"; run 9 --uninstall --purge
ck "refused, nothing removed"  "grep -q 'without confirmation' $LOGS/9.log && id theisle >/dev/null 2>&1"

echo "## cleanup"; run 10 --uninstall --purge --yes >/dev/null 2>&1
echo "logs: $LOGS"
echo "RESULT: $fails failure(s)"
exit $(( fails > 0 ))
