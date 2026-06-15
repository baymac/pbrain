#!/usr/bin/env bash
set -euo pipefail

# project-manager.sh — the technical commander of Plane (makeplane).
#
# pbrain's project brain lives in Plane: one pbrain "project" = one Plane PROJECT
# (a workspace holds many), each a Module → Issue → Sub-issue tree with Plane's
# own UI. /project-manager is the operator between pbrain and Plane — it sets the
# instance up, then reads/writes work items so the daily loop (/plan-my-work,
# /end-of-day, /weekly-review) can pull ready tasks and push status back.
#
# It absorbs /init-plane's local self-host wizard (probe|fetch|up|config|portless|
# status) AND the Plane ops (setup|use|test|states|projects|ready|progress|review|
# enrich|move|priority|timeline). Plane is the sole project backend — when it
# isn't configured, the ops below degrade to a friendly "set Plane up" message
# and the daily-loop seams in lib/projects.sh return empty.
#
# Subcommands:
#   --- infra / setup (absorbed from /init-plane) ---
#   probe                 Machine state for the wizard (default).
#   fetch                 Download Plane's official setup.sh into the managed dir.
#   up                    Run Plane's own installer menu (Install/Start/Stop…).
#   config <flags>        Wire pbrain → a LOCAL instance (base-url defaults to
#                         http://localhost; delegates to lib/plane.py setup).
#   portless [flags]      Front Plane with a stable https://<name>.localhost URL.
#   status                Docker + Plane container + pbrain backend state.
#   --- Plane ops ---
#   setup <flags>         Wire pbrain → ANY instance (Cloud or remote; no
#                         localhost default). Delegates to lib/plane.py setup.
#   use <plane|markdown>  Switch the daily-loop backend.
#   test                  Ping the configured project (lists its states).
#   states [--project P]  Dump the project's state list (JSON).
#   projects [--sync]     Show / refresh the project registry.
#   ready [--projects …]  Ready tasks across projects (cross-project sorted).
#   progress --projects … [--since DATE]   Per-project progress report.
#   review --projects …   Read-only thin-issue scan (walk + confirm enrichment).
#   enrich --edits '<json>'  Apply confirmed enrichments ([{tie,field,value}]).
#   move <tie> --to <status>           Move one issue's status.
#   priority <tie> --value <p>          Set one issue's priority.
#   timeline <tie> --target-date <d>    Set one issue's target date.
#
# Overrides:
#   PBRAIN_PLANE_HOME     where setup.sh + its data live (default
#                         ~/.config/pbrain/plane-selfhost)
#   PBRAIN_PLANE_BASE_URL/_API_KEY/_WORKSPACE/_PROJECT — Plane config/env.

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

pbrain_emit_prefs "project-manager" || true

PLANE="$(pbrain_plane_engine)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pbrain"
PLANE_CONFIG="$(pbrain_plane_config)"
PLANE_HOME="${PBRAIN_PLANE_HOME:-$CONFIG_DIR/plane-selfhost}"
SETUP_SH="$PLANE_HOME/setup.sh"
SETUP_URL="https://github.com/makeplane/plane/releases/latest/download/setup.sh"
DEFAULT_URL="http://localhost"

if ! command -v python3 >/dev/null 2>&1; then
  echo "pbrain: /project-manager needs python3 (stdlib only) and it isn't on PATH." >&2
  exit 1
fi

# --- infra helpers (ported from init-plane.sh) ------------------------------
_have() { command -v "$1" >/dev/null 2>&1; }
_docker_running() { _have docker && docker info >/dev/null 2>&1; }
_compose_ok() {
  { _have docker && docker compose version >/dev/null 2>&1; } || _have docker-compose
}
_plane_running() {
  _docker_running || return 1
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qiE 'plane' && return 0
  return 1
}

# --- flag parsing (bash-3.2-safe, verbatim from project.sh) ------------------
# Positionals go in POS[]; each --flag sets an indirect plain var (value flags
# F_<name>, bool flags B_<name>). One subcommand per process, so no reset.
POS=()
_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sync|--include-backlog|--with-lanes|--no-tls|--remove)
        local bkey="${1#--}"; bkey="${bkey//-/_}"
        eval "B_${bkey}=1"; shift ;;
      --*)
        local key="${1#--}"; key="${key//-/_}"; shift
        eval "F_${key}=\${1:-}"; shift || true ;;
      *)
        POS+=("$1"); shift ;;
    esac
  done
}
_flag() { eval "printf '%s' \"\${F_$1:-}\""; }
_has_bool() { eval "[[ -n \"\${B_$1:-}\" ]]"; }

