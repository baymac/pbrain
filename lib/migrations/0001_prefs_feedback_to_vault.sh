#!/usr/bin/env bash
# Migration 0001 (AUTO): prefs + feedback move from ~/.config/pbrain into the
# vault at $VAULT_DIR/.pbrain/, so they sync across devices with the vault.
#
#   old: ~/.config/pbrain/prefs/_global.md     → new: .pbrain/_global/prefs.md
#   old: ~/.config/pbrain/prefs/<cmd>.md       → new: .pbrain/<cmd>/prefs.md
#   old: ~/.config/pbrain/feedback/<cmd>.md    → new: .pbrain/<cmd>/feedback.md
#
# COPIES (never moves): the ledger is per-vault, so a second vault must be able
# to run this again with the source intact. Originals are left in place; the
# read/write side (lib/prefs.sh, lib/self-improve.sh) now uses the vault paths,
# so the old files simply go stale.

MIGRATION_KIND=auto
MIGRATION_OWNER=""

_pbrain_m0001_old_root() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/pbrain"
}

migration_applicable() {
  local old
  old="$(_pbrain_m0001_old_root)"
  compgen -G "$old/prefs/*.md" >/dev/null 2>&1 && return 0
  compgen -G "$old/feedback/*.md" >/dev/null 2>&1 && return 0
  return 1
}

migration_apply() {
  local old root f base dest
  old="$(_pbrain_m0001_old_root)"
  root="$VAULT_DIR/.pbrain"
  for f in "$old"/prefs/*.md; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f" .md)"
    if [[ "$base" == "_global" ]]; then
      dest="$root/_global/prefs.md"
    else
      dest="$root/$base/prefs.md"
    fi
    mkdir -p "$(dirname "$dest")"
    if [[ -f "$dest" ]]; then
      { echo ""; echo "<!-- merged from $f by migration 0001 -->"; cat "$f"; } >> "$dest"
    else
      cp "$f" "$dest"
    fi
  done
  for f in "$old"/feedback/*.md; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f" .md)"
    dest="$root/$base/feedback.md"
    mkdir -p "$(dirname "$dest")"
    if [[ -f "$dest" ]]; then
      { echo ""; echo "<!-- merged from $f by migration 0001 -->"; cat "$f"; } >> "$dest"
    else
      cp "$f" "$dest"
    fi
  done
  echo "prefs/feedback copied into $root (originals left in $old; pbrain now reads/writes the vault copies)"
}
