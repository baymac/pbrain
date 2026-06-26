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

@test "config respects an explicit --base-url (self-host on a custom domain)" {
  run IP config --base-url https://plane.example.com --api-key SECRET --workspace ws --project pid
  [ "$status" -eq 0 ]
  grep -q '"base_url": "https://plane.example.com"' "$XDG_CONFIG_HOME/pbrain/plane.json"
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

# --- up: vhost-by-default (PB-113) --------------------------------------------

_seed_setup_sh() {  # fake Plane installer so `up` can run it as a no-op
  mkdir -p "$PBRAIN_PLANE_HOME"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$PBRAIN_PLANE_HOME/setup.sh"
  chmod +x "$PBRAIN_PLANE_HOME/setup.sh"
}

@test "PB-113 up lands on the stable vhost by default (plane.localhost:1800)" {
  IP config --api-key SECRET --workspace ws --project pid >/dev/null
  _seed_setup_sh
  _seed_plane_env
  STUB="$(_stub_docker)"
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" up
  [ "$status" -eq 0 ]
  [[ "$output" == *"INIT_PLANE_VHOST"* ]]
  grep -q '^APP_DOMAIN=plane.localhost:1800$' "$PBRAIN_PLANE_HOME/plane.env"
  grep -q '^LISTEN_HTTP_PORT=1800$' "$PBRAIN_PLANE_HOME/plane.env"
  [ -f "$PBRAIN_PLANE_HOME/plane.env.pbrain-bak" ]
  grep -q '"base_url": "http://127.0.0.1:1800"' "$XDG_CONFIG_HOME/pbrain/plane.json"
}

@test "PB-113 up --no-vhost stays on bare http://localhost (no plane.env edit)" {
  _seed_setup_sh
  _seed_plane_env
  STUB="$(_stub_docker)"
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" up --no-vhost
  [ "$status" -eq 0 ]
  [[ "$output" == *"INIT_PLANE_NO_VHOST"* ]]
  [[ "$output" != *"INIT_PLANE_VHOST"* ]]
  grep -q '^APP_DOMAIN=localhost$' "$PBRAIN_PLANE_HOME/plane.env"
  grep -q '^LISTEN_HTTP_PORT=80$' "$PBRAIN_PLANE_HOME/plane.env"
  [ ! -f "$PBRAIN_PLANE_HOME/plane.env.pbrain-bak" ]
}

@test "PB-113 up --port 80 is treated as the no-vhost escape hatch" {
  _seed_setup_sh
  _seed_plane_env
  STUB="$(_stub_docker)"
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" up --port 80
  [ "$status" -eq 0 ]
  [[ "$output" == *"INIT_PLANE_NO_VHOST"* ]]
  grep -q '^LISTEN_HTTP_PORT=80$' "$PBRAIN_PLANE_HOME/plane.env"
}

@test "PB-113 up --port 9000 applies a custom vhost port" {
  IP config --api-key SECRET --workspace ws --project pid >/dev/null
  _seed_setup_sh
  _seed_plane_env
  STUB="$(_stub_docker)"
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" up --port 9000
  [ "$status" -eq 0 ]
  [[ "$output" == *"INIT_PLANE_VHOST"* ]]
  grep -q '^LISTEN_HTTP_PORT=9000$' "$PBRAIN_PLANE_HOME/plane.env"
  grep -q '"base_url": "http://127.0.0.1:9000"' "$XDG_CONFIG_HOME/pbrain/plane.json"
}

# --- github -------------------------------------------------------------------

@test "github without plane.env reports INIT_PLANE_GITHUB_NO_ENV (no crash)" {
  # Force docker discovery to find nothing so a real Plane on the dev box doesn't
  # leak a plane.env into the result.
  STUB="$TMP/nodock"; mkdir -p "$STUB"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/docker"; chmod +x "$STUB/docker"
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" github
  [ "$status" -eq 0 ] && [[ "$output" == *"INIT_PLANE_GITHUB_NO_ENV"* ]]
}

@test "github with no flags prints the guide with callback URLs derived from APP_DOMAIN" {
  _seed_plane_env 1800 plane.localhost
  STUB="$(_stub_docker)"
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" github
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"INIT_PLANE_GITHUB_GUIDE"* ]] \
    && [[ "$output" == *"http://plane.localhost/silo/api/github/auth/callback"* ]] \
    && [[ "$output" == *"http://plane.localhost/silo/api/github/github-webhook"* ]] \
    && [[ "$output" == *"silo"* ]]
}

