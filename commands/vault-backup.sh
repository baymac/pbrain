#!/usr/bin/env bash
set -euo pipefail

# vault-backup.sh — automated off-iCloud snapshots of the Obsidian vault (PB-10).
#
# A sibling of `/project-manager backup` (PB-17) for the vault instead of Plane:
# a nightly tarball of $VAULT_DIR shipped to a local dir, an external volume, or
# a VPS over rsync/scp, with N-day retention, a guarded restore, a daily
# LaunchAgent, a per-run log in vault/.pbrain/backup-log.md, and a macOS
# notification when the last good backup is older than 48h. The VPS credentials
# are inherited from the Plane backup config (same VPS, zero re-entry).
#
# All the real work lives in lib/vault-backup.sh (pbrain_vbk_*); this is just the
# CLI dispatch. Actions (the Claude-facing API; humans type natural language):
#   vault-backup.sh status                 # default: schedule, dest, retention, last-backup age
#   vault-backup.sh estimate               # projected snapshot + retention size
#   vault-backup.sh now [--dir <path>]     # take one snapshot interactively
#   vault-backup.sh run                    # headless entry point for the LaunchAgent
#   vault-backup.sh enable  [--dest local|external|vps] [--dir <path>] [--keep N]
#                           [--time HH:MM] [--vps-host <h>] [--vps-path <p>]
#                           [--vps-port <n>] [--ssh-key <path>] [--exclude <pat>]
#   vault-backup.sh disable                # remove the schedule (snapshots kept)
#   vault-backup.sh config  <same flags as enable, plus --keep-local true|false>
#   vault-backup.sh list                   # list snapshots with sizes
#   vault-backup.sh restore <snapshot|latest> --into <dir> [--yes]
#   vault-backup.sh check [--threshold H]  # notify if last good backup is stale
#   vault-backup.sh help
#
# Overrides:
#   PBRAIN_VAULT             — vault root (the thing being backed up)
#   XDG_CONFIG_HOME          — where vault-backup.json / vault-backups/ live

