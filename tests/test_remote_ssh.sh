#!/usr/bin/env bash
# =============================================================================
#  tests/test_remote_ssh.sh - remote provisioning against a REAL sshd (PRD REM-01..06).
#  Starts OpenSSH on 127.0.0.1:2222, creates a test admin user with passwordless
#  sudo, and drives tools/isle_remote.py through: add + key, a refused login,
#  test, a real upload + unpack (--stage-only), a dry run, and remote run.
#  It changes the system (user, sudoers, sshd, a stub launcher), so it refuses
#  to run without ISLE_TEST_I_UNDERSTAND=1 and root. Cleans up after itself.
#
#    sudo ISLE_TEST_I_UNDERSTAND=1 bash tests/test_remote_ssh.sh
# =============================================================================
# shellcheck disable=SC2317,SC2329  # cleanup runs from the EXIT trap
set -u
[[ "${ISLE_TEST_I_UNDERSTAND:-}" == 1 ]] || { echo "Refusing: set ISLE_TEST_I_UNDERSTAND=1 (this changes the system)"; exit 2; }
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 2; }
SRC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
T="$(mktemp -d)"; U=isleremotetest; PORT=2222
fails=0
ck() { if eval "$2"; then echo "  PASS $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

if ! command -v sshd >/dev/null 2>&1 && [[ ! -x /usr/sbin/sshd ]]; then
  apt-get install -y -q openssh-server >/dev/null 2>&1 || { echo "openssh-server is not available"; exit 1; }
fi
STUB=0
cleanup() {
  [[ -f "$T/sshd.pid" ]] && kill "$(cat "$T/sshd.pid")" 2>/dev/null
  userdel -r "$U" >/dev/null 2>&1; rm -f "/etc/sudoers.d/$U"
  (( STUB )) && rm -f /usr/local/bin/isle-server
  rm -rf -- "$T"
}
trap cleanup EXIT

useradd -m -s /bin/bash "$U" && usermod -p '*' "$U"            # no usable password; key login only
echo "$U ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$U"; chmod 440 "/etc/sudoers.d/$U"
mkdir -p /run/sshd; ssh-keygen -A >/dev/null
SFTP="$(for p in /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server /usr/lib/ssh/sftp-server; do [[ -x $p ]] && echo "$p" && break; done)"
cat > "$T/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM no
PidFile $T/sshd.pid
Subsystem sftp $SFTP
EOF
"$(command -v sshd || echo /usr/sbin/sshd)" -f "$T/sshd_config" || { echo "sshd did not start"; exit 1; }
sleep 1
if [[ ! -e /usr/local/bin/isle-server ]]; then   # a stand-in launcher for "remote run"
  # shellcheck disable=SC2016  # expanded by the stub when it runs, not here
  printf '#!/bin/sh\necho "stub isle-server as $(id -un): $*"\n' > /usr/local/bin/isle-server; chmod 755 /usr/local/bin/isle-server; STUB=1
fi
id theisle >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin theisle 2>/dev/null || true

C="$T/config"; mkdir -p "$C"
R=(python3 "$SRC/tools/isle_remote.py" --dir "$C")
echo "## remote provisioning over a real sshd"
ck "add + new ed25519 key"       "${R[*]} add lab --host 127.0.0.1 --port $PORT --user $U --new-key >/dev/null && [ -f $C/keys/lab_ed25519 ] && [ -f $C/keys/lab_ed25519.pub ]"
ck "private key is mode 600"     "[ \"\$(stat -c %a $C/keys/lab_ed25519)\" = 600 ]"
ck "login refused before the key is installed" "! ${R[*]} test lab >$T/t1 2>&1 && grep -q 'Permission denied' $T/t1 && grep -q 'copy-id lab' $T/t1"
install -d -m 700 -o "$U" -g "$U" "/home/$U/.ssh"; install -m 600 -o "$U" -g "$U" "$C/keys/lab_ed25519.pub" "/home/$U/.ssh/authorized_keys"
ck "test: reachable, linux, sudo" "${R[*]} test lab --json >$T/t2 && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"reachable\"] and d[\"os\"]==\"linux\" and d[\"admin\"], d' $T/t2"
ck "host key pinned in known_hosts" "ssh-keygen -F '[127.0.0.1]:$PORT' -f $C/keys/known_hosts >/dev/null"
ck "real upload + unpack (--stage-only)" "${R[*]} provision lab --stage-only >/dev/null && [ -f /home/$U/theisle-installer/the-isle-dedicated-server/linux/install.sh ] && [ -f /home/$U/theisle-installer/the-isle-dedicated-server/config/server.conf.example ]"
ck "no local config or keys uploaded" "[ ! -e /home/$U/theisle-installer/the-isle-dedicated-server/config/keys ] && [ ! -e /home/$U/theisle-installer/the-isle-dedicated-server/config/hosts ]"
ck "dry run shows the installer command" "${R[*]} provision lab --docker --start --dry-run | grep -q 'sudo -n bash ./linux/install.sh --docker --yes --start'"
if (( STUB )); then
  ck "remote run as the service user" "${R[*]} run lab -- status | grep -q 'stub isle-server as theisle: status'"
fi
ck "remote run refuses shell characters" "! ${R[*]} run lab -- status 'x;id' >/dev/null 2>&1"
# the server's identity changes (reinstalled, or someone in the middle): new host keys, same address
kill "$(cat "$T/sshd.pid")"; sleep 1
for t in ed25519 ecdsa rsa; do ssh-keygen -q -t "$t" -N '' -f "$T/new_host_$t" && echo "HostKey $T/new_host_$t" >> "$T/sshd_config"; done
"$(command -v sshd || echo /usr/sbin/sshd)" -f "$T/sshd_config"; sleep 1
ck "a changed host key is refused, with advice" "! ${R[*]} test lab >$T/t3 2>&1 && grep -qi 'host key' $T/t3 && grep -q 'ssh-keygen -R' $T/t3"

echo "RESULT: $fails failure(s)"
exit $(( fails > 0 ))
