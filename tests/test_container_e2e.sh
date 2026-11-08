#!/usr/bin/env bash
# =============================================================================
#  tests/test_container_e2e.sh - end-to-end Docker test through the launcher
#
#  Uses tests/fixtures/fake-isle-server.py as the "game": it speaks the Evrima
#  RCON protocol and logs every command, so the test can check what really
#  reaches the server: live whitelist/roster pushes, RCON, plugins talking to
#  the container from the host, restart-countdown, save-before-stop, overrides.
#
#  It uses the fixed names 'theisle' (container) and 'theisle-data' (volume),
#  so it REMOVES an existing local Docker install of the server:
#
#    ISLE_TEST_I_UNDERSTAND=1 IMAGE=theisle-server:ci bash tests/test_container_e2e.sh
#
#  IMAGE must already exist (CI builds it from docker/Dockerfile).
# =============================================================================
# shellcheck disable=SC2317,SC2329
set -u

[[ "${ISLE_TEST_I_UNDERSTAND:-}" == 1 ]] || { echo "refusing: set ISLE_TEST_I_UNDERSTAND=1 (removes the local 'theisle' container and 'theisle-data' volume)"; exit 2; }
IMAGE="${IMAGE:-theisle-server:ci}"
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "image $IMAGE not found"; exit 2; }

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
T="$(mktemp -d)"
L="$REPO/linux/isle-server.sh"
export ISLE_CONF="$T/server.conf"
unset ISLE_RUNTIME
GPORT=17777 QPORT=20000 RPORT=18888
sed -e 's/^RUNTIME=native/RUNTIME=docker/' -e 's/^DOCKER_BUILD=true/DOCKER_BUILD=false/' \
    -e "s|^DOCKER_IMAGE=.*|DOCKER_IMAGE=$IMAGE|" -e 's/^UPDATE_ON_START=true/UPDATE_ON_START=false/' \
    -e '/^SERVER_NAME=/d' -e '/^SERVER_PASSWORD=/d' -e "s/^GAME_PORT=.*/GAME_PORT=$GPORT/" \
    -e "s/^QUEUE_PORT=.*/QUEUE_PORT=$QPORT/" -e "s/^RCON_PORT=.*/RCON_PORT=$RPORT/" \
    -e 's/^STOP_TIMEOUT=.*/STOP_TIMEOUT=20/' "$REPO/config/server.conf.example" > "$ISLE_CONF"
# Values Docker Compose would mangle if it read server.conf directly ($VAR, $$, " #", quotes, backslash)
cat >> "$ISLE_CONF" <<'EOF'
SERVER_NAME="E2E Server"
SERVER_PASSWORD=pa$$w0rd #x"q"\b $HOME
EOF
mkdir -p "$T/overrides"
printf '[/Script/TheIsle.TIGameSession]\nbE2EOverride=true\n' > "$T/overrides/Game.ini"

fails=0
ck() { if eval "$2"; then echo "  PASS $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }
waitfor() { local _; for _ in $(seq 1 "${2:-30}"); do eval "$1" && return 0; sleep 2; done; return 1; }
srvlog() { docker exec theisle cat /data/server/TheIsle/Saved/fake-server.log 2>/dev/null; }
seen() { srvlog | grep -q -- "$1"; }
gameini() { docker exec theisle cat /data/server/TheIsle/Saved/Config/LinuxServer/Game.ini 2>/dev/null; }
healthy() { [ "$(docker inspect -f '{{.State.Health.Status}}' theisle 2>/dev/null)" = healthy ]; }
started_at() { docker inspect -f '{{.State.StartedAt}}' theisle 2>/dev/null; }
cleanup() {
  docker rm -f theisle >/dev/null 2>&1
  docker volume rm theisle-data >/dev/null 2>&1
  [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null
  rm -rf "$REPO/plugins/installed"
  rm -rf -- "$T"
}
trap cleanup EXIT
docker rm -f theisle >/dev/null 2>&1; docker volume rm theisle-data >/dev/null 2>&1

# host-side webhook catcher for discord-notify
python3 - "$T/webhook.log" "$T/webhook.port" <<'PY' &
import http.server, sys
log, portfile = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        open(log, "ab").write(body + b"\n"); self.send_response(204); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_address[1]))
s.serve_forever()
PY
HTTP_PID=$!
waitfor "[ -s $T/webhook.port ]" 10

echo "## install + seed the fake game server"
ck "install"                       "$L install >/dev/null 2>&1"
docker run --rm -v theisle-data:/data -v "$REPO/tests/fixtures:/fx:ro" --entrypoint sh "$IMAGE" -c \
  'mkdir -p /data/server/TheIsle/Binaries/Linux && cp /fx/fake-isle-server.py /data/server/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping && chmod 755 /data/server/TheIsle/Binaries/Linux/TheIsleServer-Linux-Shipping'

echo "## plugins (run on the host, talk to the container)"
ck "install plugins"               "$L plugins preset full >/dev/null 2>&1"
ck "configure plugins"             "$L plugins config discord-notify DISCORD_WEBHOOK_URL=http://127.0.0.1:\$(cat $T/webhook.port)/hook EVENTS=post-start,post-stop,post-backup >/dev/null && $L plugins config offsite-backup DEST_DIR=$T/nas >/dev/null && $L plugins config welcome-announcer DELAY_SECONDS=8 MESSAGE='Hi from {name}' >/dev/null && $L plugins config restart-countdown WARNINGS=0 FINAL_MESSAGE='E2E restart' >/dev/null"

