#!/usr/bin/env bats
# Tests for lib/reminders.sh — notify / pending-text / tick.
#
# osascript is stubbed (a fake on PATH that logs instead of displaying) so the
# suite never fires real macOS notifications and can count how many fired.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_DB_FILE="$TMP/pbrain.db"
  # Isolate the notifier-app build location away from the real ~/.config.
  export PBRAIN_NOTIFY_APP="$TMP/pbrain-notify.app"
  NOTIFS="$TMP/notifs.log"
  mkdir -p "$TMP/bin"
  # Fake osascript: record one line per fire, never display anything.
  cat > "$TMP/bin/osascript" <<EOF
#!/bin/sh
echo fired >> "$NOTIFS"
exit 0
EOF
  chmod +x "$TMP/bin/osascript"
  # Stub swiftc to a no-op so pbrain_notify never compiles/runs the real bundled
  # notifier in tests (which would fire actual notifications and bypass the fake
  # osascript these tests count). Producing no -o output leaves the app unbuilt,
  # so pbrain_notify falls back to osascript. The real-build test removes this.
  cat > "$TMP/bin/swiftc" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$TMP/bin/swiftc"
  export PATH="$TMP/bin:$PATH"
  source "$REPO_ROOT/lib/db.sh"
  source "$REPO_ROOT/lib/reminders.sh"
  pbrain_db_init
}

teardown() {
  rm -rf "$TMP"
}

# Insert a reminder; echoes nothing. Args: text due repeat
_add() {
  python3 - "$PBRAIN_DB_FILE" "$1" "$2" "$3" <<'PY'
import sqlite3, sys
db, text, due, repeat = sys.argv[1:5]
due = due or None
repeat = repeat or None
c = sqlite3.connect(db)
c.execute("insert into reminders(text,due_at,repeat,status,created_at) values(?,?,?, 'pending','2026-01-01 00:00')",
          (text, due, repeat))
c.commit()
PY
}

_col() {  # _col <id> <column> -> prints value (or 'NULL')
  python3 - "$PBRAIN_DB_FILE" "$1" "$2" <<'PY'
import sqlite3, sys
db, rid, col = sys.argv[1], sys.argv[2], sys.argv[3]
# col is a test-internal literal (fired_at/status/due_at), not user input.
assert col in {"fired_at", "status", "due_at", "text", "repeat"}, col
c = sqlite3.connect(db)
row = c.execute("select " + col + " from reminders where id=?", (rid,)).fetchone()
print(row[0] if row and row[0] is not None else "NULL")
PY
}

@test "pbrain_notify returns 0 even with quotes/backslashes in the text" {
  run pbrain_notify "Title" 'weird "quoted" \ text'
  [ "$status" -eq 0 ]
}

@test "pending_text is empty when there are no reminders" {
  run pbrain_reminders_pending_text
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pending_text marks an overdue reminder OVERDUE" {
  _add "call dentist" "2000-01-01 09:00" ""
  run pbrain_reminders_pending_text
  [ "$status" -eq 0 ]
  [[ "$output" == *"call dentist"* ]]
  [[ "$output" == *"OVERDUE"* ]]
}

@test "tick fires a due one-shot exactly once and stamps fired_at" {
  _add "pay rent" "2000-01-01 09:00" ""
  pbrain_reminders_tick
  [ -f "$NOTIFS" ]
  [ "$(wc -l < "$NOTIFS" | tr -d ' ')" = "1" ]
  run _col 1 fired_at
  [ "$output" != "NULL" ]
  # second tick must not re-fire
  pbrain_reminders_tick
  [ "$(wc -l < "$NOTIFS" | tr -d ' ')" = "1" ]
}

@test "tick rolls a long-overdue repeat to a FUTURE occurrence and fires once" {
  # 26-year-overdue daily reminder: must fire exactly ONCE (catch-up), not one
  # ping per missed cycle, and land on a genuinely future occurrence.
  _add "vitamins" "2000-01-01 08:00" "daily"
  pbrain_reminders_tick
  [ "$(wc -l < "$NOTIFS" | tr -d ' ')" = "1" ]
  run _col 1 status
  [ "$output" = "pending" ]
  run _col 1 fired_at
  [ "$output" = "NULL" ]
  run python3 -c "import sqlite3,datetime,sys; c=sqlite3.connect(sys.argv[1]); d=c.execute('select due_at from reminders where id=1').fetchone()[0]; dt=datetime.datetime.strptime(d,'%Y-%m-%d %H:%M'); print('FUTURE' if dt>datetime.datetime.now() else 'PAST')" "$PBRAIN_DB_FILE"
  [ "$output" = "FUTURE" ]
  # a second tick must not re-fire — it's now in the future
  pbrain_reminders_tick
  [ "$(wc -l < "$NOTIFS" | tr -d ' ')" = "1" ]
}

@test "tick fires a past date-only reminder but not a future-dated one" {
  _add "past day" "2000-06-01" ""
  _add "next century" "2099-06-01" ""
  pbrain_reminders_tick
  [ "$(wc -l < "$NOTIFS" | tr -d ' ')" = "1" ]
}

