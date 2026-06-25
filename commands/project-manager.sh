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
# It absorbs /init-plane's local self-host wizard (probe|fetch|up|config|vhost|
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
#   vhost [flags]         Move Plane off port 80 to a named vhost (default
#                         http://plane.localhost:1800) by editing Plane's own
#                         plane.env knobs (LISTEN_HTTP_PORT + APP_DOMAIN). No
#                         sidecar proxy — Plane's built-in Caddy serves both the
#                         vanity URL (browser) and 127.0.0.1:<port> (pbrain).
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
#   enrich --edits '<json>'  Apply enrichments ([{tie,field,value}]). Supported
#                         fields: priority, target_date/due, start_date, title/name,
#                         description/description_html, assignees (array of user UUIDs),
#                         subissue/subtask (value=title, creates a sub-issue),
#                         relation:<type> (value=target tie; types: blocking, blocked_by,
#                         relates_to, duplicate, start_after, start_before, finish_after,
#                         finish_before), estimate (value = a point on the project's
#                         scale, e.g. "3"; resolves to its estimate_point UUID — needs a
#                         cached scale, see the `estimates` verb).
#   subtree <ref>          Open sub-issues of an execute target (PB-81).
#   blocked-by <ref>       Open blockers of an execute target (PB-94) — the loop
#                          runs these first before the blocked issue.
#   move <tie> --to <status>           Move one issue's status.
#   priority <tie> --value <p>          Set one issue's priority.
#   timeline <tie> --target-date <d>    Set one issue's target date.
#   issue --project P --title T [--priority p] [--target-date d]
#                         Create a new issue in an existing project.
#   project-create --name N [--shortcut s]
#                         Create a new Plane project and add it to the registry.
#   workdir [<ref> --path <abs> [--kind conductor|repo] [--base-branch b]
#           [--isolation worktree|branch]] | workdir <ref> --clear
#                         Per-project working location for /plan-my-work
#                         `task execute` (where that project's tasks run). No
#                         args = list. Stored in plane.json projects[].work.
#   --- richer write / lookup verbs (the catalogue the NL router targets) ---
#   <plain words>         Natural-language instruction → routed to the verbs below
#                         (or explicit: route <words>). E.g. "bump PB-26 to high,
#                         tag backend". Resolves the issue, maps to ops, executes.
#   find <ref> [--project R]   Resolve URL | PB-26 | seq | name fragment → card(s).
#   update --edits '<json>'    Apply [{tie,field,value}] — any field family, batched.
#   tag <tie> --add a,b [--remove c] [--set x,y]   Labels (auto-created, capped).
#   assign <tie> --to <name|email|uuid>            Assignee by fuzzy name; '' clears.
#   comment <tie> --body <text>                    Add a comment.
#   reparent <tie> --parent <PB-12|none>           Re-parent / un-parent an issue.
#   cycle|module <tie> --name <name>               Add the issue to a cycle / module.
#   labels|members|cycles|modules [--project R]    List the project's name→uuid tables.
#   estimates [--project R] [--create [--template fibonacci|linear|squares|tshirt]
#             [--type points|categories|time] [--scale a,b,c] [--name N] [--replace]]
#             [--hours-per-point N] [--from-browser [--browser b] | --session-cookie C
#             | --email E --password P] [--import-json J]
#                         Show / create / live-fetch the project's estimate scale
#                         (story-point→uuid map + points→hours factor /plan-my-work packs
#                         blocks with). The scale is read LIVE every run (never cached, so
#                         manual edits in Plane show immediately). --create makes + activates
#                         a scale (default Fibonacci points; --template for UI presets incl.
#                         t-shirt, --replace to switch type; only points scales feed planning).
#                         The public API can't enumerate/create points → internal API. Internal auth:
#                         --from-browser pulls the session cookie from the local Chromium
#                         store + auto-refreshes on expiry (macOS), or a persisted cookie /
#                         login. Fetched if estimates exist, else skipped; --import-json is
#                         the manual fallback. Then the `estimate` field resolves.
#   backup <action>       Plane data snapshots (PB-17). Operates on Docker directly
#                         (no plane.json needed). actions: estimate | now [--dir D] |
#                         run (headless launchd entry) | enable [--time HH:MM]
#                         [--dest local|external|vps] [--dir D] [--keep N]
#                         [--vps-host H --vps-path P --vps-port N --ssh-key K] |
#                         disable | config <same flags> | status | list |
#                         restore <file|latest> --yes. See lib/plane-backup.sh.
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
source "$_SCRIPT_DIR/../lib/plane-backup.sh"
source "$_SCRIPT_DIR/../lib/plane-host.sh"
source "$_SCRIPT_DIR/../lib/pm-groom.sh"  # PB-46 headless mechanical grooming

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

# --- flag parsing (bash-3.2-safe, verbatim from project.sh) ------------------
# Positionals go in POS[]; each --flag sets an indirect plain var (value flags
# F_<name>, bool flags B_<name>). One subcommand per process, so no reset.
POS=()
_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sync|--include-backlog|--with-lanes|--no-tls|--remove|--from-browser|--create|--replace|--yes|--clear|--read|--require-approved|--apply|--autonomous|--seed|--migrate|--dry-run|--ordered)
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

RAW_ARGS="$*"               # the full instruction text, for the NL router
SUB="${1:-probe}"

