#!/usr/bin/env bash
# =============================================================================
#  tests/test_native_debian.sh - native install on Debian (PRD DEB-01)
#
#  Runs linux/install.sh --native on a Debian system (CI: a debian:bookworm
#  container), including the real apt dependencies (32-bit libs, python3).
#  Containers have no systemd, so the launcher's background watchdog is used.
#  A fake SteamCMD stands in for Valve's download.
#
#  DESTRUCTIVE for this machine's install (user 'theisle'). Run as root:
#    ISLE_TEST_I_UNDERSTAND=1 bash tests/test_native_debian.sh
#  TEST_NO_DEPS=1 skips apt (for sandboxes without Debian mirrors).
# =============================================================================
# shellcheck disable=SC2317,SC2329,SC2016
set -u
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 2; }
[[ "${ISLE_TEST_I_UNDERSTAND:-}" == 1 ]] || { echo "refusing: set ISLE_TEST_I_UNDERSTAND=1"; exit 2; }
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
I="$REPO/linux/install.sh"
LOGS="$(mktemp -d)"
NC=/home/theisle/theisle-scripts/config/server.conf
NSAVED=/home/theisle/theisle-server/TheIsle/Saved
DEPS=(); if [[ -n "${TEST_NO_DEPS:-}" ]]; then DEPS=(--no-deps); fi
fails=0
ck() { if eval "$2"; then echo "  PASS $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }
waitfor() { local _; for _ in $(seq 1 30); do eval "$1" && return 0; sleep 1; done; return 1; }
as_theisle() { runuser -u theisle -- env HOME=/home/theisle "$@"; }
lc() { as_theisle /usr/local/bin/isle-server "$@"; }
running() { lc status >/dev/null 2>&1; }
run() { local n="$1"; shift; bash "$I" "$@" </dev/null > "$LOGS/$n.log" 2>&1; local rc=$?; [[ $rc -eq 0 ]] || { echo "  install.sh $* exited $rc"; tail -20 "$LOGS/$n.log"; }; return $rc; }
prep_native() {
  mkdir -p /home/theisle/steamcmd/linux64
  cat > /home/theisle/steamcmd/steamcmd.sh <<'EOF'
#!/bin/bash
dir=""; while [ $# -gt 0 ]; do [ "$1" = "+force_install_dir" ] && dir="$2"; shift; done
mkdir -p "$dir/TheIsle/Binaries/Linux"
printf '%s\n' '#!/bin/bash' 'trap "exit 0" TERM' 'while :; do sleep 1; done' > "$dir/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"
chmod +x "$dir/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping"
EOF
  chmod 755 /home/theisle/steamcmd/steamcmd.sh
  touch /home/theisle/steamcmd/linux64/steamclient.so
}
# shellcheck source=/dev/null
. /etc/os-release
echo "## platform: ${PRETTY_NAME:-unknown}"
ck "running on Debian"            "[ \"\${ID:-}\" = debian ]"

echo "## native install (apt dependencies unless TEST_NO_DEPS)"
prep_native
run 1 --native "${DEPS[@]}" --start --ui
ck "installed"                    "grep -q 'installed (native)' $LOGS/1.log"
if [[ -z "${TEST_NO_DEPS:-}" ]]; then
  ck "32-bit libs from apt"       "dpkg -s lib32gcc-s1 lib32stdc++6 >/dev/null 2>&1"
  ck "i386 architecture enabled"  "dpkg --print-foreign-architectures | grep -qx i386"
fi
ck "python3 available"            "command -v python3 >/dev/null"
ck "service user"                 "id theisle >/dev/null"
ck "server running (watchdog)"    "waitfor running"
ck "config owned by theisle, 600" "[ \"\$(stat -c '%U %a' $NC)\" = 'theisle 600' ]"

echo "## web UI + API as the service user (PRD UI-04)"
TOK=/home/theisle/theisle-scripts/config/ui-token
ck "ui token: theisle, 600"       "[ \"\$(stat -c '%U %a' $TOK 2>/dev/null)\" = 'theisle 600' ]"
ck "ui-token prints it"           "[ \"\$(lc ui-token 2>/dev/null)\" = \"\$(cat $TOK)\" ]"
as_theisle /usr/local/bin/isle-server ui --port 8199 > "$LOGS/ui.log" 2>&1 &
UI_PID=$!
get() { python3 - "$@" <<'PY'
import json, sys, urllib.request
req = urllib.request.Request("http://127.0.0.1:8199" + sys.argv[1])
if len(sys.argv) > 2: req.add_header("Authorization", "Bearer " + sys.argv[2])
try: r = urllib.request.urlopen(req, timeout=10); print(r.status, r.read().decode())
except urllib.error.HTTPError as e: print(e.code)
except OSError: print(0)
PY
}
ck "ui answers /health"           "waitfor \"get /api/v1/health | grep -q '^200 '\""
ck "ui wants the token"           "get /api/v1/status | grep -qx 401"
ck "ui status: running"           "get /api/v1/status \"\$(cat $TOK)\" | grep -q '\"running\": true'"
ck "ui sees the config"           "get /api/v1/config \"\$(cat $TOK)\" | grep -q '\"key\": \"SERVER_NAME\"'"
ck "ui serves /docs"              "get /docs | grep -q '^200 '"
kill "$UI_PID" 2>/dev/null; wait "$UI_PID" 2>/dev/null

echo "## launcher features on Debian (mawk, dash, coreutils)"
ck "admins"                       "lc admins add 76561198000000001 >/dev/null 2>&1 && grep -q '^ADMIN_STEAM_IDS=76561198000000001' $NC"
ck "roster preset"                "lc classes preset carnivores >/dev/null 2>&1 && grep -q '^ALLOWED_CLASSES=.*Tyrannosaurus' $NC"
ck "profile"                      "lc profile apply casual >/dev/null 2>&1 && grep -q '^GROWTH_MULTIPLIER=3' $NC"
mkdir -p /home/theisle/theisle-scripts/config/overrides
printf '[/Script/TheIsle.TIGameSession]\nbDebianOverride=true\n' > /home/theisle/theisle-scripts/config/overrides/Game.ini
chown -R theisle: /home/theisle/theisle-scripts/config/overrides
ck "configure + override merge"   "lc configure >/dev/null 2>&1 && grep -q '^bDebianOverride=true' $NSAVED/Config/LinuxServer/Game.ini && grep -c '^AllowedClasses=' $NSAVED/Config/LinuxServer/Game.ini | grep -qv '^0\$'"
ck "plugins + hook on backup"     "lc plugins install offsite-backup >/dev/null 2>&1 && lc plugins config offsite-backup DEST_DIR=/home/theisle/nas >/dev/null 2>&1 && lc backup >/dev/null 2>&1 && ls /home/theisle/nas/theisle-*.tar.gz >/dev/null 2>&1"
mkdir -p "$NSAVED/SaveGames" && echo debian-world > "$NSAVED/SaveGames/w.txt" && chown -R theisle: "$NSAVED/SaveGames"
ck "snapshot create"              "lc snapshot create --include all --output /home/theisle/snap.tar.gz >/dev/null 2>&1 && cp /home/theisle/snap.tar.gz /root/snap.tar.gz"

echo "## uninstall (keep), reinstall, purge, reinstall from the snapshot"
run 2 --uninstall
ck "stopped after uninstall"      "! running"
run 3 --native --no-deps --start
ck "reinstall keeps the world"    "[ -f $NSAVED/SaveGames/w.txt ] && waitfor running"
run 4 --uninstall --purge --yes
ck "purged"                       "! id theisle >/dev/null 2>&1"
mkdir -p /home/theisle && prep_native
run 5 --native --no-deps --from-snapshot /root/snap.tar.gz --start
ck "world restored from snapshot" "[ \"\$(cat $NSAVED/SaveGames/w.txt 2>/dev/null)\" = debian-world ]"
ck "settings restored"            "grep -q '^GROWTH_MULTIPLIER=3' $NC && grep -q '^ADMIN_STEAM_IDS=76561198000000001' $NC"
ck "running again"                "waitfor running"
run 6 --uninstall --purge --yes
rm -f /root/snap.tar.gz
echo "logs: $LOGS"
echo "RESULT: $fails failure(s)"
exit $(( fails > 0 ))
