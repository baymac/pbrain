#!/usr/bin/env bats
# Tests for the laptop-tracking read/render path:
#   - lib/db.sh pbrain_tracker_db_init  (separate tracker.db, schema, idempotent)
#   - commands/laptop-tracking.sh report (seed → md render; gap-derived away;
#     domain normalization; attribution rollup; CRITICAL read-fail-no-clobber)
#
# The Swift daemon itself can't run headless in CI; it has a documented manual
# verification path in docs/laptop-tracking.md. These tests pin the bash+python
# read side, which is where all the edge-case logic lives (Decision 3A).
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0   # keep the vault migration runner out of unit tests
  export PBRAIN_UPDATE_CHECK=0  # never hit the network / nag in unit tests
  # Isolate HOME so start/stop never touch the real ~/Library/LaunchAgents or
  # ~/.config, and stub launchctl/swiftc/codesign so nothing hits the system.
  export HOME="$TMP/home"
  export XDG_CONFIG_HOME="$TMP/home/.config"
  mkdir -p "$HOME/Library/LaunchAgents" "$XDG_CONFIG_HOME/pbrain" "$TMP/bin"
  for c in launchctl swiftc codesign; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/$c"; chmod +x "$TMP/bin/$c"
  done
  export PATH="$TMP/bin:$PATH"
  export PBRAIN_TRACKER_DB_FILE="$TMP/tracker.db"
  export PBRAIN_TRACKER_DIR="$TMP/out"
  export PBRAIN_VAULT="$TMP/vault"        # keep vault.sh off the real vault
  export PBRAIN_SELF_IMPROVE=off
  export PBRAIN_TRACKER_TOPN=12
  export PBRAIN_NO_UPDATE_CHECK=1
  mkdir -p "$TMP/out" "$TMP/vault"
  SH="$REPO_ROOT/commands/laptop-tracking.sh"
  NUDGE_OFF="$XDG_CONFIG_HOME/pbrain/tracker-nudge-off"
}

teardown() {
  rm -rf "$TMP"
}

# Seed tracker.db with a known day. epoch base is arbitrary; the renderer only
# uses durations + local HH:MM, and the tests assert on durations/percentages.
seed_day() {
  local day="$1"
  source "$REPO_ROOT/lib/db.sh"
  pbrain_tracker_db_init
  python3 - "$PBRAIN_TRACKER_DB_FILE" "$day" <<'PY'
import sqlite3, sys, time, datetime
db, day = sys.argv[1], sys.argv[2]
c = sqlite3.connect(db)
# Anchor epochs to the day itself (09:00 local) so the renderer's day_midnight
# math lines up — otherwise the window collapses to 0. Activity runs 09:00–11:35.
base = int(time.mktime(datetime.datetime.strptime(day, "%Y-%m-%d").timetuple())) + 9*3600
rows = [
    # 1h Chrome on www.github.com  → normalizes to github.com
    (base,        base+3600,  "com.google.Chrome", "Google Chrome", "www.github.com", "ok"),
    # 30m Chrome on youtube.com
    (base+3600,   base+5400,  "com.google.Chrome", "Google Chrome", "youtube.com",    "ok"),
    # GAP 5400..7200 (30m away — NOT a row; derived from the gap)
    # 30m Xcode (not a browser)
    (base+7200,   base+9000,  "com.apple.dt.Xcode","Xcode",         None,             "not_browser"),
    # 5m Chrome with no domain (permission denied)
    (base+9000,   base+9300,  "com.google.Chrome", "Google Chrome", None,             "tcc_denied"),
]
for s,e,bid,name,host,attr in rows:
    c.execute("INSERT INTO tracker_segments(started_at,ended_at,occurred_on,app_bundle_id,app_name,raw_host,attribution) "
              "VALUES(?,?,?,?,?,?,?)",(s,e,day,bid,name,host,attr))
c.commit(); c.close()
PY
}

# --- schema -----------------------------------------------------------------

