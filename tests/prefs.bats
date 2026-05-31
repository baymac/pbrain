#!/usr/bin/env bats
# Tests for lib/prefs.sh — pbrain_emit_prefs.
#
# Run with:  bats tests/
# Install bats:  brew install bats-core   (macOS)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export XDG_CONFIG_HOME="$TMP/config"
  mkdir -p "$XDG_CONFIG_HOME/pbrain/prefs"
  PREFS="$XDG_CONFIG_HOME/pbrain/prefs/journal.md"
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

@test "PBRAIN_PREFS_DIR override is honoured" {
  local alt="$TMP/alt"
  mkdir -p "$alt"
  echo "- alt pref" > "$alt/journal.md"
  PBRAIN_PREFS_DIR="$alt" run pbrain_emit_prefs journal
  [[ "$output" == *"alt pref"* ]]
}
