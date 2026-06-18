#!/usr/bin/env bats
# Tests for lib/migrations.sh — the vault migration runner + ledger — and the
# real AUTO migrations (0001 prefs/feedback → vault, 0005 habits profile →
# store, 0006 food library → store).
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export VAULT_DIR="$TMP/vault"
  mkdir -p "$VAULT_DIR"
  export XDG_CONFIG_HOME="$TMP/config"
  mkdir -p "$XDG_CONFIG_HOME/pbrain"
  unset PBRAIN_MIGRATIONS PBRAIN_MIGRATIONS_SRC PBRAIN_MIGRATIONS_LEDGER
  unset PBRAIN_HABIT_TRACK_DIR PBRAIN_DIET_DIR PBRAIN_FITNESS_DIR PBRAIN_PLAN_DIR
  unset PBRAIN_FITNESS_ACTIVITIES_FILE PBRAIN_DIET_PROFILE_FILE
  source "$REPO_ROOT/lib/migrations.sh"
  LEDGER="$VAULT_DIR/.pbrain/migrations"
}

teardown() {
  rm -rf "$TMP"
}

# A sandbox migrations dir with controllable fake migrations.
make_fake_src() {
  FAKE_SRC="$TMP/migrations-src"
  mkdir -p "$FAKE_SRC"
  export PBRAIN_MIGRATIONS_SRC="$FAKE_SRC"
}

