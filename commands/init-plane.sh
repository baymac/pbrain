#!/usr/bin/env bash
# init-plane.sh — local Plane self-host setup wizard backend.
#
# Dispatched by /init-plane (init-plane.md). Stands up a self-hosted Plane
# (makeplane) on this machine via Plane's OWN official installer (setup.sh),
# then wires pbrain's project backend to it (so /plan-my-day + /end-of-day read
# ready tasks from Plane and write status back). Plane owns the
# Module→Issue→Sub-issue tree and the UI; pbrain stays the daily-ritual layer.
#
# Like /init-obsidian and /codex-install, this is a SETUP command — it does NOT
# go through lib/vault.sh (no vault is required to run Plane locally; the Plane
# config lives at ~/.config/pbrain/plane.json, independent of the vault).
#
# Subcommands (each idempotent; safe to re-run):
#   probe                 Print machine state for the wizard. Default.
#   fetch                 Download Plane's official setup.sh into the managed
#                         dir and make it executable.
#   up                    Run Plane's setup.sh (interactive menu: Install/Start/
#                         Stop/Restart/Upgrade — Plane owns lifecycle).
#   config <flags>        Wire pbrain → the instance (delegates to lib/plane.py
#                         setup; --base-url/--api-key/--workspace/--project).
#   vhost [flags]         Move Plane off port 80 to a named vhost (default
#                         http://plane.localhost:1800) by editing Plane's own
#                         plane.env knobs (LISTEN_HTTP_PORT + APP_DOMAIN). No
#                         sidecar proxy — Plane's built-in Caddy serves both the
#                         vanity URL (browser) and 127.0.0.1:<port> (pbrain). The
#                         default setup flow runs this right after `up` so the
#                         user lands on plane.localhost:1800 from the first visit;
#                         `vhost --remove` reverts to plain http://localhost.
#                         Flags: --host (default plane.localhost), --port
#                         (default 1800), --plane-home, --no-restart, --remove.
#   status                Show Docker + Plane container + pbrain backend state.
#   help
#
# Overrides:
#   PBRAIN_PLANE_HOME     where setup.sh + its data live (default
#                         ~/.config/pbrain/plane-selfhost)
set -euo pipefail

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
REPO_ROOT="$(cd -P -- "$_SCRIPT_DIR/.." && pwd -P)"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pbrain"
PLANE_CONFIG="$CONFIG_DIR/plane.json"
PLANE_HOME="${PBRAIN_PLANE_HOME:-$CONFIG_DIR/plane-selfhost}"
SETUP_SH="$PLANE_HOME/setup.sh"
SETUP_URL="https://github.com/makeplane/plane/releases/latest/download/setup.sh"
DEFAULT_URL="http://localhost"
PLANE_ENGINE="$REPO_ROOT/lib/plane.py"

_have() { command -v "$1" >/dev/null 2>&1; }

_docker_running() { _have docker && docker info >/dev/null 2>&1; }

_compose_ok() {
  # Either the v2 plugin (`docker compose`) or the legacy `docker-compose`.
  { _have docker && docker compose version >/dev/null 2>&1; } || _have docker-compose
}

# True (0) if any Plane container appears to be running.
_plane_running() {
  _docker_running || return 1
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qiE 'plane' && return 0
  return 1
}

# Locate Plane's plane.env. Order: explicit --plane-home flag → PBRAIN_PLANE_HOME
# canonical path → discovery from a running Plane proxy container's compose
# labels. Echoes the absolute path (or nothing) and returns 0 either way.
_vhost_envfile() {
  local home_override="${1:-}"
  if [[ -n "$home_override" && -f "$home_override/plane.env" ]]; then
    echo "$home_override/plane.env"; return 0
  fi
  if [[ -f "$PLANE_HOME/plane.env" ]]; then
    echo "$PLANE_HOME/plane.env"; return 0
  fi
  _docker_running || return 0
  local envf
  envf="$(docker inspect plane-app-proxy-1 \
    --format '{{ index .Config.Labels "com.docker.compose.project.environment_file" }}' \
    2>/dev/null)"
  if [[ -n "$envf" && -f "$envf" ]]; then
    echo "$envf"; return 0
  fi
  return 0
}