@test "tick is a no-op (returns 0) when the DB has no due reminders" {
  _add "future thing" "2099-01-01 08:00" ""
  run pbrain_reminders_tick
  [ "$status" -eq 0 ]
  [ ! -f "$NOTIFS" ]
}

# Roll-forward must land strictly in the future and fire exactly once for every
# repeat kind, not just daily. A bug in the weekly/monthly arithmetic or the
# weekdays loop would leave due_at in the past (re-fires) or skip too far.
_is_future() {  # _is_future <id> -> "FUTURE" or "PAST"
  python3 - "$PBRAIN_DB_FILE" "$1" <<'PY'
import sqlite3, sys, datetime
db, rid = sys.argv[1], sys.argv[2]
d = sqlite3.connect(db).execute("select due_at from reminders where id=?", (rid,)).fetchone()[0]
try:
    dt = datetime.datetime.strptime(d, "%Y-%m-%d %H:%M")
except ValueError:
    dt = datetime.datetime.strptime(d, "%Y-%m-%d").replace(hour=9)
print("FUTURE" if dt > datetime.datetime.now() else "PAST")
PY
}

@test "tick rolls a long-overdue WEEKLY repeat to a future occurrence, fires once" {
  _add "weekly review" "2000-01-01 08:00" "weekly"
  pbrain_reminders_tick
  [ "$(wc -l < "$NOTIFS" | tr -d ' ')" = "1" ]
  run _is_future 1
  [ "$output" = "FUTURE" ]
  pbrain_reminders_tick
  [ "$(wc -l < "$NOTIFS" | tr -d ' ')" = "1" ]
}

@test "tick rolls a long-overdue MONTHLY repeat to a future occurrence, fires once" {
  _add "pay invoice" "2000-01-15 08:00" "monthly"
  pbrain_reminders_tick
  [ "$(wc -l < "$NOTIFS" | tr -d ' ')" = "1" ]
  run _is_future 1
  [ "$output" = "FUTURE" ]
  pbrain_reminders_tick
  [ "$(wc -l < "$NOTIFS" | tr -d ' ')" = "1" ]
}

@test "tick rolls a WEEKDAYS repeat forward and lands on a weekday" {
  _add "standup" "2000-01-03 08:00" "weekdays"
  pbrain_reminders_tick
  [ "$(wc -l < "$NOTIFS" | tr -d ' ')" = "1" ]
  run _is_future 1
  [ "$output" = "FUTURE" ]
  # next occurrence must be Mon-Fri (weekday() 0..4)
  run python3 -c "import sqlite3,datetime,sys; d=sqlite3.connect(sys.argv[1]).execute('select due_at from reminders where id=1').fetchone()[0]; print(datetime.datetime.strptime(d,'%Y-%m-%d %H:%M').weekday())" "$PBRAIN_DB_FILE"
  [ "$output" -lt 5 ]
}

@test "pending_text tags someday / future days and shows the repeat suffix" {
  _add "no date item" "" "weekly"
  _add "far future" "2099-12-31 10:00" ""
  run pbrain_reminders_pending_text
  [ "$status" -eq 0 ]
  [[ "$output" == *"someday"* ]]
  [[ "$output" == *"(repeats weekly)"* ]]
  [[ "$output" == *"far future"* ]]
  [[ "$output" == *"days)"* ]]
}

@test "pending_text relabels a fired one-shot as 'fired', not OVERDUE" {
  # Regression: a one-shot that already fired (fired_at set) but isn't marked
  # done used to keep reading as OVERDUE forever. It should now read as 'fired'.
  _add "submit the form" "2000-01-01 09:00" ""
  pbrain_reminders_tick           # fires it once, stamps fired_at
  run _col 1 fired_at
  [ "$output" != "NULL" ]
  run pbrain_reminders_pending_text
  [ "$status" -eq 0 ]
  [[ "$output" == *"submit the form"* ]]
  [[ "$output" == *"fired"* ]]
  [[ "$output" != *"OVERDUE"* ]]
}

@test "pbrain_notify falls back to osascript when the bundled app isn't built" {
  # With swiftc stubbed to a no-op, no binary is produced, so pbrain_notify must
  # fall back to osascript (the fake records one fire).
  run pbrain_notify "Title" "body text"
  [ "$status" -eq 0 ]
  [ -f "$NOTIFS" ]
  [ "$(wc -l < "$NOTIFS" | tr -d ' ')" = "1" ]
  # No binary should have been built by the no-op swiftc stub.
  [ ! -x "$PBRAIN_NOTIFY_APP/Contents/MacOS/pbrain-notify" ]
}

@test "pbrain_notify_build compiles pbrain-notify.app when swiftc is available" {
  rm -f "$TMP/bin/swiftc"        # drop the stub → use the real swiftc, if present
  command -v swiftc >/dev/null 2>&1 || skip "swiftc not installed"
  pbrain_notify_build
  [ -x "$PBRAIN_NOTIFY_APP/Contents/MacOS/pbrain-notify" ]
  [ -f "$PBRAIN_NOTIFY_APP/Contents/Info.plist" ]
  # Re-running is a no-op (binary now at least as new as the source); still there.
  pbrain_notify_build
  [ -x "$PBRAIN_NOTIFY_APP/Contents/MacOS/pbrain-notify" ]
}
