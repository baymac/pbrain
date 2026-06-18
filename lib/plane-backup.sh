#!/usr/bin/env bash
# pbrain Plane backup helpers — sourced by commands/project-manager.sh.
#
# Implements PB-17: a self-contained, scheduled snapshot of a self-hosted Plane
# instance. Plane keeps everything that matters in two Docker volumes:
#
#   * the Postgres data volume  (*_pgdata)   — issues, projects, comments, the lot
#   * the MinIO uploads volume   (*_uploads)  — file attachments
#
# (redis + rabbitmq volumes are ephemeral cache / queue state and are NOT backed
# up.) A snapshot is a single self-describing tarball:
#
#   plane-YYYYMMDD-HHMMSS.tar.gz
#     plane-YYYYMMDD-HHMMSS/
#       db.dump          pg_dump -Fc (custom, compressed) of the Plane database
#       uploads.tar.gz   tar of the MinIO uploads volume
#       manifest.json    timestamps, container/volume/image, byte sizes, sha256s
#
# A logical pg_dump (not a raw volume copy) is used on purpose: it is ~6× smaller,
# version-portable, and restorable with pg_restore. Everything operates directly
# on the running containers/volumes via the Docker CLI — it does NOT need Plane
# wired to pbrain (no plane.json / API token), only Docker + a running Plane.
#
# Destinations (config: ~/.config/pbrain/plane-backup.json):
#   local      ~/.config/pbrain/plane-backups (Time-Machine-covered by default)
#   external   a path on a mounted external volume (/Volumes/<name>/…)
#   vps        rsync/scp to a remote host over ssh (optionally keep a local copy)
#
# Scheduling rides the shared LaunchAgent helper (lib/launchd.sh): a daily
# StartCalendarInterval agent runs `project-manager backup run`.
#
# Like the other lib/ helpers this is best-effort and bash-3.2-safe. The snapshot
# itself returns its real exit status (callers report failures); the ride-along
# helpers never take the command down.

PBK_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pbrain"
PBK_LABEL="com.pbrain.plane-backup"

pbrain_pbk_config_file() { printf '%s\n' "$PBK_CONFIG_DIR/plane-backup.json"; }
pbrain_pbk_log_file()    { printf '%s\n' "$PBK_CONFIG_DIR/plane-backup.log"; }
pbrain_pbk_plist()       { printf '%s\n' "$HOME/Library/LaunchAgents/$PBK_LABEL.plist"; }
pbrain_pbk_default_dir() { printf '%s\n' "$PBK_CONFIG_DIR/plane-backups"; }

pbrain_pbk_docker_running() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

# Pretty-print a byte count. Echoes e.g. "2.04 MB".
pbrain_pbk_human() {
  awk -v b="${1:-0}" 'BEGIN{
    split("B KB MB GB TB",u," "); i=1; x=b+0
    while(x>=1024 && i<5){x/=1024; i++}
    if(i==1) printf "%d %s\n", x, u[i]; else printf "%.2f %s\n", x, u[i]
  }'
}

