#!/usr/bin/env bats
# Tests for commands/gratitude-journal.sh — daily gratitude journal command.
# Focus: the reflection question is grounded in today's journal entry (PB-35).
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0    # keep the vault migration runner out of unit tests
  export PBRAIN_UPDATE_CHECK=0  # never hit the network / nag in unit tests
  export PBRAIN_VAULT="$TMP/vault"; mkdir -p "$PBRAIN_VAULT"
  export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/pbrain"
  printf '%s\n' "$PBRAIN_VAULT" > "$XDG_CONFIG_HOME/pbrain/vault"
  export PBRAIN_GRATITUDE_DIR="$TMP/gratitude"
  export PBRAIN_JOURNAL_DIR="$TMP/daily"
  export PBRAIN_SELF_IMPROVE=off
  TODAY="$(date +%Y-%m-%d)"
  CMD="$REPO_ROOT/commands/gratitude-journal.sh"
}

teardown() {
  rm -rf "$TMP"
}

_run_cmd() { run bash "$CMD" "$@"; }

@test "emits a GRATITUDE_JOURNAL_SESSION block with output_file" {
  _run_cmd
  [ "$status" -eq 0 ]
  [[ "$output" == *"GRATITUDE_JOURNAL_SESSION"* ]] && [[ "$output" == *"output_file:"* ]]
}

@test "injects today's journal entry into TODAY_JOURNAL_CONTEXT" {
  mkdir -p "$PBRAIN_JOURNAL_DIR"
  cat > "$PBRAIN_JOURNAL_DIR/$TODAY.md" <<EOF
---
type: daily
date: $TODAY
tags: []
---

## Focus
Ship the gratitude grounding change.

## Notes
Anxious about whether it lands. Talked to Maya.
EOF
  _run_cmd
  [ "$status" -eq 0 ]
  [[ "$output" == *"TODAY_JOURNAL_CONTEXT"* ]] && [[ "$output" == *"Ship the gratitude grounding change."* ]] && [[ "$output" == *"Talked to Maya."* ]]
}

@test "frontmatter is stripped from the injected journal context" {
  mkdir -p "$PBRAIN_JOURNAL_DIR"
  cat > "$PBRAIN_JOURNAL_DIR/$TODAY.md" <<EOF
---
type: daily
date: $TODAY
tags: []
---

## Focus
Real body line here.
EOF
  _run_cmd
  [ "$status" -eq 0 ]
  # The "type: daily" frontmatter key must not leak into the prompt body.
  [[ "$output" == *"Real body line here."* ]] && [[ "$output" != *"type: daily"* ]]
}

@test "missing journal falls back to the (no journal entry today) placeholder" {
  # No file written to PBRAIN_JOURNAL_DIR.
  _run_cmd
  [ "$status" -eq 0 ]
  [[ "$output" == *"TODAY_JOURNAL_CONTEXT"* ]] && [[ "$output" == *"(no journal entry today)"* ]]
}

@test "empty journal file also yields the placeholder" {
  mkdir -p "$PBRAIN_JOURNAL_DIR"
  : > "$PBRAIN_JOURNAL_DIR/$TODAY.md"
  _run_cmd
  [ "$status" -eq 0 ]
  [[ "$output" == *"(no journal entry today)"* ]]
}

@test "existing gratitude entry is shown and command exits without a session block" {
  mkdir -p "$PBRAIN_GRATITUDE_DIR"
  printf '%s\n' "already here" > "$PBRAIN_GRATITUDE_DIR/$TODAY.md"
  _run_cmd
  [ "$status" -eq 0 ]
  [[ "$output" == *"already here"* ]] && [[ "$output" != *"GRATITUDE_JOURNAL_SESSION"* ]]
}