_VB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_VB_SRC" ]]; do
  _VB_LINK="$(readlink "$_VB_SRC")"
  [[ "$_VB_LINK" = /* ]] && _VB_SRC="$_VB_LINK" || _VB_SRC="$(cd -P -- "$(dirname -- "$_VB_SRC")" && pwd -P)/$_VB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_VB_SRC")" && pwd -P)"
unset _VB_SRC _VB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"          # resolves $VAULT_DIR; sources launchd + reminders
source "$_SCRIPT_DIR/../lib/vault-backup.sh"

pbrain_emit_prefs "vault-backup" || true

if ! command -v python3 >/dev/null 2>&1; then
  echo "pbrain: /vault-backup needs python3 (stdlib only) and it isn't on PATH." >&2
  exit 1
fi

# --- flag parsing (bash-3.2-safe) -------------------------------------------
# Positionals → POS[]; value flags → F_<name>, bool flags → B_<name>.
POS=()
_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes)
        eval "B_yes=1"; shift ;;
      --*)
        local key="${1#--}"; key="${key//-/_}"; shift
        eval "F_${key}=\${1:-}"; shift || true ;;
      *)
        POS+=("$1"); shift ;;
    esac
  done
}
_flag() { eval "printf '%s' \"\${F_$1:-}\""; }
_has_bool() { eval "[[ -n \"\${B_$1:-}\" ]]"; }

ACTION="${1:-status}"; [[ $# -gt 0 ]] && shift || true
_parse_args "$@"
eval "$(pbrain_vbk_load)"
VB_SH="$_SCRIPT_DIR/vault-backup.sh"

# Collect dest/retention/schedule/vps flags into a saves[] array for save.
_collect_saves() {
  saves=()
  [[ -n "$(_flag dest)" ]] && saves+=("dest=$(_flag dest)")
  [[ -n "$(_flag dir)" && "$(_flag dest)" == external ]] && saves+=("external_dir=$(_flag dir)")
  [[ -n "$(_flag dir)" && "$(_flag dest)" != external ]] && saves+=("local_dir=$(_flag dir)")
  [[ -n "$(_flag keep)" ]] && saves+=("keep=$(_flag keep)")
  [[ -n "$(_flag time)" ]] && saves+=("time=$(_flag time)")
  [[ -n "$(_flag exclude)" ]] && saves+=("excludes=$(_flag exclude)")
  [[ -n "$(_flag vps_host)" ]] && saves+=("vps.host=$(_flag vps_host)")
  [[ -n "$(_flag vps_path)" ]] && saves+=("vps.path=$(_flag vps_path)")
  [[ -n "$(_flag vps_port)" ]] && saves+=("vps.port=$(_flag vps_port)")
  [[ -n "$(_flag ssh_key)" ]] && saves+=("vps.ssh_key=$(_flag ssh_key)")
  [[ -n "$(_flag keep_local)" ]] && saves+=("vps.keep_local_copy=$(_flag keep_local)")
  return 0
}

# Resolve the snapshot directory used for list/status/restore reads.
_read_dir() {
  local d="${VBK_LOCAL_DIR:-$(pbrain_vbk_default_dir)}"
  [[ "${VBK_DEST:-local}" == external ]] && d="${VBK_EXTERNAL_DIR:-$d}"
  printf '%s\n' "$d"
}

case "$ACTION" in
  estimate)
    echo "VBK_ESTIMATE_RUN"
    pbrain_vbk_estimate || true
    ;;

  now|run)
    # `run` is the headless launchd entry point; `now` is the interactive one.
    echo "VBK_BACKUP"
    [[ "$ACTION" == run ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] vault backup run start"
    dest_override="$(_flag dir)"
    if [[ -n "$dest_override" ]]; then destdir="$dest_override"; mkdir -p "$destdir"
    else destdir="$(pbrain_vbk_resolve_dest_dir)" || { echo "Backup aborted — see VBK_ERR above."; pbrain_vbk_log fail "dest unresolved"; exit 0; }; fi
    if ! snap="$(pbrain_vbk_snapshot "$destdir")"; then
      echo "Snapshot failed — see VBK_ERR above."; pbrain_vbk_log fail "snapshot error"; exit 0
    fi
    snap_human="$(pbrain_vbk_human "$(wc -c < "$snap" | tr -d ' ')")"
    echo "wrote $snap ($snap_human)"
    log_detail="$(basename "$snap") $snap_human"
    if [[ "${VBK_DEST:-local}" == vps ]]; then
      if pbrain_vbk_upload_vps "$snap"; then
        echo "uploaded to ${VBK_VPS_HOST}:${VBK_VPS_PATH}"
        log_detail="$log_detail → ${VBK_VPS_HOST}:${VBK_VPS_PATH}"
        [[ "${VBK_VPS_KEEPLOCAL:-True}" == "False" || "${VBK_VPS_KEEPLOCAL:-true}" == "false" ]] && rm -f "$snap" && echo "removed local staging copy"
      else
        echo "VBK_WARN upload failed — local copy kept at $snap"
        pbrain_vbk_log fail "upload failed: $(basename "$snap")"
        pbrain_vbk_prune "$destdir" "${VBK_KEEP:-14}"
        [[ "$ACTION" == run ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] vault backup run done (upload failed)"
        exit 0
      fi
    fi
    pbrain_vbk_prune "$destdir" "${VBK_KEEP:-14}"
    pbrain_vbk_log ok "$log_detail"
    pbrain_vbk_check_stale || true
    [[ "$ACTION" == run ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] vault backup run done"
    ;;

  enable)
    echo "VBK_ENABLE"
    _collect_saves
    [[ ${#saves[@]} -gt 0 ]] && pbrain_vbk_save "${saves[@]}"
    eval "$(pbrain_vbk_load)"
    pbrain_vbk_schedule_install "$VB_SH" "${VBK_TIME:-03:45}"
    if pbrain_launchagent_loaded "$VBK_LABEL"; then
      echo "daily vault backup scheduled at ${VBK_TIME:-03:45} → dest=${VBK_DEST:-local}, keep=${VBK_KEEP:-14}"
      [[ "${VBK_DEST:-local}" == vps ]] && echo "vps: ${VBK_VPS_HOST:-<unset>}:${VBK_VPS_PATH:-<unset>} (inherits Plane's VPS host/key unless overridden)"
      echo "runs: $(pbrain_stable_cmd_path "$VB_SH") run   (log: $(pbrain_vbk_log_file))"
    else
      echo "VBK_WARN could not load the LaunchAgent — check launchctl."
    fi
    ;;

  disable)
    echo "VBK_DISABLE"
    pbrain_vbk_schedule_uninstall
    echo "daily vault backup disabled (existing snapshots kept)."
    ;;

  config)
    echo "VBK_CONFIG"
    _collect_saves
    [[ ${#saves[@]} -gt 0 ]] && pbrain_vbk_save "${saves[@]}"
    if pbrain_launchagent_loaded "$VBK_LABEL"; then
      eval "$(pbrain_vbk_load)"
      pbrain_vbk_schedule_install "$VB_SH" "${VBK_TIME:-03:45}"
      echo "config updated + live schedule refreshed."
    else
      echo "config updated (no schedule running — enable with: enable)."
    fi
    ;;

  list)
    echo "VBK_LIST"
    bdir="$(_read_dir)"
    if ls -1 "$bdir"/vault-*.tar.gz >/dev/null 2>&1; then
      ls -1t "$bdir"/vault-*.tar.gz 2>/dev/null | while IFS= read -r f; do
        printf '%s\t%s\n' "$(pbrain_vbk_human "$(wc -c < "$f" | tr -d ' ')")" "$(basename "$f")"
      done
    else
      echo "(no snapshots in $bdir)"
    fi
    ;;

  restore)
    echo "VBK_RESTORE"
    target="${POS[0]:-$(_flag file)}"
    bdir="$(_read_dir)"
    [[ "$target" == latest || -z "$target" ]] && target="$(ls -1t "$bdir"/vault-*.tar.gz 2>/dev/null | head -1)"
    [[ -n "$target" ]] || { echo "VBK_ERR no snapshot to restore (give a path or 'latest')"; exit 0; }
    # A bare basename resolves against the snapshot dir.
    [[ ! -f "$target" && -f "$bdir/$target" ]] && target="$bdir/$target"
    into="$(_flag into)"
    [[ -n "$into" ]] || into="$bdir/restore-$(date +%Y%m%d-%H%M%S)"
    pbrain_vbk_restore "$target" "$into" "$(_has_bool yes && echo --yes)" || true
    ;;

  check)
    echo "VBK_CHECK"
    pbrain_vbk_check_stale "$(_flag threshold)" || true
    ;;

  status|*)
    echo "VBK_STATUS"
    echo "scheduled: $(pbrain_launchagent_loaded "$VBK_LABEL" && echo "yes (daily ${VBK_TIME:-03:45})" || echo no)"
    echo "destination: ${VBK_DEST:-local}"
    bdir="$(_read_dir)"
    echo "directory: $bdir"
    [[ "${VBK_DEST:-local}" == vps ]] && echo "vps: ${VBK_VPS_HOST:-<unset>}:${VBK_VPS_PATH:-<unset>} (keep_local=${VBK_VPS_KEEPLOCAL:-true})"
    echo "retention: keep ${VBK_KEEP:-14}"
    echo "excludes: ${VBK_EXCLUDES:-.DS_Store}"
    cnt="$(ls -1 "$bdir"/vault-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')" || true
    last="$(ls -1t "$bdir"/vault-*.tar.gz 2>/dev/null | head -1)" || true
    echo "snapshots: ${cnt:-0}"
    [[ -n "$last" ]] && echo "latest: $(basename "$last") ($(pbrain_vbk_human "$(wc -c < "$last" | tr -d ' ')"))"
    age="$(pbrain_vbk_last_ok_age_hours)"
    [[ "$age" == "none" ]] && echo "last good backup: none recorded" || echo "last good backup: ${age}h ago"
    ;;
esac

