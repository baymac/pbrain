#!/usr/bin/env bats
# Tests for commands/fitness-journal.sh — the mechanical (non-LLM) paths:
# migration gating, setup phases, day pre-selection, training-gap bands, and
# the profile subcommand.
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
  TRACKING="$PBRAIN_VAULT/fitness/daily-tracking"
  STORE="$TRACKING/.profile"
  TODAY="$(date +%Y-%m-%d)"
  DOW="$(date +%a)"
}

teardown() {
  rm -rf "$TMP"
}

FIT() { bash "$REPO_ROOT/commands/fitness-journal.sh" "$@"; }

write_overall_profile() {
  mkdir -p "$STORE"
  cat > "$STORE/fitness-profile.v1.md" <<EOF
---
type: fitness-profile
date: $TODAY
version: 1
committed: true
---

# Fitness profile

\`\`\`json
{"created": "$TODAY",
 "sleep": {"bed_time": "23:00", "wake_time": "07:00", "hours": 8.0},
 "steps_per_day": 8000,
 "health_metrics": {"source": "none", "notes": ""},
 "notes": ""}
\`\`\`
EOF
}

write_library() {
  mkdir -p "$STORE"
  cat > "$STORE/fitness-library.v1.md" <<EOF
---
type: fitness-library
date: $TODAY
version: 1
committed: true
---

# Fitness library

\`\`\`json
{"created": "$TODAY", "activities": [
  {"id": "gym", "name": "Gym", "occurrence": {"per": "week", "times": 4},
   "days": ["Mon", "Tue", "Thu", "Fri"], "equipment": "full gym",
   "typical_time": "17:00", "duration_min": 75, "notes": ""}]}
\`\`\`
EOF
}

write_gym_activity_profile() {
  # $1 = days list for the frontmatter, e.g. "Mon, Thu" — defaults to today.
  local days="${1:-$DOW}"
  mkdir -p "$STORE/activities"
  cat > "$STORE/activities/gym.v1.md" <<EOF
---
activity: Gym
created: $TODAY
days: [$days]
occurrence: "4/week"
equipment: full gym
version: 1
committed: true
---

# Gym — Profile

## Weekly structure

## Block 1 (Weeks 1–4)

### Day A — Push
| Exercise | Sets × Reps | Notes |
|---|---|---|
| Bench press | 4 × 8 | |
EOF
}

write_gym_session() {
  # $1 = ISO date for the session file.
  mkdir -p "$TRACKING"
  cat > "$TRACKING/$1.md" <<EOF
---
type: fitness
date: $1
week: 1
block: 1
day: A
focus: Push
status: done
tags: []
---

# Day A — Push
EOF
}

days_ago() { python3 -c "import datetime,sys; print((datetime.date.today()-datetime.timedelta(days=int(sys.argv[1]))).isoformat())" "$1"; }

# ── migration gating ─────────────────────────────────────────────────────────

@test "migration block fires when old activities json exists and store is empty" {
  echo '{"activities":["Gym"]}' > "$XDG_CONFIG_HOME/pbrain/fitness-activities.json"
  PBRAIN_MIGRATIONS=1 run FIT
  [ "$status" -eq 0 ]
  [[ "$output" == *"FITNESS_JOURNAL_MIGRATION"* ]]
  [[ "$output" == *"record 0003_fitness_profiles"* ]]
}

@test "no migration block once the store is populated" {
  echo '{"activities":["Gym"]}' > "$XDG_CONFIG_HOME/pbrain/fitness-activities.json"
  write_overall_profile
  write_library
  write_gym_activity_profile
  PBRAIN_MIGRATIONS=1 run FIT
  [[ "$output" != *"FITNESS_JOURNAL_MIGRATION"* ]]
  [[ "$output" == *"FITNESS_JOURNAL_SESSION"* ]]
}

# ── setup phases ─────────────────────────────────────────────────────────────

@test "fresh user gets the profile+library setup block" {
  run FIT
  [ "$status" -eq 0 ]
  [[ "$output" == *"FITNESS_JOURNAL_SETUP_PROFILE"* ]]
  [[ "$output" == *"fitness-profile.v1.md"* ]]
  [[ "$output" == *"fitness-library.v1.md"* ]]
}

@test "library without activity profiles gets the per-activity setup block" {
  write_overall_profile
  write_library
  run FIT
  [ "$status" -eq 0 ]
  [[ "$output" == *"FITNESS_JOURNAL_SETUP_ACTIVITY_PROFILES"* ]]
  [[ "$output" == *"Gym"* ]]
}

# ── daily flow: pre-selection + training gap ────────────────────────────────

@test "daily session pre-selects the activity scheduled today" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  run FIT
  [ "$status" -eq 0 ]
  [[ "$output" == *"FITNESS_JOURNAL_SESSION"* ]]
  [[ "$output" == *"preselected_today: Gym"* ]]
}

@test "daily session reports none scheduled when days do not match today" {
  write_overall_profile
  write_library
  # pick a day that is never today: use both other weekdays around today
  if [[ "$DOW" == "Mon" ]]; then write_gym_activity_profile "Tue"; else write_gym_activity_profile "Mon"; fi
  # ensure the chosen non-today day really is not today
  run FIT
  [[ "$output" == *"preselected_today: (none scheduled today)"* ]]
}

@test "training gap 7-13 days emits the no_progression band" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  write_gym_session "$(days_ago 10)"
  run FIT
  [[ "$output" == *"training_gap_days: 10"* ]]
  [[ "$output" == *"training_gap_band: no_progression"* ]]
}

@test "training gap 14+ days emits the deload band" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  write_gym_session "$(days_ago 16)"
  run FIT
  [[ "$output" == *"training_gap_days: 16"* ]]
  [[ "$output" == *"training_gap_band: deload"* ]]
}

@test "training gap under 7 days emits the normal band" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  write_gym_session "$(days_ago 3)"
  run FIT
  [[ "$output" == *"training_gap_days: 3"* ]]
  [[ "$output" == *"training_gap_band: normal"* ]]
}

@test "no prior gym session emits the unknown band" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  run FIT
  [[ "$output" == *"training_gap_band: unknown"* ]]
}

@test "equipment question is gone from the daily flow" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  run FIT
  [[ "$output" != *"equipment unavailable"* ]]
  [[ "$output" == *"do NOT ask about it"* ]]
}

@test "session instructions carry the sleep frontmatter contract" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  run FIT
  [[ "$output" == *"sleep_bed:"* ]]
  [[ "$output" == *"sleep_wake:"* ]]
  [[ "$output" == *"sleep_hours:"* ]]
}

@test "existing entry today short-circuits to the existing block" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  mkdir -p "$TRACKING"
  echo "session content" > "$TRACKING/$TODAY.md"
  run FIT
  [[ "$output" == *"FITNESS_JOURNAL_EXISTING"* ]]
}

# ── profile subcommand ───────────────────────────────────────────────────────

@test "profile new mints a draft and commit freezes it" {
  write_overall_profile
  write_library
  run FIT profile new fitness-profile
  [ "$status" -eq 0 ]
  [[ "$output" == *"FITNESS_PROFILE_NEW"* ]]
  [ -f "$STORE/fitness-profile.v2.md" ]
  grep -q '^committed: false$' "$STORE/fitness-profile.v2.md"
  run FIT profile commit fitness-profile
  [[ "$output" == *"FITNESS_PROFILE_COMMITTED"* ]]
  grep -q '^committed: true$' "$STORE/fitness-profile.v2.md"
}

@test "profile new while a draft is open points at the draft" {
  write_overall_profile
  FIT profile new fitness-profile >/dev/null
  run FIT profile new fitness-profile
  [[ "$output" == *"FITNESS_PROFILE_DRAFT_OPEN"* ]]
}

@test "profile show cats the committed profiles" {
  write_overall_profile
  write_library
  run FIT profile show
  [[ "$output" == *"FITNESS_PROFILE_SHOW"* ]]
  [[ "$output" == *'"steps_per_day": 8000'* ]]
}

@test "profile subcommand for an activity targets the activities store" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  run FIT profile new activity Gym
  [ "$status" -eq 0 ]
  [ -f "$STORE/activities/gym.v2.md" ]
}

@test "an open activity draft does not shadow the committed version below it" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  # mint a v2 DRAFT of the gym activity — preselection must still see v1
  FIT profile new activity Gym >/dev/null
  run FIT
  [[ "$output" == *"preselected_today: Gym"* ]]
}

@test "an open fitness-profile draft routes to the draft block, not fresh setup" {
  FIT profile new fitness-profile >/dev/null
  run FIT
  [[ "$output" == *"FITNESS_PROFILE_DRAFT_OPEN"* ]]
  [[ "$output" != *"FITNESS_JOURNAL_SETUP_PROFILE"* ]]
}
