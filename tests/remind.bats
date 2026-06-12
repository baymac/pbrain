#!/usr/bin/env bats
# Tests for commands/remind.sh — the Apple Reminders (EKReminder) command.
#
# /remind creates real Apple Reminders via a bundled EventKit helper
# (pbrain-reminders.app, from lib/pbrain-reminders.swift). It does NOT touch the
# shared SQLite reminders table (that's /remind-blocking's). These tests cover:
#   - argument validation / guards (they exit before any helper call)
#   - the add / list / edit / done / cancel success paths, driving a FAKE helper
#     app (a tiny script standing in for the compiled EventKit binary) launched
#     through a FAKE `open`, so the real shell logic runs end to end
#   - the cron→Apple-recurrence mapper (pbrain_cron_to_rrules) directly
#   - the natural-language entry block + help
#
# swiftc is stubbed no-op and the fake helper binary is future-dated so
# pbrain_reminders_app_build never rebuilds it. A throwaway vault +
# PBRAIN_SELF_IMPROVE=off keep it hermetic.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0   # keep the vault migration runner out of unit tests
  export PBRAIN_UPDATE_CHECK=0  # never hit the network / nag in unit tests
  export PBRAIN_DB_FILE="$TMP/pbrain.db"
  export PBRAIN_VAULT="$TMP/vault"; mkdir -p "$PBRAIN_VAULT"
  export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/pbrain"
  printf '%s\n' "$PBRAIN_VAULT" > "$XDG_CONFIG_HOME/pbrain/vault"
  export PBRAIN_SELF_IMPROVE=off
  export PBRAIN_REMINDERS_LIST=""
  export PBRAIN_REMINDERS_APP="$TMP/pbrain-reminders.app"

  mkdir -p "$TMP/bin" "$PBRAIN_REMINDERS_APP/Contents/MacOS"

  # No-op swiftc/launchctl so no real compile/launch happens.
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/swiftc";    chmod +x "$TMP/bin/swiftc"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/launchctl"; chmod +x "$TMP/bin/launchctl"

  # Fake helper binary: parses --op/--result/--id and writes a canned status.
  export REM_ARGLOG="$TMP/remargs.log"
  cat > "$PBRAIN_REMINDERS_APP/Contents/MacOS/pbrain-reminders" <<'EOF'
#!/usr/bin/env bash
[ -n "$REM_ARGLOG" ] && printf '%s\n' "$*" >> "$REM_ARGLOG"
op=""; res=""; id=""; prev=""
for a in "$@"; do
  case "$prev" in
    --op) op="$a" ;;
    --result) res="$a" ;;
    --id) id="$a" ;;
  esac
  prev="$a"
done
case "$op" in
  access-check) out="${FAKE_REM_ACCESS:-OK}" ;;
  add)          out="ADDED FAKE-REM-ID" ;;
  list)         out="${FAKE_REM_LIST:-}" ;;
  edit)         [ "$id" = "MISSING" ] && out="NOT_FOUND" || out="EDITED" ;;
  complete)     [ "$id" = "MISSING" ] && out="NOT_FOUND" || out="COMPLETED" ;;
  delete)       [ "$id" = "MISSING" ] && out="NOT_FOUND" || out="DELETED" ;;
  *)            out="ERROR:unknown-op" ;;
esac
[ -n "$res" ] && printf '%s' "$out" > "$res"
printf '%s' "$out"
exit 0
EOF
  chmod +x "$PBRAIN_REMINDERS_APP/Contents/MacOS/pbrain-reminders"
  # Future-date it so pbrain_reminders_app_build's up-to-date check skips rebuild.
  touch -t 203012312359 "$PBRAIN_REMINDERS_APP/Contents/MacOS/pbrain-reminders"

  # Fake `open`: emulate `open -W -n <app.app> --args <binargs...>` by exec'ing
  # the app's helper binary with everything after --args (arrays preserve spaces).
  cat > "$TMP/bin/open" <<'EOF'
#!/usr/bin/env bash
app=""; rest=(); after=0
for a in "$@"; do
  if [[ $after -eq 1 ]]; then rest+=("$a")
  elif [[ "$a" == "--args" ]]; then after=1
  elif [[ "$a" == *.app ]]; then app="$a"
  fi
done
[[ -n "$app" ]] && exec "$app/Contents/MacOS/pbrain-reminders" "${rest[@]}"
exit 0
EOF
  chmod +x "$TMP/bin/open"

  export PATH="$TMP/bin:$PATH"
  export HOME="$TMP/home"; mkdir -p "$HOME/Library/LaunchAgents"
}

teardown() { rm -rf "$TMP"; }

_remind() { run bash "$REPO_ROOT/commands/remind.sh" "$@"; }

# --- argument validation (exits before any helper call) ---------------------

@test "add requires --text" {
  _remind add --due "2030-01-01 09:00"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires --text"* ]]
}

