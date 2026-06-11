#!/usr/bin/env bats
# Tests for commands/thoughts.sh — timestamped thought capture command.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0   # keep the vault migration runner out of unit tests
  export PBRAIN_UPDATE_CHECK=0  # never hit the network / nag in unit tests
  export PBRAIN_VAULT="$TMP/vault"; mkdir -p "$PBRAIN_VAULT"
  export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/pbrain"
  printf '%s\n' "$PBRAIN_VAULT" > "$XDG_CONFIG_HOME/pbrain/vault"
  export PBRAIN_THOUGHTS_DIR="$TMP/thoughts"
  export PBRAIN_SELF_IMPROVE=off
  CMD="$REPO_ROOT/commands/thoughts.sh"
}

teardown() {
  rm -rf "$TMP"
}

_run_cmd() { run bash "$CMD" "$@"; }

@test "no args emits a THOUGHT_PROMPT block with output_file" {
  _run_cmd
  [ "$status" -eq 0 ]
  [[ "$output" == *"THOUGHT_PROMPT"* ]]
  [[ "$output" == *"output_file:"* ]]
}

@test "with text emits a THOUGHT_ENTRY block containing the raw thought" {
  _run_cmd "life is too short to skip dessert"
  [ "$status" -eq 0 ]
  [[ "$output" == *"THOUGHT_ENTRY"* ]]
  [[ "$output" == *"life is too short to skip dessert"* ]]
  [[ "$output" == *"output_file:"* ]]
}

@test "creates today's thought file on first run" {
  TODAY="$(date +%Y-%m-%d)"
  _run_cmd "testing thought creation"
  [ "$status" -eq 0 ]
  [ -f "$PBRAIN_THOUGHTS_DIR/$TODAY.md" ]
}

@test "creates thoughts directory when it does not exist" {
  rm -rf "$PBRAIN_THOUGHTS_DIR"
  _run_cmd "hello world"
  [ "$status" -eq 0 ]
  [ -d "$PBRAIN_THOUGHTS_DIR" ]
}

@test "PBRAIN_THOUGHTS_DIR override is honoured" {
  CUSTOM="$TMP/my-thoughts"
  PBRAIN_THOUGHTS_DIR="$CUSTOM" run bash "$CMD" "override test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$CUSTOM"* ]]
}
