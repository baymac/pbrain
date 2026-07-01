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
#   up [flags]            Run Plane's setup.sh (interactive menu: Install/Start/
#                         Stop/Restart/Upgrade — Plane owns lifecycle), then by
#                         default land on the stable vhost (PB-113:
#                         http://plane.localhost:1800) — no separate vhost step.
#                         Flags: --host (default plane.localhost), --port (1800),
#                         --no-vhost / --port 80 (stay on bare :80), --no-restart,
#                         --plane-home.
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
#   github [flags]        Configure Plane's GitHub integration (two-way issue /
#                         PR sync) by writing the GITHUB_* + SILO_BASE_URL knobs
#                         into Plane's own plane.env and restarting the stack.
#                         No flags → print the GitHub-App setup guide (App
#                         settings + callback/webhook URLs to paste into GitHub)
#                         plus current state. With credential flags → apply them.
#                         NOTE: the integration runs on Plane's `silo` service
#                         (the Commercial / "govern" layer) — it is NOT part of
#                         the free Community stack `up` installs; and GitHub must
#                         be able to REACH your instance, so plain localhost won't
#                         work without a public URL / tunnel (set --silo-base-url
#                         to it). Flags: --app-name, --app-id, --client-id,
#                         --client-secret, --private-key <pem path>,
#                         --silo-base-url, --plane-home, --no-restart, --remove.
#   app [flags]           Package the running Plane instance as a native macOS
#                         app (a Tauri v2 shell, source in lib/plane-app/) that
#                         registers a `plane://` URL scheme for DEEP LINKING, and
#                         install it to /Applications. Replaces the old Pake build
#                         (Pake couldn't deep-link). Mirrors vhost/github:
#                         idempotent, guides (doesn't auto-install) its cargo/tauri
#                         toolchain. NOTE: unlike a browser, the app's WebView has
#                         NO RFC 6761 `*.localhost` resolution, so a vhost host like
#                         plane.localhost must be in /etc/hosts or the app renders
#                         blank — the command detects this and prints the one-line
#                         `sudo` fix rather than running sudo itself. macOS only.
#                         Flags: --name (default Plane), --url, --host, --port,
#                         --icon, --no-install, --remove, --plane-home.
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

# PB-18 VPS-hosting helpers (sources lib/plane-backup.sh itself for the VPS creds).
# shellcheck source=/dev/null
[[ -f "$REPO_ROOT/lib/plane-host.sh" ]] && source "$REPO_ROOT/lib/plane-host.sh"

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

# True (0) if Plane's `silo` integrations service container is running. Silo is
# the backend that drives the GitHub/GitLab/Slack integrations (OAuth + webhooks)
# — it ships with Plane's Commercial / "govern" layer, NOT the free Community
# stack `up` installs, so this is how /init-plane github tells the user whether
# the integration even has a backend to talk to.
_silo_running() {
  _docker_running || return 1
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qiE 'silo' && return 0
  return 1
}

# yes (0) when Plane's plane.env already carries the GitHub-App credentials
# (keyed off GITHUB_APP_ID). Echoes yes/no; never fails.
_github_configured() {
  local envf="${1:-}"
  [[ -z "$envf" ]] && envf="$(_vhost_envfile 2>/dev/null || true)"
  if [[ -n "$envf" && -f "$envf" ]] && grep -q '^GITHUB_APP_ID=..*$' "$envf"; then
    echo yes
  else
    echo no
  fi
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

# The URL the desktop app should load. Unlike pbrain's API client (which wants the
# numeric loopback http://127.0.0.1:<port>), the app should carry the SAME vanity
# URL the user types in the browser — http://<APP_DOMAIN> from plane.env (i.e.
# http://plane.localhost:1800 after vhost), else plain http://localhost.
_app_url() {
  local envf dom
  envf="$(_vhost_envfile 2>/dev/null || true)"
  if [[ -n "$envf" && -f "$envf" ]]; then
    dom="$(awk -F= '/^APP_DOMAIN=/{print $2}' "$envf" | tail -1)"
    if [[ -n "$dom" ]]; then echo "http://$dom"; return 0; fi
  fi
  echo "$DEFAULT_URL"
}

# True (0) if a bare hostname resolves via the OS resolver (getaddrinfo) — the
# same path the app's WKWebView uses. Loopback literals and "localhost" always
# pass (no DNS needed). A vhost name like plane.localhost only passes once it's in
# /etc/hosts: browsers/curl special-case *.localhost per RFC 6761, but macOS's
# resolver and therefore the webview do NOT. stdlib-only Python (no deps).
_host_resolves() {
  local host="${1:-}"
  [[ -z "$host" ]] && return 0
  case "$host" in
    localhost|127.0.0.1|::1|0.0.0.0) return 0 ;;
  esac
  python3 -c 'import socket,sys; socket.gethostbyname(sys.argv[1])' "$host" >/dev/null 2>&1
}

