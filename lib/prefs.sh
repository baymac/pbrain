#!/usr/bin/env bash
# pbrain per-command preferences — sourced by lib/vault.sh.
#
# Defines one function:
#
#   pbrain_emit_prefs <command-name>
#
# It reads the user's standing preferences for that command from
#   ~/.config/pbrain/prefs/<command-name>.md
# and, if the file exists and is non-empty, prints a clearly labelled block
# to stdout so the calling Claude session applies those preferences while it
# does the command's work. When the file is absent or empty it prints
# NOTHING — the common case for fresh users — so the per-run token cost stays
# near zero until a preference has actually been captured.
#
# The companion writer side lives in lib/self-improve.sh, which is what
# captures new preferences into these files (consolidate-on-write).
#
# Env knobs:
#   PBRAIN_PREFS_DIR   override the prefs directory (default ~/.config/pbrain/prefs)
#
# This function NEVER exits non-zero and NEVER prints to stderr on the happy
# path: it is sourced into every command, which runs under `set -euo pipefail`,
# so a fault here must not take the command down. Call sites still append
# `|| true` as a belt-and-suspenders guard.

pbrain_emit_prefs() {
  local cmd prefs_dir prefs_file contents
  cmd="${1:-}"
  [[ -n "$cmd" ]] || return 0

  prefs_dir="${PBRAIN_PREFS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/prefs}"
  prefs_file="$prefs_dir/$cmd.md"

  [[ -f "$prefs_file" ]] || return 0

  # Read the file; bail silently on any read error.
  contents="$(cat "$prefs_file" 2>/dev/null || true)"

  # Treat whitespace-only files as empty — emit nothing.
  [[ -n "${contents//[[:space:]]/}" ]] || return 0

  printf '%s\n' "--- USER PREFERENCES for /$cmd ---"
  printf '%s\n' "Standing preferences this user has set for this command. Apply them"
  printf '%s\n' "throughout this session; they override the command's defaults wherever"
  printf '%s\n' "they conflict. Source: $prefs_file"
  printf '%s\n' ""
  printf '%s\n' "$contents"
  printf '%s\n' "--- END USER PREFERENCES ---"
  printf '%s\n' ""
  return 0
}
