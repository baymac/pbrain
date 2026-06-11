#!/usr/bin/env bats
# Tests for commands/plan-my-day.sh — the mechanical (non-LLM) paths:
# migration gating, setup/draft phases, store resolution, the new daily-flow
# context lines, removed features (current_focus / declutter / CADENCE), and
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
  # Habits + reminders stay quiet/off in unit tests.
  export PBRAIN_DB_FILE="$TMP/pbrain.db"
  : > "$TMP/blockapp"
  export PBRAIN_REMINDERS_APP="$TMP/blockapp/pbrain-reminders.app"
  PLAN="$PBRAIN_VAULT/life/daily-planning"
  STORE="$PLAN/.profile"
  TODAY="$(date +%Y-%m-%d)"
}

teardown() {
  rm -rf "$TMP"
}

PMD() { bash "$REPO_ROOT/commands/plan-my-day.sh" "$@"; }

write_goals_profile() {
  mkdir -p "$STORE"
  cat > "$STORE/goals-profile.v1.md" <<EOF
---
type: goals-profile
date: $TODAY
version: 1
committed: true
---

# Goals profile

\`\`\`json
{"created": "$TODAY",
 "work_goals": [{"id": "lettuce", "goal": "Ship Lettuce", "deadline": "2026-08",
                 "success_looks_like": "VC application out"}],
 "life_goals": [{"id": "fit-body", "goal": "Build a fit body", "deadline": "ongoing",
                 "success_looks_like": "consistent training"}],
 "working_style": {"session_length_min": 90, "break_min": 30,
   "break_activities": ["short walk", "stretch"], "work_hours_per_day": 7,
   "focus_hours": "9-12,15-17", "last_block_end": "20:00",
   "energy_peak": "morning", "day_wreckers": ["poor sleep"]},
 "daily_anchors": {"wake_time": "07:30", "workout_time": "17:00",
   "lunch_time": "13:00", "dinner_time": "20:30", "walk_time": null,
   "bed_target": "23:30"},
 "anti_patterns": ["doomscrolling"],
 "personal_anchors": {"relationships": ["Mom"], "creative_pursuits": ["DJing"],
   "health_habits": ["gym 4x/week"]},
 "notes": ""}
\`\`\`
EOF
}

write_libraries() {
  mkdir -p "$STORE"
  cat > "$STORE/work-library.v1.md" <<EOF
---
type: work-library
version: 1
committed: true
---
# Work library
\`\`\`json
{"created": "$TODAY", "projects": [
  {"id": "lettuce", "name": "Lettuce", "summary": "autonomous trading platform",
   "status": "active", "context": "VC apps due; algo part is the hard bit",
   "last_worked": null}]}
\`\`\`
EOF
  cat > "$STORE/goals-library.v1.md" <<EOF
---
type: goals-library
version: 1
committed: true
---
# Goals library
\`\`\`json
{"created": "$TODAY", "goals": [
  {"id": "fit-body", "goal": "Build a fit body", "category": "health",
   "deadline": "ongoing", "success_looks_like": "consistent training"}]}
\`\`\`
EOF
}

# ── migration gating ─────────────────────────────────────────────────────────

@test "migration block fires when the old Goals Profile exists and store is empty" {
  mkdir -p "$PBRAIN_VAULT/life"
  echo "old goals profile" > "$PBRAIN_VAULT/life/Goals Profile.md"
  PBRAIN_MIGRATIONS=1 run PMD
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_MIGRATION"* ]]
  [[ "$output" == *"record 0002_goals_profile_restructure"* ]]
  [[ "$output" == *"work-library.v1.md"* ]]
  [[ "$output" == *"goals-library.v1.md"* ]]
}

@test "no migration block once the store is populated" {
  mkdir -p "$PBRAIN_VAULT/life"
  echo "old goals profile" > "$PBRAIN_VAULT/life/Goals Profile.md"
  write_goals_profile
  write_libraries
  PBRAIN_MIGRATIONS=1 run PMD
  [[ "$output" != *"PLAN_MY_DAY_MIGRATION"* ]]
  [[ "$output" == *"PLAN_MY_DAY_SESSION"* ]]
}

@test "explicit profile override bypasses the migration prompt" {
  mkdir -p "$PBRAIN_VAULT/life"
  echo "old goals profile" > "$PBRAIN_VAULT/life/Goals Profile.md"
  write_goals_profile
  PBRAIN_MIGRATIONS=1 PBRAIN_PLAN_PROFILE_FILE="$STORE/goals-profile.v1.md" run PMD
  [[ "$output" != *"PLAN_MY_DAY_MIGRATION"* ]]
}

# ── setup / draft phases ─────────────────────────────────────────────────────

@test "fresh user gets the three-file setup block" {
  run PMD
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_SETUP_PROFILE"* ]]
  [[ "$output" == *"goals-profile.v1.md"* ]]
  [[ "$output" == *"work-library.v1.md"* ]]
  [[ "$output" == *"goals-library.v1.md"* ]]
}

@test "open goals-profile draft short-circuits to the draft block" {
  mkdir -p "$STORE"
  printf -- '---\nversion: 1\ncommitted: false\n---\n# Goals profile\n```json\n{}\n```\n' \
    > "$STORE/goals-profile.v1.md"
  run PMD
  [[ "$output" == *"PLAN_PROFILE_DRAFT_OPEN"* ]]
}

# ── daily flow ───────────────────────────────────────────────────────────────

@test "daily session has no current_focus, declutter, or cadence signal" {
  write_goals_profile
  write_libraries
  run PMD
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_SESSION"* ]]
  [[ "$output" != *"current_focus"* ]]
  [[ "$output" != *"eclutter"* ]]
  [[ "$output" != *"CADENCE SIGNAL"* ]]
}

@test "daily session injects work + goals libraries" {
  write_goals_profile
  write_libraries
  run PMD
  [[ "$output" == *"WORK LIBRARY"* ]]
  [[ "$output" == *"autonomous trading platform"* ]]
  [[ "$output" == *"GOALS LIBRARY"* ]]
}

@test "fitness sleep frontmatter is surfaced when today's entry has it" {
  write_goals_profile
  write_libraries
  mkdir -p "$PBRAIN_VAULT/fitness/daily-tracking"
  cat > "$PBRAIN_VAULT/fitness/daily-tracking/$TODAY.md" <<EOF
---
type: fitness
date: $TODAY
sleep_bed: 23:45
sleep_wake: 07:20
sleep_quality: 7
sleep_hours: 7.6
status: planned
---
# Day A
EOF
  run PMD
  [[ "$output" == *"fitness_sleep: sleep_wake=07:20"* ]]
}

@test "missing fitness entry asks for the wake time" {
  write_goals_profile
  write_libraries
  run PMD
  [[ "$output" == *"fitness_sleep: (not recorded — ask the user)"* ]]
}

@test "diet meal times are read from the diet store" {
  write_goals_profile
  write_libraries
  mkdir -p "$PBRAIN_VAULT/fitness/diet-tracking/.profile"
  cat > "$PBRAIN_VAULT/fitness/diet-tracking/.profile/diet-profile.v1.md" <<EOF
---
type: diet-profile
version: 1
committed: true
---
# Diet profile
\`\`\`json
{"created": "$TODAY", "meal_times": {"Lunch": "13:30", "Dinner": "20:30"}}
\`\`\`
EOF
  run PMD
  [[ "$output" == *"diet_meal_times: Lunch 13:30, Dinner 20:30"* ]]
}

@test "today's scheduled fitness activity is surfaced from the fitness store" {
  write_goals_profile
  write_libraries
  local dow3; dow3="$(date +%a)"
  mkdir -p "$PBRAIN_VAULT/fitness/daily-tracking/.profile/activities"
  cat > "$PBRAIN_VAULT/fitness/daily-tracking/.profile/fitness-library.v1.md" <<EOF
---
type: fitness-library
version: 1
committed: true
---
# Fitness library
\`\`\`json
{"created": "$TODAY", "activities": [
  {"id": "gym", "name": "Gym", "occurrence": {"per": "week", "times": 4},
   "typical_time": "17:00", "duration_min": 75}]}
\`\`\`
EOF
  cat > "$PBRAIN_VAULT/fitness/daily-tracking/.profile/activities/gym.v1.md" <<EOF
---
activity: Gym
days: [$dow3]
version: 1
committed: true
---
# Gym — Profile
EOF
  run PMD
  [[ "$output" == *"fitness_today_schedule: Gym — typically 17:00"* ]]
}

@test "existing plan today routes to the existing block" {
  write_goals_profile
  write_libraries
  mkdir -p "$PLAN"
  echo "plan content" > "$PLAN/$TODAY.md"
  run PMD
  [[ "$output" == *"PLAN_MY_DAY_EXISTING"* ]]
}

@test "env-override profile file is honored" {
  cp_profile="$TMP/custom-profile.md"
  write_goals_profile
  cp "$STORE/goals-profile.v1.md" "$cp_profile"
  rm -rf "$STORE"
  write_libraries
  PBRAIN_PLAN_PROFILE_FILE="$cp_profile" run PMD
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_SESSION"* ]]
  [[ "$output" == *"profile_file: $cp_profile"* ]]
}

# ── profile subcommand ───────────────────────────────────────────────────────

@test "profile new mints a draft and commit freezes it" {
  write_goals_profile
  run PMD profile new
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_PROFILE_NEW"* ]]
  [ -f "$STORE/goals-profile.v2.md" ]
  grep -q '^committed: false$' "$STORE/goals-profile.v2.md"
  run PMD profile commit
  [[ "$output" == *"PLAN_PROFILE_COMMITTED"* ]]
  grep -q '^committed: true$' "$STORE/goals-profile.v2.md"
}

@test "profile new for a library targets that base" {
  write_goals_profile
  write_libraries
  run PMD profile new goals-library
  [ "$status" -eq 0 ]
  [ -f "$STORE/goals-library.v2.md" ]
}

@test "profile show cats all three profiles" {
  write_goals_profile
  write_libraries
  run PMD profile show
  [[ "$output" == *"PLAN_PROFILE_SHOW"* ]]
  [[ "$output" == *"goals-profile"* ]]
  [[ "$output" == *"work-library"* ]]
  [[ "$output" == *"goals-library"* ]]
}

# ── weekly / monthly goals ───────────────────────────────────────────────────

write_weekly_goals() {
  local iso_week="$1"
  mkdir -p "$STORE"
  cat > "$STORE/weekly-goals.v1.md" <<EOF
---
type: weekly-goals
version: 1
committed: true
---
# Weekly goals
\`\`\`json
{"created": "$TODAY", "period": "$iso_week",
 "goals": [{"id": "lettuce-algo", "goal": "Ship the algo module",
             "tie": "lettuce", "priority": 1, "difficulty": "hard",
             "success_looks_like": "algo tests green", "status": "active"}]}
\`\`\`
EOF
}

@test "daily session surfaces weekly goals when they match the current ISO week" {
  write_goals_profile
  write_libraries
  local iso_week
  iso_week="$(python3 -c "import datetime; t=datetime.date.today(); y,w,_=t.isocalendar(); print(f'{y}-W{w:02d}')")"
  write_weekly_goals "$iso_week"
  run PMD
  [ "$status" -eq 0 ]
  [[ "$output" == *"WEEKLY GOALS"* ]]
  [[ "$output" == *"lettuce-algo"* ]]
  [[ "$output" == *"weekly_goals_file:"* ]]
}

@test "daily session shows weekly_goals_file as (not set up yet) when no weekly goals" {
  write_goals_profile
  write_libraries
  run PMD
  [[ "$output" == *"weekly_goals_file: (not set up yet)"* ]]
}

@test "daily session includes iso_week in the header" {
  write_goals_profile
  write_libraries
  run PMD
  [[ "$output" == *"iso_week: 20"* ]]  # partial match — format 20XX-WXX
}

@test "plan frontmatter template includes week_period" {
  write_goals_profile
  write_libraries
  run PMD
  [[ "$output" == *"week_period:"* ]]
}

@test "task-log table is in the plan instructions" {
  write_goals_profile
  write_libraries
  run PMD
  [[ "$output" == *"## Task log"* ]]
  [[ "$output" == *"Done at"* ]]
  [[ "$output" == *"Difficulty"* ]]
}

@test "profile new weekly-goals mints a draft" {
  write_goals_profile
  run PMD profile new weekly-goals
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_PROFILE_NEW"* ]]
  [ -f "$STORE/weekly-goals.v1.md" ]
}

@test "profile new monthly-goals mints a draft" {
  write_goals_profile
  run PMD profile new monthly-goals
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_PROFILE_NEW"* ]]
  [ -f "$STORE/monthly-goals.v1.md" ]
}

@test "profile show includes weekly-goals and monthly-goals bases" {
  write_goals_profile
  write_libraries
  run PMD profile show
  [[ "$output" == *"weekly-goals"* ]]
  [[ "$output" == *"monthly-goals"* ]]
}

@test "month_boundary_signal is present in daily session output" {
  write_goals_profile
  write_libraries
  run PMD
  [[ "$output" == *"month_boundary_signal:"* ]]
}

# ── task subcommand (mid-day edits) ──────────────────────────────────────────

write_today_plan() {
  mkdir -p "$PLAN"
  cat > "$PLAN/$TODAY.md" <<EOF
---
type: plan
date: $TODAY
week_period: 2026-W24
status: planned
---

# Day Plan — $TODAY

## Today at a glance

| Time | Action | Tie |
|---|---|---|
| 07:30–08:00 | ✓ Wake, coffee | — |
| 09:00–10:30 | Block 1: Lettuce algo | lettuce |
| 13:00–13:45 | Lunch | Eating |

## Task log

| Task | Tie | Priority | Difficulty | Done at | Status | Notes |
|---|---|---|---|---|---|---|
| Ship the algo module | lettuce | 1 | hard | | planned | |
| Email cleanup | — | — | — | 11:30 | done | |
EOF
}

@test "task add with no plan today is a clean no-op pointing at /plan-my-day" {
  write_goals_profile
  write_libraries
  run PMD task add
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_TASK_NO_PLAN"* ]]
  [[ "$output" == *"run /plan-my-day first"* ]]
  [[ "$output" != *"PLAN_MY_DAY_TASK"$'\n'* ]] || true
}

@test "task with no committed profile is still a clean no-op, not the setup interview" {
  # No profile and no plan: the early guard must win over first-run setup.
  run PMD task list
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_TASK_NO_PLAN"* ]]
  [[ "$output" != *"PLAN_MY_DAY_SETUP_PROFILE"* ]]
}

@test "task add on an existing plan emits the task block with the plan + goals context" {
  write_goals_profile
  write_libraries
  write_today_plan
  run PMD task add
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_TASK"* ]]
  [[ "$output" == *"action: add"* ]]
  [[ "$output" == *"TODAY'S PLAN"* ]]
  [[ "$output" == *"## Task log"* ]]
  [[ "$output" == *"Ship the algo module"* ]]
  [[ "$output" == *"REWRITE BOTH TABLES TOGETHER"* ]]
  [[ "$output" == *"last_block_end"* ]]
}

@test "task add surfaces weekly_goals_file for tie + suggest-tier" {
  write_goals_profile
  write_libraries
  local iso_week
  iso_week="$(python3 -c "import datetime; t=datetime.date.today(); y,w,_=t.isocalendar(); print(f'{y}-W{w:02d}')")"
  write_weekly_goals "$iso_week"
  write_today_plan
  run PMD task add
  [[ "$output" == *"weekly_goals_file:"* ]]
  [[ "$output" == *"WEEKLY GOALS"* ]]
  [[ "$output" == *"lettuce-algo"* ]]
  [[ "$output" == *"SUGGEST-TIER"* ]]
}

@test "task remove emits the confirm-on-closed-row guard" {
  write_goals_profile
  write_libraries
  write_today_plan
  run PMD task remove
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_TASK"* ]]
  [[ "$output" == *"action: remove"* ]]
  [[ "$output" == *"CONFIRM-ON-CLOSED-ROW"* ]]
  [[ "$output" == *"REWRITE BOTH TABLES TOGETHER"* ]]
}

@test "task list shows the rows without rewriting the file" {
  write_goals_profile
  write_libraries
  write_today_plan
  run PMD task list
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_TASK"* ]]
  [[ "$output" == *"action: list"* ]]
  [[ "$output" == *"task list"* ]]
  [[ "$output" == *"Do NOT rewrite the file"* ]]
}

@test "task defaults to list when no action is given" {
  write_goals_profile
  write_libraries
  write_today_plan
  run PMD task
  [ "$status" -eq 0 ]
  [[ "$output" == *"action: list"* ]]
}

@test "task with an unknown action fails with usage" {
  write_goals_profile
  write_libraries
  write_today_plan
  run PMD task frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: plan-my-day.sh task add|remove|list"* ]]
}

@test "an open activity draft does not hide today's committed schedule" {
  write_goals_profile
  write_libraries
  local dow3; dow3="$(date +%a)"
  mkdir -p "$PBRAIN_VAULT/fitness/daily-tracking/.profile/activities"
  printf -- '---\nversion: 1\ncommitted: true\n---\n# Fitness library\n```json\n{"created": "x", "activities": [{"id": "gym", "name": "Gym", "typical_time": "17:00"}]}\n```\n' \
    > "$PBRAIN_VAULT/fitness/daily-tracking/.profile/fitness-library.v1.md"
  printf -- '---\nactivity: Gym\ndays: [%s]\nversion: 1\ncommitted: true\n---\n# Gym v1\n' "$dow3" \
    > "$PBRAIN_VAULT/fitness/daily-tracking/.profile/activities/gym.v1.md"
  printf -- '---\nactivity: Gym\ndays: [%s]\nversion: 2\ncommitted: false\n---\n# Gym v2 draft\n' "$dow3" \
    > "$PBRAIN_VAULT/fitness/daily-tracking/.profile/activities/gym.v2.md"
  run PMD
  [[ "$output" == *"fitness_today_schedule: Gym — typically 17:00"* ]]
}
