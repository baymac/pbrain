#!/usr/bin/env bash
# pbrain per-command preferences — sourced by lib/vault.sh.
#
# Defines one function:
#
#   pbrain_emit_prefs <command-name>
#
# It reads the user's standing preferences from two markdown files and, for
# each that exists and is non-empty, prints a clearly labelled block to stdout
# so the calling Claude session applies those preferences while it does the
# command's work. Preferences live IN THE VAULT (so they sync across devices
# with everything else), under the hidden .pbrain control dir:
#
#   $VAULT_DIR/.pbrain/_global/prefs.md        — apply to EVERY command
#   $VAULT_DIR/.pbrain/<command-name>/prefs.md — apply to this command only
#
# (They moved here from ~/.config/pbrain/prefs/ — migration 0001 copies any
# existing files across automatically.)
#
# The global file is where cross-command standing preferences live — most
# importantly, "stop nudging / suggesting X" rules. A nudge like the
# morning-sequence journal/gratitude check fires from many commands, so a
# per-command pref could never silence it everywhere; the global file can, and
# every command's instructions defer to it. The global block is emitted first
# so a per-command pref can still refine it.
#
# When a file is absent or empty it contributes NOTHING — the common case for
# fresh users — so the per-run token cost stays near zero until a preference
# has actually been captured.
#
# The companion writer side lives in lib/self-improve.sh, which is what
# captures new preferences into these files (consolidate-on-write).
#
# Env knobs:
#   PBRAIN_PREFS_DIR   override the prefs ROOT (default $VAULT_DIR/.pbrain).
#                      Layout inside is always <root>/_global/prefs.md and
#                      <root>/<cmd>/prefs.md.
#
# This function NEVER exits non-zero and NEVER prints to stderr on the happy
# path: it is sourced into every command, which runs under `set -euo pipefail`,
# so a fault here must not take the command down. Call sites still append
# `|| true` as a belt-and-suspenders guard.

pbrain_emit_prefs() {
  local cmd prefs_root global_file prefs_file global_contents contents
  cmd="${1:-}"
  [[ -n "$cmd" ]] || return 0

  # No override and no vault → nothing to read (unit tests source this file
  # standalone; commands always have VAULT_DIR by the time they call this).
  [[ -n "${PBRAIN_PREFS_DIR:-}" || -n "${VAULT_DIR:-}" ]] || return 0
  prefs_root="${PBRAIN_PREFS_DIR:-${VAULT_DIR:-}/.pbrain}"

  # Global standing preferences — apply to EVERY command. Emitted first so a
  # per-command pref below can still refine them. This is the home for
  # cross-command "stop suggesting / don't nudge me about X" rules, including
  # silencing the morning-sequence journal/gratitude check, which fires from
  # many commands and so can't be silenced by a single command's pref file.
  global_file="$prefs_root/_global/prefs.md"
  if [[ -f "$global_file" ]]; then
    # Read the file; bail silently on any read error. Whitespace-only == empty.
    global_contents="$(cat "$global_file" 2>/dev/null || true)"
    if [[ -n "${global_contents//[[:space:]]/}" ]]; then
      printf '%s\n' "--- USER PREFERENCES (global — all pbrain commands) ---"
      printf '%s\n' "Standing preferences this user has set for ALL pbrain commands. Apply"
      printf '%s\n' "them throughout this session; they override command defaults AND any"
      printf '%s\n' "built-in suggestion or nudge wherever they conflict — including the"
      printf '%s\n' "morning-sequence journal/gratitude check. If a preference here says to"
      printf '%s\n' "skip a suggestion, do not make it. Source: $global_file"
      printf '%s\n' ""
      printf '%s\n' "$global_contents"
      printf '%s\n' "--- END USER PREFERENCES (global) ---"
      printf '%s\n' ""
    fi
  fi

  prefs_file="$prefs_root/$cmd/prefs.md"

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