# yes (0) when a Plane API key is reachable (env or config file) — Plane is the
# sole project backend, so "configured" is the only state that matters now.
_plane_configured() {
  if [[ -n "${PBRAIN_PLANE_API_KEY:-}" ]]; then echo yes; return; fi
  grep -q '"api_key"' "$PLANE_CONFIG" 2>/dev/null && { echo yes; return; }
  echo no
}

# PB-113: apply the stable vhost (move Plane off :80 onto <host>:<port>) by
# editing Plane's OWN plane.env knobs — backup once, upsert APP_DOMAIN +
# LISTEN_HTTP_PORT, restart the stack (Plane's bundled Caddy is host-agnostic on
# its listener port, so the vanity URL and the loopback both hit the backend),
# then re-point pbrain's base_url at the loopback form (setup MERGES, so an
# api_key/workspace/project already on file is preserved). Shared by `up` (the
# default flow) and the `vhost` subcommand (escape hatch / explicit re-apply).
# Args: <host> <port> <envfile> <no_restart yes|no>. Emits INIT_PLANE_VHOST.
_apply_vhost() {
  local hostname="$1" port="$2" envfile="$3" no_restart="${4:-no}"
  local plane_dir backup app_domain_val default_url
  plane_dir="$(dirname "$envfile")"
  backup="$envfile.pbrain-bak"
  app_domain_val="$hostname:$port"
  [[ -f "$backup" ]] || cp "$envfile" "$backup"
  python3 - "$envfile" "$app_domain_val" "$port" <<'PYEOF'
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
  echo "edited $envfile:"
  echo "  APP_DOMAIN=$app_domain_val"
  echo "  LISTEN_HTTP_PORT=$port"
  echo "  (WEB_URL + CORS_ALLOWED_ORIGINS rebuild from APP_DOMAIN — Plane's own substitution)"
  if [[ "$no_restart" == yes ]]; then
    echo "skipped restart (--no-restart) — apply later with: cd \"$plane_dir\" && docker compose --env-file plane.env up -d"
  else
    ( cd "$plane_dir" && docker compose --env-file plane.env up -d >/dev/null 2>&1 )
    echo "restarted Plane stack on host port $port"
  fi
  default_url="http://127.0.0.1:$port"
  if [[ -f "$PLANE_ENGINE" ]] && grep -q '"api_key"' "$PLANE_CONFIG" 2>/dev/null; then
    python3 "$PLANE_ENGINE" setup --base-url "$default_url" >/dev/null
    echo "pbrain base_url -> $default_url"
  else
    echo "INIT_PLANE_WARN pbrain not wired yet — once it is, set: /init-plane config --base-url $default_url --api-key <pat> --workspace <slug> --project <id>"
  fi
  echo "next steps:"
  echo "  1) bookmark Plane in the browser: http://$app_domain_val"
  echo "  2) verify round-trip: /project-manager test"
  echo "  3) revert any time: /init-plane vhost --remove"
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
    echo "silo_running: $(_silo_running && echo yes || echo no)"
    echo "configured: $(_plane_configured)"
    echo "default_url: $DEFAULT_URL"
    echo "setup_url: $SETUP_URL"
    echo "cargo: $(_have cargo && echo yes || echo no)"
    echo "tauri_cli: $(cargo tauri --version >/dev/null 2>&1 && echo yes || echo no)"
    echo "app_installed: $( [[ -d "/Applications/Plane.app" ]] && echo yes || echo no )"
    vhost_env="$(_vhost_envfile 2>/dev/null || true)"
    if [[ -n "$vhost_env" && -f "$vhost_env" ]]; then
      vh_port="$(awk -F= '/^LISTEN_HTTP_PORT=/{print $2}' "$vhost_env" | tail -1)"
      vh_dom="$(awk -F= '/^APP_DOMAIN=/{print $2}' "$vhost_env" | tail -1)"
      echo "plane_env: $vhost_env"
      echo "vhost_port: ${vh_port:-80}"
      echo "vhost_domain: ${vh_dom:-localhost}"
      echo "github_configured: $(_github_configured "$vhost_env")"
    else
      echo "plane_env: absent"
      echo "github_configured: no"
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
    # PB-113: by default, after the installer brings Plane up, land it on the
    # STABLE vhost (http://plane.localhost:1800) — no separate `vhost` step.
    # Escape hatches: --no-vhost (or --port 80) stays on bare http://localhost:80.
    UP_HOST="plane.localhost"; UP_PORT="1800"; UP_NO_VHOST=no; UP_NO_RESTART=no; UP_HOME_OVERRIDE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --host) UP_HOST="${2:?--host needs a value}"; shift 2;;
        --port) UP_PORT="${2:?--port needs a value}"; shift 2;;
        --no-vhost) UP_NO_VHOST=yes; shift;;
        --no-restart) UP_NO_RESTART=yes; shift;;
        --plane-home) UP_HOME_OVERRIDE="${2:?--plane-home needs a value}"; shift 2;;
        *) echo "pbrain: unknown flag for /init-plane up: $1" >&2; exit 1;;
      esac
    done
    # --port 80 means "stay on bare :80" (that IS the no-vhost case).
    [[ "$UP_PORT" == "80" ]] && UP_NO_VHOST=yes
    if [[ ! -f "$SETUP_SH" ]]; then
      echo "INIT_PLANE_NEED_FETCH setup.sh not downloaded yet — run /init-plane fetch first." ; exit 0
    fi
    if ! _docker_running; then
      echo "INIT_PLANE_NEED_DOCKER Docker isn't running. Start Docker Desktop, then re-run." ; exit 0
    fi
    echo "INIT_PLANE_UP launching Plane's installer (interactive menu: choose Install the first time, then Start)."
    cd "$PLANE_HOME"
    bash "$SETUP_SH"
    if [[ "$UP_NO_VHOST" == yes ]]; then
      echo "INIT_PLANE_NO_VHOST staying on bare http://localhost (--no-vhost / --port 80)."
      echo "  move to a stable vhost later with: /init-plane vhost"
    else
      envf="$(_vhost_envfile "$UP_HOME_OVERRIDE" 2>/dev/null || true)"
      if [[ -z "$envf" || ! -f "$envf" ]]; then
        echo "INIT_PLANE_VHOST_NO_ENV could not find plane.env to apply the vhost; Plane is up on bare http://localhost."
        echo "  apply the stable vhost once plane.env exists with: /init-plane vhost"
      else
        _apply_vhost "$UP_HOST" "$UP_PORT" "$envf" "$UP_NO_RESTART"
      fi
    fi
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

    # Apply via the shared helper (same path `up` uses by default — PB-113).
    _apply_vhost "$HOSTNAME" "$PORT" "$ENVFILE" "$NO_RESTART"
    ;;

  github)
    # Wire Plane's GitHub integration (two-way issue/PR sync) by upserting the
    # GITHUB_* + SILO_BASE_URL knobs into Plane's OWN plane.env, then restarting
    # the stack — same plane.env-editing approach as `vhost`. We do NOT touch
    # vhost's plane.env.pbrain-bak (it owns that): apply upserts our keys in
    # place, and `--remove` surgically deletes only the keys we set. No flags →
    # print the GitHub-App setup guide (the URLs/permissions to paste into
    # GitHub) plus current state, so the user can stage the GitHub side first.
    APP_NAME=""; APP_ID=""; CLIENT_ID=""; CLIENT_SECRET=""; PRIVATE_KEY_PEM=""
    SILO_BASE_URL=""; PLANE_HOME_OVERRIDE=""; NO_RESTART=no; DO_REMOVE=no
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --app-name)      APP_NAME="${2:?--app-name needs a value}"; shift 2;;
        --app-id)        APP_ID="${2:?--app-id needs a value}"; shift 2;;
        --client-id)     CLIENT_ID="${2:?--client-id needs a value}"; shift 2;;
        --client-secret) CLIENT_SECRET="${2:?--client-secret needs a value}"; shift 2;;
        --private-key)   PRIVATE_KEY_PEM="${2:?--private-key needs a path}"; shift 2;;
        --silo-base-url) SILO_BASE_URL="${2:?--silo-base-url needs a value}"; shift 2;;
        --plane-home)    PLANE_HOME_OVERRIDE="${2:?--plane-home needs a value}"; shift 2;;
        --no-restart)    NO_RESTART=yes; shift;;
        --remove)        DO_REMOVE=yes; shift;;
        *) echo "pbrain: unknown flag for /init-plane github: $1" >&2; exit 1;;
      esac
    done

    ENVFILE="$(_vhost_envfile "$PLANE_HOME_OVERRIDE")"
    if [[ -z "$ENVFILE" || ! -f "$ENVFILE" ]]; then
      echo "INIT_PLANE_GITHUB_NO_ENV"
      echo "Couldn't find Plane's plane.env. Bring Plane up via /init-plane fetch + up,"
      echo "or set PBRAIN_PLANE_HOME to the directory containing plane.env."
      exit 0
    fi
    PLANE_DIR="$(dirname "$ENVFILE")"

    # Derive the silo base URL (the public origin GitHub will call back to) from
    # plane.env's APP_DOMAIN when the caller didn't pass one.
    _derive_silo_base() {
      local dom
      dom="$(awk -F= '/^APP_DOMAIN=/{print $2}' "$ENVFILE" | tail -1)"
      [[ -z "$dom" ]] && dom="localhost"
      echo "http://$dom"
    }
    SILO_BASE_EFFECTIVE="${SILO_BASE_URL:-$(_derive_silo_base)}"

    # --remove: strip only the keys we manage (leave the rest of plane.env, incl.
    # vhost's APP_DOMAIN/LISTEN_HTTP_PORT, untouched), then restart.
    if [[ "$DO_REMOVE" == yes ]]; then
      echo "INIT_PLANE_GITHUB_REMOVE"
      python3 - "$ENVFILE" <<'PYEOF'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
