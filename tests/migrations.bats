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
            0005_habits_profile_to_store 0006_food_library_to_store; do
    [ -f "$LEDGER/$id.done" ]
  done
}
