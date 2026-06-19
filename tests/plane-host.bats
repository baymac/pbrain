#!/usr/bin/env bats
# Tests for the Plane VPS-hosting feature (PB-18): lib/plane-host.sh. No real VPS —
# `ssh` is stubbed so the resolve → ssh-build → run plumbing and the import safety
# gate are exercised without a network. `security` is stubbed so the Keychain
# password path in `wire` (lib/plane.py) is covered on macOS. `wire` runs the real
# lib/plane.py against an isolated XDG config dir.
#
# NB: bats only enforces the LAST command of each @test, so must-hold checks are
# chained with && into one final line.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0 PBRAIN_UPDATE_CHECK=0 PBRAIN_SELF_IMPROVE=off
  export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/pbrain"
  export HOME="$TMP/home"; mkdir -p "$HOME"

  STUB="$TMP/bin"; mkdir -p "$STUB"
  # ssh stub: echo the target host, and emulate the backup-listing command.
  cat > "$STUB/ssh" <<'SSH'
#!/usr/bin/env bash
host=""
for a in "$@"; do case "$a" in -*) ;; *@*) host="$a"; break ;; esac; done
cmd="${@: -1}"
echo "SSH_HOST=$host"
case "$cmd" in
  *plane-*.tar.gz*) printf '/root/pbrain-plane-backups/plane-20260101-000000.tar.gz\n/root/pbrain-plane-backups/plane-20251231-000000.tar.gz\n' ;;
esac
exit 0
SSH
  # security stub: pretend the macOS Keychain accepts/returns secrets.
  cat > "$STUB/security" <<'SEC'
#!/usr/bin/env bash
case "$1" in
  add-generic-password) exit 0 ;;
  find-generic-password) echo "stub-secret" ;;
  *) exit 0 ;;
esac
SEC
  chmod +x "$STUB/ssh" "$STUB/security"
  export PATH="$STUB:$PATH"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/plane-host.sh"
}

teardown() { rm -rf "$TMP"; }

_write_backup_cfg() {  # $1 host, $2 key
  cat > "$XDG_CONFIG_HOME/pbrain/plane-backup.json" <<JSON
{ "dest": "vps", "vps": { "host": "$1", "port": 22, "ssh_key": "$2", "path": "/root/pbrain-plane-backups" } }
JSON
}

@test "sshcmd includes the port and identity flag" {
  PLH_PORT=2222 PLH_KEY="/tmp/k"
  run pbrain_plh_sshcmd
  [[ "$output" == *"-p 2222"* ]] && [[ "$output" == *"-i /tmp/k"* ]] && [[ "$output" == *"BatchMode=yes"* ]]
}

@test "resolve inherits the VPS host/key from plane-backup.json" {
  _write_backup_cfg "root@vps.example" "/tmp/id_ecdsa"
  pbrain_plh_resolve
  [[ "$PLH_HOST" == "root@vps.example" ]] && [[ "$PLH_KEY" == "/tmp/id_ecdsa" ]] && [[ "$PLH_BACKUP_PATH" == "/root/pbrain-plane-backups" ]]
}

@test "PLH_VPS_* env overrides the backup config" {
  _write_backup_cfg "root@vps.example" "/tmp/id_ecdsa"
  export PLH_VPS_HOST="root@override.host" PLH_VPS_KEY="/tmp/other"
  pbrain_plh_resolve
  [[ "$PLH_HOST" == "root@override.host" ]] && [[ "$PLH_KEY" == "/tmp/other" ]]
}

@test "probe reports configured=no when no VPS is set" {
  run pbrain_plh_probe
  [[ "$output" == *"configured=no"* ]]
}

@test "probe targets the resolved host over ssh" {
  _write_backup_cfg "root@vps.example" "/tmp/id_ecdsa"
  run pbrain_plh_probe
  [[ "$output" == *"host=root@vps.example"* ]] && [[ "$output" == *"SSH_HOST=root@vps.example"* ]]
}

@test "import without --yes refuses and lists available backups" {
  _write_backup_cfg "root@vps.example" "/tmp/id_ecdsa"
  run pbrain_plh_import latest
  [[ "$output" == *"destructive"* ]] && [[ "$output" == *"plane-20260101-000000.tar.gz"* ]]
}

@test "wire repoints base_url and switches off the browser cookie" {
  cat > "$XDG_CONFIG_HOME/pbrain/plane.json" <<'JSON'
{ "base_url": "http://127.0.0.1:1800", "api_key": "k", "workspace": "ws", "internal_cookie_source": "browser" }
JSON
  pbrain_plh_wire "http://10.0.0.1:1800" "me@example.com" "" >/dev/null
  python3 - "$XDG_CONFIG_HOME/pbrain/plane.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["base_url"] == "http://10.0.0.1:1800", d.get("base_url")
assert d.get("internal_email") == "me@example.com", d.get("internal_email")
assert "internal_cookie_source" not in d, d.get("internal_cookie_source")
print("OK")
PY
}

@test "wire keeps the password out of plane.json on macOS (Keychain)" {
  [[ "$(uname)" == "Darwin" ]] || skip "Keychain path is macOS-only"
  cat > "$XDG_CONFIG_HOME/pbrain/plane.json" <<'JSON'
{ "base_url": "http://127.0.0.1:1800", "api_key": "k", "workspace": "ws" }
JSON
  pbrain_plh_wire "http://10.0.0.1:1800" "me@example.com" "hunter2" >/dev/null
  python3 - "$XDG_CONFIG_HOME/pbrain/plane.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("internal_password_source") == "keychain", d
assert "internal_password" not in d, "plaintext password leaked into plane.json"
assert "hunter2" not in open(sys.argv[1]).read(), "password bytes leaked"
print("OK")
PY
}