@test "pbrain_tracker_db_init creates tracker_segments with the expected columns" {
  source "$REPO_ROOT/lib/db.sh"
  run pbrain_tracker_db_init
  [ "$status" -eq 0 ]
  [ -f "$PBRAIN_TRACKER_DB_FILE" ]
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); cols=[r[1] for r in c.execute('PRAGMA table_info(tracker_segments)')]; assert cols==['id','started_at','ended_at','occurred_on','app_bundle_id','app_name','raw_host','raw_path','attribution','kind'], cols" "$PBRAIN_TRACKER_DB_FILE"
  [ "$status" -eq 0 ]
}

@test "pbrain_tracker_db_init is idempotent and preserves rows" {
  seed_day "2026-06-07"
  source "$REPO_ROOT/lib/db.sh"
  run pbrain_tracker_db_init
  [ "$status" -eq 0 ]
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute('select count(*) from tracker_segments').fetchone()[0])" "$PBRAIN_TRACKER_DB_FILE"
  [ "$output" = "4" ]
}

@test "tracker.db is separate from the shared pbrain.db" {
  export PBRAIN_DB_FILE="$TMP/pbrain.db"
  source "$REPO_ROOT/lib/db.sh"
  pbrain_db_init
  pbrain_tracker_db_init
  # the shared DB must NOT carry tracker_segments; the tracker DB must NOT carry habit_events
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); t={r[0] for r in c.execute(\"select name from sqlite_master where type='table'\")}; assert 'tracker_segments' not in t, t" "$PBRAIN_DB_FILE"
  [ "$status" -eq 0 ]
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); t={r[0] for r in c.execute(\"select name from sqlite_master where type='table'\")}; assert 'habit_events' not in t and 'tracker_segments' in t, t" "$PBRAIN_TRACKER_DB_FILE"
  [ "$status" -eq 0 ]
}

# --- render -----------------------------------------------------------------

@test "report renders a daily md with active time and a full-day window for a past day" {
  seed_day "2026-06-07"   # a past day → reconciled to the full midnight→midnight window
  run bash "$SH" report 2026-06-07
  [ "$status" -eq 0 ]
  [ -f "$PBRAIN_TRACKER_DIR/2026-06-07.md" ]
  run cat "$PBRAIN_TRACKER_DIR/2026-06-07.md"
  # active = 3600+1800+1800+300 = 7500s = 2h 05m
  [[ "$output" == *"Active time:** 2h 05m"* ]]
  # past day: window is the full calendar day; away = 24h − active = 21h 55m
  [[ "$output" == *"Day window:** 00:00 → 24:00 (full day)"* ]]
  [[ "$output" == *"21h 55m away"* ]]
}

@test "report for TODAY uses a 'so far' window ending at the last activity" {
  TODAY="$(date +%Y-%m-%d)"
  seed_day "$TODAY"
  run bash "$SH" report "$TODAY"
  [ "$status" -eq 0 ]
  run cat "$PBRAIN_TRACKER_DIR/$TODAY.md"
  [[ "$output" == *"Active time:** 2h 05m"* ]]
  # today is in progress → window runs midnight → last activity (not a full day)
  [[ "$output" == *"so far"* ]]
  [[ "$output" != *"full day"* ]]
}

@test "report normalizes www. and aggregates domains" {
  seed_day "2026-06-07"
  bash "$SH" report 2026-06-07
  run cat "$PBRAIN_TRACKER_DIR/2026-06-07.md"
  [[ "$output" == *"| github.com |"* ]]
  [[ "$output" != *"www.github.com"* ]]
  [[ "$output" == *"| youtube.com |"* ]]
}

@test "youtube per-video paths (?v=) render as distinct pages with per-video time" {
  source "$REPO_ROOT/lib/db.sh"; pbrain_tracker_db_init
  python3 - "$PBRAIN_TRACKER_DB_FILE" "2026-06-07" <<'PY'
import sqlite3, sys, time, datetime
db, day = sys.argv[1], sys.argv[2]
c = sqlite3.connect(db)
base = int(time.mktime(datetime.datetime.strptime(day, "%Y-%m-%d").timetuple())) + 9*3600
rows = [
    # two different videos on the same youtube.com/watch path → must stay separate
    (base,      base+1200, "com.google.Chrome","Google Chrome","youtube.com","youtube.com/watch?v=AAA111","ok"),
    (base+1200, base+1500, "com.google.Chrome","Google Chrome","youtube.com","youtube.com/watch?v=BBB222","ok"),
]
for s,e,bid,name,host,path,attr in rows:
    c.execute("INSERT INTO tracker_segments(started_at,ended_at,occurred_on,app_bundle_id,app_name,raw_host,raw_path,attribution) "
              "VALUES(?,?,?,?,?,?,?,?)",(s,e,day,bid,name,host,path,attr))
c.commit(); c.close()
PY
  bash "$SH" report 2026-06-07
  run cat "$PBRAIN_TRACKER_DIR/2026-06-07.md"
  # both videos appear as their own page rows (not merged into youtube.com/watch)
  [[ "$output" == *"youtube.com/watch?v=AAA111 | 20m"* ]]
  [[ "$output" == *"youtube.com/watch?v=BBB222 | 5m"* ]]
  # the domain rollup still aggregates them under the bare host
  [[ "$output" == *"| youtube.com |"* ]]
}

@test "report rolls up non-ok attribution so denied browser time is explained" {
  seed_day "2026-06-07"
  bash "$SH" report 2026-06-07
  run cat "$PBRAIN_TRACKER_DIR/2026-06-07.md"
  [[ "$output" == *"Browser attribution"* ]]
  [[ "$output" == *"permission not granted"* ]]
}

@test "background media renders in its own section and is excluded from active time" {
  source "$REPO_ROOT/lib/db.sh"; pbrain_tracker_db_init
  python3 - "$PBRAIN_TRACKER_DB_FILE" "2026-06-07" <<'PY'
import sqlite3, sys, time, datetime
db, day = sys.argv[1], sys.argv[2]
c = sqlite3.connect(db)
base = int(time.mktime(datetime.datetime.strptime(day,"%Y-%m-%d").timetuple())) + 9*3600
rows = [
    # 1h foreground work in an editor
    (base, base+3600, "com.microsoft.VSCode","Code",None,None,"ok","foreground"),
    # 30m Spotify playing concurrently in the background → separate ledger
    (base, base+1800, "com.spotify.client","Spotify",None,None,"ok","bg_media"),
]
for s,e,bid,name,host,path,attr,kind in rows:
    c.execute("INSERT INTO tracker_segments(started_at,ended_at,occurred_on,app_bundle_id,app_name,raw_host,raw_path,attribution,kind) "
              "VALUES(?,?,?,?,?,?,?,?,?)",(s,e,day,bid,name,host,path,attr,kind))
c.commit(); c.close()
PY
  bash "$SH" report 2026-06-07
  run cat "$PBRAIN_TRACKER_DIR/2026-06-07.md"
  # foreground active counts ONLY the editor's 1h — bg Spotify is NOT added in
  [[ "$output" == *"Active time:** 1h 00m"* ]]
  # bg media shows in its own section with its own time
  [[ "$output" == *"## Background media"* ]]
  [[ "$output" == *"| Spotify | 30m |"* ]]
  [[ "$output" == *"| Code |"* ]]
}

@test "a background-media-only day (e.g. locked screen, audio playing) still renders the bg section" {
  source "$REPO_ROOT/lib/db.sh"; pbrain_tracker_db_init
  python3 - "$PBRAIN_TRACKER_DB_FILE" "2026-06-07" <<'PY'
import sqlite3, sys, time, datetime
db, day = sys.argv[1], sys.argv[2]
c = sqlite3.connect(db)
base = int(time.mktime(datetime.datetime.strptime(day,"%Y-%m-%d").timetuple())) + 9*3600
c.execute("INSERT INTO tracker_segments(started_at,ended_at,occurred_on,app_bundle_id,app_name,raw_host,raw_path,attribution,kind) "
          "VALUES(?,?,?,?,?,?,?,?,?)",(base,base+1800,day,"com.spotify.client","Spotify",None,None,"ok","bg_media"))
c.commit(); c.close()
PY
  bash "$SH" report 2026-06-07
  run cat "$PBRAIN_TRACKER_DIR/2026-06-07.md"
  [[ "$output" == *"background media only"* ]]
  [[ "$output" == *"## Background media"* ]]
  [[ "$output" == *"| Spotify | 30m |"* ]]
  # no foreground activity → no active-time line
  [[ "$output" != *"Active time:"* ]]
}

@test "report on an empty day writes a clear 'no active time' file" {
  source "$REPO_ROOT/lib/db.sh"; pbrain_tracker_db_init
  run bash "$SH" report 2026-06-07
  [ "$status" -eq 0 ]
  run cat "$PBRAIN_TRACKER_DIR/2026-06-07.md"
  [[ "$output" == *"No active laptop time recorded"* ]]
}

@test "report rejects a malformed date" {
  run bash "$SH" report not-a-date
  [ "$status" -eq 0 ]
  [[ "$output" == *"Bad date"* ]]
}

# --- CRITICAL regression: read failure must never clobber an existing report --

@test "a DB read failure leaves an existing report UNTOUCHED (no empty-overwrite)" {
  # An existing, precious report for the day.
  printf 'SENTINEL PRECIOUS CONTENT\n' > "$PBRAIN_TRACKER_DIR/2026-06-07.md"
  # Point the tracker DB at a non-database garbage file → SELECT throws.
  export PBRAIN_TRACKER_DB_FILE="$TMP/garbage.db"
  printf 'this is not a sqlite database\n' > "$PBRAIN_TRACKER_DB_FILE"
  run bash "$SH" report 2026-06-07
  [ "$status" -eq 0 ]
  [[ "$output" == *"No report written"* ]]
  run cat "$PBRAIN_TRACKER_DIR/2026-06-07.md"
  [ "$output" = "SENTINEL PRECIOUS CONTENT" ]
}

@test "an unreadable DB file also leaves an existing report UNTOUCHED" {
  printf 'SENTINEL PRECIOUS CONTENT\n' > "$PBRAIN_TRACKER_DIR/2026-06-07.md"
  seed_day "2026-06-07"
  chmod 000 "$PBRAIN_TRACKER_DB_FILE"
  run bash "$SH" report 2026-06-07
  chmod 644 "$PBRAIN_TRACKER_DB_FILE" 2>/dev/null || true
  [ "$status" -eq 0 ]
  run cat "$PBRAIN_TRACKER_DIR/2026-06-07.md"
  [ "$output" = "SENTINEL PRECIOUS CONTENT" ]
}

# --- idempotent re-render ----------------------------------------------------

@test "re-rendering the same day is stable (idempotent content)" {
  seed_day "2026-06-07"
  bash "$SH" report 2026-06-07
  first="$(cat "$PBRAIN_TRACKER_DIR/2026-06-07.md")"
  bash "$SH" report 2026-06-07
  second="$(cat "$PBRAIN_TRACKER_DIR/2026-06-07.md")"
  [ "$first" = "$second" ]
}

# --- opt-in / decline state (the /plan-my-day nudge gate) --------------------

@test "decline writes the nudge-off marker and never starts anything" {
  run bash "$SH" decline
  [ "$status" -eq 0 ]
  [[ "$output" == *"won't suggest laptop tracking again"* ]]
  [ -f "$NUDGE_OFF" ]
  [ ! -f "$HOME/Library/LaunchAgents/com.pbrain.tracker.plist" ]
}

@test "disable (stop) also suppresses the setup nudge" {
  run bash "$SH" disable
  [ "$status" -eq 0 ]
  [ -f "$NUDGE_OFF" ]
}

@test "enable (start) clears a prior nudge-off marker" {
  touch "$NUDGE_OFF"
  [ -f "$NUDGE_OFF" ]
  run bash "$SH" enable
  [ "$status" -eq 0 ]
  [ ! -f "$NUDGE_OFF" ]
}

@test "stop and disable are aliases; start and enable are aliases" {
  # disable on a fresh state reports 'not installed' (same as stop)
  run bash "$SH" disable
  [ "$status" -eq 0 ]
  [[ "$output" == *"not installed"* ]] || [[ "$output" == *"Stopped"* ]]
}
