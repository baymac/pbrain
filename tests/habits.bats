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

# Profile with an eod_only scored habit alongside a normal one — for the
# end-of-day gating tests.
_write_eod_profile() {
  cat > "$PBRAIN_HABITS_PROFILE_FILE" <<'EOF'
---
type: habits-profile
---

# Habits profile

```json
{
  "habits": [
    { "id": "brush-at-night", "name": "Brush at night", "schedule_type": "daily", "direction": "at_least", "target_count": 1, "priority": "high" },
    { "id": "eat-clean", "name": "Eat clean", "schedule_type": "daily", "direction": "at_least", "priority": "high", "eod_only": true, "scoring": { "type": "slip_ladder", "good_target": 3, "ladder": [1.0, 0.6, 0.3, 0] }, "notes": "TEST-EOD-SCORED-NOTE" }
  ]
}
```
EOF
}

# PB-50: a SCORED habit with NO explicit eod_only flag — should still be deferred
# to /end-of-day mid-day (it needs whole-day evidence to score).
_write_scored_no_flag_profile() {
  cat > "$PBRAIN_HABITS_PROFILE_FILE" <<'EOF'
---
type: habits-profile
---

# Habits profile

```json
{
  "habits": [
    { "id": "brush-at-night", "name": "Brush at night", "schedule_type": "daily", "direction": "at_least", "target_count": 1, "priority": "high" },
    { "id": "sleep-well", "name": "TEST-SCORED-NOFLAG", "schedule_type": "daily", "direction": "at_least", "priority": "high", "scoring": { "type": "deviation", "window": "23:00-07:00" } }
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

# ── categories / parts (PB-27) ───────────────────────────────────────────────
@test "add stores a normalized part (slugified from free text)" {
  run HABITS add --name "Brush" --type daily --direction at_least --category "fitness activity"
  echo "$output" | grep -q "fitness-activity" \
    && pbrain_habits_json | python3 -c '
import json, sys
h = next(x for x in json.load(sys.stdin)["habits"] if x["id"] == "brush")
assert h.get("category") == "fitness-activity", h
'
}

@test "add accepts a custom part verbatim (slugified)" {
  HABITS add --name "Pray" --type daily --direction at_least --part "Spirituality"
  pbrain_habits_json | python3 -c '
import json, sys
h = next(x for x in json.load(sys.stdin)["habits"] if x["id"] == "pray")
assert h.get("category") == "spirituality", h
'
}

@test "edit sets a part by id" {
  _write_profile
  HABITS edit --id nail-cut --category looks
  pbrain_habits_json | python3 -c '
import json, sys
h = next(x for x in json.load(sys.stdin)["habits"] if x["id"] == "nail-cut")
assert h.get("category") == "looks", h
'
}

@test "edit --category \"\" clears the part" {
  _write_profile
  HABITS edit --id nail-cut --category looks
  HABITS edit --id nail-cut --category ""
  pbrain_habits_json | python3 -c '
import json, sys
h = next(x for x in json.load(sys.stdin)["habits"] if x["id"] == "nail-cut")
assert "category" not in h, h
'
}

@test "status carries category + label + sort order" {
  _write_profile
  HABITS edit --id brush-at-night --category cleanliness
  run pbrain_habits_status 2026-06-03
  echo "$output" | python3 -c '
import json, sys
h = next(x for x in json.load(sys.stdin)["habits"] if x["id"] == "brush-at-night")
assert h["category"] == "cleanliness" and h["category_label"] == "Cleanliness", h
assert isinstance(h["category_order"], int) and h["category_order"] < 1000, h
'
}

@test "rollup groups under part headers in canonical order, uncategorized last" {
  _write_profile
  HABITS edit --id brush-at-night --category cleanliness
  HABITS edit --id long-run --category fitness-activity
  # nail-cut + alcohol stay uncategorized
  run pbrain_habits_rollup 2026-06-03
  echo "$output" | python3 -c '
import sys
t = sys.stdin.read()
for label in ("**Fitness activity**", "**Cleanliness**", "**Uncategorized**"):
    assert label in t, (label, t)
# canonical order: fitness-activity (1) before cleanliness (4); uncategorized last
assert t.index("**Fitness activity**") < t.index("**Cleanliness**") < t.index("**Uncategorized**"), t
'
}

@test "rollup stays a flat list when no habit has a part" {
  _write_profile
  run pbrain_habits_rollup 2026-06-03
  [[ "$output" != *"**"* ]]
}

@test "migration 0008 is applicable while an active habit has no part" {
  _write_profile
  source "$REPO_ROOT/lib/migrations/0008_habits_categorize.sh"
  run migration_applicable
  [ "$status" -eq 0 ]
}

@test "migration 0008 stops being applicable once every active habit is parted" {
  _write_profile
  HABITS edit --id brush-at-night --category cleanliness
  HABITS edit --id nail-cut --category looks
  HABITS edit --id long-run --category fitness-activity
  HABITS edit --id alcohol --category bad-habits
  source "$REPO_ROOT/lib/migrations/0008_habits_categorize.sh"
  run migration_applicable
  [ "$status" -ne 0 ]
}

@test "track splits the daily file into one table per part, canonical order" {
  _write_profile
  HABITS edit --id brush-at-night --category cleanliness
  HABITS edit --id long-run --category fitness-activity
  HABITS track --date 2026-06-03
  cat "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md" | python3 -c '
import sys
t = sys.stdin.read()
# a section heading per part, plain 6-column tables under each
assert "## Fitness activity" in t and "## Cleanliness" in t and "## Other" in t, t
assert "| Habit | Criteria | Progress | Done | Count | Note |" in t, t
# fitness-activity (order 1) section before cleanliness (order 4); uncategorized (Other) last
assert t.index("## Fitness activity") < t.index("## Cleanliness") < t.index("## Other"), t
# each habit lands under its section
assert t.index("## Fitness activity") < t.index("| Long run |") < t.index("## Cleanliness"), t
assert t.index("## Cleanliness") < t.index("| Brush at night |") < t.index("## Other"), t
'
}

@test "sync tolerates an old 6-column tracking file (no Part column)" {
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
| Brush at night | daily | 0/7 wk | x |  |  |
EOF
  HABITS sync --days 0 --date 2026-06-03
  [ "$(_ev brush-at-night 2026-06-03)" = "1|done" ]
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

@test "emit_habits_extract holds eod_only habits back from mid-day commands" {
  _write_eod_profile
  run pbrain_emit_habits_extract journal
  [ "$status" -eq 0 ]
  # Eat clean appears ONLY in the deferral note (not the tracked list / scored
  # rules), the normal habit is tracked, and the scored note is suppressed.
  [[ "$output" == *"Brush at night"* && "$output" == *"END-OF-DAY ONLY"* && "$output" == *"Eat clean"* && "$output" != *"TEST-EOD-SCORED-NOTE"* ]]
}

@test "emit_habits_extract includes eod_only habits at end-of-day with no deferral" {
  _write_eod_profile
  run pbrain_emit_habits_extract end-of-day
  [ "$status" -eq 0 ]
  [[ "$output" == *"TEST-EOD-SCORED-NOTE"* && "$output" != *"END-OF-DAY ONLY — do NOT mark"* ]]
}

@test "PB-50: scored habits without eod_only are still deferred mid-day" {
  _write_scored_no_flag_profile
  run pbrain_emit_habits_extract plan-my-day
  [ "$status" -eq 0 ]
  # The scored habit appears ONLY in the deferral note; the plain habit is tracked.
  [[ "$output" == *"Brush at night"* ]]
  defer_line="$(printf '%s\n' "$output" | grep 'END-OF-DAY ONLY')"
  [[ "$defer_line" == *"TEST-SCORED-NOFLAG"* ]]
}

@test "PB-50: scored habits without eod_only are markable at end-of-day" {
  _write_scored_no_flag_profile
  run pbrain_emit_habits_extract end-of-day
  [ "$status" -eq 0 ]
  [[ "$output" == *"TEST-SCORED-NOFLAG"* && "$output" != *"END-OF-DAY ONLY — do NOT mark"* ]]
}

@test "emit_habits_extract forbids marking from planned/anticipated activity" {
  _write_profile
  run pbrain_emit_habits_extract fitness-journal
  [ "$status" -eq 0 ]
  [[ "$output" == *"planned is not done"* && "$output" == *"status: planned is NOT a completed workout"* ]]
}

@test "reminders-sync keeps a not-yet-fired one-shot pending even when the habit is marked" {
  cat > "$PBRAIN_HABITS_PROFILE_FILE" <<'EOF'
---
type: habits-profile
---

# Habits profile

```json
{
  "habits": [
    { "id": "future-habit", "name": "Future habit", "schedule_type": "daily", "direction": "at_least", "target_count": 1, "priority": "high", "reminder": { "state": "linked", "time": "23:59" } },
    { "id": "past-habit", "name": "Past habit", "schedule_type": "daily", "direction": "at_least", "target_count": 1, "priority": "high", "reminder": { "state": "linked", "time": "00:01" } }
  ]
}
```
EOF
  local today; today="$(date +%Y-%m-%d)"
  HABITS mark --name "Future habit" --date "$today" >/dev/null
  HABITS mark --name "Past habit"   --date "$today" >/dev/null
  python3 - "$PBRAIN_DB_FILE" "$today" <<'PY'
import sqlite3, sys
db, today = sys.argv[1:3]
c = sqlite3.connect(db)
for hid, rid in (("future-habit", "RID-F"), ("past-habit", "RID-P")):
    c.execute("insert into habit_reminders(habit_id,occurred_on,reminder_id,status,created_at) "
              "values(?,?,?,'pending','t')", (hid, today, rid))
c.commit()
PY
  HABITS reminders-sync --date "$today" >/dev/null
  # Future one-shot stays pending (nudge not fired yet); past one is completed.
  run python3 - "$PBRAIN_DB_FILE" "$today" <<'PY'
import sqlite3, sys
db, today = sys.argv[1:3]
c = sqlite3.connect(db)
f = c.execute("select status from habit_reminders where habit_id='future-habit' and occurred_on=?", (today,)).fetchone()[0]
p = c.execute("select status from habit_reminders where habit_id='past-habit'   and occurred_on=?", (today,)).fetchone()[0]
print(f"{f}|{p}")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == "pending|done" ]]
}

@test "emit_habits_scan is silent without a profile" {
  run pbrain_emit_habits_scan plan-my-day
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emit_habits_scan emits the scan + reminder-alignment + the reused extraction block" {
  _write_profile
  run pbrain_emit_habits_scan plan-my-day
  [ "$status" -eq 0 ]
  [[ "$output" == *"HABIT SCAN (plan-my-day)"* ]]
  [[ "$output" == *"EVIDENCE SCAN"* ]]
  [[ "$output" == *"reminders-reschedule --habit"* ]]
  [[ "$output" == *"reminders-cancel --habit"* ]]
  # it reuses the full extraction block (mark syntax) rather than duplicating it
  [[ "$output" == *"HABIT EXTRACTION (plan-my-day)"* && "$output" == *"Brush at night"* ]]
}

@test "PB-75: emit_habits_scan tells the model not to narrate the mechanism" {
  _write_profile
  run pbrain_emit_habits_scan plan-my-day
  [ "$status" -eq 0 ]
  # The scan block must explicitly forbid narrating the scan/realign/sync plumbing
  # and echoing the deterministic command output back to the user.
  [[ "$output" == *"do NOT"* && "$output" == *"NARRATE"* ]]
  [[ "$output" == *"REALIGNED <n> SKIPPED <n>"* ]]
  [[ "$output" == *"quiet bookkeeping"* ]]
}

@test "emit_habits_scan lists today's existing vault entries to scan" {
  _write_profile
  local today; today="$(date +%Y-%m-%d)"
  mkdir -p "$PBRAIN_VAULT/life/daily-tracking" "$PBRAIN_VAULT/fitness/diet-tracking"
  echo "# journal" > "$PBRAIN_VAULT/life/daily-tracking/$today.md"
  echo "# diet"    > "$PBRAIN_VAULT/fitness/diet-tracking/$today.md"
  run pbrain_emit_habits_scan plan-my-day
  [ "$status" -eq 0 ]
  # only the files that exist are listed; a missing one (gratitude) is not
  [[ "$output" == *"journal → "* && "$output" == *"diet → "* && "$output" != *"gratitude → "* ]]
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

@test "sync reconciles the md Progress column for a habit ticked by hand (no stale snapshot)" {
  _write_profile
  # Tracker created in the morning: Brush at night is not done yet -> "0/7 wk".
  HABITS track --date 2026-06-03
  # User ticks the Done cell directly in Obsidian (markdown-first) — no command
  # runs, so the Progress column is left at its stale creation-time snapshot.
  python3 - "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md" <<'PY'
import sys, re
p = sys.argv[1]; t = open(p).read()
# Tick the Done column (Habit | Criteria | Progress | Done | …).
t = re.sub(r"(\| Brush at night \|[^|\n]*\|[^|\n]*\|)[^|\n]*\|", r"\1 x |", t, count=1)
open(p, "w").write(t)
PY
  # Precondition: Done is x but Progress is still the stale 0/7.
  pre="$(grep 'Brush at night' "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md")"
  [[ "$pre" == *" x "* ]]
  [[ "$pre" == *"0/7 wk"* ]]
  # A plain read-path sync (what every read command runs) must now reconcile the
  # VISIBLE file's Progress with the mark — not leave it for end-of-day consolidate.
  HABITS sync --days 0 --date 2026-06-03
  post="$(grep 'Brush at night' "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md")"
  [[ "$post" == *"1/7 wk"* ]]
  [[ "$post" != *"0/7 wk"* ]]
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

@test "scored daily habit: Progress denominator is the 1.0 max, Criteria is the <1 threshold" {
  cat > "$PBRAIN_HABITS_PROFILE_FILE" <<'PROF'
---
type: habits-profile
---

```json
{"habits":[
 {"id":"deep-work","name":"Deep work","schedule_type":"daily","direction":"at_least","priority":"high","archived":false,"unit":"","measure_target":0.75,"notes":"","scoring":{"type":"focus_ratio"}},
 {"id":"water","name":"Water","schedule_type":"daily","direction":"at_least","priority":"medium","archived":false,"unit":"L","measure_target":2}
]}
```
PROF
  HABITS mark --name "Deep work" --date 2026-06-03 --focus '{"work":50,"social":50}' >/dev/null
  HABITS mark --name "Water" --date 2026-06-03 --amount 1.5 >/dev/null
  HABITS sync --days 0 --date 2026-06-03 >/dev/null
  HABITS track --date 2026-06-03 >/dev/null
  body="$(cat "$PBRAIN_HABIT_TRACK_DIR/2026-06-03.md")"
  # scored daily → Criteria shows the <1 pass threshold; Progress denominator is
  # the 1.0 unit max (NOT the threshold). measured non-scored Water is unchanged.
  [[ "$body" == *"| Deep work | daily ≥0.75 | 0.5/1 day |"* ]] \
    && [[ "$body" == *"| Water | daily ≥2 L | 1.5/2 L day |"* ]]
}

@test "scored weekly habit: Progress banks the week's sum out of 7, Criteria is the <7 pass bar" {
  cat > "$PBRAIN_HABITS_PROFILE_FILE" <<'PROF'
---
type: habits-profile
---

```json
{"habits":[{"id":"deep-work","name":"Deep work","schedule_type":"weekly","direction":"at_least","priority":"high","archived":false,"unit":"","measure_target":5,"eod_only":true,"notes":"","scoring":{"type":"focus_ratio"}}]}
```
PROF
  # week of Mon 2026-06-15: bank a 0.5 score on four days -> running sum 2.0
  for d in 2026-06-15 2026-06-16 2026-06-17 2026-06-18; do
    HABITS mark --name "Deep work" --date "$d" --amount 0.5 >/dev/null
  done
  HABITS sync --days 6 --date 2026-06-18 >/dev/null
  HABITS track --date 2026-06-18 >/dev/null
  body="$(cat "$PBRAIN_HABIT_TRACK_DIR/2026-06-18.md")"
  # weekly scored → Criteria is the <7 pass bar; Progress banks the week's sum
  # against the 7-day max (like Eat clean's "4/7 wk").
  [[ "$body" == *"| Deep work | weekly ≥5 | 2/7 wk |"* ]]
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

# ── reminders-realign-plan (PB-88): deterministic time-match to the plan ─────

# Write a daily plan with a "## Today at a glance" table containing timed rows.
_write_plan_glance() {  # <date>  → plan file under PBRAIN_PLAN_DIR
  local d="${1:-2026-06-03}"
  export PBRAIN_PLAN_DIR="$TMP/daily-planning"; mkdir -p "$PBRAIN_PLAN_DIR"
  cat > "$PBRAIN_PLAN_DIR/$d.md" <<EOF
---
type: daily-plan
date: $d
---

# $d — plan

## Today at a glance

| Time | Block | Focus | Tie |
|---|---|---|---|
| 09:00–10:00 | Wake + morning routine | rest | — |
| 22:45–23:15 | Brush at night | wind-down | — |
| 00:00 | Bed | sleep | — |

## Work tracker
EOF
}

# Count pending habit_reminders rows for a habit on a date (proves ensure ran).
_hr_pending_count() {  # <habit_id> <date>
  python3 - "$PBRAIN_DB_FILE" "$1" "$2" <<'PYEOF'
import sqlite3, sys
db, hid, date = sys.argv[1:4]
con = sqlite3.connect(db)
n = con.execute("SELECT COUNT(*) FROM habit_reminders WHERE habit_id=? AND occurred_on=? AND status='pending'",
                (hid, date)).fetchone()[0]
con.close(); print(n)
PYEOF
}

@test "reminders-realign-plan: no habits profile prints REALIGNED 0 SKIPPED 0" {
  rm -f "$PBRAIN_HABITS_PROFILE_FILE"
  _write_plan_glance 2026-06-03
  run HABITS reminders-realign-plan --plan "$PBRAIN_PLAN_DIR/2026-06-03.md" --date 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" == "REALIGNED 0 SKIPPED 0" ]]
}

@test "reminders-realign-plan: missing plan file prints REALIGNED 0 SKIPPED 0" {
  _write_profile
  HABITS reminder --id brush-at-night --link --time 07:00
  run HABITS reminders-realign-plan --plan "$TMP/nope.md" --date 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" == "REALIGNED 0 SKIPPED 0" ]]
}

@test "reminders-realign-plan: bad date is rejected" {
  _write_profile
  run HABITS reminders-realign-plan --plan "$TMP/x.md" --date "nope"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR:bad date"* ]]
}

@test "reminders-realign-plan: only LINKED habits are matched (unlinked → no attempt)" {
  _write_profile
  # Brush at night IS in the plan glance but is NOT linked → must not be touched.
  _write_plan_glance 2026-06-03
  run HABITS reminders-realign-plan --plan "$PBRAIN_PLAN_DIR/2026-06-03.md" --date 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" == "REALIGNED 0 SKIPPED 0" ]]
  # no one-shot ensured for an unlinked habit
  [ "$(_hr_pending_count brush-at-night 2026-06-03)" -eq 0 ]
}

@test "reminders-realign-plan: linked habit matched in a timed row triggers an attempt" {
  _write_profile
  HABITS reminder --id brush-at-night --link --time 07:00
  _write_plan_glance 2026-06-03
  run HABITS reminders-realign-plan --plan "$PBRAIN_PLAN_DIR/2026-06-03.md" --date 2026-06-03
  [ "$status" -eq 0 ]
  # The match fired → an ensure+reschedule attempt was made. Apple Reminders is
  # stubbed UNAVAILABLE in CI so the edit can't succeed, landing the attempt in
  # SKIPPED. The SKIPPED 1 (vs the no-match SKIPPED 0) is what proves the match.
  [[ "$output" == "REALIGNED 0 SKIPPED 1" ]]
}

@test "reminders-realign-plan: linked habit absent from the plan is not touched" {
  _write_profile
  HABITS reminder --id brush-at-night --link --time 07:00
  # Plan glance that does NOT mention "Brush at night".
  export PBRAIN_PLAN_DIR="$TMP/daily-planning"; mkdir -p "$PBRAIN_PLAN_DIR"
  cat > "$PBRAIN_PLAN_DIR/2026-06-03.md" <<'EOF'
## Today at a glance

| Time | Block | Focus | Tie |
|---|---|---|---|
| 09:00–10:00 | Deep work | focus | pbrain |
EOF
  run HABITS reminders-realign-plan --plan "$PBRAIN_PLAN_DIR/2026-06-03.md" --date 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" == "REALIGNED 0 SKIPPED 0" ]]
  [ "$(_hr_pending_count brush-at-night 2026-06-03)" -eq 0 ]
}

@test "reminders-realign-plan: defaults --plan to today's daily-planning file" {
  _write_profile
  HABITS reminder --id brush-at-night --link --time 07:00
  _write_plan_glance 2026-06-03
  # omit --plan → resolves PBRAIN_PLAN_DIR/<date>.md
  run HABITS reminders-realign-plan --date 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" == "REALIGNED 0 SKIPPED 1" ]]
}

@test "reminders-realign-plan: idempotent re-run produces the same output" {
  _write_profile
  HABITS reminder --id brush-at-night --link --time 07:00
  _write_plan_glance 2026-06-03
  HABITS reminders-realign-plan --plan "$PBRAIN_PLAN_DIR/2026-06-03.md" --date 2026-06-03
  run HABITS reminders-realign-plan --plan "$PBRAIN_PLAN_DIR/2026-06-03.md" --date 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" == "REALIGNED 0 SKIPPED 1" ]]
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
      "unit": "", "measure_target": 0.8, "scoring": { "type": "meal_ratio" } },
    { "id": "sleep-well", "name": "Sleep well", "schedule_type": "daily", "direction": "at_least", "target_count": null, "priority": "high", "archived": false,
      "unit": "", "measure_target": 0.8,
      "scoring": { "type": "deviation", "normal_time": "23:00", "normal_hours": 8.0,
                   "unit_minutes": 30, "unit_hours": 0.5, "ladder": [1.0, 0.9, 0.75, 0.5, 0.25, 0] } }
  ]
}
```
EOF
}