# The known verbs. ANYTHING ELSE that arrives with args is treated as a
# natural-language instruction and routed (D2): "bump the auth bug to high and
# tag it backend" → resolve the issue, map to priority+tag, execute.
_PM_VERBS=" probe fetch up config vhost status setup use test ping web-base states projects ready queued enqueue progress review explode subtree blocked-by spec file create track capture enrich move priority timeline completed doing issue project-create workdir find update tag comment assign reparent cycle module labels members cycles modules estimates groom backup host route help -h --help "
_pm_known_verb() { [[ "$_PM_VERBS" == *" $1 "* ]]; }

if [[ $# -gt 0 ]] && ! _pm_known_verb "$SUB"; then
  SUB="route"               # free text → NL router; RAW_ARGS carries the instruction
else
  [[ $# -gt 0 ]] && shift || true
fi

# Ops + the NL router need a configured Plane instance. The setup family
# (probe|fetch|up|config|vhost|status|setup|use) must still run unconfigured.
case "$SUB" in
  route|find|update|tag|comment|assign|reparent|cycle|module|labels|members|cycles|modules|estimates|test|ping|states|projects|ready|progress|review|explode|subtree|blocked-by|spec|file|create|track|capture|enrich|move|priority|timeline|completed|doing|issue|project-create|workdir)
    if ! pbrain_plane_configured; then
      echo "PM_NOT_CONFIGURED"
      echo "Plane isn't set up yet — this needs a configured Plane instance."
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
    eval "$(pbrain_pbk_load)"
    echo "backup_scheduled: $(pbrain_launchagent_loaded "$PBK_LABEL" && echo yes || echo no)"
    echo "backup_dest: ${PBK_DEST:-local}"
    echo "backup_time: ${PBK_TIME:-03:30}"
    echo "groom_scheduled: $(pbrain_launchagent_loaded "$PMG_LABEL" && echo yes || echo no)"
    bk_dir="${PBK_LOCAL_DIR:-$(pbrain_pbk_default_dir)}"; [[ "${PBK_DEST:-local}" == external ]] && bk_dir="${PBK_EXTERNAL_DIR:-$bk_dir}"
    echo "backup_count: $(ls -1 "$bk_dir"/plane-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
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
    # Default base-url to the active local instance when the caller doesn't pass
    # one (the vhost loopback http://127.0.0.1:1800 once Plane is moved off :80,
    # else http://localhost) — see _default_base_url.
    has_base=no
    for a in "$@"; do [[ "$a" == "--base-url" ]] && has_base=yes; done
    if [[ "$has_base" == no ]]; then
      python3 "$PLANE" setup --base-url "$(_default_base_url)" "$@"
    else
      python3 "$PLANE" setup "$@"
    fi
    ;;

  vhost)
    # Move Plane off port 80 to a stable named vhost (default
    # http://plane.localhost:1800) by editing its OWN env knobs in plane.env.
    # No sidecar proxy: Plane's bundled Caddy is host-agnostic on its listener
    # port, so both the vanity URL (browser) and http://127.0.0.1:<port>
    # (pbrain's API client) land on the same backend.
    HOSTNAME="plane.localhost"; PORT="1800"; DO_REMOVE=no; NO_RESTART=no; PLANE_HOME_OVERRIDE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --host)       HOSTNAME="${2:?--host needs a value}"; shift 2;;
        --port)       PORT="${2:?--port needs a value}"; shift 2;;
        --plane-home) PLANE_HOME_OVERRIDE="${2:?--plane-home needs a value}"; shift 2;;
        --no-restart) NO_RESTART=yes; shift;;
        --remove)     DO_REMOVE=yes; shift;;
        *) echo "pbrain: unknown flag for /project-manager vhost: $1" >&2; exit 1;;
      esac
    done
    ENVFILE="$(_vhost_envfile "$PLANE_HOME_OVERRIDE")"
    if [[ -z "$ENVFILE" || ! -f "$ENVFILE" ]]; then
      echo "INIT_PLANE_VHOST_NO_ENV"
      echo "Couldn't find Plane's plane.env. Bring Plane up via /project-manager fetch + up,"
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
      if [[ -f "$PLANE" ]] && _has_creds; then
        python3 "$PLANE" setup --base-url "$DEFAULT_URL" >/dev/null
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
    if [[ -f "$PLANE" ]] && _has_creds; then
      if python3 "$PLANE" setup --base-url "$PBRAIN_URL" >/dev/null; then
        echo "pbrain base_url -> $PBRAIN_URL"
      else
        echo "INIT_PLANE_WARN could not update pbrain base_url; run: /project-manager config --base-url $PBRAIN_URL"
      fi
    else
      echo "Plane isn't wired to pbrain yet — once it is, set the URL with:"
      echo "  /project-manager config --base-url $PBRAIN_URL --api-key <pat> --workspace <slug> --project <id>"
    fi
    echo "next steps:"
    echo "  1) bookmark Plane in your browser:  $BROWSER_URL"
    echo "  2) verify the round-trip:           /project-manager test"
    echo "  3) revert any time:                 /project-manager vhost --remove"
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
    echo "backup_scheduled: $(pbrain_launchagent_loaded "$PBK_LABEL" && echo yes || echo no)"
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
    # PB-130: `states` lists a project's states; `states --seed` creates/reconciles
    # the custom pipeline; `states --migrate` also re-points existing issues onto it.
    # Both default to the whole registry; --projects R,... narrows the set.
    echo "PM_STATES"
    python3 "$PLANE" states \
      ${F_project:+--project "$F_project"} \
      ${F_projects:+--projects "$F_projects"} \
      $(_has_bool seed && echo --seed) \
      $(_has_bool migrate && echo --migrate) \
      $(_has_bool dry_run && echo --dry-run) || true
    ;;

  web-base)
    # Browser-facing Plane base for clickable links — the single source of truth
    # (loopback→vanity host swap) shared by groom + /plan-my-work. Bare URL on
    # stdout (no PM_* prefix) so callers can $(...) it; empty + rc 0 when
    # unconfigured, so it never needs the PM_NOT_CONFIGURED gate above.
    python3 "$PLANE" web-base || true
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
      $(_has_bool with_lanes && echo --with-lanes) \
      $(_has_bool require_approved && echo --require-approved) \
      $(_has_bool ordered && echo --ordered) || true
    ;;

  # PB-141: the QUEUE. `queued` = the ordered run queue (the Queued state) that
  # /plan-my-work walks. `enqueue` = groom writes the ordered ready stream INTO
  # the Queued state (move + sort_order). Plane is the queue, not the markdown.
  queued)
    _parse_args "$@"
    echo "PM_QUEUED"
    python3 "$PLANE" queued \
      ${F_projects:+--projects "$F_projects"} \
      ${F_project:+--project "$F_project"} || true
    ;;

  enqueue)
    _parse_args "$@"
    echo "PM_ENQUEUE"
    python3 "$PLANE" enqueue \
      ${F_projects:+--projects "$F_projects"} \
      ${F_project:+--project "$F_project"} || true
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
      --include-backlog || true
    echo ""
    PM_SELF="bash \"$_SCRIPT_DIR/project-manager.sh\""
    export PM_SELF
    envsubst '$PM_SELF' < "$_SCRIPT_DIR/templates/project-manager/review-walk.txt"
    ;;

  # ===== interactive task explode (PB-24): Socratic break-down of ONE issue ===
  explode)
    _parse_args "$@"
    ref="${POS[0]:-$(_flag ref)}"
    [[ -n "$ref" ]] || { echo "Usage: /project-manager explode <URL|PB-26|seq|name> [--project R]" >&2; exit 1; }
    echo "PM_EXPLODE"
    python3 "$PLANE" explode "$ref" ${F_project:+--project "$F_project"} || true
    echo ""
    PM_SELF="bash \"$_SCRIPT_DIR/project-manager.sh\""
    export PM_SELF
    envsubst '$PM_SELF' < "$_SCRIPT_DIR/templates/project-manager/explode-walk.txt"
    ;;

  # ===== spec/approval gate (PB-45): draft + approve ONE issue's plan =========
  spec)
    _parse_args "$@"
    ref="${POS[0]:-$(_flag ref)}"
    [[ -n "$ref" ]] || { echo "Usage: /project-manager spec <URL|PB-26|seq|name> [--project R] [--read]" >&2; exit 1; }
    echo "PM_SPEC"
    python3 "$PLANE" spec "$ref" ${F_project:+--project "$F_project"} || true
    echo ""
    # --read (or executor mode, e.g. /plan-my-work task execute) = JSON only: emit
    # the plan + approval state without the interactive Socratic walk.
    if _has_bool read || [[ -n "${PBRAIN_PM_CALLER:-}" ]]; then
      :
    else
      PM_SELF="bash \"$_SCRIPT_DIR/project-manager.sh\""
      export PM_SELF
      envsubst '$PM_SELF' < "$_SCRIPT_DIR/templates/project-manager/spec-walk.txt"
    fi
    ;;

  # ===== generic work-item intake from a free-text dump (PB-67) ===============
  # `file` + aliases create|track|capture: explode a dump into a triage-ready work
  # item of ANY type (bug/feature/docs/chore/refactor/improvement). --fast = minimal
  # one-confirm path; default = full Socratic build-up (type, sub-issues, labels,
  # estimate, priority, deadline). The walk reads PM_FAST to pick the path.
  file|create|track|capture)
    _parse_args "$@"
    # Free-text dump = the positional(s); join so an unquoted multi-word dump arrives whole.
    dump="${POS[*]:-$(_flag dump)}"
    [[ -n "$dump" ]] || { echo "Usage: /project-manager file \"<dump>\" [--project R] [--fast]" >&2; exit 1; }
    echo "PM_FILE"
    python3 "$PLANE" file "$dump" ${F_project:+--project "$F_project"} || true
    echo ""
    PM_SELF="bash \"$_SCRIPT_DIR/project-manager.sh\""
    PM_FAST="$(_has_bool fast && printf yes || printf no)"
    export PM_SELF PM_FAST
    envsubst '$PM_SELF $PM_FAST' < "$_SCRIPT_DIR/templates/project-manager/file-walk.txt"
    ;;

  enrich)
    _parse_args "$@"
    echo "PM_ENRICH"
    python3 "$PLANE" enrich --edits "${F_edits:-[]}" || true
    ;;

  move)
    _parse_args "$@"
    tie="${POS[0]:-}"; to="$(_flag to)"; [[ -n "$to" ]] || to="$(_flag status)"
    [[ -n "$tie" && -n "$to" ]] || { echo "Usage: /project-manager move <tie> --to <status> [--to-state <PipelineState>]" >&2; exit 1; }
    echo "PM_MOVE"
    # PB-130: --to-state targets a named pipeline state (Planning/Building/Testing/
    # Review) within the status's group; absent → the group's default (back-compat).
    to_state="$(_flag to_state)"
    python3 "$PLANE" move --tie "$tie" --status "$to" \
      ${to_state:+--to-state "$to_state"} \
      ${F_completed_at:+--completed-at "$F_completed_at"} || true
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

  issue)
    _parse_args "$@"
    project="${POS[0]:-$(_flag project)}"
    title="$(_flag title)"
    [[ -n "$project" && -n "$title" ]] || {
      echo "Usage: /project-manager issue --project <ref> --title <title> [--priority p] [--target-date YYYY-MM-DD] [--state <name>]" >&2
      exit 1
    }
    echo "PM_ISSUE"
    # PB-130: --state files the issue directly into a named state (e.g. Backlog);
    # default is the project default (Todo).
    python3 "$PLANE" issue \
      --project "$project" \
      --title "$title" \
      ${F_priority:+--priority "$F_priority"} \
      ${F_target_date:+--target-date "$F_target_date"} \
      ${F_state:+--state "$F_state"} || true
    ;;

  project-create)
    _parse_args "$@"
    name="${POS[0]:-$(_flag name)}"
    [[ -n "$name" ]] || { echo "Usage: /project-manager project-create --name <name> [--shortcut <s>]" >&2; exit 1; }
    echo "PM_PROJECT_CREATE"
    python3 "$PLANE" project-create \
      --name "$name" \
      ${F_shortcut:+--shortcut "$F_shortcut"} || true
    ;;

  # ===== per-project working location (PB-40 `/plan-my-work task execute`) =====
  # Records where a Plane project's tasks get executed (a pre-existing repo /
  # Conductor workspace path). Single-writer rule: config writes are a PM verb.
  #   workdir                              list configured working locations
  #   workdir <ref> --path <abs> [...]     set (kind|base-branch|isolation)
  #   workdir <ref> --clear                remove
  workdir)
    _parse_args "$@"
    ref="${POS[0]:-$(_flag project)}"
    echo "PM_WORKDIR"
    python3 "$PLANE" workdir ${ref:+"$ref"} \
      ${F_path:+--path "$F_path"} \
      ${F_kind:+--kind "$F_kind"} \
      ${F_base_branch:+--base-branch "$F_base_branch"} \
      ${F_isolation:+--isolation "$F_isolation"} \
      $(_has_bool clear && printf '%s' --clear) || true
    ;;

  completed)
    _parse_args "$@"
    echo "PM_COMPLETED"
    python3 "$PLANE" completed \
      ${F_projects:+--projects "$F_projects"} \
      --date "$(_flag date)" || true
    ;;

  doing)
    # PB-94 — issues currently in progress (the started/doing group); /end-of-day
    # reads this to surface started-but-unfinished work without a vault tracker.
    _parse_args "$@"
    echo "PM_DOING"
    python3 "$PLANE" doing ${F_projects:+--projects "$F_projects"} || true
    ;;

  # ===== richer write/lookup verbs (the catalogue the NL router targets) =====
  find)
    _parse_args "$@"
    ref="${POS[0]:-$(_flag ref)}"
    [[ -n "$ref" ]] || { echo "Usage: /project-manager find <URL|PB-26|seq|name> [--project R]" >&2; exit 1; }
    echo "PM_FIND"
    python3 "$PLANE" find "$ref" ${F_project:+--project "$F_project"} || true
    ;;

  # PB-81: resolve an execute TARGET that may be a PARENT issue → its open
  # sub-issues as ready-shaped rows. Read-only. `/plan-my-work task execute`
  # uses this to drive a parent as ONE logical target = SEPARATE sequential
  # units (one branch/PR/gated-merge per child; parent closed last).
  subtree)
    _parse_args "$@"
    ref="${POS[0]:-$(_flag ref)}"
    [[ -n "$ref" ]] || { echo "Usage: /project-manager subtree <URL|PB-26|seq|name> [--project R]" >&2; exit 1; }
    echo "PM_SUBTREE"
    python3 "$PLANE" subtree "$ref" ${F_project:+--project "$F_project"} || true
    ;;

  blocked-by)
    # PB-94 — the OPEN blockers of an execute target (the loop runs these first).
    _parse_args "$@"
    ref="${POS[0]:-$(_flag ref)}"
    [[ -n "$ref" ]] || { echo "Usage: /project-manager blocked-by <URL|PB-26|seq|name> [--project R]" >&2; exit 1; }
    echo "PM_BLOCKED_BY"
    python3 "$PLANE" blocked-by "$ref" ${F_project:+--project "$F_project"} || true
    ;;

  update)
    _parse_args "$@"
    echo "PM_UPDATE"
    python3 "$PLANE" update --edits "${F_edits:-[]}" || true
    ;;

  tag)
    _parse_args "$@"
    tie="${POS[0]:-$(_flag tie)}"
    [[ -n "$tie" ]] || { echo "Usage: /project-manager tag <tie> --add a,b [--remove c] [--set x,y]" >&2; exit 1; }
    echo "PM_TAG"
    python3 "$PLANE" tag --tie "$tie" \
      ${F_add:+--add "$F_add"} ${F_remove:+--remove "$F_remove"} ${F_set:+--set "$F_set"} || true
    ;;

  comment)
    _parse_args "$@"
    tie="${POS[0]:-$(_flag tie)}"; body="$(_flag body)"
    [[ -n "$tie" && -n "$body" ]] || { echo "Usage: /project-manager comment <tie> --body <text>" >&2; exit 1; }
    echo "PM_COMMENT"
    python3 "$PLANE" comment --tie "$tie" --body "$body" || true
    ;;

  assign)
    _parse_args "$@"
    tie="${POS[0]:-$(_flag tie)}"
    # --to must be PRESENT (even empty, to clear). Absent → don't silently clear.
    [[ -n "$tie" && -n "${F_to+x}" ]] || {
      echo "Usage: /project-manager assign <tie> --to <name|email|uuid>  (--to '' clears)" >&2; exit 1; }
    echo "PM_ASSIGN"
    python3 "$PLANE" assign --tie "$tie" --to "$(_flag to)" || true
    ;;

  reparent)
    _parse_args "$@"
    tie="${POS[0]:-$(_flag tie)}"; parent="$(_flag parent)"
    [[ -n "$tie" && -n "$parent" ]] || { echo "Usage: /project-manager reparent <tie> --parent <PB-12|none>" >&2; exit 1; }
    echo "PM_REPARENT"
    python3 "$PLANE" reparent --tie "$tie" --parent "$parent" || true
    ;;

  cycle)
    _parse_args "$@"
    tie="${POS[0]:-$(_flag tie)}"; name="$(_flag name)"
    [[ -n "$tie" && -n "$name" ]] || { echo "Usage: /project-manager cycle <tie> --name <cycle name>" >&2; exit 1; }
    echo "PM_CYCLE"
    python3 "$PLANE" cycle --tie "$tie" --name "$name" || true
    ;;

  module)
    _parse_args "$@"
    tie="${POS[0]:-$(_flag tie)}"; name="$(_flag name)"
    [[ -n "$tie" && -n "$name" ]] || { echo "Usage: /project-manager module <tie> --name <module name>" >&2; exit 1; }
    echo "PM_MODULE"
    python3 "$PLANE" module --tie "$tie" --name "$name" || true
    ;;

  labels)
    _parse_args "$@"
    echo "PM_LABELS"
    # PB-70: `labels --seed [--projects R,...]` backfills the convention labels
    # (bug/feature/chore/docs) onto existing projects; bare `labels` still lists.
    seed_flag=()
    _has_bool seed && seed_flag=(--seed)
    # ${arr[@]+…} guard: bash 3.2 (macOS) treats an empty array under `set -u`
    # as an unbound variable, so expand only when the array is non-empty.
    python3 "$PLANE" labels \
      ${F_project:+--project "$F_project"} \
      ${F_projects:+--projects "$F_projects"} \
      ${seed_flag[@]+"${seed_flag[@]}"} || true
    ;;

  members|cycles|modules)
    _parse_args "$@"
    echo "PM_$(printf '%s' "$SUB" | tr '[:lower:]' '[:upper:]')"
    python3 "$PLANE" "$SUB" ${F_project:+--project "$F_project"} || true
    ;;

  estimates)
    _parse_args "$@"
    echo "PM_ESTIMATES"
    python3 "$PLANE" estimates \
      ${F_project:+--project "$F_project"} \
      ${F_import_json:+--import-json "$F_import_json"} \
      ${F_hours_per_point:+--hours-per-point "$F_hours_per_point"} \
      ${F_session_cookie:+--session-cookie "$F_session_cookie"} \
      ${F_browser:+--browser "$F_browser"} \
      ${F_email:+--email "$F_email"} \
      ${F_password:+--password "$F_password"} \
      ${F_scale:+--scale "$F_scale"} \
      ${F_name:+--name "$F_name"} \
      ${F_template:+--template "$F_template"} \
      ${F_type:+--type "$F_type"} \
      $(_has_bool from_browser && printf '%s' --from-browser) \
      $(_has_bool create && printf '%s' --create) \
      $(_has_bool replace && printf '%s' --replace) || true
    ;;

  # ===== headless mechanical grooming (PB-46) ===============================
  # The deterministic half of `review`, runnable off the interactive session so
  # /plan-my-work finds a pre-triaged board. Actions:
  #   run [--projects csv] [--apply]  — scan + write the dated report (run = the
  #                                     scheduled/headless entry; default dry-run
  #                                     unless --apply; the LaunchAgent uses --apply)
  #   status                          — schedule + today's report status
  #   doctor [--apply]                — PB-79: check macOS power settings (Power
  #                                     Nap on AC) so the scheduled groom fires
  #                                     reliably; read-only unless --apply, which
  #                                     runs `sudo pmset -c powernap 1`
  #   enable [--time HH:MM] [--projects csv] — install the daily LaunchAgent
  #   disable                         — remove the LaunchAgent
  groom)
    ACTION="${1:-status}"; [[ $# -gt 0 ]] && shift || true
    _parse_args "$@"
    case "$ACTION" in
      run)
        echo "PM_GROOM"
        # Build argv explicitly (empty-array-safe under bash 3.2 + set -u).
        if [[ -n "${F_projects:-}" ]] && _has_bool apply; then
          pmg_run --projects "$F_projects" --apply || true
        elif [[ -n "${F_projects:-}" ]]; then
          pmg_run --projects "$F_projects" || true
        elif _has_bool apply; then
          pmg_run --apply || true
        else
          pmg_run || true
        fi
        # PB-94: when an AGENT is present (i.e. not the headless nightly LaunchAgent,
        # which sets PBRAIN_PMG_HEADLESS=1), emit the agent-facing block that drives
        # the auto-exec queue through the `task execute` lifecycle, parking + commenting
        # at the first manual gate. The headless run only writes the queue; the human's
        # next interactive groom/plan-my-work drives it.
        if [[ -z "${PBRAIN_PMG_HEADLESS:-}" ]]; then
          GROOM_DATA_FILE="$(pmg_data_file "$(pmg_today)")"
          PM_SELF="bash \"$_SCRIPT_DIR/project-manager.sh\""
          export GROOM_DATA_FILE PM_SELF
          envsubst '$GROOM_DATA_FILE $PM_SELF' < "$_SCRIPT_DIR/templates/project-manager/groom-drive.txt"
        fi
        ;;
      status)
        pmg_status || true
        ;;
      doctor)
        # PB-79: read-only check that the daily groom agent will fire reliably on
        # AC (Power Nap policy); --apply opts into the one pmset fix.
        if _has_bool apply; then
          pmg_doctor --apply || true
        else
          pmg_doctor || true
        fi
        ;;
      enable)
        echo "PM_GROOM_ENABLE"
        pmg_schedule_install "${F_time:-06:40}" "${F_projects:-}" \
          "$(_has_bool autonomous && printf 1 || printf 0)" || true
        echo "scheduled: $(pmg_plist)"
        if _has_bool autonomous; then
          echo "autonomous: on (headless Claude judgment triage; run 'groom doctor' to verify the claude login)"
        fi
        ;;
      disable)
        echo "PM_GROOM_DISABLE"
        pmg_schedule_uninstall || true
        echo "removed: $PMG_LABEL"
        ;;
      *)
        echo "Usage: /project-manager groom <run|status|doctor|enable|disable> [--projects csv] [--time HH:MM] [--apply]" >&2
        exit 1
        ;;
    esac
    ;;

  # ===== Plane backup / snapshot (PB-17) ====================================
  # Operates directly on Docker (no plane.json needed). Actions:
  #   now | run | estimate | enable | disable | config | status | list | restore
  backup)
    ACTION="${1:-status}"; [[ $# -gt 0 ]] && shift || true
    _parse_args "$@"
    eval "$(pbrain_pbk_load)"
    PM_SH="$_SCRIPT_DIR/project-manager.sh"

    case "$ACTION" in
      estimate)
        echo "PM_BACKUP_ESTIMATE"
        pbrain_pbk_estimate || true
        ;;

      now|run)
        # `run` is the headless launchd entry point; `now` is the interactive one.
        echo "PM_BACKUP"
        [[ "$ACTION" == run ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] backup run start"
        dest_override="$(_flag dir)"
        if [[ -n "$dest_override" ]]; then destdir="$dest_override"; mkdir -p "$destdir"
        else destdir="$(pbrain_pbk_resolve_dest_dir)" || { echo "Backup aborted — see PBK_ERR above."; exit 0; }; fi
        snap="$(pbrain_pbk_snapshot "$destdir")" || { echo "Snapshot failed — see PBK_ERR above."; exit 0; }
        echo "wrote $snap ($(pbrain_pbk_human "$(wc -c < "$snap" | tr -d ' ')"))"
        if [[ "${PBK_DEST:-local}" == vps ]]; then
          if pbrain_pbk_upload_vps "$snap"; then
            echo "uploaded to ${PBK_VPS_HOST}:${PBK_VPS_PATH}"
            [[ "${PBK_VPS_KEEPLOCAL:-True}" == "False" || "${PBK_VPS_KEEPLOCAL:-true}" == "false" ]] && rm -f "$snap" && echo "removed local staging copy"
          else
            echo "PBK_WARN upload failed — local copy kept at $snap"
          fi
        fi
        pbrain_pbk_prune "$destdir" "${PBK_KEEP:-14}"
        [[ "$ACTION" == run ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] backup run done"
        ;;

      enable)
        echo "PM_BACKUP_ENABLE"
        # Persist any destination/retention/schedule flags, then install the agent.
        saves=()
        [[ -n "$(_flag dest)" ]] && saves+=("dest=$(_flag dest)")
        [[ -n "$(_flag dir)" && "$(_flag dest)" == external ]] && saves+=("external_dir=$(_flag dir)")
        [[ -n "$(_flag dir)" && "$(_flag dest)" != external ]] && saves+=("local_dir=$(_flag dir)")
        [[ -n "$(_flag keep)" ]] && saves+=("keep=$(_flag keep)")
        [[ -n "$(_flag time)" ]] && saves+=("time=$(_flag time)")
        [[ -n "$(_flag vps_host)" ]] && saves+=("vps.host=$(_flag vps_host)")
        [[ -n "$(_flag vps_path)" ]] && saves+=("vps.path=$(_flag vps_path)")
        [[ -n "$(_flag vps_port)" ]] && saves+=("vps.port=$(_flag vps_port)")
        [[ -n "$(_flag ssh_key)" ]] && saves+=("vps.ssh_key=$(_flag ssh_key)")
        [[ ${#saves[@]} -gt 0 ]] && pbrain_pbk_save "${saves[@]}"
        eval "$(pbrain_pbk_load)"
        pbrain_pbk_schedule_install "$PM_SH" "${PBK_TIME:-03:30}"
        if pbrain_launchagent_loaded "$PBK_LABEL"; then
          echo "daily Plane backup scheduled at ${PBK_TIME:-03:30} → dest=${PBK_DEST:-local}, keep=${PBK_KEEP:-14}"
          echo "runs: $(pbrain_stable_cmd_path "$PM_SH") backup run   (log: $(pbrain_pbk_log_file))"
        else
          echo "PBK_WARN could not load the LaunchAgent — check launchctl."
        fi
        ;;

      disable)
        echo "PM_BACKUP_DISABLE"
        pbrain_pbk_schedule_uninstall
        echo "daily Plane backup disabled (existing snapshots kept)."
        ;;

      config)
        echo "PM_BACKUP_CONFIG"
        saves=()
        [[ -n "$(_flag dest)" ]] && saves+=("dest=$(_flag dest)")
        [[ -n "$(_flag dir)" && "$(_flag dest)" == external ]] && saves+=("external_dir=$(_flag dir)")
        [[ -n "$(_flag dir)" && "$(_flag dest)" != external ]] && saves+=("local_dir=$(_flag dir)")
        [[ -n "$(_flag keep)" ]] && saves+=("keep=$(_flag keep)")
        [[ -n "$(_flag time)" ]] && saves+=("time=$(_flag time)")
        [[ -n "$(_flag vps_host)" ]] && saves+=("vps.host=$(_flag vps_host)")
        [[ -n "$(_flag vps_path)" ]] && saves+=("vps.path=$(_flag vps_path)")
        [[ -n "$(_flag vps_port)" ]] && saves+=("vps.port=$(_flag vps_port)")
        [[ -n "$(_flag ssh_key)" ]] && saves+=("vps.ssh_key=$(_flag ssh_key)")
        [[ -n "$(_flag keep_local)" ]] && saves+=("vps.keep_local_copy=$(_flag keep_local)")
        [[ ${#saves[@]} -gt 0 ]] && pbrain_pbk_save "${saves[@]}"
        # If the schedule is already live, re-install so a new time takes effect.
        if pbrain_launchagent_loaded "$PBK_LABEL"; then
          eval "$(pbrain_pbk_load)"
          pbrain_pbk_schedule_install "$PM_SH" "${PBK_TIME:-03:30}"
          echo "config updated + live schedule refreshed."
        else
          echo "config updated (no schedule running — enable with: backup enable)."
        fi
        ;;

      list)
        echo "PM_BACKUP_LIST"
        bdir="${PBK_LOCAL_DIR:-$(pbrain_pbk_default_dir)}"; [[ "${PBK_DEST:-local}" == external ]] && bdir="${PBK_EXTERNAL_DIR:-$bdir}"
        if ls -1 "$bdir"/plane-*.tar.gz >/dev/null 2>&1; then
          ls -1t "$bdir"/plane-*.tar.gz 2>/dev/null | while IFS= read -r f; do
            printf '%s\t%s\n' "$(pbrain_pbk_human "$(wc -c < "$f" | tr -d ' ')")" "$(basename "$f")"
          done
        else
          echo "(no snapshots in $bdir)"
        fi
        ;;

      restore)
        echo "PM_BACKUP_RESTORE"
        target="${POS[0]:-$(_flag file)}"
        bdir="${PBK_LOCAL_DIR:-$(pbrain_pbk_default_dir)}"; [[ "${PBK_DEST:-local}" == external ]] && bdir="${PBK_EXTERNAL_DIR:-$bdir}"
        [[ "$target" == latest || -z "$target" ]] && target="$(ls -1t "$bdir"/plane-*.tar.gz 2>/dev/null | head -1)"
        [[ -n "$target" ]] || { echo "PBK_ERR no snapshot to restore (give a path or 'latest')"; exit 0; }
        pbrain_pbk_restore "$target" "$(_has_bool yes && echo --yes)" || true
        ;;

      status|*)
        echo "PM_BACKUP_STATUS"
        echo "scheduled: $(pbrain_launchagent_loaded "$PBK_LABEL" && echo "yes (daily ${PBK_TIME:-03:30})" || echo no)"
        echo "destination: ${PBK_DEST:-local}"
        bdir="${PBK_LOCAL_DIR:-$(pbrain_pbk_default_dir)}"; [[ "${PBK_DEST:-local}" == external ]] && bdir="${PBK_EXTERNAL_DIR:-$bdir}"
        echo "directory: $bdir"
        [[ "${PBK_DEST:-local}" == vps ]] && echo "vps: ${PBK_VPS_HOST:-<unset>}:${PBK_VPS_PATH:-<unset>} (keep_local=${PBK_VPS_KEEPLOCAL:-true})"
        echo "retention: keep ${PBK_KEEP:-14}"
        if command -v tmutil >/dev/null 2>&1 && [[ "${PBK_DEST:-local}" == local ]]; then
          echo "time_machine: $(tmutil isexcluded "$bdir" 2>/dev/null | grep -q '\[Excluded\]' && echo "EXCLUDED — not in Time Machine" || echo "included (Time Machine covers it)")"
        fi
        cnt="$(ls -1 "$bdir"/plane-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')" || true
        last="$(ls -1t "$bdir"/plane-*.tar.gz 2>/dev/null | head -1)" || true
        echo "snapshots: ${cnt:-0}"
        [[ -n "$last" ]] && echo "latest: $(basename "$last") ($(pbrain_pbk_human "$(wc -c < "$last" | tr -d ' ')"))"
        ;;
    esac
    ;;

  # ===== host (PB-18): move Plane onto a VPS + repoint pbrain =====
  host)
    ACTION="${1:-probe}"; [[ $# -gt 0 ]] && shift || true
    _parse_args "$@"
    # Ad-hoc VPS overrides for a user without a backup `vps` block yet.
    [[ -n "$(_flag vps_host)" ]] && export PLH_VPS_HOST="$(_flag vps_host)"
    [[ -n "$(_flag vps_port)" ]] && export PLH_VPS_PORT="$(_flag vps_port)"
    [[ -n "$(_flag ssh_key)" ]]  && export PLH_VPS_KEY="$(_flag ssh_key)"
    case "$ACTION" in
      probe|status) echo "PM_HOST_PROBE"; pbrain_plh_probe || true ;;
      deploy)       echo "PM_HOST_DEPLOY"; pbrain_plh_deploy_guide "$(_flag port)" || true ;;
      domain)       echo "PM_HOST_DOMAIN"; pbrain_plh_domain_guide "$(_flag domain)" || true ;;
      vpn)          echo "PM_HOST_VPN"; pbrain_plh_vpn "${POS[0]:-phone}" "$(_flag tunnel)" || true ;;
      import)       echo "PM_HOST_IMPORT"; pbrain_plh_import "${POS[0]:-latest}" "$(_has_bool yes && echo --yes)" || true ;;
      wire)
        echo "PM_HOST_WIRE"
        base="$(_flag base_url)"
        [[ -n "$base" ]] || { echo "PLH_ERR host wire needs --base-url <url>"; exit 0; }
        pbrain_plh_wire "$base" "$(_flag internal_email)" "$(_flag internal_password)" || true ;;
      *)
        echo "PM_HOST usage: host probe|deploy|domain|vpn|import|wire"
        echo "  probe                          read-only VPS state (reachability, docker, plane, wg)"
        echo "  deploy [--port 1800]           guide: stand Plane up on the VPS (setup.sh is interactive)"
        echo "  domain [--domain d]            guide: public domain + Caddy auto-TLS"
        echo "  vpn [name] [--tunnel split]    no-domain access via quick-vpn (reuse existing client or install; shows the client config)"
        echo "  import [latest] --yes          restore a VPS-resident backup INTO the VPS Plane (destructive)"
        echo "  wire --base-url URL [--internal-email E --internal-password P]   point pbrain at the remote (password → Keychain)"
        ;;
    esac
    ;;

  # ===== natural-language router (D2): vague instruction → specific verbs =====
  route)
    CALLER="${PBRAIN_PM_CALLER:-}"
    INSTR="${RAW_ARGS#route }"
    PM_SELF="bash \"$_SCRIPT_DIR/project-manager.sh\""
    echo "PM_ROUTE"
    echo "instruction: $INSTR"
    echo "caller: ${CALLER:-direct}"
    echo "project_manager_cmd: $PM_SELF"
    echo ""
    echo "=== PROJECT REGISTRY (id | name | shortcut) ==="
    pbrain_projects_registry_json 2>/dev/null || echo "[]"
    echo ""
    if [[ -z "$CALLER" ]]; then
      # DIRECT invocation → load planning context so routing is goal-aware (D3).
      PLAN_DIR="${PBRAIN_PLAN_DIR:-$VAULT_DIR/life/daily-planning}"
      STORE="$(pbrain_profile_store "$PLAN_DIR" 2>/dev/null || true)"
      ISO_WEEK="$(python3 -c 'import datetime;t=datetime.date.today();y,w,_=t.isocalendar();print(f"{y}-W{w:02d}")')"
      MONTH_YEAR="$(date +%Y-%m)"
      PROFILE_FILE="$(pbrain_profile_latest "$STORE" plans-profile 2>/dev/null || true)"
      WEEKLY_GOALS_FILE="$(pbrain_profile_latest_for_period "$STORE" weekly-goals "$ISO_WEEK" 2>/dev/null || true)"
      MONTHLY_GOALS_FILE="$(pbrain_profile_latest_for_period "$STORE" monthly-goals "$MONTH_YEAR" 2>/dev/null || true)"
      echo "=== PLANNING CONTEXT (direct invocation — weigh the instruction against these) ==="
      echo "iso_week: $ISO_WEEK   month: $MONTH_YEAR"
      if [[ -n "$PROFILE_FILE" ]]; then
        echo "--- current_focus (lean: id·title·track·priority·deadline·project) ---"
        pbrain_profile_json "$PROFILE_FILE" | python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