@test "github apply writes the credentials + base64 private key + SILO_BASE_URL into plane.env" {
  _seed_plane_env
  STUB="$(_stub_docker)"
  printf -- '-----BEGIN PRIVATE KEY-----\nabc123\n-----END PRIVATE KEY-----\n' > "$TMP/key.pem"
  EXPECT_B64="$(python3 -c 'import base64,sys;sys.stdout.write(base64.b64encode(open(sys.argv[1],"rb").read()).decode())' "$TMP/key.pem")"
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" github \
    --app-name myapp --app-id 12345 --client-id cid --client-secret csecret \
    --private-key "$TMP/key.pem" --silo-base-url https://plane.example.com
  [ "$status" -eq 0 ] \
    && grep -q '^GITHUB_APP_NAME=myapp$' "$PBRAIN_PLANE_HOME/plane.env" \
    && grep -q '^GITHUB_APP_ID=12345$' "$PBRAIN_PLANE_HOME/plane.env" \
    && grep -q '^GITHUB_CLIENT_ID=cid$' "$PBRAIN_PLANE_HOME/plane.env" \
    && grep -q '^GITHUB_CLIENT_SECRET=csecret$' "$PBRAIN_PLANE_HOME/plane.env" \
    && grep -q "^GITHUB_PRIVATE_KEY=$EXPECT_B64\$" "$PBRAIN_PLANE_HOME/plane.env" \
    && grep -q '^SILO_BASE_URL=https://plane.example.com$' "$PBRAIN_PLANE_HOME/plane.env" \
    && [ ! -f "$PBRAIN_PLANE_HOME/plane.env.pbrain-bak" ]
}

@test "github apply is idempotent (no duplicate keys on re-run)" {
  _seed_plane_env
  STUB="$(_stub_docker)"
  printf 'pem\n' > "$TMP/key.pem"
  ARGS=(github --app-name a --app-id 1 --client-id c --client-secret s --private-key "$TMP/key.pem" --silo-base-url https://x.example.com)
  env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" "${ARGS[@]}" >/dev/null
  env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" "${ARGS[@]}" >/dev/null
  [ "$(grep -c '^GITHUB_APP_ID=' "$PBRAIN_PLANE_HOME/plane.env")" -eq 1 ]
}

@test "github missing flags fails with INIT_PLANE_GITHUB_INCOMPLETE" {
  _seed_plane_env
  STUB="$(_stub_docker)"
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" github --app-name only
  [ "$status" -ne 0 ] && [[ "$output" == *"INIT_PLANE_GITHUB_INCOMPLETE"* ]]
}

@test "github --remove strips only the github keys and leaves vhost knobs intact" {
  _seed_plane_env 1800 plane.localhost
  STUB="$(_stub_docker)"
  printf 'pem\n' > "$TMP/key.pem"
  env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" github \
    --app-name a --app-id 1 --client-id c --client-secret s \
    --private-key "$TMP/key.pem" --silo-base-url https://x.example.com >/dev/null
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/init-plane.sh" github --remove
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"INIT_PLANE_GITHUB_REMOVE"* ]] \
    && ! grep -q '^GITHUB_APP_ID=' "$PBRAIN_PLANE_HOME/plane.env" \
    && ! grep -q '^SILO_BASE_URL=' "$PBRAIN_PLANE_HOME/plane.env" \
    && grep -q '^APP_DOMAIN=plane.localhost$' "$PBRAIN_PLANE_HOME/plane.env" \
    && grep -q '^LISTEN_HTTP_PORT=1800$' "$PBRAIN_PLANE_HOME/plane.env"
}

@test "probe reports silo_running + github_configured keys" {
  _seed_plane_env
  run IP probe
  [[ "$output" == *"silo_running:"* ]] && [[ "$output" == *"github_configured: no"* ]]
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
