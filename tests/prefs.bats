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

@test "missing prefs file emits nothing and returns 0" {
  run pbrain_emit_prefs journal
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "empty prefs file emits nothing" {
  : > "$PREFS"
  run pbrain_emit_prefs journal
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "whitespace-only prefs file emits nothing" {
  printf '   \n\t\n' > "$PREFS"
  run pbrain_emit_prefs journal
  [ -z "$output" ]
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
  run pbrain_emit_prefs
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no vault and no override emits nothing and returns 0" {
  unset VAULT_DIR
  unset PBRAIN_PREFS_DIR
  run pbrain_emit_prefs journal
  [ "$status" -eq 0 ]
  [ -z "$output" ]
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

@test "whitespace-only global file emits nothing" {
  printf '   \n\t\n' > "$GLOBAL"
  run pbrain_emit_prefs journal
  [ "$status" -eq 0 ]
  [ -z "$output" ]
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
