#!/usr/bin/env bats
# Tests for the Plane backup feature (PB-17): lib/plane-backup.sh + the
# `/project-manager backup` dispatch. No real Docker — a stub fakes the few
# `docker` calls discovery/estimate/snapshot make, so the whole plumbing
# (discover → dump → tar → manifest → prune → config → schedule) is exercised
# end-to-end. launchctl is stubbed too so no real LaunchAgent is installed.
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
  export PBRAIN_VAULT="$TMP/vault"; mkdir -p "$PBRAIN_VAULT"
  export HOME="$TMP/home"; mkdir -p "$HOME/Library/LaunchAgents"

  # --- docker stub: simulates a running Plane Postgres + uploads volume --------
  STUB="$TMP/bin"; mkdir -p "$STUB"
  cat > "$STUB/docker" <<'DOCK'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  ps) printf 'myplane-db-1\tpostgres:15.7-alpine\n' ;;
  volume) printf 'myplane_pgdata\nmyplane_uploads\nmyplane_redisdata\n' ;;
  inspect)
    fmt="$4"
    if [[ "$fmt" == *Config.Image* ]]; then echo "postgres:15.7-alpine"
    elif [[ "$fmt" == *Config.Env* ]]; then
      printf 'POSTGRES_USER=plane\nPOSTGRES_PASSWORD=s3cret\nPOSTGRES_DB=plane\n'
    fi ;;
  exec)
    # any pg_dump → emit deterministic fake archive bytes
    for a in "$@"; do [[ "$a" == pg_dump ]] && { printf 'PGDUMPDATA-0123456789'; exit 0; }; done
    exit 0 ;;
  run)
    # estimate path asks for a byte count (wc -c); snapshot wants raw tar bytes
    for a in "$@"; do [[ "$a" == *"wc -c"* ]] && { echo 4096; exit 0; }; done
    printf 'UPLOADSTARDATA-abcdef' ; exit 0 ;;
  *) exit 0 ;;
esac
DOCK
  chmod +x "$STUB/docker"
  # `print` reports "not loaded" (exit 1) so status/probe show scheduled:no;
  # bootstrap/bootout no-op. (We assert on the plist file, not launchd state.)
  printf '#!/usr/bin/env bash\n[[ "$1" == print ]] && exit 1\nexit 0\n' > "$STUB/launchctl"; chmod +x "$STUB/launchctl"

  PM() { env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/project-manager.sh" "$@"; }
}
teardown() { rm -rf "$TMP"; }

# --- estimate ----------------------------------------------------------------
@test "backup estimate measures db + uploads and projects retention" {
  run PM backup estimate
  [ "$status" -eq 0 ]
  [[ "$output" == *PM_BACKUP_ESTIMATE* ]] && [[ "$output" == *PBK_ESTIMATE* ]] \
    && [[ "$output" == *"per_snapshot_bytes="* ]] && [[ "$output" == *"retained_bytes="* ]]
}

@test "backup estimate degrades cleanly when Docker is not running" {
  NODOCK="$TMP/nodock"; mkdir -p "$NODOCK"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$NODOCK/docker"; chmod +x "$NODOCK/docker"
  run env PATH="$NODOCK:$PATH" bash "$REPO_ROOT/commands/project-manager.sh" backup estimate
  [ "$status" -eq 0 ] && [[ "$output" == *"PBK_ERR"* ]]
}

# --- snapshot (backup now) ---------------------------------------------------
@test "backup now writes a self-describing tarball into --dir" {
  D="$TMP/snaps"
  run PM backup now --dir "$D"
  [ "$status" -eq 0 ]
  f="$(ls "$D"/plane-*.tar.gz 2>/dev/null | head -1)"
  [ -n "$f" ]
  members="$(tar tzf "$f")"
  [[ "$members" == *db.dump* ]] && [[ "$members" == *uploads.tar.gz* ]] && [[ "$members" == *manifest.json* ]]
}

@test "snapshot manifest records container, volume and byte sizes" {
  D="$TMP/snaps"; PM backup now --dir "$D" >/dev/null
  f="$(ls "$D"/plane-*.tar.gz | head -1)"; ex="$TMP/ex"; mkdir -p "$ex"; tar xzf "$f" -C "$ex"
  man="$(cat "$ex"/plane-*/manifest.json)"
  [[ "$man" == *'"db_container": "myplane-db-1"'* ]] && [[ "$man" == *'"uploads_volume": "myplane_uploads"'* ]] \
    && [[ "$man" == *'"db_dump_bytes": 2'* ]]
}

