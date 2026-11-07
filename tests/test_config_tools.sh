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
trap 'rm -rf -- "$T"' EXIT
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
ck "apply keeps a backup"         "ls $ISLE_CONF.bak-* >/dev/null 2>&1"
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
ck "list"                         "out admins list | grep -qx $A2"

echo "## whitelist"
ck "add + list"                   "out whitelist add $A1 >/dev/null && out whitelist list | grep -qx $A1"
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