@test "one-shot add requires --due" {
  _remind add --text "call dentist"
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs --due"* ]]
}

@test "add rejects an unparseable --due" {
  _remind add --text "bad date" --due "next friday"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--due must be"* ]]
}

@test "add rejects an out-of-range time in --due" {
  _remind add --text "impossible" --due "2030-01-01 25:99"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--due must be"* ]]
}

@test "add rejects a bad --priority" {
  _remind add --text x --due "2030-01-01 09:00" --priority urgent
  [ "$status" -ne 0 ]
  [[ "$output" == *"--priority must be"* ]]
}

@test "add rejects an unknown --repeat token" {
  _remind add --text x --due "2030-01-01 09:00" --repeat fortnightly
  [ "$status" -ne 0 ]
  [[ "$output" == *"unrecognized --repeat"* ]]
}

@test "--repeat without --due is rejected" {
  _remind add --text x --repeat weekly
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs a --due anchor"* ]]
}

@test "--until and --count together are rejected" {
  _remind add --text x --cron "0 9 * * 1" --until "2030-02-01" --count 3
  [ "$status" -ne 0 ]
  [[ "$output" == *"either --until or --count"* ]]
}

@test "--count must be a positive integer" {
  _remind add --text x --cron "0 9 * * 1" --count 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"--count must be a positive integer"* ]]
}

@test "--until on a one-shot is rejected" {
  _remind add --text x --due "2030-01-01 09:00" --until "2030-02-01"
  [ "$status" -ne 0 ]
  [[ "$output" == *"only apply to a recurring reminder"* ]]
}

@test "sub-daily --cron is rejected and points to /remind-blocking" {
  _remind add --text x --cron "*/5 * * * *"
  [ "$status" -ne 0 ]
  [[ "$output" == *"/remind-blocking"* ]]
}

@test "sub-daily --repeat (every-5m) is rejected" {
  _remind add --text x --due "2030-01-01 09:00" --repeat every-5m
  [ "$status" -ne 0 ]
  [[ "$output" == *"sub-daily"* ]]
}

@test "edit requires an id" {
  _remind edit --due "2030-01-01 09:00"
  [ "$status" -ne 0 ]
  [[ "$output" == *"edit requires a reminder id"* ]]
}

@test "done requires at least one id" {
  _remind done
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires at least one"* ]]
}

@test "cancel requires at least one id" {
  _remind cancel
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires at least one"* ]]
}

# --- add success paths (fake helper) ----------------------------------------

@test "one-shot add creates a reminder and echoes its id" {
  _remind add --text "call dentist" --due "2030-01-01 09:00"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMIND_ADDED FAKE-REM-ID"* ]]
  [[ "$output" == *"Added to Reminders"* ]]
  [[ "$output" == *"call dentist"* ]]
}

@test "date-only --due anchors to 09:00" {
  _remind add --text "date only" --due "2030-09-09"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2030-09-09 09:00"* ]]
}

@test "recurring add via --cron succeeds (single)" {
  _remind add --text "standup" --cron "0 9 * * 1-5"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMIND_ADDED FAKE-REM-ID"* ]]
  [[ "$output" == *"FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"* ]]
}

@test "multi-time --cron splits into multiple reminders" {
  _remind add --text "meds" --cron "0 9,17 * * *"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 reminders"* ]]
}

@test "add accepts --priority and --early" {
  _remind add --text "call mom" --due "2030-06-08 18:00" --priority high --early "15,60"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMIND_ADDED"* ]]
}

@test "bounded recurrence with --count is accepted" {
  _remind add --text "water" --cron "0 9 * * *" --count 3
  [ "$status" -eq 0 ]
  [[ "$output" == *"COUNT=3"* ]]
}

@test "every-N interval via --repeat is accepted" {
  _remind add --text "deep clean" --due "2030-01-01 10:00" --repeat every-2w:MO
  [ "$status" -eq 0 ]
  [[ "$output" == *"FREQ=WEEKLY;INTERVAL=2;BYDAY=MO"* ]]
}

# --- list / edit / done / cancel / access -----------------------------------

@test "list reports empty when there are no reminders" {
  _remind list
  [ "$status" -eq 0 ]
  [[ "$output" == *"no upcoming pbrain reminders"* ]]
}

@test "list renders a reminder with priority and recurrence" {
  export FAKE_REM_LIST="REM-1	2030-01-01 09:00	high	FREQ=DAILY	drink water"
  _remind list
  [ "$status" -eq 0 ]
  [[ "$output" == *"drink water"* ]]
  [[ "$output" == *"[high]"* ]]
  [[ "$output" == *"id: REM-1"* ]]
}

@test "edit updates a reminder" {
  _remind edit REM-1 --due "2030-02-02 10:00" --priority low
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updated reminder REM-1"* ]]
}

@test "edit reports NOT_FOUND for a missing id" {
  _remind edit MISSING --priority low
  [ "$status" -ne 0 ]
  [[ "$output" == *"no reminder with id MISSING"* ]]
}

