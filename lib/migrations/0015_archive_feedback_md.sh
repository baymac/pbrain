#!/usr/bin/env bash
# Migration 0015 (AUTO): retire the per-command feedback.md files. Quality fixes
# are no longer stored in the vault — they're filed upstream as GitHub issues
# against baymac/pbrain (see lib/self-improve.sh), with a one-line fallback note
# in <cmd>/quality-log.md. This migration archives any existing
# $VAULT_DIR/.pbrain/<cmd>/feedback.md out of the live tree so nothing references
# a now-unused path.
#
#   .pbrain/<cmd>/feedback.md  →  .pbrain/backup/feedback-md/<cmd>/feedback.md
#
# NON-DESTRUCTIVE: the files are MOVED into .pbrain/backup/ (parked, never
# deleted), so any notes the user accumulated are preserved and recoverable. The
# read/write side already stopped touching feedback.md, so the live copies are
# dead weight; this just tidies them away. Idempotent — re-running finds nothing
# left under <cmd>/feedback.md and records vacuously.
#
# Migration 0001 (which CREATED feedback.md by copying from ~/.config/pbrain) is
# left untouched — it's shipped history. This higher-numbered migration is the
# one that supersedes its outcome.

MIGRATION_KIND=auto
MIGRATION_OWNER=""

_pbrain_m0015_root() {
  printf '%s\n' "$VAULT_DIR/.pbrain"
}

migration_applicable() {
  local root
  root="$(_pbrain_m0015_root)"
  # Any <cmd>/feedback.md directly under .pbrain/ (not in backup/) is work to do.
  compgen -G "$root/*/feedback.md" >/dev/null 2>&1 && return 0
  return 1
}

migration_apply() {
  local root dest_root f cmd dest moved=0
  root="$(_pbrain_m0015_root)"
  dest_root="$root/backup/feedback-md"
  for f in "$root"/*/feedback.md; do
    [[ -f "$f" ]] || continue
    cmd="$(basename "$(dirname "$f")")"
    # Never re-archive something already living under backup/.
    [[ "$cmd" == "backup" ]] && continue
    dest="$dest_root/$cmd/feedback.md"
    mkdir -p "$(dirname "$dest")"
    # If a parked copy somehow exists, append rather than clobber.
    if [[ -f "$dest" ]]; then
      { echo ""; echo "<!-- re-archived by migration 0015 -->"; cat "$f"; } >> "$dest"
      rm -f "$f"
    else
      mv "$f" "$dest"
    fi
    # Drop the now-empty <cmd> dir only if it has nothing else in it.
    rmdir "$(dirname "$f")" 2>/dev/null || true
    moved=$((moved + 1))
  done
  echo "archived $moved feedback.md file(s) into $dest_root (quality fixes now go to GitHub issues)"
}
