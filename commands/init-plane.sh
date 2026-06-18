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
    echo "silo_running: $(_silo_running && echo yes || echo no)"
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
    echo "Try: probe | fetch | up | config | vhost | github | status | help" >&2
    exit 1
    ;;
esac