SUB="${1:-probe}"
[[ $# -gt 0 ]] && shift || true

# Ops subcommands need a configured Plane instance. The setup family
# (probe|fetch|up|config|portless|status|setup|use) must still run unconfigured.
case "$SUB" in
  test|ping|states|projects|ready|progress|review|enrich|move|priority|timeline|completed)
    if ! pbrain_plane_configured; then
      echo "PM_NOT_CONFIGURED"
      echo "Plane isn't set up yet — '$SUB' needs a configured Plane instance."
      echo "Set one up with /init-plane (local self-host) or /project-manager setup"
      echo "(Plane Cloud / a remote host), then re-run. Task planning and project"
      echo "progress require Plane; the rest of pbrain works fine without it."
      exit 0
    fi
    ;;
esac

case "$SUB" in
  # ===== infra / setup (absorbed from /init-plane) ==========================
  probe)
    echo "INIT_PLANE_PROBE"
    echo "docker: $(_have docker && echo yes || echo no)"
    echo "docker_running: $(_docker_running && echo yes || echo no)"
    echo "compose: $(_compose_ok && echo yes || echo no)"
    echo "selfhost_dir: $PLANE_HOME ($( [[ -d "$PLANE_HOME" ]] && echo exists || echo absent ))"
    echo "setup_sh: $( [[ -f "$SETUP_SH" ]] && echo present || echo absent )"
    echo "plane_config: $( [[ -f "$PLANE_CONFIG" ]] && echo present || echo absent )"
    echo "plane_running: $(_plane_running && echo yes || echo no)"
    echo "configured: $(pbrain_plane_configured && echo yes || echo no)"
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
      echo "Run it with: /project-manager up   (or: bash \"$SETUP_SH\")"
    else
      echo "INIT_PLANE_ERROR could not download $SETUP_URL — check your connection." >&2; exit 1
    fi
    ;;

  up)
    if [[ ! -f "$SETUP_SH" ]]; then
      echo "INIT_PLANE_NEED_FETCH setup.sh not downloaded yet — run /project-manager fetch first." ; exit 0
    fi
    if ! _docker_running; then
      echo "INIT_PLANE_NEED_DOCKER Docker isn't running. Start Docker Desktop, then re-run." ; exit 0
    fi
    echo "INIT_PLANE_UP launching Plane's installer (interactive menu: choose Install the first time, then Start)."
    cd "$PLANE_HOME"
    bash "$SETUP_SH"
    ;;

  config)
    if [[ ! -f "$PLANE" ]]; then
      echo "INIT_PLANE_ERROR lib/plane.py not found at $PLANE" >&2; exit 1
    fi
    echo "INIT_PLANE_CONFIG"
    # Default base-url to the local instance when the caller doesn't pass one.
    has_base=no
    for a in "$@"; do [[ "$a" == "--base-url" ]] && has_base=yes; done
    if [[ "$has_base" == no ]]; then
      python3 "$PLANE" setup --base-url "$DEFAULT_URL" "$@"
    else
      python3 "$PLANE" setup "$@"
    fi
    ;;

  portless)
    NAME="plane"; PLANE_PORT="80"; SCHEME="https"; DO_REMOVE=no; URL_OVERRIDE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name)       NAME="${2:?--name needs a value}"; shift 2;;
        --plane-port) PLANE_PORT="${2:?--plane-port needs a value}"; shift 2;;
        --no-tls)     SCHEME="http"; shift;;
        --url)        URL_OVERRIDE="${2:?--url needs a value}"; shift 2;;
        --remove)     DO_REMOVE=yes; shift;;
        *) echo "pbrain: unknown flag for /project-manager portless: $1" >&2; exit 1;;
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
      if [[ -f "$PLANE" ]] && _has_creds; then
        if python3 "$PLANE" setup --base-url "$DEFAULT_URL" >/dev/null; then
          echo "pbrain base_url -> $DEFAULT_URL"
        fi
      fi
      echo "Plane itself is untouched; trim $NAME.localhost from its CORS/WEB_URL if you added it."
      exit 0
    fi
    URL="${URL_OVERRIDE:-$SCHEME://$NAME.localhost}"
    if ! portless alias "$NAME" "$PLANE_PORT" --force; then
      echo "INIT_PLANE_ERROR portless alias failed (is the portless proxy installed correctly?)" >&2
      exit 1
    fi
    echo "alias registered: $URL -> localhost:$PLANE_PORT"
    if [[ -f "$PLANE" ]] && _has_creds; then
      if python3 "$PLANE" setup --base-url "$URL" >/dev/null; then
        echo "pbrain base_url -> $URL"
      else
        echo "INIT_PLANE_WARN could not update pbrain base_url; run: /project-manager config --base-url $URL"
      fi
    else
      echo "Plane isn't wired to pbrain yet — once it is, set the URL with:"
      echo "  /project-manager config --base-url $URL --api-key <pat> --workspace <slug> --project <id>"
    fi
    echo "next steps:"
    echo "  1) start the proxy (once):  portless proxy start   ('portless service install' persists it)"
    echo "  2) allow the host in Plane's .env — add $URL to CORS_ALLOWED_ORIGINS / WEB_URL, then restart Plane"
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
    echo "configured: $(pbrain_plane_configured && echo yes || echo no)"
    echo "url: $DEFAULT_URL"
    ;;

  # ===== Plane ops ==========================================================
  setup)
    echo "PM_SETUP"
    _parse_args "$@"
    python3 "$PLANE" setup \
      ${F_base_url:+--base-url "$F_base_url"} \
      ${F_api_key:+--api-key "$F_api_key"} \
      ${F_workspace:+--workspace "$F_workspace"} \
      ${F_project:+--project "$F_project"}
    ;;

  use)
    _parse_args "$@"
    python3 "$PLANE" use "${POS[0]:-plane}"
    ;;

  test|ping)
    echo "PM_TEST"
    _parse_args "$@"
    python3 "$PLANE" ping ${F_project:+--project "$F_project"}
    ;;

  states)
    _parse_args "$@"
    python3 "$PLANE" states ${F_project:+--project "$F_project"}
    ;;

  projects)
    _parse_args "$@"
    echo "PM_PROJECTS"
    python3 "$PLANE" projects $(_has_bool sync && echo --sync) || true
    ;;

  ready)
    _parse_args "$@"
    echo "PM_READY"
    python3 "$PLANE" ready \
      ${F_projects:+--projects "$F_projects"} \
      ${F_project:+--project "$F_project"} \
      $(_has_bool include_backlog && echo --include-backlog) \
      $(_has_bool with_lanes && echo --with-lanes) || true
    ;;

  progress)
    _parse_args "$@"
    echo "PM_PROGRESS"
    python3 "$PLANE" progress \
      ${F_projects:+--projects "$F_projects"} \
      ${F_since:+--since "$F_since"} || true
    ;;

  review)
    _parse_args "$@"
    echo "PM_REVIEW"
    python3 "$PLANE" review \
      ${F_projects:+--projects "$F_projects"} \
      $(_has_bool include_backlog && echo --include-backlog) || true
    ;;

  enrich)
    _parse_args "$@"
    echo "PM_ENRICH"
    python3 "$PLANE" enrich --edits "${F_edits:-[]}" || true
    ;;

  move)
    _parse_args "$@"
    tie="${POS[0]:-}"; to="$(_flag to)"; [[ -n "$to" ]] || to="$(_flag status)"
    [[ -n "$tie" && -n "$to" ]] || { echo "Usage: /project-manager move <tie> --to <status>" >&2; exit 1; }
    echo "PM_MOVE"
    python3 "$PLANE" move --tie "$tie" --status "$to" ${F_completed_at:+--completed-at "$F_completed_at"} || true
    ;;

  priority)
    _parse_args "$@"
    tie="${POS[0]:-}"; val="$(_flag value)"
    [[ -n "$tie" && -n "$val" ]] || { echo "Usage: /project-manager priority <tie> --value <urgent|high|medium|low|none>" >&2; exit 1; }
    echo "PM_PRIORITY"
    python3 "$PLANE" priority --tie "$tie" --value "$val" || true
    ;;

  timeline)
    _parse_args "$@"
    tie="${POS[0]:-}"; td="$(_flag target_date)"
    [[ -n "$tie" && -n "$td" ]] || { echo "Usage: /project-manager timeline <tie> --target-date <YYYY-MM-DD>" >&2; exit 1; }
    echo "PM_TIMELINE"
    python3 "$PLANE" timeline --tie "$tie" --target-date "$td" || true
    ;;

  completed)
    _parse_args "$@"
    echo "PM_COMPLETED"
    python3 "$PLANE" completed \
      ${F_projects:+--projects "$F_projects"} \
      --date "$(_flag date)" || true
    ;;

  help|-h|--help)
    awk 'NR>2 && /^#/ {sub(/^# ?/,""); print; next} NR>2 {exit}' "$_SCRIPT_DIR/project-manager.sh"
    ;;

  *)
    echo "pbrain: unknown /project-manager subcommand: $SUB" >&2
    echo "Try: probe | fetch | up | config | portless | status | setup | use | test | states | projects | ready | progress | review | enrich | move | priority | timeline" >&2
    exit 1
    ;;
esac

pbrain_emit_self_improve "project-manager" || true