keys=('id','title','goal','track','priority','deadline','plane_project','project_name')
print(json.dumps([{k:f.get(k) for k in keys if f.get(k) is not None}
                  for f in d.get('current_focus',[])], ensure_ascii=False))" 2>/dev/null || echo "[]"
      fi
      echo "--- this week's goals ($ISO_WEEK) ---"
      if [[ -n "$WEEKLY_GOALS_FILE" ]]; then cat "$WEEKLY_GOALS_FILE" 2>/dev/null || true; else echo "(none set — /weekly-review creates these)"; fi
      echo "--- this month's goals ($MONTH_YEAR) ---"
      if [[ -n "$MONTHLY_GOALS_FILE" ]]; then cat "$MONTHLY_GOALS_FILE" 2>/dev/null || true; else echo "(none set — /monthly-review creates these)"; fi
    else
      echo "=== EXECUTOR MODE (invoked by $CALLER) ==="
      echo "Do exactly the instruction below — no grooming, no planning deliberation,"
      echo "minimal questions. $CALLER already made the decisions; you just execute in Plane."
    fi
    echo ""
    export INSTR CALLER PM_SELF
    envsubst '$INSTR $CALLER $PM_SELF' < "$_SCRIPT_DIR/templates/project-manager/catalogue.txt"
    ;;

  help|-h|--help)
    awk 'NR>2 && /^#/ {sub(/^# ?/,""); print; next} NR>2 {exit}' "$_SCRIPT_DIR/project-manager.sh"
    ;;

  *)
    # Unreachable in practice: an unknown first token is treated as a natural-
    # language instruction and routed above. Kept as a defensive fallback.
    echo "pbrain: unknown /project-manager subcommand: $SUB" >&2
    echo "Verbs: probe|fetch|up|config|vhost|status|setup|use|test|states|projects|ready|" >&2
    echo "  progress|review|enrich|move|priority|timeline|issue|project-create|find|update|" >&2
    echo "  tag|comment|assign|reparent|cycle|module|labels|members|cycles|modules" >&2
    echo "Or just describe what you want in plain words — it'll be routed." >&2
    exit 1
    ;;
esac

