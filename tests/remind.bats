#!/usr/bin/env bats
# Tests for commands/remind.sh — the Apple Calendar-only reminder command.
#
# /remind no longer touches the shared SQLite reminders table: it creates real
# Calendar events via osascript (create) + a bundled EventKit helper (delete).
# So these tests cover the command-owned logic that needs NO real Calendar:
#   - argument validation / guards (they exit before any Calendar call)
#   - the add success path, with a fake `osascript` standing in for Calendar
#   - the natural-language entry block + help
#   - a regression guard that the removed `clear`/`snooze` DB paths are gone
#     (they must never mutate the DB — there are no /remind DB rows anymore;
#     the only rows belong to /remind-blocking).
#
# swiftc/open/launchctl are stubbed so no real helper app is built or launched,
# and a fake `osascript` emits a uid only for event-creation scripts (so `list`
# stays empty). A throwaway vault + PBRAIN_SELF_IMPROVE=off keep it hermetic.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_DB_FILE="$TMP/pbrain.db"
  export PBRAIN_VAULT="$TMP/vault"; mkdir -p "$PBRAIN_VAULT"
  export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/pbrain"
  printf '%s\n' "$PBRAIN_VAULT" > "$XDG_CONFIG_HOME/pbrain/vault"
  export PBRAIN_SELF_IMPROVE=off
  export PBRAIN_CALENDAR_APP="$TMP/pbrain-calendar.app"
  mkdir -p "$TMP/bin"
  # No-op swiftc/open/launchctl so no real app is compiled or launched.
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/swiftc";    chmod +x "$TMP/bin/swiftc"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/open";      chmod +x "$TMP/bin/open"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/launchctl"; chmod +x "$TMP/bin/launchctl"
  # Fake osascript: emit a fake uid ONLY for event creation; everything else
  # (the list query) returns nothing, so `list` reports empty.
  cat > "$TMP/bin/osascript" <<'EOF'
#!/bin/sh
script="$(cat)"
case "$script" in
  *"make new event"*) echo "FAKE-EVENT-UID" ;;
  *) : ;;
esac
exit 0
EOF
  chmod +x "$TMP/bin/osascript"
  export PATH="$TMP/bin:$PATH"
  export HOME="$TMP/home"; mkdir -p "$HOME/Library/LaunchAgents"
}

teardown() {
  rm -rf "$TMP"
}

_remind() { run bash "$REPO_ROOT/commands/remind.sh" "$@"; }

# --- argument validation (exits before any Calendar call) -------------------

@test "add requires --text" {
  _remind add --due "2030-01-01 09:00"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires --text"* ]]
}

@test "add requires --due (a calendar event needs a time)" {
  _remind add --text "call dentist"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires --due"* ]]
}

@test "add rejects an unparseable --due" {
  _remind add --text "bad date" --due "next friday"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--due must be"* ]]
}

@test "add rejects an out-of-range time in --due" {
  _remind add --text "impossible time" --due "2030-01-01 25:99"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--due must be"* ]]
}

@test "add rejects an unknown --repeat token" {
  _remind add --text x --due "2030-01-01 09:00" --repeat hourly
  [ "$status" -ne 0 ]
  [[ "$output" == *"unrecognized --repeat"* ]]
}

@test "--until without --repeat is rejected" {
  _remind add --text x --due "2030-01-01 09:00" --until "2030-02-01"
  [ "$status" -ne 0 ]
  [[ "$output" == *"only apply to a recurring reminder"* ]]
}

@test "--until and --count together are rejected" {
  _remind add --text x --due "2030-01-01 09:00" --repeat weekly --until "2030-02-01" --count 3
  [ "$status" -ne 0 ]
  [[ "$output" == *"either --until or --count"* ]]
}

@test "--count must be a positive integer" {
  _remind add --text x --due "2030-01-01 09:00" --repeat weekly --count 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"--count must be a positive integer"* ]]
}

@test "done requires at least one uid" {
  _remind done
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires at least one"* ]]
}

@test "cancel requires at least one uid" {
  _remind cancel
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires at least one"* ]]
}

# --- add success path (fake osascript stands in for Calendar) ---------------

@test "add creates a calendar event and echoes its uid" {
  _remind add --text "call dentist" --due "2030-01-01 09:00"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMIND_ADDED uid="* ]]
  [[ "$output" == *"Added to"* ]]
  [[ "$output" == *"call dentist"* ]]
}

@test "add reports the recurrence when --repeat is given" {
  _remind add --text "standup" --due "2030-01-01 09:00" --repeat weekly
  [ "$status" -eq 0 ]
  [[ "$output" == *"repeats weekly"* ]]
}

@test "add reports a bounded recurrence with --count" {
  _remind add --text "standup" --due "2030-01-01 09:00" --repeat weekly --count 3
  [ "$status" -eq 0 ]
  [[ "$output" == *"repeats weekly"* ]]
  [[ "$output" == *"3×"* ]]
}

@test "add accepts a date-only --due" {
  _remind add --text "date only" --due "2030-09-09"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMIND_ADDED uid="* ]]
}

# --- list / entry / help ----------------------------------------------------

@test "list reports empty when there are no events" {
  _remind list
  [ "$status" -eq 0 ]
  [[ "$output" == *"no upcoming pbrain reminders"* ]]
}

@test "natural-language entry emits a REMIND_ENTRY block with instructions" {
  _remind "remind me to call mom tomorrow at 6pm"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMIND_ENTRY"* ]]
  [[ "$output" == *"INSTRUCTIONS"* ]]
}

@test "help prints the header describing the Calendar-only model" {
  _remind help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Apple Calendar"* ]]
}

# --- regression: the removed DB-mutating subcommands are gone ----------------

@test "clear no longer mutates the DB (falls through to the entry path)" {
  # Old behaviour cancelled all pending DB rows; the DB path is removed, so
  # `clear --yes` must NOT report a cancellation — it's just entry-path input.
  _remind clear --yes
  [[ "$output" != *"Cancelled"* ]]
  [[ "$output" == *"REMIND_ENTRY"* ]]
  # And it must not have created a reminders DB at all.
  [ ! -f "$PBRAIN_DB_FILE" ]
}

@test "snooze no longer mutates the DB (falls through to the entry path)" {
  _remind snooze 1
  [[ "$output" != *"Snoozed"* ]]
  [[ "$output" == *"REMIND_ENTRY"* ]]
  [ ! -f "$PBRAIN_DB_FILE" ]
}