# Discover the Plane Postgres container, the uploads volume, the DB credentials,
# and an already-present alpine helper image (the postgres image — used for
# volume tar/untar so we never pull anything). Sets PBK_DB_CONTAINER,
# PBK_UPLOADS_VOLUME, PBK_PG_USER, PBK_PG_PASS, PBK_PG_DB, PBK_HELPER_IMAGE.
# Returns 0 when at least the DB container was found, 1 otherwise.
pbrain_pbk_discover() {
  PBK_DB_CONTAINER=""; PBK_UPLOADS_VOLUME=""; PBK_HELPER_IMAGE=""
  PBK_PG_USER="postgres"; PBK_PG_PASS=""; PBK_PG_DB="plane"
  pbrain_pbk_docker_running || return 1

  # Prefer a postgres container whose name mentions plane; else any postgres one.
  local rows
  rows="$(docker ps --format '{{.Names}}	{{.Image}}' 2>/dev/null)"
  PBK_DB_CONTAINER="$(printf '%s\n' "$rows" | awk -F'\t' 'tolower($2) ~ /postgres/ && tolower($1) ~ /plane/ {print $1; exit}')"
  [[ -z "$PBK_DB_CONTAINER" ]] && PBK_DB_CONTAINER="$(printf '%s\n' "$rows" | awk -F'\t' 'tolower($2) ~ /postgres/ {print $1; exit}')"
  [[ -n "$PBK_DB_CONTAINER" ]] || return 1

  PBK_HELPER_IMAGE="$(docker inspect "$PBK_DB_CONTAINER" --format '{{.Config.Image}}' 2>/dev/null)"

  local env_lines u p d
  env_lines="$(docker inspect "$PBK_DB_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null)"
  u="$(printf '%s\n' "$env_lines" | awk -F= '/^POSTGRES_USER=/{print $2}'     | tail -1)"
  p="$(printf '%s\n' "$env_lines" | awk -F= '/^POSTGRES_PASSWORD=/{print $2}' | tail -1)"
  d="$(printf '%s\n' "$env_lines" | awk -F= '/^POSTGRES_DB=/{print $2}'       | tail -1)"
  [[ -n "$u" ]] && PBK_PG_USER="$u"
  [[ -n "$p" ]] && PBK_PG_PASS="$p"
  [[ -n "$d" ]] && PBK_PG_DB="$d"

  # uploads volume: <project>_uploads, prefer one that mentions plane.
  local vols
  vols="$(docker volume ls --format '{{.Name}}' 2>/dev/null)"
  PBK_UPLOADS_VOLUME="$(printf '%s\n' "$vols" | awk 'tolower($0) ~ /_uploads$/ && tolower($0) ~ /plane/ {print; exit}')"
  [[ -z "$PBK_UPLOADS_VOLUME" ]] && PBK_UPLOADS_VOLUME="$(printf '%s\n' "$vols" | awk 'tolower($0) ~ /_uploads$/ {print; exit}')"
  return 0
}

# Load config → shell assignments (caller does: eval "$(pbrain_pbk_load)"). Values
# are shlex-quoted by Python so paths with spaces survive. Missing file → defaults.
pbrain_pbk_load() {
  local f; f="$(pbrain_pbk_config_file)"
  python3 - "$f" <<'PYEOF'
import json, sys, shlex
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
vps = d.get("vps") or {}
def emit(k, v):
    print(k + "=" + shlex.quote("" if v is None else str(v)))
emit("PBK_DEST",         d.get("dest", "local"))
emit("PBK_LOCAL_DIR",    d.get("local_dir", ""))
emit("PBK_EXTERNAL_DIR", d.get("external_dir", ""))
emit("PBK_KEEP",         d.get("keep", 14))
emit("PBK_TIME",         d.get("time", "03:30"))
emit("PBK_VPS_HOST",     vps.get("host", ""))
emit("PBK_VPS_PATH",     vps.get("path", ""))
emit("PBK_VPS_PORT",     vps.get("port", 22))
emit("PBK_VPS_KEY",      vps.get("ssh_key", ""))
emit("PBK_VPS_KEEPLOCAL", vps.get("keep_local_copy", True))
PYEOF
}

# Persist config. Args are key=value; nested vps fields use the vps. prefix
# (vps.host=…). Empty values are ignored (no-op), ints/bools are coerced. 0600.
pbrain_pbk_save() {
  local f; f="$(pbrain_pbk_config_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  python3 - "$f" "$@" <<'PYEOF'
import json, sys, os
f = sys.argv[1]
try:
    d = json.load(open(f))
except Exception:
    d = {}
d.setdefault("vps", {})
def coerce(v):
    if v.lower() in ("true", "false"):
        return v.lower() == "true"
    try:
        return int(v)
    except ValueError:
        return v
for arg in sys.argv[2:]:
    if "=" not in arg:
        continue
    k, v = arg.split("=", 1)
    if v == "":
        continue
    if k.startswith("vps."):
        d["vps"][k[4:]] = coerce(v)
    else:
        d[k] = coerce(v)
fd = os.open(f, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as out:
    json.dump(d, out, indent=2)
    out.write("\n")
try:
    os.chmod(f, 0o600)
except OSError:
    pass
PYEOF
}

# Echo the directory a snapshot should be written into (creating it). For dest=vps
# the snapshot stages in the local dir before upload. Relies on PBK_* being loaded.
pbrain_pbk_resolve_dest_dir() {
  local dir
  case "${PBK_DEST:-local}" in
    external)
      dir="${PBK_EXTERNAL_DIR:-}"
      if [[ -z "$dir" ]]; then echo "PBK_ERR external destination has no path set (backup config --dir <path>)" >&2; return 1; fi
      # The parent (the mount) must already exist — don't silently create a dir on
      # the boot disk when the external volume isn't plugged in.
      if [[ ! -d "$(dirname "$dir")" ]]; then echo "PBK_ERR external volume not mounted: $(dirname "$dir")" >&2; return 1; fi
      ;;
    *)
      dir="${PBK_LOCAL_DIR:-}"; [[ -n "$dir" ]] || dir="$(pbrain_pbk_default_dir)"
      ;;
  esac
  mkdir -p "$dir" 2>/dev/null || { echo "PBK_ERR could not create $dir" >&2; return 1; }
  printf '%s\n' "$dir"
}

