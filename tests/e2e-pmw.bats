#!/usr/bin/env bats
# e2e harness for /plan-my-work's execute loop (PB-89).
#
# This is the e2e LAYER, distinct from the unit suites in tests/*.bats. It runs
# the REAL commands/project-manager.sh against a faked Plane boundary
# (tests/e2e/fake_plane.py) and a throwaway git repo, driving each scenario
# through the 5-stage pipeline (execute.txt) once PER PERSONA — the agent↔agent
# replay (PB-89 comment 2: distinct personas/prefs must all behave correctly).
#
# Each (scenario × persona) is one @test. Results land as *.result.json in a
# shared dir; teardown_file aggregates them into ONE standalone, timestamped
# HTML report under .e2e_report/ (gitignored).
#
#   bats tests/e2e-pmw.bats
#
# Skips cleanly if `git` or `python3` is unavailable.

setup_file() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  export E2E_DIR="$REPO_ROOT/tests/e2e"
  export E2E_REPORT_DIR="$REPO_ROOT/.e2e_report"
  # Shared, stable results dir so `bats tests/` yields ONE union report across
  # every e2e command suite (pmw + journal + …). report.py globs whatever is
  # present, so running a single suite alone yields a partial report.
  export E2E_RESULTS="$E2E_REPORT_DIR/.results"
  mkdir -p "$E2E_RESULTS"
  _e2e_fresh_results
}

# Clear results once per `bats` invocation (keyed on the bats parent PID) so a
# fresh run starts clean, but multiple suites in the SAME invocation accumulate
# into one union report. PPID is shared across suite files of one `bats tests/`.
_e2e_fresh_results() {
  local marker="$E2E_RESULTS/.run-$PPID"
  if [ ! -e "$marker" ]; then
    rm -f "$E2E_RESULTS"/*.result.json "$E2E_RESULTS"/*.transcript.txt "$E2E_RESULTS"/.run-* 2>/dev/null || true
    : >"$marker"
  fi
}

teardown_file() {
  # Aggregate all results present into one standalone HTML report (PB-89).
  if command -v python3 >/dev/null 2>&1 && [ -n "$(ls -A "$E2E_RESULTS" 2>/dev/null)" ]; then
    report="$(python3 "$E2E_DIR/report.py" "$E2E_RESULTS" "$E2E_REPORT_DIR" 2>/dev/null)" || true
    [ -n "$report" ] && echo "# e2e report: $report" >&3
  fi
}

setup() {
  command -v git >/dev/null 2>&1 || skip "git not available"
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  export PBRAIN_MIGRATIONS=0 PBRAIN_UPDATE_CHECK=0 PBRAIN_SELF_IMPROVE=off
  load "e2e/harness.bash"
}

# --- one @test per (scenario × persona) -------------------------------------
# Personas: fast (passes every manual gate) and cautious (passes none).

@test "approved-fastpath × fast → reaches done (all auto:* + CI green)" {
  run e2e_run "$REPO_ROOT" "$E2E_DIR/scenarios/approved-fastpath.json" \
              "$E2E_DIR/personas/fast.md" "$E2E_RESULTS"
  [ "$status" -eq 0 ]
}

@test "approved-fastpath × cautious → reaches done (all gates auto, no manual go needed)" {
  run e2e_run "$REPO_ROOT" "$E2E_DIR/scenarios/approved-fastpath.json" \
              "$E2E_DIR/personas/cautious.md" "$E2E_RESULTS"
  [ "$status" -eq 0 ]
}

@test "unapproved-fallback × cautious → drafts plan, parks at implement (durable)" {
  run e2e_run "$REPO_ROOT" "$E2E_DIR/scenarios/unapproved-fallback.json" \
              "$E2E_DIR/personas/cautious.md" "$E2E_RESULTS"
  [ "$status" -eq 0 ]
}

@test "unapproved-fallback × fast → manual go's carry it through to done" {
  # fast persona approves implement/test/ship/land manually; only auto:plan set.
  # Same fixture as #3, but this persona's go's carry it to done — so override the
  # expected terminal. Use a NAMED scenario (not a bare mktemp) + a `display`
  # field so the report grid shows a friendly label, not "tmp.XXce…".
  variant="$E2E_RESULTS/unapproved-fallback-carrythrough.json"
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
d["expect"]="done"
d["display"]="unapproved-fallback (fast carries through to done)"
json.dump(d,open(sys.argv[2],"w"))' \
    "$E2E_DIR/scenarios/unapproved-fallback.json" "$variant"
  run e2e_run "$REPO_ROOT" "$variant" "$E2E_DIR/personas/fast.md" "$E2E_RESULTS"
  rm -f "$variant"
  [ "$status" -eq 0 ]
}

@test "gh-absent-handback × fast → pushes branch, hands back URL, no fabricated PR" {
  run e2e_run "$REPO_ROOT" "$E2E_DIR/scenarios/gh-absent-handback.json" \
              "$E2E_DIR/personas/fast.md" "$E2E_RESULTS"
  [ "$status" -eq 0 ]
}

@test "ci-red-hardstop × fast → auto:land + CI red hard-stops merge (no done)" {
  run e2e_run "$REPO_ROOT" "$E2E_DIR/scenarios/ci-red-hardstop.json" \
              "$E2E_DIR/personas/fast.md" "$E2E_RESULTS"
  [ "$status" -eq 0 ]
}

# --- multi-loop: dependency-aware (blocked_by) + parent/sub-issues (PB-81) ---

@test "blocked-by-chain × fast → blocker PB-811 lands first, then primary PB-812" {
  run e2e_run "$REPO_ROOT" "$E2E_DIR/scenarios/blocked-by-chain.json" \
              "$E2E_DIR/personas/fast.md" "$E2E_RESULTS"
  [ "$status" -eq 0 ]
}

@test "blocked-by-parks × cautious → blocker parks, primary never starts" {
  run e2e_run "$REPO_ROOT" "$E2E_DIR/scenarios/blocked-by-parks.json" \
              "$E2E_DIR/personas/cautious.md" "$E2E_RESULTS"
  [ "$status" -eq 0 ]
}

@test "parent-subissues × fast → each child lands, parent PB-820 closed last" {
  run e2e_run "$REPO_ROOT" "$E2E_DIR/scenarios/parent-subissues.json" \
              "$E2E_DIR/personas/fast.md" "$E2E_RESULTS"
  [ "$status" -eq 0 ]
}

@test "unapproved-deep-park × cautious → auto through ship, parks at land (CI green)" {
  run e2e_run "$REPO_ROOT" "$E2E_DIR/scenarios/unapproved-deep-park.json" \
              "$E2E_DIR/personas/cautious.md" "$E2E_RESULTS"
  [ "$status" -eq 0 ]
}
