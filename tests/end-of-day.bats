#!/usr/bin/env bats
# Tests for commands/end-of-day.sh — focused on the --date argument added in
# feat/laptop-tracking-status: parsing, validation, and DOW computation.
#
# The full close-of-day reflection flow requires a vault and LLM output, so
# this file pins only the argument-handling and date-validation layer.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_VAULT="$TMP/vault"
  export PBRAIN_PLAN_DIR="$TMP/plans"
  export PBRAIN_JOURNAL_DIR="$TMP/journal"
  export PBRAIN_FITNESS_DIR="$TMP/fitness"
  export PBRAIN_DIET_DIR="$TMP/diet"
  export PBRAIN_DB_FILE="$TMP/pbrain.db"
  export PBRAIN_SELF_IMPROVE=off
  export PBRAIN_NO_UPDATE_CHECK=1
  # Stub Apple-facing tools so launchd/swiftc never run
  mkdir -p "$TMP/bin"
  for c in launchctl swiftc codesign; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/$c"; chmod +x "$TMP/bin/$c"
  done
  export PATH="$TMP/bin:$PATH"
  mkdir -p "$PBRAIN_VAULT" "$PBRAIN_PLAN_DIR" "$PBRAIN_JOURNAL_DIR" "$PBRAIN_FITNESS_DIR" "$PBRAIN_DIET_DIR"
  SH="$REPO_ROOT/commands/end-of-day.sh"
}

teardown() {
  rm -rf "$TMP"
}

EOD() { bash "$SH" "$@"; }

# --- date validation ---------------------------------------------------------

@test "end-of-day: bad date format exits 1 with an error message" {
  run EOD --date not-a-date
  [ "$status" -eq 1 ]
  [[ "$output" == *"Bad date"* || "$stderr" == *"Bad date"* ]] || \
    [[ "$(bash "$SH" --date not-a-date 2>&1; echo "EXIT:$?")" == *"Bad date"* ]]
}

@test "end-of-day: --date YYYY-MM-DD is accepted (exit 0)" {
  run EOD --date 2026-06-03
  [ "$status" -eq 0 ]
}

@test "end-of-day: bare YYYY-MM-DD positional arg is accepted (exit 0)" {
  run EOD 2026-06-03
  [ "$status" -eq 0 ]
}

@test "end-of-day: --date sets the target date visible in output" {
  run EOD --date 2026-06-01
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-06-01"* ]]
}

@test "end-of-day: DOW is computed for the given past date (not just today)" {
  # 2026-06-01 is a Monday
  run EOD --date 2026-06-01
  [ "$status" -eq 0 ]
  [[ "$output" == *"Monday"* ]]
}