echo "## start"
ck "start"                         "$L start >/dev/null 2>&1"
ck "healthy"                       "waitfor healthy 45"
ck "status = 0"                    "$L status >/dev/null 2>&1"
ck "game runs as uid 1000"         "seen 'STARTED uid=1000'"
ck "launch args"                   "seen 'args=TheIsle -Port=$GPORT -log'"
ck "override reached Game.ini"     "gameini | grep -q '^bE2EOverride=true'"
ck "post-start hook -> webhook"    "waitfor '[ -s $T/webhook.log ] && grep -q \"is starting\" $T/webhook.log' 10"
ck "welcome-announcer (host->RCON)" "waitfor \"seen 'RCON announce Hi from E2E Server'\" 15"

ck "tricky password arrives literally" "gameini | grep -qxF 'ServerPassword=pa\$\$w0rd #x\"q\"\\b \$HOME'"

echo "## RCON and live admin tools"
ck "rcon via launcher"             "$L rcon serverdetails >/dev/null 2>&1 && seen 'RCON serverdetails'"
ck "whitelist add -> live"         "$L whitelist add 76561198000000001 2>&1 | grep -q 'Applied live' && seen 'RCON addwhitelist 76561198000000001'"
ck "whitelist on -> toggle"        "$L whitelist on 2>&1 | grep -q 'Applied live' && seen 'RCON togglewhitelist'"
ck "whitelist remove -> live"      "$L whitelist remove 76561198000000001 >/dev/null 2>&1 && seen 'RCON removewhitelist 76561198000000001'"
ck "roster -> updateplayables"     "$L classes set Tyrannosaurus Stegosaurus >/dev/null 2>&1 && seen 'RCON updateplayables Tyrannosaurus,Stegosaurus'"
ck "ai-classes -> disableaiclasses" "$L ai-classes set Boar >/dev/null 2>&1 && seen 'RCON disableaiclasses Boar'"
ck "admins saved (restart needed)" "$L admins add 76561198000000002 2>&1 | grep -q 'restart the server'"

echo "## backup (+ offsite-backup copies it out of the container)"
ck "backup"                        "$L backup >/dev/null 2>&1"
ck "save sent before backup"       "seen 'RCON save'"
ck "offsite copy on the host"      "ls $T/nas/theisle-*.tar.gz >/dev/null 2>&1"
ck "post-backup -> webhook"        "grep -q 'backup finished' $T/webhook.log"

echo "## profile + restart picks up config changes"
ck "profile apply"                 "$L profile apply realism >/dev/null 2>&1"
ck "restart"                       "$L restart >/dev/null 2>&1 && waitfor healthy 45"
ck "new settings in container"     "gameini | grep -q '^GrowthMultiplier=0.75' && gameini | grep -q '^AllowedClasses=Stegosaurus' && gameini | grep -q '^AdminsSteamIDs=76561198000000002'"

echo "## restart-countdown (announce, save, restart through the launcher)"
before="$(started_at)"
docker exec theisle sh -c ': > /data/server/TheIsle/Saved/fake-server.log'
ck "countdown run"                 "$L plugins run restart-countdown run 0 >/dev/null 2>&1"
ck "final announcement"            "seen 'RCON announce E2E restart'"
ck "container restarted"           "waitfor '[ \"\$(started_at)\" != \"$before\" ]' 30 && waitfor healthy 45"

echo "## crash: Docker's restart policy brings the server back"
before="$(started_at)"
docker exec theisle sh -c 'kill -KILL "$(cat /data/server/.isle-scripts/server.pid)"'
ck "container restarted after crash" "waitfor '[ \"\$(started_at)\" != \"$before\" ]' 40 && waitfor healthy 45"

echo "## restore a Windows-style .zip backup from the host"
mkdir -p "$T/zipsrc/Saved/SaveGames" && echo from-zip > "$T/zipsrc/Saved/SaveGames/zip-marker.txt"
(cd "$T/zipsrc" && python3 -c "import shutil; shutil.make_archive('$T/winbackup', 'zip', '.', 'Saved')")
$L stop >/dev/null 2>&1
ck "zip restore"                   "$L restore $T/winbackup.zip >/dev/null 2>&1"
ck "zip content in the volume"     "docker run --rm -v theisle-data:/data:ro --entrypoint cat $IMAGE /data/server/TheIsle/Saved/SaveGames/zip-marker.txt | grep -qx from-zip"
ck "not-a-backup refused"          "mkdir -p $T/junk && echo x > $T/junk/x && tar -czf $T/junk.tar.gz -C $T/junk x && ! $L restore $T/junk.tar.gz >/dev/null 2>&1"
ck "start again"                   "$L start >/dev/null 2>&1 && waitfor healthy 45"

echo "## stop: save before SIGTERM, clean exit"
docker exec theisle sh -c ': > /data/server/TheIsle/Saved/fake-server.log'
ck "stop"                          "$L stop >/dev/null 2>&1"
ck "exit code 0"                   "[ \"\$(docker inspect -f '{{.State.ExitCode}}' theisle)\" = 0 ]"
ck "save then SIGTERM"             "docker run --rm -v theisle-data:/data:ro --entrypoint sh $IMAGE -c 'cat /data/server/TheIsle/Saved/fake-server.log' | grep -E 'RCON save|SIGTERM' | paste -sd' ' - | grep -q '^RCON save.* SIGTERM\$'"
ck "status = 3"                    "rc=0; $L status >/dev/null 2>&1 || rc=\$?; [ \$rc = 3 ]"
ck "post-stop -> webhook"          "grep -q 'stopped' $T/webhook.log"

echo "RESULT: $fails failure(s)"
exit $(( fails > 0 ))
