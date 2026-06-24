#!/usr/bin/env bats
# e2e harness for /journal (PB-89) — the SECOND command on the framework,
# demonstrating it generalizes beyond /plan-my-work.
#
# Runs the REAL commands/journal.sh against a temp vault and replays the agent's
# documented role (ingest dump → optional one follow-up → write the dated file).
# The tracking channel is the REAL markdown artifact journal.sh produces
# (tracking_kind=vault-file), shown alongside the chat in the report.
#
#   bats tests/e2e-journal.bats        # journal runs only (partial report)
#   bats tests/                        # union report across all e2e commands
#
# Both e2e suites write *.result.json into a shared, stable results dir under
# .e2e_report/.results, and each calls report.py in teardown_file — report.py
# globs whatever results exist, so running `bats tests/` produces ONE combined
# report covering every command. Skips cleanly without git/python3.

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
  load "e2e/journal.bash"
}

@test "journal × cautious → factual log, no follow-up, fresh file written" {
  run e2e_run_journal "$REPO_ROOT" "$E2E_DIR/scenarios/journal-factual.json" \
                      "$E2E_DIR/personas/cautious.md" "$E2E_RESULTS"
  [ "$status" -eq 0 ]
}

@test "journal × fast → reflective entry, exactly one follow-up" {
  run e2e_run_journal "$REPO_ROOT" "$E2E_DIR/scenarios/journal-reflective.json" \
                      "$E2E_DIR/personas/fast.md" "$E2E_RESULTS"
  [ "$status" -eq 0 ]
}

@test "journal × cautious → resume appends under ## Log, preserves curated sections" {
  run e2e_run_journal "$REPO_ROOT" "$E2E_DIR/scenarios/journal-resume.json" \
                      "$E2E_DIR/personas/cautious.md" "$E2E_RESULTS"
  [ "$status" -eq 0 ]
}