# Take one snapshot into <destdir>. Progress → stderr; the created tarball path is
# the only thing on stdout. Returns non-zero on failure (db dump is mandatory).
pbrain_pbk_snapshot() {
  local destdir="${1:?destdir}"
  pbrain_pbk_discover || { echo "PBK_ERR Docker not running or no Plane Postgres container found" >&2; return 1; }

  local stamp stage snapdir
  stamp="$(date +%Y%m%d-%H%M%S)"
  stage="$(mktemp -d "${TMPDIR:-/tmp}/pbk.XXXXXX")" || { echo "PBK_ERR mktemp failed" >&2; return 1; }
  snapdir="$stage/plane-$stamp"
  mkdir -p "$snapdir"

  echo "→ dumping database ($PBK_PG_DB from $PBK_DB_CONTAINER)…" >&2
  if ! docker exec -e PGPASSWORD="$PBK_PG_PASS" "$PBK_DB_CONTAINER" \
        pg_dump -U "$PBK_PG_USER" -h 127.0.0.1 -d "$PBK_PG_DB" -Fc \
        > "$snapdir/db.dump" 2>"$stage/dberr"; then
    echo "PBK_ERR pg_dump failed: $(cat "$stage/dberr" 2>/dev/null)" >&2
    rm -rf "$stage"; return 1
  fi
  local db_bytes; db_bytes="$(wc -c < "$snapdir/db.dump" | tr -d ' ')"

  local up_bytes=0
  if [[ -n "$PBK_UPLOADS_VOLUME" ]]; then
    echo "→ archiving uploads ($PBK_UPLOADS_VOLUME)…" >&2
    if docker run --rm -v "$PBK_UPLOADS_VOLUME":/data:ro "$PBK_HELPER_IMAGE" \
         sh -c 'tar czf - -C /data . 2>/dev/null' > "$snapdir/uploads.tar.gz" 2>/dev/null; then
      up_bytes="$(wc -c < "$snapdir/uploads.tar.gz" | tr -d ' ')"
    else
      echo "PBK_WARN could not archive uploads volume — continuing with DB only" >&2
      rm -f "$snapdir/uploads.tar.gz"
    fi
  else
    echo "PBK_WARN no uploads volume found — DB-only snapshot" >&2
  fi

  local db_sha up_sha
  db_sha="$(_pbrain_file_hash "$snapdir/db.dump" 2>/dev/null || true)"
  [[ -f "$snapdir/uploads.tar.gz" ]] && up_sha="$(_pbrain_file_hash "$snapdir/uploads.tar.gz" 2>/dev/null || true)" || up_sha=""

  cat > "$snapdir/manifest.json" <<JSON
{
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "tool": "pbrain /project-manager backup",
  "db_container": "$PBK_DB_CONTAINER",
  "db_name": "$PBK_PG_DB",
  "db_user": "$PBK_PG_USER",
  "uploads_volume": "$PBK_UPLOADS_VOLUME",
  "helper_image": "$PBK_HELPER_IMAGE",
  "db_dump_bytes": ${db_bytes:-0},
  "uploads_bytes": ${up_bytes:-0},
  "db_dump_sha256": "${db_sha:-}",
  "uploads_sha256": "${up_sha:-}"
}
JSON

  local out="$destdir/plane-$stamp.tar.gz"
  if ! tar czf "$out" -C "$stage" "plane-$stamp" 2>/dev/null; then
    echo "PBK_ERR could not write tarball $out" >&2
    rm -rf "$stage"; return 1
  fi
  rm -rf "$stage"
  echo "$out"
}

