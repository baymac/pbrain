#!/usr/bin/env bash
# projects.sh — shared Plane seam layer for the daily loop.
#
# Sourced through lib/vault.sh (after profiles.sh) so that /plan-my-work,
# /plan-my-day, /end-of-day, /weekly-review, and /monthly-review can all reach
# the same Plane integration engine (lib/plane.py) through one set of seams.
# Like the other shared libs (habits.sh, reminders.sh) these helpers are DEFINED
# on source and only do work when CALLED; every one is written to never exit
# non-zero, so a command running under `set -euo pipefail` can call them with
# `|| true` safely.
#
# Plane is the sole project backend. When Plane isn't configured (no API key in
# env or ~/.config/pbrain/plane.json) every seam degrades to an empty array (or
# "{}" for progress), so task planning and project progress are simply
# unavailable — pbrain stays a working life-planner without them.

# Resolve this lib's directory at source time (symlink-safe) so we can find the
# engine regardless of how the sourcing command was invoked.
_PB_PROJECTS_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_PROJECTS_SRC" ]]; do
  _PB_PROJECTS_LINK="$(readlink "$_PB_PROJECTS_SRC")"
  [[ "$_PB_PROJECTS_LINK" = /* ]] && _PB_PROJECTS_SRC="$_PB_PROJECTS_LINK" \
    || _PB_PROJECTS_SRC="$(cd -P -- "$(dirname -- "$_PB_PROJECTS_SRC")" && pwd -P)/$_PB_PROJECTS_LINK"
done
PBRAIN_PROJECTS_LIB_DIR="$(cd -P -- "$(dirname -- "$_PB_PROJECTS_SRC")" && pwd -P)"
unset _PB_PROJECTS_SRC _PB_PROJECTS_LINK
export PBRAIN_PROJECTS_LIB_DIR

# Path to the Plane integration engine (lib/plane.py).
pbrain_plane_engine() {
  echo "$PBRAIN_PROJECTS_LIB_DIR/plane.py"
}

# Plane config file (holds a secret token → lives in ~/.config, never the vault).
pbrain_plane_config() {
  echo "${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/plane.json"
}

# True (0) when a Plane API key is reachable (env or config file).
pbrain_plane_configured() {
  [[ -n "${PBRAIN_PLANE_API_KEY:-}" ]] && return 0
  [[ -f "$(pbrain_plane_config)" ]] && grep -q '"api_key"' "$(pbrain_plane_config)" 2>/dev/null && return 0
  return 1
}

# Run the Plane engine; prints engine stdout. Never fatal.
pbrain_plane_run() {
  command -v python3 >/dev/null 2>&1 || { echo "[]"; return 0; }
  python3 "$(pbrain_plane_engine)" "$@" 2>/dev/null || true
}

# Path to the /project-manager command script (commands/project-manager.sh).
pbrain_projects_manager_cmd() {
  echo "$PBRAIN_PROJECTS_LIB_DIR/../commands/project-manager.sh"
}

# --- Plane seams ------------------------------------------------------------
# Each routes to Plane when configured, else degrades to []/{} so callers under
# set -e are safe. No backend branching — Plane is the only source.

# Ready open tasks as a JSON array of {tie,id,title,est_h,lane,due,status,...}.
# Used by /plan-my-day to seed the task slate. Empty array when Plane is off.
pbrain_projects_ready_json() {
  if pbrain_plane_configured; then
    local out; out="$(pbrain_plane_run ready ${PBRAIN_PLANE_READY_ARGS:-})"
    [[ -n "$out" && "$out" != PLANE_ERROR* ]] && echo "$out" || echo "[]"
    return 0
  fi
  echo "[]"
}

# Batch-apply end-of-day statuses. Arg: a JSON array of resolve rows:
#   [{"tie":"<project_id>:<issue_id>","status":"done|doing|todo|dropped|blocked","completed_at"?}]
# Used by /end-of-day.
pbrain_projects_resolve() {
  local ties="$1"
  [[ -n "$ties" ]] || { echo "[]"; return 0; }
  if pbrain_plane_configured; then
    pbrain_plane_run resolve --ties "$ties"
    return 0
  fi
  echo "[]"
}

# Project registry as a JSON array of {id,name,shortcut} (the configured
# registry / lone project).
pbrain_projects_registry_json() {
  if pbrain_plane_configured; then
    local out; out="$(pbrain_plane_run projects)"
    [[ -n "$out" && "$out" != PLANE_ERROR* ]] && echo "$out" || echo "[]"
    return 0
  fi
  echo "[]"
}

# Ready tasks across several projects (a comma-separated ref list, optional).
pbrain_projects_ready_multi_json() {
  local pids="${1:-}"
  if pbrain_plane_configured; then
    local out; out="$(pbrain_plane_run ready ${pids:+--projects "$pids"})"
    [[ -n "$out" && "$out" != PLANE_ERROR* ]] && echo "$out" || echo "[]"
    return 0
  fi
  echo "[]"
}

# Per-project progress JSON (status counts + weighted pct + completed-since).
pbrain_projects_progress_json() {
  local pids="${1:-}" since="${2:-}"
  if pbrain_plane_configured; then
    local out; out="$(pbrain_plane_run progress ${pids:+--projects "$pids"} ${since:+--since "$since"})"
    [[ -n "$out" && "$out" != PLANE_ERROR* ]] && echo "$out" || echo "{}"
    return 0
  fi
  echo "{}"
}

# Thin-issue review scan.
pbrain_projects_review_json() {
  local pids="${1:-}"
  if pbrain_plane_configured; then
    local out; out="$(pbrain_plane_run review ${pids:+--projects "$pids"})"
    [[ -n "$out" && "$out" != PLANE_ERROR* ]] && echo "$out" || echo "[]"
    return 0
  fi
  echo "[]"
}

# Issues completed in Plane on a given date (end-of-day unplanned detection).
pbrain_projects_completed_today_json() {
  local pids="${1:-}" date="${2:-}"
  [[ -n "$date" ]] || { echo "[]"; return 0; }
  if pbrain_plane_configured; then
    local out; out="$(pbrain_plane_run completed ${pids:+--projects "$pids"} --date "$date")"
    [[ -n "$out" && "$out" != PLANE_ERROR* ]] && echo "$out" || echo "[]"
    return 0
  fi
  echo "[]"
}

# Resolve an issue reference (URL | PB-26 | bare seq | name fragment) → JSON array
# of candidate cards {tie,id,issue_id,project,title,state,priority}. The caller
# (the model) disambiguates when >1 comes back. Empty array when Plane is off.
pbrain_projects_find_json() {
  local ref="${1:-}" project="${2:-}"
  [[ -n "$ref" ]] || { echo "[]"; return 0; }
  if pbrain_plane_configured; then
    local out; out="$(pbrain_plane_run find "$ref" ${project:+--project "$project"})"
    [[ -n "$out" && "$out" != PLANE_ERROR* ]] && echo "$out" || echo "[]"
    return 0
  fi
  echo "[]"
}

# Project labels / members / cycles as JSON — the name→UUID lookup tables the
# router resolves vague references against. Each takes an optional project ref
# (defaults to the lone/first project) and degrades to [] when Plane is off.
pbrain_projects_labels_json() {
  local project="${1:-}"
  if pbrain_plane_configured; then
    local out; out="$(pbrain_plane_run labels ${project:+--project "$project"})"
    [[ -n "$out" && "$out" != PLANE_ERROR* ]] && echo "$out" || echo "[]"
    return 0
  fi
  echo "[]"
}

pbrain_projects_members_json() {
  local project="${1:-}"
  if pbrain_plane_configured; then
    local out; out="$(pbrain_plane_run members ${project:+--project "$project"})"
    [[ -n "$out" && "$out" != PLANE_ERROR* ]] && echo "$out" || echo "[]"
    return 0
  fi
  echo "[]"
}

pbrain_projects_cycles_json() {
  local project="${1:-}"
  if pbrain_plane_configured; then
    local out; out="$(pbrain_plane_run cycles ${project:+--project "$project"})"
    [[ -n "$out" && "$out" != PLANE_ERROR* ]] && echo "$out" || echo "[]"
    return 0
  fi
  echo "[]"
}

# Per-project working locations (PB-40) as a JSON map {pid: {path,kind,...}}.
# Pure config read (no API call) — used by /plan-my-work `task execute` to know
# where each project's tasks run. Degrades to {} when Plane is unconfigured.
pbrain_projects_workdirs_json() {
  if pbrain_plane_configured; then
    local out; out="$(pbrain_plane_run workdirs)"
    [[ -n "$out" && "$out" != PLANE_ERROR* ]] && echo "$out" || echo "{}"
    return 0
  fi
  echo "{}"
}
