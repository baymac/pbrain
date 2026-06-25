#!/usr/bin/env bats
# Tests for commands/end-of-day.sh — focused on the --date argument added in
# feat/laptop-tracking-status: parsing, validation, and DOW computation.
#
# The full close-of-day reflection flow requires a vault and LLM output, so
# this file pins only the argument-handling and date-validation layer.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0   # keep the vault migration runner out of unit tests
  export PBRAIN_UPDATE_CHECK=0  # never hit the network / nag in unit tests
  export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/pbrain"
  export PBRAIN_VAULT="$TMP/vault"
  export PBRAIN_PLAN_DIR="$TMP/plans"
  export PBRAIN_JOURNAL_DIR="$TMP/journal"
  export PBRAIN_FITNESS_DIR="$TMP/fitness"
  export PBRAIN_DIET_DIR="$TMP/diet"
  export PBRAIN_DB_FILE="$TMP/pbrain.db"
  export PBRAIN_SELF_IMPROVE=off
  export PBRAIN_NO_UPDATE_CHECK=1
  # Stub Apple-facing tools so launchd/swiftc never run
  mkdir -p "$TMP/bin"
  for c in launchctl swiftc codesign; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/$c"; chmod +x "$TMP/bin/$c"
  done
  export PATH="$TMP/bin:$PATH"
  mkdir -p "$PBRAIN_VAULT" "$PBRAIN_PLAN_DIR" "$PBRAIN_JOURNAL_DIR" "$PBRAIN_FITNESS_DIR" "$PBRAIN_DIET_DIR"
  SH="$REPO_ROOT/commands/end-of-day.sh"
}

teardown() {
  rm -rf "$TMP"
}

EOD() { bash "$SH" "$@"; }

# --- date validation ---------------------------------------------------------

@test "end-of-day: bad date format exits 1 with an error message" {
  run EOD --date not-a-date
  [ "$status" -eq 1 ]
  [[ "$output" == *"Bad date"* || "$stderr" == *"Bad date"* ]] || \
    [[ "$(bash "$SH" --date not-a-date 2>&1; echo "EXIT:$?")" == *"Bad date"* ]]
}

@test "end-of-day: --date YYYY-MM-DD is accepted (exit 0)" {
  run EOD --date 2026-06-03
  [ "$status" -eq 0 ]
}

@test "end-of-day: bare YYYY-MM-DD positional arg is accepted (exit 0)" {
  run EOD 2026-06-03
  [ "$status" -eq 0 ]
}

@test "end-of-day: --date sets the target date visible in output" {
  run EOD --date 2026-06-01
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-06-01"* ]]
}

@test "end-of-day: DOW is computed for the given past date (not just today)" {
  # 2026-06-01 is a Monday
  run EOD --date 2026-06-01
  [ "$status" -eq 0 ]
  [[ "$output" == *"Monday"* ]]
}

# ── task-log and weekly-goal rollup ─────────────────────────────────────────

@test "end-of-day: iso_week is present in output" {
  run EOD --date 2026-06-01
  [ "$status" -eq 0 ]
  [[ "$output" == *"iso_week:"* ]]
}

@test "end-of-day: weekly_goals_file is (not set up) when no store exists" {
  run EOD --date 2026-06-01
  [[ "$output" == *"weekly_goals_file: (not set up)"* ]]
}

@test "end-of-day: work-tracker actuals instructions mention Done at and Status" {
  run EOD --date 2026-06-01
  [[ "$output" == *"Done at"* ]] && [[ "$output" == *"Status"* ]]
}

@test "end-of-day: prompt drives the autostatus pass before consolidate" {
  run EOD --date 2026-06-01
  [ "$status" -eq 0 ]
  [[ "$output" == *"autostatus --date"* ]]
  [[ "$output" == *"status=missed"* ]]
}

