#!/usr/bin/env bats
# Tests for lib/db.sh — the shared SQLite store (pbrain_db_init).
#
# db.sh is sourced into every command via lib/vault.sh, so — like the other
# lib helpers — it must never exit non-zero under `set -euo pipefail`, and its
# schema creation must be idempotent.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_DB_FILE="$TMP/pbrain.db"
  source "$REPO_ROOT/lib/db.sh"
}

teardown() {
  rm -rf "$TMP"
}

@test "pbrain_db_file echoes the resolved path" {
  run pbrain_db_file
  [ "$status" -eq 0 ]
  [ "$output" = "$PBRAIN_DB_FILE" ]
}

@test "db_init creates the DB with both tables" {
  run pbrain_db_init
  [ "$status" -eq 0 ]
  [ -f "$PBRAIN_DB_FILE" ]
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); t={r[0] for r in c.execute(\"select name from sqlite_master where type='table'\")}; assert {'habit_events','reminders'} <= t, t" "$PBRAIN_DB_FILE"
  [ "$status" -eq 0 ]
}

@test "db_init is idempotent and preserves data" {
  pbrain_db_init
  python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(\"insert into reminders(text,status,created_at) values('x','pending','2026-01-01 00:00')\"); c.commit()" "$PBRAIN_DB_FILE"
  run pbrain_db_init
  [ "$status" -eq 0 ]
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute('select count(*) from reminders').fetchone()[0])" "$PBRAIN_DB_FILE"
  [ "$output" = "1" ]
}

@test "habit_events enforces one row per (habit_id, day)" {
  pbrain_db_init
  run python3 - "$PBRAIN_DB_FILE" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("insert into habit_events(habit_id,habit,occurred_on,count,source,created_at) values('meditate','Meditate','2026-06-03',1,'a','t')")
try:
    # same habit_id + day => conflict, even if the display name changed
    c.execute("insert into habit_events(habit_id,habit,occurred_on,count,source,created_at) values('meditate','Morning sit','2026-06-03',1,'b','t')")
    print("NO_CONFLICT")
except sqlite3.IntegrityError:
    print("CONFLICT_OK")
PY
  [ "$output" = "CONFLICT_OK" ]
}

@test "fresh DB has habit_id column and the (habit_id, day) unique index" {
  pbrain_db_init
  run python3 - "$PBRAIN_DB_FILE" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
cols = {r[1] for r in c.execute("PRAGMA table_info(habit_events)")}
assert "habit_id" in cols, cols
# the unique index must cover (habit_id, occurred_on)
idx = c.execute("PRAGMA index_info(idx_habit_events_uniq)").fetchall()
names = [r[2] for r in idx]
assert names == ["habit_id", "occurred_on"], names
print("OK")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# --- migration: old-shape DB (no habit_id, unique on habit) -> habit_id key ---
_make_old_db() {  # builds a pre-redesign habit_events table with rows
  python3 - "$PBRAIN_DB_FILE" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript("""
CREATE TABLE habit_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  habit TEXT NOT NULL,
  occurred_on TEXT NOT NULL,
  count INTEGER NOT NULL DEFAULT 1,
  source TEXT NOT NULL DEFAULT '',
  note TEXT,
  created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX idx_habit_events_uniq ON habit_events(habit, occurred_on);
""")
c.execute("insert into habit_events(habit,occurred_on,count,source,created_at) values('Meditate','2026-06-01',1,'j','t')")
c.execute("insert into habit_events(habit,occurred_on,count,source,created_at) values('Meditate','2026-06-02',1,'j','t')")
c.execute("insert into habit_events(habit,occurred_on,count,source,created_at) values('Long Run','2026-06-01',1,'f','t')")
c.commit()
PY
}

@test "migration backfills habit_id from the name and re-keys the unique index" {
  _make_old_db
  run pbrain_db_init
  [ "$status" -eq 0 ]
  run python3 - "$PBRAIN_DB_FILE" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
cols = {r[1] for r in c.execute("PRAGMA table_info(habit_events)")}
assert "habit_id" in cols, cols
# all rows backfilled, slug matches the canonical algorithm
rows = dict(c.execute("select habit, habit_id from habit_events").fetchall())
assert rows["Meditate"] == "meditate", rows
assert rows["Long Run"] == "long-run", rows
# unique index now on (habit_id, occurred_on)
names = [r[2] for r in c.execute("PRAGMA index_info(idx_habit_events_uniq)")]
assert names == ["habit_id", "occurred_on"], names
# data preserved (3 rows)
assert c.execute("select count(*) from habit_events").fetchone()[0] == 3
print("OK")
PY
  [ "$output" = "OK" ]
}

@test "migration is idempotent — second run is a no-op and preserves data" {
  _make_old_db
  pbrain_db_init
  run pbrain_db_init
  [ "$status" -eq 0 ]
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute('select count(*) from habit_events').fetchone()[0])" "$PBRAIN_DB_FILE"
  [ "$output" = "3" ]
}

@test "migration collapses (habit_id, day) collisions to one row" {
  # 'Walk' and 'walk!' both slugify to 'walk' on the same day -> one survives.
  python3 - "$PBRAIN_DB_FILE" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript("""
CREATE TABLE habit_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, habit TEXT NOT NULL, occurred_on TEXT NOT NULL,
  count INTEGER NOT NULL DEFAULT 1, source TEXT NOT NULL DEFAULT '', note TEXT, created_at TEXT NOT NULL);
""")
c.execute("insert into habit_events(habit,occurred_on,count,source,created_at) values('Walk','2026-06-01',1,'a','t')")
c.execute("insert into habit_events(habit,occurred_on,count,source,created_at) values('walk!','2026-06-01',1,'b','t')")
c.commit()
PY
  run pbrain_db_init
  [ "$status" -eq 0 ]
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute(\"select count(*) from habit_events where habit_id='walk' and occurred_on='2026-06-01'\").fetchone()[0])" "$PBRAIN_DB_FILE"
  [ "$output" = "1" ]
}

@test "db_init never exits non-zero even when the path is unwritable" {
  touch "$TMP/afile"
  run pbrain_db_init "$TMP/afile/cannot/make.db"
  [ "$status" -eq 0 ]
}
