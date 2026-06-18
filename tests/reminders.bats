#!/usr/bin/env bats
# Tests for lib/reminders.sh — the blocking-overlay tick (fire / defer / miss /
# advance) over the schedule + instance model, plus the notify/overlay helpers.
#
# The overlay launcher (pbrain_overlay_show) is stubbed per-test to LOG instead
# of popping a real full-screen window, so the suite can assert what fired.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_DB_FILE="$TMP/pbrain.db"
  export PBRAIN_NOTIFY_APP="$TMP/pbrain-notify.app"
  export PBRAIN_OVERLAY_APP="$TMP/pbrain-overlay.app"
  NOTIFS="$TMP/notifs.log"
  mkdir -p "$TMP/bin"
  # Fake osascript: record one line per fire, never display anything.
  cat > "$TMP/bin/osascript" <<EOF
#!/bin/sh
echo fired >> "$NOTIFS"
exit 0
EOF
  chmod +x "$TMP/bin/osascript"
  # Stub swiftc to a no-op so helpers never compile/run the real bundled apps.
  cat > "$TMP/bin/swiftc" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$TMP/bin/swiftc"
  # Default pgrep stub: report NO overlay running, so the fire-path tests are
  # immune to a REAL pbrain-overlay being up on the host (the user's actual
  # break reminder would otherwise make the tick defer and flake these tests).
  # The overlay-busy test overwrites this stub with one that reports busy.
  cat > "$TMP/bin/pgrep" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$TMP/bin/pgrep"
  export PATH="$TMP/bin:$PATH"
  # Default the screen to UNLOCKED so the tick fires (override per-test).
  export PBRAIN_SCREEN_LOCKED=0
  source "$REPO_ROOT/lib/db.sh"
  source "$REPO_ROOT/lib/reminders.sh"
  pbrain_db_init
}

teardown() { rm -rf "$TMP"; }

# A time string N minutes from now, in the tick's 'YYYY-MM-DD HH:MM' format.
_mins() { date -v"$1"M '+%Y-%m-%d %H:%M'; }

# Insert a one-shot blocking occurrence (schedule_id NULL). Args: text due block hold
_add_oneshot() {
  python3 - "$PBRAIN_DB_FILE" "$1" "$2" "$3" "$4" <<'PY'
import sqlite3, sys
db, text, due, block, hold = sys.argv[1:6]
c = sqlite3.connect(db)
c.execute("insert into reminders(schedule_id,text,due_at,block_seconds,hold_seconds,status,source,created_at) "
          "values(NULL,?,?,?,?, 'pending','test','2026-01-01 00:00')",
          (text, due, int(block), int(hold)))
c.commit()
PY
}

# Insert a recurring series + its first pending occurrence.
# Args: text cron block hold first_due  -> echoes "<schedule_id> <instance_id>"
_add_series() {
  python3 - "$PBRAIN_DB_FILE" "$1" "$2" "$3" "$4" "$5" <<'PY'
import sqlite3, sys
db, text, cron, block, hold, due = sys.argv[1:7]
c = sqlite3.connect(db)
sid = c.execute("insert into reminder_schedules(text,cron,block_seconds,hold_seconds,status,next_due_at,source,created_at) "
                "values(?,?,?,?, 'active', ?, 'test','2026-01-01 00:00')",
                (text, cron, int(block), int(hold), due)).lastrowid
rid = c.execute("insert into reminders(schedule_id,text,due_at,block_seconds,hold_seconds,status,source,created_at) "
                "values(?,?,?,?,?, 'pending','test','2026-01-01 00:00')",
                (sid, text, due, int(block), int(hold))).lastrowid
c.commit()
print(sid, rid)
PY
}

_col() {  # _col <id> <column> -> reminders column value (or 'NULL')
  python3 - "$PBRAIN_DB_FILE" "$1" "$2" <<'PY'
import sqlite3, sys
db, rid, col = sys.argv[1], sys.argv[2], sys.argv[3]
assert col in {"fired_at", "resolved_at", "status", "due_at", "text", "schedule_id"}, col
c = sqlite3.connect(db)
row = c.execute("select " + col + " from reminders where id=?", (rid,)).fetchone()
print(row[0] if row and row[0] is not None else "NULL")
PY
}

