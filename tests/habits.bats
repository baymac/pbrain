#!/usr/bin/env bats
# Tests for the habits redesign — criteria model (daily/weekly/monthly ×
# at_least/at_most), stable-id slugs, the structured status evaluator + text
# rollup, the add/edit/archive/history/log subcommands, and the ride-along
# extraction emitter.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_DB_FILE="$TMP/pbrain.db"
  export PBRAIN_HABITS_PROFILE_FILE="$TMP/Habits Profile.md"
  export PBRAIN_HABIT_TRACK_DIR="$TMP/habit-tracking"
  export PBRAIN_VAULT="$TMP/vault"; mkdir -p "$PBRAIN_VAULT"
  export PBRAIN_SELF_IMPROVE=off
  source "$REPO_ROOT/lib/profile.sh"   # pbrain_profile_json (habits.sh depends on it)
  source "$REPO_ROOT/lib/db.sh"
  source "$REPO_ROOT/lib/habits.sh"
  pbrain_db_init
}

teardown() {
  rm -rf "$TMP"
}

HABITS() { bash "$REPO_ROOT/commands/habits.sh" "$@"; }

# New-schema profile: one of each criteria flavor.
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
    { "id": "brush-at-night", "name": "Brush at night", "schedule_type": "daily",   "direction": "at_least", "target_count": 1, "priority": "high",   "archived": false },
    { "id": "nail-cut",       "name": "Nail cut",       "schedule_type": "weekly",  "direction": "at_least", "target_count": 2, "priority": "low",    "archived": false },
    { "id": "long-run",       "name": "Long run",       "schedule_type": "monthly", "direction": "at_least", "target_count": 5, "priority": "medium", "archived": false },
    { "id": "alcohol",        "name": "Alcohol",        "schedule_type": "weekly",  "direction": "at_most",  "target_count": 2, "priority": "medium", "archived": false }
  ]
}
```
EOF
}

# Legacy-schema profile (kind/cap_period/cap_count, no ids).
_write_legacy_profile() {
  cat > "$PBRAIN_HABITS_PROFILE_FILE" <<'EOF'
---
type: habits-profile
---

# Habits profile

```json
{
  "habits": [
    { "name": "Meditate", "kind": "build", "priority": "high",   "cap_period": "week",  "cap_count": 7 },
    { "name": "Alcohol",  "kind": "limit", "priority": "medium", "cap_period": "week",  "cap_count": 2 }
  ]
}
```
EOF
}

_log_event() {  # _log_event <display-name> <date> [count]
  python3 - "$PBRAIN_DB_FILE" "$1" "$2" "${3:-1}" <<'PY'
import sqlite3, sys, re
db, name, date, count = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
hid = re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-") or "habit"
c = sqlite3.connect(db)
c.execute("insert into habit_events(habit_id,habit,occurred_on,count,source,created_at) "
          "values(?,?,?,?,'t','t') on conflict(habit_id,occurred_on) do update set count=excluded.count",
          (hid, name, date, count))
c.commit()
PY
}

# ── slug ────────────────────────────────────────────────────────────────────
@test "pbrain_habit_slug normalizes name to a stable slug" {
  run pbrain_habit_slug "Brush at night"
  [ "$output" = "brush-at-night" ]
  run pbrain_habit_slug "  Long Run!!  "
  [ "$output" = "long-run" ]
  run pbrain_habit_slug "!!!"
  [ "$output" = "habit" ]
}

@test "pbrain_habit_slug appends a collision suffix" {
  run pbrain_habit_slug "Walk" "$(printf 'walk\nwalk-2')"
  [ "$output" = "walk-3" ]
}

# ── profile json + status ────────────────────────────────────────────────────
@test "habits_json is empty when no profile exists" {
  run pbrain_habits_json
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "habits_json extracts valid JSON from the fenced block" {
  _write_profile
  run pbrain_habits_json
  [[ "$output" == *'"Brush at night"'* ]]
  echo "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

@test "status is {} when no profile exists" {
  run pbrain_habits_status 2026-06-03
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "status sorts by priority, excludes archived, computes fulfillment" {
  _write_profile
  _log_event "Brush at night" 2026-06-03
  run pbrain_habits_status 2026-06-03
  echo "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
habits = d["habits"]
# high priority first
assert habits[0]["id"] == "brush-at-night", [h["id"] for h in habits]
# 4 active, none archived
assert d["count"] == 4
brush = next(h for h in habits if h["id"] == "brush-at-night")
assert brush["schedule_type"] == "daily"
assert brush["today_count"] == 1
assert brush["fulfilled"] is True
assert brush["streak"] == 1
'
}

# ── rollup text rendering per criteria type ──────────────────────────────────
@test "rollup is empty when no profile exists" {
  run pbrain_habits_rollup 2026-06-03
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "rollup flags a limit habit over its cap" {
  _write_profile
  _log_event Alcohol 2026-06-01
  _log_event Alcohol 2026-06-02
  _log_event Alcohol 2026-06-03
  run pbrain_habits_rollup 2026-06-03
  [[ "$output" == *"Alcohol"* ]]
  [[ "$output" == *"3/2 this week"* ]]
  [[ "$output" == *"OVER"* ]]
}

@test "rollup flags a limit habit exactly at cap" {
  _write_profile
  _log_event Alcohol 2026-06-01
  _log_event Alcohol 2026-06-02
  run pbrain_habits_rollup 2026-06-03
  [[ "$output" == *"at cap"* ]]
  [[ "$output" != *"OVER"* ]]
}

@test "rollup shows a weekly build habit short of target with the hourglass" {
  _write_profile
  _log_event "Nail cut" 2026-06-02
  run pbrain_habits_rollup 2026-06-03
  [[ "$output" == *"Nail cut"* ]]
  [[ "$output" == *"1/2 this week"* ]]
  [[ "$output" == *"⏳"* ]]
}

@test "rollup marks a weekly build habit that met its target" {
  _write_profile
  _log_event "Nail cut" 2026-06-01
  _log_event "Nail cut" 2026-06-02
  run pbrain_habits_rollup 2026-06-03
  [[ "$output" == *"2/2 this week"* ]]
  [[ "$output" == *"✅"* ]]
}

@test "rollup shows a daily habit done today with a streak" {
  _write_profile
  _log_event "Brush at night" 2026-06-01
  _log_event "Brush at night" 2026-06-02
  _log_event "Brush at night" 2026-06-03
  run pbrain_habits_rollup 2026-06-03
  [[ "$output" == *"done today ✅"* ]]
  [[ "$output" == *"streak 3"* ]]
}

@test "rollup shows a daily habit not yet done today" {
  _write_profile
  run pbrain_habits_rollup 2026-06-03
  [[ "$output" == *"Brush at night"* ]]
  [[ "$output" == *"not yet today ⏳"* ]]
  [[ "$output" == *"never logged"* ]]
}

@test "rollup counts a monthly habit over the calendar month" {
  _write_profile
  _log_event "Long run" 2026-06-01
  _log_event "Long run" 2026-06-15
  run pbrain_habits_rollup 2026-06-30
  [[ "$output" == *"2/5 this month"* ]]
}

@test "rollup reads a legacy (kind/cap_period/cap_count) profile" {
  _write_legacy_profile
  _log_event Alcohol 2026-06-01
  _log_event Alcohol 2026-06-02
  _log_event Alcohol 2026-06-03
  run pbrain_habits_rollup 2026-06-03
  [[ "$output" == *"Alcohol"* ]]
  [[ "$output" == *"OVER"* ]]
}

@test "rollup caps at 20 habits and shows a +N more line" {
  python3 - "$PBRAIN_HABITS_PROFILE_FILE" <<'PY'
import json, sys
habits = [{"id": f"h{i}", "name": f"Habit {i}", "schedule_type": "weekly",
           "direction": "at_least", "target_count": 1, "priority": "low"} for i in range(25)]
with open(sys.argv[1], "w") as f:
    f.write("# Habits profile\n\n```json\n" + json.dumps({"habits": habits}, indent=2) + "\n```\n")
PY
  run pbrain_habits_rollup 2026-06-03
  [[ "$output" == *"+5 more"* ]]
}

# ── add / edit / archive subcommands ─────────────────────────────────────────
@test "add mints a stable id and writes valid JSON" {
  run HABITS add --name "Read" --type daily --direction at_least --target 1 --priority high
  [ "$status" -eq 0 ]
  [[ "$output" == *"read"* ]]
  run pbrain_habits_json
  echo "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
h = next(x for x in d["habits"] if x["id"] == "read")
assert h["schedule_type"] == "daily" and h["direction"] == "at_least"
assert h["target_count"] == 1 and h["priority"] == "high"
assert h["archived"] is False
'
}

@test "add gives a colliding name a -2 id" {
  HABITS add --name "Walk" --type daily --direction at_least
  run HABITS add --name "Walk" --type weekly --direction at_least --target 3
  [ "$status" -eq 0 ]
  run pbrain_habits_json
  echo "$output" | python3 -c '
import json, sys
ids = [h["id"] for h in json.load(sys.stdin)["habits"]]
assert "walk" in ids and "walk-2" in ids, ids
'
}

@test "edit changes criteria by id and keeps the id" {
  _write_profile
  run HABITS edit --id nail-cut --target 3 --priority high
  [ "$status" -eq 0 ]
  run pbrain_habits_json
  echo "$output" | python3 -c '
import json, sys
h = next(x for x in json.load(sys.stdin)["habits"] if x["id"] == "nail-cut")
assert h["target_count"] == 3 and h["priority"] == "high"
'
}

@test "edit renames without losing history (id stable)" {
  _write_profile
  _log_event "Brush at night" 2026-06-03
  HABITS edit --id brush-at-night --name "Night brush"
  # history is keyed by id, so the renamed habit still sees its event
  run HABITS history --name "Night brush"
  [[ "$output" == *"2026-06-03"* ]]
}

@test "archive soft-deletes: excluded from status, history preserved" {
  _write_profile
  _log_event "Long run" 2026-06-01
  HABITS archive --id long-run
  run pbrain_habits_status 2026-06-30
  echo "$output" | python3 -c '
import json, sys
ids = [h["id"] for h in json.load(sys.stdin)["habits"]]
assert "long-run" not in ids, ids
'
  run HABITS history --name "Long run"
  [[ "$output" == *"2026-06-01"* ]]
}

# ── history ──────────────────────────────────────────────────────────────────
@test "history lists events newest-first; empty case is graceful" {
  _write_profile
  run HABITS history --name "Nail cut"
  [[ "$output" == *"no history"* ]]
  _log_event "Nail cut" 2026-06-01
  _log_event "Nail cut" 2026-06-05
  run HABITS history --name "Nail cut"
  # newest first
  [[ "$(echo "$output" | grep -n 2026-06-05 | cut -d: -f1)" -lt "$(echo "$output" | grep -n 2026-06-01 | cut -d: -f1)" ]]
}

# ── log subcommand: resolve + reject unknown ─────────────────────────────────
@test "log resolves name to id and is idempotent per (habit, day)" {
  _write_profile
  HABITS log --name "Brush at night" --date 2026-06-03 --source journal
  HABITS log --name "Brush at night" --date 2026-06-03 --source plan-my-day
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute(\"select count(*) from habit_events where habit_id='brush-at-night' and occurred_on='2026-06-03'\").fetchone()[0])" "$PBRAIN_DB_FILE"
  [ "$output" = "1" ]
}

@test "log rejects a name that is not a tracked habit" {
  _write_profile
  run HABITS log --name "Skydiving" --date 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a tracked habit"* ]]
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute('select count(*) from habit_events').fetchone()[0])" "$PBRAIN_DB_FILE"
  [ "$output" = "0" ]
}

@test "log refuses an archived habit (treated as untracked)" {
  _write_profile
  HABITS archive --id alcohol
  run HABITS log --name "Alcohol" --date 2026-06-03
  [[ "$output" == *"not a tracked habit"* ]]
}

# ── extraction emitter ───────────────────────────────────────────────────────
@test "emit_habits_extract is silent without a profile" {
  run pbrain_emit_habits_extract journal
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emit_habits_extract names the habits + the mark command" {
  _write_profile
  run pbrain_emit_habits_extract journal
  [ "$status" -eq 0 ]
  [[ "$output" == *"HABIT EXTRACTION (journal)"* ]]
  [[ "$output" == *"Brush at night"* ]]
  [[ "$output" == *"mark --name"* ]]
}

# ── markdown tracking layer (md is source of truth; DB derived) ──────────────
@test "track init creates a dated md with a row per active habit + empty cells" {
  _write_profile
  run HABITS track --date 2026-06-03
  [ "$status" -eq 0 ]
  [ -f "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md" ]
  body="$(cat "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md")"
  [[ "$body" == *"| Habit | Criteria | Progress | Done | Count | Note |"* ]]
  [[ "$body" == *"Brush at night"* ]]
  [[ "$body" == *"weekly ≥2"* ]]
  [[ "$body" == *"weekly ≤2"* ]]
}

@test "mark ticks the Done cell and rejects untracked names" {
  _write_profile
  HABITS mark --name "Brush at night" --date 2026-06-03
  HABITS mark --name "Alcohol" --date 2026-06-03 --note "one beer"
  run HABITS mark --name "Skydiving" --date 2026-06-03
  [[ "$output" == *"not a tracked habit"* ]]
  body="$(cat "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md")"
  [[ "$body" == *"| Brush at night | daily | "*" | x |"* ]]
  [[ "$body" == *"one beer"* ]]
  [[ "$body" != *"Skydiving"* ]]
}

@test "sync mirrors the md done-rows into the DB" {
  _write_profile
  HABITS mark --name "Brush at night" --date 2026-06-03
  HABITS mark --name "Alcohol" --date 2026-06-03
  HABITS sync --days 0
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(sorted(r[0] for r in c.execute(\"select habit_id from habit_events where occurred_on='2026-06-03'\")))" "$PBRAIN_DB_FILE"
  [ "$output" = "['alcohol', 'brush-at-night']" ]
}

@test "sync mirror removes an event when the md is unchecked" {
  _write_profile
  HABITS mark --name "Alcohol" --date 2026-06-03
  HABITS sync --days 0
  # uncheck Alcohol in the md by rewriting its Done cell to empty
  python3 - "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md" <<'PY'
import sys, re
p = sys.argv[1]
t = open(p).read()
t = re.sub(r"(\| Alcohol \|[^\n]*?\|) x (\|)", r"\1   \2", t)
open(p, "w").write(t)
PY
  HABITS sync --days 0
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute(\"select count(*) from habit_events where occurred_on='2026-06-03'\").fetchone()[0])" "$PBRAIN_DB_FILE"
  [ "$output" = "0" ]
}

@test "consolidate syncs to DB then prunes unchecked habits from the day file" {
  _write_profile
  HABITS track --date 2026-06-03
  HABITS mark --name "Brush at night" --date 2026-06-03
  run HABITS consolidate --date 2026-06-03
  [ "$status" -eq 0 ]
  # DB has the one done habit
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute(\"select habit_id from habit_events where occurred_on='2026-06-03'\").fetchone()[0])" "$PBRAIN_DB_FILE"
  [ "$output" = "brush-at-night" ]
  # the md keeps only the done row
  body="$(cat "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md")"
  [[ "$body" == *"Brush at night"* ]]
  [[ "$body" != *"Nail cut"* ]]
  [[ "$body" != *"Alcohol"* ]]
}

@test "dashboard reflects today's marks (read path syncs md first)" {
  _write_profile
  HABITS mark --name "Brush at night" --date "$(date +%Y-%m-%d)"
  run HABITS
  [[ "$output" == *"HABITS_DASHBOARD"* ]]
  [[ "$output" == *"done today ✅"* ]]
}

# ── new-habit suggestion nudge + TTL suppression ─────────────────────────────
@test "emit_habits_extract includes a gated suggest block" {
  _write_profile
  export PBRAIN_HABIT_SUGGEST_FILE="$TMP/seen"
  run pbrain_emit_habits_extract journal
  [[ "$output" == *"HABIT SUGGEST (journal)"* ]]
  [[ "$output" == *"STANDING INTENTION"* ]]
  [[ "$output" == *"suggest-seen"* ]]
}

@test "suggest-seen records a candidate so the emitter won't re-suggest it" {
  _write_profile
  export PBRAIN_HABIT_SUGGEST_FILE="$TMP/seen"
  HABITS suggest-seen --name "Cold shower"
  run pbrain_habit_suggest_recent 2026-06-03
  [[ "$output" == *"cold-shower"* ]]
  run pbrain_emit_habits_extract journal
  [[ "$output" == *"do NOT re-suggest these: cold-shower"* ]]
}

@test "suggest suppression expires after the TTL window" {
  export PBRAIN_HABIT_SUGGEST_FILE="$TMP/seen"
  export PBRAIN_HABIT_SUGGEST_TTL_DAYS=14
  printf 'cold-shower\t2026-06-01\n' > "$PBRAIN_HABIT_SUGGEST_FILE"
  run pbrain_habit_suggest_recent 2026-06-10   # 9 days → still suppressed
  [[ "$output" == *"cold-shower"* ]]
  run pbrain_habit_suggest_recent 2026-06-30   # 29 days → expired
  [[ "$output" != *"cold-shower"* ]]
}
