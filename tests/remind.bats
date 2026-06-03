#!/usr/bin/env bats
# Tests for commands/remind.sh — the command-level SQL mutations (add / list /
# done / cancel / clear). These are the only reminder write paths not covered by
# reminders.bats (which exercises the lib-level notify / pending-text / tick).
#
# osascript is stubbed so `add`'s confirmation notification never fires for real.
# A temp vault + PBRAIN_SELF_IMPROVE=off keep the command harness self-contained.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_DB_FILE="$TMP/pbrain.db"
  export PBRAIN_VAULT="$TMP/vault"; mkdir -p "$PBRAIN_VAULT"
  export PBRAIN_SELF_IMPROVE=off
  NOTIFS="$TMP/notifs.log"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/osascript" <<EOF
#!/bin/sh
echo fired >> "$NOTIFS"
exit 0
EOF
  chmod +x "$TMP/bin/osascript"
  export PATH="$TMP/bin:$PATH"
}

teardown() {
  rm -rf "$TMP"
}

_remind() { bash "$REPO_ROOT/commands/remind.sh" "$@"; }

_col() {  # _col <id> <column> -> prints value (or 'NULL')
  python3 - "$PBRAIN_DB_FILE" "$1" "$2" <<'PY'
import sqlite3, sys
db, rid, col = sys.argv[1], sys.argv[2], sys.argv[3]
assert col in {"status", "due_at", "repeat", "text", "fired_at"}, col
c = sqlite3.connect(db)
row = c.execute("select " + col + " from reminders where id=?", (rid,)).fetchone()
print(row[0] if row and row[0] is not None else "NULL")
PY
}

@test "add inserts a pending reminder and echoes its id" {
  run _remind add --text "call dentist" --due "2030-01-01 09:00"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMIND_ADDED id=1"* ]]
  run _col 1 status
  [ "$output" = "pending" ]
  run _col 1 text
  [ "$output" = "call dentist" ]
  run _col 1 due_at
  [ "$output" = "2030-01-01 09:00" ]
}

@test "add without --text exits non-zero and writes nothing" {
  run _remind add --due "2030-01-01 09:00"
  [ "$status" -ne 0 ]
  run python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute('select count(*) from reminders').fetchone()[0])" "$PBRAIN_DB_FILE"
  [ "$output" = "0" ]
}

@test "add normalises an unknown --repeat to NULL but keeps a valid one" {
  _remind add --text "garbage repeat" --repeat hourly
  _remind add --text "good repeat" --repeat weekly
  run _col 1 repeat
  [ "$output" = "NULL" ]
  run _col 2 repeat
  [ "$output" = "weekly" ]
}

@test "add rejects an unparseable --due and writes nothing" {
  run _remind add --text "bad date" --due "next friday"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--due must be"* ]]
  run python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute('select count(*) from reminders').fetchone()[0])" "$PBRAIN_DB_FILE"
  [ "$output" = "0" ]
}

@test "add rejects an out-of-range time in --due" {
  run _remind add --text "impossible time" --due "2030-01-01 25:99"
  [ "$status" -ne 0 ]
  run python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute('select count(*) from reminders').fetchone()[0])" "$PBRAIN_DB_FILE"
  [ "$output" = "0" ]
}

@test "add accepts a date-only --due" {
  run _remind add --text "date only" --due "2030-09-09"
  [ "$status" -eq 0 ]
  run _col 1 due_at
  [ "$output" = "2030-09-09" ]
}

@test "add with no --due stores someday (NULL due)" {
  _remind add --text "someday thing"
  run _col 1 due_at
  [ "$output" = "NULL" ]
}

@test "list shows a pending reminder and reports empty otherwise" {
  run _remind list
  [ "$status" -eq 0 ]
  [[ "$output" == *"no pending reminders"* ]]
  _remind add --text "buy milk" --due "2030-02-02 10:00"
  run _remind list
  [[ "$output" == *"buy milk"* ]]
}

@test "done marks a pending reminder done; second time is a no-op" {
  _remind add --text "ship it" --due "2030-03-03 12:00"
  run _remind done 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Marked done: #1"* ]]
  run _col 1 status
  [ "$output" = "done" ]
  # Already done — no longer pending, so a repeat done reports no match.
  run _remind done 1
  [[ "$output" == *"No matching pending reminders"* ]]
}

@test "cancel marks a pending reminder cancelled" {
  _remind add --text "skip this" --due "2030-04-04 12:00"
  run _remind cancel 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Marked cancelled: #1"* ]]
  run _col 1 status
  [ "$output" = "cancelled" ]
}

@test "done requires at least one id" {
  run _remind done
  [ "$status" -ne 0 ]
}

@test "done skips non-integer ids without erroring" {
  _remind add --text "real one" --due "2030-05-05 12:00"
  run _remind done abc 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Marked done: #1"* ]]
}

@test "clear without --yes refuses and leaves reminders pending" {
  _remind add --text "keep me" --due "2030-06-06 12:00"
  run _remind clear
  [ "$status" -ne 0 ]
  run _col 1 status
  [ "$output" = "pending" ]
}

@test "clear --yes cancels all pending reminders" {
  _remind add --text "one" --due "2030-07-07 12:00"
  _remind add --text "two" --due "2030-08-08 12:00"
  run _remind clear --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cancelled 2 pending reminder(s)"* ]]
  run _col 1 status
  [ "$output" = "cancelled" ]
  run _col 2 status
  [ "$output" = "cancelled" ]
}
