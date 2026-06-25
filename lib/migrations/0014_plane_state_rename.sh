#!/usr/bin/env bash
# Migration 0014 (EFFECTFUL): rename the pipeline states "Review" → "Shipped" and
# "Done" → "Landed" (PB-XXX) across ALL registered Plane projects.
#
# Why: the state names now line up with the auto:ship / auto:land pipeline stages —
# "Shipped" = PR open / in review (the ship stage), "Landed" = merged / complete (the
# land stage). The rename is the single source: PIPELINE_STATES + STAGE_TO_STATE in
# lib/plane.py already carry the new names, and STATE_RENAMES (OLD→NEW) drives this
# migration so code and live workspace stay consistent.
#
# This is a RENAME-IN-PLACE via `states --rename`, which PATCHes each state's `name`
# (PlaneClient.update_state) WITHOUT changing its id or group — so every issue
# currently on Review/Done stays on the same state (now displayed as Shipped/Landed):
# there is NO issue re-pointing and NO downtime. Groups are unchanged (Shipped stays
# `started`, Landed stays `completed`), so all group-based logic (move --to done,
# completion detection, the queue exit, end-of-day) is unaffected.
#
# This is a SEPARATE migration from 0012/0013 (not an edit) because those are already
# merged to main and may sit in users' ledgers as .done — immutable history. 0014
# re-runs the idempotent `states --rename` engine path: on a workspace already carrying
# the new names it is a vacuous no-op.
#
# Like 0012/0013 this WRITES to the live, shared Plane workspace, so it is EFFECTFUL:
# the silent per-command runner does NOT apply it. It applies only when opted in —
# `bash lib/migrations.sh run --effectful`, or PBRAIN_MIGRATIONS_EFFECTFUL=1.
#
# State writes need Plane's internal API (session cookie / login); the public token is
# read-only for states. Without internal auth the rename makes no changes and the
# migration leaves itself unrecorded so a later opted-in run (with auth wired) retries.

MIGRATION_KIND=effectful
MIGRATION_OWNER="project-manager"

migration_applicable() {
  # Need Plane configured and the engine reachable; otherwise nothing to do here.
  declare -F pbrain_plane_configured >/dev/null || return 1
  pbrain_plane_configured || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  local engine; engine="$(pbrain_plane_engine 2>/dev/null)"
  [[ -f "$engine" ]] || return 1
  # Applicable iff at least one registered project still carries an OLD state name
  # (Review or Done). Ask the engine for a compact yes/no so a workspace already
  # renamed records vacuously (idempotent).
  local pending
  pending="$(python3 "$engine" states --rename --dry-run 2>/dev/null \
    | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    print("err"); sys.exit(0)
projs=d.get("projects",{}) if isinstance(d,dict) else {}
pending=any(r.get("old_present") for r in projs.values())
print("yes" if pending else "no")' 2>/dev/null)"
  [[ "$pending" == "yes" ]]
}

migration_apply() {
  local engine; engine="$(pbrain_plane_engine)"
  # Rename the pipeline states in place across the whole registry.
  local out
  out="$(python3 "$engine" states --rename 2>&1)" || {
    echo "0014: states --rename failed: $out" >&2
    return 1
  }
  # No internal auth → states weren't renamed; surface and leave pending.
  if printf '%s' "$out" | grep -q '"manual_steps"'; then
    echo "0014: Plane internal API not reachable — states not renamed. Run with internal auth (session login) configured, then re-run with --effectful." >&2
    return 1
  fi
  # Any per-project "error" means only a PARTIAL apply; leave pending for retry.
  if printf '%s' "$out" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
projs=d.get("projects",{}) if isinstance(d,dict) else {}
sys.exit(1 if any(r.get("error") for r in projs.values()) else 0)'; then
    echo "0014: renamed pipeline states (Review→Shipped, Done→Landed) across all registered projects."
    printf '%s\n' "$out"
  else
    echo "0014: partial — some projects errored; left pending for retry. Detail:" >&2
    printf '%s\n' "$out" >&2
    return 1
  fi
}