# The base_url pbrain should use for the local instance. The default flow moves
# Plane off port 80 to the named vhost (plane.localhost:1800), so derive the live
# port from plane.env: a non-80 LISTEN_HTTP_PORT → the loopback form
# http://127.0.0.1:<port>; otherwise plain http://localhost. Lets `config` wire
# the right URL without the caller having to remember --base-url.
_default_base_url() {
  local envf port
  envf="$(_vhost_envfile 2>/dev/null || true)"
  if [[ -n "$envf" && -f "$envf" ]]; then
    port="$(awk -F= '/^LISTEN_HTTP_PORT=/{print $2}' "$envf" | tail -1)"
    if [[ -n "$port" && "$port" != "80" ]]; then
      echo "http://127.0.0.1:$port"; return 0
    fi
  fi
  echo "$DEFAULT_URL"
}

# yes (0) when a Plane API key is reachable (env or config file) — Plane is the
# sole project backend, so "configured" is the only state that matters now.
_plane_configured() {
  if [[ -n "${PBRAIN_PLANE_API_KEY:-}" ]]; then echo yes; return; fi
  grep -q '"api_key"' "$PLANE_CONFIG" 2>/dev/null && { echo yes; return; }
  echo no
}

SUB="${1:-probe}"
[[ $# -gt 0 ]] && shift || true

case "$SUB" in
  probe)
    echo "INIT_PLANE_PROBE"
    echo "docker: $(_have docker && echo yes || echo no)"
    echo "docker_running: $(_docker_running && echo yes || echo no)"
    echo "compose: $(_compose_ok && echo yes || echo no)"
    echo "selfhost_dir: $PLANE_HOME ($( [[ -d "$PLANE_HOME" ]] && echo exists || echo absent ))"
    echo "setup_sh: $( [[ -f "$SETUP_SH" ]] && echo present || echo absent )"
    echo "plane_config: $( [[ -f "$PLANE_CONFIG" ]] && echo present || echo absent )"
    echo "plane_running: $(_plane_running && echo yes || echo no)"
    echo "configured: $(_plane_configured)"
    echo "default_url: $DEFAULT_URL"
    echo "setup_url: $SETUP_URL"
    vhost_env="$(_vhost_envfile 2>/dev/null || true)"
    if [[ -n "$vhost_env" && -f "$vhost_env" ]]; then
      vh_port="$(awk -F= '/^LISTEN_HTTP_PORT=/{print $2}' "$vhost_env" | tail -1)"
      vh_dom="$(awk -F= '/^APP_DOMAIN=/{print $2}' "$vhost_env" | tail -1)"
      echo "plane_env: $vhost_env"
      echo "vhost_port: ${vh_port:-80}"
      echo "vhost_domain: ${vh_dom:-localhost}"
    else
      echo "plane_env: absent"
    fi
    ;;

  fetch)
    if ! _have curl; then
      echo "INIT_PLANE_ERROR curl is required to download Plane's installer." >&2; exit 1
    fi
    mkdir -p "$PLANE_HOME"
    if curl -fsSL -o "$SETUP_SH" "$SETUP_URL"; then
      chmod +x "$SETUP_SH"
      echo "INIT_PLANE_FETCHED $SETUP_SH"
      echo "Run it with: /init-plane up   (or: bash \"$SETUP_SH\")"
    else
      echo "INIT_PLANE_ERROR could not download $SETUP_URL — check your connection." >&2; exit 1
    fi
    ;;

  up)
    if [[ ! -f "$SETUP_SH" ]]; then
      echo "INIT_PLANE_NEED_FETCH setup.sh not downloaded yet — run /init-plane fetch first." ; exit 0
    fi
    if ! _docker_running; then
      echo "INIT_PLANE_NEED_DOCKER Docker isn't running. Start Docker Desktop, then re-run." ; exit 0
    fi
    echo "INIT_PLANE_UP launching Plane's installer (interactive menu: choose Install the first time, then Start)."
    cd "$PLANE_HOME"
    bash "$SETUP_SH"
    ;;

  config)
    if [[ ! -f "$PLANE_ENGINE" ]]; then
      echo "INIT_PLANE_ERROR lib/plane.py not found at $PLANE_ENGINE" >&2; exit 1
    fi
    echo "INIT_PLANE_CONFIG"
    # Default base-url to the active local instance when the caller doesn't pass
    # one (the vhost loopback http://127.0.0.1:1800 once Plane is moved off :80,
    # else http://localhost) — see _default_base_url.
    has_base=no
    for a in "$@"; do [[ "$a" == "--base-url" ]] && has_base=yes; done
    if [[ "$has_base" == no ]]; then
      python3 "$PLANE_ENGINE" setup --base-url "$(_default_base_url)" "$@"
    else
      python3 "$PLANE_ENGINE" setup "$@"
    fi
    ;;

  vhost)
    # Move Plane off port 80 to a stable named vhost (default
    # http://plane.localhost:1800) by editing its OWN env knobs in plane.env.
    # No sidecar proxy: Plane's bundled Caddy is host-agnostic on its listener
    # port, so both the vanity URL (browser) and http://127.0.0.1:<port>
    # (pbrain's API client) land on the same backend. We then re-point pbrain's
    # base_url at the loopback form (lib/plane.py setup MERGES, so the
    # api_key / workspace / project already on file are preserved).
    HOSTNAME="plane.localhost"; PORT="1800"; DO_REMOVE=no; NO_RESTART=no; PLANE_HOME_OVERRIDE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --host)       HOSTNAME="${2:?--host needs a value}"; shift 2;;
        --port)       PORT="${2:?--port needs a value}"; shift 2;;
        --plane-home) PLANE_HOME_OVERRIDE="${2:?--plane-home needs a value}"; shift 2;;
        --no-restart) NO_RESTART=yes; shift;;
        --remove)     DO_REMOVE=yes; shift;;
        *) echo "pbrain: unknown flag for /init-plane vhost: $1" >&2; exit 1;;
      esac
    done
    ENVFILE="$(_vhost_envfile "$PLANE_HOME_OVERRIDE")"
    if [[ -z "$ENVFILE" || ! -f "$ENVFILE" ]]; then
      echo "INIT_PLANE_VHOST_NO_ENV"
      echo "Couldn't find Plane's plane.env. Bring Plane up via /init-plane fetch + up,"
      echo "or set PBRAIN_PLANE_HOME to the directory containing plane.env."
      exit 0
    fi
    if ! _docker_running; then
      echo "INIT_PLANE_NEED_DOCKER Docker isn't running. Start Docker Desktop, then re-run."
      exit 0
    fi
    PLANE_DIR="$(dirname "$ENVFILE")"
    BACKUP="$ENVFILE.pbrain-bak"
    _has_creds() { grep -q '"api_key"' "$PLANE_CONFIG" 2>/dev/null; }

    if [[ "$DO_REMOVE" == yes ]]; then
      echo "INIT_PLANE_VHOST_REMOVE"
      if [[ -f "$BACKUP" ]]; then
        mv "$BACKUP" "$ENVFILE"
        echo "restored plane.env from $BACKUP"
      else
        python3 - "$ENVFILE" <<'PYEOF'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