# --- config persistence ------------------------------------------------------
@test "backup config writes dest/keep/time + nested vps to a 0600 json" {
  run PM backup config --dest vps --vps-host deploy@host --vps-path /srv/bk --vps-port 2222 --keep 30 --time 04:15
  [ "$status" -eq 0 ]
  cfg="$XDG_CONFIG_HOME/pbrain/plane-backup.json"
  perm="$(stat -f '%Lp' "$cfg" 2>/dev/null || stat -c '%a' "$cfg")"
  grep -q '"dest": "vps"' "$cfg" && grep -q '"host": "deploy@host"' "$cfg" \
    && grep -q '"keep": 30' "$cfg" && grep -q '"time": "04:15"' "$cfg" && [ "$perm" = "600" ]
}

@test "external dest stores its own dir under external_dir" {
  run PM backup config --dest external --dir /Volumes/Backup/plane
  [ "$status" -eq 0 ]
  grep -q '"external_dir": "/Volumes/Backup/plane"' "$XDG_CONFIG_HOME/pbrain/plane-backup.json"
}

# --- schedule install / disable ---------------------------------------------
@test "backup enable writes a daily LaunchAgent plist with the chosen time" {
  run PM backup enable --time 02:30 --keep 7
  [ "$status" -eq 0 ]
  plist="$HOME/Library/LaunchAgents/com.pbrain.plane-backup.plist"
  [ -f "$plist" ]
  grep -q '<integer>2</integer>' "$plist" && grep -q '<integer>30</integer>' "$plist" \
    && grep -q '<string>backup</string>' "$plist" && grep -q '<string>run</string>' "$plist"
}

@test "backup disable removes the plist" {
  PM backup enable --time 02:30 >/dev/null
  plist="$HOME/Library/LaunchAgents/com.pbrain.plane-backup.plist"
  [ -f "$plist" ]
  run PM backup disable
  [ "$status" -eq 0 ] && [ ! -f "$plist" ] && [[ "$output" == *PM_BACKUP_DISABLE* ]]
}

# --- retention prune (unit, via the lib directly) ---------------------------
@test "prune keeps only the newest N snapshots" {
  source "$REPO_ROOT/lib/launchd.sh"
  source "$REPO_ROOT/lib/plane-backup.sh"
  D="$TMP/prune"; mkdir -p "$D"
  for s in 20260101-000000 20260102-000000 20260103-000000 20260104-000000 20260105-000000; do
    echo x > "$D/plane-$s.tar.gz"; touch -t "${s%-*}0000" "$D/plane-$s.tar.gz" 2>/dev/null || true
  done
  pbrain_pbk_prune "$D" 2
  n="$(ls -1 "$D"/plane-*.tar.gz | wc -l | tr -d ' ')"
  [ "$n" -eq 2 ] && [ -f "$D/plane-20260105-000000.tar.gz" ] && [ ! -f "$D/plane-20260101-000000.tar.gz" ]
}

@test "prune is a no-op when keep is 0 or non-numeric" {
  source "$REPO_ROOT/lib/launchd.sh"
  source "$REPO_ROOT/lib/plane-backup.sh"
  D="$TMP/prune2"; mkdir -p "$D"; echo x > "$D/plane-20260101-000000.tar.gz"
  pbrain_pbk_prune "$D" 0
  pbrain_pbk_prune "$D" abc
  [ -f "$D/plane-20260101-000000.tar.gz" ]
}

# --- status + list -----------------------------------------------------------
@test "backup status reports schedule/destination/retention with defaults" {
  run PM backup status
  [ "$status" -eq 0 ]
  [[ "$output" == *PM_BACKUP_STATUS* ]] && [[ "$output" == *"destination: local"* ]] \
    && [[ "$output" == *"retention: keep 14"* ]] && [[ "$output" == *"scheduled: no"* ]]
}

@test "backup restore refuses without --yes" {
  D="$TMP/snaps"; PM backup now --dir "$D" >/dev/null
  f="$(ls "$D"/plane-*.tar.gz | head -1)"
  run PM backup restore "$f"
  [ "$status" -eq 0 ] && [[ "$output" == *"re-run with --yes"* ]]
}

# --- probe exposes backup state ---------------------------------------------
@test "probe surfaces backup_scheduled / backup_dest keys for the wizard" {
  run PM probe
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup_scheduled:"* ]] && [[ "$output" == *"backup_dest:"* ]] && [[ "$output" == *"backup_time:"* ]]
}
