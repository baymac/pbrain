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
  # Stub docker to exit 1 so _default_base_url's discovery finds no local Plane
  # (a real Plane on the dev box must not leak its port into the default).
  STUB="$TMP/nodock"; mkdir -p "$STUB"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/docker"; chmod +x "$STUB/docker"
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/project-manager.sh" config --api-key SECRET --workspace ws --project pid
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLANE_CONFIGURED"* ]]
  [[ "$output" == *"backend=plane"* ]]
  grep -q '"base_url": "http://localhost"' "$XDG_CONFIG_HOME/pbrain/plane.json"
  grep -q '"backend": "plane"' "$XDG_CONFIG_HOME/pbrain/plane.json"
}

@test "estimates --import-json caches the scale; estimate field then resolvable" {
  PM setup --base-url https://api.plane.so --api-key SECRET --workspace ws --project pid >/dev/null
  payload='[{"id":"e1","type":"points","last_used":true,"name":"Points","points":[{"id":"u1","value":"1"},{"id":"u3","value":"3"}]}]'
  run PM estimates --project pid --import-json "$payload" --hours-per-point 1.5
  [[ "$output" == *PM_ESTIMATES* ]] && [[ "$output" == *'"hours_per_point": 1.5'* ]] && grep -q '"3": "u3"' "$XDG_CONFIG_HOME/pbrain/plane.json"
}

@test "setup (Cloud/remote path) passes base-url through with no localhost default" {
  run PM setup --base-url https://api.plane.so --api-key SECRET --workspace ws --project pid
  [ "$status" -eq 0 ]
  [[ "$output" == *"PM_SETUP"* ]]
  grep -q '"base_url": "https://api.plane.so"' "$XDG_CONFIG_HOME/pbrain/plane.json"
}

@test "config auto-detects the vhost port from plane.env (loopback default)" {
  # Default flow runs vhost (off :80) before config; config picks the live
  # 127.0.0.1:<port> from plane.env instead of plain http://localhost.
  mkdir -p "$PBRAIN_PLANE_HOME"
  printf 'APP_DOMAIN=plane.localhost:1800\nLISTEN_HTTP_PORT=1800\n' > "$PBRAIN_PLANE_HOME/plane.env"
  PM config --api-key SECRET --workspace ws --project pid >/dev/null
  grep -q '"base_url": "http://127.0.0.1:1800"' "$XDG_CONFIG_HOME/pbrain/plane.json"
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

@test "an unknown first token routes to the NL router (not an error)" {
  # With the router, free text is an instruction, not an error: configured →
  # PM_ROUTE with the words echoed back.
  PM config --api-key SECRET --workspace ws --project pid >/dev/null
  run PM frobnicate the gym bug up to high
  [ "$status" -eq 0 ]
  [[ "$output" == *"PM_ROUTE"* && "$output" == *"instruction: frobnicate the gym bug up to high"* ]]
}

# --- the richer write/lookup verbs (the catalogue) --------------------------
@test "a write verb is gated by the Plane guard when unset" {
  run PM tag PB-1 --add backend
  [ "$status" -eq 0 ]
  [[ "$output" == *"PM_NOT_CONFIGURED"* ]]
}

@test "find + write/lookup verbs emit their PM_* tokens (engine degrades on unreachable Plane)" {
  PM setup --base-url http://127.0.0.1:9 --api-key SECRET --workspace ws --project pid >/dev/null
  run PM find PB-1;                   [[ "$output" == *"PM_FIND"* ]]
  run PM tag PB-1 --add x;            [[ "$output" == *"PM_TAG"* ]]
  run PM comment PB-1 --body hi;      [[ "$output" == *"PM_COMMENT"* ]]
  run PM assign PB-1 --to kylo;       [[ "$output" == *"PM_ASSIGN"* ]]
  run PM reparent PB-1 --parent PB-2; [[ "$output" == *"PM_REPARENT"* ]]
  run PM update --edits '[]';         [[ "$output" == *"PM_UPDATE"* ]]
  run PM labels;                      [[ "$output" == *"PM_LABELS"* ]]
}

# --- the NL router (D2) + dual-mode (D3) ------------------------------------
@test "route emits PM_ROUTE with the catalogue and is goal-aware when invoked directly" {
  PM config --api-key SECRET --workspace ws --project pid >/dev/null
  run PM route tag PB-1 backend
  [ "$status" -eq 0 ]
  [[ "$output" == *"PM_ROUTE"* && "$output" == *"instruction: tag PB-1 backend"* \
     && "$output" == *"caller: direct"* && "$output" == *"PLANNING CONTEXT"* && "$output" == *"CATALOGUE"* ]]
}

@test "executor mode (PBRAIN_PM_CALLER) skips the planning context" {
  PM config --api-key SECRET --workspace ws --project pid >/dev/null
  PBRAIN_PM_CALLER=plan-my-work run PM route move PB-1 to todo
  [ "$status" -eq 0 ]
  [[ "$output" == *"caller: plan-my-work"* && "$output" == *"EXECUTOR MODE"* \
     && "$output" != *"PLANNING CONTEXT"* ]]
}