KEYS = ("GITHUB_CLIENT_ID","GITHUB_CLIENT_SECRET","GITHUB_APP_NAME",
        "GITHUB_APP_ID","GITHUB_PRIVATE_KEY","SILO_BASE_URL")
lines = [ln for ln in t.splitlines()
         if not any(ln.startswith(k + "=") for k in KEYS)]
p.write_text("\n".join(lines).rstrip() + "\n")
PYEOF
      echo "stripped GITHUB_* + SILO_BASE_URL from $ENVFILE"
      if [[ "$NO_RESTART" == no ]] && _docker_running; then
        ( cd "$PLANE_DIR" && docker compose --env-file plane.env up -d >/dev/null 2>&1 )
        echo "restarted Plane stack"
      else
        echo "skipped restart — apply with: cd \"$PLANE_DIR\" && docker compose --env-file plane.env up -d"
      fi
      echo "(disconnect the app in GitHub too: its Settings → Developer settings → GitHub Apps)"
      exit 0
    fi

    # No credential flags → guide mode. Print exactly what to create on GitHub's
    # side, with the callback/webhook URLs prefilled from the silo base URL, plus
    # current state. This is the read-only "what do I paste into GitHub" step.
    _any_cred="${APP_NAME}${APP_ID}${CLIENT_ID}${CLIENT_SECRET}${PRIVATE_KEY_PEM}"
    if [[ -z "$_any_cred" ]]; then
      echo "INIT_PLANE_GITHUB_GUIDE"
      echo "silo_running: $(_silo_running && echo yes || echo no)"
      echo "github_configured: $(_github_configured "$ENVFILE")"
      echo "silo_base_url: $SILO_BASE_EFFECTIVE"
      echo
      echo "CAVEATS (read first):"
      echo "  • The GitHub integration runs on Plane's 'silo' service — part of the"
      echo "    Commercial/'govern' layer, NOT the free Community stack 'up' installs."
      if ! _silo_running; then
        echo "    No 'silo' container is running here, so this likely won't activate"
        echo "    until you're on a Plane build that ships it."
      fi
      echo "  • GitHub must be able to REACH your instance for OAuth + webhooks."
      echo "    $SILO_BASE_EFFECTIVE is local — give --silo-base-url a public HTTPS URL"
      echo "    (a real domain, or a tunnel like cloudflared/ngrok) or it won't work."
      echo
      echo "1) GitHub → Settings → Developer settings → GitHub Apps → New GitHub App"
      echo "2) Basic info:"
      echo "     Homepage URL:   $SILO_BASE_EFFECTIVE"
      echo "     Callback URLs (add BOTH):"
      echo "       $SILO_BASE_EFFECTIVE/silo/api/github/auth/callback"
      echo "       $SILO_BASE_EFFECTIVE/silo/api/github/auth/user/callback"
      echo "     Post installation → Setup URL: $SILO_BASE_EFFECTIVE/silo/api/github/auth/callback"
      echo "       and enable 'Redirect on update'."
      echo "     Webhook URL:    $SILO_BASE_EFFECTIVE/silo/api/github/github-webhook"
      echo "     Optional features → DISABLE 'Expire user authorization tokens'."
      echo "3) Repository permissions: Issues = R/W, Pull requests = R/W, Metadata = RO."
      echo "   Account permissions:    Email addresses = RO, Profile = R/W."
      echo "4) Subscribe to events: Installation target, Meta, Issue comment, Issues,"
      echo "   Pull request, Pull request review, Pull request review comment,"
      echo "   Pull request review thread, Push, Repository (sub issues)."
      echo "5) Create the app, then: generate a client secret, generate a private key"
      echo "   (.pem download), and note the App ID, Client ID, App name."
      echo "6) Make the app Public so it can be installed on your repos."
      echo
      echo "Then wire it into Plane:"
      echo "  /init-plane github \\"
      echo "    --app-name <name> --app-id <id> --client-id <id> \\"
      echo "    --client-secret <secret> --private-key /path/to/private-key.pem \\"
      echo "    --silo-base-url https://<public-host>"
      echo
      echo "(--private-key takes the .pem PATH; pbrain base64-encodes it for plane.env.)"
      echo "Revert any time: /init-plane github --remove"
      exit 0
    fi

    # Apply mode — require the full credential set (a partial config is useless).
    missing=()
    [[ -z "$APP_NAME" ]]       && missing+=("--app-name")
    [[ -z "$APP_ID" ]]        && missing+=("--app-id")
    [[ -z "$CLIENT_ID" ]]     && missing+=("--client-id")
    [[ -z "$CLIENT_SECRET" ]] && missing+=("--client-secret")
    [[ -z "$PRIVATE_KEY_PEM" ]] && missing+=("--private-key")
    if [[ ${#missing[@]} -gt 0 ]]; then
      echo "INIT_PLANE_GITHUB_INCOMPLETE missing: ${missing[*]}" >&2
      echo "Run /init-plane github with no flags to see the full setup guide." >&2
      exit 1
    fi
    if [[ ! -f "$PRIVATE_KEY_PEM" ]]; then
      echo "INIT_PLANE_GITHUB_ERROR private key file not found: $PRIVATE_KEY_PEM" >&2; exit 1
    fi

    # base64-encode the .pem (no newlines) — done in Python for portability
    # (GNU `base64 -w0` vs BSD `base64 -b0` differ across macOS/Linux).
    PRIVATE_KEY_B64="$(python3 - "$PRIVATE_KEY_PEM" <<'PYEOF'
import base64, sys, pathlib
sys.stdout.write(base64.b64encode(pathlib.Path(sys.argv[1]).read_bytes()).decode())
PYEOF
)"
    if [[ -z "$PRIVATE_KEY_B64" ]]; then
      echo "INIT_PLANE_GITHUB_ERROR could not read/encode $PRIVATE_KEY_PEM" >&2; exit 1
    fi

    python3 - "$ENVFILE" "$CLIENT_ID" "$CLIENT_SECRET" "$APP_NAME" "$APP_ID" "$PRIVATE_KEY_B64" "$SILO_BASE_EFFECTIVE" <<'PYEOF'
import re, sys, pathlib
envfile = sys.argv[1]
vals = {
    "GITHUB_CLIENT_ID":     sys.argv[2],
    "GITHUB_CLIENT_SECRET": sys.argv[3],
    "GITHUB_APP_NAME":      sys.argv[4],
    "GITHUB_APP_ID":        sys.argv[5],
    "GITHUB_PRIVATE_KEY":   sys.argv[6],
    "SILO_BASE_URL":        sys.argv[7],
}
p = pathlib.Path(envfile); t = p.read_text()
def upsert(t, k, v):
    pat = re.compile(rf"(?m)^{re.escape(k)}=.*$")
    return pat.sub(lambda _: f"{k}={v}", t) if pat.search(t) else t.rstrip() + f"\n{k}={v}\n"
for k, v in vals.items():
    t = upsert(t, k, v)
p.write_text(t)
PYEOF
    echo "INIT_PLANE_GITHUB"
    echo "wrote GitHub-App credentials + SILO_BASE_URL=$SILO_BASE_EFFECTIVE into $ENVFILE"
    echo "  (GITHUB_PRIVATE_KEY stored base64-encoded; the secret is never printed)"
    if [[ "$NO_RESTART" == yes ]]; then
      echo "skipped restart (--no-restart) — apply with: cd \"$PLANE_DIR\" && docker compose --env-file plane.env up -d"
    elif _docker_running; then
      ( cd "$PLANE_DIR" && docker compose --env-file plane.env up -d >/dev/null 2>&1 )
      echo "restarted Plane stack"
    else
      echo "Docker isn't running — restart Plane to apply: cd \"$PLANE_DIR\" && docker compose --env-file plane.env up -d"
    fi
    if ! _silo_running; then
      echo "INIT_PLANE_GITHUB_WARN no 'silo' container detected — the integration backend"
      echo "  isn't part of the Community stack, so activation may not be available on this build."
    fi
    case "$SILO_BASE_EFFECTIVE" in
      *localhost*|*127.0.0.1*)
        echo "INIT_PLANE_GITHUB_WARN SILO_BASE_URL is local ($SILO_BASE_EFFECTIVE) — GitHub can't"
        echo "  reach it for OAuth/webhooks. Re-run with --silo-base-url <public https URL>.";;
    esac
    echo "next steps:"
    echo "  1) Plane → Workspace Settings → Integrations → GitHub → Connect, then install the app on your repos."
    echo "  2) In a project, connect a repo to enable two-way issue/PR sync."
    echo "  3) revert any time: /init-plane github --remove"
    ;;

  app)
    # PB-136 / PB-148: package the running Plane instance as a native macOS app and
    # install it to /Applications. The app is a Tauri v2 shell (source in
    # lib/plane-app/) that registers a `plane://` URL scheme, so issue links open
    # straight inside the app (deep linking) — something the old Pake wrapper could
    # not do (Pake ignores any URL passed on launch). Idempotent; guides (never
    # auto-installs) its cargo/tauri toolchain the same way `up` guides Docker.
    #
    # The app carries the browser-facing vanity URL (_app_url) so it looks and
    # behaves like the site — EXCEPT the webview resolves hostnames through the OS,
    # with no RFC 6761 *.localhost shortcut, so a vhost name like plane.localhost
    # must be in /etc/hosts or the app loads blank. We detect that and print the
    # one-line sudo fix instead of running it. The resolved URL is templated into
    # the app's single PLANE_BASE (window start URL + plane:// deep-link target).
    NAME="Plane"; APP_URL=""; A_HOST=""; A_PORT=""; DO_REMOVE=no; NO_INSTALL=no
    PLANE_HOME_OVERRIDE=""
    ICON_URL="https://plane.so/favicon/android-chrome-512x512.png"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name)       NAME="${2:?--name needs a value}"; shift 2;;
        --url)        APP_URL="${2:?--url needs a value}"; shift 2;;
        --host)       A_HOST="${2:?--host needs a value}"; shift 2;;
        --port)       A_PORT="${2:?--port needs a value}"; shift 2;;
        --icon)       ICON_URL="${2:?--icon needs a value}"; shift 2;;
        --plane-home) PLANE_HOME_OVERRIDE="${2:?--plane-home needs a value}"; shift 2;;
        --no-install) NO_INSTALL=yes; shift;;
        --remove)     DO_REMOVE=yes; shift;;
        *) echo "pbrain: unknown flag for /init-plane app: $1" >&2; exit 1;;
      esac
    done

    APP_PATH="/Applications/$NAME.app"

    if [[ "$DO_REMOVE" == yes ]]; then
      echo "INIT_PLANE_APP_REMOVE"
      osascript -e "quit app \"$NAME\"" >/dev/null 2>&1 || true
      if [[ -d "$APP_PATH" ]]; then
        rm -rf "$APP_PATH"
        echo "removed $APP_PATH"
      else
        echo "nothing to remove ($APP_PATH not present)"
      fi
      exit 0
    fi

    if [[ "$(uname -s)" != "Darwin" ]]; then
      echo "INIT_PLANE_APP_UNSUPPORTED /init-plane app builds a macOS .app — this isn't macOS."
      exit 0
    fi

    # The Tauri toolchain is required; guide rather than auto-install (matches
    # `up`'s Docker flow). Need both `cargo` (Rust) and the v2 `cargo tauri` CLI.
    if ! _have cargo; then
      echo "INIT_PLANE_APP_NEED_TAURI Rust's cargo isn't installed."
      echo "Install Rust (https://rustup.rs), then the Tauri CLI:"
      echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
      echo "  cargo install tauri-cli --version \"^2\""
      echo "then re-run: /init-plane app"
      exit 0
    fi
    if ! cargo tauri --version >/dev/null 2>&1; then
      echo "INIT_PLANE_APP_NEED_TAURI the Tauri v2 CLI isn't installed."
      echo "Install it (compiles from source — a few minutes):"
      echo "  cargo install tauri-cli --version \"^2\""
      echo "then re-run: /init-plane app"
      exit 0
    fi

    # Locate the app source shipped with pbrain.
    APP_SRC="$_SCRIPT_DIR/../lib/plane-app"
    if [[ ! -f "$APP_SRC/src-tauri/tauri.conf.json" ]]; then
      echo "INIT_PLANE_APP_ERROR app source not found at $APP_SRC" >&2
      exit 1
    fi

    # Resolve the URL: explicit --url wins; else --host/--port compose one; else
    # the vhost vanity URL from plane.env (falls back to http://localhost).
    if [[ -z "$APP_URL" ]]; then
      if [[ -n "$A_HOST" || -n "$A_PORT" ]]; then
        APP_URL="http://${A_HOST:-plane.localhost}:${A_PORT:-1800}"
      else
        APP_URL="$(_app_url)"
      fi
    fi
    APP_URL="${APP_URL%/}"   # normalize: no trailing slash (we template a bare base)

    # Pull the bare host out of the URL for the /etc/hosts resolution check.
    URL_HOST="$(printf '%s\n' "$APP_URL" | sed -E 's#^[a-z]+://##; s#[:/].*$##')"

    echo "INIT_PLANE_APP"
    echo "target URL: $APP_URL"

    if ! _plane_running; then
      echo "INIT_PLANE_APP_WARN no Plane container is running — the app will show a"
      echo "  connection error until you start Plane (/init-plane up)."
    fi

    # The blank-screen guard: the webview can't resolve a vhost name that the OS
    # resolver doesn't know. Fail fast with the exact fix instead of shipping a
    # blank app. (curl/Chrome work via their own *.localhost shortcut; the webview
    # does not — this is the one place the otherwise-unneeded hosts entry matters.)
    if ! _host_resolves "$URL_HOST"; then
      echo "INIT_PLANE_APP_NEED_HOSTS the app's webview can't resolve '$URL_HOST'."
      echo "Unlike a browser, the macOS webview has no automatic *.localhost"
      echo "resolution, so add it to /etc/hosts once (needs sudo — run it yourself):"
      echo "  echo \"127.0.0.1 $URL_HOST\" | sudo tee -a /etc/hosts"
      echo "then re-run: /init-plane app"
      exit 0
    fi

    # Copy the app source into a writable build dir under the managed Plane home,
    # so the repo's source tree (and its committed localhost default) stays pristine
    # and re-runs are clean. rsync without target/ keeps the build incremental.
    BUILD_DIR="$PLANE_HOME/plane-app-build"; mkdir -p "$BUILD_DIR"
    rsync -a --delete --exclude 'target' --exclude 'node_modules' --exclude 'gen' \
      "$APP_SRC/" "$BUILD_DIR/"

    # Template the resolved URL into the single PLANE_BASE that drives BOTH the
    # window start URL and the plane:// deep-link target. The window is built in
    # Rust (so it can carry the requestIdleCallback init-script polyfill), so
    # PLANE_BASE in lib.rs is the sole start-URL source — there is no window URL in
    # tauri.conf.json to template.
    LIBRS="$BUILD_DIR/src-tauri/src/lib.rs"
    # lib.rs PLANE_BASE const (marked with __PLANE_BASE__): swap the bare base.
    python3 - "$LIBRS" "$APP_URL" <<'PYEOF'
