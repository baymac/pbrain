#!/usr/bin/env bats
# Tests for commands/remind-blocking.sh — the blocking-overlay reminder command.
#
# The command sources lib/vault.sh, so a throwaway vault + config are pointed at
# $TMP. swiftc and launchctl are stubbed so no real overlay app is built and no
# launchd poller is registered. The DB is isolated via PBRAIN_DB_FILE.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_DB_FILE="$TMP/pbrain.db"
  export PBRAIN_VAULT="$TMP/vault"; mkdir -p "$PBRAIN_VAULT"
  export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/pbrain"
  # Point the vault config file at our throwaway vault so vault.sh resolves clean.
  printf '%s\n' "$PBRAIN_VAULT" > "$XDG_CONFIG_HOME/pbrain/vault"
  export PBRAIN_SELF_IMPROVE=off
  export PBRAIN_OVERLAY_APP="$TMP/pbrain-overlay.app"
  export PBRAIN_NOTIFY_APP="$TMP/pbrain-notify.app"
  mkdir -p "$TMP/bin"
  # No-op swiftc → no real apps compiled.
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/swiftc"; chmod +x "$TMP/bin/swiftc"
  # Stub launchctl + open so `add`/`install` never touch the real session.
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/launchctl"; chmod +x "$TMP/bin/launchctl"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/open"; chmod +x "$TMP/bin/open"
  export PATH="$TMP/bin:$PATH"
  # Keep launchd plist writes inside $TMP, not the real ~/Library.
  export HOME="$TMP/home"; mkdir -p "$HOME/Library/LaunchAgents"
  CMD="$REPO_ROOT/commands/remind-blocking.sh"
}

teardown() {
  rm -rf "$TMP"
}

_run_cmd() { run bash "$CMD" "$@"; }

@test "add stores a blocking reminder with duration + hold" {
  _run_cmd add --text "Take a break" --due "2099-01-01 09:00" --duration 300 --hold 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMIND_BLOCKING_ADDED"* ]]
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute('select text,block_seconds,hold_seconds from reminders').fetchone())" "$PBRAIN_DB_FILE"
  [[ "$output" == *"Take a break"* ]]
  [[ "$output" == *"300"* ]]
  [[ "$output" == *"5"* ]]
}

@test "add without --duration defaults to 0 (stays until skipped)" {
  _run_cmd add --text "Stand up" --due "2099-01-02 10:00"
  [ "$status" -eq 0 ]
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute('select block_seconds,hold_seconds from reminders').fetchone())" "$PBRAIN_DB_FILE"
  [ "$output" = "(0, 5)" ]
}

@test "add requires --text" {
  _run_cmd add --due "2099-01-01 09:00"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires --text"* ]]
}

@test "add rejects a non-numeric duration" {
  _run_cmd add --text x --duration abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"--duration must be a whole number"* ]]
}

@test "add --cron stores the cron expr and computes a concrete next due_at" {
  _run_cmd add --text "Stand up" --cron "0 14,17 * * 2,6" --duration 120
  [ "$status" -eq 0 ]
  [[ "$output" == *"cron: 0 14,17 * * 2,6"* ]]
  run python3 -c "import sqlite3,sys,datetime; c=sqlite3.connect(sys.argv[1]); cr,d=c.execute('select cron,due_at from reminders').fetchone(); datetime.datetime.strptime(d,'%Y-%m-%d %H:%M'); print(cr)" "$PBRAIN_DB_FILE"
  [ "$output" = "0 14,17 * * 2,6" ]
}

@test "add rejects an invalid --cron expression" {
  _run_cmd add --text x --cron "not a cron"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid --cron"* ]]
}

@test "add rejects a bad --due format" {
  _run_cmd add --text x --due "next friday"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--due must be"* ]]
}

@test "list shows only blocking reminders" {
  # one blocking (via the command) + one plain notification reminder (direct insert)
  bash "$CMD" add --text "Take a break" --due "2099-01-01 09:00" --duration 120 >/dev/null 2>&1
  python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(\"insert into reminders(text,due_at,status,created_at) values('plain ping','2099-01-01 09:00','pending','t')\"); c.commit()" "$PBRAIN_DB_FILE"
  _run_cmd list
  [ "$status" -eq 0 ]
  [[ "$output" == *"Take a break"* ]]
  [[ "$output" != *"plain ping"* ]]
}

@test "done marks a blocking reminder done" {
  bash "$CMD" add --text "Take a break" --due "2099-01-01 09:00" --duration 120 >/dev/null 2>&1
  ID="$(python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute('select id from reminders').fetchone()[0])" "$PBRAIN_DB_FILE")"
  _run_cmd done "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Marked done"* ]]
  run python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute('select status from reminders').fetchone()[0])" "$PBRAIN_DB_FILE"
  [ "$output" = "done" ]
}

@test "install writes a self-owned poller plist pointing at remind-blocking.sh tick" {
  _run_cmd install
  [ "$status" -eq 0 ]
  [[ "$output" == *"blocking-reminders poller"* ]]
  PLIST="$HOME/Library/LaunchAgents/com.pbrain.reminders.plist"
  [ -f "$PLIST" ]
  grep -q "remind-blocking.sh" "$PLIST"
  grep -q "<string>tick</string>" "$PLIST"
}

@test "uninstall removes the poller plist" {
  bash "$CMD" install >/dev/null 2>&1
  _run_cmd uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed"* ]]
  [ ! -f "$HOME/Library/LaunchAgents/com.pbrain.reminders.plist" ]
}

@test "add auto-installs the poller when not present" {
  PLIST="$HOME/Library/LaunchAgents/com.pbrain.reminders.plist"
  [ ! -f "$PLIST" ]
  bash "$CMD" add --text "Take a break" --due "2099-01-01 09:00" --duration 120 >/dev/null 2>&1
  [ -f "$PLIST" ]
  grep -q "remind-blocking.sh" "$PLIST"
}

@test "natural-language entry emits a REMIND_BLOCKING_ENTRY block" {
  _run_cmd "take a break every afternoon"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMIND_BLOCKING_ENTRY"* ]]
  [[ "$output" == *"INSTRUCTIONS"* ]]
}