@test "edit --until without recurrence is rejected" {
  _remind edit REM-1 --until "2030-06-09"
  [ "$status" -ne 0 ]
  [[ "$output" == *"need the recurrence too"* ]]
}

@test "edit caps a series: --cron + --until passes UNTIL through to the rrule" {
  _remind edit REM-1 --cron "0 9 * * *" --until "2026-06-09"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updated reminder REM-1"* ]]
  grep -q "UNTIL=20260609" "$REM_ARGLOG"
}

@test "edit to a splitting cron is refused" {
  _remind edit REM-1 --cron "0 9,17 * * *"
  [ "$status" -ne 0 ]
  [[ "$output" == *"separate reminders"* ]]
}

@test "done marks a reminder complete" {
  _remind done REM-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Marked done: REM-1"* ]]
}

@test "cancel deletes a reminder" {
  _remind cancel REM-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed: REM-1"* ]]
}

@test "access reports granted" {
  _remind access
  [ "$status" -eq 0 ]
  [[ "$output" == *"access granted"* ]]
}

# --- helper unavailable (no swiftc-built app) -------------------------------

@test "add reports clearly when the EventKit helper can't be built" {
  export PBRAIN_REMINDERS_APP="$TMP/missing.app"   # no binary here; swiftc is no-op
  _remind add --text "x" --due "2030-01-01 09:00"
  [ "$status" -ne 0 ]
  [[ "$output" == *"can't reach Reminders"* ]]
  [[ "$output" == *"swiftc"* ]]
}

# --- entry / help -----------------------------------------------------------

@test "natural-language entry emits a REMIND_ENTRY block with instructions" {
  _remind "remind me to call mom tomorrow at 6pm"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMIND_ENTRY"* ]]
  [[ "$output" == *"INSTRUCTIONS"* ]]
  [[ "$output" == *"Apple"* ]]
}

@test "help prints the header describing the Reminders model" {
  _remind help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Apple"* ]]
  [[ "$output" == *"Reminders"* ]]
}

# --- cron→recurrence mapper (pbrain_cron_to_rrules) directly -----------------

@test "mapper: daily" {
  source "$REPO_ROOT/lib/reminders.sh"
  run pbrain_cron_to_rrules "0 9 * * *" "2026-06-06 12:00"
  [[ "$output" == *"OK	2026-06-07 09:00	FREQ=DAILY"* ]]
}

@test "mapper: weekdays" {
  source "$REPO_ROOT/lib/reminders.sh"
  run pbrain_cron_to_rrules "30 7 * * 1-5" "2026-06-06 12:00"
  [[ "$output" == *"FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"* ]]
}

@test "mapper: first Monday via 1#1" {
  source "$REPO_ROOT/lib/reminders.sh"
  run pbrain_cron_to_rrules "0 9 * * 1#1" "2026-06-06 12:00"
  [[ "$output" == *"FREQ=MONTHLY;BYDAY=1MO"* ]]
}

@test "mapper: last Friday via 5L" {
  source "$REPO_ROOT/lib/reminders.sh"
  run pbrain_cron_to_rrules "0 22 * * 5L" "2026-06-06 12:00"
  [[ "$output" == *"FREQ=MONTHLY;BYDAY=-1FR"* ]]
}

@test "mapper: leap day resolves beyond the 366-day window" {
  source "$REPO_ROOT/lib/reminders.sh"
  run pbrain_cron_to_rrules "0 9 29 2 *" "2026-06-06 12:00"
  [[ "$output" == *"2028-02-29 09:00"* ]]
  [[ "$output" == *"FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29"* ]]
}

@test "mapper: impossible date is rejected" {
  source "$REPO_ROOT/lib/reminders.sh"
  run pbrain_cron_to_rrules "0 9 30 2 *" "2026-06-06 12:00"
  [[ "$output" == *"REJECT	INVALID"* ]]
}

@test "mapper: sub-daily is rejected" {
  source "$REPO_ROOT/lib/reminders.sh"
  run pbrain_cron_to_rrules "0 * * * *" "2026-06-06 12:00"
  [[ "$output" == *"REJECT	SUBDAILY"* ]]
}

@test "mapper: dom AND dow splits into two reminders (OR semantics)" {
  source "$REPO_ROOT/lib/reminders.sh"
  run pbrain_cron_to_rrules "0 9 1 * 1" "2026-06-06 12:00"
  [[ "$output" == *"FREQ=WEEKLY;BYDAY=MO"* ]]
  [[ "$output" == *"FREQ=MONTHLY;BYMONTHDAY=1"* ]]
}

@test "mapper: invalid field is rejected" {
  source "$REPO_ROOT/lib/reminders.sh"
  run pbrain_cron_to_rrules "99 9 * * *" "2026-06-06 12:00"
  [[ "$output" == *"REJECT	INVALID"* ]]
}
