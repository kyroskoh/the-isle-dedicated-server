#!/usr/bin/env bash
# =============================================================================
#  tests/test_config_tools.sh - ini overrides, profiles, presets, admins,
#  whitelist and roster commands (PRD CFX-01..09). Safe to run anywhere: it
#  works on a throwaway copy of the repo and never starts a server.
#
#    bash tests/test_config_tools.sh
# =============================================================================
# shellcheck disable=SC2317,SC2329
set -u   # no pipefail: grep -q closing a pipe early is fine here

SRC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
T="$(mktemp -d)"
# fake Steam for the name lookups (tests/fixtures/fake-steam.py)
exec {STEAM_FD}< <(exec python3 "$SRC/tests/fixtures/fake-steam.py" 0)
STEAM_PID=$!
read -r _ STEAM_PORT <&"$STEAM_FD"
export ISLE_STEAM_COMMUNITY_URL="http://127.0.0.1:$STEAM_PORT" ISLE_STEAM_API_URL="http://127.0.0.1:$STEAM_PORT"
trap 'rm -rf -- "$T"; kill "$STEAM_PID" 2>/dev/null || true' EXIT
mkdir -p "$T/repo"
(cd "$SRC" && tar --exclude=.git --exclude='config/server.conf' -cf - .) | (cd "$T/repo" && tar -xf -)
R="$T/repo"
export ISLE_CONF="$T/server.conf" ISLE_NO_SYSTEMD=1 ISLE_RUNTIME=native HOME="$T/home"
export ISLE_ALLOW_ROOT=1   # lets the backup steps run when the test itself runs as root
sed -e "s|^SERVER_DIR=|SERVER_DIR=$T/srv|" -e "s|^BACKUP_DIR=|BACKUP_DIR=$T/bk|" \
    -e 's|^RCON_PASSWORD=|RCON_PASSWORD=test-password|' -e 's|^UPDATE_ON_START=true|UPDATE_ON_START=false|' \
    "$R/config/server.conf.example" > "$ISLE_CONF"
