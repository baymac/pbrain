#!/usr/bin/env bash
# pbrain vault backup helpers — sourced by commands/vault-backup.sh.
#
# Implements PB-10: an automated, scheduled, off-iCloud snapshot of the Obsidian
# vault. iCloud Drive gives the vault cross-device SYNC, not a backup — a bad
# sync, an accidental delete, or an account problem propagates everywhere. This
# keeps an independent copy somewhere iCloud can't reach.
#
# It is a deliberate sibling of lib/plane-backup.sh (PB-17): same shape — nightly
# tarball, local / external-volume / VPS-over-rsync destinations, N-day retention
# pruning, a daily LaunchAgent — with three domain-forced differences:
#
#   1. The source is the vault directory ($VAULT_DIR), not Docker. A snapshot is
#      a single self-describing tarball:
#
#        vault-YYYYMMDD-HHMMSS.tar.gz
#          manifest.json   created-at, vault path, file count, total bytes, git HEAD
#          <vaultbase>/...  the whole vault tree (honouring VBK_EXCLUDES)
#
#   2. VPS credentials are INHERITED from the Plane backup (PB-17) so the user
#      never re-enters them: any unset vps host/port/ssh_key in vault-backup.json
#      falls back to plane-backup.json's `vps` block. The remote PATH stays
#      distinct (vault tarballs must not land in the Plane snapshot dir) — it
#      defaults to a `vault-backups` dir alongside the Plane one.
#
#   3. Restore is NON-DESTRUCTIVE: it extracts a snapshot into a chosen directory
#      (--into <dir>), never silently overwriting the live iCloud vault.
#
# Plus PB-10's two extras: every run appends to vault/.pbrain/backup-log.md, and a
# staleness check fires a macOS notification when the last good backup is >48h old.
#
# Scheduling rides the shared LaunchAgent helper (lib/launchd.sh): a daily
# StartCalendarInterval agent runs `vault-backup.sh run`.
#
# Like the other lib/ helpers this is best-effort and bash-3.2-safe. The snapshot
# itself returns its real exit status (callers report failures); the ride-along
# helpers (log, stale-check) never take the command down.

VBK_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pbrain"
VBK_LABEL="com.pbrain.vault-backup"

pbrain_vbk_config_file()       { printf '%s\n' "$VBK_CONFIG_DIR/vault-backup.json"; }
pbrain_vbk_plane_config_file() { printf '%s\n' "$VBK_CONFIG_DIR/plane-backup.json"; }
pbrain_vbk_log_file()          { printf '%s\n' "$VBK_CONFIG_DIR/vault-backup.log"; }
pbrain_vbk_plist()             { printf '%s\n' "$HOME/Library/LaunchAgents/$VBK_LABEL.plist"; }
pbrain_vbk_default_dir()       { printf '%s\n' "$VBK_CONFIG_DIR/vault-backups"; }

# Pretty-print a byte count. Echoes e.g. "2.04 MB".
pbrain_vbk_human() {
  awk -v b="${1:-0}" 'BEGIN{
    split("B KB MB GB TB",u," "); i=1; x=b+0
    while(x>=1024 && i<5){x/=1024; i++}
    if(i==1) printf "%d %s\n", x, u[i]; else printf "%.2f %s\n", x, u[i]
  }'
}

# Load config → shell assignments (caller does: eval "$(pbrain_vbk_load)"). Values
# are shlex-quoted by Python so paths with spaces survive. Missing file → defaults.
# VPS host/port/ssh_key fall back to plane-backup.json's vps block when unset
# (PB-10 reuses the same VPS as PB-17); the remote PATH does NOT inherit — when
# unset it defaults to a `vault-backups` dir alongside the Plane path.
pbrain_vbk_load() {
  local f pf; f="$(pbrain_vbk_config_file)"; pf="$(pbrain_vbk_plane_config_file)"
  python3 - "$f" "$pf" <<'PYEOF'
import json, sys, shlex, posixpath
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
try:
    pd = json.load(open(sys.argv[2]))
except Exception:
    pd = {}
vps  = d.get("vps") or {}
pvps = pd.get("vps") or {}
def emit(k, v):
    print(k + "=" + shlex.quote("" if v is None else str(v)))
emit("VBK_DEST",         d.get("dest", "local"))
emit("VBK_LOCAL_DIR",    d.get("local_dir", ""))
emit("VBK_EXTERNAL_DIR", d.get("external_dir", ""))
emit("VBK_KEEP",         d.get("keep", 14))
emit("VBK_TIME",         d.get("time", "03:45"))
emit("VBK_EXCLUDES",     d.get("excludes", ".DS_Store"))
# host / port / ssh_key: vault config wins, else inherit from the Plane backup.
emit("VBK_VPS_HOST", vps.get("host") or pvps.get("host", ""))
emit("VBK_VPS_PORT", vps.get("port") or pvps.get("port", 22))
emit("VBK_VPS_KEY",  vps.get("ssh_key") or pvps.get("ssh_key", ""))
# path: vault config only; else a distinct dir alongside the Plane path.
path = vps.get("path", "")
if not path:
    pp = pvps.get("path", "")
    if pp:
        path = posixpath.join(posixpath.dirname(pp.rstrip("/")) or ".", "vault-backups")
emit("VBK_VPS_PATH", path)
emit("VBK_VPS_KEEPLOCAL", vps.get("keep_local_copy", True))
PYEOF
}