_scol() {  # _scol <schedule_id> <column> -> reminder_schedules column value
  python3 - "$PBRAIN_DB_FILE" "$1" "$2" <<'PY'
import sqlite3, sys
db, sid, col = sys.argv[1], sys.argv[2], sys.argv[3]
assert col in {"status", "next_due_at", "cron"}, col
c = sqlite3.connect(db)
row = c.execute("select " + col + " from reminder_schedules where id=?", (sid,)).fetchone()
print(row[0] if row and row[0] is not None else "NULL")
PY
}

_count() {  # _count <where> -> number of reminders rows matching
  python3 - "$PBRAIN_DB_FILE" "$1" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute("select count(*) from reminders where " + sys.argv[2]).fetchone()[0])
PY
}

# ---------------------------------------------------------------------------
# One-shots
# ---------------------------------------------------------------------------

@test "one-shot due within the grace window fires exactly once (overlay, fired_at stamped)" {
  LOG="$TMP/ov.log"
  pbrain_overlay_show() { echo "$1|secs=$2|hold=$3|id=$5" >> "$LOG"; }
  _add_oneshot "Stand up" "$(_mins -2)" 120 5
  pbrain_reminders_tick
  [ "$(wc -l < "$LOG" | tr -d ' ')" = "1" ]
  [ "$(cat "$LOG")" = "Stand up|secs=120|hold=5|id=1" ]
  run _col 1 status;   [ "$output" = "pending" ]   # overlay resolves it, not the tick
  run _col 1 fired_at; [ "$output" != "NULL" ]
  # Already fired → a second tick does not re-fire it.
  pbrain_reminders_tick
  [ "$(wc -l < "$LOG" | tr -d ' ')" = "1" ]
}

@test "one-shot overdue beyond grace is MISSED, not fired (no overlay)" {
  LOG="$TMP/ov.log"
  pbrain_overlay_show() { echo "$1" >> "$LOG"; }
  _add_oneshot "Old break" "$(_mins -30)" 120 5    # 30 min ago > 10 min grace
  pbrain_reminders_tick
  [ ! -f "$LOG" ]
  run _col 1 status;      [ "$output" = "missed" ]
  run _col 1 resolved_at; [ "$output" != "NULL" ]
  run _col 1 fired_at;    [ "$output" = "NULL" ]
}

@test "PBRAIN_REMIND_GRACE_SECONDS widens the miss threshold" {
  LOG="$TMP/ov.log"
  pbrain_overlay_show() { echo "$1" >> "$LOG"; }
  _add_oneshot "Break" "$(_mins -30)" 120 5
  # 30 min overdue is within a 1-hour grace → fires instead of missing.
  PBRAIN_REMIND_GRACE_SECONDS=3600 pbrain_reminders_tick
  [ "$(cat "$LOG")" = "Break" ]
  run _col 1 fired_at; [ "$output" != "NULL" ]
}

@test "locked screen DEFERS a within-grace one-shot (no fire, no miss); unlock then fires" {
  LOG="$TMP/ov.log"
  pbrain_overlay_show() { echo "$1" >> "$LOG"; }
  _add_oneshot "Break" "$(_mins -2)" 120 5
  PBRAIN_SCREEN_LOCKED=1 pbrain_reminders_tick
  [ ! -f "$LOG" ]
  run _col 1 status;   [ "$output" = "pending" ]
  run _col 1 fired_at; [ "$output" = "NULL" ]
  PBRAIN_SCREEN_LOCKED=0 pbrain_reminders_tick
  [ "$(cat "$LOG")" = "Break" ]
}

@test "locked screen still MISSES an over-grace one-shot (reconciles even while locked)" {
  LOG="$TMP/ov.log"
  pbrain_overlay_show() { echo "$1" >> "$LOG"; }
  _add_oneshot "Stale" "$(_mins -30)" 120 5
  PBRAIN_SCREEN_LOCKED=1 pbrain_reminders_tick
  [ ! -f "$LOG" ]
  run _col 1 status; [ "$output" = "missed" ]
}