# Delete all but the newest <keep> snapshots in <dir>. keep<=0 disables pruning.
pbrain_pbk_prune() {
  local dir="${1:-}" keep="${2:-14}"
  [[ -d "$dir" ]] || return 0
  case "$keep" in ''|*[!0-9]*) return 0 ;; esac
  [[ "$keep" -gt 0 ]] || return 0
  local f
  ls -1t "$dir"/plane-*.tar.gz 2>/dev/null | tail -n +"$((keep + 1))" | while IFS= read -r f; do
    [[ -n "$f" ]] && rm -f "$f" 2>/dev/null && echo "pruned $(basename "$f")" >&2 || true
  done
  return 0
}

# Upload one snapshot file to the configured VPS over ssh. rsync if present, else
# scp. Non-interactive (BatchMode) so a headless run can't hang on a password.
# Relies on PBK_VPS_* being loaded. Returns the transfer's exit status.
pbrain_pbk_upload_vps() {
  local file="${1:?file}"
  [[ -n "${PBK_VPS_HOST:-}" && -n "${PBK_VPS_PATH:-}" ]] || {
    echo "PBK_ERR vps destination needs host + path (backup config --vps-host … --vps-path …)" >&2; return 1; }
  local port="${PBK_VPS_PORT:-22}"
  local sshcmd="ssh -p $port -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
  [[ -n "${PBK_VPS_KEY:-}" ]] && sshcmd="$sshcmd -i ${PBK_VPS_KEY}"
  echo "→ uploading $(basename "$file") to ${PBK_VPS_HOST}:${PBK_VPS_PATH}…" >&2
  $sshcmd "$PBK_VPS_HOST" "mkdir -p $(printf '%q' "$PBK_VPS_PATH")" 2>/dev/null || true
  if command -v rsync >/dev/null 2>&1; then
    rsync -az -e "$sshcmd" "$file" "${PBK_VPS_HOST}:${PBK_VPS_PATH}/"
  else
    scp -P "$port" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      ${PBK_VPS_KEY:+-i "$PBK_VPS_KEY"} "$file" "${PBK_VPS_HOST}:${PBK_VPS_PATH}/"
  fi
}

# Measure a real, current snapshot size without writing one. Prints a machine line
# plus a human read; projects the retention footprint. Relies on PBK_KEEP loaded.
pbrain_pbk_estimate() {
  pbrain_pbk_discover || { echo "PBK_ERR Docker not running or no Plane Postgres container found"; return 1; }
  local db_bytes up_bytes
  db_bytes="$(docker exec -e PGPASSWORD="$PBK_PG_PASS" "$PBK_DB_CONTAINER" \
      pg_dump -U "$PBK_PG_USER" -h 127.0.0.1 -d "$PBK_PG_DB" -Fc 2>/dev/null | wc -c | tr -d ' ')"
  db_bytes="${db_bytes:-0}"
  up_bytes=0
  if [[ -n "$PBK_UPLOADS_VOLUME" ]]; then
    up_bytes="$(docker run --rm -v "$PBK_UPLOADS_VOLUME":/data:ro "$PBK_HELPER_IMAGE" \
        sh -c 'tar czf - -C /data . 2>/dev/null | wc -c' 2>/dev/null | tr -d ' ')"
    up_bytes="${up_bytes:-0}"
  fi
  local total=$((db_bytes + up_bytes))
  local keep="${PBK_KEEP:-14}"
  case "$keep" in ''|*[!0-9]*) keep=14 ;; esac
  echo "PBK_ESTIMATE db_bytes=$db_bytes uploads_bytes=$up_bytes per_snapshot_bytes=$total keep=$keep retained_bytes=$((total * keep))"
  echo "  database (pg_dump -Fc): $(pbrain_pbk_human "$db_bytes")"
  echo "  uploads  (tar.gz):      $(pbrain_pbk_human "$up_bytes")"
  echo "  per daily snapshot:     $(pbrain_pbk_human "$total")"
  echo "  × $keep-day retention:  $(pbrain_pbk_human "$((total * keep))")"
}