# Persist config. Args are key=value; nested vps fields use the vps. prefix
# (vps.host=…). Empty values are ignored (no-op), ints/bools are coerced. 0600.
pbrain_vbk_save() {
  local f; f="$(pbrain_vbk_config_file)"
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
# the snapshot stages in the local dir before upload. Relies on VBK_* being loaded.
pbrain_vbk_resolve_dest_dir() {
  local dir
  case "${VBK_DEST:-local}" in
    external)
      dir="${VBK_EXTERNAL_DIR:-}"
      if [[ -z "$dir" ]]; then echo "VBK_ERR external destination has no path set (config --dir <path>)" >&2; return 1; fi
      # The parent (the mount) must already exist — don't silently create a dir on
      # the boot disk when the external volume isn't plugged in.
      if [[ ! -d "$(dirname "$dir")" ]]; then echo "VBK_ERR external volume not mounted: $(dirname "$dir")" >&2; return 1; fi
      ;;
    *)
      dir="${VBK_LOCAL_DIR:-}"; [[ -n "$dir" ]] || dir="$(pbrain_vbk_default_dir)"
      ;;
  esac
  mkdir -p "$dir" 2>/dev/null || { echo "VBK_ERR could not create $dir" >&2; return 1; }
  printf '%s\n' "$dir"
}

# Build the tar --exclude arg list from VBK_EXCLUDES (space-separated patterns).
# Echoes one --exclude=<pat> token per line (caller reads into an array).
_pbrain_vbk_exclude_args() {
  local pat
  for pat in ${VBK_EXCLUDES:-.DS_Store}; do
    [[ -n "$pat" ]] && printf -- '--exclude=%s\n' "$pat"
  done
}

# Take one snapshot into <destdir>. Progress → stderr; the created tarball path is
# the only thing on stdout. Returns non-zero on failure. Needs $VAULT_DIR.
pbrain_vbk_snapshot() {
  local destdir="${1:?destdir}"
  local vault="${VAULT_DIR:-}"
  [[ -n "$vault" && -d "$vault" ]] || { echo "VBK_ERR vault directory not found: ${vault:-<unset>}" >&2; return 1; }

  local base parent stamp stage out
  base="$(basename "$vault")"; parent="$(dirname "$vault")"
  stamp="$(date +%Y%m%d-%H%M%S)"
  stage="$(mktemp -d "${TMPDIR:-/tmp}/vbk.XXXXXX")" || { echo "VBK_ERR mktemp failed" >&2; return 1; }

  local file_count total_kb git_head
  file_count="$(find "$vault" -type f 2>/dev/null | wc -l | tr -d ' ')"
  total_kb="$(du -sk "$vault" 2>/dev/null | awk '{print $1}')"
  git_head="$(git -C "$vault" rev-parse HEAD 2>/dev/null || true)"

  cat > "$stage/manifest.json" <<JSON
{
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "tool": "pbrain /vault-backup",
  "vault_path": "$vault",
  "file_count": ${file_count:-0},
  "total_bytes": $(( ${total_kb:-0} * 1024 )),
  "git_head": "${git_head:-}"
}
JSON

  # One pass, no copy: tar reads the manifest from the stage dir and the vault
  # tree directly from its parent (interleaved -C). bsdtar + GNU tar both honour
  # multiple -C and leading --exclude patterns.
  local ex=(); local line
  while IFS= read -r line; do [[ -n "$line" ]] && ex+=("$line"); done < <(_pbrain_vbk_exclude_args)
  out="$destdir/vault-$stamp.tar.gz"
  echo "→ archiving vault ($vault, ${file_count:-0} files)…" >&2
  # ${ex[@]+…} guards the empty-array case under `set -u` on bash 3.2 (the
  # launchd agent's /bin/bash) — a bare "${ex[@]}" on an empty array aborts there.
  if ! tar czf "$out" ${ex[@]+"${ex[@]}"} -C "$stage" manifest.json -C "$parent" "$base" 2>/dev/null; then
    echo "VBK_ERR could not write tarball $out" >&2
    rm -rf "$stage"; return 1
  fi
  rm -rf "$stage"
  printf '%s\n' "$out"
}

