#!/usr/bin/env bats
# Tests for lib/prefs.sh — pbrain_emit_prefs.
#
# Prefs live in the vault under .pbrain/ (one subdir per command):
#   $VAULT_DIR/.pbrain/_global/prefs.md
#   $VAULT_DIR/.pbrain/<cmd>/prefs.md
# PBRAIN_PREFS_DIR overrides the ROOT (layout inside is identical).
#
# Run with:  bats tests/
# Install bats:  brew install bats-core   (macOS)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export VAULT_DIR="$TMP/vault"
  mkdir -p "$VAULT_DIR/.pbrain/journal" "$VAULT_DIR/.pbrain/_global"
  PREFS="$VAULT_DIR/.pbrain/journal/prefs.md"
  GLOBAL="$VAULT_DIR/.pbrain/_global/prefs.md"
  source "$REPO_ROOT/lib/prefs.sh"
}

teardown() {
  rm -rf "$TMP"
}

# Note (PB-95): pbrain_emit_prefs always emits a shipped CHAT OUTPUT HYGIENE
# baseline block, so "emits nothing" now means "emits no USER PREFERENCES block"
# — the hygiene block is the only output. These tests assert that distinction.

@test "missing prefs file emits no user-prefs block and returns 0" {
  run pbrain_emit_prefs journal
  [ "$status" -eq 0 ]
  [[ "$output" != *"USER PREFERENCES"* ]]
}

@test "empty prefs file emits no user-prefs block" {
  : > "$PREFS"
  run pbrain_emit_prefs journal
  [ "$status" -eq 0 ]
  [[ "$output" != *"USER PREFERENCES"* ]]
}

@test "whitespace-only prefs file emits no user-prefs block" {
  printf '   \n\t\n' > "$PREFS"
  run pbrain_emit_prefs journal
  [[ "$output" != *"USER PREFERENCES"* ]]
}

@test "prefs with content emits a labelled block including the content" {
  echo "- Ask only 1 question, not 3." > "$PREFS"
  run pbrain_emit_prefs journal
  [ "$status" -eq 0 ]
  [[ "$output" == *"USER PREFERENCES for /journal"* ]]
  [[ "$output" == *"Ask only 1 question"* ]]
  [[ "$output" == *"END USER PREFERENCES"* ]]
}

@test "no command name emits nothing and returns 0" {
  # The $cmd guard returns before even the hygiene block, so this stays silent.
  run pbrain_emit_prefs
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no vault and no override still emits the hygiene block, no user prefs" {
  unset VAULT_DIR
  unset PBRAIN_PREFS_DIR
  run pbrain_emit_prefs journal
  [ "$status" -eq 0 ]
  # The shipped hygiene baseline ships with the code, independent of any vault.
  [[ "$output" == *"CHAT OUTPUT HYGIENE"* ]]
  [[ "$output" != *"USER PREFERENCES"* ]]
}

@test "PBRAIN_PREFS_DIR override is honoured (root with per-cmd subdirs)" {
  local alt="$TMP/alt"
  mkdir -p "$alt/journal"
  echo "- alt pref" > "$alt/journal/prefs.md"
  PBRAIN_PREFS_DIR="$alt" run pbrain_emit_prefs journal
  [[ "$output" == *"alt pref"* ]]
}

@test "global prefs file emits a labelled global block" {
  echo "- Stop nudging me about journal/gratitude." > "$GLOBAL"
  run pbrain_emit_prefs journal
  [ "$status" -eq 0 ]
  [[ "$output" == *"USER PREFERENCES (global — all pbrain commands)"* ]]
  [[ "$output" == *"Stop nudging me about journal/gratitude."* ]]
  [[ "$output" == *"END USER PREFERENCES (global)"* ]]
}

@test "whitespace-only global file emits no global prefs block" {
  printf '   \n\t\n' > "$GLOBAL"
  run pbrain_emit_prefs journal
  [ "$status" -eq 0 ]
  [[ "$output" != *"USER PREFERENCES"* ]]
}

@test "global block is emitted before the per-command block" {
  echo "- global rule" > "$GLOBAL"
  echo "- command rule" > "$PREFS"
  run pbrain_emit_prefs journal
  [ "$status" -eq 0 ]
  # The global header must appear before the per-command header.
  local gpos cpos
  gpos="${output%%USER PREFERENCES (global*}"
  cpos="${output%%USER PREFERENCES for /journal*}"
  [ "${#gpos}" -lt "${#cpos}" ]
  [[ "$output" == *"global rule"* ]]
  [[ "$output" == *"command rule"* ]]
}

