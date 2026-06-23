#!/usr/bin/env bats
# Tests /plan-my-work (commands/plan-my-work.sh) — the EXECUTION layer (PB-94).
# pmw was stripped to ONE loop: it takes a single Plane issue id and emits the
# execute dispatch (PLAN_MY_WORK_EXECUTE), or PLAN_MY_WORK_NEEDS_ID when given no
# id (it never selects tasks — that's groom's job), or PLAN_MY_WORK_NO_PLANE when
# Plane isn't configured. The daily-planning machinery (## Work tracker, session
# flow, task add/remove/list, plans-profile, blocks/alloc) is GONE. These tests
# assert the new dispatch shape + that pmw writes nothing to the vault.
#
# Run with: bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0 PBRAIN_UPDATE_CHECK=0 PBRAIN_SELF_IMPROVE=off
  export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/pbrain"
  export PBRAIN_VAULT="$TMP/vault"; mkdir -p "$PBRAIN_VAULT"
  unset PBRAIN_PLANE_API_KEY PBRAIN_PLANE_BASE_URL PBRAIN_PLANE_WORKSPACE PBRAIN_PLANE_PROJECT
  TODAY="$(date +%Y-%m-%d)"
  PMW() { bash "$REPO_ROOT/commands/plan-my-work.sh" "$@"; }
}
teardown() { rm -rf "$TMP"; }

# Configure Plane (an unreachable instance is fine — pbrain_plane_configured only
# checks for an api_key; the loop is read-only here, no live calls are made).
configure_plane() {
  cat > "$XDG_CONFIG_HOME/pbrain/plane.json" <<'JSON'
{"base_url":"http://127.0.0.1:9","api_key":"SECRET","workspace":"ws","project":"pid"}
JSON
}

# --- guards -----------------------------------------------------------------

@test "no Plane configured → PLAN_MY_WORK_NO_PLANE (the loop's state lives in Plane)" {
  run PMW pb96
  [ "$status" -eq 0 ]
  [[ "$output" == *PLAN_MY_WORK_NO_PLANE* ]]
}

@test "Plane configured, no id → PLAN_MY_WORK_NEEDS_ID (never selects tasks)" {
  configure_plane
  run PMW
  [ "$status" -eq 0 ]
  [[ "$output" == *PLAN_MY_WORK_NEEDS_ID* ]]
  # it must point the agent at groom for selection, not pick work itself
  [[ "$output" == *groom* ]]
}

# --- the single execute loop ------------------------------------------------

@test "a bare PB id → PLAN_MY_WORK_EXECUTE with target_kind id" {
  configure_plane
  run PMW pb96
  [ "$status" -eq 0 ]
  [[ "$output" == *PLAN_MY_WORK_EXECUTE* ]]
  [[ "$output" == *"target_ref: pb96"* ]]
  [[ "$output" == *"target_kind: id"* ]]
}

@test "back-compat: task execute <id> routes to the same execute path" {
  configure_plane
  run PMW task execute pb96
  [ "$status" -eq 0 ]
  [[ "$output" == *PLAN_MY_WORK_EXECUTE* ]]
  [[ "$output" == *"target_ref: pb96"* ]]
}

@test "NL 'work on pb96' → execute, id kind" {
  configure_plane
  run PMW work on pb96
  [ "$status" -eq 0 ]
  [[ "$output" == *PLAN_MY_WORK_EXECUTE* ]]
  [[ "$output" == *"target_ref: pb96"* ]]
  [[ "$output" == *"target_kind: id"* ]]
}

@test "NL 'fix the routing bug' → execute, desc kind (find-or-file)" {
  configure_plane
  run PMW fix the routing bug
  [ "$status" -eq 0 ]
  [[ "$output" == *PLAN_MY_WORK_EXECUTE* ]]
  [[ "$output" == *"target_kind: desc"* ]]
  # leading verb + connective ("fix the") are stripped → "routing bug"
  [[ "$output" == *"target_ref: routing bug"* ]]
}

@test "NL bare verb 'do some work' → no target → NEEDS_ID (no task selection)" {
  configure_plane
  run PMW do some work
  [ "$status" -eq 0 ]
  [[ "$output" == *PLAN_MY_WORK_NEEDS_ID* ]]
}

@test "execute dispatch carries the loop's context (PM cmd, web base, workdirs)" {
  configure_plane
  run PMW pb96
  [ "$status" -eq 0 ]
  [[ "$output" == *"project_manager_cmd:"* ]]
  [[ "$output" == *"plane_web_base:"* ]]
  [[ "$output" == *"WORKING LOCATIONS"* ]]
}

# --- removed surfaces -------------------------------------------------------

@test "task add|remove|list were removed in PB-94 (rejected with usage)" {
  configure_plane
  run PMW task list
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* || "$output" == *"removed in PB-94"* ]]
}

@test "pmw writes NOTHING to the vault (Plane-only state)" {
  configure_plane
  run PMW pb96
  [ "$status" -eq 0 ]
  # no daily-planning file, no work tracker, nothing under the vault
  run find "$PBRAIN_VAULT" -type f
  [ -z "$output" ]
}