# Delete all but the newest <keep> snapshots in <dir>. keep<=0 disables pruning.
pbrain_vbk_prune() {
  local dir="${1:-}" keep="${2:-14}"
  [[ -d "$dir" ]] || return 0
  case "$keep" in ''|*[!0-9]*) return 0 ;; esac
  [[ "$keep" -gt 0 ]] || return 0
  local f
  ls -1t "$dir"/vault-*.tar.gz 2>/dev/null | tail -n +"$((keep + 1))" | while IFS= read -r f; do
    [[ -n "$f" ]] && rm -f "$f" 2>/dev/null && echo "pruned $(basename "$f")" >&2 || true
  done
  return 0
}

# Upload one snapshot file to the configured VPS over ssh. rsync if present, else
# scp. Non-interactive (BatchMode) so a headless run can't hang on a password.
# Relies on VBK_VPS_* being loaded. Returns the transfer's exit status.
pbrain_vbk_upload_vps() {
  local file="${1:?file}"
  [[ -n "${VBK_VPS_HOST:-}" && -n "${VBK_VPS_PATH:-}" ]] || {
    echo "VBK_ERR vps destination needs host + path (config --vps-host … --vps-path …)" >&2; return 1; }
  local port="${VBK_VPS_PORT:-22}"
  local sshcmd="ssh -p $port -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
  [[ -n "${VBK_VPS_KEY:-}" ]] && sshcmd="$sshcmd -i ${VBK_VPS_KEY}"
  echo "→ uploading $(basename "$file") to ${VBK_VPS_HOST}:${VBK_VPS_PATH}…" >&2
  $sshcmd "$VBK_VPS_HOST" "mkdir -p $(printf '%q' "$VBK_VPS_PATH")" 2>/dev/null || true
  if command -v rsync >/dev/null 2>&1; then
    rsync -az -e "$sshcmd" "$file" "${VBK_VPS_HOST}:${VBK_VPS_PATH}/"
  else
    scp -P "$port" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      ${VBK_VPS_KEY:+-i "$VBK_VPS_KEY"} "$file" "${VBK_VPS_HOST}:${VBK_VPS_PATH}/"
  fi
}

# Measure a real, current snapshot size without writing one. Prints a machine line
# plus a human read; projects the retention footprint. Relies on VBK_KEEP loaded.
pbrain_vbk_estimate() {
  local vault="${VAULT_DIR:-}"
  [[ -n "$vault" && -d "$vault" ]] || { echo "VBK_ERR vault directory not found: ${vault:-<unset>}"; return 1; }
  local base parent bytes
  base="$(basename "$vault")"; parent="$(dirname "$vault")"
  local ex=(); local line
  while IFS= read -r line; do [[ -n "$line" ]] && ex+=("$line"); done < <(_pbrain_vbk_exclude_args)
  bytes="$(tar czf - ${ex[@]+"${ex[@]}"} -C "$parent" "$base" 2>/dev/null | wc -c | tr -d ' ')"
  bytes="${bytes:-0}"
  local keep="${VBK_KEEP:-14}"
  case "$keep" in ''|*[!0-9]*) keep=14 ;; esac
  echo "VBK_ESTIMATE per_snapshot_bytes=$bytes keep=$keep retained_bytes=$((bytes * keep))"
  echo "  per daily snapshot:     $(pbrain_vbk_human "$bytes")"
  echo "  × $keep-day retention:  $(pbrain_vbk_human "$((bytes * keep))")"
}

# Restore a snapshot tarball by EXTRACTING it into <into> (NON-destructive — never
# overwrites the live vault unless <into> is the vault path AND --yes is given).
# Args: <file> <into> [--yes]. Echoes the extraction path on success.
pbrain_vbk_restore() {
  local file="${1:-}" into="${2:-}" confirmed="${3:-}"
  [[ -f "$file" ]] || { echo "VBK_ERR snapshot not found: $file" >&2; return 1; }
  [[ -n "$into" ]] || { echo "VBK_ERR restore needs a target dir (restore <snapshot|latest> --into <dir>)" >&2; return 1; }
  # Guard the live vault: refuse to extract over $VAULT_DIR without --yes.
  local vault="${VAULT_DIR:-}"
  if [[ -n "$vault" ]]; then
    local rinto rvault
    rinto="$(cd "$into" 2>/dev/null && pwd -P || printf '%s' "$into")"
    rvault="$(cd "$vault" 2>/dev/null && pwd -P || printf '%s' "$vault")"
    if [[ "$rinto" == "$rvault" && "$confirmed" != "--yes" ]]; then
      echo "VBK_ERR refusing to extract over the live vault ($rvault) — re-run with --yes to force" >&2; return 1
    fi
  fi
  mkdir -p "$into" 2>/dev/null || { echo "VBK_ERR could not create $into" >&2; return 1; }
  echo "→ extracting $(basename "$file") into $into…" >&2
  if ! tar xzf "$file" -C "$into" 2>/dev/null; then
    echo "VBK_ERR could not unpack $file" >&2; return 1
  fi
  echo "VBK_RESTORED $into" >&2
  printf '%s\n' "$into"
}

