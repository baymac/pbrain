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
  export PBRAIN_MIGRATIONS=0   # keep the vault migration runner out of unit tests
  export PBRAIN_UPDATE_CHECK=0  # never hit the network / nag in unit tests
  export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/pbrain"
  export PBRAIN_DB_FILE="$TMP/pbrain.db"
  export PBRAIN_HABITS_PROFILE_FILE="$TMP/Habits Profile.md"
  export PBRAIN_HABIT_TRACK_DIR="$TMP/habit-tracking"
  export PBRAIN_VAULT="$TMP/vault"; mkdir -p "$PBRAIN_VAULT"
  export PBRAIN_SELF_IMPROVE=off
  # Force the Reminders helper UNAVAILABLE so reminder ops never build/launch a
  # real EventKit app in CI: point the app under a regular FILE, so the builder's
  # `mkdir -p` fails cleanly and pbrain_reminders_run returns UNAVAILABLE. The
  # Apple round-trip (create/complete/status) is validated manually, not here.
  : > "$TMP/blockapp"
  export PBRAIN_REMINDERS_APP="$TMP/blockapp/pbrain-reminders.app"
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
  HABITS sync --days 0 --date 2026-06-03
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(sorted(r[0] for r in c.execute(\"select habit_id from habit_events where occurred_on='2026-06-03'\")))" "$PBRAIN_DB_FILE"
  [ "$output" = "['alcohol', 'brush-at-night']" ]
}

@test "sync mirror removes an event when the md is unchecked" {
  _write_profile
  HABITS mark --name "Alcohol" --date 2026-06-03
  HABITS sync --days 0 --date 2026-06-03
  # uncheck Alcohol in the md by rewriting its Done cell to empty
  python3 - "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md" <<'PY'
import sys, re
p = sys.argv[1]
t = open(p).read()
t = re.sub(r"(\| Alcohol \|[^\n]*?\|) x (\|)", r"\1   \2", t)
open(p, "w").write(t)
PY
  HABITS sync --days 0 --date 2026-06-03
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

# ── measured habits (first-class quantity tracking) ──────────────────────────
@test "add stores a unit + measure_target on the habit" {
  run HABITS add --name "Water" --type daily --direction at_least --unit L --measure-target 4 --priority high
  [ "$status" -eq 0 ]
  [[ "$output" == *"4 L"* ]]
  run pbrain_habits_json
  echo "$output" | python3 -c '
import json, sys
h = next(x for x in json.load(sys.stdin)["habits"] if x["id"] == "water")
assert h["unit"] == "L", h
assert h["measure_target"] == 4, h
'
}

@test "add keeps a fractional measure_target as a float" {
  HABITS add --name "Coffee" --type daily --direction at_most --unit cups --measure-target 2.5
  run pbrain_habits_json
  echo "$output" | python3 -c '
import json, sys
h = next(x for x in json.load(sys.stdin)["habits"] if x["id"] == "coffee")
assert h["measure_target"] == 2.5, h
'
}

@test "status evaluates a measured daily habit by amount, not occurrences" {
  HABITS add --name "Water" --type daily --direction at_least --unit L --measure-target 4 >/dev/null
  HABITS mark --name "Water" --date 2026-06-03 --amount 2.5 >/dev/null
  HABITS sync --days 0 --date 2026-06-03 >/dev/null
  run pbrain_habits_status 2026-06-03
  echo "$output" | python3 -c '
import json, sys
h = next(x for x in json.load(sys.stdin)["habits"] if x["id"] == "water")
assert h["measured"] is True
assert h["period_used"] == 2.5 and h["period_target"] == 4
assert h["fulfilled"] is False        # 2.5 < 4
'
  HABITS mark --name "Water" --date 2026-06-03 --amount 4 >/dev/null
  HABITS sync --days 0 --date 2026-06-03 >/dev/null
  run pbrain_habits_status 2026-06-03
  echo "$output" | python3 -c '
import json, sys
h = next(x for x in json.load(sys.stdin)["habits"] if x["id"] == "water")
assert h["fulfilled"] is True         # 4 >= 4
'
}

@test "status sums amounts over the week for a measured weekly habit" {
  HABITS add --name "Run" --type weekly --direction at_least --unit km --measure-target 20 >/dev/null
  HABITS mark --name "Run" --date 2026-06-01 --amount 8 >/dev/null
  HABITS mark --name "Run" --date 2026-06-03 --amount 12 >/dev/null
  HABITS sync --days 7 >/dev/null
  run pbrain_habits_status 2026-06-03
  echo "$output" | python3 -c '
import json, sys
h = next(x for x in json.load(sys.stdin)["habits"] if x["id"] == "run")
assert h["period_used"] == 20 and h["fulfilled"] is True, h
'
}

@test "rollup renders measured progress with the unit" {
  HABITS add --name "Water" --type daily --direction at_least --unit L --measure-target 4 --priority high >/dev/null
  HABITS mark --name "Water" --date 2026-06-03 --amount 2.5 >/dev/null
  HABITS sync --days 0 --date 2026-06-03 >/dev/null
  run pbrain_habits_rollup 2026-06-03
  [[ "$output" == *"2.5/4 L today ⏳"* ]]
}

@test "rollup flags a measured limit habit over its target" {
  HABITS add --name "Sugar" --type daily --direction at_most --unit g --measure-target 30 >/dev/null
  HABITS mark --name "Sugar" --date 2026-06-03 --amount 45 >/dev/null
  HABITS sync --days 0 --date 2026-06-03 >/dev/null
  run pbrain_habits_rollup 2026-06-03
  [[ "$output" == *"45/30 g today"* ]]
  [[ "$output" == *"OVER"* ]]
}

@test "mark writes the amount into the Count cell of the tracking md" {
  HABITS add --name "Water" --type daily --direction at_least --unit L --measure-target 4 >/dev/null
  HABITS mark --name "Water" --date 2026-06-03 --amount 2.5 >/dev/null
  body="$(cat "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md")"
  [[ "$body" == *"daily ≥4 L"* ]]
  [[ "$body" == *"| Water |"*"| x | 2.5 |"* ]]
}

@test "sync stores a measured amount in the amount column (count stays 1)" {
  HABITS add --name "Water" --type daily --direction at_least --unit L --measure-target 4 >/dev/null
  HABITS mark --name "Water" --date 2026-06-03 --amount 2.5 >/dev/null
  HABITS sync --days 0 --date 2026-06-03 >/dev/null
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute(\"select count,amount from habit_events where habit_id='water' and occurred_on='2026-06-03'\").fetchone())" "$PBRAIN_DB_FILE"
  [ "$output" = "(1, 2.5)" ]
}

@test "sync without --date defaults to today (empty-string fallback)" {
  _write_profile
  TODAY="$(date +%Y-%m-%d)"
  HABITS mark --name "Brush at night" --date "$TODAY"
  HABITS sync --days 0
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute(\"select count(*) from habit_events where occurred_on=?\", [sys.argv[2]]).fetchone()[0])" "$PBRAIN_DB_FILE" "$TODAY"
  [ "$output" = "1" ]
}

@test "sync --days N --date covers the full N-day window" {
  _write_profile
  HABITS mark --name "Brush at night" --date 2026-06-01
  HABITS mark --name "Alcohol" --date 2026-06-03
  HABITS sync --days 2 --date 2026-06-03
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(sorted(r[0] for r in c.execute(\"select habit_id from habit_events where occurred_on>='2026-06-01'\")))" "$PBRAIN_DB_FILE"
  [ "$output" = "['alcohol', 'brush-at-night']" ]
}

@test "log records an amount on a measured habit" {
  HABITS add --name "Water" --type daily --direction at_least --unit L --measure-target 4 >/dev/null
  HABITS log --name "Water" --date 2026-06-03 --amount 3.5 --source journal
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute(\"select amount from habit_events where habit_id='water'\").fetchone()[0])" "$PBRAIN_DB_FILE"
  [ "$output" = "3.5" ]
}

@test "edit can clear a measure back to occurrence-based" {
  HABITS add --name "Water" --type daily --direction at_least --unit L --measure-target 4 >/dev/null
  HABITS edit --id water --measure-target ""
  run pbrain_habits_json
  echo "$output" | python3 -c '
import json, sys
h = next(x for x in json.load(sys.stdin)["habits"] if x["id"] == "water")
assert h["measure_target"] is None, h
'
}

@test "emit_habits_extract tags measured habits and mentions --amount" {
  HABITS add --name "Water" --type daily --direction at_least --unit L --measure-target 4 >/dev/null
  run pbrain_emit_habits_extract journal
  [ "$status" -eq 0 ]
  [[ "$output" == *"measured: 4 L"* ]]
  [[ "$output" == *"--amount"* ]]
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

# ── post-fix regression: live progress, daily-limit format, refresh, lapse-only ──

@test "mark recomputes the Progress cell live (the day's own mark counts)" {
  _write_profile
  HABITS mark --name "Nail cut" --date 2026-06-03 >/dev/null
  body="$(cat "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md")"
  # was the kickboxing bug: progress must read 1/2 the instant it's marked, not 0/2
  [[ "$body" == *"| Nail cut | weekly ≥2 | 1/2 wk | x |"* ]]
}

@test "daily limit Progress reads today-vs-cap, not a weekly sum" {
  HABITS add --name "Smokes" --type daily --direction at_most --target 0 --priority high >/dev/null
  HABITS mark --name "Smokes" --date 2026-06-03 --count 3 --note "3 cigs" >/dev/null
  body="$(cat "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md")"
  [[ "$body" == *"| Smokes | daily (limit) | 3/0 day | x | 3 | 3 cigs |"* ]]
}

@test "refresh recomputes a stale Progress cell from the DB without touching marks" {
  _write_profile
  mkdir -p "$PBRAIN_HABIT_TRACK_DIR"
  cat > "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md" <<'EOF'
---
type: habit-tracking
date: 2026-06-03
tags: []
---

# Habits — 2026-06-03

| Habit | Criteria | Progress | Done | Count | Note |
|-------|----------|----------|------|-------|------|
| Nail cut | weekly ≥2 | 9/9 stale | x |  |  |
EOF
  run HABITS refresh --date 2026-06-03
  [ "$status" -eq 0 ]
  body="$(cat "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md")"
  [[ "$body" == *"| Nail cut | weekly ≥2 | 1/2 wk | x |"* ]]
  [[ "$body" != *"9/9 stale"* ]]
}

@test "emit_habits_extract tags limit vs build correctly and instructs lapse-only" {
  _write_profile
  run pbrain_emit_habits_extract journal
  [ "$status" -eq 0 ]
  [[ "$output" == *"Alcohol [limit]"* ]]
  [[ "$output" == *"Brush at night [build]"* ]]
  [[ "$output" == *"work INVERSELY"* ]]
  [[ "$output" == *"LAPSED"* ]]
}

# ── coverage gap tests: mark-no-db, refresh-no-db, refresh_range, refresh --days ──

@test "mark writes the file correctly when the DB is absent (con is None path)" {
  _write_profile
  HABITS track --date 2026-06-03 >/dev/null
  export PBRAIN_DB_FILE="$TMP/nonexistent.db"
  run HABITS mark --name "Nail cut" --date 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" == *"marked: Nail cut on 2026-06-03"* ]]
  body="$(cat "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md")"
  [[ "$body" == *"| Nail cut |"* ]]
  [[ "$body" == *"| x |"* ]]
}

@test "refresh rewrites the file even when DB is absent (no mirror, no progress recompute)" {
  _write_profile
  mkdir -p "$PBRAIN_HABIT_TRACK_DIR"
  cat > "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md" <<'EOF'
---
type: habit-tracking
date: 2026-06-03
tags: []
---

# Habits — 2026-06-03

| Habit | Criteria | Progress | Done | Count | Note |
|-------|----------|----------|------|-------|------|
| Nail cut | weekly ≥2 | 9/9 stale | x |  |  |
EOF
  export PBRAIN_DB_FILE="$TMP/nonexistent.db"
  run HABITS refresh --date 2026-06-03
  [ "$status" -eq 0 ]
  [ -f "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md" ]
  [[ "$output" == *"refresh"* ]]
}

@test "refresh_range processes multiple days oldest-to-newest, skipping missing files" {
  _write_profile
  mkdir -p "$PBRAIN_HABIT_TRACK_DIR"
  for d in 2026-06-01 2026-06-03; do
    cat > "$PBRAIN_HABIT_TRACK_DIR/$d.md" <<EOF
---
type: habit-tracking
date: $d
tags: []
---

# Habits — $d

| Habit | Criteria | Progress | Done | Count | Note |
|-------|----------|----------|------|-------|------|
| Nail cut | weekly ≥2 | 9/9 stale | x |  |  |
EOF
  done
  run pbrain_habit_refresh_range 5 2026-06-03
  [ "$status" -eq 0 ]
  body01="$(cat "$PBRAIN_HABIT_TRACK_DIR/2026-06-01.md")"
  body03="$(cat "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md")"
  [[ "$body01" != *"9/9 stale"* ]]
  [[ "$body03" != *"9/9 stale"* ]]
}

@test "refresh --days N calls refresh_range and reports the range" {
  _write_profile
  mkdir -p "$PBRAIN_HABIT_TRACK_DIR"
  cat > "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md" <<'EOF'
---
type: habit-tracking
date: 2026-06-03
tags: []
---

# Habits — 2026-06-03

| Habit | Criteria | Progress | Done | Count | Note |
|-------|----------|----------|------|-------|------|
| Nail cut | weekly ≥2 | 9/9 stale | x |  |  |
EOF
  run HABITS refresh --days 3 --date 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" == *"refreshed Progress across the last 3 day(s)"* ]]
  body="$(cat "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md")"
  [[ "$body" != *"9/9 stale"* ]]
}

# ── reminder linking ─────────────────────────────────────────────────────────
@test "reminders-pending lists every undecided habit (reminders are an opt-in any habit can take)" {
  _write_profile
  run HABITS reminders-pending
  [ "$status" -eq 0 ]
  [[ "$output" == *"brush-at-night"* ]]   # daily build
  [[ "$output" == *"nail-cut"* ]]         # weekly build — now eligible
  [[ "$output" == *"long-run"* ]]         # monthly build — now eligible
  [[ "$output" == *"alcohol"* ]]          # limit habit — can opt in too (D1)
}

@test "reminders-pending drops a habit once it's decided (linked or declined)" {
  _write_profile
  HABITS reminder --id alcohol --decline
  HABITS reminder --id nail-cut --link --time 20:00
  run HABITS reminders-pending
  [[ "$output" != *"alcohol"* ]]          # declined → decided
  [[ "$output" != *"nail-cut"* ]]         # linked → decided
  [[ "$output" == *"brush-at-night"* ]]   # still undecided
}

# Count habit_reminders rows for a habit (optionally a specific date).
_hr_count() {  # <habit_id> [date]
  python3 - "$PBRAIN_DB_FILE" "$1" "${2:-}" <<'PYEOF'
import sqlite3, sys
db, hid, date = sys.argv[1], sys.argv[2], sys.argv[3]
con = sqlite3.connect(db)
if date:
    n = con.execute("SELECT COUNT(*) FROM habit_reminders WHERE habit_id=? AND occurred_on=?", (hid, date)).fetchone()[0]
else:
    n = con.execute("SELECT COUNT(*) FROM habit_reminders WHERE habit_id=?", (hid,)).fetchone()[0]
print(n)
PYEOF
}

@test "habit_reminders table is created by pbrain_db_init" {
  run python3 - "$PBRAIN_DB_FILE" <<'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
rows = con.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='habit_reminders'").fetchall()
print("yes" if rows else "no")
PYEOF
  [[ "$output" == *"yes"* ]]
}

@test "reminder --link stores intent {state,time} (no id), shows 🔔, drops from pending" {
  _write_profile
  run HABITS reminder --id brush-at-night --link --time 07:00
  [ "$status" -eq 0 ]
  [[ "$output" == *"linked 'Brush at night'"* ]]
  body="$(cat "$PBRAIN_HABITS_PROFILE_FILE")"
  [[ "$body" == *'"state": "linked"'* ]]
  [[ "$body" == *'"time": "07:00"'* ]]
  [[ "$body" != *'"id":'* ]]              # per-day ids live in the DB, not the profile
  run pbrain_habits_rollup 2026-06-03
  [[ "$output" == *"🔔 07:00"* ]]
  run HABITS reminders-pending
  [[ "$output" != *"brush-at-night"* ]]
}

@test "reminder --link requires a valid HH:MM time" {
  _write_profile
  run HABITS reminder --id brush-at-night --link --time 7am
  [ "$status" -eq 1 ]
  [[ "$output" == *"HH:MM"* ]]
}

@test "reminder --decline records the decision and drops from pending" {
  _write_profile
  run HABITS reminder --id brush-at-night --decline
  [ "$status" -eq 0 ]
  body="$(cat "$PBRAIN_HABITS_PROFILE_FILE")"
  [[ "$body" == *'"state": "declined"'* ]]
  run HABITS reminders-pending
  [[ "$output" != *"brush-at-night"* ]]
}

@test "reminders-ensure is a no-op (no rows) when no habit is linked" {
  _write_profile
  run HABITS reminders-ensure --date 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENSURED 0"* ]]
  [ "$(_hr_count brush-at-night)" = "0" ]
}

@test "reminders-ensure degrades to UNAVAILABLE and writes no rows when Reminders helper is absent" {
  _write_profile
  HABITS reminder --id brush-at-night --link --time 07:00   # link writes intent only
  run HABITS reminders-ensure --date 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNAVAILABLE"* ]]
  [ "$(_hr_count brush-at-night 2026-06-03)" = "0" ]   # no reminder id recorded → retried next run
}

@test "reminders-sync is a clean no-op when nothing is pending or done" {
  _write_profile
  run HABITS reminders-sync --date 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" == *"SYNCED pulled=0 pushed=0"* ]]
}

# Insert a pending habit_reminders row directly (simulates a created one-shot).
_hr_seed_pending() {  # <habit_id> <date> <reminder_id>
  python3 - "$PBRAIN_DB_FILE" "$1" "$2" "$3" <<'PYEOF'
import sqlite3, sys
db, hid, date, rid = sys.argv[1:5]
con = sqlite3.connect(db)
con.execute("INSERT OR REPLACE INTO habit_reminders (habit_id, occurred_on, reminder_id, status, created_at) VALUES (?,?,?,?,?)",
            (hid, date, rid, 'pending', '2026-06-03 00:00'))
con.commit(); con.close()
PYEOF
}
# Read one habit_reminders row's status (or empty).
_hr_status() {  # <habit_id> <date>
  python3 - "$PBRAIN_DB_FILE" "$1" "$2" <<'PYEOF'
import sqlite3, sys
db, hid, date = sys.argv[1:4]
con = sqlite3.connect(db)
r = con.execute("SELECT status FROM habit_reminders WHERE habit_id=? AND occurred_on=?", (hid, date)).fetchone()
print(r[0] if r else "")
PYEOF
}

@test "reminders-sync WITHOUT --sweep leaves an undone habit's one-shot pending" {
  _write_profile
  _hr_seed_pending brush-at-night 2026-06-03 R-UNDONE
  run HABITS reminders-sync --date 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" == *"swept=0"* ]]
  [ "$(_hr_status brush-at-night 2026-06-03)" = "pending" ]   # morning sync never sweeps
}

@test "reminders-sync --sweep closes an undone habit's stale one-shot" {
  _write_profile
  _hr_seed_pending brush-at-night 2026-06-03 R-UNDONE
  run HABITS reminders-sync --date 2026-06-03 --sweep
  [ "$status" -eq 0 ]
  [[ "$output" == *"swept=1"* ]]
  [ "$(_hr_status brush-at-night 2026-06-03)" = "cancelled" ] # end-of-day sweep deletes + closes
}

@test "archive of a linked habit reports LINKED_REMINDER" {
  _write_profile
  HABITS reminder --id brush-at-night --link --time 07:00
  run HABITS archive --id brush-at-night
  [ "$status" -eq 0 ]
  [[ "$output" == *"LINKED_REMINDER"* ]]
}

@test "reminder --unlink clears the link → back to undecided" {
  _write_profile
  HABITS reminder --id brush-at-night --link --time 07:00
  run HABITS reminder --id brush-at-night --unlink
  [ "$status" -eq 0 ]
  body="$(cat "$PBRAIN_HABITS_PROFILE_FILE")"
  [[ "$body" != *'"state": "linked"'* ]]
  run HABITS reminders-pending
  [[ "$output" == *"brush-at-night"* ]]   # back to undecided → offered again
}

# ── reminders are opt-in for ANY habit; the SCHEDULE (not the link) gates days ──
@test "reminder --link works for a limit habit (any habit can opt in)" {
  _write_profile
  run HABITS reminder --id alcohol --link --time 20:00
  [ "$status" -eq 0 ]
  [[ "$output" == *"linked 'Alcohol'"* ]]
  body="$(cat "$PBRAIN_HABITS_PROFILE_FILE")"
  [[ "$body" == *'"state": "linked"'* ]]
}

@test "reminder --link no longer accepts --days (the schedule owns days)" {
  _write_profile
  # A stray --days is simply ignored; the habit's schedule decides the days.
  run HABITS reminder --id brush-at-night --link --time 07:00 --days mon,wed,fri
  [ "$status" -eq 0 ]
  body="$(cat "$PBRAIN_HABITS_PROFILE_FILE")"
  [[ "$body" != *'"days"'* ]]             # nothing written onto the reminder intent
}

# ── add/edit write schedule blocks; ensure gates on them ────────────────────
@test "add --schedule weekdays --days writes a weekdays schedule" {
  _write_profile
  run HABITS add --name "Gym" --schedule weekdays --days mon,wed,fri --direction at_least
  [ "$status" -eq 0 ]
  body="$(cat "$PBRAIN_HABITS_PROFILE_FILE")"
  [[ "$body" == *'"type": "weekdays"'* ]]
  [[ "$body" == *'"mon"'* && "$body" == *'"wed"'* && "$body" == *'"fri"'* ]]
}

@test "add --times-per-week resolves to spaced weekdays from the start day" {
  _write_profile
  run HABITS add --name "Run" --schedule weekdays --times-per-week 2 --start-day mon --direction at_least
  [ "$status" -eq 0 ]
  body="$(cat "$PBRAIN_HABITS_PROFILE_FILE")"
  [[ "$body" == *'"mon"'* && "$body" == *'"thu"'* ]]   # 2/week from Mon → Mon, Thu
}

@test "add --schedule interval writes start_date + every_days" {
  _write_profile
  run HABITS add --name "Deep clean" --schedule interval --every-days 15 --start-date 2026-06-01 --direction at_least
  [ "$status" -eq 0 ]
  body="$(cat "$PBRAIN_HABITS_PROFILE_FILE")"
  [[ "$body" == *'"type": "interval"'* ]]
  [[ "$body" == *'"every_days": 15'* ]]
}

@test "edit --schedule rebuilds the schedule block" {
  _write_profile
  HABITS add --name "Stretch" --schedule daily --direction at_least
  run HABITS edit --id stretch --schedule weekdays --days tue,sat
  [ "$status" -eq 0 ]
  body="$(cat "$PBRAIN_HABITS_PROFILE_FILE")"
  [[ "$body" == *'"type": "weekdays"'* ]]
  [[ "$body" == *'"tue"'* && "$body" == *'"sat"'* ]]
}

@test "reminders-ensure skips a scheduled-weekday habit on an off-day (no-op, no Apple call)" {
  _write_profile
  HABITS add --name "Gym" --schedule weekdays --days mon,wed,fri --direction at_least
  HABITS reminder --id gym --link --time 07:00
  run HABITS reminders-ensure --date 2026-06-02   # Tuesday → not scheduled
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENSURED 0"* ]]
  [ "$(_hr_count gym 2026-06-02)" = "0" ]
}

@test "reminders-ensure attempts creation on a scheduled weekday (degrades to UNAVAILABLE)" {
  _write_profile
  HABITS add --name "Gym" --schedule weekdays --days mon,wed,fri --direction at_least
  HABITS reminder --id gym --link --time 07:00
  run HABITS reminders-ensure --date 2026-06-03   # Wednesday → scheduled
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNAVAILABLE"* ]]              # tried to create, helper absent in CI
  [ "$(_hr_count gym 2026-06-03)" = "0" ]
}

# A profile with explicit `schedule` blocks (interval + monthly), both linked.
_write_scheduled_profile() {
  cat > "$PBRAIN_HABITS_PROFILE_FILE" <<'EOF'
---
type: habits-profile
---

```json
{
  "created": "2026-06-01",
  "habits": [
    { "id": "deep-clean", "name": "Deep clean", "direction": "at_least",
      "schedule": { "type": "interval", "start_date": "2026-06-01", "every_days": 15 },
      "priority": "medium", "archived": false,
      "reminder": { "state": "linked", "time": "09:00" } },
    { "id": "pay-rent", "name": "Pay rent", "direction": "at_least",
      "schedule": { "type": "monthly", "days_of_month": [1] },
      "priority": "high", "archived": false,
      "reminder": { "state": "linked", "time": "08:00" } }
  ]
}
```
EOF
}

@test "reminders-ensure honors an explicit interval schedule (off-cadence = no-op)" {
  _write_scheduled_profile
  run HABITS reminders-ensure --date 2026-06-10   # not a multiple of 15 from Jun 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENSURED 0"* ]]
  [ "$(_hr_count deep-clean 2026-06-10)" = "0" ]
}

@test "reminders-ensure honors an explicit interval schedule (on-cadence attempts)" {
  _write_scheduled_profile
  run HABITS reminders-ensure --date 2026-06-16   # exactly 15 days after start
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNAVAILABLE"* ]]              # due → tried to create
}

@test "reminders-ensure honors an explicit monthly schedule (the 1st attempts, the 2nd is a no-op)" {
  _write_scheduled_profile
  run HABITS reminders-ensure --date 2026-07-01   # the 1st → due
  [[ "$output" == *"UNAVAILABLE"* ]]
  run HABITS reminders-ensure --date 2026-07-02   # the 2nd → not due
  [[ "$output" == *"ENSURED 0"* ]]
}

# ── schedule-aware scoring (Slice 3) ────────────────────────────────────────
# Read a field off a single habit in the status JSON.
_status_field() {  # <date> <habit_id> <field>
  local js; js="$(pbrain_habits_status "$1")"
  python3 - "$js" "$2" "$3" <<'PYEOF'
import json, sys
js, hid, field = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.loads(js)
except Exception:
    d = {}
for h in d.get("habits") or []:
    if h.get("id") == hid:
        print(h.get(field)); break
PYEOF
}

@test "schedule-aware: an explicit weekdays habit reads 'off today' on a non-due day" {
  _write_profile
  HABITS add --name "Gym" --schedule weekdays --days mon,wed,fri --direction at_least
  run pbrain_habits_rollup 2026-06-02   # Tuesday → not a Mon/Wed/Fri day
  [[ "$output" == *"Gym"* ]]
  [[ "$output" == *"off today"* ]]
}

@test "schedule-aware: an explicit weekdays habit reads 'not yet today' on a due day" {
  _write_profile
  HABITS add --name "Gym" --schedule weekdays --days mon,wed,fri --direction at_least
  run pbrain_habits_rollup 2026-06-03   # Wednesday → due
  [[ "$output" == *"not yet today"* ]]
  [[ "$output" != *"off today"* ]]
}

@test "schedule-aware: due_today reflects the schedule" {
  _write_profile
  HABITS add --name "Gym" --schedule weekdays --days mon,wed,fri --direction at_least
  [ "$(_status_field 2026-06-03 gym due_today)" = "True" ]    # Wed
  [ "$(_status_field 2026-06-02 gym due_today)" = "False" ]   # Tue
}

@test "schedule-aware: streak survives an off day (counts only due days)" {
  _write_profile
  HABITS add --name "Gym" --schedule weekdays --days mon,wed,fri --direction at_least
  _log_event "Gym" 2026-06-01   # Mon ✓
  _log_event "Gym" 2026-06-03   # Wed ✓  (Tue 06-02 is an off day, must not break it)
  [ "$(_status_field 2026-06-03 gym streak)" = "2" ]
}

@test "schedule-aware: weekdays period progress counts only scheduled days" {
  _write_profile
  HABITS add --name "Gym" --schedule weekdays --days mon,wed,fri --direction at_least
  _log_event "Gym" 2026-06-01   # Mon of the week containing 06-03
  run pbrain_habits_rollup 2026-06-03
  [[ "$output" == *"1/3 this week"* ]]   # 1 of 3 scheduled (Mon/Wed/Fri) done
}

@test "schedule-aware: a legacy floating weekly habit stays count-based (no 'off today')" {
  _write_profile                 # nail-cut: weekly at_least target 2, NO explicit schedule
  _log_event "Nail cut" 2026-06-01
  run pbrain_habits_rollup 2026-06-03
  [[ "$output" == *"Nail cut"* ]]
  [[ "$output" != *"off today"* ]]   # floating → never "off"
  [[ "$output" == *"1/2 this week"* ]]
}

# ── scored habits (generic slip_ladder evaluator) ───────────────────────────
# A habit carries a structured `scoring` block; habits.sh computes the score
# deterministically from raw classification counts (the caller never picks it).
_write_scored_profile() {
  cat > "$PBRAIN_HABITS_PROFILE_FILE" <<'EOF'
---
type: habits-profile
---

# Habits profile

```json
{
  "habits": [
    { "id": "eat-clean", "name": "Eat clean", "schedule_type": "weekly", "direction": "at_least",
      "priority": "high", "archived": false, "unit": "", "measure_target": 6,
      "scoring": { "type": "slip_ladder", "good_target": 3, "ladder": [1.0, 0.6, 0.4, 0] } },
    { "id": "long-run", "name": "Long run", "schedule_type": "monthly", "direction": "at_least", "target_count": 5, "priority": "medium", "archived": false }
  ]
}
```
EOF
}

@test "score: good/bad map through the ladder per the profile rule" {
  _write_scored_profile
  run pbrain_habit_score "Eat clean" 3 0 ""   # 0 slips
  [ "$output" = "1" ]
  run pbrain_habit_score "Eat clean" 2 0 ""   # only 2 clean meals → 1 slip
  [ "$output" = "0.6" ]
  run pbrain_habit_score "Eat clean" 2 1 ""   # 2 clean, 1 junk → 1 slip
  [ "$output" = "0.6" ]
  run pbrain_habit_score "Eat clean" 1 2 ""   # 2 slips
  [ "$output" = "0.4" ]
  run pbrain_habit_score "Eat clean" 0 3 ""   # 3 slips → floor
  [ "$output" = "0" ]
}

@test "score: clean count and junk count combine via max(bad, target-good)" {
  _write_scored_profile
  run pbrain_habit_score "Eat clean" 3 1 ""   # 3 clean + 1 junk (4 meals) → 1 slip
  [ "$output" = "0.6" ]
  run pbrain_habit_score "Eat clean" 4 0 ""   # 4 clean, no junk → 0 slips
  [ "$output" = "1" ]
}

@test "score: --slips indexes the ladder directly" {
  _write_scored_profile
  run pbrain_habit_score "Eat clean" "" "" 2
  [ "$output" = "0.4" ]
  run pbrain_habit_score "Eat clean" "" "" 9   # clamps to last rung
  [ "$output" = "0" ]
}

@test "score: a non-scored habit yields blank (mechanism stays generic)" {
  _write_scored_profile
  run pbrain_habit_score "Long run" 3 0 ""
  [ -z "$output" ]
}

@test "mark --good/--bad writes the computed score as the amount (md + DB)" {
  _write_scored_profile
  pbrain_habit_mark "2026-06-07" "Eat clean" "1" "all 3 meals out" "" 0 3 ""
  # md Count cell holds the computed amount
  body="$(cat "$PBRAIN_HABIT_TRACK_DIR/2026-06-07.md")"
  [[ "$body" == *"Eat clean"* ]]
  # DB amount reflects the formula, not a hand-picked number
  run sqlite3 "$PBRAIN_DB_FILE" "select amount from habit_events where habit_id='eat-clean' and occurred_on='2026-06-07'"
  [ "$output" = "0.0" ]

  pbrain_habit_mark "2026-06-06" "Eat clean" "1" "2 clean home meals" "" 2 0 ""
  run sqlite3 "$PBRAIN_DB_FILE" "select amount from habit_events where habit_id='eat-clean' and occurred_on='2026-06-06'"
  [ "$output" = "0.6" ]
}

@test "mark: --amount still works when no classification counts are passed" {
  _write_scored_profile
  pbrain_habit_mark "2026-06-05" "Eat clean" "1" "manual override" "0.4"
  run sqlite3 "$PBRAIN_DB_FILE" "select amount from habit_events where habit_id='eat-clean' and occurred_on='2026-06-05'"
  [ "$output" = "0.4" ]
}

@test "mark subcommand parses --good/--bad and emits a [scored] extraction tag" {
  _write_scored_profile
  export PBRAIN_PREFS_DIR="$TMP/prefs"   # isolate from the real user prefs
  run bash "$REPO_ROOT/commands/habits.sh" mark --name "Eat clean" --date 2026-06-07 --good 3 --bad 0
  [ "$status" -eq 0 ]
  run sqlite3 "$PBRAIN_DB_FILE" "select amount from habit_events where habit_id='eat-clean' and occurred_on='2026-06-07'"
  [ "$output" = "1.0" ]
}

# ── reminders-reschedule ─────────────────────────────────────────────────────

@test "reminders-reschedule: missing --habit prints ERROR:--habit required" {
  _write_profile
  run HABITS reminders-reschedule --time 08:00 --date 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR:--habit required"* ]]
}

@test "reminders-reschedule: missing --time prints ERROR:--time required" {
  _write_profile
  run HABITS reminders-reschedule --habit "Brush at night" --date 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR:--time required"* ]]
}

@test "reminders-reschedule: unknown habit name prints NOT_LINKED" {
  _write_profile
  run HABITS reminders-reschedule --habit "No Such Habit" --time 08:00 --date 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT_LINKED"* ]]
}

@test "reminders-reschedule: habit exists but is not linked prints NOT_LINKED" {
  _write_profile
  # brush-at-night exists in the profile with no reminder link
  run HABITS reminders-reschedule --habit "Brush at night" --time 08:00 --date 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT_LINKED"* ]]
}

@test "reminders-reschedule: linked habit with no pending DB row prints NOT_FOUND" {
  _write_profile
  HABITS reminder --id brush-at-night --link --time 07:00
  # No row seeded in habit_reminders for this date
  run HABITS reminders-reschedule --habit "Brush at night" --time 08:00 --date 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT_FOUND"* ]]
}

@test "reminders-reschedule: linked habit with pending row attempts edit (UNAVAILABLE in CI)" {
  _write_profile
  HABITS reminder --id brush-at-night --link --time 07:00
  _hr_seed_pending brush-at-night 2026-06-03 R-RESCHED-TEST
  run HABITS reminders-reschedule --habit "Brush at night" --time 08:00 --date 2026-06-03
  [ "$status" -eq 0 ]
  # Apple Reminders is stubbed to UNAVAILABLE in test setup; any non-EDITED response is acceptable
  [[ "$output" != "NOT_LINKED" && "$output" != "NOT_FOUND" ]]
}

# ── new scoring types: meal_ratio + deviation ───────────────────────────────

_write_v2_scored_profile() {
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
    { "id": "eat-clean",  "name": "Eat clean",  "schedule_type": "daily", "direction": "at_least", "target_count": null, "priority": "high", "archived": false,
      "unit": "", "measure_target": 80, "scoring": { "type": "meal_ratio" } },
    { "id": "sleep-well", "name": "Sleep well", "schedule_type": "daily", "direction": "at_least", "target_count": null, "priority": "high", "archived": false,
      "unit": "", "measure_target": 80,
      "scoring": { "type": "deviation", "normal_time": "23:00", "normal_hours": 8.0,
                   "unit_minutes": 30, "unit_hours": 0.5, "ladder": [100, 90, 75, 50, 25, 0] } }
  ]
}
```
EOF
}

@test "score meal_ratio: 5 clean 1 unclean -> 83" {
  _write_v2_scored_profile
  run HABITS score --name "Eat clean" --good 5 --bad 1
  [ "$status" -eq 0 ]
  [ "$output" = "83" ]
}

@test "score meal_ratio: 2 clean 1 unclean -> 67 (fewer meals weigh slips more)" {
  _write_v2_scored_profile
  run HABITS score --name "Eat clean" --good 2 --bad 1
  [ "$output" = "67" ]
}

@test "score meal_ratio: zero meals -> blank (caller falls back)" {
  _write_v2_scored_profile
  run HABITS score --name "Eat clean" --good 0 --bad 0
  [ -z "$output" ]
}

@test "score deviation: exactly normal -> 100" {
  _write_v2_scored_profile
  run HABITS score --name "Sleep well" --actual-time 23:00 --actual-hours 8
  [ "$output" = "100" ]
}

@test "score deviation: 1h late + 1h short -> 4 slips -> 25" {
  _write_v2_scored_profile
  run HABITS score --name "Sleep well" --actual-time 00:00 --actual-hours 7
  [ "$output" = "25" ]
}

@test "score deviation: midnight crossing is circular (00:30 vs 23:00 = 90min)" {
  _write_v2_scored_profile
  # 90 min late -> 3 slips; hours on target -> ladder[3] = 50
  run HABITS score --name "Sleep well" --actual-time 00:30 --actual-hours 8
  [ "$output" = "50" ]
}

@test "mark with --actual-time/--actual-hours writes the deviation score as amount" {
  _write_v2_scored_profile
  run HABITS mark --name "Sleep well" --date 2026-06-03 --actual-time 00:00 --actual-hours 7
  [ "$status" -eq 0 ]
  amt="$(python3 -c "
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
row = con.execute(\"SELECT amount FROM habit_events WHERE habit_id='sleep-well' AND occurred_on='2026-06-03'\").fetchone()
print(row[0] if row else 'none')
" "$PBRAIN_DB_FILE")"
  [ "$amt" = "25.0" ]
}

# ── default-habit seeding (eat-clean + sleep-well) ──────────────────────────

_plant_source_profiles() {
  mkdir -p "$PBRAIN_VAULT/fitness/diet-tracking/.profile" \
           "$PBRAIN_VAULT/fitness/daily-tracking/.profile"
  cat > "$PBRAIN_VAULT/fitness/diet-tracking/.profile/diet-profile.v1.md" <<'EOF'
---
type: diet-profile
version: 1
committed: true
---
# Diet profile
```json
{"created": "2026-06-03", "meal_slots": ["Breakfast", "Lunch", "Dinner"]}
```
EOF
  cat > "$PBRAIN_VAULT/fitness/daily-tracking/.profile/fitness-profile.v1.md" <<'EOF'
---
type: fitness-profile
version: 1
committed: true
---
# Fitness profile
```json
{"created": "2026-06-03",
 "sleep": {"bed_time": "23:15", "wake_time": "07:15", "hours": 8.0},
 "steps_per_day": 8000}
```
EOF
}

@test "dashboard seeds eat-clean + sleep-well when diet + fitness profiles exist" {
  _write_profile
  _plant_source_profiles
  run HABITS
  [ "$status" -eq 0 ]
  [[ "$output" == *"Added default habit: Eat clean"* ]]
  [[ "$output" == *"Added default habit: Sleep well"* ]]
  grep -q '"id": "eat-clean"' "$PBRAIN_HABITS_PROFILE_FILE"
  grep -q '"id": "sleep-well"' "$PBRAIN_HABITS_PROFILE_FILE"
  # sleep-well bakes the normal window from the fitness profile
  grep -q '"normal_time": "23:15"' "$PBRAIN_HABITS_PROFILE_FILE"
}

@test "seeding is idempotent on re-run" {
  _write_profile
  _plant_source_profiles
  HABITS >/dev/null
  run HABITS
  [[ "$output" != *"Added default habit"* ]]
  [ "$(grep -c '"id": "eat-clean"' "$PBRAIN_HABITS_PROFILE_FILE")" -eq 1 ]
}

@test "an archived default habit is never resurrected" {
  _write_profile
  _plant_source_profiles
  HABITS >/dev/null
  HABITS archive --id eat-clean >/dev/null
  run HABITS
  [[ "$output" != *"Added default habit: Eat clean"* ]]
}

@test "no seeding without the source profiles" {
  _write_profile
  run HABITS
  [[ "$output" != *"Added default habit"* ]]
}

@test "extraction emitter explains meal_ratio and deviation marking" {
  _write_v2_scored_profile
  run bash -c "source '$REPO_ROOT/lib/profile.sh'; source '$REPO_ROOT/lib/db.sh'; source '$REPO_ROOT/lib/habits.sh'; pbrain_emit_habits_extract test-cmd"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--actual-time HH:MM"* ]]
  [[ "$output" == *"clean vs unclean MEALS"* ]]
}

# ── bootstrap + profile subcommand (versioned store) ────────────────────────

@test "add bootstrap without override lands in the versioned store, committed" {
  unset PBRAIN_HABITS_PROFILE_FILE
  run HABITS add --name "Meditate" --type daily
  [ "$status" -eq 0 ]
  local store_file="$PBRAIN_HABIT_TRACK_DIR/.profile/habits-profile.v1.md"
  [ -f "$store_file" ]
  grep -q '^version: 1$' "$store_file"
  grep -q '^committed: true$' "$store_file"
  grep -q '"id": "meditate"' "$store_file"
}

@test "profile subcommand: new mints a draft, commit freezes it" {
  unset PBRAIN_HABITS_PROFILE_FILE
  HABITS add --name "Meditate" --type daily >/dev/null
  run HABITS profile new
  [ "$status" -eq 0 ]
  [[ "$output" == *"HABITS_PROFILE_NEW"* ]]
  [ -f "$PBRAIN_HABIT_TRACK_DIR/.profile/habits-profile.v2.md" ]
  run HABITS profile commit
  [[ "$output" == *"HABITS_PROFILE_COMMITTED"* ]]
  grep -q '^committed: true$' "$PBRAIN_HABIT_TRACK_DIR/.profile/habits-profile.v2.md"
}

@test "profile show reports committed/draft/active paths" {
  unset PBRAIN_HABITS_PROFILE_FILE
  HABITS add --name "Meditate" --type daily >/dev/null
  run HABITS profile show
  [[ "$output" == *"HABITS_PROFILE_SHOW"* ]]
  [[ "$output" == *"habits-profile.v1.md"* ]]
  [[ "$output" == *'"id": "meditate"'* ]]
}

# ── new scoring types: weighted_completion + session_volume ──────────────────

_write_wc_profile() {
  cat > "$PBRAIN_HABITS_PROFILE_FILE" <<'PEOF'
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
    { "id": "work-the-plan", "name": "Work the plan", "schedule_type": "daily",
      "direction": "at_least", "target_count": null, "priority": "high",
      "archived": false, "unit": "", "measure_target": 70,
      "scoring": { "type": "weighted_completion",
        "difficulty_weights": {"easy":1,"normal":2,"hard":3,"nightmare":5},
        "status_credit": {"done":1.0,"partial":0.5,"dropped":0.0,"carried":0.0},
        "priority_pivot": 3, "priority_step": 0.25 } },
    { "id": "train", "name": "Train", "schedule_type": "daily",
      "direction": "at_least", "target_count": null, "priority": "high",
      "archived": false, "unit": "", "measure_target": 80,
      "scoring": { "type": "session_volume",
        "status_credit": {"completed":1.0,"partial":0.5,"skipped":0.0},
        "volume_cap": 1.0 } }
  ]
}
```
PEOF
}

@test "score weighted_completion: all done tasks -> 100" {
  _write_wc_profile
  run HABITS score --name "Work the plan" \
    --items '[{"priority":1,"difficulty":"hard","status":"done"},{"priority":2,"difficulty":"normal","status":"done"}]'
  [ "$status" -eq 0 ]
  [ "$output" = "100" ]
}

@test "score weighted_completion: all dropped -> 0" {
  _write_wc_profile
  run HABITS score --name "Work the plan" \
    --items '[{"priority":1,"difficulty":"hard","status":"dropped"}]'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "score weighted_completion: empty items list -> blank" {
  _write_wc_profile
  run HABITS score --name "Work the plan" --items '[]'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "score weighted_completion: nightmare p1 done + easy p3 dropped -> 88" {
  # nightmare(5) * (1+(3-1)*0.25)=1.5 -> 7.5 earned; easy(1)*1.0=1.0 dropped -> 0
  # score = round_half_up(100 * 7.5 / 8.5) = round(88.235) = 88
  _write_wc_profile
  run HABITS score --name "Work the plan" \
    --items '[{"priority":1,"difficulty":"nightmare","status":"done"},{"priority":3,"difficulty":"easy","status":"dropped"}]'
  [ "$status" -eq 0 ]
  [ "$output" = "88" ]
}

@test "score weighted_completion: partial task counts half credit -> 50" {
  # normal(2) * p3_boost(1.0) = 2.0 possible; partial credit 0.5 -> earned 1.0; score = 50
  _write_wc_profile
  run HABITS score --name "Work the plan" \
    --items '[{"priority":3,"difficulty":"normal","status":"partial"}]'
  [ "$status" -eq 0 ]
  [ "$output" = "50" ]
}

@test "score weighted_completion: half-up rounding -> 67" {
  # normal(2)*1.0=2 done + easy(1)*1.0=1 dropped: earned=2, possible=3 -> 66.67 -> rounds to 67
  _write_wc_profile
  run HABITS score --name "Work the plan" \
    --items '[{"priority":3,"difficulty":"normal","status":"done"},{"priority":3,"difficulty":"easy","status":"dropped"}]'
  [ "$status" -eq 0 ]
  [ "$output" = "67" ]
}

@test "score session_volume: skipped -> 0" {
  _write_wc_profile
  run HABITS score --name "Train" \
    --session '{"mode":"strength","status":"skipped","planned":100,"actual":0}'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "score session_volume: completed binary -> 100" {
  _write_wc_profile
  run HABITS score --name "Train" \
    --session '{"mode":"binary","status":"completed"}'
  [ "$status" -eq 0 ]
  [ "$output" = "100" ]
}

@test "score session_volume: partial binary -> 50" {
  _write_wc_profile
  run HABITS score --name "Train" \
    --session '{"mode":"binary","status":"partial"}'
  [ "$status" -eq 0 ]
  [ "$output" = "50" ]
}

@test "score session_volume: 90 pct of planned strength volume -> 90" {
  _write_wc_profile
  run HABITS score --name "Train" \
    --session '{"mode":"strength","status":"completed","planned":100,"actual":90}'
  [ "$status" -eq 0 ]
  [ "$output" = "90" ]
}

@test "score session_volume: actual over planned is capped at 100" {
  _write_wc_profile
  run HABITS score --name "Train" \
    --session '{"mode":"strength","status":"completed","planned":100,"actual":150}'
  [ "$status" -eq 0 ]
  [ "$output" = "100" ]
}

@test "score session_volume: duration mode ratio -> 75" {
  # duration is the second volume mode (alongside strength): 45/60 -> 75.
  _write_wc_profile
  run HABITS score --name "Train" \
    --session '{"mode":"duration","status":"completed","planned":60,"actual":45}'
  [ "$status" -eq 0 ]
  [ "$output" = "75" ]
}

@test "score session_volume: strength with no planned falls through to binary credit -> 100" {
  # planned missing -> the volume-ratio guard fails -> binary status credit.
  _write_wc_profile
  run HABITS score --name "Train" \
    --session '{"mode":"strength","status":"completed"}'
  [ "$status" -eq 0 ]
  [ "$output" = "100" ]
}

@test "score session_volume: skipped wins before the mode branch (binary, no volume) -> 0" {
  _write_wc_profile
  run HABITS score --name "Train" \
    --session '{"mode":"binary","status":"skipped"}'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "score weighted_completion: a non-dict item is skipped, not counted" {
  _write_wc_profile
  run HABITS score --name "Work the plan" \
    --items '[{"priority":1,"difficulty":"hard","status":"done"}, "junk"]'
  [ "$status" -eq 0 ]
  [ "$output" = "100" ]
}

@test "score weighted_completion: unknown difficulty + status fall back to default weight / 0 credit" {
  # difficulty 'weird' -> default weight 2; status 'mystery' -> 0 credit: 0/2 -> 0.
  _write_wc_profile
  run HABITS score --name "Work the plan" \
    --items '[{"priority":3,"difficulty":"weird","status":"mystery"}]'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "mark with --items writes the weighted_completion score as amount" {
  _write_wc_profile
  run HABITS mark --name "Work the plan" --date 2026-06-03 \
    --items '[{"priority":1,"difficulty":"hard","status":"done"}]'
  [ "$status" -eq 0 ]
  amt="$(python3 -c "
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
row = con.execute(\"SELECT amount FROM habit_events WHERE habit_id='work-the-plan' AND occurred_on='2026-06-03'\").fetchone()
print(row[0] if row else 'none')
" "$PBRAIN_DB_FILE")"
  [ "$amt" = "100.0" ]
}

@test "mark with --session writes the session_volume score as amount" {
  _write_wc_profile
  run HABITS mark --name "Train" --date 2026-06-03 \
    --session '{"mode":"strength","status":"completed","planned":100,"actual":80}'
  [ "$status" -eq 0 ]
  amt="$(python3 -c "
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
row = con.execute(\"SELECT amount FROM habit_events WHERE habit_id='train' AND occurred_on='2026-06-03'\").fetchone()
print(row[0] if row else 'none')
" "$PBRAIN_DB_FILE")"
  [ "$amt" = "80.0" ]
}

# ── default-habit seeding: work-the-plan + train ─────────────────────────────

_plant_goals_profile() {
  mkdir -p "$PBRAIN_VAULT/life/daily-planning/.profile"
  cat > "$PBRAIN_VAULT/life/daily-planning/.profile/plans-profile.v1.md" <<'EOF'
---
type: plans-profile
version: 1
committed: true
---
# Plans profile
```json
{"created": "2026-06-03",
 "working_style": {"session_length_min": 90, "break_min": 30, "break_activities": [], "work_hours_per_day": 7},
 "current_focus": [{"id": "ship", "lib": "work", "name": "Ship pbrain", "track": "professional",
                    "horizon": "short", "priority": 1, "deadline": "ongoing",
                    "success_looks_like": "shipped", "context": "pbrain tooling", "status": "active"}]}
```
EOF
}

_plant_fitness_library() {
  mkdir -p "$PBRAIN_VAULT/fitness/daily-tracking/.profile"
  cat > "$PBRAIN_VAULT/fitness/daily-tracking/.profile/fitness-library.v1.md" <<'EOF'
---
type: fitness-library
version: 1
committed: true
---
# Fitness library
```json
{"created": "2026-06-03", "activities": [{"id": "gym", "name": "Gym", "occurrence": "4x/week"}]}
```
EOF
}

@test "dashboard seeds work-the-plan when goals-profile exists" {
  _write_profile
  _plant_goals_profile
  run HABITS
  [ "$status" -eq 0 ]
  [[ "$output" == *"Added default habit: Work the plan"* ]]
  grep -q '"id": "work-the-plan"' "$PBRAIN_HABITS_PROFILE_FILE"
  grep -q '"type": "weighted_completion"' "$PBRAIN_HABITS_PROFILE_FILE"
}

@test "dashboard seeds train when fitness-library exists" {
  _write_profile
  _plant_fitness_library
  run HABITS
  [ "$status" -eq 0 ]
  [[ "$output" == *"Added default habit: Train"* ]]
  grep -q '"id": "train"' "$PBRAIN_HABITS_PROFILE_FILE"
  grep -q '"type": "session_volume"' "$PBRAIN_HABITS_PROFILE_FILE"
}

@test "train seeds with weekdays schedule from activity profile days" {
  # Per-activity profiles store fixed days in FRONTMATTER as weekday NAMES
  # (the format fitness-journal actually writes) — NOT as a JSON block.
  _write_profile
  _plant_fitness_library
  mkdir -p "$PBRAIN_VAULT/fitness/daily-tracking/.profile/activities"
  cat > "$PBRAIN_VAULT/fitness/daily-tracking/.profile/activities/gym.v1.md" <<'EOF'
---
type: activity-profile
activity: Gym
days: [Mon, Wed, Fri]
version: 1
committed: true
---
# Gym
EOF
  run HABITS
  [ "$status" -eq 0 ]
  python3 -c "
import json, re
with open('$PBRAIN_HABITS_PROFILE_FILE') as f: t = f.read()
m = re.search(r'\x60\x60\x60json\s*\n(.*?)\x60\x60\x60', t, re.DOTALL)
data = json.loads(m.group(1))
train = next((h for h in data['habits'] if h['id'] == 'train'), None)
assert train is not None
sched = train.get('schedule', {})
# Stored schedules key on 'type' (same as the add path / build_schedule),
# NOT 'kind' — otherwise derive_schedule/is_due ignore it and the habit
# collapses to a legacy floating schedule.
assert sched.get('type') == 'weekdays', repr(sched)
assert sched.get('days') == ['mon', 'wed', 'fri'], repr(sched)
"
}

@test "seeded train is genuinely schedule-aware (is_due honors its weekdays)" {
  # Regression: the seeded schedule must be readable by the schedule engine,
  # i.e. is_due must treat it as weekdays — due on Mon, off on Tue.
  _write_profile
  _plant_fitness_library
  mkdir -p "$PBRAIN_VAULT/fitness/daily-tracking/.profile/activities"
  printf -- '---\nactivity: Gym\ndays: [Mon, Wed, Fri]\nversion: 1\ncommitted: true\n---\n# Gym\n' \
    > "$PBRAIN_VAULT/fitness/daily-tracking/.profile/activities/gym.v1.md"
  run HABITS
  [ "$status" -eq 0 ]
  python3 -c "
import json, re, sys
sys.path.insert(0, '$REPO_ROOT/lib')
from habit_schedule import is_due
with open('$PBRAIN_HABITS_PROFILE_FILE') as f: t = f.read()
m = re.search(r'\x60\x60\x60json\s*\n(.*?)\x60\x60\x60', t, re.DOTALL)
train = next(h for h in json.loads(m.group(1))['habits'] if h['id'] == 'train')
sched = train['schedule']
assert is_due(sched, '2026-06-08') is True, 'Mon 2026-06-08 should be due'   # Monday
assert is_due(sched, '2026-06-09') is False, 'Tue 2026-06-09 should be off'  # Tuesday
"
}

@test "train unions the fixed days across activities (highest committed version per slug)" {
  _write_profile
  _plant_fitness_library
  mkdir -p "$PBRAIN_VAULT/fitness/daily-tracking/.profile/activities"
  # gym v1 Mon/Thu, superseded by a committed v2 Tue/Fri — only v2's days count.
  printf -- '---\nactivity: Gym\ndays: [Mon, Thu]\nversion: 1\ncommitted: true\n---\n# Gym v1\n' \
    > "$PBRAIN_VAULT/fitness/daily-tracking/.profile/activities/gym.v1.md"
  printf -- '---\nactivity: Gym\ndays: [Tue, Fri]\nversion: 2\ncommitted: true\n---\n# Gym v2\n' \
    > "$PBRAIN_VAULT/fitness/daily-tracking/.profile/activities/gym.v2.md"
  # a separate activity adds Sunday; an open draft must NOT contribute.
  printf -- '---\nactivity: Yoga\ndays: [Sun]\nversion: 1\ncommitted: true\n---\n# Yoga\n' \
    > "$PBRAIN_VAULT/fitness/daily-tracking/.profile/activities/yoga.v1.md"
  printf -- '---\nactivity: Run\ndays: [Sat]\nversion: 1\ncommitted: false\n---\n# Run draft\n' \
    > "$PBRAIN_VAULT/fitness/daily-tracking/.profile/activities/run.v1.md"
  run HABITS
  [ "$status" -eq 0 ]
  python3 -c "
import json, re
with open('$PBRAIN_HABITS_PROFILE_FILE') as f: t = f.read()
m = re.search(r'\x60\x60\x60json\s*\n(.*?)\x60\x60\x60', t, re.DOTALL)
data = json.loads(m.group(1))
train = next((h for h in data['habits'] if h['id'] == 'train'), None)
sched = train.get('schedule', {})
# gym v2 (tue,fri) + yoga (sun); gym v1 superseded; run draft excluded.
assert sched.get('type') == 'weekdays', repr(sched)
assert sched.get('days') == ['tue', 'fri', 'sun'], repr(sched)
"
}

@test "train seeds with daily schedule when no activity profiles exist" {
  _write_profile
  _plant_fitness_library
  run HABITS
  [ "$status" -eq 0 ]
  [[ "$output" == *"Added default habit: Train"* ]]
  python3 -c "
import json, re
with open('$PBRAIN_HABITS_PROFILE_FILE') as f: t = f.read()
m = re.search(r'\x60\x60\x60json\s*\n(.*?)\x60\x60\x60', t, re.DOTALL)
data = json.loads(m.group(1))
train = next((h for h in data['habits'] if h['id'] == 'train'), None)
assert train is not None
assert train.get('schedule', {}).get('type') == 'daily', repr(train.get('schedule'))
"
}

@test "work-the-plan and train seeding is idempotent" {
  _write_profile
  _plant_goals_profile
  _plant_fitness_library
  HABITS >/dev/null
  run HABITS
  [[ "$output" != *"Added default habit: Work the plan"* ]]
  [[ "$output" != *"Added default habit: Train"* ]]
  [ "$(grep -c '"id": "work-the-plan"' "$PBRAIN_HABITS_PROFILE_FILE")" -eq 1 ]
  [ "$(grep -c '"id": "train"' "$PBRAIN_HABITS_PROFILE_FILE")" -eq 1 ]
}
