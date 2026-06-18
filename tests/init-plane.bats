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
  # Stub docker to exit 1 so _default_base_url's discovery finds no local Plane
  # (a real Plane on the dev box must not leak its port into the default).
  STUB="$TMP/nodock"; mkdir -p "$STUB"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/docker"; chmod +x "$STUB/docker"
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" config --api-key SECRET --workspace ws --project pid
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

@test "config auto-detects the vhost port from plane.env (defaults base_url to the loopback)" {
  # Default flow runs vhost (off :80) before config; config should pick the live
  # 127.0.0.1:<port> from plane.env rather than the plain http://localhost.
  _seed_plane_env 1800
  IP config --api-key SECRET --workspace ws --project pid >/dev/null
  grep -q '"base_url": "http://127.0.0.1:1800"' "$XDG_CONFIG_HOME/pbrain/plane.json"
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

@test "probe reports plane_env (absent when no PBRAIN_PLANE_HOME plane.env)" {
  # Force docker discovery to find nothing so a real Plane on the dev box
  # doesn't leak into the result.
  STUB="$TMP/nodock"; mkdir -p "$STUB"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/docker"; chmod +x "$STUB/docker"
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" probe
  [[ "$output" == *"plane_env: absent"* ]]
}

@test "probe reflects vhost state when plane.env is seeded" {
  _seed_plane_env
  run IP probe
  [[ "$output" == *"plane_env: $PBRAIN_PLANE_HOME/plane.env"* ]]
  [[ "$output" == *"vhost_port: 80"* ]]
  [[ "$output" == *"vhost_domain: localhost"* ]]
}

# --- vhost --------------------------------------------------------------------
# Sketch a fake Plane install (plane.env in PBRAIN_PLANE_HOME) and stub the
# `docker` CLI so info/compose are silent no-ops. We do NOT exercise the
# discovery-by-docker-inspect fallback here — the explicit PBRAIN_PLANE_HOME
# path is the documented one.
_seed_plane_env() {
  local port="${1:-80}" dom="${2:-localhost}"
  mkdir -p "$PBRAIN_PLANE_HOME"
  cat > "$PBRAIN_PLANE_HOME/plane.env" <<ENV
APP_DOMAIN=$dom
LISTEN_HTTP_PORT=$port
LISTEN_HTTPS_PORT=443
WEB_URL=http://\${APP_DOMAIN}
CORS_ALLOWED_ORIGINS=http://\${APP_DOMAIN}
ENV
}
_stub_docker() {
  STUB="$TMP/bin"; mkdir -p "$STUB"
  printf '#!/usr/bin/env bash\nif [[ "$1" == info ]]; then exit 0; fi\nif [[ "$1" == compose ]]; then exit 0; fi\nexit 0\n' > "$STUB/docker"
  chmod +x "$STUB/docker"
  echo "$STUB"
}

@test "vhost without plane.env reports INIT_PLANE_VHOST_NO_ENV (no crash)" {
  STUB="$(_stub_docker)"
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" vhost
  [ "$status" -eq 0 ]
  [[ "$output" == *"INIT_PLANE_VHOST_NO_ENV"* ]]
}

@test "vhost edits plane.env, backs it up, and re-points pbrain to 127.0.0.1" {
  IP config --api-key SECRET --workspace ws --project pid >/dev/null
  _seed_plane_env
  STUB="$(_stub_docker)"
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" vhost
  [ "$status" -eq 0 ]
  [[ "$output" == *"INIT_PLANE_VHOST"* ]]
  [[ "$output" == *"http://plane.localhost:1800"* ]]
  grep -q '^APP_DOMAIN=plane.localhost:1800$' "$PBRAIN_PLANE_HOME/plane.env"
  grep -q '^LISTEN_HTTP_PORT=1800$' "$PBRAIN_PLANE_HOME/plane.env"
  [ -f "$PBRAIN_PLANE_HOME/plane.env.pbrain-bak" ]
  grep -q '"base_url": "http://127.0.0.1:1800"' "$XDG_CONFIG_HOME/pbrain/plane.json"
  grep -q '"api_key": "SECRET"' "$XDG_CONFIG_HOME/pbrain/plane.json"
  grep -q '"workspace": "ws"' "$XDG_CONFIG_HOME/pbrain/plane.json"
}

@test "vhost --host and --port flow through into plane.env and pbrain" {
  IP config --api-key SECRET --workspace ws --project pid >/dev/null
  _seed_plane_env
  STUB="$(_stub_docker)"
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" vhost --host proj.localhost --port 8080
  [ "$status" -eq 0 ]
  [[ "$output" == *"http://proj.localhost:8080"* ]]
  grep -q '^APP_DOMAIN=proj.localhost:8080$' "$PBRAIN_PLANE_HOME/plane.env"
  grep -q '^LISTEN_HTTP_PORT=8080$' "$PBRAIN_PLANE_HOME/plane.env"
  grep -q '"base_url": "http://127.0.0.1:8080"' "$XDG_CONFIG_HOME/pbrain/plane.json"
}

@test "vhost --remove restores plane.env from the backup and resets base_url" {
  IP config --api-key SECRET --workspace ws --project pid >/dev/null
  _seed_plane_env
  STUB="$(_stub_docker)"
  env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" vhost >/dev/null
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" vhost --remove
  [ "$status" -eq 0 ]
  [[ "$output" == *"INIT_PLANE_VHOST_REMOVE"* ]]
  grep -q '^APP_DOMAIN=localhost$' "$PBRAIN_PLANE_HOME/plane.env"
  grep -q '^LISTEN_HTTP_PORT=80$' "$PBRAIN_PLANE_HOME/plane.env"
  [ ! -f "$PBRAIN_PLANE_HOME/plane.env.pbrain-bak" ]
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
