#!/usr/bin/env bash
# Migration 0013 (EFFECTFUL): add the "Queued" pipeline state (PB-141) across ALL
# registered Plane projects.
#
# PB-141 makes Plane the queue: groom ranks todo issues into a new "Queued" state
# and /plan-my-work walks it. Queued was added to PIPELINE_STATES (between Todo and
# Planning, group=unstarted). Projects bootstrapped before PB-141 have every state
# EXCEPT Queued, so `states --migrate` now reports it as a "missing" state.
#
# This is a SEPARATE migration from 0012 (not an edit) because 0012 is already
# merged to main and may sit in users' ledgers as .done — immutable history. 0013
# re-runs the same idempotent `states --migrate` engine path, which (re)seeds any
# missing pipeline state (now including Queued) and re-points stragglers. Re-running
# on a workspace already carrying Queued is a vacuous no-op.
#
# Like 0012 this WRITES to the live, shared Plane workspace, so it is EFFECTFUL: the
# silent per-command runner does NOT apply it. It applies only when opted in —
# `bash lib/migrations.sh run --effectful`, or PBRAIN_MIGRATIONS_EFFECTFUL=1.
#
# State CREATION needs Plane's internal API (session cookie / login). Without it the
# seed makes no changes and reports manual UI steps; the migration then leaves itself
# unrecorded so a later opted-in run (with auth wired) retries.

MIGRATION_KIND=effectful
MIGRATION_OWNER="project-manager"

migration_applicable() {
  # Need Plane configured and the engine reachable; otherwise nothing to do here.
  declare -F pbrain_plane_configured >/dev/null || return 1
  pbrain_plane_configured || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  local engine; engine="$(pbrain_plane_engine 2>/dev/null)"
  [[ -f "$engine" ]] || return 1
  # Applicable iff at least one registered project is missing a pipeline state
  # (post-PB-141 that includes "Queued") or still carries a legacy default. Ask the
  # engine for a compact yes/no so a workspace already on the full pipeline records
  # vacuously (idempotent).
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
  # Seed (incl. the new Queued state) + re-point across the whole registry.
  local out
  out="$(python3 "$engine" states --migrate 2>&1)" || {
    echo "0013: states --migrate failed: $out" >&2
    return 1
  }
  # No internal auth → states weren't created; surface and leave pending.
  if printf '%s' "$out" | grep -q '"manual_steps"'; then
    echo "0013: Plane internal API not reachable — Queued state not created. Run with internal auth (session login) configured, then re-run with --effectful." >&2
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
    echo "0013: added the PB-141 Queued state across all registered projects (seed + re-point)."
    printf '%s\n' "$out"
  else
    echo "0013: partial — some projects errored; left pending for retry. Detail:" >&2
    printf '%s\n' "$out" >&2
    return 1
  fi
}
