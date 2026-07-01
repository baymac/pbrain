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
  # Gym carries an explicit kpis array; swimming below (added in a kpis test) is
  # deliberately left WITHOUT kpis to exercise the derive-default fallback.
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
   "equipment": "full gym",
   "typical_time": "17:00", "duration_min": 75, "notes": "",
   "kpis": [{"id": "sets", "label": "Sets", "type": "sets", "unit": null}]}]}
\`\`\`
EOF
}

write_library_no_kpis() {
  # A library whose activity predates KPIs — the daily flow must derive defaults.
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
  {"id": "swimming", "name": "Swimming", "occurrence": {"per": "week", "times": 2},
   "equipment": "pool",
   "typical_time": "07:00", "duration_min": 45, "notes": ""}]}
\`\`\`
EOF
}

write_swim_activity_profile() {
  local days="${1:-$DOW}"
  mkdir -p "$STORE/activities"
  cat > "$STORE/activities/swimming.v1.md" <<EOF
---
activity: Swimming
created: $TODAY
days: [$days]
occurrence: "2/week"
equipment: pool
version: 1
committed: true
---

# Swimming — Profile

## Current state
Comfortable 1.5k freestyle.
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

@test "equipment is not re-asked in the daily flow" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  run FIT
  [[ "$output" == *"do NOT ask about it"* ]]
}

@test "session instructions carry the sleep frontmatter contract" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  run FIT
  [[ "$output" == *"sleep_bed:"* && "$output" == *"sleep_wake:"* && "$output" == *"sleep_hours:"* ]]
}

@test "Step 4 asks for sleep and is given-or-blank, never carried or fabricated (PB-110)" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  run FIT
  # Final contract: sleep is mandatory to ASK, written only from what the user gives
  # this session, else BLANK. No carry-forward, no profile window, no inference.
  [[ "$output" == *"mandatory to surface"* ]]
  [[ "$output" == *"SLEEP GIVEN THIS SESSION"* ]]
  [[ "$output" == *"leave all four sleep_* BLANK"* ]]
  [[ "$output" == *"false data"* ]]
  # Carry-forward must be GONE from the instructions entirely.
  [[ "$output" != *"CARRY FORWARD"* ]]
  [[ "$output" != *"carried forward"* ]]
  [[ "$output" != *"MOST RECENT SLEEP"* ]]
}

@test "a prior session's sleep is NOT pulled into today's context (PB-110, no carry)" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  # A prior session that recorded sleep — under the old contract this was the
  # carry-forward source; under the final contract it must NOT surface at all.
  cat > "$TRACKING/2026-06-20.md" <<EOF
---
type: fitness
date: 2026-06-20
activity: gym
sleep_bed: 23:40
sleep_wake: 07:10
sleep_quality: 7
sleep_hours: 7.5
---
# Gym
EOF
  run FIT
  # No carry-forward mechanism: the dedicated sleep-source block is gone entirely,
  # so the prior night is never presented AS today's sleep source. (The raw file
  # still appears verbatim in the RECENT SESSIONS dump — that's context, not a
  # sleep source — so we assert on the source machinery, not the substring.)
  [[ "$output" != *"MOST RECENT SLEEP"* ]]
  [[ "$output" != *"most recent session (2026-06-20)"* ]]
  [[ "$output" != *"CARRY FORWARD"* ]]
  [[ "$output" != *"carried forward"* ]]
}

@test "the profile typical window is never offered as a sleep source (PB-110)" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  run FIT
  # write_overall_profile sets the window to 23:00/07:00 — it must never appear as a
  # sleep value, and the instructions must forbid using it.
  [[ "$output" != *"profile typical sleep window"* ]]
  [[ "$output" != *"sleep_bed: 23:00"* ]]
  [[ "$output" != *"sleep_wake: 07:00"* ]]
  # The instructions explicitly forbid copying the profile's typical window.
  [[ "$output" == *"profile's typical sleep window"* ]]
}

@test "daily flow opens with a skippable readiness check-in, logger-framed" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  run FIT
  [[ "$output" == *"flexible LOGGER"* && "$output" == *"Quick check-in"* \
     && "$output" == *"LOGGER, not an interrogation"* \
     && "$output" == *"straight to logging"* ]]
}

@test "sleep is mandatory to ask even when the check-in is skipped (PB-110, revised)" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  run FIT
  # Step 1 must carve sleep out of the skip: the check-in is skippable, the one
  # sleep line is not, and it is surfaced once and never force-filled or invented.
  # (PB-165 turned the cold ask into surface/confirm — the never-fabricate
  # invariant is unchanged; the wording now reads "did not give or confirm".)
  [[ "$output" == *"sleep is the one mandatory field"* ]]
  [[ "$output" == *"ALWAYS surface"* ]]
  [[ "$output" == *"still confirm the one sleep line"* ]]
  [[ "$output" == *"did not give or confirm is"* ]]
}

@test "daily flow bundles resolved per-activity KPIs (explicit kpis kept)" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  run FIT
  [[ "$output" == *"PER-ACTIVITY KPIs"* && "$output" == *'"derived": false'* ]]
}

@test "library activity without kpis gets archetype defaults derived on the fly" {
  write_overall_profile
  write_library_no_kpis
  write_swim_activity_profile "$DOW"
  run FIT
  [[ "$output" == *'"derived": true'* && "$output" == *'"type": "distance"'* ]]
}

@test "session emits an authoritative date_human and forbids guessing the weekday" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  run FIT
  local human; human="$(date '+%A, %B %e, %Y' | tr -s ' ')"
  [[ "$output" == *"date_human: $human"* && "$output" == *"NEVER compute or guess the day of the week"* ]]
}

@test "session emits an authoritative time_now and the clock disambiguates planned vs completed (PB-117)" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  run FIT
  # time_now is present as HH:MM and the clock-based contract is spelled out
  [[ "$output" =~ time_now:\ [0-2][0-9]:[0-5][0-9] ]]
  [[ "$output" == *"compare it against time_now"* ]]
  [[ "$output" == *"FUTURE SESSION (stated time is after time_now"* ]]
  [[ "$output" == *"NOT write a ## Logged section or invent any actuals"* ]]
}

@test "check-in offers skip and can persist a skip preference" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  run FIT
  # PB-37: fitness-journal is a profile-owning command, so a persisted standing pref
  # folds into the fitness profile's "prefs" array (fitness-profile.vN.md), NOT a
  # separate fitness-journal/prefs.md file.
  [[ "$output" == *"or say 'skip'"* && "$output" == *"Skip the quick check-in"* \
     && "$output" == *"fitness-profile"* && "$output" == *'"prefs" array'* ]]
}

@test "phase 2 is today's picture with one question, not a menu dump" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  run FIT
  [[ "$output" == *"TODAY'S PICTURE"* && "$output" == *"no menu dump"* \
     && "$output" == *"something else?"* ]]
}

@test "session template carries Planned + Logged sections and completed-status vocab" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  run FIT
  [[ "$output" == *"## Planned"* && "$output" == *"## Logged"* \
     && "$output" == *"status: planned | completed | partial | skipped"* ]]
}

@test "existing entry today routes to update mode" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  mkdir -p "$TRACKING"
  echo "session content" > "$TRACKING/$TODAY.md"
  run FIT
  [[ "$output" == *"FITNESS_JOURNAL_EXISTING"* && "$output" == *"What's the update"* ]]
  # update mode also carries time_now + the clock guard so it can't flip a
  # still-future session to completed (PB-117)
  [[ "$output" =~ time_now:\ [0-2][0-9]:[0-5][0-9] ]]
  [[ "$output" == *"CLOCK GUARD"* ]]
}

@test "fresh setup library template includes a kpis field" {
  run FIT
  [[ "$output" == *"FITNESS_JOURNAL_SETUP_PROFILE"* && "$output" == *'"kpis":'* ]]
}

@test "fresh setup library schema does NOT carry days; days live in step-2 profile (PB-178)" {
  run FIT
  [[ "$output" == *"FITNESS_JOURNAL_SETUP_PROFILE"* ]]
  # The LIBRARY is a pure catalogue — its JSON schema must not emit a days field.
  [[ "$output" != *'"days"'* ]]
  # Step 1 asks occurrence only, not fixed days.
  [[ "$output" == *"occurrence only"* ]]
}

@test "step-2 per-activity setup asks fixed days and owns the schedule (PB-178)" {
  write_overall_profile
  write_library
  run FIT
  [[ "$output" == *"FITNESS_JOURNAL_SETUP_ACTIVITY_PROFILES"* ]]
  # The per-activity profile is where fixed days are captured now.
  [[ "$output" == *"FIXED days"* ]]
  [[ "$output" == *"sole owner of the schedule"* ]]
  [[ "$output" == *"does NOT carry days"* ]]
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

# ── journal sleep prefill (PB-165) ──────────────────────────────────────────

@test "journal_sleep_hint carries today's journal sleep line when present" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  mkdir -p "$PBRAIN_VAULT/life/daily-tracking"
  cat > "$PBRAIN_VAULT/life/daily-tracking/$TODAY.md" <<EOF
---
type: journal
date: $TODAY
---
# Focus
- Today: gym, clean diet. slept at 4:30, woke up at 12pm.
EOF
  run FIT
  [ "$status" -eq 0 ]
  [[ "$output" == *"FITNESS_JOURNAL_SESSION"* ]]
  [[ "$output" == *"journal_sleep_hint:"* ]]
  [[ "$output" == *"slept at 4:30, woke up at 12pm"* ]]
}

@test "journal_sleep_hint emits the sentinel when no journal exists" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  # no life/daily-tracking file at all
  run FIT
  [ "$status" -eq 0 ]
  [[ "$output" == *"journal_sleep_hint: (none found in today journal)"* ]]
}

@test "journal_sleep_hint ignores journal prose with no sleep mention" {
  write_overall_profile
  write_library
  write_gym_activity_profile "$DOW"
  mkdir -p "$PBRAIN_VAULT/life/daily-tracking"
  cat > "$PBRAIN_VAULT/life/daily-tracking/$TODAY.md" <<EOF
---
type: journal
date: $TODAY
---
# Focus
- Ship the PB-165 fix and get to the gym.
EOF
  run FIT
  [ "$status" -eq 0 ]
  [[ "$output" == *"journal_sleep_hint: (none found in today journal)"* ]]
}
