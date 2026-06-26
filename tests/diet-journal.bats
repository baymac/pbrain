#!/usr/bin/env bats
# Tests for commands/diet-journal.sh — the mechanical (non-LLM) paths:
# migration gating, setup/draft phases, profile-driven meal meta, env
# overrides, the food-library stub, and the profile subcommand.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0   # keep the vault migration runner out of unit tests
  export PBRAIN_VAULT="$TMP/vault"
  export XDG_CONFIG_HOME="$TMP/config"
  mkdir -p "$PBRAIN_VAULT" "$XDG_CONFIG_HOME/pbrain"
  export PBRAIN_SELF_IMPROVE=off
  export PBRAIN_UPDATE_CHECK=0
  DIET="$PBRAIN_VAULT/fitness/diet-tracking"
  STORE="$DIET/.profile"
  TODAY="$(date +%Y-%m-%d)"
}

teardown() {
  rm -rf "$TMP"
}

DIETJ() { bash "$REPO_ROOT/commands/diet-journal.sh" "$@"; }

write_profile() {
  mkdir -p "$STORE"
  cat > "$STORE/diet-profile.v1.md" <<EOF
---
type: diet-profile
date: $TODAY
version: 1
committed: true
---

# Diet profile

\`\`\`json
{"created": "$TODAY", "weight_kg": 80, "height_cm": 180, "age": 30,
 "sex": "male", "activity_level": "moderate", "goal": "fat_loss",
 "conditions": [], "dietary_preference": "omnivore",
 "eating_window": "8am-9pm",
 "targets": {"calories": 2200, "protein_g": 160, "carbs_g": 200,
             "fat_g": 70, "fiber_g": 35, "water_l": 3},
 "macro_approach": "standard",
 "meal_pattern": "3 meals + 1 snack",
 "meal_slots": ["Breakfast", "Lunch", "Snack", "Dinner"],
 "meal_times": {"Breakfast": "09:00", "Lunch": "13:30", "Snack": "17:00", "Dinner": "20:30"}}
\`\`\`

## Meal structure (typical day)

### Breakfast — 09:00
EOF
}

# ── migration gating ─────────────────────────────────────────────────────────

@test "migration block fires when an old Diet Plan exists and store is empty" {
  mkdir -p "$PBRAIN_VAULT/fitness"
  echo "old plan" > "$PBRAIN_VAULT/fitness/Diet Plan.md"
  PBRAIN_MIGRATIONS=1 run DIETJ
  [ "$status" -eq 0 ]
  [[ "$output" == *"DIET_JOURNAL_MIGRATION"* ]]
  [[ "$output" == *"record 0004_diet_profile_combine"* ]]
}

@test "no migration block once the store is populated" {
  mkdir -p "$PBRAIN_VAULT/fitness"
  echo "old plan" > "$PBRAIN_VAULT/fitness/Diet Plan.md"
  write_profile
  PBRAIN_MIGRATIONS=1 run DIETJ
  [[ "$output" != *"DIET_JOURNAL_MIGRATION"* ]]
  [[ "$output" == *"DIET_JOURNAL_SESSION"* ]]
}

# ── setup / draft phases ─────────────────────────────────────────────────────

@test "fresh user gets the single setup block (profile, not plan)" {
  run DIETJ
  [ "$status" -eq 0 ]
  [[ "$output" == *"DIET_JOURNAL_SETUP_PROFILE"* ]]
  [[ "$output" == *"diet-profile.v1.md"* ]]
  [[ "$output" != *"DIET_JOURNAL_SETUP_PLAN"* ]]
}

@test "open draft short-circuits to the draft-continuation block" {
  mkdir -p "$STORE"
  cat > "$STORE/diet-profile.v1.md" <<EOF
---
type: diet-profile
version: 1
committed: false
---
# Diet profile
\`\`\`json
{"created": "$TODAY"}
\`\`\`
EOF
  run DIETJ
  [[ "$output" == *"DIET_PROFILE_DRAFT_OPEN"* ]]
  [[ "$output" == *"profile commit diet-profile"* ]]
}

# ── daily flow ───────────────────────────────────────────────────────────────

@test "daily flow reads slots, approach, and times from the stored profile" {
  write_profile
  run DIETJ
  [ "$status" -eq 0 ]
  [[ "$output" == *"DIET_JOURNAL_SESSION"* ]]
  [[ "$output" == *"Breakfast|Lunch|Snack|Dinner"* ]] || [[ "$output" == *"meal_pattern: 3 meals + 1 snack"* ]]
  [[ "$output" == *"macro_approach: standard"* ]]
  [[ "$output" == *"Breakfast 09:00"* ]]
}

@test "env-override profile file (legacy raw JSON) is honored" {
  cat > "$TMP/legacy.json" <<EOF
{"created": "$TODAY", "goal": "fat_loss", "eating_window": "16:8",
 "dietary_preference": "omnivore"}
EOF
  PBRAIN_DIET_PROFILE_FILE="$TMP/legacy.json" run DIETJ
  [ "$status" -eq 0 ]
  [[ "$output" == *"DIET_JOURNAL_SESSION"* ]]
  # slots derived from the 16:8 window fallback
  [[ "$output" == *"Lunch|Snack|Dinner"* ]] || [[ "$output" == *"IF/16:8"* ]]
}

@test "food-library stub is auto-created committed in the store" {
  write_profile
  run DIETJ
  [ -f "$STORE/food-library.v1.md" ]
  grep -q '^committed: true$' "$STORE/food-library.v1.md"
  grep -q '## Home / regular foods' "$STORE/food-library.v1.md"
}

@test "existing entry today routes to update mode" {
  write_profile
  mkdir -p "$DIET"
  echo "entry" > "$DIET/$TODAY.md"
  run DIETJ
  [[ "$output" == *"DIET_JOURNAL_UPDATE"* ]]
}

@test "fitness-anchored meal timing rules are emitted" {
  write_profile
  run DIETJ
  [[ "$output" == *"MEAL TIMING (fitness-anchored)"* ]]
  [[ "$output" == *"post-workout protein"* ]]
}

# ── --date (backfill a past day) ─────────────────────────────────────────────

@test "--date drives the entry date and output path" {
  write_profile
  run DIETJ --date 2026-06-26
  [ "$status" -eq 0 ]
  [[ "$output" == *"DIET_JOURNAL_SESSION"* ]]
  [[ "$output" == *"date: 2026-06-26"* ]]
  [[ "$output" == *"output_file: $DIET/2026-06-26.md"* ]]
}

@test "bare YYYY-MM-DD positional also drives the date" {
  write_profile
  run DIETJ 2026-06-26
  [ "$status" -eq 0 ]
  [[ "$output" == *"date: 2026-06-26"* ]]
}

@test "no --date defaults to today" {
  write_profile
  run DIETJ
  [[ "$output" == *"date: $TODAY"* ]]
  [[ "$output" == *"output_file: $DIET/$TODAY.md"* ]]
}

@test "--date routes a past day's existing entry to update mode" {
  write_profile
  mkdir -p "$DIET"
  echo "entry" > "$DIET/2026-06-26.md"
  run DIETJ --date 2026-06-26
  [[ "$output" == *"DIET_JOURNAL_UPDATE"* ]]
  [[ "$output" == *"date: 2026-06-26"* ]]
}

@test "bad --date is rejected" {
  write_profile
  run DIETJ --date not-a-date
  [ "$status" -ne 0 ]
  [[ "$output" == *"Bad date"* ]]
}

@test "profile subcommand still works alongside the new arg parsing" {
  write_profile
  run DIETJ profile show
  [ "$status" -eq 0 ]
  [[ "$output" == *"DIET_PROFILE_SHOW"* ]]
}

# ── profile subcommand ───────────────────────────────────────────────────────

@test "profile new mints a draft and commit freezes it" {
  write_profile
  run DIETJ profile new
  [ "$status" -eq 0 ]
  [[ "$output" == *"DIET_PROFILE_NEW"* ]]
  [ -f "$STORE/diet-profile.v2.md" ]
  grep -q '^committed: false$' "$STORE/diet-profile.v2.md"
  run DIETJ profile commit
  [[ "$output" == *"DIET_PROFILE_COMMITTED"* ]]
  grep -q '^committed: true$' "$STORE/diet-profile.v2.md"
}

@test "profile show cats the committed profile" {
  write_profile
  run DIETJ profile show
  [[ "$output" == *"DIET_PROFILE_SHOW"* ]]
  [[ "$output" == *'"calories": 2200'* ]]
}

@test "no plan wording for the stored config in setup output" {
  run DIETJ
  [[ "$output" != *"Diet Plan.md"* ]]
  [[ "$output" != *"DIET_JOURNAL_SETUP_PLAN"* ]]
}
