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

@test "habit_events enforces one row per (habit, day)" {
  pbrain_db_init
  run python3 - "$PBRAIN_DB_FILE" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("insert into habit_events(habit,occurred_on,count,source,created_at) values('Meditate','2026-06-03',1,'a','t')")
try:
    c.execute("insert into habit_events(habit,occurred_on,count,source,created_at) values('Meditate','2026-06-03',1,'b','t')")
    print("NO_CONFLICT")
except sqlite3.IntegrityError:
    print("CONFLICT_OK")
PY
  [ "$output" = "CONFLICT_OK" ]
}

@test "db_init never exits non-zero even when the path is unwritable" {
  touch "$TMP/afile"
  run pbrain_db_init "$TMP/afile/cannot/make.db"
  [ "$status" -eq 0 ]
}
