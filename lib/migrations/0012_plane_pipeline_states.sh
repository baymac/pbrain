#!/usr/bin/env bash
# Migration 0012 (EFFECTFUL): adopt the custom lifecycle pipeline (PB-130) across
# ALL registered Plane projects.
#
#   For each project in the registry:
#     - seed the pipeline states Backlog → Triage → Planning → Building →
#       Testing → Review (+ Done/Cancelled), replacing Plane's default Todo /
#       In Progress (idempotent: seed_pipeline_states);
#     - re-point every EXISTING issue still on a removed/legacy state onto its
#       group-equivalent pipeline state (unstarted→Triage, started→Building);
#       issues already on a pipeline state, or on Done/Cancelled/Backlog, are
#       left untouched.
#
# This is the live-Plane counterpart to the code in this same change. Because it
# WRITES to a live, shared workspace (not local vault files), it is an EFFECTFUL
# migration: the silent per-command runner does NOT apply it (live writes must
# not fire as a side effect of running an unrelated command on another machine).
# It applies only when opted in — `bash lib/migrations.sh run --effectful`, or
# PBRAIN_MIGRATIONS_EFFECTFUL=1 in the env — and is idempotent, so a re-run after
# the workspace is already on the pipeline is a harmless no-op (recorded vacuous).
#
# State CREATION needs Plane's internal API (session cookie / login). Without it
# the seed makes no changes and reports the manual UI steps; this migration then
# leaves itself unrecorded so a later opted-in run (with auth wired) retries.

MIGRATION_KIND=effectful
MIGRATION_OWNER="project-manager"

migration_applicable() {
  # Need Plane configured and the engine reachable; otherwise nothing to do here.
  declare -F pbrain_plane_configured >/dev/null || return 1
  pbrain_plane_configured || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  local engine; engine="$(pbrain_plane_engine 2>/dev/null)"
  [[ -f "$engine" ]] || return 1
  # Applicable iff at least one registered project isn't fully on the pipeline yet —
  # i.e. it still has the "In Progress" default we remove, OR is missing any of the
  # pipeline work-states. We ask the engine for a compact yes/no so an already-
  # migrated workspace records vacuously (keeps the migration idempotent).
  local pending
  pending="$(python3 "$engine" states --migrate --dry-run 2>/dev/null \
    | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    print("err"); sys.exit(0)
projs=d.get("projects",{}) if isinstance(d,dict) else {}
pending=any((r.get("legacy_present") or r.get("missing")) for r in projs.values())
print("yes" if pending else "no")' 2>/dev/null)"
  [[ "$pending" == "yes" ]]
}

migration_apply() {
  local engine; engine="$(pbrain_plane_engine)"
  # Seed + re-point across the whole registry (default scope of states --migrate).
  local out
  out="$(python3 "$engine" states --migrate 2>&1)" || {
    echo "0012: states --migrate failed: $out" >&2
    return 1
  }
  # If the engine couldn't create states (no internal auth), it returns
  # manual_steps and changed nothing — don't record; surface and retry later.
  if printf '%s' "$out" | grep -q '"manual_steps"'; then
    echo "0012: Plane internal API not reachable — states not created. Run with internal auth (session login) configured, then re-run with --effectful." >&2
    return 1
  fi
  # Any per-project "error" means the migration is only PARTIALLY applied (e.g. a
  # state create/rename failed). Don't record — leave it pending so a re-run (now
  # idempotent for the projects that succeeded) retries the stragglers.
  if printf '%s' "$out" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)            # unparseable → treat as failure
projs=d.get("projects",{}) if isinstance(d,dict) else {}
sys.exit(1 if any(r.get("error") for r in projs.values()) else 0)'; then
    echo "0012: migrated all registered projects onto the PB-130 pipeline states (seed + re-point)."
    printf '%s\n' "$out"
  else
    echo "0012: partial — some projects errored; left pending for retry. Detail:" >&2
    printf '%s\n' "$out" >&2
    return 1
  fi
}
