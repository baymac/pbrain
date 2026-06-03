#!/usr/bin/env bats
# Tests for lib/habits.sh — profile JSON extraction, rollup, and the ride-along
# extraction emitter. Plus the commands/habits.sh `log` idempotency contract.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_DB_FILE="$TMP/pbrain.db"
  export PBRAIN_HABITS_PROFILE_FILE="$TMP/Habits Profile.md"
  source "$REPO_ROOT/lib/profile.sh"   # pbrain_profile_json (habits.sh depends on it)
  source "$REPO_ROOT/lib/db.sh"
  source "$REPO_ROOT/lib/habits.sh"
  pbrain_db_init
}

teardown() {
  rm -rf "$TMP"
}

_write_profile() {
  cat > "$PBRAIN_HABITS_PROFILE_FILE" <<'EOF'
---
type: habits-profile
date: 2026-06-03
tags: []
---

# Habits profile

```json
{
  "created": "2026-06-03",
  "habits": [
    { "name": "Meditate", "kind": "build", "priority": "high", "cap_period": "week", "cap_count": 7 },
    { "name": "Alcohol", "kind": "limit", "priority": "medium", "cap_period": "week", "cap_count": 2 }
  ]
}
EOF
  printf '```\n' >> "$PBRAIN_HABITS_PROFILE_FILE"
}

_log_event() {  # _log_event <habit> <date>
  python3 - "$PBRAIN_DB_FILE" "$1" "$2" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("insert into habit_events(habit,occurred_on,count,source,created_at) values(?,?,1,'t','t') "
          "on conflict(habit,occurred_on) do nothing", (sys.argv[2], sys.argv[3]))
c.commit()
PY
}

@test "habits_json is empty when no profile exists" {
  run pbrain_habits_json
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "habits_json extracts valid JSON from the fenced block" {
  _write_profile
  run pbrain_habits_json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"Meditate"'* ]]
  echo "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

@test "rollup is empty when no profile exists" {
  run pbrain_habits_rollup 2026-06-03
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "rollup counts the week and flags a limit habit over cap" {
  _write_profile
  # Week of Wed 2026-06-03 is Mon 06-01 .. Sun 06-07.
  _log_event Alcohol 2026-06-01
  _log_event Alcohol 2026-06-02
  _log_event Alcohol 2026-06-03
  run pbrain_habits_rollup 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" == *"Alcohol"* ]]
  [[ "$output" == *"3 this week"* ]]
  [[ "$output" == *"OVER cap"* ]]
}

@test "rollup shows a build habit with its target and counts" {
  _write_profile
  _log_event Meditate 2026-06-03
  run pbrain_habits_rollup 2026-06-03
  [[ "$output" == *"Meditate"* ]]
  [[ "$output" == *"target 7/week"* ]]
  [[ "$output" == *"1 this week"* ]]
}

@test "rollup flags a limit habit sitting exactly at cap" {
  _write_profile
  # Alcohol cap is 2/week; log exactly 2 in the week of 2026-06-03.
  _log_event Alcohol 2026-06-01
  _log_event Alcohol 2026-06-02
  run pbrain_habits_rollup 2026-06-03
  [[ "$output" == *"Alcohol"* ]]
  [[ "$output" == *"at cap"* ]]
  [[ "$output" != *"OVER cap"* ]]
}

@test "rollup flags a build habit that met its target" {
  _write_profile
  # Meditate target is 7/week; log all 7 days of the week.
  for d in 01 02 03 04 05 06 07; do _log_event Meditate "2026-06-$d"; done
  run pbrain_habits_rollup 2026-06-03
  [[ "$output" == *"Meditate"* ]]
  [[ "$output" == *"target met"* ]]
}

@test "rollup nudges a high-priority build habit with nothing logged this week" {
  _write_profile
  # Meditate is build + high priority; log nothing this week.
  run pbrain_habits_rollup 2026-06-03
  [[ "$output" == *"Meditate"* ]]
  [[ "$output" == *"nothing logged this week"* ]]
  [[ "$output" == *"never logged"* ]]
}

@test "emit_habits_extract is silent without a profile" {
  run pbrain_emit_habits_extract journal
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emit_habits_extract emits a block naming the habits + the log command" {
  _write_profile
  run pbrain_emit_habits_extract journal
  [ "$status" -eq 0 ]
  [[ "$output" == *"HABIT EXTRACTION (journal)"* ]]
  [[ "$output" == *"Meditate"* ]]
  [[ "$output" == *"habits.sh"* ]]
  [[ "$output" == *"--source journal"* ]]
}

@test "habits.sh log is idempotent per (habit, day)" {
  export PBRAIN_VAULT="$TMP/vault"; mkdir -p "$PBRAIN_VAULT"
  export PBRAIN_SELF_IMPROVE=off
  bash "$REPO_ROOT/commands/habits.sh" log --name "Walk" --date 2026-06-03 --source journal
  bash "$REPO_ROOT/commands/habits.sh" log --name "Walk" --date 2026-06-03 --source plan-my-day
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute(\"select count(*) from habit_events where habit='Walk' and occurred_on='2026-06-03'\").fetchone()[0])" "$PBRAIN_DB_FILE"
  [ "$output" = "1" ]
}