@test "runner is silent and records nothing on an empty migrations dir" {
  make_fake_src
  run pbrain_run_migrations
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "applicable AUTO migration applies once and is recorded" {
  make_fake_src
  cat > "$FAKE_SRC/0001_test.sh" <<EOF
MIGRATION_KIND=auto
migration_applicable() { [[ ! -f "$TMP/applied" ]]; }
migration_apply() { touch "$TMP/applied"; echo "did the thing"; }
EOF
  run pbrain_run_migrations
  [ "$status" -eq 0 ]
  [[ "$output" == *"did the thing"* ]]
  [[ "$output" == *"PBRAIN_MIGRATED 0001_test"* ]]
  [ -f "$TMP/applied" ]
  [ -f "$LEDGER/0001_test.done" ]
  # second run: ledger short-circuits — silent no-op
  run pbrain_run_migrations
  [ -z "$output" ]
}

@test "inapplicable AUTO migration is recorded vacuously without applying" {
  make_fake_src
  cat > "$FAKE_SRC/0001_test.sh" <<EOF
MIGRATION_KIND=auto
migration_applicable() { return 1; }
migration_apply() { touch "$TMP/applied"; }
EOF
  run pbrain_run_migrations
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$TMP/applied" ]
  [ -f "$LEDGER/0001_test.done" ]
}

@test "applicable STAGED migration stays pending; record flips it" {
  make_fake_src
  cat > "$FAKE_SRC/0002_test.sh" <<'EOF'
MIGRATION_KIND=staged
MIGRATION_OWNER="some-cmd"
migration_applicable() { return 0; }
EOF
  run pbrain_run_migrations
  [ "$status" -eq 0 ]
  [ ! -f "$LEDGER/0002_test.done" ]
  run pbrain_migration_pending 0002_test
  [ "$status" -eq 0 ]
  pbrain_migration_record 0002_test
  [ -f "$LEDGER/0002_test.done" ]
  run pbrain_migration_pending 0002_test
  [ "$status" -ne 0 ]
}

@test "inapplicable STAGED migration is recorded vacuously" {
  make_fake_src
  cat > "$FAKE_SRC/0002_test.sh" <<'EOF'
MIGRATION_KIND=staged
migration_applicable() { return 1; }
EOF
  run pbrain_run_migrations
  [ -f "$LEDGER/0002_test.done" ]
}

@test "a failing AUTO migration is left unrecorded (retried next run)" {
  make_fake_src
  cat > "$FAKE_SRC/0003_test.sh" <<'EOF'
MIGRATION_KIND=auto
migration_applicable() { return 0; }
migration_apply() { return 1; }
EOF
  run pbrain_run_migrations
  [ "$status" -eq 0 ]
  [ ! -f "$LEDGER/0003_test.done" ]
}

@test "migrations run in id order" {
  make_fake_src
  cat > "$FAKE_SRC/0002_b.sh" <<EOF
MIGRATION_KIND=auto
migration_applicable() { return 0; }
migration_apply() { echo two >> "$TMP/order"; }
EOF
  cat > "$FAKE_SRC/0001_a.sh" <<EOF
MIGRATION_KIND=auto
migration_applicable() { return 0; }
migration_apply() { echo one >> "$TMP/order"; }
EOF
  pbrain_run_migrations
  [ "$(head -1 "$TMP/order")" = "one" ]
  [ "$(tail -1 "$TMP/order")" = "two" ]
}

@test "PBRAIN_MIGRATIONS=0 disables the runner entirely" {
  make_fake_src
  cat > "$FAKE_SRC/0001_test.sh" <<EOF
MIGRATION_KIND=auto
migration_applicable() { return 0; }
migration_apply() { touch "$TMP/applied"; }
EOF
  PBRAIN_MIGRATIONS=0 run pbrain_run_migrations
  [ "$status" -eq 0 ]
  [ ! -f "$TMP/applied" ]
  [ ! -f "$LEDGER/0001_test.done" ]
}

@test "runner is a no-op without a vault dir" {
  make_fake_src
  cat > "$FAKE_SRC/0001_test.sh" <<EOF
MIGRATION_KIND=auto
migration_applicable() { return 0; }
migration_apply() { touch "$TMP/applied"; }
EOF
  VAULT_DIR="$TMP/does-not-exist" run pbrain_run_migrations
  [ "$status" -eq 0 ]
  [ ! -f "$TMP/applied" ]
}

@test "direct execution: record + pending round-trip" {
  make_fake_src
  cat > "$FAKE_SRC/0009_test.sh" <<'EOF'
MIGRATION_KIND=staged
migration_applicable() { return 0; }
EOF
  PBRAIN_VAULT="$VAULT_DIR" run bash "$REPO_ROOT/lib/migrations.sh" pending 0009_test
  [ "$output" = "pending" ]
  PBRAIN_VAULT="$VAULT_DIR" run bash "$REPO_ROOT/lib/migrations.sh" record 0009_test
  [ "$status" -eq 0 ]
  [ -f "$LEDGER/0009_test.done" ]
  PBRAIN_VAULT="$VAULT_DIR" run bash "$REPO_ROOT/lib/migrations.sh" pending 0009_test
  [ "$output" = "not-pending" ]
}

# ── real migration: 0001 prefs/feedback → vault ────────────────────────────

@test "0001 copies prefs + feedback into vault .pbrain (originals kept)" {
  mkdir -p "$XDG_CONFIG_HOME/pbrain/prefs" "$XDG_CONFIG_HOME/pbrain/feedback"
  echo "- global rule" > "$XDG_CONFIG_HOME/pbrain/prefs/_global.md"
  echo "- journal rule" > "$XDG_CONFIG_HOME/pbrain/prefs/journal.md"
  echo "- diet bug" > "$XDG_CONFIG_HOME/pbrain/feedback/diet-journal.md"
  run pbrain_run_migrations
  [ "$status" -eq 0 ]
  [[ "$output" == *"PBRAIN_MIGRATED 0001_prefs_feedback_to_vault"* ]]
  grep -q "global rule" "$VAULT_DIR/.pbrain/_global/prefs.md"
  grep -q "journal rule" "$VAULT_DIR/.pbrain/journal/prefs.md"
  grep -q "diet bug" "$VAULT_DIR/.pbrain/diet-journal/feedback.md"
  # originals untouched (copy, not move — ledger is per-vault)
  [ -f "$XDG_CONFIG_HOME/pbrain/prefs/journal.md" ]
  [ -f "$LEDGER/0001_prefs_feedback_to_vault.done" ]
}

@test "0001 merges into an existing destination instead of clobbering" {
  mkdir -p "$XDG_CONFIG_HOME/pbrain/prefs" "$VAULT_DIR/.pbrain/journal"
  echo "- old machine rule" > "$XDG_CONFIG_HOME/pbrain/prefs/journal.md"
  echo "- already-in-vault rule" > "$VAULT_DIR/.pbrain/journal/prefs.md"
  pbrain_run_migrations
  grep -q "already-in-vault rule" "$VAULT_DIR/.pbrain/journal/prefs.md"
  grep -q "old machine rule" "$VAULT_DIR/.pbrain/journal/prefs.md"
}

@test "0001 records vacuously when there is nothing to migrate" {
  run pbrain_run_migrations
  [ -z "$output" ]
  [ -f "$LEDGER/0001_prefs_feedback_to_vault.done" ]
}

# ── real migration: 0005 habits profile → store ────────────────────────────

@test "0005 moves the habits profile into the versioned store, committed" {
  mkdir -p "$VAULT_DIR/life"
  cat > "$VAULT_DIR/life/Habits Profile.md" <<'EOF'
---
type: habits-profile
date: 2026-06-01
tags: []
---

# Habits profile

```json
{"created": "2026-06-01", "habits": []}
```
EOF
  run pbrain_run_migrations
  [[ "$output" == *"PBRAIN_MIGRATED 0005_habits_profile_to_store"* ]]
  local dest="$VAULT_DIR/life/habit-tracking/.profile/habits-profile.v1.md"
  [ -f "$dest" ]
  grep -q '^version: 1$' "$dest"
  grep -q '^committed: true$' "$dest"
  grep -q '"habits": \[\]' "$dest"
  # original parked in backup, not deleted
  [ ! -f "$VAULT_DIR/life/Habits Profile.md" ]
  [ -f "$VAULT_DIR/.pbrain/backup/Habits Profile.md" ]
}

@test "0005 is vacuous when the store is already populated" {
  mkdir -p "$VAULT_DIR/life/habit-tracking/.profile"
  printf -- '---\nversion: 1\ncommitted: true\n---\nx\n' \
    > "$VAULT_DIR/life/habit-tracking/.profile/habits-profile.v1.md"
  mkdir -p "$VAULT_DIR/life"
  echo "legacy" > "$VAULT_DIR/life/Habits Profile.md"
  run pbrain_run_migrations
  [[ "$output" != *"0005"* ]]
  # legacy file untouched (store already won)
  [ -f "$VAULT_DIR/life/Habits Profile.md" ]
}

# ── real migration: 0006 food library → store ──────────────────────────────

@test "0006 moves the food library into the diet store" {
  mkdir -p "$VAULT_DIR/fitness"
  cat > "$VAULT_DIR/fitness/Food Library.md" <<'EOF'
---
type: food-library
created: 2026-06-01
tags: []
---

# Food Library

| Item | Description |
|---|---|
| Protein shake | whey + milk |
EOF
  run pbrain_run_migrations
  [[ "$output" == *"PBRAIN_MIGRATED 0006_food_library_to_store"* ]]
  local dest="$VAULT_DIR/fitness/diet-tracking/.profile/food-library.v1.md"
  [ -f "$dest" ]
  grep -q '^committed: true$' "$dest"
  grep -q 'Protein shake' "$dest"
  [ ! -f "$VAULT_DIR/fitness/Food Library.md" ]
  [ -f "$VAULT_DIR/.pbrain/backup/Food Library.md" ]
}

# ── staged migration applicability (0002/0003/0004) ────────────────────────

@test "0002 pending when an old goals profile exists and the store is empty" {
  mkdir -p "$VAULT_DIR/life"
  echo "old profile" > "$VAULT_DIR/life/Goals Profile.md"
  run pbrain_migration_pending 0002_plans_profile_rebuild
  [ "$status" -eq 0 ]
  # populate the store → no longer applicable → vacuous-record on next run
  mkdir -p "$VAULT_DIR/life/daily-planning/.profile"
  printf -- '---\nversion: 1\ncommitted: true\n---\nx\n' \
    > "$VAULT_DIR/life/daily-planning/.profile/plans-profile.v1.md"
  run pbrain_migration_pending 0002_plans_profile_rebuild
  [ "$status" -ne 0 ]
}

@test "0003 pending when fitness-activities.json exists and the store is empty" {
  echo '{"activities":["Gym"]}' > "$XDG_CONFIG_HOME/pbrain/fitness-activities.json"
  run pbrain_migration_pending 0003_fitness_profiles
  [ "$status" -eq 0 ]
  mkdir -p "$VAULT_DIR/fitness/daily-tracking/.profile"
  printf -- '---\nversion: 1\ncommitted: true\n---\nx\n' \
    > "$VAULT_DIR/fitness/daily-tracking/.profile/fitness-library.v1.md"
  run pbrain_migration_pending 0003_fitness_profiles
  [ "$status" -ne 0 ]
}

@test "0004 pending when an old diet plan exists and the store is empty" {
  mkdir -p "$VAULT_DIR/fitness"
  echo "old diet plan" > "$VAULT_DIR/fitness/Diet Plan.md"
  run pbrain_migration_pending 0004_diet_profile_combine
  [ "$status" -eq 0 ]
  mkdir -p "$VAULT_DIR/fitness/diet-tracking/.profile"
  printf -- '---\nversion: 1\ncommitted: true\n---\nx\n' \
    > "$VAULT_DIR/fitness/diet-tracking/.profile/diet-profile.v1.md"
  run pbrain_migration_pending 0004_diet_profile_combine
  [ "$status" -ne 0 ]
}

@test "fresh user: all real migrations record vacuously in one run" {
  run pbrain_run_migrations
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  for id in 0001_prefs_feedback_to_vault 0002_plans_profile_rebuild \
            0003_fitness_profiles 0004_diet_profile_combine \
            0005_habits_profile_to_store 0006_food_library_to_store \
            0007_goals_project_reframe; do
    [ -f "$LEDGER/$id.done" ]
  done
}

@test "0007 pending when a goals file lacks allocation_percent; not once it has it" {
  store="$VAULT_DIR/life/daily-planning/.profile"
  mkdir -p "$store"
  # legacy weekly-goals (task-level, no allocation_percent) → pending
  cat > "$store/weekly-goals.v1.md" <<'EOF'
---
type: weekly-goals
period: 2026-W24
version: 1
committed: false
---
```json
{"period":"2026-W24","goals":[{"id":"g1","goal":"ship","tie":"lt/w1","priority":1,"status":"active"}]}
```
EOF
  run pbrain_migration_pending 0007_goals_project_reframe
  [ "$status" -eq 0 ]
  # once reframed (allocation_percent present) → not pending
  cat > "$store/weekly-goals.v1.md" <<'EOF'
---
type: weekly-goals
period: 2026-W24
version: 1
committed: false
---
```json
{"period":"2026-W24","goals":[{"id":"g1","goal":"ship","plane_project":"uuid-1","project_name":"Lettuce","priority":1,"allocation_percent":100,"status":"active"}]}
```
EOF
  run pbrain_migration_pending 0007_goals_project_reframe
  [ "$status" -ne 0 ]
}

@test "0007 not pending for a fresh user with no goals files" {
  run pbrain_migration_pending 0007_goals_project_reframe
  [ "$status" -ne 0 ]
}

# ── real migration: 0009 scored-habit values → 0–1 unit scale ───────────────

# A committed habits profile + a dated md + a DB, all carrying old 0–100 scored
# values, plus a measured habit that must NOT be rescaled.
_seed_unit_scale_fixtures() {
  mkdir -p "$VAULT_DIR/life/habit-tracking/.profile"
  cat > "$VAULT_DIR/life/habit-tracking/.profile/habits-profile.v1.md" <<'EOF'
---
type: habits-profile
version: 1
committed: true
---

```json
{"created":"2026-06-01","habits":[
  {"id":"eat-clean","name":"Eat clean","schedule_type":"weekly","direction":"at_least","priority":"high","archived":false,"unit":"","measure_target":7,"scoring":{"type":"slip_ladder","good_target":3,"ladder":[1.0,0.6,0.3,0]}},
  {"id":"sleep-well","name":"Sleep well","schedule_type":"daily","direction":"at_least","priority":"high","archived":false,"unit":"","measure_target":100,"scoring":{"type":"deviation","normal_time":"23:00","normal_hours":8.0,"unit_minutes":30,"unit_hours":0.5,"ladder":[100,90,75,50,25,0]}},
  {"id":"deep-work","name":"Deep work","schedule_type":"daily","direction":"at_least","priority":"high","archived":false,"unit":"","measure_target":75,"scoring":{"type":"focus_ratio","work_categories":["work"],"distraction_categories":["social"]}},
  {"id":"water","name":"Water","schedule_type":"daily","direction":"at_least","priority":"medium","archived":false,"unit":"L","measure_target":4}
]}
```
EOF
  cat > "$VAULT_DIR/life/habit-tracking/2026-06-17.md" <<'EOF'
| Habit | Criteria | Progress | Done | Count | Note |
|-------|----------|----------|------|-------|------|
| Sleep well | daily ≥100 | 50/100 day | x | 50 |  |
| Deep work | daily ≥100 | 82/100 day | x | 82 |  |
| Eat clean | weekly ≥7 | 0.6/7 wk | x | 0.6 | one slip |
| Water | daily ≥4 | 2.5/4 day | x | 2.5 |  |
EOF
  export PBRAIN_DB_FILE="$TMP/pbrain.db"
  python3 - "$PBRAIN_DB_FILE" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE habit_events (habit_id TEXT, occurred_on TEXT, count INTEGER, amount REAL)")
c.executemany("INSERT INTO habit_events VALUES (?,?,?,?)", [
  ("sleep-well","2026-06-17",1,50.0),
  ("deep-work","2026-06-17",1,82.0),
  ("eat-clean","2026-06-17",1,0.6),   # already unit — must stay
  ("water","2026-06-17",1,2.5),       # measured non-scored — must stay
])
c.commit()
PY
}

@test "0009 rescales scored profile targets/ladders, md Count and DB; leaves eat-clean + measured" {
  _seed_unit_scale_fixtures
  run pbrain_run_migrations
  [[ "$output" == *"PBRAIN_MIGRATED 0009_habit_scores_to_unit_scale"* ]]
  local prof="$VAULT_DIR/life/habit-tracking/.profile/habits-profile.v1.md"
  # profile: sleep-well ladder + targets → 0–1; eat-clean untouched
  run python3 - "$prof" <<'PY'
import json,re,sys
d=json.loads(re.search(r"```json\s*\n(.*?)```",open(sys.argv[1]).read(),re.S).group(1))
h={x["id"]:x for x in d["habits"]}
ok=(h["sleep-well"]["scoring"]["ladder"]==[1.0,0.9,0.75,0.5,0.25,0.0]
    and h["sleep-well"]["measure_target"]==1.0
    and h["deep-work"]["measure_target"]==0.75
    and h["eat-clean"]["scoring"]["ladder"]==[1.0,0.6,0.3,0]
    and h["eat-clean"]["measure_target"]==7
    and h["water"]["measure_target"]==4)
print("OK" if ok else "BAD:"+json.dumps(h))
PY
  [ "$output" = "OK" ]
  # md Count: scored rows ÷100, eat-clean + water untouched
  run cat "$VAULT_DIR/life/habit-tracking/2026-06-17.md"
  [[ "$output" == *"| Sleep well "*"| 0.5 |"* ]]
  [[ "$output" == *"| Deep work "*"| 0.82 |"* ]]
  [[ "$output" == *"| Eat clean "*"| 0.6 |"* ]]
  [[ "$output" == *"| Water "*"| 2.5 |"* ]]
  # DB: scored ÷100, eat-clean + water untouched
  run sqlite3 "$PBRAIN_DB_FILE" "SELECT habit_id||'='||amount FROM habit_events ORDER BY habit_id"
  [[ "$output" == *"deep-work=0.82"* ]]
  [[ "$output" == *"sleep-well=0.5"* ]]
  [[ "$output" == *"eat-clean=0.6"* ]]
  [[ "$output" == *"water=2.5"* ]]
  # backups parked; idempotent on re-run
  [ -f "$VAULT_DIR/.pbrain/backup/habits-profile.v1.md.pre-0009" ]
  run pbrain_run_migrations
  [[ "$output" != *"0009_habit_scores_to_unit_scale"* ]]
}

@test "0009 is vacuous when all scored values are already on the 0–1 scale" {
  mkdir -p "$VAULT_DIR/life/habit-tracking/.profile"
  cat > "$VAULT_DIR/life/habit-tracking/.profile/habits-profile.v1.md" <<'EOF'
---
type: habits-profile
version: 1
committed: true
---
```json
{"habits":[{"id":"deep-work","name":"Deep work","schedule_type":"daily","measure_target":0.75,"archived":false,"scoring":{"type":"focus_ratio"}}]}
```
EOF
  run pbrain_run_migrations
  [[ "$output" != *"0009_habit_scores_to_unit_scale"* ]]
  [ -f "$VAULT_DIR/.pbrain/migrations/0009_habit_scores_to_unit_scale.done" ]
}
