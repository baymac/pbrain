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

write_plans_profile() {
  mkdir -p "$STORE"
  cat > "$STORE/plans-profile.v1.md" <<EOF
---
type: plans-profile
date: $TODAY
version: 1
committed: true
---

# Plans profile

\`\`\`json
{"created": "$TODAY",
 "working_style": {"session_length_min": 90, "break_min": 30,
   "break_activities": ["short walk", "stretch"], "work_hours_per_day": 7,
   "focus_hours": "9-12,15-17", "last_block_end": "20:00",
   "energy_peak": "morning", "day_wreckers": ["poor sleep"], "other_prefs": []},
 "planning_guidelines": "Blocks of 90 min, 30-min breaks, life anchors first.",
 "current_focus": [
   {"id": "lettuce", "lib": "work", "name": "Ship Lettuce",
    "track": "professional", "horizon": "short",
    "priority": 1, "deadline": "2026-08",
    "success_looks_like": "VC application out",
    "context": "Autonomous trading platform; algo module is the hard bit.",
    "status": "active"},
   {"id": "fit-body", "lib": "goals", "name": "Build a fit body",
    "track": "personal", "horizon": "long",
    "priority": 2, "deadline": "ongoing",
    "success_looks_like": "consistent training",
    "context": "Gym 4x/week, track metrics.", "status": "active"}],
 "daily_anchors": {"wake_time": "07:30", "workout_time": "17:00",
   "lunch_time": "13:00", "dinner_time": "20:30", "walk_time": null,
   "bed_target": "23:30"},
 "typical_day": {"padded": true, "rest_days": ["sat", "sun"],
   "workday": [
     {"slot": "wake", "start": "07:30", "end": "08:00", "duration_min": 30, "category": "wake", "flex": "fixed"},
     {"slot": "work_am", "start": "09:00", "end": "13:00", "duration_min": 240, "category": "work", "flex": "flex"},
     {"slot": "lunch", "start": "13:00", "end": "13:45", "duration_min": 45, "category": "meal", "flex": "fixed"},
     {"slot": "bed", "start": "23:30", "end": "23:30", "duration_min": 0, "category": "bed", "flex": "fixed"}],
   "rest_day": [
     {"slot": "wake", "start": "08:30", "end": "09:00", "duration_min": 30, "category": "wake", "flex": "fixed"}]},
 "variation_rules": {"priority_order": ["events_and_nonnegotiables", "meals_and_fitness", "work"],
   "work_is_flex": true, "keep_meal_count": true, "min_wake_to_work_gap_min": 30,
   "non_gym_fitness": {"ask_duration_including_buffer": true, "shift_meals_to_fit": true},
   "late_wake": {"shift_timeline": true},
   "skip_fitness_when": "Suggest skipping only when meals run late AND recently active."},
 "anti_patterns": ["doomscrolling"],
 "personal_anchors": {"relationships": ["Mom"], "creative_pursuits": ["DJing"],
   "health_habits": ["gym 4x/week"]},
 "notes": ""}
\`\`\`
EOF
}

# Keep backward-compat alias used by many tests below.
write_goals_profile() { write_plans_profile; }

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
  {"id": "lettuce", "name": "Lettuce", "shortcut": "lt",
   "summary": "autonomous trading platform", "category": "work",
   "metadata": {"repo": "gh/lettuce"}, "timeline": null}]}
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
  {"id": "fit-body", "name": "Build a fit body", "shortcut": "fb",
   "category": "health", "summary": "consistent training", "timeline": null}]}
\`\`\`
EOF
}

# ── migration gating ─────────────────────────────────────────────────────────

@test "rebuild block fires when the old Goals Profile exists and store is empty" {
  mkdir -p "$PBRAIN_VAULT/life"
  echo "old goals profile" > "$PBRAIN_VAULT/life/Goals Profile.md"
  PBRAIN_MIGRATIONS=1 run PMD
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_REBUILD"* ]]
  [[ "$output" == *"record 0002_plans_profile_rebuild"* ]]
  [[ "$output" == *"work-library.v1.md"* ]]
  [[ "$output" == *"goals-library.v1.md"* ]]
}

@test "no rebuild block once the store is populated" {
  mkdir -p "$PBRAIN_VAULT/life"
  echo "old goals profile" > "$PBRAIN_VAULT/life/Goals Profile.md"
  write_plans_profile
  write_libraries
  PBRAIN_MIGRATIONS=1 run PMD
  [[ "$output" != *"PLAN_MY_DAY_REBUILD"* ]]
  [[ "$output" == *"PLAN_MY_DAY_SESSION"* ]]
}

@test "explicit profile override bypasses the rebuild prompt" {
  mkdir -p "$PBRAIN_VAULT/life"
  echo "old goals profile" > "$PBRAIN_VAULT/life/Goals Profile.md"
  write_plans_profile
  PBRAIN_MIGRATIONS=1 PBRAIN_PLAN_PROFILE_FILE="$STORE/plans-profile.v1.md" run PMD
  [[ "$output" != *"PLAN_MY_DAY_REBUILD"* ]]
}

# ── setup / draft phases ─────────────────────────────────────────────────────

@test "fresh user gets the three-file setup block" {
  run PMD
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_SETUP_PROFILE"* ]]
  [[ "$output" == *"plans-profile.v1.md"* ]]
  [[ "$output" == *"work-library.v1.md"* ]]
  [[ "$output" == *"goals-library.v1.md"* ]]
}

@test "open plans-profile draft short-circuits to the draft block" {
  mkdir -p "$STORE"
  printf -- '---\nversion: 1\ncommitted: false\n---\n# Plans profile\n```json\n{}\n```\n' \
    > "$STORE/plans-profile.v1.md"
  run PMD
  [[ "$output" == *"PLAN_PROFILE_DRAFT_OPEN"* ]]
}

# ── daily flow ───────────────────────────────────────────────────────────────

@test "daily session has plans profile context and no declutter or cadence signal" {
  write_plans_profile
  write_libraries
  run PMD
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_SESSION"* ]]
  [[ "$output" == *"PLANS PROFILE"* ]]
  [[ "$output" != *"eclutter"* ]]
  [[ "$output" != *"CADENCE SIGNAL"* ]]
}

@test "daily INSTRUCTIONS lay EMPTY placeholder blocks (no task slate) and define anchors as life-only" {
  write_plans_profile
  write_libraries
  run PMD
  [ "$status" -eq 0 ]
  # Step 2d no longer proposes/assigns tasks — blocks are placeholders
  [[ "$output" == *"WORK BLOCKS STAY EMPTY"* ]]
  [[ "$output" == *"GENERIC PLACEHOLDER"* ]]
  [[ "$output" != *"candidate task slate"* ]]
  # the task slate + suggest-tier logic is gone
  [[ "$output" != *"SUGGEST-TIER"* ]]
  # anchors are life structure only, never work
  [[ "$output" == *"ANCHORS are LIFE structure ONLY"* ]]
  [[ "$output" == *"Work and"* && "$output" == *"NEVER anchors"* ]]
  # nudge to /plan-my-work landed
  [[ "$output" == *"/plan-my-work"* ]]
  # weekly/monthly goals anchoring is gone (moved to /plan-my-work)
  [[ "$output" != *"## Today's focus"* ]]
}

@test "fresh setup block carries the typical_day + variation_rules template" {
  run PMD
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_SETUP_PROFILE"* ]]
  [[ "$output" == *"\"typical_day\""* ]]
  [[ "$output" == *"\"variation_rules\""* ]]
  [[ "$output" == *"\"workday\""* ]]
  [[ "$output" == *"\"rest_day\""* ]]
  [[ "$output" == *"min_wake_to_work_gap_min"* ]]
  [[ "$output" == *"Typical day breakup"* ]]
}

@test "rebuild block carries the typical_day + variation_rules template" {
  mkdir -p "$PBRAIN_VAULT/life"
  echo "old goals profile" > "$PBRAIN_VAULT/life/Goals Profile.md"
  PBRAIN_MIGRATIONS=1 run PMD
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_REBUILD"* ]]
  [[ "$output" == *"\"typical_day\""* ]]
  [[ "$output" == *"\"variation_rules\""* ]]
  [[ "$output" == *"flesh your flat anchors"* ]]
}

@test "a plans profile with typical_day still parses as valid JSON" {
  write_plans_profile
  # The fenced JSON block must round-trip through json.loads.
  run python3 - "$STORE/plans-profile.v1.md" <<'PYEOF'
import json, re, sys
with open(sys.argv[1]) as fh:
    m = re.search(r"```json\s*\n(.*?)```", fh.read(), re.DOTALL)
p = json.loads(m.group(1))
assert "typical_day" in p and "workday" in p["typical_day"], "missing typical_day"
assert "variation_rules" in p, "missing variation_rules"
print("OK")
PYEOF
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "daily session reports typical_day_present yes and injects recent fitness activity" {
  write_plans_profile
  write_libraries
  run PMD
  [ "$status" -eq 0 ]
  [[ "$output" == *"typical_day_present: yes"* ]]
  [[ "$output" == *"RECENT FITNESS ACTIVITY"* ]]
  [[ "$output" == *"1b.5"* ]]
  [[ "$output" == *"NON-NEGOTIABLES"* ]]
}

@test "daily session falls back gracefully when the profile lacks typical_day" {
  # A committed profile WITHOUT typical_day (pre-existing vaults) still plans.
  local legacy="$TMP/legacy-profile.md"
  cat > "$legacy" <<EOF
---
type: plans-profile
version: 1
committed: true
---
# Plans profile
\`\`\`json
{"created": "$TODAY", "working_style": {"session_length_min": 90,
  "break_min": 30, "last_block_end": "20:00"}, "current_focus": [],
  "daily_anchors": {"wake_time": "07:30"}}
\`\`\`
EOF
  write_libraries
  PBRAIN_PLAN_PROFILE_FILE="$legacy" run PMD
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_SESSION"* ]]
  [[ "$output" == *"typical_day_present: no"* ]]
}

@test "plan path does NOT inject work/goals libraries (moved to /plan-my-work)" {
  write_plans_profile
  write_libraries
  run PMD
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_SESSION"* ]]
  # blocks are empty placeholders now, so the libraries are no longer planning
  # context — they belong to /plan-my-work. Combined into the final command so
  # every condition is actually enforced (bats only fails on the last command).
  [[ "$output" != *"=== WORK LIBRARY"* && "$output" != *"=== GOALS LIBRARY"* && "$output" != *"autonomous trading platform"* ]]
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

@test "today's chosen fitness activity (focus:) is surfaced as fitness_today_activity" {
  write_goals_profile
  write_libraries
  mkdir -p "$PBRAIN_VAULT/fitness/daily-tracking"
  cat > "$PBRAIN_VAULT/fitness/daily-tracking/$TODAY.md" <<EOF
---
type: fitness
date: $TODAY
focus: Apple Fitness+ Kickboxing + Strength + Cooldown
sleep_wake: 07:20
---
# Day A
EOF
  run PMD
  [[ "$output" == *"fitness_today_activity: Apple Fitness+ Kickboxing + Strength + Cooldown"* ]]
}

@test "fitness_today_activity falls back when there is no focus field" {
  write_goals_profile
  write_libraries
  run PMD
  [[ "$output" == *"fitness_today_activity: (no fitness entry / focus not set)"* ]]
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

@test "existing plan today routes to the UPDATE path" {
  write_goals_profile
  write_libraries
  mkdir -p "$PLAN"
  echo "plan content" > "$PLAN/$TODAY.md"
  run PMD
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_UPDATE"* && "$output" == *"TODAY'S PLAN (current)"* && "$output" == *"plan content"* ]]
}

@test "plan path emits a compact recent-days digest, not the full prior plans" {
  write_plans_profile
  write_libraries
  mkdir -p "$PLAN"
  cat > "$PLAN/2000-01-02.md" <<EOF
---
energy: 6
sleep_hours: 7.5
---
# Day Plan — 2000-01-02 (Sun)
## Today at a glance
| Time | Action | Tie |
|---|---|---|
| 07:00–07:30 | Wake | — |
| 09:00–10:30 | Block 1 — focus work | — |
| 13:00–13:45 | Lunch | Eating |
SECRET_FULL_PLAN_BODY_MARKER
EOF
  run PMD
  [ "$status" -eq 0 ]
  # digest header present; the old full-7 dump is gone; the prior plan's body
  # is NOT pasted in (all enforced — final command is the meaningful one).
  [[ "$output" == *"RECENT DAYS (last 3"* && "$output" != *"RECENT DAY PLANS (last 7)"* && "$output" != *"SECRET_FULL_PLAN_BODY_MARKER"* ]]
}

@test "recent-days digest summarizes a prior day in one line" {
  write_plans_profile
  write_libraries
  mkdir -p "$PLAN"
  cat > "$PLAN/2000-01-02.md" <<EOF
---
energy: 6
---
# Day Plan
## Today at a glance
| Time | Action | Tie |
|---|---|---|
| 07:00–07:30 | Wake | — |
| 09:00–10:30 | Block 1 — focus work | — |
| 13:00–13:45 | Lunch | Eating |
| 20:00–20:45 | Dinner | Eating |
EOF
  run PMD
  [ "$status" -eq 0 ]
  [[ "$output" == *"2000-01-02"* && "$output" == *"lunch 13:00"* && "$output" == *"energy 6"* ]]
}

@test "no timing signal block in the plan path" {
  write_plans_profile
  write_libraries
  run PMD
  [ "$status" -eq 0 ]
  [[ "$output" != *"TIMING SIGNAL"* ]]
}

@test "explicit 'plan' verb forces the plan path even when today's plan exists" {
  write_plans_profile
  write_libraries
  mkdir -p "$PLAN"
  echo "# existing" > "$PLAN/$TODAY.md"
  run PMD plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_SESSION"* && "$output" != *"PLAN_MY_DAY_UPDATE"* ]]
}

@test "explicit 'update' verb with no plan yet says so" {
  write_plans_profile
  write_libraries
  run PMD update
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_NO_PLAN_YET"* ]]
}

@test "update path surfaces this week's goals and the update template" {
  write_goals_profile
  write_libraries
  local iso_week
  iso_week="$(python3 -c "import datetime; t=datetime.date.today(); y,w,_=t.isocalendar(); print(f'{y}-W{w:02d}')")"
  write_weekly_goals "$iso_week"
  mkdir -p "$PLAN"
  echo "# Day Plan" > "$PLAN/$TODAY.md"
  run PMD update
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_UPDATE"* && "$output" == *"WEEKLY GOALS ($iso_week)"* && "$output" == *"revise-in-place"* ]]
}

@test "env-override profile file is honored" {
  cp_profile="$TMP/custom-profile.md"
  write_plans_profile
  cp "$STORE/plans-profile.v1.md" "$cp_profile"
  rm -rf "$STORE"
  write_libraries
  PBRAIN_PLAN_PROFILE_FILE="$cp_profile" run PMD
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_SESSION"* ]]
  [[ "$output" == *"profile_file: $cp_profile"* ]]
}

# ── profile subcommand ───────────────────────────────────────────────────────

@test "profile new mints a draft and commit freezes it" {
  write_plans_profile
  run PMD profile new
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_PROFILE_NEW"* ]]
  [ -f "$STORE/plans-profile.v2.md" ]
  grep -q '^committed: false$' "$STORE/plans-profile.v2.md"
  run PMD profile commit
  [[ "$output" == *"PLAN_PROFILE_COMMITTED"* ]]
  grep -q '^committed: true$' "$STORE/plans-profile.v2.md"
}

@test "profile new for a library targets that base" {
  write_goals_profile
  write_libraries
  run PMD profile new goals-library
  [ "$status" -eq 0 ]
  [ -f "$STORE/goals-library.v2.md" ]
}

@test "profile show cats all three profiles" {
  write_plans_profile
  write_libraries
  run PMD profile show
  [[ "$output" == *"PLAN_PROFILE_SHOW"* ]]
  [[ "$output" == *"plans-profile"* ]]
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

@test "daily session does NOT surface weekly/monthly goals anchoring" {
  # /plan-my-day no longer anchors on weekly/monthly goals — that's /plan-my-work's
  # job now. Even when this week's goals exist, the daily planner ignores them.
  write_goals_profile
  write_libraries
  local iso_week
  iso_week="$(python3 -c "import datetime; t=datetime.date.today(); y,w,_=t.isocalendar(); print(f'{y}-W{w:02d}')")"
  write_weekly_goals "$iso_week"
  run PMD
  [ "$status" -eq 0 ]
  [[ "$output" != *"=== WEEKLY GOALS"* ]]
  [[ "$output" != *"=== MONTHLY GOALS"* ]]
  [[ "$output" != *"lettuce-algo"* ]]
  [[ "$output" != *"weekly_goals_file:"* ]]
  [[ "$output" != *"monthly_goals_file:"* ]]
  [[ "$output" != *"iso_week:"* ]]
}

@test "plan frontmatter template includes week_period" {
  write_goals_profile
  write_libraries
  run PMD
  [[ "$output" == *"week_period:"* ]]
}

@test "no task-log table in the plan instructions; work blocks are placeholders" {
  write_goals_profile
  write_libraries
  run PMD
  [[ "$output" != *"## Task log"* ]]
  [[ "$output" == *"placeholders"* ]]
  [[ "$output" == *"Block N — focus work"* ]]
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

# ── task subcommand MOVED to /plan-my-work ───────────────────────────────────

@test "task verb redirects to /plan-my-work (any action), even with no plan/profile" {
  for action in add remove list; do
    run PMD task "$action"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PLAN_MY_DAY_TASK_MOVED"* ]]
    [[ "$output" == *"/plan-my-work task $action"* ]]
    # the old in-flow task handler is gone
    [[ "$output" != *"REWRITE BOTH TABLES TOGETHER"* ]]
  done
}

@test "task redirect never triggers the first-run setup interview" {
  # No profile and no plan: the redirect must win over first-run setup.
  run PMD task list
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_TASK_MOVED"* ]]
  [[ "$output" != *"PLAN_MY_DAY_SETUP_PROFILE"* ]]
}

@test "task defaults to list in the redirect when no action is given" {
  write_goals_profile
  write_libraries
  run PMD task
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_TASK_MOVED"* ]]
  [[ "$output" == *"action: list"* ]]
}

# ── focus / library subcommands ──────────────────────────────────────────────

@test "focus list emits PLAN_MY_DAY_FOCUS with plans profile context" {
  write_plans_profile
  write_libraries
  run PMD focus list
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_FOCUS"* ]]
  [[ "$output" == *"action: list"* ]]
  [[ "$output" == *"PLANS PROFILE"* ]]
  [[ "$output" == *"WORK LIBRARY"* ]]
}

@test "focus add emits PLAN_MY_DAY_FOCUS with add action" {
  write_plans_profile
  write_libraries
  run PMD focus add
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_FOCUS"* ]]
  [[ "$output" == *"action: add"* ]]
}

@test "focus archive emits PLAN_MY_DAY_FOCUS with archive action" {
  write_plans_profile
  write_libraries
  run PMD focus archive
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_FOCUS"* ]]
  [[ "$output" == *"action: archive"* ]]
}

@test "focus with unknown action fails with usage" {
  write_plans_profile
  write_libraries
  run PMD focus frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: plan-my-day.sh focus"* ]]
}

@test "focus with no profile triggers setup, not a crash" {
  run PMD focus list
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_SETUP_PROFILE"* ]]
}

@test "library work show emits PLAN_MY_DAY_LIBRARY" {
  write_plans_profile
  write_libraries
  run PMD library work show
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_LIBRARY"* ]]
  [[ "$output" == *"target: work"* ]]
  [[ "$output" == *"action: show"* ]]
}

@test "library goals show emits PLAN_MY_DAY_LIBRARY" {
  write_plans_profile
  write_libraries
  run PMD library goals show
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_DAY_LIBRARY"* ]]
  [[ "$output" == *"target: goals"* ]]
}

@test "library with unknown target fails with usage" {
  write_plans_profile
  write_libraries
  run PMD library other show
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: plan-my-day.sh library"* ]]
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