@test "score meal_ratio: 5 clean 1 unclean -> 83" {
  _write_v2_scored_profile
  run HABITS score --name "Eat clean" --good 5 --bad 1
  [ "$status" -eq 0 ]
  [ "$output" = "0.83" ]
}

@test "score meal_ratio: 2 clean 1 unclean -> 67 (fewer meals weigh slips more)" {
  _write_v2_scored_profile
  run HABITS score --name "Eat clean" --good 2 --bad 1
  [ "$output" = "0.67" ]
}

@test "score meal_ratio: zero meals -> blank (caller falls back)" {
  _write_v2_scored_profile
  run HABITS score --name "Eat clean" --good 0 --bad 0
  [ -z "$output" ]
}

@test "score deviation: exactly normal -> 100" {
  _write_v2_scored_profile
  run HABITS score --name "Sleep well" --actual-time 23:00 --actual-hours 8
  [ "$output" = "1" ]
}

@test "score deviation: 1h late + 1h short -> 4 slips -> 25" {
  _write_v2_scored_profile
  run HABITS score --name "Sleep well" --actual-time 00:00 --actual-hours 7
  [ "$output" = "0.25" ]
}

@test "score deviation: midnight crossing is circular (00:30 vs 23:00 = 90min)" {
  _write_v2_scored_profile
  # 90 min late -> 3 slips; hours on target -> ladder[3] = 50
  run HABITS score --name "Sleep well" --actual-time 00:30 --actual-hours 8
  [ "$output" = "0.5" ]
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
  [ "$amt" = "0.25" ]
}