@test "end-of-day: reconcile targets the ## Work tracker (PB-85 standalone schema)" {
  run EOD --date 2026-06-01
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Work tracker"* ]]
  [[ "$output" == *"% complete"* ]]
  [[ "$output" == *"Time taken"* ]]   # PB-85: new CEO column (replaces Est rating)
}

@test "PB-85: end-of-day surfaces glance_present and work_tracker_present flags" {
  run EOD --date 2026-06-01
  [ "$status" -eq 0 ]
  [[ "$output" == *"glance_present:"* ]]
  [[ "$output" == *"work_tracker_present:"* ]]
}

@test "PB-94: end-of-day reconciles WORK from Plane (Plane-only, no vault tracker)" {
  run EOD --date 2026-06-01
  [ "$status" -eq 0 ]
  # the close reconciles the work side from Plane, not a vault Work tracker
  [[ "$output" == *"WORK STATE IS PLANE-ONLY"* ]]
  [[ "$output" == *"WORK RECONCILE"* ]]
  # glance is still independent; a legacy tracker is reconciled only if present
  [[ "$output" == *"glance_present"* ]]
  [[ "$output" == *"work_tracker_present"* ]]
}

@test "end-of-day: injects the Plane reconcile context (completed + doing today)" {
  run EOD --date 2026-06-01
  [ "$status" -eq 0 ]
  [[ "$output" == *"plane_configured:"* ]]
  [[ "$output" == *"weekly_pids:"* ]]
  [[ "$output" == *"completed_in_plane_today:"* ]]
  [[ "$output" == *"doing_in_plane_now:"* ]]
  [[ "$output" == *"completed_in_plane_today:"* ]]
}

@test "end-of-day: unconfigured Plane skips sync — completed-today is []" {
  run EOD --date 2026-06-01
  [ "$status" -eq 0 ]
  [[ "$output" == *"plane_configured: no"* ]]
  [[ "$output" == *"completed_in_plane_today: []"* ]]
}

@test "end-of-day: instructions cover Plane sync + reconcile + unplanned (4k)" {
  run EOD --date 2026-06-01
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLANE SYNC + RECONCILE + UNPLANNED"* ]]
  [[ "$output" == *"plane_project"* ]]   # weekly-goal rollup matches by project
}

@test "PB-85: end-of-day 4k reconciles manual Plane changes back into the tracker" {
  run EOD --date 2026-06-01
  [ "$status" -eq 0 ]
  # Req 5: Plane → tracker reconcile of cancelled/done, both directions present.
  [[ "$output" == *"RECONCILE"* ]]
  [[ "$output" == *"cancelled in Plane"* ]]
  [[ "$output" == *"Plane is authoritative"* ]]
}

# ── Scoreboard markdown shape ────────────────────────────────────────────────

@test "Scoreboard: a blank line separates **Habits (scored)** from its table (GFM tables need it)" {
  # A markdown table must be preceded by a blank line, else the renderer folds
  # the bold label + rows into one paragraph and the table shows as raw text.
  # Regression guard for the Scoreboard "Habits (scored)" block in the template.
  run EOD --date 2026-06-01
  [ "$status" -eq 0 ]
  # the label and the table header must both be present
  [[ "$output" == *"**Habits (scored)**"* ]]
  [[ "$output" == *"| Habit | Score | Priority | Basis |"* ]]
  # walk the emitted lines: the line AFTER "**Habits (scored)**" must be blank
  # (not the table header glued directly onto the label).
  local found_label="" prev=""
  while IFS= read -r line; do
    if [ "$prev" = "**Habits (scored)**" ]; then
      found_label=1
      [ -z "$line" ] || {
        echo "FAIL: line after '**Habits (scored)**' is not blank: '$line'" >&2
        return 1
      }
    fi
    prev="${line#"${line%%[![:space:]]*}"}"   # left-trimmed line for the label compare
  done <<< "$output"
  [ -n "$found_label" ] || { echo "FAIL: '**Habits (scored)**' label not found in output" >&2; return 1; }
}