def upsert(t, k, v):
    pat = re.compile(rf"(?m)^{re.escape(k)}=.*$")
    return pat.sub(f"{k}={v}", t) if pat.search(t) else t.rstrip() + f"\n{k}={v}\n"
t = upsert(t, "APP_DOMAIN", "localhost")
t = upsert(t, "LISTEN_HTTP_PORT", "80")
p.write_text(t)
PYEOF
        echo "no backup found — reset APP_DOMAIN=localhost, LISTEN_HTTP_PORT=80 in $ENVFILE"
      fi
      if [[ "$NO_RESTART" == no ]]; then
        ( cd "$PLANE_DIR" && docker compose --env-file plane.env up -d >/dev/null 2>&1 )
        echo "restarted Plane on http://localhost"
      fi
      if [[ -f "$PLANE_ENGINE" ]] && _has_creds; then
        python3 "$PLANE_ENGINE" setup --base-url "$DEFAULT_URL" >/dev/null
        echo "pbrain base_url -> $DEFAULT_URL"
      fi
      exit 0
    fi

    # Apply: back up once, upsert the two knobs, restart, re-point pbrain.
    if [[ ! -f "$BACKUP" ]]; then
      cp "$ENVFILE" "$BACKUP"
    fi
    APP_DOMAIN_VAL="$HOSTNAME:$PORT"
    python3 - "$ENVFILE" "$APP_DOMAIN_VAL" "$PORT" <<'PYEOF'