# Append a result line to vault/.pbrain/backup-log.md (PB-10). Best-effort.
# Args: <ok|fail> <detail>. Creates the file with a header on first write.
pbrain_vbk_log() {
  local status="${1:-ok}" detail="${2:-}"
  local vault="${VAULT_DIR:-}"
  [[ -n "$vault" && -d "$vault" ]] || return 0
  local dir="$vault/.pbrain" logf="$vault/.pbrain/backup-log.md"
  mkdir -p "$dir" 2>/dev/null || return 0
  [[ -f "$logf" ]] || printf '# Vault backup log\n\nAppended by `/vault-backup` (PB-10). Most recent last.\n\n' > "$logf" 2>/dev/null || true
  printf -- '- %s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status" "$detail" >> "$logf" 2>/dev/null || true
  return 0
}

# Echo the age (hours, integer) of the last successful backup per backup-log.md,
# or "none" if there is no `ok` line. Reads $VAULT_DIR/.pbrain/backup-log.md.
pbrain_vbk_last_ok_age_hours() {
  local vault="${VAULT_DIR:-}" logf
  logf="$vault/.pbrain/backup-log.md"
  [[ -f "$logf" ]] || { echo "none"; return 0; }
  python3 - "$logf" <<'PYEOF'
import sys, re
from datetime import datetime, timezone
last = None
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) >= 2 and parts[1] == "ok":
        m = re.search(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)", parts[0])
        if m:
            last = m.group(1)
if not last:
    print("none"); sys.exit(0)
try:
    t = datetime.fromisoformat(last.replace("Z", "+00:00"))
    age = (datetime.now(timezone.utc) - t).total_seconds() / 3600.0
    print(int(age))
except Exception:
    print("none")
PYEOF
}

# Notify (macOS) if the last good backup is older than the threshold (default 48h).
# Best-effort; always returns 0. Echoes a status line for the caller to relay.
pbrain_vbk_check_stale() {
  local threshold="${1:-48}" age
  age="$(pbrain_vbk_last_ok_age_hours)"
  if [[ "$age" == "none" ]]; then
    echo "VBK_STALE no successful backup recorded yet"
    pbrain_notify "Vault backup" "No successful vault backup recorded yet — run /vault-backup now." 2>/dev/null || true
  elif [[ "$age" =~ ^[0-9]+$ && "$age" -ge "$threshold" ]]; then
    echo "VBK_STALE last good backup was ${age}h ago (threshold ${threshold}h)"
    pbrain_notify "Vault backup stale" "Last off-iCloud vault backup was ${age}h ago. Check /vault-backup status." 2>/dev/null || true
  else
    echo "VBK_FRESH last good backup ${age}h ago"
  fi
  return 0
}

# Install the daily LaunchAgent (StartCalendarInterval) that runs `run`.
# Args: <vault-backup.sh abs path> <HH:MM>. Best-effort via the shared launchd helper.
pbrain_vbk_schedule_install() {
  local sh="${1:?vault-backup.sh path}" hhmm="${2:-03:45}"
  # Bake the stable command path, not the (possibly ephemeral) invoking path —
  # a workspace/dev clone gets cleaned up, the daily agent must outlive it.
  sh="$(pbrain_stable_cmd_path "$sh")"
  local hh="${hhmm%%:*}" mm="${hhmm##*:}"
  hh=$((10#${hh:-3})); mm=$((10#${mm:-45}))
  local extra
  extra="  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>$hh</integer>
    <key>Minute</key><integer>$mm</integer>
  </dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>"
  pbrain_launchagent_install "$VBK_LABEL" "$(pbrain_vbk_plist)" "$(pbrain_vbk_log_file)" "$extra" \
    -- /bin/bash "$sh" run
}

pbrain_vbk_schedule_uninstall() {
  pbrain_launchagent_uninstall "$VBK_LABEL" "$(pbrain_vbk_plist)"
}
