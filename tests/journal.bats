#!/usr/bin/env bats
# Tests for commands/journal.sh — the quiet daily journal command.
# Focus: PB-57 — the dump passed as a command argument is auto-ingested
# (no "Ready when you are." wait), and the open-questions interview is run
# rather than skipped. Both the fresh-day and resume paths honour the arg.
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
  export PBRAIN_JOURNAL_DIR="$TMP/daily"
  export PBRAIN_SELF_IMPROVE=off
  TODAY="$(date +%Y-%m-%d)"
  CMD="$REPO_ROOT/commands/journal.sh"
}

teardown() {
  rm -rf "$TMP"
}

_run_cmd() { run bash "$CMD" "$@"; }

# --- fresh day -------------------------------------------------------------

@test "fresh day, no arg: emits JOURNAL_SESSION and waits with 'Ready when you are.'" {
  _run_cmd
  [ "$status" -eq 0 ]
  [[ "$output" == *"JOURNAL_SESSION"* ]]
  [[ "$output" == *"dump_provided: no"* ]]
  [[ "$output" == *"Ready when you are."* ]]
}

@test "fresh day, with a dump arg: ingests it and is told NOT to wait" {
  _run_cmd "shipped the auth refactor, unsure whether to cut the v2 dashboard"
  [ "$status" -eq 0 ]
  [[ "$output" == *"JOURNAL_SESSION"* ]]
  [[ "$output" == *"dump_provided: yes"* ]]
  # the provided dump is surfaced for ingestion
  [[ "$output" == *"shipped the auth refactor, unsure whether to cut the v2 dashboard"* ]]
  # and the instruction explicitly forbids the wait on the yes path
  [[ "$output" == *'Do NOT say "Ready when you are."'* ]]
}

@test "fresh day: the open-questions interview is a hard gate, not skippable" {
  _run_cmd
  [ "$status" -eq 0 ]
  [[ "$output" == *"MUST run the interview"* ]]
  [[ "$output" == *"Do NOT skip the"* ]]
  [[ "$output" == *"actually asked"* ]]
}

# --- resume (existing file) ------------------------------------------------

@test "resume, no arg: emits JOURNAL_SESSION_RESUME and offers to wait" {
  mkdir -p "$PBRAIN_JOURNAL_DIR"
  printf '%s\n' "## Focus" "existing entry" > "$PBRAIN_JOURNAL_DIR/$TODAY.md"
  _run_cmd
  [ "$status" -eq 0 ]
  [[ "$output" == *"JOURNAL_SESSION_RESUME"* ]]
  [[ "$output" == *"dump_provided: no"* ]]
}

@test "resume, with a dump arg: ingests it without waiting" {
  mkdir -p "$PBRAIN_JOURNAL_DIR"
  printf '%s\n' "## Focus" "existing entry" > "$PBRAIN_JOURNAL_DIR/$TODAY.md"
  _run_cmd "quick note: deploy went out clean at 4pm"
  [ "$status" -eq 0 ]
  [[ "$output" == *"JOURNAL_SESSION_RESUME"* ]]
  [[ "$output" == *"dump_provided: yes"* ]]
  [[ "$output" == *"quick note: deploy went out clean at 4pm"* ]]
}