# Restore a snapshot tarball into the live Plane (DESTRUCTIVE — overwrites the DB
# and wipes the uploads volume). Requires --yes. Relies on discovery.
pbrain_pbk_restore() {
  local file="${1:-}" confirmed="${2:-}"
  [[ -f "$file" ]] || { echo "PBK_ERR snapshot not found: $file" >&2; return 1; }
  [[ "$confirmed" == "--yes" ]] || { echo "PBK_ERR restore is destructive — re-run with --yes to proceed" >&2; return 1; }
  pbrain_pbk_discover || { echo "PBK_ERR Docker not running or no Plane Postgres container found" >&2; return 1; }

  local work; work="$(mktemp -d "${TMPDIR:-/tmp}/pbk.XXXXXX")" || return 1
  if ! tar xzf "$file" -C "$work" 2>/dev/null; then echo "PBK_ERR could not unpack $file" >&2; rm -rf "$work"; return 1; fi
  local snap; snap="$(find "$work" -maxdepth 1 -type d -name 'plane-*' | head -1)"
  [[ -n "$snap" && -f "$snap/db.dump" ]] || { echo "PBK_ERR snapshot has no db.dump" >&2; rm -rf "$work"; return 1; }

  echo "→ restoring database into $PBK_PG_DB (drop + recreate objects)…" >&2
  docker exec -i -e PGPASSWORD="$PBK_PG_PASS" "$PBK_DB_CONTAINER" \
    pg_restore --clean --if-exists --no-owner -U "$PBK_PG_USER" -h 127.0.0.1 -d "$PBK_PG_DB" \
    < "$snap/db.dump" 2>"$work/err" || echo "PBK_WARN pg_restore reported: $(tail -3 "$work/err" 2>/dev/null)" >&2

  if [[ -f "$snap/uploads.tar.gz" && -n "$PBK_UPLOADS_VOLUME" ]]; then
    echo "→ restoring uploads volume…" >&2
    docker run --rm -i -v "$PBK_UPLOADS_VOLUME":/data "$PBK_HELPER_IMAGE" \
      sh -c 'rm -rf /data/* /data/..?* 2>/dev/null; tar xzf - -C /data' < "$snap/uploads.tar.gz" 2>/dev/null \
      || echo "PBK_WARN could not restore uploads" >&2
  fi
  rm -rf "$work"
  echo "PBK_RESTORED $file" >&2
  echo "Restart Plane workers to pick up the restored data: cd <plane dir> && docker compose restart" >&2
}

# Install the daily LaunchAgent (StartCalendarInterval) that runs `backup run`.
# Args: <project_manager_sh_abs_path> <HH:MM>. PATH includes docker's dir (launchd
# starts with a bare PATH). Best-effort via the shared launchd helper.
pbrain_pbk_schedule_install() {
  local pm_sh="${1:?project-manager.sh path}" hhmm="${2:-03:30}"
  local hh="${hhmm%%:*}" mm="${hhmm##*:}"
  hh=$((10#${hh:-3})); mm=$((10#${mm:-30}))
  local docker_dir=""; command -v docker >/dev/null 2>&1 && docker_dir="$(dirname "$(command -v docker)")"
  local pathval="${docker_dir:+$docker_dir:}/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  local extra
  extra="  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>$hh</integer>
    <key>Minute</key><integer>$mm</integer>
  </dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$(_pbrain_xml_escape "$pathval")</string>
  </dict>"
  pbrain_launchagent_install "$PBK_LABEL" "$(pbrain_pbk_plist)" "$(pbrain_pbk_log_file)" "$extra" \
    -- /bin/bash "$pm_sh" backup run
}

pbrain_pbk_schedule_uninstall() {
  pbrain_launchagent_uninstall "$PBK_LABEL" "$(pbrain_pbk_plist)"
}
