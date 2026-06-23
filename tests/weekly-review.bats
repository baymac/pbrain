#!/usr/bin/env bats
# Tests for commands/weekly-review.sh — the mechanical paths: store-based CORE
# PROFILES, the Improvements flow markers, and graceful empties.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0   # keep the vault migration runner out of unit tests
  export PBRAIN_UPDATE_CHECK=0
  export PBRAIN_VAULT="$TMP/vault"
  export XDG_CONFIG_HOME="$TMP/config"
  mkdir -p "$PBRAIN_VAULT" "$XDG_CONFIG_HOME/pbrain"
  export PBRAIN_SELF_IMPROVE=off
  export PBRAIN_DB_FILE="$TMP/pbrain.db"
  export PBRAIN_HABITS_PROFILE_FILE="$TMP/Habits Profile.md"
  TODAY="$(date +%Y-%m-%d)"
}

teardown() {
  rm -rf "$TMP"
}

WR() { bash "$REPO_ROOT/commands/weekly-review.sh" "$@"; }

@test "emits CORE PROFILES section with graceful placeholders when no stores exist" {
  run WR
  [ "$status" -eq 0 ]
  [[ "$output" == *"WEEKLY_REVIEW_SESSION"* ]]
  [[ "$output" == *"--- CORE PROFILES (for Step 4 improvements) ---"* ]]
  [[ "$output" == *"no committed version yet"* ]]
  [[ "$output" == *"## Improvements"* ]]
}

@test "emits commands_dir for the profile-versioning instructions" {
  run WR
  [[ "$output" == *"commands_dir: $REPO_ROOT/commands"* ]]
  [[ "$output" == *"profile new"* ]]
  [[ "$output" == *"profile commit"* ]]
}

@test "committed profiles from the stores are included with version paths" {
  mkdir -p "$PBRAIN_VAULT/life/daily-planning/.profile" \
           "$PBRAIN_VAULT/fitness/diet-tracking/.profile" \
           "$PBRAIN_VAULT/fitness/daily-tracking/.profile"
  printf -- '---\nversion: 1\ncommitted: true\n---\n# Goals profile\nGOALS-MARKER\n' \
    > "$PBRAIN_VAULT/life/daily-planning/.profile/goals-profile.v1.md"
  printf -- '---\nversion: 2\ncommitted: true\n---\n# Diet profile\nDIET-MARKER-V2\n' \
    > "$PBRAIN_VAULT/fitness/diet-tracking/.profile/diet-profile.v2.md"
  printf -- '---\nversion: 1\ncommitted: true\n---\n# Fitness profile\nFIT-MARKER\n' \
    > "$PBRAIN_VAULT/fitness/daily-tracking/.profile/fitness-profile.v1.md"
  run WR
  [[ "$output" == *"GOALS-MARKER"* ]]
  [[ "$output" == *"DIET-MARKER-V2"* ]]
  [[ "$output" == *"FIT-MARKER"* ]]
  [[ "$output" == *"goals-profile.v1.md"* ]]
  [[ "$output" == *"diet-profile.v2.md"* ]]
}

@test "no legacy plan-file env vars are referenced" {
  run WR
  [[ "$output" != *"Diet Plan.md"* ]]
  [[ "$output" != *"Gym Plan.md"* ]]
  [[ "$output" != *"Proposed plan changes"* ]]
}

@test "existing review for the previous week short-circuits" {
  # A no-arg run defaults to the PREVIOUS completed week (PB-63), so the
  # short-circuit keys off that week's file, not the current one.
  local iso
  iso="$(python3 -c "import datetime; t=datetime.date.today()-datetime.timedelta(days=7); y,w,_=t.isocalendar(); print(f'{y}-W{w:02d}')")"
  mkdir -p "$PBRAIN_VAULT/life/weekly-tracking"
  echo "already written" > "$PBRAIN_VAULT/life/weekly-tracking/$iso.md"
  run WR
  [[ "$output" == *"already exists"* ]]
  [[ "$output" == *"already written"* ]]
}

@test "no-arg run defaults to the previous completed week (PB-63)" {
  # iso_week → previous completed week; next_iso_week → the now-current week.
  local prev_iso cur_iso
  prev_iso="$(python3 -c "import datetime; t=datetime.date.today()-datetime.timedelta(days=7); y,w,_=t.isocalendar(); print(f'{y}-W{w:02d}')")"
  cur_iso="$(python3 -c "import datetime; t=datetime.date.today(); y,w,_=t.isocalendar(); print(f'{y}-W{w:02d}')")"
  run WR
  [ "$status" -eq 0 ]
  [[ "$output" == *"iso_week: $prev_iso"* ]]
  [[ "$output" == *"next_iso_week: $cur_iso"* ]]
  [[ "$output" == *"output_file: "*"$prev_iso.md"* ]]
}

@test "--date anchors on the ISO week containing that exact date" {
  # Explicit anchor is respected as-is — no 7-day shift (retroactive reviews).
  run WR --date 2026-06-10   # Wed of 2026-W24 (Mon 2026-06-08 → Sun 2026-06-14)
  [ "$status" -eq 0 ]
  [[ "$output" == *"iso_week: 2026-W24"* ]]
  [[ "$output" == *"date_range: 2026-06-08 → 2026-06-14"* ]]
  [[ "$output" == *"next_iso_week: 2026-W25"* ]]
}

@test "script source carries no declutter references" {
  ! grep -qi declutter "$REPO_ROOT/commands/weekly-review.sh"
  ! grep -qi declutter "$REPO_ROOT/commands/end-of-day.sh"
}

# ── weekly goals lifecycle ───────────────────────────────────────────────────

@test "weekly review emits weekly goals section" {
  run WR
  [ "$status" -eq 0 ]
  [[ "$output" == *"WEEKLY GOALS"* ]]
}

@test "weekly review emits the work-tracker rows section" {
  run WR
  [[ "$output" == *"THIS WEEK'S WORK TRACKER ROWS"* ]]
}

@test "weekly review injects project registry + progress + a Work review section" {
  run WR
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROJECT REGISTRY (registry_json)"* ]]
  [[ "$output" == *"PROJECT PROGRESS (progress_json"* ]]
  [[ "$output" == *"## Work review"* ]]
  [[ "$output" == *"Step 3w"* ]]
}

@test "weekly review goals minting uses project-level fields (plane_project + allocation_percent)" {
  run WR
  [[ "$output" == *"plane_project"* ]]
  [[ "$output" == *"allocation_percent"* ]]
}

@test "weekly review emits next_iso_week in output" {
  run WR
  [[ "$output" == *"next_iso_week:"* ]]
}

@test "weekly review emits monthly goals section" {
  run WR
  [[ "$output" == *"MONTHLY GOALS"* ]]
}

@test "weekly review instructions include Weekly Goals lifecycle step" {
  run WR
  [[ "$output" == *"Weekly Goals lifecycle"* ]] || [[ "$output" == *"Weekly goals lifecycle"* ]] || [[ "$output" == *"Step 4b"* ]]
}
