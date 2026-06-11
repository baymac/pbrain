#!/usr/bin/env bash
# Migration 0002 (STAGED, owner: plan-my-day): restructure the goals profile
# into the versioned store, dropping current_focus and splitting out the new
# work library + goals library.
#
#   old: $VAULT_DIR/life/Goals Profile.md  (or legacy ~/.config/pbrain/plan-profile.json)
#   new: <plan-dir>/.profile/goals-profile.v1.md   (no current_focus;
#        work_goals/life_goals reference the libraries; consolidated
#        working_style fields)
#        <plan-dir>/.profile/work-library.v1.md
#        <plan-dir>/.profile/goals-library.v1.md
#
# This rebuild needs the user (validate old values part by part, ask what is
# new, drop what is gone), so the runner leaves it pending; plan-my-day.sh
# detects it via pbrain_migration_pending and drives the rebuild in-session,
# then records it with `bash lib/migrations.sh record 0002_goals_profile_restructure`.

MIGRATION_KIND=staged
MIGRATION_OWNER="plan-my-day"

migration_applicable() {
  local store
  store="${PBRAIN_PLAN_DIR:-$VAULT_DIR/life/daily-planning}/.profile"
  # Already rebuilt → nothing to do.
  compgen -G "$store/goals-profile.v*.md" >/dev/null 2>&1 && return 1
  [[ -f "$VAULT_DIR/life/Goals Profile.md" ]] && return 0
  [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/plan-profile.json" ]] && return 0
  return 1
}
