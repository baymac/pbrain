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
#   portless [flags]      Front Plane with a stable named .localhost URL via
#                         portless (vercel-labs/portless): registers a static
#                         alias (https://<name>.localhost -> localhost:<port>)
#                         and re-points pbrain's base_url at it. Optional — the
#                         plain http://localhost setup works without it. Flags:
#                         --name (default plane), --plane-port (default 80),
#                         --no-tls, --url <explicit>, --remove (tear it down).
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
    echo "portless: $(_have portless && echo yes || echo no)"
    echo "node: $(_have node && node -v 2>/dev/null || echo absent)"
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
    # Default base-url to the local instance when the caller doesn't pass one.
    has_base=no
    for a in "$@"; do [[ "$a" == "--base-url" ]] && has_base=yes; done
    if [[ "$has_base" == no ]]; then
      python3 "$PLANE_ENGINE" setup --base-url "$DEFAULT_URL" "$@"
    else
      python3 "$PLANE_ENGINE" setup "$@"
    fi
    ;;

  portless)
    # Front the self-hosted Plane with a stable named URL via portless
    # (https://portless.sh — vercel-labs/portless). Plane's nginx listens on a
    # fixed port (default 80); portless's HTTPS proxy listens on 443, so there's
    # no conflict. `portless alias <name> <port>` is the documented static-route
    # case ("for Docker containers") — exactly Plane's shape. We then re-point
    # pbrain's base_url at the named URL (lib/plane.py setup MERGES, so the
    # api_key / workspace / project already on file are preserved).
    NAME="plane"
    PLANE_PORT="80"
    SCHEME="https"
    DO_REMOVE=no
    URL_OVERRIDE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name)       NAME="${2:?--name needs a value}"; shift 2;;
        --plane-port) PLANE_PORT="${2:?--plane-port needs a value}"; shift 2;;
        --no-tls)     SCHEME="http"; shift;;
        --url)        URL_OVERRIDE="${2:?--url needs a value}"; shift 2;;
        --remove)     DO_REMOVE=yes; shift;;
        *) echo "pbrain: unknown flag for /init-plane portless: $1" >&2; exit 1;;
      esac
    done

    if ! _have portless; then
      echo "INIT_PLANE_PORTLESS_MISSING"
      echo "portless isn't installed. It needs Node.js 24+, then:"
      echo "  npm install -g portless"
      echo "Docs: https://portless.sh"
      exit 0
    fi

    echo "INIT_PLANE_PORTLESS"
    _has_creds() { grep -q '"api_key"' "$PLANE_CONFIG" 2>/dev/null; }

    if [[ "$DO_REMOVE" == yes ]]; then
      portless alias --remove "$NAME" || true
      echo "removed portless alias: $NAME"
      if [[ -f "$PLANE_ENGINE" ]] && _has_creds; then
        if python3 "$PLANE_ENGINE" setup --base-url "$DEFAULT_URL" >/dev/null; then
          echo "pbrain base_url -> $DEFAULT_URL"
        fi
      fi
      echo "Plane itself is untouched; trim $NAME.localhost from its CORS/WEB_URL if you added it."
      exit 0
    fi

    URL="${URL_OVERRIDE:-$SCHEME://$NAME.localhost}"

    # Register the static route. --force keeps re-runs idempotent.
    if ! portless alias "$NAME" "$PLANE_PORT" --force; then
      echo "INIT_PLANE_ERROR portless alias failed (is the portless proxy installed correctly?)" >&2
      exit 1
    fi
    echo "alias registered: $URL -> localhost:$PLANE_PORT"

    # Re-point pbrain at the named URL (merge — token/workspace/project kept).
    if [[ -f "$PLANE_ENGINE" ]] && _has_creds; then
      if python3 "$PLANE_ENGINE" setup --base-url "$URL" >/dev/null; then
        echo "pbrain base_url -> $URL"
      else
        echo "INIT_PLANE_WARN could not update pbrain base_url; run: /init-plane config --base-url $URL"
      fi
    else
      echo "Plane isn't wired to pbrain yet — once it is, set the URL with:"
      echo "  /init-plane config --base-url $URL --api-key <pat> --workspace <slug> --project <id>"
    fi

    echo "next steps:"
    echo "  1) start the proxy (once):  portless proxy start   (sudo binds :443; 'portless service install' persists it across reboots)"
    echo "  2) allow the host in Plane's .env — add $URL to CORS_ALLOWED_ORIGINS / WEB_URL, then restart Plane from setup.sh"
    echo "  3) verify the round-trip:    /project-manager test"
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
    echo "Try: probe | fetch | up | config | portless | status | help" >&2
    exit 1
    ;;
esac