import re, sys, pathlib
envfile, app_domain, port = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(envfile); t = p.read_text()
def upsert(t, k, v):
    pat = re.compile(rf"(?m)^{re.escape(k)}=.*$")
    return pat.sub(f"{k}={v}", t) if pat.search(t) else t.rstrip() + f"\n{k}={v}\n"
t = upsert(t, "APP_DOMAIN", app_domain)
t = upsert(t, "LISTEN_HTTP_PORT", port)
p.write_text(t)
PYEOF
    echo "INIT_PLANE_VHOST"
    echo "edited $ENVFILE:"
    echo "  APP_DOMAIN=$APP_DOMAIN_VAL"
    echo "  LISTEN_HTTP_PORT=$PORT"
    echo "  (WEB_URL + CORS_ALLOWED_ORIGINS rebuild from APP_DOMAIN — Plane's own substitution)"
    if [[ "$NO_RESTART" == yes ]]; then
      echo "skipped restart (--no-restart) — apply with: cd \"$PLANE_DIR\" && docker compose --env-file plane.env up -d"
    else
      ( cd "$PLANE_DIR" && docker compose --env-file plane.env up -d >/dev/null 2>&1 )
      echo "restarted Plane stack on host port $PORT"
    fi
    BROWSER_URL="http://$APP_DOMAIN_VAL"
    PBRAIN_URL="http://127.0.0.1:$PORT"
    if [[ -f "$PLANE_ENGINE" ]] && _has_creds; then
      if python3 "$PLANE_ENGINE" setup --base-url "$PBRAIN_URL" >/dev/null; then
        echo "pbrain base_url -> $PBRAIN_URL"
      else
        echo "INIT_PLANE_WARN could not update pbrain base_url; run: /init-plane config --base-url $PBRAIN_URL"
      fi
    else
      echo "Plane isn't wired to pbrain yet — once it is, set the URL with:"
      echo "  /init-plane config --base-url $PBRAIN_URL --api-key <pat> --workspace <slug> --project <id>"
    fi
    echo "next steps:"
    echo "  1) bookmark Plane in your browser:  $BROWSER_URL"
    echo "  2) verify the round-trip:           /project-manager test"
    echo "  3) revert any time:                 /init-plane vhost --remove"
    ;;

  status)
    echo "INIT_PLANE_STATUS"
    echo "docker_running: $(_docker_running && echo yes || echo no)"
    echo "plane_running: $(_plane_running && echo yes || echo no)"
    if _plane_running; then
      docker ps --format '  {{.Names}}\t{{.Status}}' 2>/dev/null | grep -i plane || true
    fi
    echo "plane_config: $( [[ -f "$PLANE_CONFIG" ]] && echo present || echo absent )"
    echo "configured: $(_plane_configured)"
    echo "url: $DEFAULT_URL"
    ;;

  help|-h|--help)
    awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$_SCRIPT_DIR/init-plane.sh"
    ;;

  *)
    echo "pbrain: unknown /init-plane subcommand: $SUB" >&2
    echo "Try: probe | fetch | up | config | vhost | status | help" >&2
    exit 1
    ;;
esac
