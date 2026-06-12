#!/usr/bin/env bats
# Tests for commands/monthly-review.sh — mechanical paths.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0
  export PBRAIN_UPDATE_CHECK=0
  export PBRAIN_VAULT="$TMP/vault"
  export XDG_CONFIG_HOME="$TMP/config"
  mkdir -p "$PBRAIN_VAULT" "$XDG_CONFIG_HOME/pbrain"
  export PBRAIN_SELF_IMPROVE=off
  export PBRAIN_DB_FILE="$TMP/pbrain.db"
  export PBRAIN_HABITS_PROFILE_FILE="$TMP/Habits Profile.md"
  TODAY="$(date +%Y-%m-%d)"
  MONTH_YEAR="$(date +%Y-%m)"
}

teardown() {
  rm -rf "$TMP"
}

MR() { bash "$REPO_ROOT/commands/monthly-review.sh" "$@"; }

@test "monthly review emits MONTHLY_REVIEW_SESSION" {
  run MR
  [ "$status" -eq 0 ]
  [[ "$output" == *"MONTHLY_REVIEW_SESSION"* ]]
}

@test "monthly review emits the current month" {
  run MR
  [[ "$output" == *"month: $MONTH_YEAR"* ]]
}

@test "monthly review emits output_file path" {
  run MR
  [[ "$output" == *"output_file:"* ]]
  [[ "$output" == *"$MONTH_YEAR.md"* ]]
}

@test "monthly review emits next_month_year" {
  run MR
  [[ "$output" == *"next_month_year:"* ]]
}

@test "existing monthly review short-circuits" {
  mkdir -p "$PBRAIN_VAULT/life/monthly-tracking"
  echo "already written" > "$PBRAIN_VAULT/life/monthly-tracking/$MONTH_YEAR.md"
  run MR
  [[ "$output" == *"already exists"* ]]
  [[ "$output" == *"already written"* ]]
}

@test "monthly review emits CORE PROFILES section" {
  run MR
  [[ "$output" == *"CORE PROFILES"* ]]
}

@test "monthly review emits MONTHLY GOALS section" {
  run MR
  [[ "$output" == *"MONTHLY GOALS"* ]]
}

@test "monthly review emits commands_dir" {
  run MR
  [[ "$output" == *"commands_dir:"* ]]
}

@test "monthly review INSTRUCTIONS contain monthly goals lifecycle" {
  run MR
  [[ "$output" == *"monthly goals"* ]] || [[ "$output" == *"monthly-goals"* ]]
}

@test "monthly review INSTRUCTIONS contain hygiene pass" {
  run MR
  [[ "$output" == *"hygiene"* ]] || [[ "$output" == *"maintenance_mode"* ]]
}