import sys
path, base = sys.argv[1], sys.argv[2].rstrip('/')
s = open(path).read()
s = s.replace('"http://localhost:1800"; // __PLANE_BASE__',
              '"%s"; // __PLANE_BASE__' % base)
open(path, 'w').write(s)
PYEOF
    if ! grep -q "$APP_URL" "$LIBRS" 2>/dev/null; then
      echo "INIT_PLANE_APP_WARN could not template PLANE_BASE — app will target localhost:1800."
    fi

    # App Transport Security: macOS auto-exempts the literal host "localhost" from
    # its cleartext-http block, but NOT *.localhost subdomains (so an app pointed at
    # plane.localhost otherwise loads blank). Template the resolved host into the
    # merged Info.plist's ATS exception so the local http instance loads regardless
    # of host. URL_HOST was extracted above for the /etc/hosts check.
    PLIST="$BUILD_DIR/src-tauri/Info.plist"
    if [[ -f "$PLIST" ]]; then
      python3 - "$PLIST" "$URL_HOST" <<'PYEOF'
import sys
path, host = sys.argv[1], sys.argv[2]
s = open(path).read()
s = s.replace('<key>plane.localhost</key>', '<key>%s</key>' % host)
open(path, 'w').write(s)
PYEOF
    fi

    # Set the app/window display name to --name if customized.
    if [[ "$NAME" != "Plane" ]]; then
      python3 - "$CONF" "$NAME" <<'PYEOF'
