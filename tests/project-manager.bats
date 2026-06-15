#!/usr/bin/env bats
# Tests for /project-manager (commands/project-manager.sh) — the Plane commander.
# It sources lib/vault.sh, so a (test) vault is provided via PBRAIN_VAULT. We
# don't drive real Docker or Plane; we test dispatch + token emission, the
# absorbed init-plane setup wizard (probe/config/status), flag parsing, and that
# the ops degrade gracefully (PLANE_ERROR, never a stack trace) when Plane is
# unreachable.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0 PBRAIN_UPDATE_CHECK=0 PBRAIN_SELF_IMPROVE=off
  export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/pbrain"
  export PBRAIN_VAULT="$TMP/vault"; mkdir -p "$PBRAIN_VAULT"
  export PBRAIN_PLANE_HOME="$TMP/plane-selfhost"
  unset PBRAIN_PLANE_API_KEY PBRAIN_PLANE_BASE_URL PBRAIN_PLANE_WORKSPACE PBRAIN_PLANE_PROJECT
  PM() { bash "$REPO_ROOT/commands/project-manager.sh" "$@"; }
}
teardown() { rm -rf "$TMP"; }

# --- absorbed init-plane setup wizard ---------------------------------------
@test "probe (default) prints the wizard state keys" {
  run PM
  [ "$status" -eq 0 ]
  [[ "$output" == *"INIT_PLANE_PROBE"* ]]
  for k in docker docker_running compose selfhost_dir setup_sh plane_config plane_running configured default_url portless node; do
    [[ "$output" == *"$k:"* ]]
  done
  [[ "$output" == *"default_url: http://localhost"* ]]
  [[ "$output" == *"configured: no"* ]]
}

@test "config wires pbrain to the local instance and flips backend to plane" {
  run PM config --api-key SECRET --workspace ws --project pid
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLANE_CONFIGURED"* ]]
  [[ "$output" == *"backend=plane"* ]]
  grep -q '"base_url": "http://localhost"' "$XDG_CONFIG_HOME/pbrain/plane.json"
  grep -q '"backend": "plane"' "$XDG_CONFIG_HOME/pbrain/plane.json"
}

@test "setup (Cloud/remote path) passes base-url through with no localhost default" {
  run PM setup --base-url https://api.plane.so --api-key SECRET --workspace ws --project pid
  [ "$status" -eq 0 ]
  [[ "$output" == *"PM_SETUP"* ]]
  grep -q '"base_url": "https://api.plane.so"' "$XDG_CONFIG_HOME/pbrain/plane.json"
}

@test "status reflects config + backend" {
  PM config --api-key SECRET --workspace ws --project pid >/dev/null
  run PM status
  [ "$status" -eq 0 ]
  [[ "$output" == *"INIT_PLANE_STATUS"* ]]
  [[ "$output" == *"configured: yes"* ]]
}

@test "use switches the backend" {
  PM config --api-key SECRET --workspace ws --project pid >/dev/null
  run PM use markdown
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLANE_BACKEND markdown"* ]]
}

# --- ops guard: Plane not configured ----------------------------------------
@test "ops emit PM_NOT_CONFIGURED when Plane isn't set up; setup family still runs" {
  # Unconfigured (no plane.json, no env): every op subcommand short-circuits.
  for sub in ready progress review projects test move priority timeline; do
    run PM "$sub"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PM_NOT_CONFIGURED"* ]]
  done
  # The setup family still runs unconfigured (probe here).
  run PM probe
  [ "$status" -eq 0 ]
  [[ "$output" == *"INIT_PLANE_PROBE"* ]]
  [[ "$output" != *"PM_NOT_CONFIGURED"* ]]
}

# --- ops: token emission + graceful degrade ---------------------------------
@test "projects prints PM_PROJECTS and the synthesized registry" {
  PM config --api-key SECRET --workspace ws --project pid >/dev/null
  run PM projects
  [ "$status" -eq 0 ]
  [[ "$output" == *"PM_PROJECTS"* ]]
  [[ "$output" == *'"id": "pid"'* ]]   # lone project → one-entry registry
}

@test "ready against an unreachable Plane emits PM_READY then degrades to [] (never a trace)" {
  PM setup --base-url http://127.0.0.1:9 --api-key SECRET --workspace ws --project pid >/dev/null
  run PM ready --projects pid
  [ "$status" -eq 0 ]
  [[ "$output" == *"PM_READY"* ]]
  [[ "$output" == *"[]"* ]]   # ready_multi degrades per-project, never partial garbage
  [[ "$output" != *"Traceback"* ]]
}

@test "progress + review emit their tokens and degrade gracefully" {
  PM setup --base-url http://127.0.0.1:9 --api-key SECRET --workspace ws --project pid >/dev/null
  run PM progress --projects pid --since 2026-06-01
  [ "$status" -eq 0 ]; [[ "$output" == *"PM_PROGRESS"* ]]
  run PM review --projects pid
  [ "$status" -eq 0 ]; [[ "$output" == *"PM_REVIEW"* ]]
}

@test "move/priority/timeline require a tie + value" {
  # Configure Plane so the ops guard passes and we exercise the arg validation.
  PM config --api-key SECRET --workspace ws --project pid >/dev/null
  run PM move
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
  run PM priority pid:abc
  [ "$status" -ne 0 ]
  run PM timeline pid:abc
  [ "$status" -ne 0 ]
}

@test "move with a tie + --to emits PM_MOVE and degrades on unreachable Plane" {
  PM setup --base-url http://127.0.0.1:9 --api-key SECRET --workspace ws --project pid >/dev/null
  run PM move pid:abc --to done
  [ "$status" -eq 0 ]
  [[ "$output" == *"PM_MOVE"* ]]
}

@test "unknown subcommand exits non-zero with a hint" {
  run PM frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown /project-manager subcommand"* ]]
}