# ── default-habit seeding (eat-clean + sleep-well) ──────────────────────────

# /diet-journal "enabled" signal: a committed diet profile.
_plant_diet_profile() {
  mkdir -p "$PBRAIN_VAULT/fitness/diet-tracking/.profile"
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
}

# /fitness-journal "enabled" signal: a committed fitness profile (Sleep well).
_plant_fitness_profile() {
  mkdir -p "$PBRAIN_VAULT/fitness/daily-tracking/.profile"
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

# Both diet + fitness profiles (the original combined planter).
_plant_source_profiles() {
  _plant_diet_profile
  _plant_fitness_profile
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

# ── PB-39: a default habit seeds ONLY when its owning command is enabled ─────
# "Enabled" = that command's committed profile (or, for Deep work, the laptop
# tracker DB) is present. These guard the cross-command isolation: enabling one
# command must not seed another command's habits (e.g. no Train without
# /fitness-journal). Assertions are &&-chained onto the final line because the
# suite only enforces each test's last command.

# Negatives assert on the precise seed line ("Added default habit: <name>"),
# not a bare name — the dashboard's scoring legend mentions every scored default
# by name ("e.g. Sleep well") regardless of what is actually seeded.

@test "PB-39: /diet-journal enabled alone seeds only Eat clean" {
  _write_profile
  _plant_diet_profile
  run HABITS
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"Added default habit: Eat clean"* ]] \
    && [[ "$output" != *"Added default habit: Sleep well"* ]] \
    && [[ "$output" != *"Added default habit: Train"* ]] \
    && [[ "$output" != *"per-activity fitness habit)"* ]] \
    && [[ "$output" != *"Added default habit: Work the plan"* ]] \
    && [[ "$output" != *"Added default habit: Deep work"* ]]
}

@test "PB-39: /fitness-journal enabled alone seeds Sleep well + Train, not Eat clean / Work the plan" {
  _write_profile
  _plant_fitness_profile
  _plant_fitness_library
  run HABITS
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"Added default habit: Sleep well"* ]] \
    && [[ "$output" == *"Added default habit: Train"* ]] \
    && [[ "$output" != *"Added default habit: Eat clean"* ]] \
    && [[ "$output" != *"Added default habit: Work the plan"* ]] \
    && [[ "$output" != *"Added default habit: Deep work"* ]]
}

@test "PB-39: /fitness-journal disabled means no Train even with the fitness profile present" {
  # fitness PROFILE (Sleep well) present, but no fitness LIBRARY → no Train / per-activity.
  _write_profile
  _plant_fitness_profile
  run HABITS
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"Added default habit: Sleep well"* ]] \
    && [[ "$output" != *"Added default habit: Train"* ]] \
    && [[ "$output" != *"per-activity fitness habit)"* ]]
}