import sys, json
path, name = sys.argv[1], sys.argv[2]
c = json.load(open(path))
c['productName'] = name
for w in c.get('app', {}).get('windows', []):
    if w.get('label') == 'main':
        w['title'] = name
json.dump(c, open(path, 'w'), indent=2)
PYEOF
    fi

    # Fetch the icon to a PNG and regenerate the bundle icon set (.icns) from it.
    ICON_TMP="$(mktemp -t plane-icon).png"
    if _have curl && curl -fsSL -o "$ICON_TMP" "$ICON_URL" 2>/dev/null \
        && file "$ICON_TMP" 2>/dev/null | grep -qi "PNG image"; then
      cp "$ICON_TMP" "$BUILD_DIR/src-tauri/icons/icon.png"
      ( cd "$BUILD_DIR/src-tauri/icons"
        sips -z 32 32   icon.png --out 32x32.png >/dev/null 2>&1 || true
        sips -z 128 128 icon.png --out 128x128.png >/dev/null 2>&1 || true
        sips -z 256 256 icon.png --out 128x128@2x.png >/dev/null 2>&1 || true
        ISET=icon.iconset; mkdir -p "$ISET"
        for s in 16 32 128 256 512; do sips -z $s $s icon.png --out "$ISET/icon_${s}x${s}.png" >/dev/null 2>&1 || true; done
        sips -z 32 32 icon.png --out "$ISET/icon_16x16@2x.png" >/dev/null 2>&1 || true
        sips -z 64 64 icon.png --out "$ISET/icon_32x32@2x.png" >/dev/null 2>&1 || true
        sips -z 256 256 icon.png --out "$ISET/icon_128x128@2x.png" >/dev/null 2>&1 || true
        sips -z 512 512 icon.png --out "$ISET/icon_256x256@2x.png" >/dev/null 2>&1 || true
        iconutil -c icns "$ISET" -o icon.icns >/dev/null 2>&1 || true
        rm -rf "$ISET" )
    else
      echo "INIT_PLANE_APP_WARN couldn't fetch a PNG icon — building with the bundled Plane icon."
    fi
    rm -f "$ICON_TMP"

    echo "building $NAME.app with Tauri (compiles a Rust binary — a few minutes)…"
    if ! ( cd "$BUILD_DIR" && cargo tauri build --bundles app ); then
      echo "INIT_PLANE_APP_ERROR Tauri build failed — see the output above." >&2
      exit 1
    fi
    BUILT_APP="$BUILD_DIR/src-tauri/target/release/bundle/macos/Plane.app"
    # Honor a custom --name: the bundle is named from productName, so it is already
    # "$NAME.app"; recompute the path generically.
    BUILT_APP="$(find "$BUILD_DIR/src-tauri/target/release/bundle/macos" -maxdepth 1 -name '*.app' | head -1)"
    if [[ -z "$BUILT_APP" || ! -d "$BUILT_APP" ]]; then
      echo "INIT_PLANE_APP_ERROR build produced no .app bundle" >&2
      exit 1
    fi

    if [[ "$NO_INSTALL" == yes ]]; then
      echo "built (not installed): $BUILT_APP"
      echo "  open it with: open \"$BUILT_APP\""
      exit 0
    fi

    # Install to /Applications: replace any existing copy, clear the Gatekeeper
    # quarantine flag so the unsigned app opens without the 'unidentified
    # developer' block, and register the plane:// scheme with Launch Services
    # (macOS only binds a custom scheme from an app under /Applications).
    osascript -e "quit app \"$NAME\"" >/dev/null 2>&1 || true
    rm -rf "$APP_PATH"
    cp -R "$BUILT_APP" "$APP_PATH"
    xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$APP_PATH" >/dev/null 2>&1 || true
    echo "installed: $APP_PATH"
    echo "next steps:"
    echo "  1) launch it:           open -a \"$NAME\""
    echo "  2) deep link an issue:  open 'plane://pb/browse/PB-110'"
    echo "  3) or convert a link:   $APP_SRC/plane-open.sh 'http://plane.localhost:1800/pb/browse/PB-110'"
    echo "  4) in-app find:         Cmd+F"
    echo "  5) rebuild any time:    /init-plane app"
    echo "  6) remove it:           /init-plane app --remove"
    echo "note: the app only works while your Docker Plane containers are running."
    echo "note: first launch shows Plane's login — after you sign in, deep links land on the issue."
    ;;

  host)
    # PB-18: move Plane onto a VPS + repoint pbrain. Mirrors /project-manager host
    # for the vault-free path. Delegates to lib/plane-host.sh.
    if ! declare -f pbrain_plh_probe >/dev/null 2>&1; then
      echo "INIT_PLANE_ERROR lib/plane-host.sh not available" >&2; exit 1
    fi
    HACTION="${1:-probe}"; [[ $# -gt 0 ]] && shift || true
    H_NAME=""; H_PORT=""; H_DOMAIN=""; H_TUNNEL=""; H_BASE=""; H_EMAIL=""; H_PW=""; H_YES=no
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --vps-host)        export PLH_VPS_HOST="${2:?}"; shift 2;;
        --vps-port)        export PLH_VPS_PORT="${2:?}"; shift 2;;
        --ssh-key)         export PLH_VPS_KEY="${2:?}"; shift 2;;
        --port)            H_PORT="${2:?}"; shift 2;;
        --domain)          H_DOMAIN="${2:?}"; shift 2;;
        --tunnel)          H_TUNNEL="${2:?}"; shift 2;;
        --base-url)        H_BASE="${2:?}"; shift 2;;
        --internal-email)  H_EMAIL="${2:?}"; shift 2;;
        --internal-password) H_PW="${2:?}"; shift 2;;
        --yes)             H_YES=yes; shift;;
        --*)               echo "pbrain: unknown flag for /init-plane host: $1" >&2; exit 1;;
        *)                 [[ -z "$H_NAME" ]] && H_NAME="$1"; shift;;
      esac
    done
    case "$HACTION" in
      probe|status) echo "INIT_PLANE_HOST_PROBE"; pbrain_plh_probe || true ;;
      deploy)       echo "INIT_PLANE_HOST_DEPLOY"; pbrain_plh_deploy_guide "$H_PORT" || true ;;
      domain)       echo "INIT_PLANE_HOST_DOMAIN"; pbrain_plh_domain_guide "$H_DOMAIN" || true ;;
      vpn)          echo "INIT_PLANE_HOST_VPN"; pbrain_plh_vpn "${H_NAME:-phone}" "$H_TUNNEL" || true ;;
      import)       echo "INIT_PLANE_HOST_IMPORT"; pbrain_plh_import "${H_NAME:-latest}" "$([[ "$H_YES" == yes ]] && echo --yes)" || true ;;
      wire)
        echo "INIT_PLANE_HOST_WIRE"
        [[ -n "$H_BASE" ]] || { echo "PLH_ERR host wire needs --base-url <url>"; exit 0; }
        pbrain_plh_wire "$H_BASE" "$H_EMAIL" "$H_PW" || true ;;
      *)
        echo "INIT_PLANE_HOST usage: host probe|deploy|domain|vpn|import|wire"
        echo "  probe | deploy [--port N] | domain [--domain d] | vpn [name] [--tunnel split]"
        echo "  import [latest] --yes | wire --base-url URL [--internal-email E --internal-password P]" ;;
    esac
    ;;

  status)
    echo "INIT_PLANE_STATUS"
    echo "docker_running: $(_docker_running && echo yes || echo no)"
    echo "plane_running: $(_plane_running && echo yes || echo no)"
    if _plane_running; then
      docker ps --format '  {{.Names}}\t{{.Status}}' 2>/dev/null | grep -i plane || true
    fi
    echo "silo_running: $(_silo_running && echo yes || echo no)"
    echo "github_configured: $(_github_configured)"
    echo "plane_config: $( [[ -f "$PLANE_CONFIG" ]] && echo present || echo absent )"
    echo "configured: $(_plane_configured)"
    echo "url: $DEFAULT_URL"
    ;;

  help|-h|--help)
    awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$_SCRIPT_DIR/init-plane.sh"
    ;;

  *)
    echo "pbrain: unknown /init-plane subcommand: $SUB" >&2
    echo "Try: probe | fetch | up | config | vhost | github | app | host | status | help" >&2
    exit 1
    ;;
esac