@test "a future one-shot does not fire" {
  LOG="$TMP/ov.log"
  pbrain_overlay_show() { echo "$1" >> "$LOG"; }
  _add_oneshot "Later" "$(_mins +30)" 120 5
  pbrain_reminders_tick
  [ ! -f "$LOG" ]
  run _col 1 fired_at; [ "$output" = "NULL" ]
}

# ---------------------------------------------------------------------------
# Series (recurring) — the chain must survive missed/locked fires
# ---------------------------------------------------------------------------

@test "series fires within grace AND advances: next instance + next_due_at" {
  LOG="$TMP/ov.log"
  pbrain_overlay_show() { echo "$1|id=$5" >> "$LOG"; }
  RAW="$(_add_series 'Stretch' '*/30 * * * *' 120 5 "$(_mins -2)")"
  sid="${RAW%% *}"; rid="${RAW##* }"
  pbrain_reminders_tick
  # Fired the current occurrence...
  [ "$(cat "$LOG")" = "Stretch|id=$rid" ]
  run _col "$rid" fired_at; [ "$output" != "NULL" ]
  # ...and materialised the NEXT occurrence + advanced the schedule cache.
  [ "$(_count "schedule_id=$sid AND status='pending' AND fired_at IS NULL")" = "1" ]
  run _scol "$sid" next_due_at; [ "$output" != "$(_col "$rid" due_at)" ]
  run _scol "$sid" status;      [ "$output" = "active" ]
}

@test "series occurrence overdue beyond grace is MISSED but STILL advances the series" {
  LOG="$TMP/ov.log"
  pbrain_overlay_show() { echo "$1" >> "$LOG"; }
  RAW="$(_add_series 'Stretch' '*/30 * * * *' 120 5 "$(_mins -45)")"
  sid="${RAW%% *}"; rid="${RAW##* }"
  pbrain_reminders_tick
  [ ! -f "$LOG" ]                                    # nothing shown (too stale)
  run _col "$rid" status; [ "$output" = "missed" ]   # this occurrence reconciled
  # The chain did NOT die: a fresh future occurrence exists.
  [ "$(_count "schedule_id=$sid AND status='pending' AND fired_at IS NULL")" = "1" ]
  run _scol "$sid" status; [ "$output" = "active" ]
}

@test "cancelled series' pending occurrence is never fired" {
  LOG="$TMP/ov.log"
  pbrain_overlay_show() { echo "$1" >> "$LOG"; }
  RAW="$(_add_series 'Stretch' '*/30 * * * *' 120 5 "$(_mins -2)")"
  sid="${RAW%% *}"; rid="${RAW##* }"
  python3 -c "import sqlite3;c=sqlite3.connect('$PBRAIN_DB_FILE');c.execute(\"update reminder_schedules set status='cancelled' where id=$sid\");c.commit()"
  pbrain_reminders_tick
  [ ! -f "$LOG" ]
  run _col "$rid" fired_at; [ "$output" = "NULL" ]
}

# ---------------------------------------------------------------------------
# Serialization: at most one overlay per tick
# ---------------------------------------------------------------------------

@test "at most ONE overlay fires per tick; the rest defer to a later tick" {
  LOG="$TMP/ov.log"
  pbrain_overlay_show() { echo "$1" >> "$LOG"; }
  _add_oneshot "A break" "$(_mins -3)" 120 5    # earlier due → wins the slot
  _add_oneshot "B break" "$(_mins -1)" 120 5
  pbrain_reminders_tick
  [ "$(wc -l < "$LOG" | tr -d ' ')" = "1" ]
  [ "$(cat "$LOG")" = "A break" ]
  run _col 2 fired_at; [ "$output" = "NULL" ]   # B deferred, still eligible
  pbrain_reminders_tick
  [ "$(wc -l < "$LOG" | tr -d ' ')" = "2" ]
}