@test "PB-39: /plan-my-day enabled alone seeds only Work the plan" {
  # plans profile present but no tracker DB → Work the plan yes, Deep work no.
  _write_profile
  _plant_goals_profile
  run HABITS
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"Added default habit: Work the plan"* ]] \
    && [[ "$output" != *"Added default habit: Eat clean"* ]] \
    && [[ "$output" != *"Added default habit: Sleep well"* ]] \
    && [[ "$output" != *"Added default habit: Train"* ]] \
    && [[ "$output" != *"Added default habit: Deep work"* ]]
}

@test "extraction emitter explains meal_ratio and deviation marking" {
  _write_v2_scored_profile
  # Scored-habit marking rules only surface at end-of-day now (PB-50): scored
  # habits are deferred from mid-day commands where they cannot yet be scored.
  run bash -c "source '$REPO_ROOT/lib/profile.sh'; source '$REPO_ROOT/lib/db.sh'; source '$REPO_ROOT/lib/habits.sh'; pbrain_emit_habits_extract end-of-day"
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
      "archived": false, "unit": "", "measure_target": 0.7,
      "scoring": { "type": "weighted_completion",
        "difficulty_weights": {"easy":1,"normal":2,"hard":3,"nightmare":5},
        "status_credit": {"done":1.0,"partial":0.5,"dropped":0.0,"carried":0.0},
        "priority_pivot": 3, "priority_step": 0.25 } },
    { "id": "train", "name": "Train", "schedule_type": "daily",
      "direction": "at_least", "target_count": null, "priority": "high",
      "archived": false, "unit": "", "measure_target": 0.8,
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
  [ "$output" = "1" ]
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
  [ "$output" = "0.88" ]
}

@test "score weighted_completion: partial task counts half credit -> 50" {
  # normal(2) * p3_boost(1.0) = 2.0 possible; partial credit 0.5 -> earned 1.0; score = 50
  _write_wc_profile
  run HABITS score --name "Work the plan" \
    --items '[{"priority":3,"difficulty":"normal","status":"partial"}]'
  [ "$status" -eq 0 ]
  [ "$output" = "0.5" ]
}

@test "score weighted_completion: half-up rounding -> 67" {
  # normal(2)*1.0=2 done + easy(1)*1.0=1 dropped: earned=2, possible=3 -> 66.67 -> rounds to 67
  _write_wc_profile
  run HABITS score --name "Work the plan" \
    --items '[{"priority":3,"difficulty":"normal","status":"done"},{"priority":3,"difficulty":"easy","status":"dropped"}]'
  [ "$status" -eq 0 ]
  [ "$output" = "0.67" ]
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
  [ "$output" = "1" ]
}

@test "score session_volume: partial binary -> 50" {
  _write_wc_profile
  run HABITS score --name "Train" \
    --session '{"mode":"binary","status":"partial"}'
  [ "$status" -eq 0 ]
  [ "$output" = "0.5" ]
}

@test "score session_volume: 90 pct of planned strength volume -> 90" {
  _write_wc_profile
  run HABITS score --name "Train" \
    --session '{"mode":"strength","status":"completed","planned":100,"actual":90}'
  [ "$status" -eq 0 ]
  [ "$output" = "0.9" ]
}

