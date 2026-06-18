#!/usr/bin/env bats
# Tests for the vault backup feature (PB-10): lib/vault-backup.sh + the
# /vault-backup command dispatch. No real Docker (it tars the vault directory);
# launchctl, ssh and rsync are stubbed so no agent is installed and no transfer
# is attempted, and swiftc/osascript are stubbed so the stale-notify path is a
# quiet no-op. The whole plumbing (snapshot → manifest → prune → config → VPS
# inheritance → schedule → restore → log → stale) is exercised end-to-end.
#
# NB: bats only enforces the LAST command of each @test, so must-hold checks are
# chained with && into one final line.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0 PBRAIN_UPDATE_CHECK=0 PBRAIN_SELF_IMPROVE=off PBRAIN_NO_AUTOVAULT=1
  export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/pbrain"
  export HOME="$TMP/home"; mkdir -p "$HOME/Library/LaunchAgents"
  export PBRAIN_VAULT="$TMP/vault"; mkdir -p "$PBRAIN_VAULT/life" "$PBRAIN_VAULT/.pbrain"
  printf 'note one\n' > "$PBRAIN_VAULT/life/a.md"
  printf 'note two\n' > "$PBRAIN_VAULT/b.md"
  printf 'junk\n'     > "$PBRAIN_VAULT/.DS_Store"

  STUB="$TMP/bin"; mkdir -p "$STUB"
  # launchctl: `print` reports not-loaded (exit 1) so status shows scheduled:no;
  # bootstrap/bootout no-op. We assert on the plist file, not launchd state.
  printf '#!/usr/bin/env bash\n[[ "$1" == print ]] && exit 1\nexit 0\n' > "$STUB/launchctl"; chmod +x "$STUB/launchctl"
  # ssh/rsync/scp: record args, never touch the network.
  printf '#!/usr/bin/env bash\necho "rsync $*" >> "%s/transfer.log"\nexit 0\n' "$TMP" > "$STUB/rsync"; chmod +x "$STUB/rsync"
  printf '#!/usr/bin/env bash\necho "ssh $*" >> "%s/transfer.log"\nexit 0\n' "$TMP" > "$STUB/ssh"; chmod +x "$STUB/ssh"
  printf '#!/usr/bin/env bash\necho "scp $*" >> "%s/transfer.log"\nexit 0\n' "$TMP" > "$STUB/scp"; chmod +x "$STUB/scp"
  # swiftc/osascript absent-ish: make the stale-notify path a no-op.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/swiftc"; chmod +x "$STUB/swiftc"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/osascript"; chmod +x "$STUB/osascript"

  VB() { env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/vault-backup.sh" "$@"; }
}
teardown() { rm -rf "$TMP"; }

# --- estimate ----------------------------------------------------------------
@test "estimate measures the vault tarball and projects retention" {
  run VB estimate
  [ "$status" -eq 0 ]
  [[ "$output" == *VBK_ESTIMATE* ]] && [[ "$output" == *"per_snapshot_bytes="* ]] \
    && [[ "$output" == *"retained_bytes="* ]]
}

# --- snapshot (now) ----------------------------------------------------------
@test "now writes a self-describing tarball with manifest + the vault tree" {
  D="$TMP/snaps"
  run VB now --dir "$D"
  [ "$status" -eq 0 ]
  f="$(ls "$D"/vault-*.tar.gz 2>/dev/null | head -1)"
  [ -n "$f" ]
  members="$(tar tzf "$f")"
  [[ "$members" == *manifest.json* ]] && [[ "$members" == *vault/life/a.md* ]] && [[ "$members" == *vault/b.md* ]]
}

@test "now honours excludes (.DS_Store is not in the tarball)" {
  D="$TMP/snaps"; VB now --dir "$D" >/dev/null
  f="$(ls "$D"/vault-*.tar.gz | head -1)"
  ! tar tzf "$f" | grep -q '\.DS_Store'
}

