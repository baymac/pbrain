#!/usr/bin/env bats
# Tests for commands/discuss.sh — Socratic dilemma discussion command.
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
  export PBRAIN_NOTES_DIR="$TMP/notes"
  export PBRAIN_SELF_IMPROVE=off
  CMD="$REPO_ROOT/commands/discuss.sh"
}

teardown() {
  rm -rf "$TMP"
}

_run_cmd() { run bash "$CMD" "$@"; }

@test "no args prints usage and exits non-zero" {
  _run_cmd
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "with a topic emits DISCUSS_SESSION block" {
  _run_cmd "should I change careers"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DISCUSS_SESSION"* ]]
  [[ "$output" == *"topic:"* ]]
  [[ "$output" == *"output_file:"* ]]
}

@test "creates notes directory when it does not exist" {
  rm -rf "$PBRAIN_NOTES_DIR"
  _run_cmd "test topic"
  [ "$status" -eq 0 ]
  [ -d "$PBRAIN_NOTES_DIR" ]
}

@test "creates a stub note file with frontmatter" {
  TODAY="$(date +%Y-%m-%d)"
  _run_cmd "balance work and rest"
  [ "$status" -eq 0 ]
  OUT="$(ls "$PBRAIN_NOTES_DIR/$TODAY"-*.md 2>/dev/null | head -1)"
  [ -n "$OUT" ]
  grep -q "type: discuss" "$OUT"
}

@test "slug strips stop words and special chars from the topic" {
  TODAY="$(date +%Y-%m-%d)"
  _run_cmd "the art of saying no to people"
  [ "$status" -eq 0 ]
  # Slug should keep content words like 'art', 'saying', 'people'
  OUT="$(ls "$PBRAIN_NOTES_DIR/$TODAY"-*.md 2>/dev/null | head -1)"
  [ -n "$OUT" ]
  [[ "$OUT" != *"the-art"* ]] || [[ "$OUT" == *"art"* ]]
}

@test "resumes an existing note rather than overwriting it" {
  TODAY="$(date +%Y-%m-%d)"
  # First run creates the stub
  _run_cmd "test resume topic"
  FILE="$(ls "$PBRAIN_NOTES_DIR/$TODAY"-*.md 2>/dev/null | head -1)"
  printf '\n## My notes\n\nSome content.\n' >> "$FILE"
  # Second run with same topic
  _run_cmd "test resume topic"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists today"* ]]
  # Content preserved
  grep -q "Some content." "$FILE"
}