@test "global file applies even when no per-command file exists" {
  echo "- global only" > "$GLOBAL"
  run pbrain_emit_prefs journal
  [ "$status" -eq 0 ]
  [[ "$output" == *"global only"* ]]
  [[ "$output" != *"USER PREFERENCES for /journal"* ]]
}

# --- PB-95: shipped CHAT OUTPUT HYGIENE baseline ----------------------------

@test "PB-95: hygiene block is emitted even with no prefs of any kind" {
  run pbrain_emit_prefs journal
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHAT OUTPUT HYGIENE (all pbrain commands)"* ]]
  [[ "$output" == *"END CHAT OUTPUT HYGIENE"* ]]
  [[ "$output" == *"markdown link"* ]]
  [[ "$output" == *"backticks"* ]]
}

@test "PB-95: hygiene block is emitted exactly once per call" {
  echo "- a global rule" > "$GLOBAL"
  echo "- a command rule" > "$PREFS"
  run pbrain_emit_prefs journal
  [ "$status" -eq 0 ]
  local n
  n="$(printf '%s\n' "$output" | grep -c 'CHAT OUTPUT HYGIENE (all pbrain commands)')"
  [ "$n" -eq 1 ]
}

@test "PB-95: hygiene block precedes any USER PREFERENCES block" {
  echo "- a global rule" > "$GLOBAL"
  run pbrain_emit_prefs journal
  [ "$status" -eq 0 ]
  local hpos ppos
  hpos="${output%%CHAT OUTPUT HYGIENE*}"
  ppos="${output%%USER PREFERENCES*}"
  [ "${#hpos}" -lt "${#ppos}" ]
}

@test "PB-95: hygiene block never exits non-zero (sourced under set -e)" {
  # Mirrors the never-fail contract: the function must not take a command down.
  run bash -c "set -euo pipefail; source '$REPO_ROOT/lib/prefs.sh'; pbrain_emit_prefs journal >/dev/null; echo OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# --- PB-37: prefs read from a profile's "prefs" array -----------------------

@test "PB-37: profile prefs array is surfaced when a profile file is passed" {
  local prof="$VAULT_DIR/habits-profile.v1.md"
  printf -- '---\nversion: 1\ncommitted: true\n---\n```json\n{"habits": [], "prefs": ["Eat clean good = mains only"]}\n```\n' > "$prof"
  run pbrain_emit_prefs journal "$prof"
  [ "$status" -eq 0 ] && [[ "$output" == *"USER PREFERENCES for /journal"* && "$output" == *"Eat clean good = mains only"* && "$output" == *'profile "prefs"'* ]]
}

@test "PB-37: pbrain_prefs_from_profile lists each prefs entry as a bullet" {
  local prof="$VAULT_DIR/p.v1.md"
  printf -- '```json\n{"prefs": ["one", "two"]}\n```\n' > "$prof"
  run pbrain_prefs_from_profile "$prof"
  [ "$status" -eq 0 ] && [[ "$output" == *"- one"* && "$output" == *"- two"* ]]
}

@test "PB-37: profile with no prefs array falls back to the flat prefs.md" {
  local prof="$VAULT_DIR/noprefs.v1.md"
  printf -- '```json\n{"habits": []}\n```\n' > "$prof"
  echo "- flat fallback pref" > "$PREFS"
  run pbrain_emit_prefs journal "$prof"
  [ "$status" -eq 0 ] && [[ "$output" == *"flat fallback pref"* && "$output" == *"$PREFS"* ]]
}

@test "PB-37: empty prefs array in profile falls back to the flat prefs.md" {
  local prof="$VAULT_DIR/empty.v1.md"
  printf -- '```json\n{"prefs": []}\n```\n' > "$prof"
  echo "- still flat" > "$PREFS"
  run pbrain_emit_prefs journal "$prof"
  [ "$status" -eq 0 ] && [[ "$output" == *"still flat"* ]]
}

@test "PB-37: no profile file passed still reads the flat prefs.md (back-compat)" {
  echo "- legacy flat pref" > "$PREFS"
  run pbrain_emit_prefs journal
  [ "$status" -eq 0 ] && [[ "$output" == *"legacy flat pref"* ]]
}