@test "snapshot manifest records the vault path and file count" {
  D="$TMP/snaps"; VB now --dir "$D" >/dev/null
  f="$(ls "$D"/vault-*.tar.gz | head -1)"; ex="$TMP/ex"; mkdir -p "$ex"; tar xzf "$f" -C "$ex"
  man="$(cat "$ex/manifest.json")"
  [[ "$man" == *'"vault_path": "'"$PBRAIN_VAULT"'"'* ]] && [[ "$man" == *'"file_count":'* ]] && [[ "$man" == *'"tool": "pbrain /vault-backup"'* ]]
}

@test "now appends an ok line to vault/.pbrain/backup-log.md" {
  D="$TMP/snaps"; VB now --dir "$D" >/dev/null
  logf="$PBRAIN_VAULT/.pbrain/backup-log.md"
  [ -f "$logf" ] && grep -qE $'\tok\t' "$logf"
}

# --- config persistence ------------------------------------------------------
@test "config writes dest/keep/time + nested vps to a 0600 json" {
  run VB config --dest vps --vps-host deploy@host --vps-path /srv/vbk --vps-port 2222 --keep 30 --time 04:15
  [ "$status" -eq 0 ]
  cfg="$XDG_CONFIG_HOME/pbrain/vault-backup.json"
  perm="$(stat -f '%Lp' "$cfg" 2>/dev/null || stat -c '%a' "$cfg")"
  grep -q '"dest": "vps"' "$cfg" && grep -q '"host": "deploy@host"' "$cfg" \
    && grep -q '"keep": 30' "$cfg" && grep -q '"time": "04:15"' "$cfg" && [ "$perm" = "600" ]
}

@test "external dest stores its own dir under external_dir" {
  run VB config --dest external --dir /Volumes/Backup/vault
  [ "$status" -eq 0 ]
  grep -q '"external_dir": "/Volumes/Backup/vault"' "$XDG_CONFIG_HOME/pbrain/vault-backup.json"
}

# --- VPS credential inheritance from the Plane backup (PB-10's "same VPS") ----
@test "vps host/port/key are inherited from plane-backup.json; path stays distinct" {
  cat > "$XDG_CONFIG_HOME/pbrain/plane-backup.json" <<'J'
{ "vps": { "host": "user@vps.example.com", "path": "/home/user/plane-backups", "port": 2222, "ssh_key": "/Users/u/.ssh/id_ed25519" } }
J
  source "$REPO_ROOT/lib/vault-backup.sh"
  eval "$(pbrain_vbk_load)"
  [ "$VBK_VPS_HOST" = "user@vps.example.com" ] && [ "$VBK_VPS_PORT" = "2222" ] \
    && [ "$VBK_VPS_KEY" = "/Users/u/.ssh/id_ed25519" ] && [ "$VBK_VPS_PATH" = "/home/user/vault-backups" ]
}

@test "an explicit vault vps path overrides the inherited default" {
  cat > "$XDG_CONFIG_HOME/pbrain/plane-backup.json" <<'J'
{ "vps": { "host": "user@vps.example.com", "path": "/home/user/plane-backups" } }
J
  VB config --vps-path /custom/vault/dir >/dev/null
  source "$REPO_ROOT/lib/vault-backup.sh"
  eval "$(pbrain_vbk_load)"
  [ "$VBK_VPS_HOST" = "user@vps.example.com" ] && [ "$VBK_VPS_PATH" = "/custom/vault/dir" ]
}

# --- schedule install / disable ---------------------------------------------
@test "enable writes a daily LaunchAgent plist running the headless 'run'" {
  run VB enable --time 02:30 --keep 7
  [ "$status" -eq 0 ]
  plist="$HOME/Library/LaunchAgents/com.pbrain.vault-backup.plist"
  [ -f "$plist" ]
  grep -q '<integer>2</integer>' "$plist" && grep -q '<integer>30</integer>' "$plist" \
    && grep -q '<string>run</string>' "$plist" && grep -q 'vault-backup.sh' "$plist"
}

@test "disable removes the plist" {
  VB enable --time 02:30 >/dev/null
  plist="$HOME/Library/LaunchAgents/com.pbrain.vault-backup.plist"
  [ -f "$plist" ]
  run VB disable
  [ "$status" -eq 0 ] && [ ! -f "$plist" ] && [[ "$output" == *VBK_DISABLE* ]]
}