@test "an overlay already on screen (pgrep busy) defers ALL fires this tick" {
  LOG="$TMP/ov.log"
  pbrain_overlay_show() { echo "$1" >> "$LOG"; }
  cat > "$TMP/bin/pgrep" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$TMP/bin/pgrep"
  _add_oneshot "Break" "$(_mins -2)" 120 5
  pbrain_reminders_tick
  [ ! -f "$LOG" ]
  run _col 1 fired_at; [ "$output" = "NULL" ]
  printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/pgrep"; chmod +x "$TMP/bin/pgrep"
  pbrain_reminders_tick
  [ "$(cat "$LOG")" = "Break" ]
}

@test "tick is a no-op (returns 0) when nothing is due" {
  run pbrain_reminders_tick
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Helpers retained for the overlay's no-swiftc degradation path
# ---------------------------------------------------------------------------

@test "pbrain_notify returns 0 even with quotes/backslashes in the text" {
  run pbrain_notify "Title" "weird \" ' \\ \$x text"
  [ "$status" -eq 0 ]
}

@test "pbrain_overlay_show falls back to a notification when the app isn't built" {
  # swiftc is stubbed to a no-op, so the overlay app never builds → notify path.
  run pbrain_overlay_show "Take a break" 0 5
  [ "$status" -eq 0 ]
  [ -f "$NOTIFS" ]
}

@test "pbrain_notify_build compiles pbrain-notify.app when swiftc is available" {
  # Use a REAL swiftc for this test (drop the no-op stub).
  rm -f "$TMP/bin/swiftc"
  if ! command -v swiftc >/dev/null 2>&1; then skip "swiftc not installed"; fi
  pbrain_notify_build
  [ -x "$PBRAIN_NOTIFY_APP/Contents/MacOS/pbrain-notify" ]
}

# ---------------------------------------------------------------------------
# Snooze arg threading (warning-panel "Snooze" button). pbrain_overlay_show
# passes --snooze-minutes through to the overlay binary; assert the launch argv
# via a fake `open`. The fake overlay bin survives pbrain_swift_build (the no-op
# swiftc never produces a temp to rename over it), so the launch path is taken.
# ---------------------------------------------------------------------------

# Make the overlay look "built" and capture its launch argv into $ARGLOG.
_stub_overlay_launch() {
  mkdir -p "$PBRAIN_OVERLAY_APP/Contents/MacOS"
  : > "$PBRAIN_OVERLAY_APP/Contents/MacOS/pbrain-overlay"
  chmod +x "$PBRAIN_OVERLAY_APP/Contents/MacOS/pbrain-overlay"
  ARGLOG="$TMP/open.args"
  cat > "$TMP/bin/open" <<EOF
#!/bin/sh
echo "\$@" > "$ARGLOG"
exit 0
EOF
  chmod +x "$TMP/bin/open"
}

@test "pbrain_overlay_show threads an explicit --snooze-minutes plus the id/db" {
  _stub_overlay_launch
  pbrain_overlay_show "Eye break" 0 5 "" 7 "$PBRAIN_DB_FILE" 0 10 5
  grep -q -- "--snooze-minutes 5" "$ARGLOG"
  grep -q -- "--warning-seconds 10" "$ARGLOG"
  grep -q -- "--id 7" "$ARGLOG"
}

@test "PBRAIN_OVERLAY_SNOOZE_MINUTES supplies the snooze fallback when the arg is empty" {
  _stub_overlay_launch
  PBRAIN_OVERLAY_SNOOZE_MINUTES=8 pbrain_overlay_show "Eye break" 0 5 "" 7 "$PBRAIN_DB_FILE"
  grep -q -- "--snooze-minutes 8" "$ARGLOG"
}

@test "no --snooze-minutes flag is emitted when neither arg nor env is set (overlay defaults internally)" {
  _stub_overlay_launch
  pbrain_overlay_show "Eye break" 0 5 "" 7 "$PBRAIN_DB_FILE"
  ! grep -q -- "--snooze-minutes" "$ARGLOG"
}
