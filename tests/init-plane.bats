#!/usr/bin/env bats
# Tests for /init-plane (commands/init-plane.sh). Like /init-obsidian and
# /codex-install it bypasses lib/vault.sh, so no vault is needed. We don't drive
# real Docker or Plane here — we test the probe output shape, idempotent config
# wiring (delegates to lib/plane.py), backend reflection, and the guard paths.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/pbrain"
  export PBRAIN_PLANE_HOME="$TMP/plane-selfhost"
  unset PBRAIN_PLANE_API_KEY PBRAIN_PLANE_BASE_URL PBRAIN_PLANE_WORKSPACE PBRAIN_PLANE_PROJECT
  IP() { bash "$REPO_ROOT/commands/init-plane.sh" "$@"; }
}
teardown() { rm -rf "$TMP"; }

@test "probe prints the expected state keys" {
  run IP probe
  [ "$status" -eq 0 ]
  [[ "$output" == *"INIT_PLANE_PROBE"* ]]
  for k in docker docker_running compose selfhost_dir setup_sh plane_config plane_running configured default_url setup_url; do
    [[ "$output" == *"$k:"* ]]
  done
  [[ "$output" == *"default_url: http://localhost"* ]]
}

@test "probe on a fresh machine reports no config and not configured" {
  run IP probe
  [[ "$output" == *"plane_config: absent"* ]]
  [[ "$output" == *"configured: no"* ]]
}

@test "config wires pbrain to the local instance and switches backend to plane" {
  run IP config --api-key SECRET --workspace ws --project pid
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLANE_CONFIGURED"* ]]
  [[ "$output" == *"backend=plane"* ]]
  [ -f "$XDG_CONFIG_HOME/pbrain/plane.json" ]
  grep -q '"base_url": "http://localhost"' "$XDG_CONFIG_HOME/pbrain/plane.json"   # defaulted
  grep -q '"backend": "plane"' "$XDG_CONFIG_HOME/pbrain/plane.json"
}

@test "config respects an explicit --base-url (e.g. Plane Cloud)" {
  run IP config --base-url https://api.plane.so --api-key SECRET --workspace ws --project pid
  [ "$status" -eq 0 ]
  grep -q '"base_url": "https://api.plane.so"' "$XDG_CONFIG_HOME/pbrain/plane.json"
}

@test "probe reflects the config + configured state after wiring" {
  IP config --api-key SECRET --workspace ws --project pid >/dev/null
  run IP probe
  [[ "$output" == *"plane_config: present"* ]]
  [[ "$output" == *"configured: yes"* ]]
}

@test "config is idempotent and the token file is 0600" {
  IP config --api-key SECRET --workspace ws --project pid >/dev/null
  IP config --api-key SECRET --workspace ws --project pid >/dev/null
  perm="$(stat -f '%Lp' "$XDG_CONFIG_HOME/pbrain/plane.json" 2>/dev/null || stat -c '%a' "$XDG_CONFIG_HOME/pbrain/plane.json")"
  [ "$perm" = "600" ]
}

@test "probe reports portless availability" {
  run IP probe
  [[ "$output" == *"portless:"* ]]
  [[ "$output" == *"node:"* ]]
}

@test "portless without portless installed gives an install hint (no crash)" {
  # Strip any real portless from PATH so the missing-branch fires.
  STUB="$TMP/nobin"; mkdir -p "$STUB"
  for b in bash dirname readlink python3 grep curl docker node; do
    src="$(command -v "$b" 2>/dev/null)"; [ -n "$src" ] && ln -sf "$src" "$STUB/$b"
  done
  run env PATH="$STUB" bash "$REPO_ROOT/commands/init-plane.sh" portless
  [ "$status" -eq 0 ]
  [[ "$output" == *"INIT_PLANE_PORTLESS_MISSING"* ]]
  [[ "$output" == *"npm install -g portless"* ]]
}

@test "portless registers a static alias and re-points pbrain base_url" {
  # Wire pbrain to Plane first so creds exist to preserve.
  IP config --api-key SECRET --workspace ws --project pid >/dev/null
  # Stub the portless CLI to capture its args and succeed.
  STUB="$TMP/bin"; mkdir -p "$STUB"
  printf '#!/usr/bin/env bash\necho "$@" >> "$PORTLESS_LOG"\nexit 0\n' > "$STUB/portless"
  chmod +x "$STUB/portless"
  export PORTLESS_LOG="$TMP/portless.log"
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" portless
  [ "$status" -eq 0 ]
  [[ "$output" == *"INIT_PLANE_PORTLESS"* ]]
  [[ "$output" == *"https://plane.localhost"* ]]
  # the alias call carried the right name + Plane port + idempotent --force
  grep -q "alias plane 80 --force" "$PORTLESS_LOG"
  # base_url re-pointed, creds preserved
  grep -q '"base_url": "https://plane.localhost"' "$XDG_CONFIG_HOME/pbrain/plane.json"
  grep -q '"api_key": "SECRET"' "$XDG_CONFIG_HOME/pbrain/plane.json"
  grep -q '"workspace": "ws"' "$XDG_CONFIG_HOME/pbrain/plane.json"
}

@test "portless --name and --plane-port flow through; --no-tls flips scheme" {
  IP config --api-key SECRET --workspace ws --project pid >/dev/null
  STUB="$TMP/bin"; mkdir -p "$STUB"
  printf '#!/usr/bin/env bash\necho "$@" >> "$PORTLESS_LOG"\nexit 0\n' > "$STUB/portless"
  chmod +x "$STUB/portless"
  export PORTLESS_LOG="$TMP/portless2.log"
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" portless --name proj --plane-port 8080 --no-tls
  [ "$status" -eq 0 ]
  [[ "$output" == *"http://proj.localhost"* ]]
  grep -q "alias proj 8080 --force" "$PORTLESS_LOG"
  grep -q '"base_url": "http://proj.localhost"' "$XDG_CONFIG_HOME/pbrain/plane.json"
}

@test "portless --remove tears down the alias and restores the local URL" {
  IP config --base-url https://plane.localhost --api-key SECRET --workspace ws --project pid >/dev/null
  STUB="$TMP/bin"; mkdir -p "$STUB"
  printf '#!/usr/bin/env bash\necho "$@" >> "$PORTLESS_LOG"\nexit 0\n' > "$STUB/portless"
  chmod +x "$STUB/portless"
  export PORTLESS_LOG="$TMP/portless3.log"
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" portless --remove
  [ "$status" -eq 0 ]
  grep -q "alias --remove plane" "$PORTLESS_LOG"
  grep -q '"base_url": "http://localhost"' "$XDG_CONFIG_HOME/pbrain/plane.json"
}

@test "up before fetch tells the user to fetch first (no crash)" {
  run IP up
  [ "$status" -eq 0 ]
  [[ "$output" == *"INIT_PLANE_NEED_FETCH"* ]]
}

@test "help prints the header without error" {
  run IP help
  [ "$status" -eq 0 ]
  [[ "$output" == *"local Plane self-host setup wizard"* ]]
}

@test "unknown subcommand exits non-zero with guidance" {
  run IP frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown /init-plane subcommand"* ]]
}