L="$R/linux/isle-server.sh"
GI="$T/srv/TheIsle/Saved/Config/LinuxServer/Game.ini"
EI="$T/srv/TheIsle/Saved/Config/LinuxServer/Engine.ini"
fails=0
ck() { if eval "$2"; then echo "  PASS $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }
conf() { grep -E "^$1=" "$ISLE_CONF" | tail -n1 | cut -d= -f2-; }
out() { "$L" "$@" 2>&1; }

echo "## profiles"
ck "list shows all profiles"      "out profile list | grep -q realism && [ \$(out profile list | wc -l) -ge 7 ]"
ck "show prints changes"          "out profile show realism | grep -q 'GROWTH_MULTIPLIER *1 -> 0.75'"
ck "apply writes keys"            "out profile apply realism >/dev/null && [ \"\$(conf GROWTH_MULTIPLIER)\" = 0.75 ] && [ \"\$(conf GLOBAL_CHAT)\" = false ]"
ck "apply keeps a backup"         "ls $ISLE_CONF.bak_* >/dev/null 2>&1"
ck "unknown profile fails"        "! out profile apply nope >/dev/null"
ck "one profile at a time"        "! out profile apply realism casual >/dev/null"

echo "## presets"
ck "stacked presets apply in order" "out preset apply ai-off fast-growth very-fast-growth >/dev/null && [ \"\$(conf SPAWN_AI)\" = false ] && [ \"\$(conf GROWTH_MULTIPLIER)\" = 5 ]"
printf '# Preset: zz-bad - invalid\nGAME_PORT=99999\n' > "$R/config/presets/zz-bad.conf"
before="$(md5sum < "$ISLE_CONF")"
ck "invalid result rolls back"    "! out preset apply zz-bad >/dev/null && [ \"\$(md5sum < $ISLE_CONF)\" = \"$before\" ]"
rm -f "$R/config/presets/zz-bad.conf"

echo "## admins"
A1=76561198000000001; A2=76561198000000002
ck "add two admins"               "out admins add $A1 $A2 >/dev/null && [ \"\$(conf ADMIN_STEAM_IDS)\" = $A1,$A2 ]"
ck "duplicates are ignored"       "out admins add $A1 >/dev/null && [ \"\$(conf ADMIN_STEAM_IDS)\" = $A1,$A2 ]"
ck "invalid SteamID refused"      "! out admins add 12345 >/dev/null && [ \"\$(conf ADMIN_STEAM_IDS)\" = $A1,$A2 ]"
ck "remove one"                   "out admins remove $A1 >/dev/null && [ \"\$(conf ADMIN_STEAM_IDS)\" = $A2 ]"
ck "list"                         "out admins list | grep -q '^$A2  '"

echo "## Steam names (PLY-01..03)"
ck "admins add shows the Steam name" "out admins add 76561198000000042 | grep -q '76561198000000042  NewAdmin'"
ck "admins list shows names"      "out admins list | grep -q '^$A2  Ptera <Pal> & Co'"
ck "unknown profile marked"       "out steam names 76561198000000099 | grep -q '(name unknown)'"
ck "steam names checks ids"       "! out steam names 123 >/dev/null"
ck "names are cached"             "[ -f $T/.steam-names.json ] && ISLE_STEAM_COMMUNITY_URL=http://127.0.0.1:9 out admins list | grep -q 'Ptera <Pal>'"
ck "lookups can be turned off"    "sed -i 's/^STEAM_NAME_LOOKUP=.*/STEAM_NAME_LOOKUP=false/' $ISLE_CONF && out steam names --refresh 76561198000000003 | grep -q '(name unknown)'"
sed -i 's/^STEAM_NAME_LOOKUP=.*/STEAM_NAME_LOOKUP=true/' "$ISLE_CONF"; out admins remove 76561198000000042 >/dev/null

echo "## whitelist"
ck "add + list"                   "out whitelist add $A1 >/dev/null && out whitelist list | grep -q '^$A1  RexHunter'"
ck "on"                           "out whitelist on >/dev/null && [ \"\$(conf WHITELIST_ENABLED)\" = true ]"
ck "off"                          "out whitelist off >/dev/null && [ \"\$(conf WHITELIST_ENABLED)\" = false ]"
ck "not running: no live RCON"    "out whitelist add $A2 | grep -q 'applies on the next start'"

echo "## playable roster"
ck "known classes listed"         "out classes known | grep -qx Tyrannosaurus"
ck "set"                          "out classes set Tyrannosaurus Triceratops >/dev/null && [ \"\$(conf ALLOWED_CLASSES)\" = Tyrannosaurus,Triceratops ]"
ck "add + remove"                 "out classes add Stegosaurus >/dev/null && out classes remove Triceratops >/dev/null && [ \"\$(conf ALLOWED_CLASSES)\" = Tyrannosaurus,Stegosaurus ]"
ck "unknown class warns, is kept" "out classes add Futurosaurus | grep -q 'not in config/classes.txt' && conf ALLOWED_CLASSES | grep -q Futurosaurus"
ck "invalid name refused"         "! out classes add 'Bad Name!' >/dev/null"
ck "roster presets listed"        "out classes preset | grep -q carnivores"
ck "roster preset applied"        "out classes preset herbivores >/dev/null && conf ALLOWED_CLASSES | grep -q Triceratops && ! conf ALLOWED_CLASSES | grep -q Tyrannosaurus"
ck "reset = all classes"          "out classes reset >/dev/null && [ -z \"\$(conf ALLOWED_CLASSES)\" ]"
ck "ai-classes"                   "out ai-classes set Compsognathus Boar >/dev/null && [ \"\$(conf DISABLED_AI_CLASSES)\" = Compsognathus,Boar ]"

echo "## Game.ini / Engine.ini"
out classes set Tyrannosaurus Dryosaurus >/dev/null
out configure >/dev/null
ck "roster rendered as list"      "[ \$(grep -c '^AllowedClasses=' $GI) = 2 ]"
ck "admins in both sections"      "[ \$(grep -c '^AdminsSteamIDs=$A2' $GI) = 2 ]"
ck "optional keys absent by default" "! grep -q 'bUseRegionSpawning\\|NetServerMaxTickRate' $GI $EI"
out preset apply region-spawning >/dev/null; out profile apply performance >/dev/null; out configure >/dev/null
ck "optional keys rendered"       "grep -q '^bUseRegionSpawning=true' $GI && grep -q '^RegionSpawnCooldownTimeSeconds=300' $GI && grep -q '^NetServerMaxTickRate=30' $EI"
mkdir -p "$T/overrides"
cat > "$T/overrides/Game.ini" <<'EOF'
; comment
[/Script/TheIsle.TIGameSession]
GrowthMultiplier=9
AllowedClasses=Carnotaurus
AllowedClasses=Pteranodon
bSomethingNew=true
+ArrayKey=one

[/Script/TheIsle.Custom]
Foo=Bar
EOF
printf '[/Script/OnlineSubsystemUtils.IpNetDriver]\nNetServerMaxTickRate=60\n' > "$T/overrides/Engine.ini"
out configure >/dev/null
ck "override replaces a key"      "[ \$(grep -c '^GrowthMultiplier=' $GI) = 1 ] && grep -q '^GrowthMultiplier=9' $GI"
ck "override replaces a list"     "[ \"\$(grep '^AllowedClasses=' $GI | paste -sd, -)\" = 'AllowedClasses=Carnotaurus,AllowedClasses=Pteranodon' ]"
ck "new key lands in its section" "awk '/^\\[/{s=\$0} /^bSomethingNew=true/{print s}' $GI | grep -qx '\\[/Script/TheIsle.TIGameSession\\]'"
ck "+array lines pass through"    "grep -q '^+ArrayKey=one' $GI"
ck "new section appended"         "grep -q '^\\[/Script/TheIsle.Custom\\]' $GI && grep -q '^Foo=Bar' $GI"
ck "other sections untouched"     "grep -q '^MaxPlayers=' $GI"
ck "Engine override"              "[ \$(grep -c '^NetServerMaxTickRate=' $EI) = 1 ] && grep -q '^NetServerMaxTickRate=60' $EI"
sed -i "s|^INI_OVERRIDES_DIR=.*|INI_OVERRIDES_DIR=$T/nowhere|" "$ISLE_CONF"; out configure >/dev/null
ck "INI_OVERRIDES_DIR is honoured" "grep -q '^NetServerMaxTickRate=30' $EI"

echo "## maps and AI (MAP-01..03, AIX-01..03)"
ck "maps list"                    "out maps list | grep -q '^\* Gateway' && out maps list | grep -q Isla_Spiro"
ck "maps set switches branch"     "out maps set Isla_Spiro >/dev/null && [ \"\$(conf MAP_NAME)\" = Isla_Spiro ] && [ \"\$(conf STEAM_BRANCH)\" = spiro0.11.59.04 ]"
ck "maps set --keep-branch"       "out maps set Gateway --keep-branch >/dev/null && [ \"\$(conf STEAM_BRANCH)\" = spiro0.11.59.04 ]"
ck "maps names are case-sensitive" "! out maps set gateway >/dev/null && out maps set Gateway >/dev/null && [ \"\$(conf STEAM_BRANCH)\" = evrima ]"
ck "unknown MAP_NAME only warns"  "sed -i 's/^MAP_NAME=.*/MAP_NAME=NewMap/' $ISLE_CONF && out check | grep -q 'not in config/maps.txt' && out maps set Gateway >/dev/null"
ck "ai density + interval"        "out ai density 0.5 >/dev/null && out ai interval 25 >/dev/null && [ \"\$(conf AI_DENSITY)\" = 0.5 ] && [ \"\$(conf AI_SPAWN_INTERVAL)\" = 25 ]"
ck "ai bad values refused"        "! out ai density lots >/dev/null && ! out ai interval 0 >/dev/null && ! out ai interval 2.5 >/dev/null"
ck "ai off/on"                    "out ai off >/dev/null && [ \"\$(conf SPAWN_AI)\" = false ] && out ai on >/dev/null && [ \"\$(conf SPAWN_AI)\" = true ]"
ck "ai preset (ai-* only)"        "out ai preset ai-prey-only >/dev/null && [ \"\$(conf DISABLED_AI_CLASSES)\" = Compsognathus,Pterodactylus ] && ! out ai preset casual >/dev/null"
ck "AISpawnInterval rendered"     "out configure >/dev/null && grep -q '^AISpawnInterval=25' $GI && grep -q '^AIDensity=0.5' $GI"
ck "AI roles listed"              "grep -q '^Seaturtle *aquatic' $R/config/classes.txt && out ai-classes known | grep -qx Seaturtle"
ck "bad AI_SPAWN_INTERVAL rejected" "sed -i 's/^AI_SPAWN_INTERVAL=.*/AI_SPAWN_INTERVAL=often/' $ISLE_CONF && ! out check >/dev/null; sed -i 's/^AI_SPAWN_INTERVAL=.*/AI_SPAWN_INTERVAL=40/' $ISLE_CONF"
ck "plugins community"            "out plugins community | grep -q isle-evrima-rcon"

echo "## roster types, humans, mutations (ROS-05..07, MUT-01..03)"
ck "types listed"                 "out classes types | grep -q '^  flying *Pteranodon'"
ck "select keeps only that type"  "out classes select flying >/dev/null && [ \"\$(conf ALLOWED_CLASSES)\" = Pteranodon ]"
ck "add-type adds a type"         "out classes add-type aquatic >/dev/null && [ \"\$(conf ALLOWED_CLASSES)\" = Pteranodon,Deinosuchus ] || [ \"\$(conf ALLOWED_CLASSES)\" = Deinosuchus,Pteranodon ]"
ck "remove-type removes it"       "out classes remove-type flying >/dev/null && [ \"\$(conf ALLOWED_CLASSES)\" = Deinosuchus ]"
ck "unknown type refused"         "! out classes select egg >/dev/null && ! out classes select human >/dev/null"
ck "humans on/off"                "out classes humans on >/dev/null && [ \"\$(conf ENABLE_HUMANS)\" = true ] && out classes humans off >/dev/null && [ \"\$(conf ENABLE_HUMANS)\" = false ]"
out classes reset >/dev/null
ck "mutations list"               "[ \$(out mutations list | grep -c .) -ge 40 ]"
ck "mutation enable with value"   "out mutations enable Hemomania 0.3 >/dev/null && conf ENABLED_MUTATIONS | grep -q 'Hemomania:0.3'"
ck "fixed mutation only takes 1"  "! out mutations enable Reabsorption 2 >/dev/null"
ck "unknown mutation refused"     "! out mutations enable Wings >/dev/null"
ck "EnabledMutations in Game.ini" "out configure >/dev/null && grep -q '^EnabledMutations=Hemomania, 0.3' $GI"
ck "mutations reset = all"        "out mutations reset >/dev/null && [ -z \"\$(conf ENABLED_MUTATIONS)\" ]"

echo "## scheduled backups + 3-2-1 (BAK-06..09)"
ck "schedule set"                 "out backup schedule set '30 */6 * * 1-5' >/dev/null && conf BACKUP_SCHEDULE | grep -q '30 \*/6 \* \* 1-5'"
ck "invalid schedule refused"     "! out backup schedule set '61 * * * *' >/dev/null && conf BACKUP_SCHEDULE | grep -q '30 \*/6'"
ck "schedule show lists runs"     "[ \$(out backup schedule show | grep -c ' 06:30 \\| 12:30 ') -ge 2 ]"
ck "status json"                  "out backup status --json | tail -n1 | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"rule321\"][\"copies\"]>=1'"
mkdir -p "$T/copy"
sed -i "s|^BACKUP_COPY_DIR=.*|BACKUP_COPY_DIR=$T/copy|; s|^BACKUP_OFFSITE_COMMAND=.*|BACKUP_OFFSITE_COMMAND=cp {file} $T/offsite/|" "$ISLE_CONF"; mkdir -p "$T/offsite"
ck "backup copies to 2nd dir + offsite" "out backup >/dev/null && ls $T/copy/theisle-*.tar.gz >/dev/null 2>&1 && ls $T/offsite/theisle-*.tar.gz >/dev/null 2>&1"
while [ "$(date +%S | sed s/^0//)" -gt 45 ]; do sleep 1; done   # both ticks in the same minute
ck "tick runs when due, once"     "rm -f $T/.backup-tick; out backup schedule set '* * * * *' >/dev/null && out backup tick | grep -q 'Scheduled backup' && ! out backup tick | grep -q 'Scheduled backup'"
ck "off never runs"               "out backup schedule off >/dev/null && rm -f $T/.backup-tick && ! out backup tick | grep -q 'Scheduled backup'"
sed -i 's|^BACKUP_COPY_DIR=.*|BACKUP_COPY_DIR=|; s|^BACKUP_OFFSITE_COMMAND=.*|BACKUP_OFFSITE_COMMAND=|' "$ISLE_CONF"; out backup schedule set '0 5 * * *' >/dev/null

echo "## 3-2-1 strategy (BAK-10..12)"
ck "strategy copy + keep"         "out backup strategy copy $T/copy2 --keep 3 >/dev/null && [ \"\$(conf BACKUP_COPY_DIR)\" = $T/copy2 ] && [ \"\$(conf BACKUP_COPY_RETENTION)\" = 3 ]"
ck "strategy offsite dir"         "out backup strategy offsite dir:$T/nas2 --keep 2 >/dev/null && [ \"\$(conf BACKUP_OFFSITE_TARGET)\" = dir:$T/nas2 ]"
ck "unsafe targets refused"       "! out backup strategy offsite 'ssh://h/p;rm' >/dev/null && ! out backup strategy offsite 'rclone copy {file} x' >/dev/null && [ \"\$(conf BACKUP_OFFSITE_TARGET)\" = dir:$T/nas2 ]"
ck "relative copy folder refused" "! out backup strategy copy rel/dir >/dev/null"
ck "strategy test passes"         "out backup strategy test | grep -q 'Off-site    : OK'"
if ! command -v rclone >/dev/null 2>&1; then   # an rclone target fails its test while rclone is not installed
  out backup strategy offsite rclone:none:x >/dev/null
  ck "a failing test exits 1, no backup" "n=\$(ls $T/bk | wc -l); out backup strategy test | grep -q 'not installed'; ! out backup strategy test >/dev/null && [ \$(ls $T/bk | wc -l) -eq \$n ]"
fi
out backup strategy offsite "dir:$T/nas2" >/dev/null
ck "backup sends off-site + prunes" "for i in 1 2 3; do out backup >/dev/null; sleep 1; done; [ \$(ls $T/nas2 | grep -c theisle-) -eq 2 ] && [ \$(ls $T/copy2 | grep -c theisle-) -eq 3 ]"
ck "check validates the target"   "sed -i 's|^BACKUP_OFFSITE_TARGET=.*|BACKUP_OFFSITE_TARGET=ftp://x|' $ISLE_CONF && out check | grep -q 'BACKUP_OFFSITE_TARGET'"
out backup strategy offsite off >/dev/null; out backup strategy copy off >/dev/null

echo "## onboarding (ONB-01..02)"
export ISLE_SYSINFO_FAKE='{"cpus": 2, "mem_gb": 6, "disk_free_gb": 50, "arch": "x86_64"}'
ck "recommend shows a table"      "out recommend | grep -q 'MAX_PLAYERS *30'"
ck "recommend --apply KEY"        "out recommend --apply MAX_PLAYERS NET_TICK_RATE >/dev/null && [ \"\$(conf MAX_PLAYERS)\" = 30 ] && [ \"\$(conf NET_TICK_RATE)\" = 20 ]"
ck "recommend --apply unknown"    "! out recommend --apply RCON_PASSWORD >/dev/null"
rm -f "$T/.setup-done"
ck "setup wizard (answers piped)" "printf 'n\\nWizard Isle\\n-\\n\\n24\\n\\n\\n\\n\\n\\n' | ISLE_SETUP_INTERACTIVE=1 out setup >/dev/null && [ \"\$(conf SERVER_NAME)\" = 'Wizard Isle' ] && [ \"\$(conf MAX_PLAYERS)\" = 24 ] && [ -f $T/.setup-done ]"
ck "setup --yes applies recommendations" "out recommend --apply MAX_PLAYERS >/dev/null; sed -i 's/^AI_DENSITY=.*/AI_DENSITY=2/' $ISLE_CONF && out setup --yes </dev/null >/dev/null && [ \"\$(conf AI_DENSITY)\" = 0.75 ]"
unset ISLE_SYSINFO_FAKE

echo "## admin (ADM-01..03)"
ck "admin usage notes the limits" "out admin | grep -q 'god mode'"
ck "admin kick needs a SteamID64" "! out admin kick 123 >/dev/null"
ck "admin growth must be a number" "! out admin growth fast >/dev/null"
ck "version shows project + author" "out version | grep -q 'github.com/kyroskoh/the-isle-dedicated-server' && out version | grep -q 'Kyros Koh'"

echo "## validation"
sed -i 's|^NET_TICK_RATE=.*|NET_TICK_RATE=fast|' "$ISLE_CONF"
ck "bad NET_TICK_RATE rejected"   "! out check >/dev/null"
sed -i 's|^NET_TICK_RATE=.*|NET_TICK_RATE=|' "$ISLE_CONF"

echo "## plugins via the launcher (hooks fire on launcher actions)"
ck "plugins list"                 "out plugins list | grep -q offsite-backup"
ck "install + config"             "out plugins install offsite-backup >/dev/null && out plugins config offsite-backup DEST_DIR=$T/nas >/dev/null"
ck "backup fires post-backup hook" "out backup >/dev/null && ls $T/nas/theisle-*.tar.gz >/dev/null 2>&1"
ck "disabled plugin does not run" "rm -rf -- $T/nas && out plugins disable offsite-backup >/dev/null && out backup >/dev/null && [ ! -e $T/nas ]"

if [[ $EUID -eq 0 ]] && id nobody >/dev/null 2>&1; then
  echo "## ownership"
  chown nobody "$ISLE_CONF"
  out admins add $A1 >/dev/null
  ck "root edit keeps the owner"  "[ \"\$(stat -c %U $ISLE_CONF)\" = nobody ]"
fi

echo "RESULT: $fails failure(s)"
exit $(( fails > 0 ))