@test "score session_volume: actual over planned is capped at 100" {
  _write_wc_profile
  run HABITS score --name "Train" \
    --session '{"mode":"strength","status":"completed","planned":100,"actual":150}'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "score session_volume: duration mode ratio -> 75" {
  # duration is the second volume mode (alongside strength): 45/60 -> 75.
  _write_wc_profile
  run HABITS score --name "Train" \
    --session '{"mode":"duration","status":"completed","planned":60,"actual":45}'
  [ "$status" -eq 0 ]
  [ "$output" = "0.75" ]
}

@test "score session_volume: strength with no planned falls through to binary credit -> 100" {
  # planned missing -> the volume-ratio guard fails -> binary status credit.
  _write_wc_profile
  run HABITS score --name "Train" \
    --session '{"mode":"strength","status":"completed"}'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
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
  [ "$output" = "1" ]
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
  [ "$amt" = "1.0" ]
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
  [ "$amt" = "0.8" ]
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

@test "train seeds as a floating weekly aggregate (max 7, pass 5), not schedule-bound" {
  # Train is a cross-activity weekly volume score banked like Eat clean — scored
  # on the days you do ANY fitness activity, not pinned to library weekdays.
  _write_profile
  _plant_fitness_library
  mkdir -p "$PBRAIN_VAULT/fitness/daily-tracking/.profile/activities"
  printf -- '---\nactivity: Gym\ndays: [Mon, Wed, Fri]\nversion: 1\ncommitted: true\n---\n# Gym\n' \
    > "$PBRAIN_VAULT/fitness/daily-tracking/.profile/activities/gym.v1.md"
  run HABITS
  [ "$status" -eq 0 ]
  python3 -c "
import json, re
with open('$PBRAIN_HABITS_PROFILE_FILE') as f: t = f.read()
m = re.search(r'\x60\x60\x60json\s*\n(.*?)\x60\x60\x60', t, re.DOTALL)
train = next(h for h in json.loads(m.group(1))['habits'] if h['id'] == 'train')
assert train.get('schedule_type') == 'weekly', repr(train)
assert train.get('schedule') is None, repr(train)
assert train.get('measure_target') == 5, repr(train)
assert train.get('eod_only') is True, repr(train)
assert train['scoring']['type'] == 'session_volume', repr(train)
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

# ── focus_ratio (the "Deep work" scored habit) ───────────────────────────────

_write_deepwork_profile() {
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
    { "id": "deep-work", "name": "Deep work", "schedule_type": "daily",
      "direction": "at_least", "target_count": null, "priority": "high",
      "archived": false, "unit": "", "measure_target": 0.75,
      "scoring": { "type": "focus_ratio",
        "work_categories": ["work"],
        "distraction_categories": ["social","entertainment"] } }
  ]
}
```
PEOF
}

@test "score focus_ratio: work-only -> 100" {
  _write_deepwork_profile
  run HABITS score --name "Deep work" --focus '{"work":120}'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "score focus_ratio: all-distraction -> 0" {
  _write_deepwork_profile
  run HABITS score --name "Deep work" --focus '{"social":30,"entertainment":10}'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "score focus_ratio: mixed 90 work / 30 distraction -> 75 (neutral+afk excluded)" {
  _write_deepwork_profile
  run HABITS score --name "Deep work" --focus '{"work":90,"social":20,"entertainment":10,"neutral":40,"afk":15}'
  [ "$status" -eq 0 ]
  [ "$output" = "0.75" ]
}

@test "score focus_ratio: only neutral/afk (no work or distraction) -> blank (unmarked)" {
  _write_deepwork_profile
  run HABITS score --name "Deep work" --focus '{"neutral":50,"afk":30}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "score focus_ratio: category membership is configurable in the spec" {
  # Re-point the spec so 'entertainment' counts as WORK and 'social' is the only distraction.
  cat > "$PBRAIN_HABITS_PROFILE_FILE" <<'PEOF'
---
type: habits-profile
---
```json
{ "habits": [
  { "id": "deep-work", "name": "Deep work", "schedule_type": "daily",
    "direction": "at_least", "target_count": null, "priority": "high",
    "archived": false, "unit": "", "measure_target": 0.75,
    "scoring": { "type": "focus_ratio",
      "work_categories": ["work","entertainment"],
      "distraction_categories": ["social"] } } ] }
```
PEOF
  # work = 60 + 30 = 90; distraction = social 30 -> 90/120 = 75
  run HABITS score --name "Deep work" --focus '{"work":60,"entertainment":30,"social":30}'
  [ "$status" -eq 0 ]
  [ "$output" = "0.75" ]
}

@test "mark focus_ratio: the computed score lands in habit_events.amount" {
  _write_deepwork_profile
  run HABITS mark --name "Deep work" --date 2026-06-03 --focus '{"work":90,"social":20,"entertainment":10}'
  [ "$status" -eq 0 ]
  amt="$(python3 -c "
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
row = con.execute(\"SELECT amount FROM habit_events WHERE habit_id='deep-work' AND occurred_on='2026-06-03'\").fetchone()
print(row[0] if row else 'none')
" "$PBRAIN_DB_FILE")"
  [ "$amt" = "0.75" ]
}

# ── default-habit seeding: deep-work (needs tracker.db AND a plans profile) ───

_plant_goals_profile_rest() {  # $1 = JSON array of rest-day tokens, e.g. '["Sat","Sun"]'
  mkdir -p "$PBRAIN_VAULT/life/daily-planning/.profile"
  cat > "$PBRAIN_VAULT/life/daily-planning/.profile/plans-profile.v1.md" <<EOF
---
type: plans-profile
version: 1
committed: true
---
# Plans profile
\`\`\`json
{"created": "2026-06-03",
 "typical_day": {"rest_days": $1},
 "current_focus": []}
\`\`\`
EOF
}

@test "dashboard seeds deep-work when tracker.db AND plans profile exist" {
  _write_profile
  _plant_goals_profile
  : > "$XDG_CONFIG_HOME/pbrain/tracker.db"   # presence is all the seed checks
  export PBRAIN_TRACKER_DB_FILE="$XDG_CONFIG_HOME/pbrain/tracker.db"
  run HABITS
  [ "$status" -eq 0 ]
  [[ "$output" == *"Added default habit: Deep work"* ]]
  grep -q '"id": "deep-work"' "$PBRAIN_HABITS_PROFILE_FILE"
  grep -q '"type": "focus_ratio"' "$PBRAIN_HABITS_PROFILE_FILE"
}

@test "deep-work is NOT seeded without a tracker.db" {
  _write_profile
  _plant_goals_profile
  export PBRAIN_TRACKER_DB_FILE="$TMP/nope-tracker.db"   # does not exist
  run HABITS
  [ "$status" -eq 0 ]
  [[ "$output" != *"Added default habit: Deep work"* ]]
  ! grep -q '"id": "deep-work"' "$PBRAIN_HABITS_PROFILE_FILE"
}

@test "deep-work is NOT seeded without a committed plans profile" {
  _write_profile
  _plant_fitness_library   # a profile exists so seeding runs, but no plans profile
  : > "$XDG_CONFIG_HOME/pbrain/tracker.db"
  export PBRAIN_TRACKER_DB_FILE="$XDG_CONFIG_HOME/pbrain/tracker.db"
  run HABITS
  [ "$status" -eq 0 ]
  [[ "$output" != *"Added default habit: Deep work"* ]]
}

@test "deep-work seeds as a floating weekly aggregate (max 7, pass 5), not workday-bound" {
  _write_profile
  _plant_goals_profile_rest '"'"'["Sat","Sun"]'"'"'
  : > "$XDG_CONFIG_HOME/pbrain/tracker.db"
  export PBRAIN_TRACKER_DB_FILE="$XDG_CONFIG_HOME/pbrain/tracker.db"
  run HABITS
  [ "$status" -eq 0 ]
  python3 -c "
import json, re
with open('$PBRAIN_HABITS_PROFILE_FILE') as f: t = f.read()
m = re.search(r'\x60\x60\x60json\s*\n(.*?)\x60\x60\x60', t, re.DOTALL)
dw = next(h for h in json.loads(m.group(1))['habits'] if h['id'] == 'deep-work')
assert dw.get('schedule_type') == 'weekly', repr(dw)
assert dw.get('schedule') is None, repr(dw)
assert dw.get('measure_target') == 5, repr(dw)
assert dw.get('eod_only') is True, repr(dw)
assert dw['scoring']['type'] == 'focus_ratio', repr(dw)
"
}

@test "deep-work seeding is idempotent" {
  _write_profile
  _plant_goals_profile
  : > "$XDG_CONFIG_HOME/pbrain/tracker.db"
  export PBRAIN_TRACKER_DB_FILE="$XDG_CONFIG_HOME/pbrain/tracker.db"
  HABITS >/dev/null
  run HABITS
  [[ "$output" != *"Added default habit: Deep work"* ]]
  [ "$(grep -c '"id": "deep-work"' "$PBRAIN_HABITS_PROFILE_FILE")" -eq 1 ]
}

# ── scores subcommand ────────────────────────────────────────────────────────

_write_scores_profile() {
  cat > "$PBRAIN_HABITS_PROFILE_FILE" <<'EOF'
---
type: habits-profile
version: 1
committed: true
---

# Habits profile

```json
{
  "habits": [
    { "id": "eat-clean", "name": "Eat clean", "schedule_type": "daily",
      "direction": "at_least", "priority": "high", "archived": false,
      "unit": "", "measure_target": 0.8,
      "scoring": { "type": "meal_ratio" } },
    { "id": "sleep-well", "name": "Sleep well", "schedule_type": "daily",
      "direction": "at_least", "priority": "high", "archived": false,
      "unit": "", "measure_target": 0.8,
      "scoring": { "type": "deviation", "normal_time": "23:00",
                   "normal_hours": 8.0, "unit_minutes": 30,
                   "unit_hours": 0.5, "ladder": [1.0, 0.9, 0.75, 0.5, 0.25, 0] } },
    { "id": "brush-at-night", "name": "Brush at night", "schedule_type": "daily",
      "direction": "at_least", "target_count": 1, "priority": "medium",
      "archived": false }
  ]
}
```
EOF
}

@test "scores: marked scored habit prints the unit score and appears in HABIT_SCORES JSON" {
  _write_scores_profile
  HABITS mark --name "Eat clean" --date "2026-06-13" --good 4 --bad 1 >/dev/null
  run HABITS scores --date "2026-06-13"
  [ "$status" -eq 0 ]
  # human line: 4 clean / 1 unclean = 0.8
  [[ "$output" == *"Eat clean · 0.8 · meal_ratio · high"* ]]
  # machine line present with correct score
  python3 -c "
import json, sys
lines = '''$output'''.splitlines()
trailer = next((l for l in lines if l.startswith('HABIT_SCORES ')), None)
assert trailer, 'no HABIT_SCORES line'
data = json.loads(trailer[len('HABIT_SCORES '):])
ec = next(h for h in data if h['id'] == 'eat-clean')
assert ec['score'] == 0.8, repr(ec)
assert ec['scoring_type'] == 'meal_ratio', repr(ec)
assert ec['priority'] == 'high', repr(ec)
"
}

@test "scores: unmarked scored habit prints not-marked and score null in JSON" {
  _write_scores_profile
  # mark eat-clean but leave sleep-well unmarked
  HABITS mark --name "Eat clean" --date "2026-06-13" --good 4 --bad 1 >/dev/null
  run HABITS scores --date "2026-06-13"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sleep well · not marked · deviation · high"* ]]
  python3 -c "
import json, sys
lines = '''$output'''.splitlines()
trailer = next((l for l in lines if l.startswith('HABIT_SCORES ')), None)
assert trailer, 'no HABIT_SCORES line'
data = json.loads(trailer[len('HABIT_SCORES '):])
sw = next(h for h in data if h['id'] == 'sleep-well')
assert sw['score'] is None, repr(sw)
"
}

@test "scores: non-scored habit is excluded from output and HABIT_SCORES JSON" {
  _write_scores_profile
  run HABITS scores --date "2026-06-13"
  [ "$status" -eq 0 ]
  [[ "$output" != *"brush-at-night"* ]]
  [[ "$output" != *"Brush at night"* ]]
  python3 -c "
import json
lines = '''$output'''.splitlines()
trailer = next((l for l in lines if l.startswith('HABIT_SCORES ')), None)
assert trailer, 'no HABIT_SCORES line'
data = json.loads(trailer[len('HABIT_SCORES '):])
ids = [h['id'] for h in data]
assert 'brush-at-night' not in ids, repr(ids)
"
}

@test "scores: no profile yields HABIT_SCORES []" {
  run HABITS scores --date "2026-06-13"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HABIT_SCORES []"* ]]
}

# ── checklist (e.g. the "Supplements" scored habit) ──────────────────────────

_write_supplements_profile() {
  # 3 equal-weight components: morning ×2 + a night magnesium = score out of 3.
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
    { "id": "supplements", "name": "Supplements", "schedule_type": "daily",
      "direction": "at_least", "target_count": null, "priority": "high",
      "archived": false, "unit": "", "measure_target": 1.0,
      "scoring": { "type": "checklist", "components": [
        { "id": "morning-vit-d", "name": "Morning vitamin D", "weight": 1 },
        { "id": "morning-omega", "name": "Morning omega-3", "weight": 1 },
        { "id": "magnesium-night", "name": "Magnesium (night)", "weight": 1 } ] } }
  ]
}
```
PEOF
}

@test "score checklist: all components done -> 100" {
  _write_supplements_profile
  run HABITS score --name "Supplements" --done '["Morning vitamin D","Morning omega-3","Magnesium (night)"]'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "score checklist: morning only (2 of 3 equal weights) -> 67" {
  _write_supplements_profile
  run HABITS score --name "Supplements" --done '["Morning vitamin D","Morning omega-3"]'
  [ "$status" -eq 0 ]
  [ "$output" = "0.67" ]
}

@test "score checklist: night magnesium only (1 of 3) -> 33" {
  _write_supplements_profile
  run HABITS score --name "Supplements" --done '["Magnesium (night)"]'
  [ "$status" -eq 0 ]
  [ "$output" = "0.33" ]
}

@test "score checklist: components match by id as well as name" {
  _write_supplements_profile
  run HABITS score --name "Supplements" --done '["morning-vit-d","magnesium-night"]'
  [ "$status" -eq 0 ]
  [ "$output" = "0.67" ]
}

@test "score checklist: nothing done (empty list) -> 0" {
  _write_supplements_profile
  run HABITS score --name "Supplements" --done '[]'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "score checklist: no --done at all -> blank (unmarked, not a zero)" {
  _write_supplements_profile
  run HABITS score --name "Supplements"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "score checklist: unknown component names are ignored" {
  _write_supplements_profile
  run HABITS score --name "Supplements" --done '["Morning vitamin D","creatine"]'
  [ "$status" -eq 0 ]
  [ "$output" = "0.33" ]
}

@test "score checklist: weighted components (morning group worth 2, night worth 1)" {
  cat > "$PBRAIN_HABITS_PROFILE_FILE" <<'PEOF'
---
type: habits-profile
---
```json
{ "habits": [
  { "id": "supplements", "name": "Supplements", "schedule_type": "daily",
    "direction": "at_least", "target_count": null, "priority": "high",
    "archived": false, "unit": "", "measure_target": 1.0,
    "scoring": { "type": "checklist", "components": [
      { "id": "morning", "name": "Morning stack", "weight": 2 },
      { "id": "magnesium", "name": "Magnesium", "weight": 1 } ] } } ] }
```
PEOF
  run HABITS score --name "Supplements" --done '["Morning stack"]'
  [ "$status" -eq 0 ]
  [ "$output" = "0.67" ]
}

@test "mark checklist: the computed score lands in habit_events.amount" {
  _write_supplements_profile
  run HABITS mark --name "Supplements" --date 2026-06-03 --done '["Morning vitamin D","Morning omega-3"]'
  [ "$status" -eq 0 ]
  amt="$(python3 -c "
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
row = con.execute(\"SELECT amount FROM habit_events WHERE habit_id='supplements' AND occurred_on='2026-06-03'\").fetchone()
print(row[0] if row else 'none')
" "$PBRAIN_DB_FILE")"
  [ "$amt" = "0.67" ]
}

@test "add --components builds a checklist scoring block + defaults measure_target to 1.0" {
  HABITS add --name "Supplements" --type daily --priority high \
    --components "Morning vitamin D; Morning omega-3; Magnesium (night)" >/dev/null
  run python3 -c "
import json, re, sys
text = open(sys.argv[1]).read()
m = re.search(r'\`\`\`json\s*\n(.*?)\`\`\`', text, re.DOTALL)
data = json.loads(m.group(1))
h = next(x for x in data['habits'] if x['id'] == 'supplements')
sc = h['scoring']
assert sc['type'] == 'checklist', sc
assert len(sc['components']) == 3, sc
assert [c['name'] for c in sc['components']] == ['Morning vitamin D','Morning omega-3','Magnesium (night)'], sc
assert all(c['weight'] == 1 for c in sc['components']), sc
assert h['measure_target'] == 1.0, h
print('ok')
" "$PBRAIN_HABITS_PROFILE_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "add --components parses per-item weights after '='" {
  HABITS add --name "Supplements" --type daily \
    --components "Morning stack=2; Magnesium=1" >/dev/null
  run python3 -c "
import json, re, sys
data = json.loads(re.search(r'\`\`\`json\s*\n(.*?)\`\`\`', open(sys.argv[1]).read(), re.DOTALL).group(1))
sc = next(x for x in data['habits'] if x['id'] == 'supplements')['scoring']
assert [(c['name'], c['weight']) for c in sc['components']] == [('Morning stack', 2), ('Magnesium', 1)], sc
print('ok')
" "$PBRAIN_HABITS_PROFILE_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "add --components then score end-to-end via the freshly added habit" {
  HABITS add --name "Supplements" --type daily \
    --components "Morning vitamin D; Morning omega-3; Magnesium (night)" >/dev/null
  run HABITS score --name "Supplements" --done '["Morning vitamin D"]'
  [ "$status" -eq 0 ]
  [ "$output" = "0.33" ]
}

@test "edit --components empty string clears the checklist scoring" {
  _write_supplements_profile
  HABITS edit --id supplements --components "" >/dev/null
  run python3 -c "
import json, re, sys
data = json.loads(re.search(r'\`\`\`json\s*\n(.*?)\`\`\`', open(sys.argv[1]).read(), re.DOTALL).group(1))
h = next(x for x in data['habits'] if x['id'] == 'supplements')
assert 'scoring' not in h, h
print('ok')
" "$PBRAIN_HABITS_PROFILE_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "emit_habits_extract surfaces checklist components + the --done channel" {
  _write_supplements_profile
  # Checklist (Supplements) is a scored habit — its components surface at
  # end-of-day, where scored habits are markable (PB-50).
  run bash -c "source '$REPO_ROOT/lib/profile.sh'; source '$REPO_ROOT/lib/db.sh'; source '$REPO_ROOT/lib/habits.sh'; pbrain_emit_habits_extract end-of-day"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--done"* ]]
  [[ "$output" == *"Magnesium (night)"* ]]
}

# ── weekly scored habits AVERAGE daily scores (not sum) ───────────────────────

_write_weekly_scored_profile() {
  # A weekly SCORED habit (deep-work) + a plain measured weekly habit (water).
  cat > "$PBRAIN_HABITS_PROFILE_FILE" <<'PEOF'
---
type: habits-profile
---
```json
{ "habits": [
  { "id": "deep-work", "name": "Deep work", "schedule_type": "weekly",
    "direction": "at_least", "target_count": null, "priority": "high",
    "archived": false, "unit": "", "measure_target": 0.75,
    "schedule": {"type":"weekdays","days":["mon","tue","wed","thu","fri"]},
    "scoring": { "type": "focus_ratio", "work_categories": ["work"],
      "distraction_categories": ["social","entertainment"] } },
  { "id": "water", "name": "Water", "schedule_type": "weekly",
    "direction": "at_least", "target_count": null, "priority": "low",
    "archived": false, "unit": "L", "measure_target": 28 }
] }
```
PEOF
}

@test "rollup: a weekly scored habit banks the running SUM of its daily scores out of 7" {
  _write_weekly_scored_profile
  # Mon/Tue/Wed of the week containing 2026-06-17: scores 0.6, 0.8, 1.0 → sum 2.4.
  HABITS mark --name "Deep work" --date 2026-06-15 --focus '{"work":60,"social":40}' >/dev/null
  HABITS mark --name "Deep work" --date 2026-06-16 --focus '{"work":80,"social":20}' >/dev/null
  HABITS mark --name "Deep work" --date 2026-06-17 --focus '{"work":100}' >/dev/null
  run bash -c "source '$REPO_ROOT/lib/profile.sh'; source '$REPO_ROOT/lib/db.sh'; source '$REPO_ROOT/lib/habits.sh'; pbrain_habits_rollup 2026-06-17"
  [ "$status" -eq 0 ]
  # banked sum 2.4 against the 7-day max, not an average
  [[ "$output" == *"Deep work"* ]] && [[ "$output" == *"2.4/7 this week"* ]]
}

@test "rollup: a plain measured weekly habit still SUMS its amounts" {
  _write_weekly_scored_profile
  HABITS mark --name "Water" --date 2026-06-15 --amount 4 >/dev/null
  HABITS mark --name "Water" --date 2026-06-16 --amount 5 >/dev/null
  run bash -c "source '$REPO_ROOT/lib/profile.sh'; source '$REPO_ROOT/lib/db.sh'; source '$REPO_ROOT/lib/habits.sh'; pbrain_habits_rollup 2026-06-17"
  [ "$status" -eq 0 ]
  [[ "$output" == *"9/28 L this week"* ]]
}

@test "tracker Progress column sums a weekly scored habit's scores (agg, not avg)" {
  _write_weekly_scored_profile
  HABITS mark --name "Deep work" --date 2026-06-15 --focus '{"work":60,"social":40}' >/dev/null
  HABITS mark --name "Deep work" --date 2026-06-17 --focus '{"work":100}' >/dev/null
  HABITS track --date 2026-06-17 >/dev/null
  run grep "Deep work" "$PBRAIN_HABIT_TRACK_DIR/2026-06-17.md"
  [ "$status" -eq 0 ]
  # weekly = running SUM over the period out of the 7-day max: 0.6 + 1.0 = 1.6
  [[ "$output" == *"1.6/7 wk"* ]]
}

@test "tracker Progress rounds an accumulated scored sum (no 1.9300000000000002 float artifact)" {
  _write_weekly_scored_profile
  # 93/(93+7)=0.93 plus 100/100=1.0 sums to 1.9300000000000002 in raw float —
  # must render rounded to 2dp as "1.93/7 wk", never the binary-float artifact (PB-106).
  HABITS mark --name "Deep work" --date 2026-06-15 --focus '{"work":93,"social":7}' >/dev/null
  HABITS mark --name "Deep work" --date 2026-06-17 --focus '{"work":100}' >/dev/null
  HABITS track --date 2026-06-17 >/dev/null
  run grep "Deep work" "$PBRAIN_HABIT_TRACK_DIR/2026-06-17.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1.93/7 wk"* ]]
  [[ "$output" != *"1.9300000000000002"* ]]
}

# ═════════════════════════════════════════════════════════════════════════
# 3-state habit status: done / skipped / missed  (Phase 1)
# ═════════════════════════════════════════════════════════════════════════

# A weekdays-scheduled fitness profile used by status / reconcile / autostatus.
# Gym Mon/Wed (linked 12:30); Apple Fitness Tue/Fri (linked 12:30); Meditation
# floating (no explicit schedule, daily build); No smoking daily limit.
_write_fitness_habits() {
  cat > "$PBRAIN_HABITS_PROFILE_FILE" <<'EOF'
---
type: habits-profile
---
```json
{"habits":[
 {"id":"gym","name":"Gym","direction":"at_least","schedule":{"type":"weekdays","days":["mon","wed"]},"schedule_type":"weekly","priority":"high","reminder":{"state":"linked","time":"12:30"}},
 {"id":"apple-fitness","name":"Apple Fitness","direction":"at_least","schedule":{"type":"weekdays","days":["tue","fri"]},"schedule_type":"weekly","priority":"high","reminder":{"state":"linked","time":"12:30"}},
 {"id":"meditation","name":"Meditation","direction":"at_least","priority":"medium"},
 {"id":"no-smoking","name":"No smoking","direction":"at_most","schedule":{"type":"daily"},"schedule_type":"daily","target_count":0,"priority":"high"}
]}
```
EOF
}

# A flexible "N times per week" habit (schedule_type weekly + target_count, no
# fixed days) — exercises the period-aware autostatus path.
_write_flex_weekly() {
  cat > "$PBRAIN_HABITS_PROFILE_FILE" <<'EOF'
---
type: habits-profile
---
```json
{"habits":[
 {"id":"microneedling","name":"Microneedling","direction":"at_least","schedule_type":"weekly","target_count":2,"priority":"medium"}
]}
```
EOF
}

_plant_fitness_lib_multi() {
  mkdir -p "$PBRAIN_VAULT/fitness/daily-tracking/.profile"
  cat > "$PBRAIN_VAULT/fitness/daily-tracking/.profile/fitness-library.v1.md" <<'EOF'
---
type: fitness-library
version: 1
committed: true
---
```json
{"activities":[
 {"id":"gym","name":"Gym","occurrence":{"per":"week","times":2},"days":["Mon","Wed"],"typical_time":"12:30"},
 {"id":"apple-fitness-kickboxing","name":"Apple Fitness+ Kickboxing","occurrence":{"per":"week","times":2},"days":["Tue"]},
 {"id":"meditation","name":"Meditation","occurrence":{"per":"week","times":3},"days":[]}
]}
```
EOF
}

# count|status of a habit_events row for a (habit_id, date), or "NONE".
_ev() {
  python3 -c "
import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
r=c.execute('select count,status from habit_events where habit_id=? and occurred_on=?',(sys.argv[2],sys.argv[3])).fetchone()
print('NONE' if not r else '%d|%s'%(r[0],r[1]))" "$PBRAIN_DB_FILE" "$1" "$2"
}

@test "mark --status skipped: skip token in md + count=0 status=skipped in DB" {
  _write_profile
  HABITS track --date 2026-06-15 >/dev/null
  run HABITS mark --id brush-at-night --date 2026-06-15 --status skipped
  [ "$status" -eq 0 ]
  grep -qE '^\| Brush at night .*\| skip \|' "$PBRAIN_HABIT_TRACK_DIR/2026-06-15.md"
  [ "$(_ev brush-at-night 2026-06-15)" = "0|skipped" ]
}

@test "mark --skip is sugar for --status skipped" {
  _write_profile
  HABITS track --date 2026-06-15 >/dev/null
  HABITS mark --id brush-at-night --date 2026-06-15 --skip >/dev/null
  [ "$(_ev brush-at-night 2026-06-15)" = "0|skipped" ]
}

@test "mark --status missed: miss token in md + count=0 status=missed in DB" {
  _write_profile
  HABITS track --date 2026-06-15 >/dev/null
  HABITS mark --id brush-at-night --date 2026-06-15 --status missed >/dev/null
  grep -qE '^\| Brush at night .*\| miss \|' "$PBRAIN_HABIT_TRACK_DIR/2026-06-15.md"
  [ "$(_ev brush-at-night 2026-06-15)" = "0|missed" ]
}

@test "plain mark is still a done completion (count>=1 status=done)" {
  _write_profile
  HABITS track --date 2026-06-15 >/dev/null
  HABITS mark --id brush-at-night --date 2026-06-15 >/dev/null
  [ "$(_ev brush-at-night 2026-06-15)" = "1|done" ]
}

@test "consolidate keeps done + skipped + missed rows, prunes only untouched" {
  _write_profile
  HABITS track --date 2026-06-15 >/dev/null
  HABITS mark --id brush-at-night --date 2026-06-15 >/dev/null              # done
  HABITS mark --id nail-cut --date 2026-06-15 --status skipped >/dev/null   # skipped
  HABITS mark --id long-run --date 2026-06-15 --status missed >/dev/null    # missed
  HABITS consolidate --date 2026-06-15 >/dev/null
  f="$PBRAIN_HABIT_TRACK_DIR/2026-06-15.md"
  grep -qE '^\| Brush at night .*\| x \|' "$f"
  grep -qE '^\| Nail cut .*\| skip \|' "$f"
  grep -qE '^\| Long run .*\| miss \|' "$f"
  run grep -qE '^\| Alcohol ' "$f"   # untouched limit row pruned
  [ "$status" -ne 0 ]
}

@test "rollup: a skipped due day never breaks the streak; a missed one does" {
  _write_fitness_habits
  # Gym Mon/Wed. Wed 2026-06-10 done, Fri n/a, Mon 2026-06-15 done; middle day…
  HABITS mark --id gym --date 2026-06-10 >/dev/null               # Wed done
  HABITS mark --id gym --date 2026-06-15 >/dev/null               # Mon done
  # With nothing between, streak from Mon back to Wed (no due day between) = 2
  run bash -c "source '$REPO_ROOT/lib/vault.sh'; pbrain_habits_status 2026-06-15"
  echo "$output" | python3 -c "import json,sys; h=[x for x in json.load(sys.stdin)['habits'] if x['id']=='gym'][0]; assert h['streak']==2, h['streak']"
}

# ═════════════════════════════════════════════════════════════════════════
# reminders-cancel  (Phase 2)
# ═════════════════════════════════════════════════════════════════════════

@test "reminders-cancel: unknown habit → NOT_FOUND" {
  _write_fitness_habits
  run HABITS reminders-cancel --habit DoesNotExist --date 2026-06-15
  [ "$status" -eq 0 ]
  [ "$output" = "NOT_FOUND" ]
}

@test "reminders-cancel: no pending one-shot → NOT_FOUND" {
  _write_fitness_habits
  run HABITS reminders-cancel --habit Gym --date 2026-06-15
  [ "$status" -eq 0 ]
  [ "$output" = "NOT_FOUND" ]
}

@test "reminders-cancel: missing --habit is a soft error, not a crash" {
  _write_fitness_habits
  run HABITS reminders-cancel --date 2026-06-15
  [ "$status" -eq 0 ]
  [[ "$output" == ERROR:* ]]
}

# ═════════════════════════════════════════════════════════════════════════
# fitness-reconcile  (Phase 3)
# ═════════════════════════════════════════════════════════════════════════

@test "fitness-reconcile: chosen activity resolves + off-activity is auto-skipped" {
  _write_fitness_habits
  _plant_fitness_lib_multi
  HABITS track --date 2026-06-15 >/dev/null    # Monday → Gym is due
  run HABITS fitness-reconcile --activity "Apple Fitness+ Kickboxing + Strength" --date 2026-06-15
  [ "$status" -eq 0 ]
  [[ "$output" == "RECONCILED chosen=Apple Fitness"* ]]
  # Gym (scheduled Monday, not chosen) → auto-skipped
  [ "$(_ev gym 2026-06-15)" = "0|skipped" ]
  # Meditation (floating, no fixed schedule) is NEVER auto-skipped
  [ "$(_ev meditation 2026-06-15)" = "NONE" ]
}

@test "fitness-reconcile: unresolvable activity → NO_MATCH, nothing skipped" {
  _write_fitness_habits
  _plant_fitness_lib_multi
  HABITS track --date 2026-06-15 >/dev/null
  run HABITS fitness-reconcile --activity "Underwater Basket Weaving" --date 2026-06-15
  [ "$status" -eq 0 ]
  [[ "$output" == NO_MATCH* ]]
  [ "$(_ev gym 2026-06-15)" = "NONE" ]
}

@test "fitness-reconcile: idempotent on a second run" {
  _write_fitness_habits
  _plant_fitness_lib_multi
  HABITS track --date 2026-06-15 >/dev/null
  HABITS fitness-reconcile --activity "Apple Fitness+ Kickboxing" --date 2026-06-15 >/dev/null
  run HABITS fitness-reconcile --activity "Apple Fitness+ Kickboxing" --date 2026-06-15
  [ "$status" -eq 0 ]
  [[ "$output" == "RECONCILED chosen=Apple Fitness"* ]]
  [ "$(_ev gym 2026-06-15)" = "0|skipped" ]
}

# ═════════════════════════════════════════════════════════════════════════
# autostatus  (Phase 4)
# ═════════════════════════════════════════════════════════════════════════

@test "autostatus: due build habit with no mark → missed; done/skipped/limit left" {
  _write_fitness_habits
  HABITS track --date 2026-06-15 >/dev/null      # Monday: Gym due, Meditation daily, No smoking daily, Apple Fitness not due
  HABITS mark --id meditation --date 2026-06-15 >/dev/null   # Meditation done
  run HABITS autostatus --date 2026-06-15
  [ "$status" -eq 0 ]
  [[ "$output" == AUTOSTATUS\ missed=* ]]
  [ "$(_ev gym 2026-06-15)" = "0|missed" ]        # due build, unmarked → missed
  [ "$(_ev meditation 2026-06-15)" = "1|done" ]   # done → left
  [ "$(_ev no-smoking 2026-06-15)" = "NONE" ]     # limit habit → never auto-missed
  [ "$(_ev apple-fitness 2026-06-15)" = "NONE" ]  # not due Monday → left
}

@test "autostatus: an already-skipped habit is left skipped (counted, not missed)" {
  _write_fitness_habits
  HABITS track --date 2026-06-15 >/dev/null
  HABITS mark --id gym --date 2026-06-15 --status skipped >/dev/null
  run HABITS autostatus --date 2026-06-15
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped=1"* ]]
  [ "$(_ev gym 2026-06-15)" = "0|skipped" ]
}

@test "autostatus: a flexible weekly-count habit is NOT auto-missed mid-week" {
  _write_flex_weekly
  HABITS track --date 2026-06-15 >/dev/null          # Monday — mid-week, unmarked
  run HABITS autostatus --date 2026-06-15
  [ "$status" -eq 0 ]
  [[ "$output" == *"missed=0"* ]]                    # weekly count, not a daily miss
  [ "$(_ev microneedling 2026-06-15)" = "NONE" ]     # left "not yet", pruned later
}

@test "autostatus: a flexible weekly-count habit short at week-end IS missed once" {
  _write_flex_weekly
  HABITS track --date 2026-06-21 >/dev/null          # Sunday closes the week, 0/2 done
  run HABITS autostatus --date 2026-06-21
  [ "$status" -eq 0 ]
  [[ "$output" == *"missed=1"* ]]
  [ "$(_ev microneedling 2026-06-21)" = "0|missed" ]
}

@test "autostatus: a flexible weekly-count habit that hit target is NOT missed at week-end" {
  _write_flex_weekly
  HABITS track --date 2026-06-15 >/dev/null
  HABITS mark --id microneedling --date 2026-06-15 >/dev/null   # done Mon
  HABITS track --date 2026-06-18 >/dev/null
  HABITS mark --id microneedling --date 2026-06-18 >/dev/null   # done Thu → 2/2 met
  HABITS track --date 2026-06-21 >/dev/null
  run HABITS autostatus --date 2026-06-21                        # Sunday — target already hit
  [ "$status" -eq 0 ]
  [[ "$output" == *"missed=0"* ]]
  [ "$(_ev microneedling 2026-06-21)" = "NONE" ]
}

# ═════════════════════════════════════════════════════════════════════════
# per-activity seeding + activity backfill  (Phase 5)
# ═════════════════════════════════════════════════════════════════════════

@test "seeding: an existing habit gets its activity field backfilled (no duplicate)" {
  cat > "$PBRAIN_HABITS_PROFILE_FILE" <<'EOF'
---
type: habits-profile
---
```json
{"habits":[{"id":"apple-fitness","name":"Apple Fitness","direction":"at_least","schedule":{"type":"weekdays","days":["tue","fri"]},"schedule_type":"weekly","priority":"high"}]}
```
EOF
  _plant_fitness_lib_multi
  run HABITS track --date 2026-06-15
  [ "$status" -eq 0 ]
  # apple-fitness habit now tagged with its activity slug…
  grep -q '"activity": "apple-fitness-kickboxing"' "$PBRAIN_HABITS_PROFILE_FILE"
  # …and there is still exactly ONE apple-fitness habit (no dup created)
  run python3 -c "
import json,re,sys
d=json.loads(re.search(r'\`\`\`json\s*\n(.*?)\`\`\`',open(sys.argv[1]).read(),re.DOTALL).group(1))
print(sum(1 for h in d['habits'] if 'apple fitness' in h['name'].lower()))" "$PBRAIN_HABITS_PROFILE_FILE"
  [ "$output" = "1" ]
}

@test "seeding: a fresh vault gets one per-activity habit, each tagged with activity" {
  cat > "$PBRAIN_HABITS_PROFILE_FILE" <<'EOF'
---
type: habits-profile
---
```json
{"habits":[]}
```
EOF
  _plant_fitness_lib_multi
  run HABITS track --date 2026-06-15
  [ "$status" -eq 0 ]
  grep -q '"id": "gym"' "$PBRAIN_HABITS_PROFILE_FILE"
  grep -q '"activity": "gym"' "$PBRAIN_HABITS_PROFILE_FILE"
  grep -q '"activity": "meditation"' "$PBRAIN_HABITS_PROFILE_FILE"
}

# --- PB-42 regression: the ride-along extractor must not be O(n^2) ---------
# pbrain_emit_habits_extract runs on EVERY pbrain command. Its emptiness guard
# used `${json//[[:space:]]/}`, a global pattern substitution that is O(n^2) in
# bash 3.2: on a ~16KB habits profile it took ~20s PER command. The fix is the
# O(n) regex test `[[ $json =~ [^[:space:]] ]]`. This test builds a large but
# valid profile and asserts the extractor finishes well under a budget the old
# idiom could never meet (it would take minutes on this input).
@test "PB-42: emit_habits_extract stays fast on a large profile (no O(n^2) whitespace strip)" {
  python3 - "$PBRAIN_HABITS_PROFILE_FILE" <<'PY'
import json, sys
habits = []
for i in range(400):
    habits.append({
        "name": "Habit number %d with a reasonably long descriptive name" % i,
        "id": "habit-%d" % i,
        "kind": "build", "direction": "at_least",
        "schedule_type": "daily", "target_count": 1,
        "priority": "medium", "archived": False,
        "notes": "padding notes for realistic size " * 6,
    })
data = {"habits": habits}
body = "---\ntype: habits-profile\n---\n```json\n" + json.dumps(data, indent=2) + "\n```\n"
open(sys.argv[1], "w").write(body)
PY
  pbrain_db_init >/dev/null 2>&1 || true
  bytes="$(wc -c < "$PBRAIN_HABITS_PROFILE_FILE" | tr -d ' ')"
  start="$(date +%s)"
  pbrain_emit_habits_extract habits >/dev/null 2>&1 || true
  elapsed="$(( $(date +%s) - start ))"
  # Profile is genuinely large (>40KB) AND the emitter finished in well under
  # the budget. The old O(n^2) idiom took minutes on this size; new code <1s.
  [ "$bytes" -gt 40000 ] && [ "$elapsed" -lt 8 ]
}

# --- reminders-sync arg-parsing guards (PB-43) -----------------------------
# reminders-sync must parse --date/--sweep order-independently and fail LOUDLY
# on a missing/flag-shaped/unparseable date — a wrong-day --sweep DELETES that
# day's reminders, so a silent default is dangerous.

@test "reminders-sync: --date swallowing the next flag fails loudly (exit 2)" {
  run HABITS reminders-sync --date --sweep
  [ "$status" -eq 2 ] && [[ "$output" == *"requires a YYYY-MM-DD value"* ]]
}

@test "reminders-sync: a bare trailing --date fails loudly (exit 2)" {
  run HABITS reminders-sync --date
  [ "$status" -eq 2 ] && [[ "$output" == *"requires a YYYY-MM-DD value"* ]]
}

@test "reminders-sync: an unparseable date fails loudly, never defaults (exit 2)" {
  run HABITS reminders-sync --date 2026-13-99
  [ "$status" -eq 2 ] && [[ "$output" == *"invalid date"* ]]
}

@test "reminders-sync: a valid --date passes the guard regardless of flag order" {
  # No profile file => the subcommand exits 0 right after the guard; both
  # orderings must clear the guard (status 0, no guard error on stderr).
  run HABITS reminders-sync --sweep --date 2026-06-19
  [ "$status" -eq 0 ] && [[ "$output" != *"invalid date"* ]]
}
