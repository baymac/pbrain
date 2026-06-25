#!/usr/bin/env bats
# e2e harness for /fitness-journal (PB-110 revised) — the THIRD command on the
# framework. Exercises the sleep-capture contract end-to-end: sleep is mandatory
# to ASK, carried forward from a real prior entry ONLY on confirmation, and NEVER
# fabricated from the profile's typical window.
#
# Runs the REAL commands/fitness-journal.sh against a temp vault (seeded with a
# committed profile/library/activity-profile so it reaches the daily LOG flow) and
# replays the agent's documented role (ask → confirm-or-skip → write the dated
# file). The tracking channel is the REAL markdown artifact and its sleep_*
# frontmatter (tracking_kind=vault-file), shown alongside the chat in the report.
#
#   bats tests/e2e-fitness.bats        # fitness runs only (partial report)
#   bats tests/                        # union report across all e2e commands
#
# Shares the .e2e_report/.results dir + report.py with the other e2e suites, so a
# `bats tests/` invocation folds fitness into the one union HTML report.

setup_file() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  export E2E_DIR="$REPO_ROOT/tests/e2e"
  export E2E_REPORT_DIR="$REPO_ROOT/.e2e_report"
  export E2E_RESULTS="$E2E_REPORT_DIR/.results"
  mkdir -p "$E2E_RESULTS"
  _e2e_fresh_results
}

# Clear results once per `bats` invocation (keyed on the bats parent PID) so a
# fresh run starts clean, but suites in the SAME invocation accumulate into one
# union report. Idempotent across suites via the PPID marker.
_e2e_fresh_results() {
  local marker="$E2E_RESULTS/.run-$PPID"
  if [ ! -e "$marker" ]; then
    rm -f "$E2E_RESULTS"/*.result.json "$E2E_RESULTS"/*.transcript.txt "$E2E_RESULTS"/.run-* 2>/dev/null || true
    : >"$marker"
  fi
}

teardown_file() {
  if command -v python3 >/dev/null 2>&1 && [ -n "$(ls -A "$E2E_RESULTS" 2>/dev/null)" ]; then
    report="$(python3 "$E2E_DIR/report.py" "$E2E_RESULTS" "$E2E_REPORT_DIR" 2>/dev/null)" || true
    [ -n "$report" ] && echo "# e2e report: $report" >&3
  fi
}

setup() {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  export PBRAIN_MIGRATIONS=0 PBRAIN_UPDATE_CHECK=0 PBRAIN_SELF_IMPROVE=off
  load "e2e/fitness-journal.bash"
  load "e2e/fitness-clock.bash"
}

@test "fitness × fast → sleep given this session (fresh reading, no provenance)" {
  run e2e_run_fitness "$REPO_ROOT" "$E2E_DIR/scenarios/fitness-journal/sleep/captured.json" \
                      "$E2E_DIR/personas/fast/persona.md" "$E2E_RESULTS"
  [ "$status" -eq 0 ]
}

@test "fitness × fast → sleep withheld, left blank (no carry, no fabrication)" {
  run e2e_run_fitness "$REPO_ROOT" "$E2E_DIR/scenarios/fitness-journal/sleep/cold.json" \
                      "$E2E_DIR/personas/fast/persona.md" "$E2E_RESULTS"
  [ "$status" -eq 0 ]
}

@test "fitness × cautious → sleep withheld, left blank (no carry, no fabrication)" {
  run e2e_run_fitness "$REPO_ROOT" "$E2E_DIR/scenarios/fitness-journal/sleep/cold.json" \
                      "$E2E_DIR/personas/cautious/persona.md" "$E2E_RESULTS"
  [ "$status" -eq 0 ]
}

@test "fitness × fast → future session time logs as planned, no fabricated actuals (PB-117)" {
  run e2e_run_fitness_clock "$REPO_ROOT" "$E2E_DIR/scenarios/fitness-journal/clock/future-planned.json" \
                            "$E2E_DIR/personas/fast/persona.md" "$E2E_RESULTS"
  [ "$status" -eq 0 ]
}

@test "fitness × fast → past session time + done logs as completed, both sections (PB-117)" {
  run e2e_run_fitness_clock "$REPO_ROOT" "$E2E_DIR/scenarios/fitness-journal/clock/past-completed.json" \
                            "$E2E_DIR/personas/fast/persona.md" "$E2E_RESULTS"
  [ "$status" -eq 0 ]
}