# --- VPS upload path (run with dest=vps) ------------------------------------
@test "a vps backup uploads via rsync and logs the destination" {
  VB config --dest vps --vps-host user@host --vps-path /srv/vbk >/dev/null
  run VB now
  [ "$status" -eq 0 ]
  [[ "$output" == *"uploaded to user@host:/srv/vbk"* ]] && grep -q 'rsync' "$TMP/transfer.log"
}

# --- retention prune (unit, via the lib directly) ---------------------------
@test "prune keeps only the newest N snapshots" {
  source "$REPO_ROOT/lib/vault-backup.sh"
  D="$TMP/prune"; mkdir -p "$D"
  for s in 20260101-000000 20260102-000000 20260103-000000 20260104-000000 20260105-000000; do
    echo x > "$D/vault-$s.tar.gz"; touch -t "${s%-*}0000" "$D/vault-$s.tar.gz" 2>/dev/null || true
  done
  pbrain_vbk_prune "$D" 2
  n="$(ls -1 "$D"/vault-*.tar.gz | wc -l | tr -d ' ')"
  [ "$n" -eq 2 ] && [ -f "$D/vault-20260105-000000.tar.gz" ] && [ ! -f "$D/vault-20260101-000000.tar.gz" ]
}

@test "prune is a no-op when keep is 0 or non-numeric" {
  source "$REPO_ROOT/lib/vault-backup.sh"
  D="$TMP/prune2"; mkdir -p "$D"; echo x > "$D/vault-20260101-000000.tar.gz"
  pbrain_vbk_prune "$D" 0
  pbrain_vbk_prune "$D" abc
  [ -f "$D/vault-20260101-000000.tar.gz" ]
}

# --- status ------------------------------------------------------------------
@test "status reports schedule/destination/retention with defaults" {
  run VB status
  [ "$status" -eq 0 ]
  [[ "$output" == *VBK_STATUS* ]] && [[ "$output" == *"destination: local"* ]] \
    && [[ "$output" == *"retention: keep 14"* ]] && [[ "$output" == *"scheduled: no"* ]] \
    && [[ "$output" == *"last good backup: none recorded"* ]]
}

# --- restore (non-destructive) ----------------------------------------------
@test "restore extracts a snapshot into --into without touching the live vault" {
  D="$TMP/snaps"; VB now --dir "$D" >/dev/null
  f="$(ls "$D"/vault-*.tar.gz | head -1)"
  run VB restore "$f" --into "$TMP/out"
  [ "$status" -eq 0 ]
  [ -f "$TMP/out/manifest.json" ] && [ -f "$TMP/out/vault/b.md" ]
}

@test "restore refuses to extract over the live vault without --yes" {
  VB now >/dev/null   # default local dir, so `latest` resolves there
  run VB restore latest --into "$PBRAIN_VAULT"
  [ "$status" -eq 0 ] && [[ "$output" == *"refusing to extract over the live vault"* ]]
}

# --- staleness check ---------------------------------------------------------
@test "check notifies when the last good backup is older than the threshold" {
  source "$REPO_ROOT/lib/vault-backup.sh"
  export VAULT_DIR="$PBRAIN_VAULT"
  pbrain_notify() { echo "NOTIFY:$1" >> "$TMP/notify.log"; }
  printf -- '- 2026-06-01T00:00:00Z\tok\told.tar.gz\n' > "$PBRAIN_VAULT/.pbrain/backup-log.md"
  out="$(pbrain_vbk_check_stale 48)"
  [[ "$out" == *VBK_STALE* ]] && grep -q 'NOTIFY:Vault backup stale' "$TMP/notify.log"
}

@test "check is fresh right after a backup" {
  source "$REPO_ROOT/lib/vault-backup.sh"
  export VAULT_DIR="$PBRAIN_VAULT"
  pbrain_notify() { :; }
  printf -- '- %s\tok\tnew.tar.gz\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$PBRAIN_VAULT/.pbrain/backup-log.md"
  out="$(pbrain_vbk_check_stale 48)"
  [[ "$out" == *VBK_FRESH* ]]
}
