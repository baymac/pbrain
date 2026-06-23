#!/usr/bin/env bash
# Migration 0007 (STAGED, owner: plan-my-day): reframe weekly/monthly goals
# from TASK-level to PROJECT-level.
#
#   old goal item: {id, goal, tie, priority, difficulty, success_looks_like, status}
#   new goal item: {id, goal, plane_project, project_name, priority,
#                   allocation_percent, success_looks_like, status, difficulty}
#
# The goals tiers become a CEO overview — which Plane PROJECTS are in play this
# week/month, at what priority, and at what % of expected time (allocation_percent
# summing to 100 across active goals) — no longer task-level detail. The real
# tasks live in Plane (see /project-manager, /plan-my-work).
#
# This rebuild needs the user (set the allocation %, balance to 100, and — when
# Plane is configured — pick the Plane project for each goal), so the runner
# leaves it pending; plan-my-day.sh detects it via pbrain_migration_pending and
# drives the reframe in-session over the CURRENT OPEN period's draft only. The
# allocation_percent reframe ALWAYS applies; "plane_project" is assigned only
# when Plane is configured (the registry is non-empty) — without Plane, goals
# reframe to focus-area + allocation_percent and plane_project stays "". Closed/
# committed periods stay legacy-but-readable (readers tolerate an absent
# allocation_percent), and the next /weekly-review mints fresh files in the new
# shape. Recorded with `bash lib/migrations.sh record 0007_goals_project_reframe`.

MIGRATION_KIND=staged
MIGRATION_OWNER="plan-my-day"

migration_applicable() {
  local store f
  store="${PBRAIN_PLAN_DIR:-$VAULT_DIR/life/daily-planning}/.profile"
  [[ -d "$store" ]] || return 1
  # Applicable when a weekly- or monthly-goals file exists that has NOT yet been
  # reframed (no allocation_percent anywhere in it). One such file is enough.
  for f in "$store"/weekly-goals.v*.md "$store"/monthly-goals.v*.md; do
    [[ -f "$f" ]] || continue
    grep -q 'allocation_percent' "$f" 2>/dev/null && continue
    return 0
  done
  return 1
}
